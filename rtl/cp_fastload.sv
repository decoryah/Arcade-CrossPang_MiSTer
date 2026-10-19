// Fast load: with address="0x32000000" on the MRA's index-0 <rom>, a recent Main_MiSTer copies the whole assembled image into the DDR3
// at that byte address in one memcpy, bracketed by a download without a data byte that starts with ioctl_addr = the image's length
// (an ordinary download starts at 0: Crospang.sv tells them apart).  This reads the image back and hands it to cp_mem's loader a byte
// at a time, in order, as the HPS would (dl_we / dl_addr / dl_data, held off by dl_wait), so the loader and its layout are unchanged.
// An older Main_MiSTer ignores address= and sends the image the ordinary way.
//
// The DDR3 port is the framework's DDRAM_* (Avalon-MM, 64-bit beats; DDRAM_ADDR is the beat address in the HPS's whole space, byte =
// 8 x beat -- sys/arcade_video.v's frame buffer at byte 0x24000000 is beat 0x4800000 -- so the image at byte 0x32000000 starts at beat
// 0x6400000): bursts of 32 beats (256 bytes) into a block buffer, then out byte by byte; byte n of a beat is bits 8n+7..8n.
// The loader writes about a word per 12 clocks, so the 5.3 MB image takes about a third of a second; the DDR3 is not the limit.
// (After the fast load of the owner's Monster Maulers / Violent Storm cores, mm_mem.sv / vs_mem.sv.)
`default_nettype none
module cp_fastload #(
    parameter [28:0] BASE = 29'h6400000        // the image's first beat: byte 0x32000000 / 8
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        go,                    // one clock: the empty download has ended, the image is in the DDR3
    input  logic        abort,                 // a download is going on: stop handing over bytes
    input  logic [24:0] len,                   // the image's length in bytes
    output logic        done,                  // one clock: the last byte has been handed over
    output logic        busy,

    // the loader's byte input (cp_mem dl_*)
    output logic        dl_we,
    output logic [24:0] dl_addr,
    output logic  [7:0] dl_data,
    input  logic        dl_wait,

    // DDR3 (rd held until a clock where busy is low; the beats come back with dout_ready)
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD
);
    localparam int BEATS = 32;

    logic [63:0] blk [BEATS];                  // one block (an M10K)
    logic [63:0] blk_q;                        // its registered read port
    logic  [4:0] wi, ri;                       // the beat written next / read out
    logic [63:0] cur;                          // the beat whose bytes are going out
    logic  [2:0] bi;                           // the byte of it
    logic [24:0] off;                          // the image offset of the next byte
    logic  [8:0] owed;                         // beats asked for and not yet back (a burst of an aborted load drains first)
    logic        pend;

    typedef enum logic [2:0] { F_IDLE, F_REQ, F_RX, F_RD, F_RD2, F_OUT } st_t;
    st_t st;

    always_ff @(posedge clk) blk_q <= blk[ri];

    always_ff @(posedge clk) begin
        dl_we <= 1'b0;
        done  <= 1'b0;
        owed  <= owed + ((DDRAM_RD && !DDRAM_BUSY) ? 9'(DDRAM_BURSTCNT) : 9'd0) - (DDRAM_DOUT_READY ? 9'd1 : 9'd0);
        if (DDRAM_RD && !DDRAM_BUSY) DDRAM_RD <= 1'b0;            // taken
        if (go) pend <= 1'b1;
        if (rst) begin
            st <= F_IDLE; busy <= 1'b0; pend <= 1'b0; DDRAM_RD <= 1'b0; owed <= '0;
        end else if (abort) begin
            st <= F_IDLE; busy <= 1'b0; pend <= 1'b0;
        end else case (st)
            F_IDLE: if (pend && owed == 9'd0) begin
                pend <= 1'b0; busy <= 1'b1; off <= '0; st <= F_REQ;
            end
            F_REQ: if (off >= len) begin
                busy <= 1'b0; done <= 1'b1; st <= F_IDLE;
            end else begin
                DDRAM_RD <= 1'b1; DDRAM_ADDR <= BASE + 29'(off[24:3]); DDRAM_BURSTCNT <= 8'(BEATS); wi <= '0; st <= F_RX;
            end
            F_RX: if (DDRAM_DOUT_READY) begin
                blk[wi] <= DDRAM_DOUT;
                wi <= wi + 5'd1;
                if (wi == 5'(BEATS - 1)) begin ri <= '0; st <= F_RD; end
            end
            F_RD:  st <= F_RD2;                                     // blk_q follows ri a clock later
            F_RD2: begin cur <= blk_q; bi <= '0; st <= F_OUT; end
            F_OUT: if (!dl_wait) begin
                dl_we <= 1'b1; dl_addr <= off; dl_data <= cur[7:0];
                cur <= cur >> 8;
                off <= off + 25'd1;
                bi  <= bi + 3'd1;
                if (off + 25'd1 >= len) st <= F_REQ;                // the last byte: F_REQ finishes
                else if (bi == 3'd7) begin
                    if (ri == 5'(BEATS - 1)) st <= F_REQ;
                    else begin ri <= ri + 5'd1; st <= F_RD; end
                end
            end
            default: st <= F_IDLE;
        endcase
    end

    initial begin
        st = F_IDLE; busy = 1'b0; pend = 1'b0; DDRAM_RD = 1'b0; owed = '0; dl_we = 1'b0; done = 1'b0;
    end
endmodule
`default_nettype wire
