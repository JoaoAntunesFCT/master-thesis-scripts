`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    tb_trex1_packet_engine_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Self-checking testbench for trex1_packet_engine_top. Builds a
//                 272-bit reference packet (32-byte 0xA5 payload + CRC-16,
//                 PN9-whitened) using behavioral software-style code, injects a
//                 single-bit error at index 128, streams it into the DUT one
//                 bit per clock, and checks that packet_valid pulses (meaning
//                 the single-bit error was located and corrected) rather than
//                 packet_error.
//
// Dependencies:   trex1_packet_engine_top (DUT).
//
//////////////////////////////////////////////////////////////////////////////////

module tb_trex1_packet_engine_top;

    localparam CLK_PERIOD = 1000; // 1 MHz Baseband Clock

    reg clk;
    reg rst_n;
    reg enable;
    reg raw_bit_in;

    wire [255:0] clean_payload_out;
    wire packet_valid;
    wire packet_error;

    // Instantiate the Top Module
    trex1_packet_engine_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .raw_bit_in(raw_bit_in),
        .clean_payload_out(clean_payload_out),
        .packet_valid(packet_valid),
        .packet_error(packet_error)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    localparam PAYLOAD_LEN = 256;
    localparam CRC_LEN = 16;
    localparam TOTAL_LEN = PAYLOAD_LEN + CRC_LEN;

    // Test Payload: 32 Bytes of 0xA5
    reg [255:0] tx_payload = {32{8'hA5}};
    reg [TOTAL_LEN-1:0] tx_packet_clean;
    reg [TOTAL_LEN-1:0] tx_packet_whitened;

    reg [15:0] tx_crc;
    reg [8:0]  tx_pn9;
    reg tx_crc_fb, tx_pn9_fb;
    integer i;

    initial begin
        clk = 0; rst_n = 0; enable = 0; raw_bit_in = 0;

        // --- 1. Calculate TX CRC-16 ---
        // Software model of the same CRC-16 LFSR (x^16 + x^12 + x^5 + 1)
        // implemented in hardware by trex1_pe_datapath, run here with
        // blocking assigns to produce the reference CRC for the payload.
        tx_crc = 16'd0;
        for (i = PAYLOAD_LEN-1; i >= 0; i = i - 1) begin
            tx_crc_fb = tx_crc[15] ^ tx_payload[i];
            tx_crc[15:12] = tx_crc[14:11];
            tx_crc[11]    = tx_crc[10] ^ tx_crc_fb;
            tx_crc[10:5]  = tx_crc[9:4];
            tx_crc[4]     = tx_crc[3]  ^ tx_crc_fb;
            tx_crc[3:1]   = tx_crc[2:0];
            tx_crc[0]     = tx_crc_fb;
        end
        tx_packet_clean = {tx_payload, tx_crc};

        // --- 2. Apply PN9 Whitening ---
        // Same PN9 LFSR (x^9 + x^5 + 1) as the DUT's de-whitener; XOR-ing the
        // clean packet with this sequence here is what the DUT's de-whitener
        // undoes on the receive side.
        tx_pn9 = 9'h1FF;
        for (i = TOTAL_LEN-1; i >= 0; i = i - 1) begin
            tx_pn9_fb = tx_pn9[8] ^ tx_pn9[4];
            tx_packet_whitened[i] = tx_packet_clean[i] ^ tx_pn9[8];
            tx_pn9 = {tx_pn9_fb, tx_pn9[8:1]};
        end

        // --- 3. INJECT A SINGLE-BIT ERROR ---
        // We flip the bit at index 128 to test the Syndrome LUT
        tx_packet_whitened[128] = ~tx_packet_whitened[128];

        // --- 4. Stream into Hardware ---
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("--- TREX1 PACKET ENGINE TOP-LEVEL SIMULATION ---");
        $display("Injecting 32-Byte Payload with 1 bit error...");

        enable = 1;
        // Stream MSB-first: index TOTAL_LEN-1 (the first payload bit) goes
        // out first, down to index 0 (the last CRC bit) last.
        for (i = TOTAL_LEN-1; i >= 0; i = i - 1) begin
            raw_bit_in = tx_packet_whitened[i];
            #(CLK_PERIOD);
        end
        enable = 0;

        // Wait to observe the valid pulse and correction
        #(CLK_PERIOD * 5);

        if (packet_valid)
            $display("SUCCESS: Packet Valid pulse detected! Check clean_payload_out in waveform.");
        else if (packet_error)
            $display("FAIL: Packet marked as uncorrectable error.");

        $finish;
    end

endmodule
