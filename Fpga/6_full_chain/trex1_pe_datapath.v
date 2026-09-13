`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_pe_datapath
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Serial PN9 de-whitener (x^9+x^5+1) and CRC-16 (x^16+x^12+x^5+1,
//                 CCITT-style) syndrome generator for one recovered bit at a
//                 time. Both LFSRs are clocked once per recovered symbol
//                 (bit_valid) rather than once per system clock, since the
//                 symbol rate is much slower than clk; they hold between
//                 pulses and reset whenever the packet window (enable) is
//                 inactive, so exactly 272 bits (256 payload + 16 CRC) are
//                 consumed per packet.
//
// Dependencies:   Instantiated by trex1_packet_engine_top.v (u_datapath).
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_pe_datapath (
    input  wire clk,
    input  wire rst_n,

    input  wire enable,      // High for the whole packet window (level)
    input  wire bit_valid,   // 1-clock strobe per recovered symbol (rx_bit_valid)
    input  wire raw_bit_in,  // From the GMSK Demodulator

    output wire dewhitened_bit,
    output reg  [15:0] crc_syndrome,
    output reg  [8:0]  pn9_state
);

    // 1. PN9 De-whitener (x^9 + x^5 + 1)
    wire pn9_feedback = pn9_state[8] ^ pn9_state[4];
    assign dewhitened_bit = raw_bit_in ^ pn9_state[8];

    // 2. Hardware-Accurate CRC-16 (x^16 + x^12 + x^5 + 1)
    wire crc_feedback = crc_syndrome[15] ^ dewhitened_bit;

    // TIMING FIX: the packet arrives one bit PER RECOVERED SYMBOL, not one bit
    // per system clock. 'enable' is a level held high for the whole 272-symbol
    // window; 'bit_valid' (rx_bit_valid from the GMSK demod) pulses once per
    // symbol. Shift the LFSRs only on bit_valid so exactly 272 bits are clocked
    // in; hold between pulses; reset only when the packet window is inactive.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pn9_state <= 9'h1FF; // Initial State: All 1s
            crc_syndrome <= 16'd0;
        end else if (!enable) begin
            // Reset state between packets
            pn9_state <= 9'h1FF;
            crc_syndrome <= 16'd0;
        end else if (bit_valid) begin
            // Consume exactly ONE bit per recovered symbol
            // Shift PN9
            pn9_state <= {pn9_feedback, pn9_state[8:1]};

            // Shift CRC-16 and apply XOR taps (parallel-load form of the
            // standard x^16+x^12+x^5+1 Galois LFSR, one bit per symbol)
            crc_syndrome[15:12] <= crc_syndrome[14:11];
            crc_syndrome[11]    <= crc_syndrome[10] ^ crc_feedback;
            crc_syndrome[10:5]  <= crc_syndrome[9:4];
            crc_syndrome[4]     <= crc_syndrome[3]  ^ crc_feedback;
            crc_syndrome[3:1]   <= crc_syndrome[2:0];
            crc_syndrome[0]     <= crc_feedback;
        end
        // else (enable && !bit_valid): HOLD - registers retain their value
    end

endmodule
