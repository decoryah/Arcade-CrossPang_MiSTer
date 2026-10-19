// Whole-machine bench driver (sim/tb_top.sv).
//   Vtb_top <image.rom> <frames> <out-prefix> [+state=<MAME state prefix>] [+load=rtl] [+every=N] [+first=N] [+foff=K]
//           [+inputs=<file>] [+dsw=<hex>] [+trace] [+wav] [+audio_from=<frame>] [+live]
// The image is tools/crospang_image.py's (the MRA's bytes).  Writes <out>.fNNNNN.ppm (the 320 x 240 picture of every frame from +first,
// every +every-th), a status line per frame and <out>.wav (48 kHz stereo: left the YM3812 (jtopl2) output, right the OKI's sum x 16) with +wav.
//   +state=P   preload the RAMs from P.{fg,bg,pal1,spr,regs} and keep both CPUs in reset (frozen-state bench)
//   +load=rtl  push the image through the RTL loader instead of preloading the SDRAM (and check what it stored)
//   +load=fast the same through the fast load (rtl/cp_fastload.sv) from the DDR3 model of tb_top.sv, as Main_MiSTer's address= leaves it
//   +foff=K    frame names: the picture that ends at vertical blank n (counted from 1 after the reset) is frame n + K.  MAME's dumps
//              (tools/lua/dump_state.lua) number the first vertical blank 0 and their picture of frame f is drawn at vertical blank f from
//              the state of that moment: the core's vertical blank n is MAME's n - 1; its picture ending at vertical blank n shows the
//              snapshot of vertical blank n - 1 (MAME's frame n - 2), or, with +live, the RAMs as the interrupt routine after vertical
//              blank n - 1 left them (what MAME draws at n - 1).  Default -2, with +live -1.
//   +ioff=K    the input log's frame f (dump_state.lua INPUTLOG writes f for a value set in MAME's frame notifier f - 1) is applied at the
//              core's vertical blank f + K.  Default 1: MAME's game first reads such a value after its vertical blank f (measured with
//              tools/lua/inreads.lua: the start set in notifier 260 is first read after vertical blank 261), which is the core's vertical
//              blank f + 1
//   +mameraster  (only with a VFLAGS=-DSIM_RASTER_60HZ build) start the raster so that its vertical blanks come at MAME's times: the
//              comparison of games whose main loop is not paced by the interrupt (Pitapat Puzzle) or CPU-paced effects
//   +cpustats  per frame: the 68000's bus cycles, the clocks its ROM reads wait for the cache, the clocks of cache line fills
//   +live      the renderer reads the video RAMs live (the core's OSD option "Video RAM: Live"); default: the snapshot taken at the
//              start of vertical blank, as MAME draws
//   +inputs=F  replay MAME's port values: lines "<frame> <P1_P2 hex> <COIN hex>" (dump_state.lua INPUTLOG), taking effect at that
//              frame's vertical blank
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "Vtb_top.h"
#include "Vtb_top__Dpi.h"
#include "Vtb_top___024root.h"
#include "verilated.h"
#include "svdpi.h"

static std::vector<uint8_t> load_file(const char* p) {
    std::vector<uint8_t> v;
    FILE* f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    v.resize(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) exit(2);
    fclose(f);
    return v;
}

static void write_ppm(const char* path, const uint8_t* rgb, int w, int h) {
    FILE* f = fopen(path, "wb");
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    fwrite(rgb, 1, (size_t)w * h * 3, f);
    fclose(f);
}

// the DDR3 model's data (sim/tb_top.sv): the image at byte 0x32000000, as Main_MiSTer's fast load leaves it; a beat is 8 bytes, the
// first in its low byte
static std::vector<uint8_t> g_img;
long long tb_ddr_beat(int beat) {
    long long off = (long long)(unsigned)beat * 8 - 0x32000000LL;
    unsigned long long v = 0;
    for (int i = 7; i >= 0; i--) {
        long long a = off + i;
        v = (v << 8) | ((a >= 0 && a < (long long)g_img.size()) ? g_img[a] : 0);
    }
    return (long long)v;
}

// the loader's remap of the graphics ROMs (rtl/cp_mem.sv remap(), tools/crospang_image.py remap())
static const long SD_TILE = 0x080000, SD_SPR = 0x180000, SD_PCM = 0x280000, IMG_WORDS = 0x2A0000;
static long remap(long wa) {
    if (wa >= SD_TILE && wa < SD_SPR) {
        long r = wa - SD_TILE;
        return SD_TILE + (((r >> 5) & 0x3fff) << 6 | (r & 15) << 2 | ((r >> 4) & 1) << 1 | ((r >> 19) & 1));
    }
    if (wa >= SD_SPR && wa < SD_PCM) {
        long r = wa - SD_SPR;
        return SD_SPR + (((r >> 5) & 0x3fff) << 6 | (r & 15) << 2 | (((r >> 4) & 1) ^ 1) << 1 | ((r >> 19) & 1));
    }
    return wa;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: tb_top image.rom frames out-prefix [+state=..]\n"); return 2; }
    const char* rom = argv[1];
    int frames = atoi(argv[2]);
    std::string outp = argv[3];
    bool state_mode = false, load_rtl = false, load_fast = false, trace = false, wav = false, live = false, mameraster = false, cpustats = false;
    int every = 1, first = 1, audio_from = 0, foff = -99, ioff = 1;
    unsigned dsw = 0xFFFF;
    const char* inputs = nullptr;
    std::string state_pre;
    for (int i = 4; i < argc; i++) {
        if (!strncmp(argv[i], "+state=", 7)) { state_mode = true; state_pre = argv[i] + 7; }
        else if (!strcmp(argv[i], "+load=rtl")) load_rtl = true;
        else if (!strcmp(argv[i], "+load=fast")) load_fast = true;
        else if (!strcmp(argv[i], "+trace")) trace = true;
        else if (!strcmp(argv[i], "+wav")) wav = true;
        else if (!strcmp(argv[i], "+live")) live = true;
        else if (!strcmp(argv[i], "+mameraster")) mameraster = true;
        else if (!strcmp(argv[i], "+cpustats")) cpustats = true;
        else if (!strncmp(argv[i], "+every=", 7)) every = atoi(argv[i] + 7);
        else if (!strncmp(argv[i], "+first=", 7)) first = atoi(argv[i] + 7);
        else if (!strncmp(argv[i], "+foff=", 6)) foff = atoi(argv[i] + 6);
        else if (!strncmp(argv[i], "+ioff=", 6)) ioff = atoi(argv[i] + 6);
        else if (!strncmp(argv[i], "+inputs=", 8)) inputs = argv[i] + 8;
        else if (!strncmp(argv[i], "+dsw=", 5)) dsw = strtoul(argv[i] + 5, nullptr, 16);
        else if (!strncmp(argv[i], "+audio_from=", 12)) audio_from = atoi(argv[i] + 12);
    }
    if (foff == -99) foff = live ? -1 : -2;
    auto img = load_file(rom);
    if (img.size() < 0x550008) { fprintf(stderr, "%s: not a crospang_image.py image (%zu bytes)\n", rom, img.size()); return 2; }
    Vtb_top* t = new Vtb_top;
    svSetScope(svGetScopeFromName("TOP.tb_top"));

    // MAME's recorded port values, by frame
    std::vector<std::pair<int, std::pair<uint16_t, uint16_t>>> inlog;
    if (inputs) {
        FILE* f = fopen(inputs, "r");
        if (!f) { fprintf(stderr, "cannot open %s\n", inputs); return 2; }
        int fr; unsigned a, b;
        while (fscanf(f, "%d %x %x", &fr, &a, &b) == 3) inlog.push_back({fr, {(uint16_t)a, (uint16_t)b}});
        fclose(f);
    }
    size_t inpos = 0;
    uint16_t p12 = 0xFFFF, coin = 0xFFFF;

    t->p1p2_in = 0xFFFF; t->coin_in = 0xFFFF; t->dsw_in = dsw;
    t->dl_we = 0; t->dl_addr = 0; t->dl_data = 0;
    t->fl_go = 0; t->fl_len = 0;
    g_img = img;
    t->clk = 0;
    t->init = 1; t->rst = 1; t->cpu_hold = 1; t->vsnap = live ? 0 : 1;

    auto step = [&]() { t->clk = !t->clk; t->eval(); };
    auto run_cycles = [&](int n) { for (int i = 0; i < n; i++) { step(); step(); } };

    run_cycles(200);
    t->init = 0;
    while (!t->mem_ready) run_cycles(1);
    run_cycles(100);

    if (!load_rtl && !load_fast) {
        for (long wa = 0; wa < IMG_WORDS; wa++) tb_sdram_write((int)remap(wa), img[2 * wa] | (img[2 * wa + 1] << 8));
        for (int a = 0; a < 0x10000; a++) tb_zrom(a, img[0x540000 + a]);
        for (int i = 0; i < 8; i++) tb_cfg(i, img[0x550000 + i]);
        fprintf(stderr, "image preloaded (%zu bytes)\n", img.size());
    } else {
        size_t n = img.size();
        // the SDRAM and the Z80 ROM start out as anything but the image, so a byte the load misses shows
        for (long wa = 0; wa < IMG_WORDS; wa++) tb_sdram_write((int)remap(wa), 0xDEAD);
        for (int a = 0; a < 0x10000; a++) tb_zrom(a, (uint8_t)~img[0x540000 + a]);
        for (int i = 0; i < 8; i++) tb_cfg(i, 0xA5);
        long long clocks = 0;
        if (load_rtl) {
            for (size_t i = 0; i < n; ) {
                if (!t->dl_wait) { t->dl_we = 1; t->dl_addr = i; t->dl_data = img[i]; i++; }
                else t->dl_we = 0;
                run_cycles(1);
                t->dl_we = 0;
                run_cycles(2);
            }
        } else {
            t->fl_len = n; t->fl_go = 1; run_cycles(1); t->fl_go = 0;
            while (!t->fl_done && clocks < 400000000LL) { run_cycles(1); clocks++; }
            if (!t->fl_done) { fprintf(stderr, "fast load: no fl_done after %lld clocks\n", clocks); return 1; }
        }
        while (t->dl_busy) { run_cycles(1); clocks++; }
        run_cycles(100);
        long bad = 0, zbad = 0, cbad = 0;
        for (long wa = 0; wa < IMG_WORDS; wa++) {
            uint16_t w = img[2 * wa] | (img[2 * wa + 1] << 8);
            if ((uint16_t)tb_sdram_read((int)remap(wa)) != w) { if (bad < 10) fprintf(stderr, "mismatch at word %lx\n", wa); bad++; }
        }
        for (int a = 0; a < 0x10000; a++) if ((uint8_t)tb_zrom_read(a) != img[0x540000 + a]) zbad++;
        for (int i = 0; i < 8; i++) if ((uint8_t)tb_cfg_read(i) != img[0x550000 + i]) cbad++;
        fprintf(stderr, "image loaded through the RTL loader%s: %ld of %ld SDRAM words differ, %ld of 65536 Z80 ROM bytes differ, "
                "%ld of 8 configuration bytes differ\n", load_fast ? " by the fast load" : "", bad, IMG_WORDS, zbad, cbad);
        if (load_fast) fprintf(stderr, "fast load: %lld clocks from fl_go to the last word in the SDRAM (%.3f s at 96 MHz)\n",
                               clocks, clocks / 96e6);
    }

    int state_frame = 0;
    if (state_mode) {
        // "<frame> <r0..r7 hex> <bank0..3> <bank select>"
        std::string rp = state_pre + ".regs";
        FILE* rf = fopen(rp.c_str(), "r");
        if (!rf) { fprintf(stderr, "cannot open %s\n", rp.c_str()); return 2; }
        unsigned r[8]; int b[4], sel;
        if (fscanf(rf, "%d %x %x %x %x %x %x %x %x %d %d %d %d %d", &state_frame, &r[0], &r[1], &r[2], &r[3], &r[4], &r[5], &r[6], &r[7],
                   &b[0], &b[1], &b[2], &b[3], &sel) != 14) { fprintf(stderr, "bad %s\n", rp.c_str()); return 2; }
        fclose(rf);
        tb_regs(r[1], r[2], r[3], r[4], r[5], r[6], b[0], b[1], b[2], b[3], sel);
        tb_flash(state_frame % 2 == 0);      // crospang_ref.py flash_hide(): MAME hides flashing sprites in the picture of an even dumped frame
        fprintf(stderr, "state of frame %d loaded\n", state_frame);
    }
    // +mameraster (with a VFLAGS=-DSIM_RASTER_60HZ build: 400 x 250 dots, exactly 60 Hz): put the raster where MAME's is at its reset,
    // so that every vertical blank comes at MAME's time: its 512-line raster starts vertical blank at line 240, 7.8125 ms = 750,000
    // machine clocks after the reset = 117 lines of 400 dots and 75 dots before line 240 (line 122, dot 325)
    if (mameraster) tb_raster(122, 325);
    t->rst = 0;
    t->cpu_hold = state_mode ? 1 : 0;

    std::vector<uint8_t> fb(320 * 240 * 3, 0);
    std::vector<int16_t> audio;
    int col = 0, row = 0, nframe = 0;
    bool prev_hblank = true, prev_vblank = true;
    long ovr = 0, irqs = 0;
    bool pirq = false, povr = false;
    long clocks = 0, busy_run = 0, busy_max = 0, snd_div = 0;
    long st_cycles = 0, st_romwait = 0, st_fill = 0;               // +cpustats: per frame
    long st_ymw = 0, st_okiw = 0, st_fmmax = 0;
    bool pas = true;
    FILE* tf = trace ? fopen((outp + ".trace").c_str(), "w") : nullptr;
    uint64_t guard = (uint64_t)(frames + 4) * 1700000ULL;

    auto set_inputs_for_frame = [&](int fr) {
        if (inputs) {
            while (inpos < inlog.size() && inlog[inpos].first <= fr) { p12 = inlog[inpos].second.first; coin = inlog[inpos].second.second; inpos++; }
        }
        t->p1p2_in = p12; t->coin_in = coin;
    };

    while (nframe < frames + 1 && (uint64_t)clocks < guard) {
        step();                                          // clk 1 -> rising edge evaluated
        if (t->clk) {
            clocks++;
            if (t->dbg_ovr && !povr) ovr++;
            povr = t->dbg_ovr;
            if (t->dbg_irq && !pirq) {
                irqs++;
                set_inputs_for_frame((int)(irqs - ioff));             // log frame f takes effect at vertical blank f + ioff
            }
            // the core flips the flash parity on the clock after the pulse: force it once the pulse is over
            if (!t->dbg_irq && pirq && state_mode) tb_flash(state_frame % 2 == 0);
            pirq = t->dbg_irq;
            if (cpustats) {
                auto* r = t->rootp;
                bool as = r->tb_top__DOT__u_core__DOT__u_main__DOT__ASn;
                if (!as && pas) st_cycles++;                                        // a bus cycle starts
                pas = as;
                if (r->tb_top__DOT__u_core__DOT__u_main__DOT__rom_req) st_romwait++;  // clocks a ROM read waits for the cache
                if (r->tb_top__DOT__u_core__DOT__u_cache__DOT__fill_req) st_fill++;   // clocks of line fills
                if (r->tb_top__DOT__u_core__DOT__u_sound__DOT__ym_wr) st_ymw++;
                if (r->tb_top__DOT__u_core__DOT__u_sound__DOT__oki_wr) st_okiw++;
                long a = labs((long)(int16_t)t->snd_fm);
                if (a > st_fmmax) st_fmmax = a;
            }
            busy_run = t->dbg_render_busy ? busy_run + 1 : 0;
            if (busy_run > busy_max) busy_max = busy_run;
            if (tf && t->trc_stb) fprintf(tf, "%c %06x %04x %d%d\n", t->trc_rw ? 'R' : 'W', (uint32_t)t->dbg_addr << 1, t->trc_data, (t->trc_be >> 1) & 1, t->trc_be & 1);
            if (t->dbg_halted) { fprintf(stderr, "CPU HALTED at frame %d\n", nframe); break; }
            if (wav && nframe >= audio_from && ++snd_div == 2000) {          // 96 MHz / 2000 = 48 kHz
                snd_div = 0;
                audio.push_back((int16_t)t->snd_fm);
                int s = t->snd_pcm & 0x3fff;
                if (s & 0x2000) s -= 0x4000;
                s *= 16;
                if (s > 32767) s = 32767; if (s < -32768) s = -32768;
                audio.push_back((int16_t)s);
            }
            if (t->ce_pix) {
                bool hb = t->hblank, vb = t->vblank;
                if (!hb && !vb) {
                    if (col < 320 && row < 240) {
                        uint32_t c = t->rgb;
                        fb[(row * 320 + col) * 3 + 0] = (c >> 16) & 255;
                        fb[(row * 320 + col) * 3 + 1] = (c >> 8) & 255;
                        fb[(row * 320 + col) * 3 + 2] = c & 255;
                    }
                    col++;
                }
                if (hb && !prev_hblank && !vb) { row++; col = 0; }
                if (vb && !prev_vblank) {
                    const long mf = irqs + foff;                                   // MAME's frame number of the picture that just ended
                    if (mf >= first && ((mf - first) % every) == 0) {
                        char p[512]; snprintf(p, sizeof p, "%s.f%05ld.ppm", outp.c_str(), mf);
                        write_ppm(p, fb.data(), 320, 240);
                    }
                    if (state_mode || nframe % 50 == 0 || nframe < 4)
                        fprintf(stderr, "frame %d (MAME %ld): rows %d, overruns %ld, longest render %ld clocks, Z80 at %04x\n",
                                nframe, mf, row, ovr, busy_max, t->dbg_zpc);
                    if (cpustats) {
                        fprintf(stderr, "cpustats %ld: bus cycles %ld, ROM wait %ld clocks, line fills %ld clocks; YM3812 writes %ld, OKI writes %ld, |fm| max %ld\n",
                                mf, st_cycles, st_romwait, st_fill, st_ymw, st_okiw, st_fmmax);
                        st_cycles = st_romwait = st_fill = st_ymw = st_okiw = st_fmmax = 0;
                    }
                    busy_max = 0;
                    nframe++;
                    row = 0; col = 0;
                }
                if (vb) { row = 0; col = 0; }
                prev_hblank = hb; prev_vblank = vb;
            }
        }
    }
    if (wav && !audio.empty()) {
        FILE* f = fopen((outp + ".wav").c_str(), "wb");
        uint32_t n = audio.size() * 2, rate = 48000, br = rate * 4;
        uint16_t two = 2, bits = 16, ba = 4, fmt = 1; uint32_t sixteen = 16, riff = 36 + n;
        fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&sixteen, 4, 1, f);
        fwrite(&fmt, 2, 1, f); fwrite(&two, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&br, 4, 1, f); fwrite(&ba, 2, 1, f); fwrite(&bits, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f); fwrite(audio.data(), 2, audio.size(), f);
        fclose(f);
        fprintf(stderr, "audio: %zu stereo samples\n", audio.size() / 2);
    }
    if (tf) fclose(tf);
    fprintf(stderr, "done: %d frames, %ld clocks, overruns %ld\n", nframe, clocks, ovr);
    delete t;
    return 0;
}
