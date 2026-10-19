//============================================================================
//
//  F2 System "Cross Pang" hardware (1997-1998): Cross Pang, Heuk Sun Baek Sa, Bestri, Pitapat Puzzle -- MAME's f32/crospang.cpp --
//  for MiSTer.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/f32/crospang.cpp) and its sprite chip (src/mame/shared/decospr.cpp).
//  The 68000 is fx68k (Jorge Cwik), the Z80 is TV80 (Guy Hutchison), the YM3812 is jtopl2 and the OKI M6295 jt6295 (Jose Tejada);
//  the platform layer (SDRAM controller, loader, CRT adjust) follows the owner's other cores (ohmygod-mister, mcatadv-mister,
//  metro-mister).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

// Aspect ratio and Scale. The framework's video_freak (after arcade_video, below) turns the two into VIDEO_ARX/ARY: with Scale Normal
// they pass through as they are; the integer modes replace them with the exact size in pixels (bit 12 set) that the HDMI scaler should
// give the picture. The menu's order is the owner's (as in the Monster Maulers / Violent Storm / Gaiapolis cores); video_freak's SCALE
// input counts 0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+ (wider), 4 HV-Integer
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;   // V-Integer
	3'd2:    scale_sel = 3'd4;   // HV-Integer
	3'd3:    scale_sel = 3'd2;   // Narrower HV-Integer
	3'd4:    scale_sel = 3'd3;   // HV-Integer+
	default: scale_sel = 3'd0;   // Normal
endcase
// Full Screen is ARX = ARY = 0 ("fill"), which has no proportions for the integer rule to size the width from: it sizes the height
// from the width instead and asks for more rows than the screen has. With an integer Scale the screen's own proportions stand in for
// it, so the picture is a whole-number size in the screen's aspect
wire  [1:0] ar     = status[122:121];
wire        fs_int = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
wire [11:0] arx    = fs_int ? HDMI_WIDTH  : (!ar) ? 12'd4 : {10'd0, ar - 2'd1};
wire [11:0] ary    = fs_int ? HDMI_HEIGHT : (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"A.CROSPANG;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1,CRT Adjust;",
	"P1O[101],CRT Adjust,Off,On;",
	"H3P1O[100:96],H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3P1O[85:79],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3P1O[78:74],V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,-18 dB;",
	"O[10],Video RAM,At vblank (MAME),Live (less lag);",
	"O[20],SDRAM read capture,Normal,Late;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"jn,A,B,X,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the machine (enables for the 68000, the Z80, the YM3812, the OKI and the dots)
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(),
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         ioctl_wait;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({12'd0, ~status[101], 1'b0, 1'b0, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   DIP SWITCHES (from the MRA)   ///////////////////////

// ioctl index 254: byte 0 = SW1 (MAME's DSW port bits 7:0), byte 1 = SW2 (bits 15:8); a 1 is "off" (the switches are active low).
reg [7:0] sw[2];
initial begin sw[0] = 8'hFF; sw[1] = 8'hFF; end
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[26:1]) sw[ioctl_addr[0]] <= ioctl_dout;
end

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1/2 start, 5/6 coin (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];
			9'h01E: key_start2  <= ps2_key[9];
			9'h02E: key_coin1   <= ps2_key[9];
			9'h036: key_coin2   <= ps2_key[9];
			default: ;
		endcase
	end
end

// the MRA's configuration bytes (cp_mem.sv; tools/crospang_image.py): byte 5 bit 0 = the set has a third button
wire [63:0] cfg;
wire        b3_on = cfg[40];

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4 button 1, 5 button 2, 6 button 3, 7 start, 8 coin (the MRA's <buttons> list names
// them; "-" where a set has no button 3). Button 3 only reaches the sets that have one (Cross Pang, Pitapat Puzzle): the others'
// INPUT_PORTS have that bit as unknown, held off.
// No service button: every game reads the DIP switches once while it boots (tools/service.py), so the way into the test mode is the
// OSD's Service Mode switch and a reset, as in MAME.
wire j1_r = joystick_0[0], j1_l = joystick_0[1], j1_d = joystick_0[2], j1_u = joystick_0[3], j1_b1 = joystick_0[4], j1_b2 = joystick_0[5];
wire j2_r = joystick_1[0], j2_l = joystick_1[1], j2_d = joystick_1[2], j2_u = joystick_1[3], j2_b1 = joystick_1[4], j2_b2 = joystick_1[5];
wire j1_b3 = joystick_0[6] & b3_on, j2_b3 = joystick_1[6] & b3_on;
wire start1 = joystick_0[7] | key_start1, coin1 = joystick_0[8] | key_coin1;
wire start2 = joystick_1[7] | key_start2, coin2 = joystick_1[8] | key_coin2;

// the board's inputs, active low (MAME's INPUT_PORTS crospang and the others):
//   P1_P2: bit 0 up, 1 down, 2 left, 3 right, 4 button 1, 5 button 2, 6 button 3 (pitapat), 7 start 1; bits 8..15 the same for
//          player 2 (15 start 2)
//   COIN:  bit 8 coin 1, bit 9 coin 2
//   DSW:   SW1 / SW2 from the MRA
wire [15:0] p1p2_in = ~{start2, j2_b3, j2_b2, j2_b1, j2_r, j2_l, j2_d, j2_u, start1, j1_b3, j1_b2, j1_b1, j1_r, j1_l, j1_d, j1_u};
wire [15:0] coin_in = ~{6'd0, coin2, coin1, 8'd0};
wire [15:0] dsw_in  = {sw[1], sw[0]};

///////////////////////   MEMORY   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);

wire        mem_init = ~pll_locked | RESET;
wire        mem_ready;
wire        dl_busy;

// Fast load (rtl/cp_fastload.sv): with address= on the MRA's index-0 <rom>, Main_MiSTer puts the image into the DDR3 and sends a
// download without data that starts with ioctl_addr = the image's length (an ordinary one starts at 0; hps_io loads ioctl_addr
// before it raises ioctl_download). When it ends, the image is read back and pushed through the loader; the machine is held until
// the last word is in the SDRAM. An older Main_MiSTer ignores address= and sends the image the ordinary way.
reg         rom_dl_d = 1'b0;
reg         fast_dl = 1'b0;
reg  [24:0] fast_len;
wire        fl_done, fl_we;
wire [24:0] fl_addr;
wire  [7:0] fl_data;
always @(posedge clk_sys) begin
	rom_dl_d <= rom_dl;
	if (rom_dl && !rom_dl_d) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr[24:0]; end
	else if (fl_done) fast_dl <= 1'b0;
end
wire        fl_go = fast_dl && rom_dl_d && !rom_dl;              // the empty download has ended

// the loader's byte input: the HPS's bytes, or the fast load's
wire        dl_we   = (rom_dl && ioctl_wr) | fl_we;
wire [24:0] dl_addr = fl_we ? fl_addr : ioctl_addr[24:0];
wire  [7:0] dl_data = fl_we ? fl_data : ioctl_dout;
wire        dl_wait;
assign      ioctl_wait = dl_wait;

cp_fastload u_fastload
(
	.clk(clk_sys), .rst(mem_init), .go(fl_go), .abort(rom_dl), .len(fast_len), .done(fl_done), .busy(),
	.dl_we(fl_we), .dl_addr(fl_addr), .dl_data(fl_data), .dl_wait(dl_wait),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD)
);
assign DDRAM_CLK = clk_sys;
assign {DDRAM_DIN, DDRAM_BE, DDRAM_WE} = '0;

wire        p_req, t_req, s_req, pcm_req;
wire [19:4] p_addr;
wire [24:1] t_addr, s_addr;
wire [17:0] pcm_addr;
wire        p_wr, t_wr, s_wr, p_done, t_done, s_done, pcm_ack;
wire  [2:0] p_idx;
wire  [1:0] t_idx, s_idx;
wire [15:0] p_data, t_data, s_data;
wire  [7:0] pcm_q;
wire        zr_we;
wire [15:0] zr_addr;
wire  [7:0] zr_data;

cp_mem u_mem
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .rd_late(status[20]), .ready(mem_ready),
	.dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait), .dl_busy(dl_busy), .cfg(cfg),
	.zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
	.p_req(p_req), .p_addr(p_addr), .p_wr(p_wr), .p_idx(p_idx), .p_data(p_data), .p_done(p_done),
	.t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
	.s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw = RESET | status[0] | buttons[1];
// the machine is held while a ROM loads (a fast load too) and until the memory is up; registered, it fans out to the whole core
reg         mc_rst = 1'b1;
always @(posedge clk_sys) mc_rst <= reset_sw | rom_dl | fast_dl | dl_busy | ~mem_ready | ~pll_locked;

wire        ce_pix, hblank, vblank, hsync, vsync;
wire [23:0] rgb;
wire signed [15:0] snd_fm;
wire signed [13:0] snd_pcm;
wire        dbg_ovr, dbg_irq, dbg_halted, dbg_render_busy;

cp_core u_core
(
	.clk(clk_sys), .rst(mc_rst), .cpu_hold(1'b0), .vsnap(~status[10]),
	.cfg_map(cfg[1:0]), .cfg_ram(cfg[9:8]), .cfg_fast(cfg[16]), .cfg_tbig(cfg[24]), .cfg_sbig(cfg[32]),
	.cache_inval(rom_dl | fast_dl | mem_init),
	.p_req(p_req), .p_addr(p_addr), .p_wr(p_wr), .p_idx(p_idx), .p_data(p_data), .p_done(p_done),
	.t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
	.s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
	.p1p2_in(p1p2_in), .coin_in(coin_in), .dsw_in(dsw_in),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .rgb(rgb),
	.snd_fm(snd_fm), .snd_pcm(snd_pcm),
	.dbg_ovr(dbg_ovr), .dbg_irq(dbg_irq), .dbg_halted(dbg_halted), .dbg_render_busy(dbg_render_busy),
	.dbg_addr(), .dbg_zpc(), .trc_stb(), .trc_rw(), .trc_data(), .trc_be()
);

///////////////////////   AUDIO   ///////////////////////

// MAME mixes both chips into one speaker at route 1.0: the YM3812's 16-bit output plus the OKI's, which is 16 times jt6295's 14-bit
// sum of the voices (measured on the owner's ohmygod-mister core); clipped to 16 bits as MAME does.  "Normal" is that level, the others
// 6 / 12 / 18 dB lower.
reg signed [15:0] aud;
wire signed [19:0] aud_sum = {{4{snd_fm[15]}}, snd_fm} + {{2{snd_pcm[13]}}, snd_pcm, 4'b0000};
wire signed [19:0] aud_sh  = aud_sum >>> {1'b0, status[9:8]};
always @(posedge clk_sys) begin
	if (aud_sh > 20'sd32767)       aud <= 16'sd32767;
	else if (aud_sh < -20'sd32768) aud <= -16'sd32768;
	else                           aud <= aud_sh[15:0];
end
assign AUDIO_L = aud;
assign AUDIO_R = aud;

///////////////////////   VIDEO   ///////////////////////

// CRT Adjust (OSD page of the same name): H-Size, H-Position and V-Shift of the picture, through rmonic79's line buffer
// (rtl/cp_crtadj.sv). It is off while the scandoubler is in use (Scandoubler Fx, MiSTer.ini's forced_scandoubler): its output's
// horizontal blank includes the vertical one (the module is given the combined blank), but sys/scandoubler.v takes its line timing
// from HBlank's edges and needs them on every line, the vertical blank's too -- with a blank held through the vertical blank the
// doubled picture has no vertical sync and stands still (found on the owner's Monster Maulers core). Without CRT Adjust the core's
// HBlank (rtl/cp_video.sv) is the horizontal blank alone, as the scandoubler wants. CRT Adjust is for 15 kHz anyway.
wire        crt_sd = (|status[5:3]) | forced_scandoubler;
wire        crt_on = status[101] & ~crt_sd;
wire        ca_ce, ca_hblank, ca_vblank, ca_hs, ca_vs, ca_de_osd;
wire [23:0] vid_rgb;
wire [23:0] rgb_in = mc_rst ? 24'd0 : rgb;
cp_crtadj u_crtadj
(
	.clk(clk_sys), .i_on(crt_on), .i_hsize_f(status[100:96]), .i_hpos_f(status[85:79]), .i_vshift_f(status[78:74]), .i_pdot(5'd16),
	.i_ce(ce_pix), .i_hblank(hblank), .i_vblank(vblank), .i_hs(hsync), .i_vs(vsync), .i_rgb(rgb_in),
	.o_ce(ca_ce), .o_hblank(ca_hblank), .o_vblank(ca_vblank), .o_hs(ca_hs), .o_vs(ca_vs), .o_rgb(vid_rgb), .o_de_osd(ca_de_osd)
);
wire        vga_de_mix;

arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ca_ce),
	.RGB_in(vid_rgb),
	.HBlank(ca_hblank),
	.VBlank(ca_vblank),
	.HSync(ca_hs),
	.VSync(ca_vs),
	.fx(status[5:3]),
	.VGA_DE(vga_de_mix)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(crt_on ? ca_de_osd : vga_de_mix),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

// user LED: on while the machine is held (a ROM loading), blinks once per frame while it runs, blinks fast once a line has not
// been finished in time (since the reset)
reg        led_vbl_toggle, led_ovr;
reg [23:0] led_cnt;
always @(posedge clk_sys) begin
	led_cnt <= led_cnt + 24'd1;
	if (dbg_irq) led_vbl_toggle <= ~led_vbl_toggle;
	if (mc_rst) led_ovr <= 1'b0;
	else if (dbg_ovr) led_ovr <= 1'b1;
end
assign LED_USER = mc_rst ? 1'b1 : led_ovr ? led_cnt[22] : led_vbl_toggle;

endmodule
