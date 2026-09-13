`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    ddc_frontend_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    DDC (digital down-converter) front end: ADC format aligner,
//                 a mode-selectable pair of mixer paths (fixed Fs/4 or NCO),
//                 per-channel CIC decimators, and per-channel FIR channel
//                 filters, producing baseband I/Q at the decimated rate.
//
// Dependencies:   Instantiates adc_format_aligner.v (u_aligner), ddc_fs4_mixer.v
//                 (u_fs4_mixer), ddc_nco_cmix.v (u_flex_mixer),
//                 cic_decimator_4th_order.v (u_cic_i, u_cic_q), and
//                 fir_csd_filter.v (u_fir_i, u_fir_q). Instantiated by
//                 trex1_rx_frontend_top.v (u_ddc).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
//
// Changes from previous version (12-bit LO LUT upgrade):
//   - cos_lo, sin_lo ports: signed [9:0] -> signed [11:0]
//   - i_out_flex, q_out_flex: signed [20:0] -> signed [22:0]
//   - i_mixer_int, q_mixer_int: signed [20:0] -> signed [22:0]
//   - CIC d_in port: signed [20:0] -> signed [22:0]
//     (requires cic_decimator_4th_order to accept 23-bit input;
//      its internal integrators widen from 36-bit to 38-bit accordingly)
//
// Debug probe outputs added (for ILA observation in the wrapper):
//   - mixer_i_out / mixer_q_out : raw mixer output before CIC
//   - cic_i_out   / cic_q_out   : CIC output before FIR
// ============================================================================

module ddc_frontend_top (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire [1:0]         adc_res_sel,
    input  wire [9:0]         raw_i_in,
    input  wire [9:0]         raw_q_in,
    input  wire               mode_sel,
    input  wire [23:0]        fcw,
    input  wire signed [11:0] cos_lo,
    input  wire signed [11:0] sin_lo,
    input  wire [3:0]         decimation_rate,

    // Debug probes - internal pipeline taps for ILA observation
    output wire signed [22:0] mixer_i_out,
    output wire signed [22:0] mixer_q_out,
    output wire signed [23:0] cic_i_out,
    output wire signed [23:0] cic_q_out,

    output wire        [23:0] phase_out,
    output wire               baseband_valid_out,
    output wire signed [23:0] i_out_baseband,
    output wire signed [23:0] q_out_baseband
);

    // -----------------------------------------------------------------------
    // ADC format aligner (output always 10-bit signed)
    // -----------------------------------------------------------------------
    wire signed [9:0] i_aligned, q_aligned;
    adc_format_aligner u_aligner (
        .adc_res_sel(adc_res_sel),
        .raw_i_in   (raw_i_in),
        .raw_q_in   (raw_q_in),
        .i_aligned  (i_aligned),
        .q_aligned  (q_aligned)
    );

    // -----------------------------------------------------------------------
    // fs/4 mixer (11-bit signed output)
    // -----------------------------------------------------------------------
    wire signed [10:0] i_out_fs4, q_out_fs4;
    ddc_fs4_mixer u_fs4_mixer (
        .clk   (clk),
        .rst_n (rst_n),
        .enable(enable),
        .i_in  (i_aligned),
        .q_in  (q_aligned),
        .i_out (i_out_fs4),
        .q_out (q_out_fs4)
    );

    // -----------------------------------------------------------------------
    // NCO + complex mixer (23-bit signed output, 12-bit LO)
    // -----------------------------------------------------------------------
    wire signed [22:0] i_out_flex, q_out_flex;
    ddc_nco_cmix u_flex_mixer (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .fcw      (fcw),
        .i_in     (i_aligned),
        .q_in     (q_aligned),
        .cos_lo   (cos_lo),
        .sin_lo   (sin_lo),
        .phase_out(phase_out),
        .i_out    (i_out_flex),
        .q_out    (q_out_flex)
    );

    // -----------------------------------------------------------------------
    // Mixer output mux. fs/4 path sign-extended; NCO path direct.
    // -----------------------------------------------------------------------
    wire signed [22:0] i_mixer_int = (mode_sel == 1'b0)
                                   ? {{12{i_out_fs4[10]}}, i_out_fs4}
                                   : i_out_flex;
    wire signed [22:0] q_mixer_int = (mode_sel == 1'b0)
                                   ? {{12{q_out_fs4[10]}}, q_out_fs4}
                                   : q_out_flex;

    // Debug probe - tap mixer output for ILA observation
    assign mixer_i_out = i_mixer_int;
    assign mixer_q_out = q_mixer_int;

    // -----------------------------------------------------------------------
    // CIC decimators - one per channel.
    // -----------------------------------------------------------------------
    wire cic_valid_i, cic_valid_q;
    wire signed [23:0] i_cic_int, q_cic_int;

    cic_decimator_4th_order u_cic_i (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .rate     (decimation_rate),
        .d_in     (i_mixer_int),
        .valid_out(cic_valid_i),
        .d_out    (i_cic_int)
    );
    cic_decimator_4th_order u_cic_q (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .rate     (decimation_rate),
        .d_in     (q_mixer_int),
        .valid_out(cic_valid_q),
        .d_out    (q_cic_int)
    );

    // Debug probe - tap CIC output for ILA observation
    assign cic_i_out = i_cic_int;
    assign cic_q_out = q_cic_int;

    // -----------------------------------------------------------------------
    // Decimation strobe from I-channel CIC drives both FIR filters.
    // -----------------------------------------------------------------------
    wire decimation_strobe = cic_valid_i;
    assign baseband_valid_out = decimation_strobe;

    // -----------------------------------------------------------------------
    // FIR channel filters (73-tap)
    // -----------------------------------------------------------------------
    fir_csd_filter u_fir_i (
        .clk   (clk),
        .rst_n (rst_n),
        .enable(decimation_strobe),
        .d_in  (i_cic_int),
        .d_out (i_out_baseband)
    );
    fir_csd_filter u_fir_q (
        .clk   (clk),
        .rst_n (rst_n),
        .enable(decimation_strobe),
        .d_in  (q_cic_int),
        .d_out (q_out_baseband)
    );

endmodule
