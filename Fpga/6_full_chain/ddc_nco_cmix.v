`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    ddc_nco_cmix
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    24-bit NCO phase accumulator driving an external DDS LO
//                 LUT, plus the complex mixer that multiplies the ADC I/Q by
//                 the resulting cos/sin. Implements the lower-sideband
//                 (difference-frequency) mixing convention - see the design
//                 note below for the sign derivation and bit-width rationale.
//
// Dependencies:   Instantiated by ddc_frontend_top.v (u_flex_mixer).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : ddc_nco_cmix
// Description : 24-bit NCO phase accumulator + complex mixer.
//               LO sin/cos ports widened from 10-bit to 12-bit to match the
//               upgraded Xilinx DDS LO LUT (12-bit output, ~72 dB SFDR vs
//               ~60 dB for the previous 10-bit configuration).
//
// Changes from previous version:
//   - cos_lo, sin_lo : widened from signed [9:0] to signed [11:0]
//   - i_cos, i_sin, q_cos, q_sin: widened from [19:0] to [21:0]
//     (10b x 12b product = 22b signed, so [21:0] is exact)
//   - i_out, q_out: widened from signed [20:0] to signed [22:0]
//     (sum of two 22-bit products needs 23 bits for overflow safety)
//
// Mixer sign convention (lower sideband, negative-frequency LO):
//   I_out = I*cos_lo - Q*sin_lo
//   Q_out = Q*cos_lo + I*sin_lo
// With a backward-spinning NCO (negative FCW), sin_lo from the DDS LUT
// carries a built-in negation (sin(-wt) = -sin(wt)), so the equations above
// correctly select the difference frequency (f_in - |f_LO|).
//
// Frequency resolution: f_res = Fs / 2^24 = 10 MHz / 16777216 = 0.596 Hz/LSB
// ============================================================================

module ddc_nco_cmix (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire        [23:0] fcw,
    input  wire signed [9:0]  i_in,
    input  wire signed [9:0]  q_in,
    input  wire signed [11:0] cos_lo,     // 12-bit LO cosine  (was 10-bit)
    input  wire signed [11:0] sin_lo,     // 12-bit LO sine    (was 10-bit)

    output reg         [23:0] phase_out,
    output reg  signed [22:0] i_out,      // was [20:0]
    output reg  signed [22:0] q_out       // was [20:0]
);

    // 24-bit phase accumulator
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase_out <= 24'd0;
        else if (enable) phase_out <= phase_out + fcw;
    end

    // Pipeline stage 1: four 10b x 12b = 22b products
    reg signed [21:0] i_cos, i_sin, q_cos, q_sin;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_cos <= 22'd0; i_sin <= 22'd0;
            q_cos <= 22'd0; q_sin <= 22'd0;
            i_out <= 23'd0; q_out <= 23'd0;
        end else if (enable) begin
            // Stage 1: register all four products
            i_cos <= i_in * cos_lo;
            i_sin <= i_in * sin_lo;
            q_cos <= q_in * cos_lo;
            q_sin <= q_in * sin_lo;

            // Stage 2: cross-add using registered products from stage 1
            // Lower-sideband (difference frequency) selection:
            i_out <= i_cos - q_sin;
            q_out <= q_cos + i_sin;
        end
    end

endmodule
