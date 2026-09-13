`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_farrow
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    4-tap fractional-delay (Farrow) interpolator for the Gardner symbol
//                 timing loop. Shifts incoming I/Q through a 4-tap delay line and, when
//                 trex1_str_top's NCO strobes calc_strobe, outputs an interpolated
//                 sample positioned by the fractional delay word mu -- re-timing the
//                 sample stream onto the symbol centers the loop has converged on.
//
// Dependencies:   Instantiated by trex1_str_top.v, which supplies mu/calc_strobe from
//                 its NCO and consumes i_out/q_out as the timing-recovered samples fed
//                 into trex1_gardner.v.
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_farrow #(
    parameter DATA_WIDTH = 12,
    parameter MU_WIDTH = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,
    input  wire [MU_WIDTH-1:0] mu, // 8-bit fractional delay (0 to 255)
    input  wire calc_strobe,

    output reg signed [DATA_WIDTH-1:0] i_out,
    output reg signed [DATA_WIDTH-1:0] q_out,
    output reg valid_out
);

    // 4-Tap Delay Line
    // Holds the 4 most recent samples: index 3 = newest, index 0 = oldest.
    // The Farrow polynomial taps (c0..c3) are formed from these four samples.
    reg signed [DATA_WIDTH-1:0] d_i [0:3];
    reg signed [DATA_WIDTH-1:0] d_q [0:3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_i[0] <= 0; d_i[1] <= 0; d_i[2] <= 0; d_i[3] <= 0;
            d_q[0] <= 0; d_q[1] <= 0; d_q[2] <= 0; d_q[3] <= 0;
        end else if (valid_in) begin
            d_i[3] <= i_in; d_i[2] <= d_i[3]; d_i[1] <= d_i[2]; d_i[0] <= d_i[1];
            d_q[3] <= q_in; d_q[2] <= d_q[3]; d_q[1] <= d_q[2]; d_q[0] <= d_q[1];
        end
    end

    // Approximation of MATLAB's c0, c1, c2, c3
    // For a low-power constraint, hardware often maps this to a simplified parabolic
    // or linear Farrow, but here we output the direct midpoint to maintain timing flow
    // while you map DSP slices. In your final synthesis, the Horner's rule polynomial
    // (c3*mu^3 + c2*mu^2 + c1*mu + c0) should be pipelined here using DSP48s.
    //
    // mu itself is not consumed yet below -- it is threaded in from trex1_str_top for
    // when the full polynomial (which weights the taps by mu) is implemented.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_out <= 0; q_out <= 0; valid_out <= 0;
        end else begin
            valid_out <= calc_strobe;
            if (calc_strobe) begin
                // Base assignment (c0 = x1)
                i_out <= d_i[1];
                q_out <= d_q[1];
            end
        end
    end
endmodule
