// F2 System "Cross Pang" family board (MAME src/mame/f32/crospang.cpp): the 68000 side.
//
// The 68000 (fx68k; 7.159 MHz, Pitapat Puzzle 14.318 MHz), its memory map (crospang_state::base_map + the per-game maps), the RAMs the
// video reads, the inputs, the tile bank registers, the per-game scroll registers and the sound latch.
//
//   000000-0FFFFF  program ROM (SDRAM, through a cache; writes are ignored: "writes to ROM quite often")
//   100000 (w)     tile bank select: sel = (data >> 8) & 3
//   10000E (w)     tile bank data:   bank[sel] = data >> 8
//   100002-10000D  scroll registers: which register is which depends on the game (cfg_map, see below)
//   120000-1207FF  FG video RAM (32 x 32 words)       122000-1227FF  BG video RAM (32 x 32 words)
//   200000-2005FF  palette RAM (0x300 words, xRGB555) 210000-2107FF  sprite RAM (256 entries x 4 words)
//   270001 (w)     sound latch (low byte)             270004-270007  writes ignored
//   280000 P1_P2   280002 COIN   280004 DSW           (16 bit, active low)
//   <ram base>     64 KB work RAM: 320000 (Cross Pang, Heuk Sun Baek Sa), 300000 (Pitapat), 3A0000 (Bestri), 340000 (Bestri set 2)
//
// cfg_map (the scroll registers; the *_map functions of the driver, scroll values as the tilemap's set_scrollx / set_scrolly gets them):
//   0 crospang, heuksun, pitapat:  100002 FG y + 8, 100004 BG x + 4, 100006 BG y + 8, 100008 FG x
//   1 pitapata:                    100002 FG x, 100004 FG y + 8, 100006 BG x + 4, 100008 BG y + 8
//   2 bestri:                      100004 FG x, 100006 FG y, 10000A BG y, 10000C BG x     (add / XOR transformed, see below)
//   3 bestria:                     100006 FG x, 100008 FG y, 10000A BG x, 10000C BG y
//   Bestri: scroll = (data & 3FF) ^ k:  FG x: ^1E1, then - 1;  FG y: ^AB, then 7 - scroll;  BG x: ^3C1, then + 3;  BG y: ^155, then 7 - scroll.
//
// Every access completes with DTACK from here: block-RAM accesses after four clocks, ROM accesses when the cache has the word.
// Unmapped addresses read as 0 and swallow writes (MAME's defaults).
`default_nettype none

module cp_main (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_phi1, cen_phi2,           // the CPU clock as alternating enables
    input  logic [1:0]  cfg_map,                      // scroll register map (see above)
    input  logic [1:0]  cfg_ram,                      // work RAM base: 0 = 320000, 1 = 300000, 2 = 3A0000, 3 = 340000

    // program ROM word read (through the cache): level request until ack
    output logic        rom_req,
    output logic [19:1] rom_addr,
    input  logic        rom_ack,                      // one cycle, rom_data valid
    input  logic [15:0] rom_data,

    // inputs, active low, in the board's bit order
    input  logic [15:0] p1p2_in, coin_in, dsw_in,

    input  logic        vblank_irq,                   // pulse: raise the level 6 interrupt (the start of vertical blank)
    input  logic        vsnap,                        // 1: the picture shows the video RAMs and registers as they were at the start of
                                                      //    vertical blank (MAME); 0: as they are while each line is drawn

    // video: tile RAM read ports (registered, one clock after the address)
    input  logic [9:0]  fg_addr, bg_addr,
    output logic [15:0] fg_data, bg_data,
    // video: sprite RAM read port ({w3, w2, w1, w0} of an entry)
    input  logic [7:0]  sr_addr,
    output logic [63:0] sr_data,
    // video: palette RAM read port (always live: the palette is looked up as the dots go out)
    input  logic [9:0]  pal_addr,
    output logic [15:0] pal_data,
    // video: registers (snapshot or live, as the RAMs)
    output logic [15:0] fg_sx, fg_sy, bg_sx, bg_sy,
    output logic [7:0]  bank0, bank1, bank2, bank3,

    // sound
    output logic [7:0]  snd_latch,
    output logic        snd_latch_wr,                 // one-cycle pulse

    // bus trace for the simulation
    output logic        trc_stb,
    output logic [23:1] trc_addr,
    output logic        trc_rw,
    output logic [15:0] trc_data,
    output logic [1:0]  trc_be,
    output logic        cpu_halted
);

    // ------------------------------------------------------------------ CPU
    logic [23:1] eab;
    logic [15:0] oEdb, iEdb;
    logic        eRWn, ASn, LDSn, UDSn, VMAn, E;
    logic        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
    logic        DTACKn;

    wire iack = FC2 & FC1 & FC0 & ~ASn;

    // level 6 interrupt, held until acknowledged (MAME: irq6_line_hold)
    logic irq6;
    logic iack_d;
    always_ff @(posedge clk) begin
        iack_d <= iack;
        if (reset)                   irq6 <= 1'b0;
        else if (iack_d & ~iack)     irq6 <= 1'b0;
        else if (vblank_irq)         irq6 <= 1'b1;
    end

    logic pwr_d;
    always_ff @(posedge clk) pwr_d <= reset;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(reset | pwr_d), .pwrUp(reset),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E), .VMAn(VMAn),
        .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(BGn),
        .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
        .DTACKn(DTACKn), .VPAn(~iack),
        .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(1'b1), .IPL1n(~irq6), .IPL2n(~irq6),     // level 6 = 110
        .iEdb(iEdb), .oEdb(oEdb),
        .eab(eab)
    );
    assign cpu_halted = ~oHALTEDn;

    // ------------------------------------------------------------------ decode
    wire [23:0] ba = {eab, 1'b0};
    wire sel_rom   = ba[23:20] == 4'h0;                // 000000-0FFFFF
    wire sel_reg   = ba[23:4]  == 20'h10000;           // 100000-10000F
    wire sel_fg    = ba[23:11] == 13'h0240;            // 120000-1207FF
    wire sel_bg    = ba[23:11] == 13'h0244;            // 122000-1227FF
    wire sel_pal   = (ba[23:11] == 13'h0400) && (ba[10:9] != 2'b11);   // 200000-2005FF
    wire sel_spr   = ba[23:11] == 13'h0420;            // 210000-2107FF
    wire sel_latch = eab == 23'h138000;                // 270000 / 270001 (the byte at 270001)
    wire sel_p12   = eab == 23'h140000;                // 280000
    wire sel_coin  = eab == 23'h140001;                // 280002
    wire sel_dsw   = eab == 23'h140002;                // 280004
    logic [7:0] ram_hi;
    always_comb case (cfg_ram)
        2'd0:    ram_hi = 8'h32;
        2'd1:    ram_hi = 8'h30;
        2'd2:    ram_hi = 8'h3A;
        default: ram_hi = 8'h34;
    endcase
    wire sel_ram   = ba[23:16] == ram_hi;              // 64 KB

    // ------------------------------------------------------------------ RAMs
    logic        we;                                   // one-cycle write strobe
    wire  [1:0]  be = {~UDSn, ~LDSn};

    logic [15:0] q_ram, q_fg, q_bg, q_pal;
    logic [15:0] q_s0, q_s1, q_s2, q_s3;

    cp_ram16 #(.AW(15)) u_ram (
        .clka(clk), .addra(eab[15:1]), .da(oEdb), .wea(we && sel_ram ? be : 2'b00), .qa(q_ram),
        .clkb(clk), .addrb(15'd0), .qb());
    // The CPU's tile and sprite RAMs are copied into the renderer's copies of them (`*_d`) by a sweep of 1024 clocks: once at the start
    // of vertical blank when `vsnap` (MAME draws the whole frame at that moment, before the interrupt routine rewrites the RAMs -- the
    // games copy the whole sprite list and both tilemaps every frame, 0.05 .. 5.5 ms after the interrupt, measured in MAME with
    // tools/lua/vwrites.lua), over and over otherwise (the copy then trails the CPU's writes by at most 11 us).
    logic [10:0] cp_i = 11'd0;
    logic        cp_run = 1'b0;
    logic        cp_we;
    logic [9:0]  cp_wa;
    wire  [9:0]  cp_ra = cp_i[9:0];
    always_ff @(posedge clk) begin
        cp_we <= cp_run;
        cp_wa <= cp_ra;
        if (vsnap ? vblank_irq : !cp_run) begin cp_i <= 11'd0; cp_run <= 1'b1; end
        else if (cp_run) begin
            cp_i <= cp_i + 11'd1;
            if (cp_i == 11'd1023) cp_run <= 1'b0;
        end
    end
    logic [15:0] c_fg, c_bg, c_s0, c_s1, c_s2, c_s3;

    cp_ram16 #(.AW(10)) u_fg (
        .clka(clk), .addra(eab[10:1]), .da(oEdb), .wea(we && sel_fg ? be : 2'b00), .qa(q_fg),
        .clkb(clk), .addrb(cp_ra), .qb(c_fg));
    cp_ram16 #(.AW(10)) u_bg (
        .clka(clk), .addra(eab[10:1]), .da(oEdb), .wea(we && sel_bg ? be : 2'b00), .qa(q_bg),
        .clkb(clk), .addrb(cp_ra), .qb(c_bg));
    cp_ram16 #(.AW(10)) u_pal (
        .clka(clk), .addra(eab[10:1]), .da(oEdb), .wea(we && sel_pal ? be : 2'b00), .qa(q_pal),
        .clkb(clk), .addrb(pal_addr), .qb(pal_data));
    // sprite RAM: word field in four RAMs, the entry (0..255) as the address: CPU word w = eab[10:1]: entry = w[9:2], field = w[1:0]
    cp_ram16 #(.AW(8)) u_s0 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd0 ? be : 2'b00), .qa(q_s0),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s0));
    cp_ram16 #(.AW(8)) u_s1 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd1 ? be : 2'b00), .qa(q_s1),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s1));
    cp_ram16 #(.AW(8)) u_s2 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd2 ? be : 2'b00), .qa(q_s2),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s2));
    cp_ram16 #(.AW(8)) u_s3 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd3 ? be : 2'b00), .qa(q_s3),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s3));

    // the renderer's copies
    cp_sdp #(.AW(10), .DW(16)) u_fg_d (.clk(clk), .we(cp_we), .waddr(cp_wa), .wdata(c_fg), .raddr(fg_addr), .rdata(fg_data));
    cp_sdp #(.AW(10), .DW(16)) u_bg_d (.clk(clk), .we(cp_we), .waddr(cp_wa), .wdata(c_bg), .raddr(bg_addr), .rdata(bg_data));
    cp_sdp #(.AW(8),  .DW(64)) u_sp_d (.clk(clk), .we(cp_we && cp_wa[9:8] == 2'd0), .waddr(cp_wa[7:0]), .wdata({c_s3, c_s2, c_s1, c_s0}),
                                       .raddr(sr_addr), .rdata(sr_data));

    // ------------------------------------------------------------------ registers
    // The raw scroll registers (100000-10000F as last written), the tile banks and the sound latch are plain latches: the machine's
    // reset does not clear them (the game writes them at start-up; MAME clears its tilemap scrolls only by never having been written),
    // which also lets the simulation hold the CPU in reset with a frozen state loaded.  `wv` marks a register that has been written:
    // until then its scroll contribution is 0, as the MAME tilemap's.
    logic [15:0] raw [8];
    logic  [7:0] wv;
    logic  [1:0] tb_sel;
    logic  [7:0] tbank [4];
    initial begin
        for (int i = 0; i < 8; i++) raw[i] = 16'd0;
        wv = 8'd0; tb_sel = 2'd0;
        tbank[0] = 8'd0; tbank[1] = 8'd1; tbank[2] = 8'd2; tbank[3] = 8'd3;
        snd_latch = 8'd0;
    end

    // MAME hands a byte write to a 16-bit handler as the byte on both lanes (the log of the driver shows `0101 ff00`)
    wire [15:0] wdat = (be == 2'b11) ? oEdb : be[1] ? {oEdb[15:8], oEdb[15:8]} : {oEdb[7:0], oEdb[7:0]};

    always_ff @(posedge clk) begin
        snd_latch_wr <= 1'b0;
        if (we) begin
            if (sel_reg) begin
                case (eab[3:1])
                    3'd0:    tb_sel <= wdat[9:8];                                   // tilebank_select_w
                    3'd7:    tbank[tb_sel] <= wdat[15:8];                           // tilebank_data_w
                    default: begin raw[eab[3:1]] <= wdat; wv[eab[3:1]] <= 1'b1; end
                endcase
            end
            if (sel_latch && be[0]) begin snd_latch <= oEdb[7:0]; snd_latch_wr <= 1'b1; end
        end
    end

    // the scroll values the driver's handlers would have given the tilemaps (only the low 9 bits matter: 512 x 512)
    function automatic [15:0] bx(input [15:0] d, input [9:0] k);     // (data & 0x3ff) ^ k
        bx = {6'd0, (d[9:0] ^ k)};
    endfunction
    logic [15:0] fg_sx_l, fg_sy_l, bg_sx_l, bg_sy_l;            // live
    always_comb begin
        fg_sx_l = 16'd0; fg_sy_l = 16'd0; bg_sx_l = 16'd0; bg_sy_l = 16'd0;
        case (cfg_map)
            2'd0: begin
                if (wv[1]) fg_sy_l = raw[1] + 16'd8;
                if (wv[2]) bg_sx_l = raw[2] + 16'd4;
                if (wv[3]) bg_sy_l = raw[3] + 16'd8;
                if (wv[4]) fg_sx_l = raw[4];
            end
            2'd1: begin
                if (wv[1]) fg_sx_l = raw[1];
                if (wv[2]) fg_sy_l = raw[2] + 16'd8;
                if (wv[3]) bg_sx_l = raw[3] + 16'd4;
                if (wv[4]) bg_sy_l = raw[4] + 16'd8;
            end
            2'd2: begin
                if (wv[2]) fg_sx_l = bx(raw[2], 10'h1e1) - 16'd1;
                if (wv[3]) fg_sy_l = 16'd7 - bx(raw[3], 10'h0ab);
                if (wv[5]) bg_sy_l = 16'd7 - bx(raw[5], 10'h155);
                if (wv[6]) bg_sx_l = bx(raw[6], 10'h3c1) + 16'd3;
            end
            default: begin
                if (wv[3]) fg_sx_l = bx(raw[3], 10'h1e1) - 16'd1;
                if (wv[4]) fg_sy_l = 16'd7 - bx(raw[4], 10'h0ab);
                if (wv[6]) bg_sy_l = 16'd7 - bx(raw[6], 10'h155);
                if (wv[5]) bg_sx_l = bx(raw[5], 10'h3c1) + 16'd3;
            end
        endcase
    end

    // as the picture uses them: latched with the RAMs' snapshot at the start of vertical blank, or live
    logic [15:0] fg_sx_s, fg_sy_s, bg_sx_s, bg_sy_s;
    logic  [7:0] bank_s [4];
    always_ff @(posedge clk) if (vblank_irq) begin
        fg_sx_s <= fg_sx_l; fg_sy_s <= fg_sy_l; bg_sx_s <= bg_sx_l; bg_sy_s <= bg_sy_l;
        bank_s[0] <= tbank[0]; bank_s[1] <= tbank[1]; bank_s[2] <= tbank[2]; bank_s[3] <= tbank[3];
    end
    assign fg_sx = vsnap ? fg_sx_s : fg_sx_l;
    assign fg_sy = vsnap ? fg_sy_s : fg_sy_l;
    assign bg_sx = vsnap ? bg_sx_s : bg_sx_l;
    assign bg_sy = vsnap ? bg_sy_s : bg_sy_l;
    assign {bank3, bank2, bank1, bank0} = vsnap ? {bank_s[3], bank_s[2], bank_s[1], bank_s[0]} : {tbank[3], tbank[2], tbank[1], tbank[0]};

    // ------------------------------------------------------------------ bus cycle
    logic        rdy;                             // DTACK
    logic [2:0]  cnt;
    logic        wr_seen;
    assign DTACKn = ~rdy;

    logic [15:0] rd_mux;
    always_comb begin
        rd_mux = 16'h0000;
        if      (sel_ram)   rd_mux = q_ram;
        else if (sel_fg)    rd_mux = q_fg;
        else if (sel_bg)    rd_mux = q_bg;
        else if (sel_pal)   rd_mux = q_pal;
        else if (sel_spr)   rd_mux = (eab[2:1] == 2'd0) ? q_s0 : (eab[2:1] == 2'd1) ? q_s1 : (eab[2:1] == 2'd2) ? q_s2 : q_s3;
        else if (sel_p12)   rd_mux = p1p2_in;
        else if (sel_coin)  rd_mux = coin_in;
        else if (sel_dsw)   rd_mux = dsw_in;
    end

    assign rom_addr = eab[19:1];

    always_ff @(posedge clk) begin
        we         <= 1'b0;
        trc_stb    <= 1'b0;
        if (reset || ASn) begin
            rdy     <= 1'b0;
            cnt     <= 3'd0;
            wr_seen <= 1'b0;
            rom_req <= 1'b0;
        end else if (!iack && !rdy) begin
            if (!eRWn) begin
                // write: the data strobes (and the data) arrive a clock after AS
                if (!wr_seen) begin
                    if (be != 2'b00) begin
                        wr_seen <= 1'b1;
                        we      <= 1'b1;
                        trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b0; trc_data <= oEdb; trc_be <= be;
                    end
                end else begin
                    rdy <= 1'b1;
                end
            end else if (sel_rom) begin
                // read from the ROM cache
                rom_req <= 1'b1;
                if (rom_ack) begin
                    iEdb    <= rom_data;
                    rom_req <= 1'b0;
                    rdy     <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= rom_data; trc_be <= be;
                end
            end else begin
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) begin
                    iEdb <= rd_mux;
                    rdy  <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= rd_mux; trc_be <= be;
                end
            end
        end
    end
endmodule
`default_nettype wire
