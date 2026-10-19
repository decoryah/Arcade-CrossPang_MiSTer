// YM3812 bench driver (sim/tb_opl.sv):
//   Vtb_opl <ymlog.txt> <seconds> <out.wav>
// Replays MAME's YM3812 register writes ("time reg data" lines, the time in seconds of machine time; tools/lua/ymlog.lua) into jtopl2
// on the 96 MHz clock -- the address write at the logged time, the data write 32 clocks later -- and writes its output at 48 kHz
// (mono, 16 bit) for comparison with MAME's YM3812-only recording (tools/lua/fmonly.lua, tools/cmp_audio.py).
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include "Vtb_opl.h"
#include "verilated.h"

struct W { uint64_t clk; int reg, data; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: Vtb_opl ymlog.txt seconds out.wav\n"); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    std::vector<W> log;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        for (char* p = line; *p; p++) if (*p == ',') *p = '.';       // MAME's Lua writes the locale's decimal separator
        double t; unsigned r, d;
        if (sscanf(line, "%lf %x %x", &t, &r, &d) == 3) log.push_back({(uint64_t)(t * 96e6 + 0.5), (int)r, (int)d});
    }
    fclose(f);
    double secs = atof(argv[2]);
    uint64_t end = (uint64_t)(secs * 96e6);
    fprintf(stderr, "%zu writes, %.1f s\n", log.size(), secs);

    Vtb_opl* t = new Vtb_opl;
    t->clk = 0; t->rst = 1; t->wr = 0; t->a0 = 0; t->din = 0;
    auto tick = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); };
    for (int i = 0; i < 2000; i++) tick();
    t->rst = 0;

    std::vector<int16_t> out;
    size_t pos = 0;
    uint64_t next_free = 0;                      // writes are kept at least 64 clocks apart
    int phase = 0;                               // 0 idle, 1 address written, data pending
    uint64_t data_at = 0;
    int cur_data = 0;
    for (uint64_t c = 0; c < end; c++) {
        t->wr = 0;
        if (phase == 1 && c >= data_at) {
            t->wr = 1; t->a0 = 1; t->din = cur_data; phase = 0; next_free = c + 64;
        } else if (phase == 0 && pos < log.size() && c >= log[pos].clk && c >= next_free) {
            t->wr = 1; t->a0 = 0; t->din = log[pos].reg; cur_data = log[pos].data; data_at = c + 32; phase = 1; pos++;
        }
        tick();
        if (c % 2000 == 0) out.push_back((int16_t)t->snd);
    }
    FILE* o = fopen(argv[3], "wb");
    uint32_t n = out.size() * 2, rate = 48000, br = rate * 2, riff = 36 + n, sixteen = 16;
    uint16_t one = 1, bits = 16, ba = 2, fmt = 1;
    fwrite("RIFF", 1, 4, o); fwrite(&riff, 4, 1, o); fwrite("WAVEfmt ", 1, 8, o); fwrite(&sixteen, 4, 1, o);
    fwrite(&fmt, 2, 1, o); fwrite(&one, 2, 1, o); fwrite(&rate, 4, 1, o); fwrite(&br, 4, 1, o); fwrite(&ba, 2, 1, o); fwrite(&bits, 2, 1, o);
    fwrite("data", 1, 4, o); fwrite(&n, 4, 1, o); fwrite(out.data(), 2, out.size(), o);
    fclose(o);
    fprintf(stderr, "wrote %zu samples, %zu of %zu writes replayed\n", out.size(), pos, log.size());
    delete t;
    return 0;
}
