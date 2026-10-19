// Line renderer: MAME's crospang_state::screen_update for one line (the one after the line being shown).
//
//   1. BG tilemap: 32 x 32 tiles of 16 x 16 (512 x 512), opaque; 21 tiles cover the line.  Per tile: the word from the BG video RAM
//      ({colour[15:12], bank select[11:10], code[9:0]}), the tile = {bank[sel], code}, the row's 4 words from the tile ROM in SDRAM, 16 pen writes.
//   2. FG tilemap, the same, pen 0 transparent.   Pen = (colour + 0x20) * 16 + pixel for BG, (colour + 0x10) * 16 + pixel for FG.
//   3. sprites: decospr (standard list format, bootleg mode, offsets 5 / 7, flip screen off), 256 entries of 4 words, drawn in entry order,
//      the last one on top, pen 0 transparent, pen = colour * 16 + pixel.  The entry scan runs one entry a clock and stops at a hit.
//
// Sprite placement (decospr.cpp draw_sprites_common, the 320-wide branch):
//   y' = ((w0 & 1FF) + 7) & 1FF, signed 9 bit;  yb = 240 - y';   a sprite of M + 1 tiles covers the lines yb - 16 * M ... yb + 15;
//   x' = ((w2 & 1FF) + 5) & 1FF, signed with the threshold 320 (x' >= 320 -> x' - 512);  xl = 304 - x'  (left edge of the 16-pixel column)
//   row of the sprite on this line  d = line - (yb - 16 * M),  tile row t = d / 16 (0 = top),  pixel row d % 16 (15 - that when flip Y)
//   tile = w1 + (flip Y ? M - t : t)   (bootleg: no masking of w1 with ~M);  wide (w0 bit 11): a second tile of the row at xl - 16 with tile - (M + 1)
//
// The ROM layout (the loader's remap, cp_mem.sv / tools/crospang_image.py): a 16-pixel row of a tile is 4 words at {tile[13:0], row[3:0], col half, plane half}:
//   word 0 / 1: pixels 0..7, plane half 0 / 1; word 2 / 3: pixels 8..15.  Each word = {byte +8, byte +0} of the gfx layout's 16-bit rows; the pixel x of a
//   byte is bit 7 - x.   tiles:   pen = {w0[hi], w0[lo], w1[hi], w1[lo]}    sprites:  pen = {w1[hi], w1[lo], w0[hi], w0[lo]}   (MAME's tlayout_alt / tlayout)
//
// Line buffer entries are palette indexes.  (Structure after omg_render.sv.)
`default_nettype none
module cp_render #(
    parameter [24:1] TILE_BASE = 24'h080000,      // SDRAM word address of the (remapped) tile ROM
    parameter [24:1] SPR_BASE  = 24'h180000       // ... and of the sprite ROM
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,                    // draw `line` into half `bank` of the line buffer
    input  logic [7:0]  line,
    input  logic        bank,
    output logic        busy,
    output logic        overrun,                  // pulse: a line started while the last one was still being drawn

    input  logic [15:0] fg_sx, fg_sy, bg_sx, bg_sy,
    input  logic [7:0]  bank0, bank1, bank2, bank3,
    input  logic        tmask_big,                // tile ROM: 16384 tiles (else 4096)
    input  logic        smask_big,                // sprite ROM: 16384 tiles (else 8192)
    input  logic        flash_hide,               // flashing sprites are hidden in this frame

    // tile RAMs (registered, one clock after the address)
    output logic [9:0]  fg_addr, bg_addr,
    input  logic [15:0] fg_data, bg_data,
    // sprite RAM: {w3, w2, w1, w0} of the entry, one clock after the address
    output logic [7:0]  sr_addr,
    input  logic [63:0] sr_data,

    // SDRAM burst clients (level request, a word per wr with its index, a pulse at the end): 4 words each
    output logic        t_req,
    output logic [24:1] t_addr,
    input  logic        t_wr,
    input  logic [1:0]  t_idx,
    input  logic [15:0] t_data,
    input  logic        t_done,
    output logic        s_req,
    output logic [24:1] s_addr,
    input  logic        s_wr,
    input  logic [1:0]  s_idx,
    input  logic [15:0] s_data,
    input  logic        s_done,

    // line buffer write port
    output logic        lb_we,
    output logic [9:0]  lb_addr,                  // {bank, x[8:0]}
    output logic [9:0]  lb_data
);
    typedef enum logic [3:0] {
        S_IDLE, T_ADDR, T_WAIT, T_CAP, T_FETCH, T_PIX,
        S_SCAN, S_FETCH, S_DRAW
    } st_t;
    st_t st = S_IDLE;

    // latched at the start of the line
    logic [7:0]  y;
    logic        bk;
    logic        layer;                           // 0 BG, 1 FG
    logic [8:0]  sx, sy;                          // the layer's scroll
    logic [8:0]  my;                              // tile row source line: y + scroll y
    logic        fl_hide;

    // tile pass
    logic [4:0]  ti;                              // tile 0..20
    logic [3:0]  t_col;                           // colour of the tile
    logic [15:0] tw [4];
    logic [3:0]  pp;                              // pixel 0..15
    wire  [4:0]  tcol = sx[8:4] + ti;
    wire  [10:0] tl_x = {2'b00, ti, 4'b0000} - {7'd0, sx[3:0]} + {7'd0, pp};      // signed 11 bit: screen x of the pixel

    // sprite pass
    logic [7:0]  ia;                              // next entry to ask for
    logic        scan_run;
    logic [7:0]  i_sa, i_sd;
    logic        v_sa, v_sd;
    logic [7:0]  resume;
    logic        last_hit;
    logic [15:0] sp_code;                         // the tile of the row being drawn (before the ROM mask)
    logic [4:0]  sp_col;
    logic        sp_fx, sp_wide, sp_second;
    logic [3:0]  sp_row;                          // pixel row in the tile (flip Y applied)
    logic [2:0]  sp_ntm1;                         // M
    logic [15:0] sp_w1;
    logic [10:0] sp_xl;                           // xl, signed 11 bit
    logic [15:0] sw [4];
    logic [3:0]  sp;                              // pixel 0..15

    wire [15:0] w0 = sr_data[15:0], w1 = sr_data[31:16], w2 = sr_data[47:32];

    // ---- the hit test (decospr placement)
    wire  [8:0]  yq   = w0[8:0] + 9'd7;                                            // (y & 1ff) + y_offset, mod 512
    wire signed [10:0] ys   = {{2{yq[8]}}, yq};                                    // signed 9 bit
    wire signed [10:0] yb   = 11'sd240 - ys;                                       // bottom tile's top line
    logic [2:0]  mtall;                                                             // M: 0 / 1 / 3 / 7 (1, 2, 4, 8 tiles tall)
    always_comb case ({w0[10], w0[9]})
        2'd0: mtall = 3'd0;
        2'd1: mtall = 3'd1;
        2'd2: mtall = 3'd3;
        default: mtall = 3'd7;
    endcase
    wire signed [10:0] top  = yb - {4'd0, mtall, 4'd0};                            // yb - 16 * M
    wire signed [10:0] dd   = {3'b000, y} - top;                                   // line - top
    wire         hit_y = (dd >= 11'sd0) && (dd < ({4'd0, mtall, 4'd0} + 11'sd16));
    wire  [8:0]  xq   = w2[8:0] + 9'd5;
    wire signed [10:0] xs   = (xq >= 9'd320) ? ({2'b00, xq} - 11'sd512) : {2'b00, xq};   // x' (>= 320 wraps to negative)
    wire signed [10:0] xl   = 11'sd304 - xs;
    wire         hit_x = (xl < 11'sd320) || (w0[11] && (xl < 11'sd336));
    wire         hit   = v_sd && hit_y && hit_x && !(w0[12] && fl_hide);

    // ---- pixel pick from the fetched row words
    function automatic [3:0] pick(input [15:0] a0, input [15:0] a1, input [15:0] b0, input [15:0] b1, input [3:0] x, input is_spr);
        // x = pixel 0..15 of the row; words 0/1 hold pixels 0..7, 2/3 pixels 8..15
        logic [15:0] p, q;
        logic [2:0]  b;
        begin
            p = x[3] ? b0 : a0;
            q = x[3] ? b1 : a1;
            b = 3'd7 - x[2:0];
            pick = is_spr ? {q[8 + b], q[b], p[8 + b], p[b]}
                          : {p[8 + b], p[b], q[8 + b], q[b]};
        end
    endfunction
    wire [3:0] t_pen  = pick(tw[0], tw[1], tw[2], tw[3], pp, 1'b0);
    wire [3:0] sp_c   = sp_fx ? (4'd15 - sp) : sp;                                   // source pixel column
    wire [3:0] s_pen  = pick(sw[0], sw[1], sw[2], sw[3], sp_c, 1'b1);
    wire signed [10:0] sp_x = sp_xl + {7'd0, sp};

    assign busy = (st != S_IDLE);

    // the last row fetched of each kind, kept for the next tile / sprite of the same row (the ROMs do not change while the machine runs;
    // rst invalidates them, and a ROM load holds the machine in reset)
    logic        tc_valid, sc_valid;
    logic [17:0] tc_key, sc_key;                  // {tile[13:0], row[3:0]}
    wire  t_empty = ~|{tw[0], tw[1], tw[2], tw[3]};
    wire  s_empty = ~|{sw[0], sw[1], sw[2], sw[3]};

    // the sprite code the ROM sees: the row's tile, or the second tile of a wide sprite (tile - (M + 1))
    wire [15:0] sp_code_use = sp_second ? (sp_code - {12'd0, 1'b0, sp_ntm1} - 16'd1) : sp_code;
    wire [13:0] sp_code_m   = smask_big ? sp_code_use[13:0] : {1'b0, sp_code_use[12:0]};

    always_ff @(posedge clk) begin
        lb_we   <= 1'b0;
        overrun <= 1'b0;
        if (t_wr) tw[t_idx] <= t_data;
        if (s_wr) sw[s_idx] <= s_data;

        if (rst) begin
            st <= S_IDLE; t_req <= 1'b0; s_req <= 1'b0; scan_run <= 1'b0; tc_valid <= 1'b0; sc_valid <= 1'b0;
        end else begin
            if (start && st != S_IDLE) overrun <= 1'b1;
            case (st)
                S_IDLE: if (start) begin
                    y       <= line;
                    bk      <= bank;
                    layer   <= 1'b0;
                    sx      <= bg_sx[8:0];
                    sy      <= bg_sy[8:0];
                    fl_hide <= flash_hide;
                    ti      <= 5'd0;
                    st      <= T_ADDR;
                end

                // ---------------------------------------------------- tiles
                T_ADDR: begin
                    my <= {1'b0, y} + sy;
                    st <= T_WAIT;
                end
                T_WAIT: begin
                    if (layer) fg_addr <= {my[8:4], tcol};
                    else       bg_addr <= {my[8:4], tcol};
                    st <= T_CAP;
                end
                T_CAP: begin                                    // the RAM's word arrives one clock after the address (T_FETCH's first clock)
                    st <= T_FETCH;
                    t_req <= 1'b0;
                end
                T_FETCH: begin
                    // (entered from T_CAP: the data is valid now; the request goes out in the clock after)
                    if (!t_req && !t_done) begin
                        logic [15:0] v;
                        logic [7:0]  bkv;
                        logic [17:0] code;
                        logic [17:0] key;
                        v = layer ? fg_data : bg_data;
                        case (v[11:10])
                            2'd0: bkv = bank0;
                            2'd1: bkv = bank1;
                            2'd2: bkv = bank2;
                            default: bkv = bank3;
                        endcase
                        code  = {bkv, v[9:0]};
                        key   = {tmask_big ? code[13:0] : {2'b00, code[11:0]}, my[3:0]};
                        t_col <= v[15:12];
                        if (tc_valid && tc_key == key) begin    // the same row as the last fetch: its words are still in tw
                            pp <= 4'd0;
                            st <= T_PIX;
                        end else begin
                            t_addr   <= TILE_BASE + {key, 2'b00};
                            t_req    <= 1'b1;
                            tc_key   <= key;
                            tc_valid <= 1'b0;
                        end
                    end else if (t_done) begin
                        t_req    <= 1'b0;
                        tc_valid <= 1'b1;
                        pp       <= 4'd0;
                        st       <= T_PIX;
                    end
                end
                T_PIX: begin
                    if (tl_x[10] == 1'b0 && tl_x < 11'd320 && (!layer || t_pen != 4'd0)) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bk, tl_x[8:0]};
                        lb_data <= {layer ? 2'b01 : 2'b10, t_col, t_pen};
                    end
                    pp <= pp + 4'd1;
                    if (pp == 4'd15 || (layer && t_empty)) begin          // an FG row of pen 0 only draws nothing
                        if (ti == 5'd20) begin
                            if (!layer) begin
                                layer <= 1'b1;
                                sx    <= fg_sx[8:0];
                                sy    <= fg_sy[8:0];
                                ti    <= 5'd0;
                                st    <= T_ADDR;
                            end else begin
                                ia <= 8'd0; scan_run <= 1'b1; v_sa <= 1'b0; v_sd <= 1'b0;
                                st <= S_SCAN;
                            end
                        end else begin
                            ti <= ti + 5'd1;
                            st <= T_ADDR;
                        end
                    end
                end

                // ---------------------------------------------------- sprites
                S_SCAN: begin
                    // pipeline: ia -> sr_addr -> (RAM) -> sr_data, evaluated on arrival
                    sr_addr <= ia;
                    i_sa    <= ia;
                    v_sa    <= scan_run;
                    i_sd    <= i_sa;
                    v_sd    <= v_sa;
                    if (scan_run) begin
                        ia <= ia + 8'd1;
                        if (ia == 8'd255) scan_run <= 1'b0;
                    end
                    if (hit) begin
                        sp_w1     <= w1;
                        sp_col    <= w2[13:9];
                        sp_fx     <= w0[13];
                        sp_wide   <= w0[11];
                        sp_ntm1   <= mtall;
                        sp_xl     <= xl;
                        sp_second <= 1'b0;
                        sp_row    <= w0[14] ? (4'd15 - dd[3:0]) : dd[3:0];
                        // tile row t = dd / 16; the tile is w1 + (flip Y ? M - t : t)
                        sp_code   <= w1 + {13'd0, w0[14] ? (mtall - dd[6:4]) : dd[6:4]};
                        resume    <= i_sd + 8'd1;
                        last_hit  <= (i_sd == 8'd255);
                        scan_run  <= 1'b0;
                        v_sa      <= 1'b0;
                        v_sd      <= 1'b0;
                        st        <= S_FETCH;
                    end else if (!scan_run && !v_sa && !v_sd) begin
                        st <= S_IDLE;                           // all entries seen
                    end
                end
                S_FETCH: begin
                    if (!s_req && !s_done) begin
                        if (sc_valid && sc_key == {sp_code_m, sp_row}) begin     // the same row as the last fetch: still in sw
                            sp <= 4'd0;
                            st <= S_DRAW;
                        end else begin
                            s_addr   <= SPR_BASE + {sp_code_m, sp_row, 2'b00};
                            s_req    <= 1'b1;
                            sc_key   <= {sp_code_m, sp_row};
                            sc_valid <= 1'b0;
                        end
                    end else if (s_done) begin
                        s_req    <= 1'b0;
                        sc_valid <= 1'b1;
                        sp       <= 4'd0;
                        st       <= S_DRAW;
                    end
                end
                S_DRAW: begin
                    if (s_pen != 4'd0 && sp_x[10] == 1'b0 && sp_x < 11'd320) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bk, sp_x[8:0]};
                        lb_data <= {1'b0, sp_col, s_pen};
                    end
                    sp <= sp + 4'd1;
                    if (sp == 4'd15 || s_empty) begin                    // a row of pen 0 only draws nothing
                        if (sp_wide && !sp_second) begin
                            sp_second <= 1'b1;
                            sp_xl     <= sp_xl - 11'd16;
                            st        <= S_FETCH;
                        end else if (last_hit) st <= S_IDLE;
                        else begin
                            ia <= resume; scan_run <= 1'b1; v_sa <= 1'b0; v_sd <= 1'b0;
                            st <= S_SCAN;
                        end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    wire unused = ^{sp_w1, sr_data[63:48]};
endmodule
`default_nettype wire
