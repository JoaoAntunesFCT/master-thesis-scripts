`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    ddc_fs4_mixer
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Fixed-frequency complex mixer that multiplies the aligned ADC
//                 I/Q samples by e^{-j*pi/2*n}, shifting the input spectrum down
//                 by exactly Fs/4 (25 MHz at Fs = 100 MHz). Multiplier-free:
//                 implemented as a 4-state sign/swap sequencer.
//
// Dependencies:   Instantiated by ddc_frontend_top.v (u_fs4_mixer) as one of
//                 the two selectable mixer paths (fs/4 fixed-shift vs the
//                 tunable ddc_nco_cmix.v). No sub-module instantiations.
//
//////////////////////////////////////////////////////////////////////////////////

// ============================================================================
// Shift direction: -Fs/4 (-25 MHz)
//   Input at f_in -> baseband output at (f_in - 25 MHz)
//   Designed for signals near +25 MHz (e.g. 24.9 MHz -> -100 kHz baseband)
//
// Sequence table (correct -Fs/4):
//   n mod 4 = 0 : multiply by +1  -> ( I,  Q)
//   n mod 4 = 1 : multiply by -j  -> ( Q, -I)
//   n mod 4 = 2 : multiply by -1  -> (-I, -Q)
//   n mod 4 = 3 : multiply by +j  -> (-Q,  I)
//
// Original bug: states 1 and 3 were swapped, implementing +Fs/4 instead of
// -Fs/4. Input at 24.9 MHz was shifted to +49.9 MHz, aliasing to an
// out-of-band frequency after CIC decimation -> ~-130 dBFS output.
//
// Bit widths:
//   i_in / q_in  : 10-bit signed (ADC resolution)
//   i_out / q_out: 11-bit signed (one guard bit for two's complement negation)
//
// Latency: 1 clock cycle (registered output)
// ============================================================================

module ddc_fs4_mixer (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire signed [9:0]  i_in,
    input  wire signed [9:0]  q_in,
    output reg  signed [10:0] i_out,
    output reg  signed [10:0] q_out
);

    reg [1:0] seq_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq_cnt <= 2'b00;
            i_out   <= 11'd0;
            q_out   <= 11'd0;
        end else if (enable) begin
            seq_cnt <= seq_cnt + 1'b1;
            case (seq_cnt)
                //                                  Multiplier
                2'b00: begin i_out <=  i_in;  q_out <=  q_in;  end  // x +1
                2'b01: begin i_out <=  q_in;  q_out <= -i_in;  end  // x -j
                2'b10: begin i_out <= -i_in;  q_out <= -q_in;  end  // x -1
                2'b11: begin i_out <= -q_in;  q_out <=  i_in;  end  // x +j
            endcase
        end
    end

endmodule
