`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_gmsk_demod
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    1-symbol-delay cross-product (quadricorrelator) FM discriminator
//                 for GMSK demodulation. For complex baseband symbol z[n] =
//                 I[n] + jQ[n], the instantaneous frequency deviation is
//                 freq_dev = Im{ z[n] * conj(z[n-1]) } = Q[n]*I[n-1] - I[n]*Q[n-1].
//                 The sign of freq_dev is the hard-decision demodulated bit
//                 (>0 -> '1', else '0'). Mirrors the MATLAB reference model
//                 gmsk_demod_model.m.
//
// Dependencies:   Instantiated by top_nexys_a7_gmsk (Nexys A7 FPGA top-level)
//                 and by tb_trex1_gmsk_demod (simulation testbench).
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

    // --- Pipeline Stage 0: 1-Symbol Delay Line ---
    // The discriminator needs both the current symbol z[n] and the previous
    // symbol z[n-1], so I/Q are latched here one valid_in cycle behind
    // i_in/q_in. delay_valid tracks whether i_prev/q_prev already hold a
    // real previous symbol (it is low for the very first valid sample after
    // reset, since there is no z[n-1] to cross with yet).
    reg signed [DATA_WIDTH-1:0] i_prev;
    reg signed [DATA_WIDTH-1:0] q_prev;
    reg delay_valid;

    // --- Pipeline Stage 1: Cross-Multiplication ---
    // Im{ z[n]*conj(z[n-1]) } = Q[n]*I[n-1] - I[n]*Q[n-1], so the two cross
    // terms are formed and registered here; the subtraction itself happens
    // one cycle later in Stage 2. Each term is the product of two
    // DATA_WIDTH-bit signed values, so it needs up to 2*DATA_WIDTH bits to
    // represent without overflow.
    reg signed [(2*DATA_WIDTH)-1:0] cross_q_i; // Q[n] * I[n-1]
    reg signed [(2*DATA_WIDTH)-1:0] cross_i_q; // I[n] * Q[n-1]
    reg mult_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_prev      <= 0;
            q_prev      <= 0;
            cross_q_i   <= 0;
            cross_i_q   <= 0;
            delay_valid <= 0;
            mult_valid  <= 0;
        end else if (valid_in) begin
            // Shift current symbol into previous
            i_prev      <= i_in;
            q_prev      <= q_in;
            delay_valid <= 1'b1;

            // If we have a previous symbol, perform the cross multiplications
            if (delay_valid) begin
                cross_q_i  <= q_in * i_prev;
                cross_i_q  <= i_in * q_prev;
                mult_valid <= 1'b1;
            end
        end else begin
            mult_valid <= 1'b0;
        end
    end

    // --- Pipeline Stage 2: Subtractor and Hard-Decision Slicer ---
    // freq_dev_out is 2*DATA_WIDTH+1 bits wide: one extra bit beyond the
    // 2*DATA_WIDTH-bit cross terms is enough to hold their difference
    // (freq_dev = cross_q_i - cross_i_q) without overflow in either sign.
    // The slicer is a simple zero-threshold comparator: GMSK/MSK symbols
    // carry no DC frequency offset, so the ideal decision boundary for the
    // instantaneous frequency deviation sits at zero.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            freq_dev_out <= 0;
            rx_bit_out   <= 0;
            valid_out    <= 0;
        end else begin
            valid_out <= mult_valid;
            if (mult_valid) begin
                // freq_dev = Q_curr * I_prev - I_curr * Q_prev
                freq_dev_out <= cross_q_i - cross_i_q;

                // Slicer: Hard Decision
                // If frequency deviation > 0, output '1', else output '0'
                if ((cross_q_i - cross_i_q) > 0) begin
                    rx_bit_out <= 1'b1;
                end else begin
                    rx_bit_out <= 1'b0;
                end
            end
        end
    end

endmodule
