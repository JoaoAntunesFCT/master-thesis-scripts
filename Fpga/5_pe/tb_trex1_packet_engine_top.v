`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_packet_engine_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Top-level receive Packet Engine for TRex1. Wraps
//                 trex1_pe_datapath (PN9 de-whitening + CRC-16 syndrome
//                 accumulation) and syndrome_lut (single-bit error locator),
//                 captures the de-whitened bit stream into a 272-bit shift
//                 register as it arrives, and once the packet ends either
//                 passes the 256-bit payload through unmodified (syndrome
//                 already 0), corrects a single flipped bit using the syndrome
//                 LUT, or flags an uncorrectable multi-bit error.
//
// Dependencies:   trex1_pe_datapath, syndrome_lut. Instantiated by
//                 nexys_pe_hw_tester and by tb_trex1_packet_engine_top.
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_packet_engine_top (
    input  wire clk,
    input  wire rst_n,

    // Inputs from GMSK Demodulator (or Hardware Wrapper)
    input  wire enable,
    input  wire raw_bit_in,

    // Outputs to RX FIFO / MAC Layer
    output reg [255:0] clean_payload_out,
    output reg packet_valid,
    output reg packet_error // High if packet is dropped (uncorrectable)
);

    // ----------------------------------------------------
    // 1. Serial Datapath Instance (De-whitener & CRC)
    // ----------------------------------------------------
    wire dewhitened_bit;
    wire [15:0] crc_syndrome;
    wire [8:0] pn9_state;

    trex1_pe_datapath u_datapath (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .raw_bit_in(raw_bit_in),
        .dewhitened_bit(dewhitened_bit),
        .crc_syndrome(crc_syndrome),
        .pn9_state(pn9_state)
    );

    // ----------------------------------------------------
    // 2. Shift Register (Stores the full 272-bit packet)
    // ----------------------------------------------------
    // 272 = 256-bit payload + 16-bit CRC, streamed MSB-first. Each new bit
    // enters at LSB (index 0) and everything already in the buffer shifts
    // left, so the FIRST bit received ends up parked at the MSB (index 271)
    // and the LAST bit received (the final CRC bit) sits at the LSB (index 0)
    // once the packet is complete.
    reg [271:0] packet_buffer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            packet_buffer <= 272'd0;
        end else if (enable) begin
            // Shift left: First bit received goes to MSB (271)
            packet_buffer <= {packet_buffer[270:0], dewhitened_bit};
        end
    end

    // ----------------------------------------------------
    // 3. End-of-Packet Detection
    // ----------------------------------------------------
    reg enable_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) enable_d <= 1'b0;
        else enable_d <= enable;
    end

    // Trigger correction exactly 1 clock cycle after 'enable' falls
    // (enable_d lags enable by one cycle, so this pulses high for a single
    // cycle right after the last packet bit has been captured into
    // packet_buffer and crc_syndrome has settled to its final value).
    wire correction_trigger = (enable_d && !enable);

    // ----------------------------------------------------
    // 4. Syndrome LUT Instance
    // ----------------------------------------------------
    wire [8:0] error_idx;

    syndrome_lut u_lut (
        .crc_syndrome(crc_syndrome),
        .error_idx(error_idx)
    );

    // ----------------------------------------------------
    // 5. Packet Evaluation & Error Correction
    // ----------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clean_payload_out <= 256'd0;
            packet_valid <= 1'b0;
            packet_error <= 1'b0;
        end else begin
            packet_valid <= 1'b0; // Default to low (1-cycle pulse)

            if (correction_trigger) begin
                if (crc_syndrome == 16'h0000) begin
                    // ---- CASE 1: Perfect Packet ----
                    // Strip the bottom 16 bits (CRC) and output the payload
                    clean_payload_out <= packet_buffer[271:16];
                    packet_error <= 1'b0;
                    packet_valid <= 1'b1;
                end
                else if (error_idx != 9'h1FF) begin
                    // ---- CASE 2: Single Bit Error (Correctable) ----
                    clean_payload_out <= packet_buffer[271:16];

                    // FIX: Reverse the LUT's Arrival Index to match physical Shift Register Index
                    // LUT 0 (1st bit arrived) -> Buffer index 271
                    // LUT 271 (Last bit arrived) -> Buffer index 0

                    if ((271 - error_idx) >= 16) begin
                        // The error is in the payload. Invert the broken bit!
                        // (271 - error_idx) is the buffer index of the bad
                        // bit; subtracting the 16-bit CRC field converts that
                        // into the matching bit position within the 256-bit
                        // payload being written to clean_payload_out.
                        clean_payload_out[(271 - error_idx) - 16] <= ~packet_buffer[(271 - error_idx)];
                    end
                    // (If the error falls in the CRC field itself,
                    // (271 - error_idx) < 16, the payload is already correct
                    // as copied above, so no bit needs flipping.)

                    packet_error <= 1'b0;
                    packet_valid <= 1'b1;
                end
                else begin
                    // ---- CASE 3: Multi-bit Burst Error (Uncorrectable) ----
                    // syndrome_lut found no matching single-bit-error entry,
                    // so the syndrome corresponds to a burst of 2+ bad bits,
                    // which this scheme cannot locate or correct.
                    clean_payload_out <= 256'd0; // Wipe the payload
                    packet_error <= 1'b1;        // Flag the failure
                    packet_valid <= 1'b0;
                end
            end
        end
    end

endmodule
