`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_blue_autocorr
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Generic lagged autocorrelator used for carrier-frequency-
//                 offset (CFO) estimation. Delays I/Q by LAG_SAMPLES, forms the
//                 complex conjugate product of the live sample against the
//                 delayed one, and accumulates that product over ACCUM_LENGTH
//                 samples while preamble_active is held, producing
//                 r_m = sum(x[n] * conj(x[n-LAG])). The phase of r_m is
//                 proportional to the CFO times the lag (a "Blue"-style
//                 autocorrelation frequency estimator); downstream CORDIC
//                 logic extracts that phase.
//
// Dependencies:   Instantiated twice by trex1_cfo_top.v: as coarse_discriminator
//                 (LAG_SAMPLES=1, single-sample lag) and as fine_estimator
//                 (LAG_SAMPLES=SPS, one-symbol lag).
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_blue_autocorr #(
    parameter DATA_WIDTH = 12,
    parameter LAG_SAMPLES = 16,
    parameter ACCUM_LENGTH = 512
)(
    input  wire clk,
    input  wire rst_n,

    input  wire preamble_active,
    input  wire valid_in,

    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,

    output reg signed [(2*DATA_WIDTH)+9:0] r_m_i,
    output reg signed [(2*DATA_WIDTH)+9:0] r_m_q,
    output reg valid_out
);

    // Programmable Delay Line (Vivado SRL Inference)
    (* shreg_extract = "yes" *) reg signed [DATA_WIDTH-1:0] delay_line_i [0:LAG_SAMPLES-1];
    (* shreg_extract = "yes" *) reg signed [DATA_WIDTH-1:0] delay_line_q [0:LAG_SAMPLES-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LAG_SAMPLES; i = i + 1) begin
                delay_line_i[i] <= 0;
                delay_line_q[i] <= 0;
            end
        end else if (valid_in) begin
            delay_line_i[0] <= i_in;
            delay_line_q[0] <= q_in;
            for (i = 1; i < LAG_SAMPLES; i = i + 1) begin
                delay_line_i[i] <= delay_line_i[i-1];
                delay_line_q[i] <= delay_line_q[i-1];
            end
        end
    end

    wire signed [DATA_WIDTH-1:0] delayed_i = delay_line_i[LAG_SAMPLES-1];
    wire signed [DATA_WIDTH-1:0] delayed_q = delay_line_q[LAG_SAMPLES-1];

    // Complex Conjugate Multiplication
    // (i_in + j*q_in) * conj(delayed_i + j*delayed_q):
    //   real = i_in*delayed_i + q_in*delayed_q
    //   imag = q_in*delayed_i - i_in*delayed_q
    reg signed [(2*DATA_WIDTH)-1:0] mult_i_i, mult_q_q, mult_q_i, mult_i_q;
    reg mult_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_i_i <= 0; mult_q_q <= 0;
            mult_q_i <= 0; mult_i_q <= 0;
            mult_valid <= 0;
        end else if (valid_in && preamble_active) begin
            mult_i_i <= i_in * delayed_i;
            mult_q_q <= q_in * delayed_q;
            mult_q_i <= q_in * delayed_i;
            mult_i_q <= i_in * delayed_q;
            mult_valid <= 1'b1;
        end else begin
            mult_valid <= 1'b0;
        end
    end

    reg signed [(2*DATA_WIDTH):0] cross_real;
    reg signed [(2*DATA_WIDTH):0] cross_imag;
    reg cross_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cross_real <= 0; cross_imag <= 0; cross_valid <= 0;
        end else begin
            cross_real  <= mult_i_i + mult_q_q;
            cross_imag  <= mult_q_i - mult_i_q;
            cross_valid <= mult_valid;
        end
    end

    // Accumulation
    // Sums cross_real/cross_imag over exactly ACCUM_LENGTH samples (the
    // preamble length), then holds valid_out high with the final sum until
    // preamble_active drops (next preamble restarts the accumulation).
    reg [11:0] sample_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_m_i <= 0; r_m_q <= 0;
            sample_count <= 0; valid_out <= 0;
        end else if (!preamble_active) begin
            r_m_i <= 0; r_m_q <= 0;
            sample_count <= 0; valid_out <= 0;
        end else if (cross_valid) begin
            if (sample_count < ACCUM_LENGTH) begin
                r_m_i <= r_m_i + cross_real;
                r_m_q <= r_m_q + cross_imag;
                sample_count <= sample_count + 1;
                valid_out <= 1'b0;
            end else begin
                valid_out <= 1'b1;
            end
        end
    end

endmodule
