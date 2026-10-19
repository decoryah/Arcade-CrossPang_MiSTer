// The sound board (MAME crospang_state::sound_map / sound_io_map): a Z80 at 3.579545 MHz, its 48 KB program in block RAM (written by the
// loader), 2 KB of RAM, a YM3812 (jtopl2, Jose Tejada) at 3.579545 MHz whose IRQ drives the Z80's INT, an OKI M6295 (jt6295, Jose Tejada)
// at 894.886 kHz with pin 7 high (MAME: XTAL / 16, PIN7_HIGH: sample rate clock / 132) reading its 256 KB of samples from SDRAM, and the
// sound latch the 68000 writes.
//
//   Z80 memory:  0000-BFFF ROM    C000-C7FF RAM
//   Z80 I/O:     00 YM3812 address (w) / status (r)   01 YM3812 data   02 OKI M6295   06 sound latch (r)
//   (global mask 0xFF; MAME's unmapped reads are 0; no NMI)
`default_nettype none
module cp_sound (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_z80,              // 3.579545 MHz: the Z80 and the YM3812
    input  logic        cen_oki,              // 894.886 kHz

    input  logic [7:0]  latch,                // the 68000's sound latch

    // Z80 program load (from the loader)
    input  logic        zr_we,
    input  logic [15:0] zr_addr,
    input  logic [7:0]  zr_data,

    // OKI sample byte read: level request until ack (cp_mem.sv)
    output logic        pcm_req,
    output logic [17:0] pcm_addr,
    input  logic        pcm_ack,
    input  logic [7:0]  pcm_q,

    output logic signed [15:0] fm,            // jtopl2's output
    output logic signed [13:0] pcm,           // jt6295's sum of the voices
    output logic [15:0] dbg_pc,
    output logic        dbg_irq
);
    // ------------------------------------------------------------------ Z80
    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    logic [15:0] A;
    logic [7:0]  cpu_di, cpu_do;
    logic        int_n;

    tv80s_cen u_cpu (
        .reset_n(~rst), .clk(clk), .cen(cen_z80), .wait_n(1'b1),
        .int_n(int_n), .nmi_n(1'b1), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc = A;

    // ------------------------------------------------------------------ memories
    // the bus signals come from registers that change only on cen_z80 (every 27 machine clocks), so the block RAMs' registered reads
    // of the live address are valid long before the CPU samples them
    wire sel_rom = A[15:14] != 2'b11;                         // 0000-BFFF
    wire sel_ram = A[15:11] == 5'b11000;                      // C000-C7FF
    wire mem_wr  = !mreq_n && !wr_n && rfsh_n;

    logic [7:0] rom_q, ram_q;
    cp_sdp #(.AW(16), .DW(8)) u_rom (.clk(clk), .we(zr_we), .waddr(zr_addr), .wdata(zr_data), .raddr(A), .rdata(rom_q));
    cp_ram8 #(.AW(11)) u_ram (.clk(clk), .we(mem_wr && sel_ram), .addr(A[10:0]), .d(cpu_do), .q(ram_q));

    // ------------------------------------------------------------------ I/O
    wire io_cyc = !iorq_n && m1_n;                            // (M1 with IORQ is the interrupt acknowledge)
    wire io_wr  = io_cyc && !wr_n;
    logic io_wr_d;
    always_ff @(posedge clk) io_wr_d <= io_wr;
    wire io_wr_p = io_wr && !io_wr_d;                         // one pulse per I/O write cycle

    logic       ym_wr, oki_wr;
    logic [7:0] wdat;
    logic       ym_a0;
    always_ff @(posedge clk) begin
        ym_wr  <= 1'b0;
        oki_wr <= 1'b0;
        if (io_wr_p) begin
            wdat  <= cpu_do;
            ym_a0 <= A[0];
            if (A[7:1] == 7'd0) ym_wr  <= 1'b1;
            if (A[7:0] == 8'h02) oki_wr <= 1'b1;
        end
    end

    // YM3812: the address / data register writes, the status read; IRQ -> INT
    logic [7:0] ym_dout;
    logic       ym_irq_n;
    jtopl2 u_opl (
        .rst(rst), .clk(clk), .cen(cen_z80),
        .din(wdat), .addr(ym_a0), .cs_n(~ym_wr), .wr_n(~ym_wr),
        .dout(ym_dout), .irq_n(ym_irq_n), .snd(fm), .sample()
    );
    assign int_n   = ym_irq_n;
    assign dbg_irq = ~ym_irq_n;

    // OKI M6295
    logic [7:0]  oki_dout;
    logic [17:0] oki_a;
    logic [7:0]  oki_rd;
    logic        oki_ok;
    jt6295 #(.INTERPOL(0)) u_oki (
        .rst(rst), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(~oki_wr), .din(wdat), .dout(oki_dout),
        .rom_addr(oki_a), .rom_data(oki_rd), .rom_ok(oki_ok),
        .sound(pcm), .sample()
    );
    // the sample byte is read from the SDRAM whenever the chip's address changes and held (as omg_sound.sv)
    logic [17:0] srv_a;
    logic        have;
    always_ff @(posedge clk) begin
        if (rst) begin
            have <= 1'b0; pcm_req <= 1'b0; oki_rd <= 8'h00; srv_a <= 18'd0;
        end else begin
            if (pcm_ack) begin
                oki_rd <= pcm_q; srv_a <= pcm_addr; have <= 1'b1; pcm_req <= 1'b0;
            end else if (!pcm_req && !(have && srv_a == oki_a)) begin
                pcm_addr <= oki_a; pcm_req <= 1'b1;
            end
        end
    end
    assign oki_ok = have && (srv_a == oki_a);

    // ------------------------------------------------------------------ the CPU's data input
    always_comb begin
        cpu_di = 8'h00;
        if (!m1_n && !iorq_n)       cpu_di = 8'hFF;               // interrupt acknowledge: the bus floats high (IM 1)
        else if (!mreq_n) begin
            if (sel_rom)            cpu_di = rom_q;
            else if (sel_ram)       cpu_di = ram_q;
        end else if (io_cyc) begin
            if (A[7:1] == 7'd0)     cpu_di = ym_dout;
            else if (A[7:0] == 8'h02) cpu_di = oki_dout;
            else if (A[7:0] == 8'h06) cpu_di = latch;
        end
    end
endmodule
`default_nettype wire
