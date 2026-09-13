`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    fir_csd_filter
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    73-tap symmetric linear-phase FIR channel filter, pipelined
//                 (5 sys_clk cycles internal latency) to meet timing closure.
//                 Exploits tap symmetry with a pre-adder, then splits the
//                 37-input multiply-accumulate into two levels of partial
//                 sums so no single pipeline stage exceeds one multiply or
//                 one wide adder tree. See the timing-history note below for
//                 the revision history and the per-stage bit widths.
//
// Dependencies:   Instantiated by ddc_frontend_top.v (u_fir_i, u_fir_q - one
//                 per I/Q channel).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : fir_csd_filter
// Description : 73-tap symmetric linear-phase FIR channel filter.
//
// TIMING HISTORY:
//   Rev 1 (original): combinatorial pre-adder + multiplier in one cone.
//     WNS = -2.565 ns, TNS = -244 ns (74 paths failing - 37 tap pairs × I+Q).
//
//   Rev 2: registered pre-adders (pipe0 stage added).
//     WNS = -0.640 ns, TNS = -7.4 ns (~12 paths failing - 37-input adder tree).
//     The pre-adder fix eliminated 97% of violations but exposed the next
//     bottleneck: the 37-input binary reduction tree on 41-bit products.
//     A 37-input tree requires ceil(log2(37)) = 6 levels of carry-propagate
//     addition ≈ 6 × 1.7 ns = 10.2 ns, exceeding the 10 ns budget by 0.640 ns.
//     Only the deepest paths (top 2 levels) fail, giving ~12 violating paths.
//
//   Rev 3 (this version): 4-group partial accumulation (pipe2a + pipe2b).
//     The 37-input sum is split into 4 groups of 9-10 inputs, summed in pipe2a,
//     then the 4 partial sums are combined in pipe2b:
//
//       pipe2a: 4 partial sums (9+9+9+10 inputs)
//               Each group: ceil(log2(10)) = 4 levels ≈ 6.8 ns  → meets 10 ns
//       pipe2b: sum of 4 partials
//               ceil(log2(4)) = 2 levels ≈ 3.4 ns  → meets 10 ns
//
//     Expected result: WNS > 0, TNS = 0.
//
// PIPELINE STAGES (sys_clk cycles after enable):
//   enable  → delay_line shifts
//   pipe0   → pre_reg[j] latches   (FF → 25-bit adder → FF,  ~3 ns)
//   pipe1   → p_xx latches          (FF → 16×25 mult   → FF,  ~6-7 ns)
//   pipe2a  → partial[0..3] latch   (FF → 9/10-in tree → FF,  ~6.8 ns)
//   pipe2b  → acc latches           (FF → 4-in tree    → FF,  ~3.4 ns)
//   pipe3   → d_out latches         (FF → arithmetic shift → FF, trivial)
//
//   Total internal pipeline: 5 sys_clk cycles.
//   Minimum decimation period: 6 sys_clk cycles (dec=6). Fits with 1 cycle margin.
//   Total group delay: 73 enable-cycles + 5 sys_clk cycles.
//
// Bit widths:
//   pre_reg  : signed [24:0]  (24+24 with carry)
//   p_xx     : signed [40:0]  (16×25 product)
//   partial  : signed [44:0]  (sum of 10 × 41-bit needs 4 guard bits → 45-bit)
//   acc      : signed [46:0]  (sum of 4 × 45-bit needs 2 guard bits → 47-bit)
//   d_out    : signed [23:0]  (acc >>> 15, top 24 bits)
//
// Coefficients: Q1.15 (unchanged). DC gain ≈ 1.17 (+1.4 dB).
// ============================================================================

module fir_csd_filter (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire signed [23:0] d_in,
    output reg  signed [23:0] d_out
);

    // -----------------------------------------------------------------------
    // 73-element delay line
    // -----------------------------------------------------------------------
    reg signed [23:0] delay_line [0:72];
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k <= 72; k = k + 1)
                delay_line[k] <= 24'sd0;
        end else if (enable) begin
            delay_line[0] <= d_in;
            for (k = 1; k <= 72; k = k + 1)
                delay_line[k] <= delay_line[k-1];
        end
    end

    // -----------------------------------------------------------------------
    // Pipeline strobes: enable → pipe0 → pipe1 → pipe2a → pipe2b → pipe3
    // -----------------------------------------------------------------------
    reg pipe0, pipe1, pipe2a, pipe2b, pipe3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe0  <= 1'b0; pipe1  <= 1'b0; pipe2a <= 1'b0;
            pipe2b <= 1'b0; pipe3  <= 1'b0;
        end else begin
            pipe0  <= enable;
            pipe1  <= pipe0;
            pipe2a <= pipe1;
            pipe2b <= pipe2a;
            pipe3  <= pipe2b;
        end
    end

    // -----------------------------------------------------------------------
    // Coefficients (Q1.15, signed 16-bit, unchanged across all revisions)
    // -----------------------------------------------------------------------
    localparam signed [15:0]
        C00 =  16'sd0,
        C01 =  16'sd1,    C02 =  16'sd3,    C03 =  16'sd6,    C04 =  16'sd11,
        C05 =  16'sd17,   C06 =  16'sd23,   C07 =  16'sd30,   C08 =  16'sd35,
        C09 =  16'sd36,   C10 =  16'sd33,   C11 =  16'sd23,   C12 =  16'sd5,
        C13 = -16'sd23,   C14 = -16'sd60,   C15 = -16'sd105,  C16 = -16'sd155,
        C17 = -16'sd207,  C18 = -16'sd253,  C19 = -16'sd287,  C20 = -16'sd302,
        C21 = -16'sd288,  C22 = -16'sd240,  C23 = -16'sd150,  C24 = -16'sd15,
        C25 =  16'sd167,  C26 =  16'sd394,  C27 =  16'sd660,  C28 =  16'sd957,
        C29 =  16'sd1273, C30 =  16'sd1594, C31 =  16'sd1903, C32 =  16'sd2184,
        C33 =  16'sd2422, C34 =  16'sd2603, C35 =  16'sd2715, C36 =  16'sd2754;

    // -----------------------------------------------------------------------
    // PIPE0: register pre-adder outputs
    //   Path: delay_line FF → 25-bit adder → pre_reg FF  (~3 ns)
    //   Exploits linear-phase (symmetric) tap coefficients: since
    //   C[j] == C[72-j], each pair of taps can share a single multiply by
    //   pre-adding the two symmetric delay-line samples first, halving the
    //   number of multipliers needed.
    // -----------------------------------------------------------------------
    reg signed [24:0] pre_reg [0:35];
    reg signed [24:0] centre_reg;
    genvar j;
    generate
        for (j = 0; j <= 35; j = j + 1) begin : gen_pre_reg
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) pre_reg[j] <= 25'sd0;
                else if (pipe0)
                    pre_reg[j] <= delay_line[j] + delay_line[72-j];
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) centre_reg <= 25'sd0;
        else if (pipe0) centre_reg <= {delay_line[36][23], delay_line[36]};
    end

    // -----------------------------------------------------------------------
    // PIPE1: register all 37 products
    //   Path: pre_reg FF → 16×25 multiplier → p_xx FF  (~6-7 ns)
    // -----------------------------------------------------------------------
    reg signed [40:0] p00, p01, p02, p03, p04, p05, p06, p07, p08, p09;
    reg signed [40:0] p10, p11, p12, p13, p14, p15, p16, p17, p18, p19;
    reg signed [40:0] p20, p21, p22, p23, p24, p25, p26, p27, p28, p29;
    reg signed [40:0] p30, p31, p32, p33, p34, p35, p36;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p00<=41'sd0; p01<=41'sd0; p02<=41'sd0; p03<=41'sd0; p04<=41'sd0;
            p05<=41'sd0; p06<=41'sd0; p07<=41'sd0; p08<=41'sd0; p09<=41'sd0;
            p10<=41'sd0; p11<=41'sd0; p12<=41'sd0; p13<=41'sd0; p14<=41'sd0;
            p15<=41'sd0; p16<=41'sd0; p17<=41'sd0; p18<=41'sd0; p19<=41'sd0;
            p20<=41'sd0; p21<=41'sd0; p22<=41'sd0; p23<=41'sd0; p24<=41'sd0;
            p25<=41'sd0; p26<=41'sd0; p27<=41'sd0; p28<=41'sd0; p29<=41'sd0;
            p30<=41'sd0; p31<=41'sd0; p32<=41'sd0; p33<=41'sd0; p34<=41'sd0;
            p35<=41'sd0; p36<=41'sd0;
        end else if (pipe1) begin
            p00 <= C00 * pre_reg[ 0]; p01 <= C01 * pre_reg[ 1];
            p02 <= C02 * pre_reg[ 2]; p03 <= C03 * pre_reg[ 3];
            p04 <= C04 * pre_reg[ 4]; p05 <= C05 * pre_reg[ 5];
            p06 <= C06 * pre_reg[ 6]; p07 <= C07 * pre_reg[ 7];
            p08 <= C08 * pre_reg[ 8]; p09 <= C09 * pre_reg[ 9];
            p10 <= C10 * pre_reg[10]; p11 <= C11 * pre_reg[11];
            p12 <= C12 * pre_reg[12]; p13 <= C13 * pre_reg[13];
            p14 <= C14 * pre_reg[14]; p15 <= C15 * pre_reg[15];
            p16 <= C16 * pre_reg[16]; p17 <= C17 * pre_reg[17];
            p18 <= C18 * pre_reg[18]; p19 <= C19 * pre_reg[19];
            p20 <= C20 * pre_reg[20]; p21 <= C21 * pre_reg[21];
            p22 <= C22 * pre_reg[22]; p23 <= C23 * pre_reg[23];
            p24 <= C24 * pre_reg[24]; p25 <= C25 * pre_reg[25];
            p26 <= C26 * pre_reg[26]; p27 <= C27 * pre_reg[27];
            p28 <= C28 * pre_reg[28]; p29 <= C29 * pre_reg[29];
            p30 <= C30 * pre_reg[30]; p31 <= C31 * pre_reg[31];
            p32 <= C32 * pre_reg[32]; p33 <= C33 * pre_reg[33];
            p34 <= C34 * pre_reg[34]; p35 <= C35 * pre_reg[35];
            p36 <= C36 * centre_reg;
        end
    end

    // -----------------------------------------------------------------------
    // PIPE2a: 4 partial sums (groups of 9-10 products)
    //   Path: p_xx FF → 9/10-input 41-bit adder tree → partial FF  (~6.8 ns)
    //   4 levels of binary reduction → easily meets 10 ns.
    //
    //   Group 0: p00..p08  (9 inputs → 45-bit partial)
    //   Group 1: p09..p17  (9 inputs → 45-bit partial)
    //   Group 2: p18..p26  (9 inputs → 45-bit partial)
    //   Group 3: p27..p36  (10 inputs → 45-bit partial)  ← includes centre (p36)
    // -----------------------------------------------------------------------
    reg signed [44:0] partial0, partial1, partial2, partial3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            partial0 <= 45'sd0; partial1 <= 45'sd0;
            partial2 <= 45'sd0; partial3 <= 45'sd0;
        end else if (pipe2a) begin
            partial0 <= p00 + p01 + p02 + p03 + p04 + p05 + p06 + p07 + p08;
            partial1 <= p09 + p10 + p11 + p12 + p13 + p14 + p15 + p16 + p17;
            partial2 <= p18 + p19 + p20 + p21 + p22 + p23 + p24 + p25 + p26;
            partial3 <= p27 + p28 + p29 + p30 + p31 + p32 + p33 + p34 + p35 + p36;
        end
    end

    // -----------------------------------------------------------------------
    // PIPE2b: final accumulation of 4 partial sums
    //   Path: partial FF → 4-input 45-bit adder (2 levels) → acc FF  (~3.4 ns)
    // -----------------------------------------------------------------------
    reg signed [46:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc <= 47'sd0;
        else if (pipe2b)
            acc <= partial0 + partial1 + partial2 + partial3;
    end

    // -----------------------------------------------------------------------
    // PIPE3: output register with Q1.15 scaling
    //   Each product p_xx = C[coefficient, Q1.15] * pre_reg[sample]; the
    //   >>>15 (via bit-select acc[38:15]) undoes the coefficients' Q1.15
    //   fixed-point scaling, leaving d_out in the same integer domain as
    //   d_in (up to the filter's own passband gain - see DC gain note above).
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) d_out <= 24'sd0;
        else if (pipe3) d_out <= acc[38:15];
    end

endmodule
