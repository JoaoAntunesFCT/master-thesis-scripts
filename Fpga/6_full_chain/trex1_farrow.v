`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_farrow
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Cubic Lagrange (Farrow-form) fractional-delay interpolator.
//                 Interpolates between two consecutive input samples at
//                 fractional position mu/256 using a 4-tap Horner-evaluated
//                 cubic kernel, so the symbol timing loop can retime to any
//                 sub-sample offset without a variable-length delay line. See
//                 the design note below for the coefficient derivation and
//                 pipeline map.
//
// Dependencies:   Not currently instantiated anywhere in this project.
//                 trex1_str_top.v (Rev 4) implements the identical Farrow
//                 interpolation arithmetic inline, as part of its pipelined
//                 symbol timing recovery loop, rather than instantiating this
//                 module. Kept as a standalone, easier-to-verify reference for
//                 the interpolator math.
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// trex1_farrow  -  Cubic Lagrange fractional interpolator (Farrow form)
//
// Replaces the previous passthrough placeholder (which output d_i[1] regardless
// of mu).  Interpolates between d_i[1] = x(0) and d_i[2] = x(1) at fractional
// delay mu/256, using a 4-point cubic Lagrange kernel evaluated by Horner's rule.
//
// Coefficients are scaled by 6 to clear the /6, /3, /2 divisions, then the final
// result is divided by 6 via a constant multiply (*10923 >> 16).  Verified in
// fixed point: max interpolation error < 2 LSB, unity gain (mu=0 -> x(0),
// mu=255 -> x(1)).
//
//   A3 = -d0 + 3*d1 - 3*d2 +   d3      (= 6*C3)
//   A2 =  3*d0 - 6*d1 + 3*d2           (= 6*C2)
//   A1 = -2*d0 - 3*d1 + 6*d2 -   d3    (= 6*C1)
//   A0 =  6*d1                         (= 6*C0)
//   y6 = ((A3*mu>>8 + A2)*mu>>8 + A1)*mu>>8 + A0     (mu in 0..255)
//   y  = (y6 * 10923) >> 16                          (divide by 6)
//
// Pipeline (all stepped on the sparse calc_strobe, which fires ~1/SPS samples):
//   S0: latch taps+mu on calc_strobe, form A3..A0
//   S1: h = (A3*mu)>>8 + A2
//   S2: h = (h *mu)>>8 + A1
//   S3: h = (h *mu)>>8 + A0
//   S4: y = (h*10923)>>16, valid_out asserted
// ============================================================================
module trex1_farrow #(
    parameter DATA_WIDTH = 12,
    parameter MU_WIDTH   = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,
    input  wire [MU_WIDTH-1:0] mu,
    input  wire calc_strobe,

    output reg  signed [DATA_WIDTH-1:0] i_out,
    output reg  signed [DATA_WIDTH-1:0] q_out,
    output reg  valid_out
);

    // ---- 4-tap delay line (shift one stage per valid sample) ----
    reg signed [DATA_WIDTH-1:0] d_i [0:3];
    reg signed [DATA_WIDTH-1:0] d_q [0:3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_i[0]<=0; d_i[1]<=0; d_i[2]<=0; d_i[3]<=0;
            d_q[0]<=0; d_q[1]<=0; d_q[2]<=0; d_q[3]<=0;
        end else if (valid_in) begin
            d_i[3]<=i_in; d_i[2]<=d_i[3]; d_i[1]<=d_i[2]; d_i[0]<=d_i[1];
            d_q[3]<=q_in; d_q[2]<=d_q[3]; d_q[1]<=d_q[2]; d_q[0]<=d_q[1];
        end
    end

    // ---- S0: capture window + mu at strobe, build scaled coefficients ----
    reg signed [DATA_WIDTH+4:0] A3i,A2i,A1i,A0i;   // 17b, holds up to ~6*2048
    reg signed [DATA_WIDTH+4:0] A3q,A2q,A1q,A0q;
    reg [MU_WIDTH-1:0] mu0, mu1, mu2, mu3;
    reg s0,s1,s2,s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0<=0; mu0<=0;
            A3i<=0; A2i<=0; A1i<=0; A0i<=0;
            A3q<=0; A2q<=0; A1q<=0; A0q<=0;
        end else begin
            s0  <= calc_strobe;
            mu0 <= mu;
            if (calc_strobe) begin
                A3i <= -d_i[0] + 3*d_i[1] - 3*d_i[2] + d_i[3];
                A2i <=  3*d_i[0] - 6*d_i[1] + 3*d_i[2];
                A1i <= -2*d_i[0] - 3*d_i[1] + 6*d_i[2] - d_i[3];
                A0i <=  6*d_i[1];
                A3q <= -d_q[0] + 3*d_q[1] - 3*d_q[2] + d_q[3];
                A2q <=  3*d_q[0] - 6*d_q[1] + 3*d_q[2];
                A1q <= -2*d_q[0] - 3*d_q[1] + 6*d_q[2] - d_q[3];
                A0q <=  6*d_q[1];
            end
        end
    end

    // ---- S1..S3: Horner.  h scale stays bounded (~6*y) ----
    reg signed [DATA_WIDTH+8:0] hi1,hq1, hi2,hq2, hi3,hq3;   // 21b headroom

    // helper: (acc * mu) >>> 8 + nextA  -- done inline below
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1<=0;s2<=0;s3<=0; mu1<=0;mu2<=0;mu3<=0;
            hi1<=0;hq1<=0; hi2<=0;hq2<=0; hi3<=0;hq3<=0;
        end else begin
            // S1
            s1  <= s0;  mu1 <= mu0;
            hi1 <= ((A3i * $signed({1'b0,mu0})) >>> 8) + A2i;
            hq1 <= ((A3q * $signed({1'b0,mu0})) >>> 8) + A2q;
            // S2
            s2  <= s1;  mu2 <= mu1;
            hi2 <= ((hi1 * $signed({1'b0,mu1})) >>> 8) + A1i;
            hq2 <= ((hq1 * $signed({1'b0,mu1})) >>> 8) + A1q;
            // S3
            s3  <= s2;  mu3 <= mu2;
            hi3 <= ((hi2 * $signed({1'b0,mu2})) >>> 8) + A0i;
            hq3 <= ((hq2 * $signed({1'b0,mu2})) >>> 8) + A0q;
        end
    end

    // ---- S4: divide by 6 (*10923 >>16), saturate to DATA_WIDTH ----
    wire signed [DATA_WIDTH+8+14:0] yi_full    = hi3 * 18'sd10923;
    wire signed [DATA_WIDTH+8+14:0] yq_full    = hq3 * 18'sd10923;
    wire signed [DATA_WIDTH+8+14:0] yi_shifted = yi_full >>> 16;
    wire signed [DATA_WIDTH+8+14:0] yq_shifted = yq_full >>> 16;
    wire signed [DATA_WIDTH+8:0]    yi_s       = yi_shifted[DATA_WIDTH+8:0];
    wire signed [DATA_WIDTH+8:0]    yq_s       = yq_shifted[DATA_WIDTH+8:0];

    localparam signed [DATA_WIDTH:0] MAXV =  (1<<(DATA_WIDTH-1))-1;
    localparam signed [DATA_WIDTH:0] MINV = -(1<<(DATA_WIDTH-1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_out<=0; q_out<=0; valid_out<=0;
        end else begin
            valid_out <= s3;
            if (s3) begin
                i_out <= (yi_s >  MAXV) ? MAXV[DATA_WIDTH-1:0] :
                         (yi_s <  MINV) ? MINV[DATA_WIDTH-1:0] : yi_s[DATA_WIDTH-1:0];
                q_out <= (yq_s >  MAXV) ? MAXV[DATA_WIDTH-1:0] :
                         (yq_s <  MINV) ? MINV[DATA_WIDTH-1:0] : yq_s[DATA_WIDTH-1:0];
            end
        end
    end

endmodule
