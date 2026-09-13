`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_sync_hw_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Synchronization chain for the TREX1 receiver: chains
//                 feed-forward AGC -> CFO estimation -> CFO de-rotation ->
//                 symbol timing recovery (STR), taking DDC baseband samples
//                 in and delivering symbol-rate I/Q plus CFO estimator debug
//                 taps out. The preamble flag is delayed to match the AGC's
//                 pipeline latency so it stays aligned with the AGC output
//                 that the CFO estimator consumes.
//
// Dependencies:   Instantiates trex1_ff_agc.v (u_agc), trex1_cfo_top.v (u_cfo,
//                 which itself instantiates trex1_blue_autocorr.v x2),
//                 trex1_cfo_derotate.v (u_derot), and trex1_str_top.v (u_str).
//                 Instantiated by trex1_rx_frontend_top.v (u_sync).
//
//////////////////////////////////////////////////////////////////////////////////


module trex1_sync_hw_top #(
    parameter DATA_WIDTH = 12,
    parameter AGC_WINDOW = 100,
    parameter SPS = 16,
    parameter PREAMBLE_SYMS = 32
)(
    input  wire clk,
    input  wire rst_n,

    // Raw Baseband Inputs (From DDC)
    input  wire signed [DATA_WIDTH-1:0] hw_i_in,
    input  wire signed [DATA_WIDTH-1:0] hw_q_in,
    input  wire hw_valid_in,
    input  wire hw_preamble_flag,

    // Config Gains
    input  wire signed [15:0] kp_val,
    input  wire signed [15:0] ki_val,

    // CFO de-rotation enable (tie high for normal operation; expose to a VIO
    // bit if you want to A/B the correction on/off)
    input  wire cfo_correct_en,

    // Final STR Outputs
    output wire signed [DATA_WIDTH-1:0] hw_i_out,
    output wire signed [DATA_WIDTH-1:0] hw_q_out,
    output wire hw_valid_out,

    // CFO Outputs (To CORDIC)
    output wire signed [(2*DATA_WIDTH)+9:0] cfo_coarse_i,
    output wire signed [(2*DATA_WIDTH)+9:0] cfo_coarse_q,
    output wire cfo_coarse_valid,
    output wire signed [(2*DATA_WIDTH)+9:0] cfo_fine_i,
    output wire signed [(2*DATA_WIDTH)+9:0] cfo_fine_q,
    output wire cfo_fine_valid
);

    // 1. AGC Interconnects
    wire signed [DATA_WIDTH-1:0] agc_i_out;
    wire signed [DATA_WIDTH-1:0] agc_q_out;
    wire agc_valid_out;

    trex1_ff_agc #(
        .DATA_WIDTH(DATA_WIDTH),
        .WINDOW_SIZE(AGC_WINDOW)
    ) u_agc (
        .clk(clk), .rst_n(rst_n),
        .i_data_in(hw_i_in), .q_data_in(hw_q_in), .valid_in(hw_valid_in),
        .i_data_out(agc_i_out), .q_data_out(agc_q_out), .valid_out(agc_valid_out)
    );

    // Preamble Flag Delay Line (Matches AGC latency)
    // Uses shreg_extract to save power
    (* shreg_extract = "yes" *) reg [AGC_WINDOW-1:0] flag_delay_pipe;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) flag_delay_pipe <= 0;
        else if (hw_valid_in) flag_delay_pipe <= {flag_delay_pipe[AGC_WINDOW-2:0], hw_preamble_flag};
    end
    wire sync_preamble_active = flag_delay_pipe[AGC_WINDOW-1];

    // 2. CFO Estimator
    trex1_cfo_top #(
        .DATA_WIDTH(DATA_WIDTH), .SPS(SPS), .PREAMBLE_SYMS(PREAMBLE_SYMS)
    ) u_cfo (
        .clk(clk), .rst_n(rst_n),
        .preamble_active(sync_preamble_active),
        .valid_in(agc_valid_out), .i_in(agc_i_out), .q_in(agc_q_out),
        .coarse_i(cfo_coarse_i), .coarse_q(cfo_coarse_q), .coarse_valid(cfo_coarse_valid),
        .fine_i(cfo_fine_i), .fine_q(cfo_fine_q), .fine_valid(cfo_fine_valid)
    );

    // 2b. CFO DE-ROTATION  (closes the loop the estimator left open)
    //     Uses the coarse (lag-1) estimate to de-rotate AGC output before STR.
    //     When no estimate is available yet (dphi=0) it is transparent.
    wire signed [DATA_WIDTH-1:0] derot_i, derot_q;
    wire                         derot_valid;

    trex1_cfo_derotate #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH ((2*DATA_WIDTH)+10),
        .STAGES    (14)
    ) u_derot (
        .clk(clk), .rst_n(rst_n),
        .enable(cfo_correct_en),
        .valid_in(agc_valid_out), .i_in(agc_i_out), .q_in(agc_q_out),
        .coarse_i(cfo_fine_i), .coarse_q(cfo_fine_q), .coarse_valid(cfo_fine_valid),  // fine = lag-16, matches LAG_LOG2=4
        .i_out(derot_i), .q_out(derot_q), .valid_out(derot_valid)
    );

    // 3. Symbol Timing Recovery (STR)  -- now fed from de-rotated samples
    trex1_str_top #(
        .DATA_WIDTH(DATA_WIDTH), .MU_WIDTH(8), .SPS(SPS)
    ) u_str (
        .clk(clk), .rst_n(rst_n),
        .valid_in(derot_valid), .i_in(derot_i), .q_in(derot_q),
        .kp(kp_val), .ki(ki_val),
        .i_out(hw_i_out), .q_out(hw_q_out), .valid_out(hw_valid_out)
    );

endmodule
