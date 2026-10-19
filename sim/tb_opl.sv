// YM3812 bench: jtopl2 as cp_sound.sv connects it (the YM3812 on cp_cen's 3.579545 MHz enable, a one-clock write strobe), driven by the
// C++ side with MAME's register writes (tools/lua/ymlog.lua / fmonly.lua) at their machine times; sim/tb_opl.cpp.
`default_nettype none
module tb_opl (
    input  logic        clk,
    input  logic        rst,
    input  logic        wr,                 // one-clock write strobe
    input  logic        a0,                 // 0 address register, 1 data
    input  logic [7:0]  din,
    output logic signed [15:0] snd
);
    logic cen_phi1, cen_phi2, cen_z80, cen_oki;
    cp_cen u_cen (.clk(clk), .fast(1'b0), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80), .cen_oki(cen_oki));
    jtopl2 u_opl (
        .rst(rst), .clk(clk), .cen(cen_z80),
        .din(din), .addr(a0), .cs_n(~wr), .wr_n(~wr),
        .dout(), .irq_n(), .snd(snd), .sample()
    );
endmodule
`default_nettype wire
