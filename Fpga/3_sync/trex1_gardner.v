`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_gardner
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Gardner timing-error detector (TED). Buffers three consecutive
//                 Farrow-interpolated samples -- the alternating on-time / mid-symbol /
//                 on-time triple produced by trex1_str_top's NCO strobing twice per
//                 symbol -- and forms the classic Gardner error
//                 e = I_mid*(I_early - I_late) + Q_mid*(Q_early - Q_late).
//                 This correlates the mid-symbol (off-center) sample against the slope
//                 between the two surrounding on-time samples: the error is (ideally)
//                 zero when the on-time strobes sit exactly on the symbol centers, and
//                 its sign indicates which way the strobe timing needs to move.
//                 trex1_str_top's loop filter drives this error toward zero.
//
// Dependencies:   Instantiated by trex1_str_top.v. i_in/q_in come from trex1_farrow.v's
//                 i_out/q_out (valid_in tied to Farrow's valid_out); error_out feeds the
//                 kp/ki loop filter in trex1_str_top.v.
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
    // Newest sample shifts in at index 2 and ages down to index 0, so once the FIFO
    // has filled: f_i[0]/f_q[0] = "early" (oldest of the three), f_i[1]/f_q[1] =
    // "mid" (the middle, mid-symbol sample), f_i[2]/f_q[2] = "late" (newest).
    reg signed [DATA_WIDTH-1:0] f_i [0:2];
    reg signed [DATA_WIDTH-1:0] f_q [0:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_i[0] <= 0; f_i[1] <= 0; f_i[2] <= 0;
            f_q[0] <= 0; f_q[1] <= 0; f_q[2] <= 0;
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
    // diff_i/diff_q approximate the local slope between the two on-time samples that
    // bracket the mid-symbol sample; multiplying by the mid-symbol sample itself
    // correlates that slope with the amplitude actually seen off-center.
    wire signed [DATA_WIDTH:0] diff_i = f_i[0] - f_i[2];
    wire signed [DATA_WIDTH:0] diff_q = f_q[0] - f_q[2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) error_out <= 0;
        else if (valid_in) error_out <= (f_i[1] * diff_i) + (f_q[1] * diff_q);
    end
endmodule
