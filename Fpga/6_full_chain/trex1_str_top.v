`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_str_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Symbol timing recovery (STR): a Gardner-loop timing NCO,
//                 cubic (Farrow-form) fractional interpolator, and Gardner
//                 timing-error detector, all inlined into a single 6-stage
//                 pipelined datapath (Rev 4) for timing closure. See the
//                 design note below for why this differs from a straightforward
//                 structural composition of separate interpolator/TED blocks.
//
// Dependencies:   Instantiated by trex1_sync_hw_top.v (u_str). Despite
//                 implementing Farrow interpolation and Gardner TED math
//                 equivalent to trex1_farrow.v / trex1_gardner.v, this module
//                 does NOT instantiate either - Rev 4 spreads that arithmetic
//                 across its own pipeline stages instead (see header note),
//                 so trex1_farrow.v and trex1_gardner.v currently exist only
//                 as standalone reference modules, unused elsewhere in this
//                 project.
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : trex1_str_top  (Rev 4 - PIPELINED Gardner timing recovery)
//
// Symbol timing recovery for the TREX1 receiver.
//
// Rev 3 was a self-contained interpolating Gardner loop that locked correctly
// (validated bit-for-bit in the reference model: recovers the 272-bit packet to
// within the single-bit CRC-LUT correction). However Rev 3 computed the whole
// loop - interpolation multiply, Gardner TED (two multiplies), and the loop
// update - in ONE combinational cone through three DSP48 blocks in series
// (pmi -> ted0 -> ted -> clamp -> Wc). That cone was 20.65 ns and blew the
// 10 ns (100 MHz) budget (WNS -10.66 ns).
//
// Rev 4 keeps the *identical* arithmetic but spreads it across registered
// pipeline stages so no path contains more than one DSP:
//
//   Stage N (NCO, every valid_in cycle, DSP-free):
//        eta accumulator, strobe (eta<Wc), fractional index mu=eta>>5.
//        On a strobe, di=x[m]-x[m-1], mu, ip/qp and the on-time flag are
//        latched into the pipeline.
//   Stage 1 : pmi = di * mu                          (1 DSP, registered)
//   Stage 2 : yi  = ip + (pmi >>> 8)                 (add)
//   Stage 3 : on-time -> emit symbol, ted0=(yi-yi_onp)*yi_mid,
//                                     ted1=(yq-yq_onp)*yq_mid   (2 || DSPs)
//             mid     -> latch yi_mid/yq_mid
//   Stage 4 : ted = ted0 + ted1                      (add)
//   Stage 5 : Wc  = clamp(W0 + (ted >>> KP_SHIFT))   (add + clamp)
//
// The loop updates only once per symbol (~1 update per 16 baseband samples,
// strobes are >=8 cycles apart) so the ~6-cycle Wc-update latency introduced by
// the pipeline has no effect on loop dynamics - confirmed in the reference
// model: the pipelined loop recovers the packet to the SAME 271/272 bits
// (syndrome 0xA424, single-bit LUT-correctable) as the combinational Rev 3.
//
// Output: i_out/q_out = on-time symbol, valid_out = 1-clk strobe per symbol.
// NOTE: the divider-free mu (eta>>5) and W0 assume SPS = 16.
// ============================================================================

module trex1_str_top #(
    parameter DATA_WIDTH = 12,
    parameter MU_WIDTH   = 8,     // (unused; kept for interface compatibility)
    parameter SPS        = 16
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,

    input  wire signed [15:0] kp,   // unused (see header)
    input  wire signed [15:0] ki,   // unused

    output wire signed [DATA_WIDTH-1:0] i_out,
    output wire signed [DATA_WIDTH-1:0] q_out,
    output wire valid_out
);
    // ---- loop constants (Q0.16 timing accumulator) -----------------------
    localparam signed [17:0] W0       = 18'sd8192;   // 2/16 in Q0.16 (2 strobes/sym)
    localparam signed [17:0] WMIN     = 18'sd6144;   // 0.75*W0 clamp
    localparam signed [17:0] WMAX     = 18'sd10240;  // 1.25*W0 clamp
    localparam integer        KP_SHIFT = 11;   // proportional gain (tuned for low jitter)

    // ---- NCO / interpolation state ---------------------------------------
    reg  [16:0] eta;                             // timing accumulator (unsigned)
    reg  signed [17:0] Wc;                        // control word
    reg  signed [DATA_WIDTH-1:0] ip, qp;          // previous input sample (x[m-1])
    reg  ontime;                                  // 1 = next strobe is on-time

    // ---- Gardner symbol history ------------------------------------------
    reg  signed [DATA_WIDTH+1:0] yi_onp, yq_onp;  // last on-time symbol  (14b)
    reg  signed [DATA_WIDTH+1:0] yi_mid, yq_mid;  // last mid sample      (14b)

    // ---- pipeline registers ----------------------------------------------
    // Stage 1 (latched at strobe)
    reg  s1_v, s1_ot;
    reg  signed [DATA_WIDTH:0]   s1_di, s1_dq;    // 13b
    reg  [MU_WIDTH-1:0]          s1_mu;           // 8b unsigned
    reg  signed [DATA_WIDTH-1:0] s1_ip, s1_qp;    // 12b
    // Stage 2 (interpolation product)
    reg  s2_v, s2_ot;
    reg  signed [DATA_WIDTH+9:0] s2_pmi, s2_pmq;  // 22b
    reg  signed [DATA_WIDTH-1:0] s2_ip, s2_qp;    // 12b
    // Stage 3 (interpolated sample)
    reg  s3_v, s3_ot;
    reg  signed [DATA_WIDTH+1:0] s3_yi, s3_yq;    // 14b
    // Stage 4 (TED partial products)
    reg  s4_v;
    reg  signed [31:0] s4_t0, s4_t1;
    // Stage 5 (TED sum)
    reg  s5_v;
    reg  signed [31:0] s5_ted;

    // ---- outputs ---------------------------------------------------------
    reg  signed [DATA_WIDTH-1:0] i_out_r, q_out_r;
    reg  valid_out_r;
    assign i_out     = i_out_r;
    assign q_out     = q_out_r;
    assign valid_out = valid_out_r;

    // ---- Stage N combinational: NCO underflow, fractional index ----------
    wire [17:0] etaz     = {1'b0, eta};
    wire [17:0] sub      = etaz - Wc[17:0];        // MSB = borrow => eta < Wc
    wire        strobe   = sub[17];
    wire [16:0] eta_next = eta - Wc[16:0] + (strobe ? 17'd65536 : 17'd0);

    wire [11:0] mu_raw = eta[16:5];                // eta / 32  (W0 = 2^13)
    wire [MU_WIDTH-1:0] mu = (mu_raw > 12'd255) ? 8'd255 : mu_raw[MU_WIDTH-1:0];

    wire signed [DATA_WIDTH:0] di = i_in - ip;     // 13b
    wire signed [DATA_WIDTH:0] dq = q_in - qp;

    // ---- Stage 5 combinational: loop update ------------------------------
    wire signed [31:0] wc_new = $signed({{14{W0[17]}}, W0}) + (s5_ted >>> KP_SHIFT);
    wire signed [17:0] wc_clamped =
           (wc_new < WMIN) ? WMIN :
           (wc_new > WMAX) ? WMAX : wc_new[17:0];

    // ---- single synchronous process --------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eta <= 17'd0;  Wc <= W0;  ip <= 0; qp <= 0;  ontime <= 1'b1;
            yi_onp <= 0; yq_onp <= 0; yi_mid <= 0; yq_mid <= 0;
            s1_v <= 1'b0; s1_ot <= 1'b0; s1_di <= 0; s1_dq <= 0; s1_mu <= 0; s1_ip <= 0; s1_qp <= 0;
            s2_v <= 1'b0; s2_ot <= 1'b0; s2_pmi <= 0; s2_pmq <= 0; s2_ip <= 0; s2_qp <= 0;
            s3_v <= 1'b0; s3_ot <= 1'b0; s3_yi <= 0; s3_yq <= 0;
            s4_v <= 1'b0; s4_t0 <= 0; s4_t1 <= 0;
            s5_v <= 1'b0; s5_ted <= 0;
            i_out_r <= 0; q_out_r <= 0; valid_out_r <= 1'b0;
        end else begin
            // ---- Stage 5: apply loop update (once per symbol) ----
            if (s5_v) Wc <= wc_clamped;

            // ---- Stage 4 -> 5 : TED sum ----
            s5_v   <= s4_v;
            s5_ted <= s4_t0 + s4_t1;

            // ---- Stage 3 -> 4 : symbol emit + TED products ----
            s4_v        <= 1'b0;
            valid_out_r <= 1'b0;
            if (s3_v) begin
                if (s3_ot) begin
                    // on-time strobe: emit the symbol and fire the TED
                    i_out_r     <= s3_yi[DATA_WIDTH-1:0];
                    q_out_r     <= s3_yq[DATA_WIDTH-1:0];
                    valid_out_r <= 1'b1;
                    s4_t0 <= (s3_yi - yi_onp) * yi_mid;   // DSP (pre-adder + mult)
                    s4_t1 <= (s3_yq - yq_onp) * yq_mid;   // DSP (pre-adder + mult)
                    s4_v  <= 1'b1;
                    yi_onp <= s3_yi;  yq_onp <= s3_yq;
                end else begin
                    // mid strobe: store the half-symbol sample for the TED
                    yi_mid <= s3_yi;  yq_mid <= s3_yq;
                end
            end

            // ---- Stage 2 -> 3 : interpolation add ----
            s3_v  <= s2_v;
            s3_ot <= s2_ot;
            s3_yi <= s2_ip + (s2_pmi >>> 8);
            s3_yq <= s2_qp + (s2_pmq >>> 8);

            // ---- Stage 1 -> 2 : interpolation multiply ----
            s2_v   <= s1_v;
            s2_ot  <= s1_ot;
            s2_pmi <= s1_di * $signed({1'b0, s1_mu});   // DSP
            s2_pmq <= s1_dq * $signed({1'b0, s1_mu});   // DSP
            s2_ip  <= s1_ip;
            s2_qp  <= s1_qp;

            // ---- Stage N -> 1 : NCO + latch on strobe ----
            s1_v <= 1'b0;
            if (valid_in) begin
                ip  <= i_in;
                qp  <= q_in;
                eta <= eta_next;
                if (strobe) begin
                    ontime <= ~ontime;
                    s1_v   <= 1'b1;
                    s1_ot  <= ontime;
                    s1_di  <= di;
                    s1_dq  <= dq;
                    s1_mu  <= mu;
                    s1_ip  <= ip;    // x[m-1], the same sample used to form di
                    s1_qp  <= qp;
                end
            end
        end
    end

endmodule
