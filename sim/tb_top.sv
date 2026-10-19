// Whole-machine bench: cp_core behind cp_mem and a behavioural SDRAM chip, one clock (96 MHz).
// The C++ side preloads the chip (DPI) with the ROM image (through the loader's remap), or pushes it through the loader (dl_*), and can
// preload the RAMs from a MAME state dump (tools/lua/dump_state.lua: <prefix>.{fg,bg,pal1,spr,regs}) with both CPUs held in reset.
`default_nettype none
module tb_top (
    input  logic        clk,
    input  logic        rst,                // the machine (CPUs, sound, renderer)
    input  logic        cpu_hold,           // keep the CPUs in reset
    input  logic        vsnap,              // video RAM snapshot at the start of vertical blank (MAME) / live
    input  logic        init,               // the SDRAM controller

    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic [7:0]  dl_data,
    output logic        dl_wait,
    output logic        dl_busy,
    output logic        mem_ready,

    input  logic        fl_go,              // +load=fast: cp_fastload reads the image from the DDR3 model below into the loader
    input  logic [24:0] fl_len,
    output logic        fl_done,

    input  logic [15:0] p1p2_in, coin_in, dsw_in,

    output logic        ce_pix,
    output logic        hblank, vblank, hsync, vsync,
    output logic [23:0] rgb,
    output logic signed [15:0] snd_fm,
    output logic signed [13:0] snd_pcm,

    output logic        dbg_ovr, dbg_irq, dbg_halted, dbg_render_busy,
    output logic [23:1] dbg_addr,
    output logic [15:0] dbg_zpc,
    output logic        trc_stb, trc_rw,
    output logic [15:0] trc_data,
    output logic [1:0]  trc_be
);
    wire  [15:0] dram_dq;
    wire  [12:0] dram_a;
    wire  [1:0]  dram_ba;
    wire         dram_dqml, dram_dqmh, dram_ncs, dram_nras, dram_ncas, dram_nwe, dram_cke, dram_clk;

    logic        p_req, t_req, s_req, pcm_req;
    logic [19:4] p_addr;
    logic [24:1] t_addr, s_addr;
    logic [17:0] pcm_addr;
    logic        p_wr, t_wr, s_wr, p_done, t_done, s_done, pcm_ack;
    logic [2:0]  p_idx;
    logic [1:0]  t_idx, s_idx;
    logic [15:0] p_data, t_data, s_data;
    logic [7:0]  pcm_q;
    logic [63:0] cfg;
    logic        zr_we;
    logic [15:0] zr_addr;
    logic [7:0]  zr_data;

    // the fast load (Crospang.sv): its bytes go into the loader's input as the HPS's do
    logic        fl_we;
    logic [24:0] fl_addr;
    logic  [7:0] fl_data;
    logic        ddr_busy, ddr_rd, ddr_dready;
    logic  [7:0] ddr_burst;
    logic [28:0] ddr_addr;
    logic [63:0] ddr_dout;
    cp_fastload u_fl (
        .clk(clk), .rst(init), .go(fl_go), .abort(1'b0), .len(fl_len), .done(fl_done), .busy(),
        .dl_we(fl_we), .dl_addr(fl_addr), .dl_data(fl_data), .dl_wait(dl_wait),
        .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr), .DDRAM_DOUT(ddr_dout),
        .DDRAM_DOUT_READY(ddr_dready), .DDRAM_RD(ddr_rd)
    );

    // a DDR3 model (Avalon-MM slave): busy at random and while a burst is going out; the beats of a burst after 20 clocks, with gaps;
    // the data from the image (tb_main.cpp tb_ddr_beat: the image at byte 0x32000000)
    import "DPI-C" function longint tb_ddr_beat(input int beat);
    logic [28:0] dm_addr;
    logic  [7:0] dm_left = 8'd0;
    logic  [5:0] dm_lat;
    logic [15:0] lfsr = 16'hACE1;
    logic        rnd_busy = 1'b0;
    assign ddr_busy = rnd_busy || (dm_left != 8'd0);
    always_ff @(posedge clk) begin
        lfsr       <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        rnd_busy   <= lfsr[3] & lfsr[7];
        ddr_dready <= 1'b0;
        if (ddr_rd && !ddr_busy) begin dm_addr <= ddr_addr; dm_left <= ddr_burst; dm_lat <= 6'd20; end
        else if (dm_left != 8'd0) begin
            if (dm_lat != 6'd0) dm_lat <= dm_lat - 6'd1;
            else if (!lfsr[0] || lfsr[5]) begin
                ddr_dready <= 1'b1; ddr_dout <= tb_ddr_beat(int'(dm_addr)); dm_addr <= dm_addr + 29'd1; dm_left <= dm_left - 8'd1;
            end
        end
    end

    cp_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(init), .rd_late(1'b0), .ready(mem_ready),
        .dl_we(dl_we | fl_we), .dl_addr(fl_we ? fl_addr : dl_addr), .dl_data(fl_we ? fl_data : dl_data), .dl_wait(dl_wait),
        .dl_busy(dl_busy), .cfg(cfg),
        .zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
        .p_req(p_req), .p_addr(p_addr), .p_wr(p_wr), .p_idx(p_idx), .p_data(p_data), .p_done(p_done),
        .t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
        .s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqml), .SDRAM_DQMH(dram_dqmh), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(dram_ncs), .SDRAM_nWE(dram_nwe), .SDRAM_nRAS(dram_nras), .SDRAM_nCAS(dram_ncas),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk)
    );

    sdram_model #(.PHASE_LAG(0), .AW(23)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba), .dqml(dram_dqml), .dqmh(dram_dqmh),
        .cs_n(dram_ncs), .ras_n(dram_nras), .cas_n(dram_ncas), .we_n(dram_nwe), .cke(dram_cke)
    );

    cp_core u_core (
        .clk(clk), .rst(rst), .cpu_hold(cpu_hold), .vsnap(vsnap),
        .cfg_map(cfg[1:0]), .cfg_ram(cfg[9:8]), .cfg_fast(cfg[16]), .cfg_tbig(cfg[24]), .cfg_sbig(cfg[32]),
        .cache_inval(init | dl_busy),
        .p_req(p_req), .p_addr(p_addr), .p_wr(p_wr), .p_idx(p_idx), .p_data(p_data), .p_done(p_done),
        .t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
        .s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
        .p1p2_in(p1p2_in), .coin_in(coin_in), .dsw_in(dsw_in),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .rgb(rgb),
        .snd_fm(snd_fm), .snd_pcm(snd_pcm),
        .dbg_ovr(dbg_ovr), .dbg_irq(dbg_irq), .dbg_halted(dbg_halted), .dbg_render_busy(dbg_render_busy),
        .dbg_addr(dbg_addr), .dbg_zpc(dbg_zpc),
        .trc_stb(trc_stb), .trc_rw(trc_rw), .trc_data(trc_data), .trc_be(trc_be)
    );

    // ---------------------------------------------------------------- backdoors for the C++ side
    export "DPI-C" function tb_sdram_write;
    function void tb_sdram_write(input int idx, input int w);
        chip.mem[idx[22:0]] = w[15:0];
    endfunction
    export "DPI-C" function tb_sdram_read;
    function int tb_sdram_read(input int idx);
        return {16'd0, chip.mem[idx[22:0]]};
    endfunction
    // the configuration bytes and the Z80 program the loader would have captured (a preloaded image does not go through it)
    export "DPI-C" function tb_cfg;
    function void tb_cfg(input int i, input int v);
        u_mem.cfg_r[i[2:0]] = v[7:0];
    endfunction
    export "DPI-C" function tb_cfg_read;
    function int tb_cfg_read(input int i);
        return {24'd0, u_mem.cfg_r[i[2:0]]};
    endfunction
    export "DPI-C" function tb_zrom;
    function void tb_zrom(input int a, input int v);
        u_core.u_sound.u_rom.mem[a[15:0]] = v[7:0];
    endfunction
    export "DPI-C" function tb_zrom_read;
    function int tb_zrom_read(input int a);
        return {24'd0, u_core.u_sound.u_rom.mem[a[15:0]]};
    endfunction

    // ---------------------------------------------------------------- RAMs from a MAME state dump
    string pre;
    logic [15:0] t1k [0:1023];
    initial begin
        if ($value$plusargs("state=%s", pre)) begin
            $readmemh({pre, ".fg"}, t1k);
            for (int i = 0; i < 1024; i++) begin u_core.u_main.u_fg.hi[i] = t1k[i][15:8]; u_core.u_main.u_fg.lo[i] = t1k[i][7:0]; end
            $readmemh({pre, ".bg"}, t1k);
            for (int i = 0; i < 1024; i++) begin u_core.u_main.u_bg.hi[i] = t1k[i][15:8]; u_core.u_main.u_bg.lo[i] = t1k[i][7:0]; end
            $readmemh({pre, ".spr"}, t1k);
            for (int w = 0; w < 1024; w++) begin
                case (w & 3)
                    0: begin u_core.u_main.u_s0.hi[w >> 2] = t1k[w][15:8]; u_core.u_main.u_s0.lo[w >> 2] = t1k[w][7:0]; end
                    1: begin u_core.u_main.u_s1.hi[w >> 2] = t1k[w][15:8]; u_core.u_main.u_s1.lo[w >> 2] = t1k[w][7:0]; end
                    2: begin u_core.u_main.u_s2.hi[w >> 2] = t1k[w][15:8]; u_core.u_main.u_s2.lo[w >> 2] = t1k[w][7:0]; end
                    3: begin u_core.u_main.u_s3.hi[w >> 2] = t1k[w][15:8]; u_core.u_main.u_s3.lo[w >> 2] = t1k[w][7:0]; end
                endcase
            end
            // the palette MAME converted the frame with (see tools/lua/dump_state.lua)
            for (int i = 0; i < 1024; i++) t1k[i] = 16'h0000;
            $readmemh({pre, ".pal1"}, t1k, 0, 767);
            for (int i = 0; i < 1024; i++) begin u_core.u_main.u_pal.hi[i] = t1k[i][15:8]; u_core.u_main.u_pal.lo[i] = t1k[i][7:0]; end
        end
    end
    // the registers are forced by the C++ side after elaboration (an initial block here would race with the module's own power-up values)
    export "DPI-C" function tb_regs;
    function void tb_regs(input int r1, input int r2, input int r3, input int r4, input int r5, input int r6,
                          input int b0, input int b1, input int b2, input int b3, input int sel);
        u_core.u_main.raw[1] = r1[15:0]; u_core.u_main.raw[2] = r2[15:0]; u_core.u_main.raw[3] = r3[15:0];
        u_core.u_main.raw[4] = r4[15:0]; u_core.u_main.raw[5] = r5[15:0]; u_core.u_main.raw[6] = r6[15:0];
        u_core.u_main.wv = 8'h7e;
        u_core.u_main.tbank[0] = b0[7:0]; u_core.u_main.tbank[1] = b1[7:0];
        u_core.u_main.tbank[2] = b2[7:0]; u_core.u_main.tbank[3] = b3[7:0];
        u_core.u_main.tb_sel = sel[1:0];
    endfunction
    // the raster's position at the release of the reset (+mameraster: MAME's first vertical blank 7.8125 ms after the reset)
    export "DPI-C" function tb_raster;
    function void tb_raster(input int v, input int h);
        u_core.u_video.vc = v[8:0];
        u_core.u_video.hc = h[8:0];
        u_core.u_video.ph = 4'd0;
    endfunction
    export "DPI-C" function tb_flash;
    function void tb_flash(input int hide);
        u_core.flash_hide = hide[0];
    endfunction
endmodule
