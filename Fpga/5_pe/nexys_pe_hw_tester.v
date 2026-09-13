`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    nexys_pe_hw_tester
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Nexys A7 board-level hardware test wrapper for the TRex1
//                 Packet Engine (trex1_packet_engine_top). Divides the 100 MHz
//                 board clock down to 1 MHz, builds a fixed 272-bit test packet
//                 (32-byte 0xA5 payload + CRC-16, PN9-whitened, with a single
//                 bit forced wrong at index 128) in an initial block, shifts it
//                 into the Packet Engine one bit per clock when BTNC is pressed,
//                 and displays packet_valid / packet_error plus a recovered
//                 payload byte on the board LEDs.
//
// Dependencies:   trex1_packet_engine_top. Top-level for the Nexys A7 board
//                 (no parent instantiation).
//
//////////////////////////////////////////////////////////////////////////////////

module nexys_pe_hw_tester(
    input  wire clk_100mhz,   // 100 MHz clock from Nexys A7
    input  wire btn_rst,      // CPU_RESET push button (Active Low)
    input  wire btn_start,    // BTNC push button to trigger packet

    output reg  [15:0] led    // 16 physical LEDs on Nexys A7
);

    // ----------------------------------------------------
    // 1. Clock Divider (100 MHz -> 1 MHz)
    // ----------------------------------------------------
    reg [5:0] clk_div = 0;
    reg clk_1mhz = 0;

    always @(posedge clk_100mhz) begin
        // Toggle every 50 ticks to get a 1 MHz clock
        if (clk_div == 49) begin
            clk_div <= 0;
            clk_1mhz <= ~clk_1mhz;
        end else begin
            clk_div <= clk_div + 1;
        end
    end

    // ----------------------------------------------------
    // 2. Button Debouncing / Edge Detection
    // ----------------------------------------------------
    reg [2:0] btn_sync = 0;

    // Fixed: Declared start_pulse only once, WITH the debug attribute
    (* mark_debug = "true" *) wire start_pulse;

    always @(posedge clk_1mhz) begin
        btn_sync <= {btn_sync[1:0], btn_start};
    end
    // 2-stage synchronizer + rising-edge detect: pulses for one clk_1mhz
    // cycle when btn_start transitions 0 -> 1.
    assign start_pulse = (btn_sync[2:1] == 2'b01);

    // ----------------------------------------------------
    // 3. Test Packet Generation (Synthesizable ROM Init)
    // ----------------------------------------------------
    localparam PAYLOAD_LEN = 256;
    localparam CRC_LEN = 16;
    localparam TOTAL_LEN = PAYLOAD_LEN + CRC_LEN;

    reg [TOTAL_LEN-1:0] tx_packet_whitened;

    // Computes the fixed test vector once at time 0 (synthesizes as an
    // initial-value ROM). Mirrors the CRC-16 / PN9 math in
    // trex1_pe_datapath, run here in software (blocking assigns) as the
    // reference "transmitter" model instead of the streaming hardware LFSR.
    initial begin : INIT_ROM
        reg [255:0] tx_payload;
        reg [TOTAL_LEN-1:0] tx_packet_clean;
        reg [15:0] tx_crc;
        reg [8:0]  tx_pn9;
        reg tx_crc_fb, tx_pn9_fb;
        integer i;

        tx_payload = {32{8'hA5}};
        tx_crc = 16'd0;

        // CRC Calculation
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

        // Whitening
        tx_pn9 = 9'h1FF;
        for (i = TOTAL_LEN-1; i >= 0; i = i - 1) begin
            tx_pn9_fb = tx_pn9[8] ^ tx_pn9[4];
            tx_packet_whitened[i] = tx_packet_clean[i] ^ tx_pn9[8];
            tx_pn9 = {tx_pn9_fb, tx_pn9[8:1]};
        end

        // INJECT SINGLE BIT ERROR at index 128
        tx_packet_whitened[128] = ~tx_packet_whitened[128];
    end

    // ----------------------------------------------------
    // 4. Data Injection State Machine (FIXED: Shift Register)
    // ----------------------------------------------------
    reg [TOTAL_LEN-1:0] tx_shift_reg;
    reg [8:0] bits_left;

    reg pe_enable;
    reg pe_raw_bit_in;

    always @(posedge clk_1mhz or negedge btn_rst) begin
        if (!btn_rst) begin
            pe_enable <= 0;
            pe_raw_bit_in <= 0;
            bits_left <= 0;
            tx_shift_reg <= 0;
        end else begin
            // Trigger the packet
            if (start_pulse && bits_left == 0) begin
                bits_left <= TOTAL_LEN;
                tx_shift_reg <= tx_packet_whitened << 1;           // Pre-shift the rest of the packet
                pe_enable <= 1;                                    // Turn on engine
                pe_raw_bit_in <= tx_packet_whitened[TOTAL_LEN-1];  // Fire the 1st bit IMMEDIATELY

            // Continue shifting data
            end else if (bits_left > 0) begin
                pe_raw_bit_in <= tx_shift_reg[TOTAL_LEN-1]; // Push next MSB
                tx_shift_reg <= tx_shift_reg << 1;          // Shift left

                // Turn off enable on the very last bit
                if (bits_left == 1) begin
                    pe_enable <= 0;
                end
                bits_left <= bits_left - 1;
            end
        end
    end

    // ----------------------------------------------------
    // 5. Instantiate Your Packet Engine
    // ----------------------------------------------------
    (* mark_debug = "true" *) wire [255:0] clean_payload_out;
    (* mark_debug = "true" *) wire packet_valid;
    (* mark_debug = "true" *) wire packet_error;

    trex1_packet_engine_top u_pe_top (
        .clk(clk_1mhz),
        .rst_n(btn_rst),
        .enable(pe_enable),
        .raw_bit_in(pe_raw_bit_in),
        .clean_payload_out(clean_payload_out),
        .packet_valid(packet_valid),
        .packet_error(packet_error)
    );

    // ----------------------------------------------------
    // 6. Result Capture & LED Mapping (RESTORED)
    // ----------------------------------------------------
    always @(posedge clk_1mhz or negedge btn_rst) begin
        if (!btn_rst) begin
            led <= 16'd0;
        end else if (packet_valid || packet_error) begin
            led[15]   <= packet_error;
            led[14]   <= packet_valid;
            led[13:8] <= 6'd0;

            // Show the byte where the error was corrected!
            led[7:0]  <= clean_payload_out[119:112];
        end
    end

endmodule
