`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_cfo_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Carrier-frequency-offset (CFO) estimator front end. Wraps
//                 two trex1_blue_autocorr instances run over the preamble: a
//                 lag-1 "coarse" discriminator (unambiguous over a wide CFO
//                 range) and a lag-SPS "fine" discriminator (one symbol period,
//                 more precise but wraps sooner). Both raw autocorrelation
//                 phasors are passed downstream for CORDIC phase extraction
//                 and CFO de-rotation - this module does no phase math itself.
//
// Dependencies:   Instantiates trex1_blue_autocorr.v (x2: coarse_discriminator,
//                 fine_estimator). Instantiated by trex1_sync_hw_top.v (u_cfo).
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_cfo_top #(
    parameter DATA_WIDTH = 12,
    parameter SPS = 16,
    parameter PREAMBLE_SYMS = 32
)(
    input  wire clk,
    input  wire rst_n,

    input  wire preamble_active,
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,

    output wire signed [(2*DATA_WIDTH)+9:0] coarse_i,
    output wire signed [(2*DATA_WIDTH)+9:0] coarse_q,
    output wire coarse_valid,

    output wire signed [(2*DATA_WIDTH)+9:0] fine_i,
    output wire signed [(2*DATA_WIDTH)+9:0] fine_q,
    output wire fine_valid
);

    localparam ACCUM_LEN = PREAMBLE_SYMS * SPS;

    // 1. COARSE ESTIMATOR: Delay = 1 Sample
    trex1_blue_autocorr #(
        .DATA_WIDTH(DATA_WIDTH),
        .LAG_SAMPLES(1),
        .ACCUM_LENGTH(ACCUM_LEN)
    ) coarse_discriminator (
        .clk(clk), .rst_n(rst_n),
        .preamble_active(preamble_active), .valid_in(valid_in),
        .i_in(i_in), .q_in(q_in),
        .r_m_i(coarse_i), .r_m_q(coarse_q), .valid_out(coarse_valid)
    );

    // 2. FINE ESTIMATOR: Delay = 1 Symbol (16 Samples)
    trex1_blue_autocorr #(
        .DATA_WIDTH(DATA_WIDTH),
        .LAG_SAMPLES(SPS),
        .ACCUM_LENGTH(ACCUM_LEN)
    ) fine_estimator (
        .clk(clk), .rst_n(rst_n),
        .preamble_active(preamble_active), .valid_in(valid_in),
        .i_in(i_in), .q_in(q_in),
        .r_m_i(fine_i), .r_m_q(fine_q), .valid_out(fine_valid)
    );

endmodule
