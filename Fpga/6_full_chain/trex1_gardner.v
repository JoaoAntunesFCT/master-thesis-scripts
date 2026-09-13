`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_gardner
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Gardner timing-error detector (TED). Maintains a 3-sample
//                 (early/mid/late) sliding window over the interpolated I/Q
//                 stream and computes the classic non-data-aided Gardner error
//                 term error = I_mid*(I_early-I_late) + Q_mid*(Q_early-Q_late),
//                 which is zero when the mid tap sits exactly on-time between
//                 two symbols and takes the sign of the timing offset otherwise.
//
// Dependencies:   Not currently instantiated anywhere in this project.
//                 trex1_str_top.v (Rev 4) implements the identical Gardner TED
//                 arithmetic inline, as one stage of its pipelined symbol
//                 timing recovery loop, rather than instantiating this module.
//                 Kept as a standalone, easier-to-verify reference for the TED
//                 math.
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_gardner #(
    parameter DATA_WIDTH = 12
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,

    output reg signed [(2*DATA_WIDTH):0] error_out,
    output reg error_valid
);

    // 3-Sample FIFO (Early, Mid, Late)
    reg signed [DATA_WIDTH-1:0] f_i [0:2];
    reg signed [DATA_WIDTH-1:0] f_q [0:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_i[0]<=0; f_i[1]<=0; f_i[2]<=0;
            f_q[0]<=0; f_q[1]<=0; f_q[2]<=0;
            error_valid <= 0;
        end else if (valid_in) begin
            f_i[2] <= i_in; f_i[1] <= f_i[2]; f_i[0] <= f_i[1];
            f_q[2] <= q_in; f_q[1] <= f_q[2]; f_q[0] <= f_q[1];
            error_valid <= 1'b1;
        end else begin
            error_valid <= 1'b0;
        end
    end

    // Error = I_mid * (I_early - I_late) + Q_mid * (Q_early - Q_late)
    // f_i[0]/f_q[0] = early (oldest), f_i[1]/f_q[1] = mid, f_i[2]/f_q[2] = late (newest)
    wire signed [DATA_WIDTH:0] diff_i = f_i[0] - f_i[2];
    wire signed [DATA_WIDTH:0] diff_q = f_q[0] - f_q[2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) error_out <= 0;
        else if (valid_in) error_out <= (f_i[1] * diff_i) + (f_q[1] * diff_q);
    end
endmodule
