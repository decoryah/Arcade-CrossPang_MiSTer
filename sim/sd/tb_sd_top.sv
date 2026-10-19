// The raster of this core (rtl/cp_video.sv, as the machine drives it: a dot every 16 clocks) through CRT Adjust (rtl/cp_crtadj.sv)
// into the framework's arcade_video, with Scandoubler Fx / forced_scandoubler selectable, and nothing else: what the scandoubled
// output (31 kHz) does.  CRT=1 is the OSD's CRT Adjust On; GATE=1 the core's wiring (Crospang.sv: CRT Adjust is off while the
// scandoubler is in use), GATE=0 the wiring before it.  (After the owner's Monster Maulers core, sim/emu/tb_sd_top.sv.)
`default_nettype none
module tb_sd_top #(parameter bit CRT = 0, parameter bit GATE = 1) (
    input  wire        clk,
    input  wire        reset,
    input  wire  [2:0] fx,
    input  wire        fsd,
    output wire        CE_PIXEL,
    output wire  [7:0] VGA_R, VGA_G, VGA_B,
    output wire        VGA_HS, VGA_VS, VGA_DE
);
    wire        ce_pix, hblank, vblank, hsync, vsync;
    cp_video v (
        .clk(clk), .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .rgb(),
        .line_start(), .line_no(), .line_bank(), .vbl_pulse(),
        .lb_we(1'b0), .lb_addr(10'd0), .lb_data(10'd0),
        .pal_addr(), .pal_data(16'd0)
    );

    // a picture that shows where it is: red = the dot, green = the line (both counted here), blue fixed
    reg [7:0] line = 8'd0, dot = 8'd0;
    reg       hb_d = 1'b1;
    always @(posedge clk) if (ce_pix) begin
        hb_d <= hblank;
        dot  <= hblank ? 8'd0 : dot + 8'd1;
        if (vblank) line <= 8'd0;
        else if (hblank && !hb_d) line <= line + 8'd1;
    end
    wire [23:0] rgb = (!hblank && !vblank) ? {dot, line, 8'h80} : 24'd0;

    // Crospang.sv: crt_sd = Scandoubler Fx or forced_scandoubler; crt_on = OSD CRT Adjust & ~crt_sd
    wire        crt_sd = (|fx) | fsd;
    wire        crt_on = CRT & (GATE ? ~crt_sd : 1'b1);
    wire        ca_ce, ca_hb, ca_vb, ca_hs, ca_vs;
    wire [23:0] ca_rgb;
    cp_crtadj u_crt (
        .clk(clk), .i_on(crt_on), .i_hsize_f(5'd0), .i_hpos_f(7'd0), .i_vshift_f(5'd0), .i_pdot(5'd16),
        .i_ce(ce_pix), .i_hblank(hblank), .i_vblank(vblank), .i_hs(hsync), .i_vs(vsync), .i_rgb(rgb),
        .o_ce(ca_ce), .o_hblank(ca_hb), .o_vblank(ca_vb), .o_hs(ca_hs), .o_vs(ca_vs), .o_rgb(ca_rgb), .o_de_osd()
    );

    wire [21:0] gamma_bus;
    assign gamma_bus[20:0] = {clk, 20'd0};
    wire  [1:0] sl;
    arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) av (
        .clk_video(clk), .ce_pix(ca_ce), .RGB_in(ca_rgb),
        .HBlank(ca_hb), .VBlank(ca_vb), .HSync(ca_hs), .VSync(ca_vs),
        .CLK_VIDEO(), .CE_PIXEL(CE_PIXEL), .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .VGA_SL(sl),
        .fx(fx), .forced_scandoubler(fsd), .gamma_bus(gamma_bus)
    );
endmodule
