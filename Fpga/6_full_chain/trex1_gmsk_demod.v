`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_gmsk_demod
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    GMSK cross-product (differential) frequency discriminator.
//                 Cross-multiplies the current symbol against the previous one
//                 (Q[n]*I[n-1] - I[n]*Q[n-1], proportional to sin of the phase
//                 change between symbols) and hard-slices the sign of that
//                 frequency-deviation term to recover the transmitted bit -
//                 the standard non-coherent GMSK/MSK demodulation technique.
//
// Dependencies:   Instantiated by trex1_rx_frontend_top.v (u_gmsk_demod),
//                 fed by the symbol-rate output of trex1_sync_hw_top.v (STR).
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_gmsk_demod #(
    parameter DATA_WIDTH = 12
)(
    input  wire clk,
    input  wire rst_n,

    // Inputs from Symbol Timing Recovery (STR)
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,

    // Hard-Decision Bit Output
    output reg  rx_bit_out,
    output reg  valid_out,

    // Debug Output (The raw Frequency Deviation)
    output reg signed [(2*DATA_WIDTH):0] freq_dev_out
);

    // 1-Symbol Delay Line
    reg signed [DATA_WIDTH-1:0] i_prev;
    reg signed [DATA_WIDTH-1:0] q_prev;
    reg delay_valid;

    // Cross-Multiplication Registers (Pipeline Stage 1)
    reg signed [(2*DATA_WIDTH)-1:0] cross_q_i; // Q[n] * I[n-1]
    reg signed [(2*DATA_WIDTH)-1:0] cross_i_q; // I[n] * Q[n-1]
    reg mult_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_prev <= 0;
            q_prev <= 0;
            cross_q_i <= 0;
            cross_i_q <= 0;
            delay_valid <= 0;
            mult_valid <= 0;
        end else if (valid_in) begin
            // Shift current symbol into previous
            i_prev <= i_in;
            q_prev <= q_in;
            delay_valid <= 1'b1;

            // If we have a previous symbol, perform the cross multiplications
            if (delay_valid) begin
                cross_q_i <= q_in * i_prev;
                cross_i_q <= i_in * q_prev;
                mult_valid <= 1'b1;
            end
        end else begin
            mult_valid <= 1'b0;
        end
    end

    // Subtractor and Hard-Decision Slicer (Pipeline Stage 2)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            freq_dev_out <= 0;
            rx_bit_out <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= mult_valid;
            if (mult_valid) begin
                // freq_dev = Q_curr * I_prev - I_curr * Q_prev
                freq_dev_out <= cross_q_i - cross_i_q;

                // Slicer: Hard Decision
                // If frequency deviation > 0, output '1', else output '0'.
                // (The earlier inversion was a mis-diagnosis; the reference
                //  model confirms non-inverted polarity once the STR locks.)
                if ((cross_q_i - cross_i_q) > 0) begin
                    rx_bit_out <= 1'b1;
                end else begin
                    rx_bit_out <= 1'b0;
                end
            end
        end
    end

endmodule
