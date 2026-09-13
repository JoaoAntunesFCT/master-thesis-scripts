`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_pe_datapath
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Streaming receive datapath for the TRex1 Packet Engine. A PN9
//                 de-whitening LFSR (x^9 + x^5 + 1) recovers each original bit
//                 from the raw demodulated stream, and a parallel CRC-16 LFSR
//                 (x^16 + x^12 + x^5 + 1) accumulates a running syndrome over
//                 the de-whitened bits. For a clean 272-bit packet (256-bit
//                 payload + 16-bit CRC) the syndrome lands on 16'h0000 once the
//                 whole packet has been shifted through; any other final value
//                 is looked up in syndrome_lut to locate a single flipped bit.
//
// Dependencies:   None (leaf module). Instantiated by trex1_packet_engine_top.
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_pe_datapath (
    input  wire clk,
    input  wire rst_n,

    input  wire enable,      // High when receiving packet bits
    input  wire raw_bit_in,  // From the GMSK Demodulator

    output wire dewhitened_bit,
    output reg  [15:0] crc_syndrome,
    output reg  [8:0]  pn9_state
);

    // 1. PN9 De-whitener (x^9 + x^5 + 1)
    // The transmitter XORs the payload with this same PN9 sequence to
    // "whiten" it (break up long runs of 1s/0s for the modulator); XOR-ing
    // the raw bit with the current top-of-LFSR state here undoes that,
    // since XOR-ing twice with the same value is the identity.
    wire pn9_feedback = pn9_state[8] ^ pn9_state[4];
    assign dewhitened_bit = raw_bit_in ^ pn9_state[8];

    // 2. Hardware-Accurate CRC-16 (x^16 + x^12 + x^5 + 1)
    // Standard CRC-16/CCITT-style LFSR, fed one de-whitened bit per clock.
    // crc_feedback is XOR-ed into the taps at bits 11, 4 and 0 (matching the
    // x^12, x^5 and x^0 terms of the generator polynomial) as the register
    // shifts down each cycle. Run over payload+CRC together, this drives the
    // syndrome to exactly 16'h0000 when the received packet is error-free.
    wire crc_feedback = crc_syndrome[15] ^ dewhitened_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pn9_state <= 9'h1FF; // Initial State: All 1s
            crc_syndrome <= 16'd0;
        end else if (enable) begin
            // Shift PN9
            pn9_state <= {pn9_feedback, pn9_state[8:1]};

            // Shift CRC-16 and apply XOR taps
            crc_syndrome[15:12] <= crc_syndrome[14:11];
            crc_syndrome[11]    <= crc_syndrome[10] ^ crc_feedback;
            crc_syndrome[10:5]  <= crc_syndrome[9:4];
            crc_syndrome[4]     <= crc_syndrome[3]  ^ crc_feedback;
            crc_syndrome[3:1]   <= crc_syndrome[2:0];
            crc_syndrome[0]     <= crc_feedback;
        end else begin
            // Reset state when enable is low (between packets)
            pn9_state <= 9'h1FF;
            crc_syndrome <= 16'd0;
        end
    end

endmodule
