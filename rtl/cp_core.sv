// The whole machine, without its memory (SDRAM) and the platform: the 68000 board, the sound board, the video renderer and the raster.
// One clock: clk 96 MHz (68000 7.159 / 14.318 MHz, Z80 and YM3812 3.579545 MHz, OKI 894.886 kHz, dots 6 MHz).
`default_nettype none
module cp_core (
    input  logic        clk,
    input  logic        rst,                  // the machine (CPUs, sound, renderer)
    input  logic        cpu_hold,             // simulation: keep both CPUs in reset (frozen-state benches)
    input  logic        vsnap,                // the picture shows the video RAMs as they were at the start of vertical blank (MAME)

    // per-game configuration (cp_mem.sv's configuration bytes)
    input  logic [1:0]  cfg_map,
    input  logic [1:0]  cfg_ram,
    input  logic        cfg_fast,
    input  logic        cfg_tbig,
    input  logic        cfg_sbig,

    input  logic        cache_inval,          // a ROM load starts

    // memory clients (rtl/cp_mem.sv)
    output logic        p_req,  output logic [19:4] p_addr,
    input  logic        p_wr,   input logic [2:0] p_idx,  input logic [15:0] p_data,  input logic p_done,
    output logic        t_req,  output logic [24:1] t_addr,
    input  logic        t_wr,   input logic [1:0] t_idx,  input logic [15:0] t_data,  input logic t_done,
    output logic        s_req,  output logic [24:1] s_addr,
    input  logic        s_wr,   input logic [1:0] s_idx,  input logic [15:0] s_data,  input logic s_done,
    output logic        pcm_req, output logic [17:0] pcm_addr,
    input  logic        pcm_ack, input logic [7:0] pcm_q,
    input  logic        zr_we,  input logic [15:0] zr_addr, input logic [7:0] zr_data,

    // controls (active low, the board's bit order)
    input  logic [15:0] p1p2_in, coin_in, dsw_in,

    // picture and sound
    output logic        ce_pix,
    output logic        hblank, vblank, hsync, vsync,
    output logic [23:0] rgb,
    output logic signed [15:0] snd_fm,
    output logic signed [13:0] snd_pcm,

    // debug
    output logic        dbg_ovr,              // a line was not finished in time
    output logic        dbg_irq,
    output logic        dbg_halted,
    output logic        dbg_render_busy,
    output logic [23:1] dbg_addr,
    output logic [15:0] dbg_zpc,
    output logic        trc_stb, output logic trc_rw, output logic [15:0] trc_data, output logic [1:0] trc_be
);
    wire mreset = rst | cpu_hold;

    logic cen_phi1, cen_phi2, cen_z80, cen_oki;
    cp_cen u_cen (.clk(clk), .fast(cfg_fast), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80), .cen_oki(cen_oki));

    // ---------------------------------------------------------------- raster
    logic        line_start, line_bank, vbl_pulse;
    logic  [7:0] line_no;
    logic        lb_we;
    logic  [9:0] lb_addr, lb_data;
    logic  [9:0] pal_addr;
    logic [15:0] pal_data;
    cp_video u_video (
        .clk(clk),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .rgb(rgb),
        .line_start(line_start), .line_no(line_no), .line_bank(line_bank), .vbl_pulse(vbl_pulse),
        .lb_we(lb_we), .lb_addr(lb_addr), .lb_data(lb_data),
        .pal_addr(pal_addr), .pal_data(pal_data)
    );

    // ---------------------------------------------------------------- the 68000 board
    logic        rom_req, rom_ack;
    logic [19:1] rom_addr;
    logic [15:0] rom_data;
    logic  [9:0] fg_addr, bg_addr;
    logic [15:0] fg_data, bg_data;
    logic  [7:0] sr_addr;
    logic [63:0] sr_data;
    logic [15:0] fg_sx, fg_sy, bg_sx, bg_sy;
    logic  [7:0] bank0, bank1, bank2, bank3;
    logic  [7:0] snd_latch;
    logic        snd_latch_wr;

    cp_main u_main (
        .clk(clk), .reset(mreset), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .cfg_map(cfg_map), .cfg_ram(cfg_ram),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
        .p1p2_in(p1p2_in), .coin_in(coin_in), .dsw_in(dsw_in),
        .vblank_irq(vbl_pulse), .vsnap(vsnap),
        .fg_addr(fg_addr), .bg_addr(bg_addr), .fg_data(fg_data), .bg_data(bg_data),
        .sr_addr(sr_addr), .sr_data(sr_data),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .fg_sx(fg_sx), .fg_sy(fg_sy), .bg_sx(bg_sx), .bg_sy(bg_sy),
        .bank0(bank0), .bank1(bank1), .bank2(bank2), .bank3(bank3),
        .snd_latch(snd_latch), .snd_latch_wr(snd_latch_wr),
        .trc_stb(trc_stb), .trc_addr(dbg_addr), .trc_rw(trc_rw), .trc_data(trc_data), .trc_be(trc_be),
        .cpu_halted(dbg_halted)
    );
    assign dbg_irq = vbl_pulse;

    cp_cache u_cache (
        .clk(clk), .inval(cache_inval), .busy(),
        .req(rom_req), .addr(rom_addr), .ack(rom_ack), .data(rom_data),
        .fill_req(p_req), .fill_addr(p_addr), .fill_wr(p_wr), .fill_idx(p_idx), .fill_data(p_data), .fill_done(p_done)
    );

    // ---------------------------------------------------------------- the sound board
    cp_sound u_sound (
        .clk(clk), .rst(mreset), .cen_z80(cen_z80), .cen_oki(cen_oki),
        .latch(snd_latch),
        .zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .fm(snd_fm), .pcm(snd_pcm), .dbg_pc(dbg_zpc), .dbg_irq()
    );

    // ---------------------------------------------------------------- the line renderer
    // decospr hides a flashing sprite when the frame number is odd: the parity flips at every vertical blank (its phase against the
    // board's cannot be known; the frozen-state bench sets it to MAME's)
    logic flash_hide = 1'b0;
    always_ff @(posedge clk) if (vbl_pulse) flash_hide <= ~flash_hide;

    cp_render u_render (
        .clk(clk), .rst(rst),
        .start(line_start), .line(line_no), .bank(line_bank), .busy(dbg_render_busy), .overrun(dbg_ovr),
        .fg_sx(fg_sx), .fg_sy(fg_sy), .bg_sx(bg_sx), .bg_sy(bg_sy),
        .bank0(bank0), .bank1(bank1), .bank2(bank2), .bank3(bank3),
        .tmask_big(cfg_tbig), .smask_big(cfg_sbig), .flash_hide(flash_hide),
        .fg_addr(fg_addr), .bg_addr(bg_addr), .fg_data(fg_data), .bg_data(bg_data),
        .sr_addr(sr_addr), .sr_data(sr_data),
        .t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
        .s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
        .lb_we(lb_we), .lb_addr(lb_addr), .lb_data(lb_data)
    );

    wire unused = ^{snd_latch_wr};
endmodule
`default_nettype wire
