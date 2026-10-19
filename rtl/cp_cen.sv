// Clock enables from the 96 MHz machine clock, all derived from the board's one crystal (14.318181 MHz, MAME's XTAL(14'318'181)):
//
//   68000   crystal / 2 = 7.159 MHz  (Pitapat Puzzle: the whole crystal, 14.318 MHz: `fast`)    cen_phi1 / cen_phi2, alternating
//   Z80     crystal / 4 = 3.579545 MHz                                                           cen_z80   (also the YM3812's clock)
//   OKI     crystal / 16 = 894.886 kHz  (MAME's OKIM6295 clock; the driver notes it as unverified) cen_oki
//
// A phase accumulator makes a pulse stream at exactly 2 x the crystal (28.636362 MHz average, a pulse every 3 or 4 machine clocks);
// the other enables are exact divisions of it, so the sound CPU, the FM chip and the OKI keep their exact ratios to each other and to the
// 68000. The dot clock (6 MHz = 96 / 16) is generated in cp_video.
`default_nettype none
module cp_cen (
    input  logic clk,
    input  logic fast,                                      // 68000 at the whole crystal (Pitapat Puzzle)
    output logic cen_phi1, cen_phi2,
    output logic cen_z80,
    output logic cen_oki
);
    localparam [31:0] MCLK = 32'd96_000_000;
    localparam [31:0] STEP = 32'd28_636_362;                // 2 x 14.318181 MHz

    logic [31:0] acc  = 32'd0;
    logic        c28  = 1'b0;                               // 28.636 MHz pulse
    wire  [31:0] nxt  = acc + STEP;
    always_ff @(posedge clk) begin
        if (nxt >= MCLK) begin acc <= nxt - MCLK; c28 <= 1'b1; end
        else             begin acc <= nxt;        c28 <= 1'b0; end
    end

    logic       t14  = 1'b0;                                // toggles on every c28: a pulse on every second one is the 14.318 MHz
    logic [3:0] d14  = 4'd0;                                // counts the 14.318 MHz pulses
    logic       c14;
    assign c14 = c28 & t14;
    always_ff @(posedge clk) begin
        if (c28) t14 <= ~t14;
        if (c14) d14 <= d14 + 4'd1;
    end

    // the CPU's phase enables alternate; each phase runs at the CPU's clock (7.159 MHz, or 14.318 MHz when `fast`)
    wire  cpu_step = fast ? c28 : c14;
    logic ph = 1'b0;
    always_ff @(posedge clk) begin
        cen_phi1 <= 1'b0;
        cen_phi2 <= 1'b0;
        if (cpu_step) begin
            ph <= ~ph;
            if (ph) cen_phi2 <= 1'b1; else cen_phi1 <= 1'b1;
        end
        cen_z80 <= c14 && (d14[1:0] == 2'd3);
        cen_oki <= c14 && (d14 == 4'd15);
    end
endmodule
`default_nettype wire
