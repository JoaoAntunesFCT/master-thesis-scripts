`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
// 
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    adc_format_aligner
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Aligns raw ADC samples of a runtime-selectable resolution
//                 (7/8/9/10-bit, via adc_res_sel) to a common 10-bit signed
//                 two's-complement format by sign-extending the valid bits.
//                 Lets every downstream block assume a fixed 10-bit signed
//                 sample width regardless of the ADC's configured resolution.
//
// Dependencies:   Instantiated by ddc_frontend_top.v (u_aligner).
//
//////////////////////////////////////////////////////////////////////////////////


module adc_format_aligner (
    input  wire [1:0]        adc_res_sel, // 00: 7-bit, 01: 8-bit, 10: 9-bit, 11: 10-bit
    input  wire [9:0]        raw_i_in,
    input  wire [9:0]        raw_q_in,
    output wire signed [9:0] i_aligned,
    output wire signed [9:0] q_aligned
);

    // Sign-extend the selected number of valid ADC bits up to the full
    // 10-bit signed field. The unused upper bits of raw_i_in/raw_q_in
    // (above the configured resolution) are simply ignored.
    assign i_aligned = (adc_res_sel == 2'b00) ? {{3{raw_i_in[6]}}, raw_i_in[6:0]} :
                       (adc_res_sel == 2'b01) ? {{2{raw_i_in[7]}}, raw_i_in[7:0]} :
                       (adc_res_sel == 2'b10) ? {{1{raw_i_in[8]}}, raw_i_in[8:0]} :
                                                raw_i_in[9:0];

    assign q_aligned = (adc_res_sel == 2'b00) ? {{3{raw_q_in[6]}}, raw_q_in[6:0]} :
                       (adc_res_sel == 2'b01) ? {{2{raw_q_in[7]}}, raw_q_in[7:0]} :
                       (adc_res_sel == 2'b10) ? {{1{raw_q_in[8]}}, raw_q_in[8:0]} :
                                                raw_q_in[9:0];
endmodule
