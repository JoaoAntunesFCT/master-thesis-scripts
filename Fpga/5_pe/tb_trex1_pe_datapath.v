`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    tb_trex1_pe_datapath
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Self-checking testbench for trex1_pe_datapath. Builds a
//                 small 32-bit reference packet (16-bit 0xA5A5 payload +
//                 CRC-16), PN9-whitens it using behavioral software-style
//                 code, streams it into the DUT one bit per clock, and checks
//                 that the DUT's crc_syndrome output settles to 16'h0000 for
//                 this error-free packet.
//
// Dependencies:   trex1_pe_datapath (DUT).
//
//////////////////////////////////////////////////////////////////////////////////


module tb_trex1_pe_datapath;

    localparam CLK_PERIOD = 1000; // 1 MHz Baseband Clock

    // DUT Inputs
    reg clk;
    reg rst_n;
    reg enable;
    reg raw_bit_in;

    // DUT Outputs
    wire dewhitened_bit;
    wire [15:0] crc_syndrome;
    wire [8:0]  pn9_state;

    // Instantiate the DUT
    trex1_pe_datapath dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .raw_bit_in(raw_bit_in),
        .dewhitened_bit(dewhitened_bit),
        .crc_syndrome(crc_syndrome),
        .pn9_state(pn9_state)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ----------------------------------------------------
    // TESTBENCH TX GENERATOR LOGIC
    // ----------------------------------------------------
    // We will simulate a small 16-bit payload for visual verification
    localparam PAYLOAD_LEN = 16;
    localparam CRC_LEN = 16;
    localparam TOTAL_LEN = PAYLOAD_LEN + CRC_LEN;

    reg [15:0] tx_payload = 16'hA5A5; // Test Payload
    reg [TOTAL_LEN-1:0] tx_packet_clean;
    reg [TOTAL_LEN-1:0] tx_packet_whitened;

    // TX Variables
    reg [15:0] tx_crc;
    reg [8:0]  tx_pn9;
    reg tx_crc_fb, tx_pn9_fb;
    integer i;

    initial begin
        clk = 0; rst_n = 0; enable = 0; raw_bit_in = 0;

        // --- STEP 1: CALCULATE TX CRC-16 ---
        // Software model of the CRC-16 LFSR (x^16 + x^12 + x^5 + 1) that
        // trex1_pe_datapath implements in hardware, used here to compute the
        // reference CRC for tx_payload with blocking assigns.
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

        // Assemble clean packet (Payload + CRC)
        tx_packet_clean = {tx_payload, tx_crc};

        // --- STEP 2: APPLY TX PN9 WHITENING ---
        // Same PN9 LFSR (x^9 + x^5 + 1, seed 9'h1FF) as the DUT; whitening
        // here with XOR is exactly what the DUT's de-whitener reverses.
        tx_pn9 = 9'h1FF;
        for (i = TOTAL_LEN-1; i >= 0; i = i - 1) begin
            tx_pn9_fb = tx_pn9[8] ^ tx_pn9[4];
            tx_packet_whitened[i] = tx_packet_clean[i] ^ tx_pn9[8];
            tx_pn9 = {tx_pn9_fb, tx_pn9[8:1]};
        end

        // --- STEP 3: RUN RECEIVER SIMULATION ---
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("--- TREX1 Packet Engine Verification ---");
        $display("Transmitting Payload: %h", tx_payload);
        $display("Transmitting CRC-16:  %h", tx_crc);

        enable = 1;

        // Feed the whitened bits into the RX datapath one by one
        // MSB-first: index TOTAL_LEN-1 (first payload bit) goes first, down
        // to index 0 (last CRC bit).
        for (i = TOTAL_LEN-1; i >= 0; i = i - 1) begin
            raw_bit_in = tx_packet_whitened[i];
            #(CLK_PERIOD);
        end

        enable = 0;
        #(CLK_PERIOD * 5);

        // --- STEP 4: CHECK FINAL SYNDROME ---
        // With no bit errors injected, the DUT's running CRC-16 syndrome
        // should land on 0 once the whole packet has shifted through.
        if (crc_syndrome == 16'h0000) begin
            $display("RESULT: PASS! RX Syndrome is 0x0000. Packet is completely error-free.");
        end else begin
            $display("RESULT: FAIL! RX Syndrome is %h", crc_syndrome);
        end

        $finish;
    end

endmodule
