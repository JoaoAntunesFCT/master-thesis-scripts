`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_packet_engine_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Packet engine: PN9 de-whitener + CRC-16 syndrome check +
//                 single-bit error correction via syndrome LUT. Shifts in one
//                 dewhitened bit per recovered symbol into a 272-bit packet
//                 buffer, and on the falling edge of 'enable' (end of the
//                 272-symbol window) evaluates the CRC syndrome to release
//                 either a perfect packet, a single-bit-corrected packet, or
//                 an uncorrectable-error flag.
//
// Dependencies:   Instantiates trex1_pe_datapath.v (u_datapath) and
//                 syndrome_lut.v (u_lut). Instantiated by trex1_rx_frontend_top.v
//                 (u_pe).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : trex1_packet_engine_top
// Description : Packet engine: PN9 de-whitener + CRC-16 check + syndrome LUT
//               single-bit error correction.
//
// MODIFICATION for integration (Rev 2):
//   Added debug output ports for crc_syndrome and error_idx so the FPGA
//   wrapper can probe them on ILA without needing mark_debug on internal nets.
//   Functionally identical to the original.
// ============================================================================
module trex1_packet_engine_top (
    input  wire clk,
    input  wire rst_n,

    // Inputs from GMSK Demodulator (or Hardware Wrapper)
    input  wire enable,      // level: high for the whole 272-symbol packet window
    input  wire bit_valid,   // 1-clock strobe per recovered symbol (rx_bit_valid)
    input  wire raw_bit_in,

    // Outputs to RX FIFO / MAC Layer
    output reg [255:0] clean_payload_out,
    output reg packet_valid,
    output reg packet_error,

    // Debug outputs (NEW in Rev 2)
    output wire [15:0] dbg_crc_syndrome,
    output wire [8:0]  dbg_error_idx
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
        .bit_valid(bit_valid),
        .raw_bit_in(raw_bit_in),
        .dewhitened_bit(dewhitened_bit),
        .crc_syndrome(crc_syndrome),
        .pn9_state(pn9_state)
    );

    // Debug probe assignments
    assign dbg_crc_syndrome = crc_syndrome;

    // ----------------------------------------------------
    // 2. Shift Register (Stores the full 272-bit packet)
    // ----------------------------------------------------
    reg [271:0] packet_buffer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            packet_buffer <= 272'd0;
        end else if (enable && bit_valid) begin
            // shift in one dewhitened bit per recovered symbol (not per clock)
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

    // One-clock pulse on the enable falling edge: fires exactly once, right
    // after the 272nd (last) bit has been shifted into packet_buffer.
    wire correction_trigger = (enable_d && !enable);

    // ----------------------------------------------------
    // 4. Syndrome LUT Instance
    // ----------------------------------------------------
    wire [8:0] error_idx;

    syndrome_lut u_lut (
        .crc_syndrome(crc_syndrome),
        .error_idx(error_idx)
    );

    assign dbg_error_idx = error_idx;

    // ----------------------------------------------------
    // 5. Packet Evaluation & Error Correction
    // ----------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clean_payload_out <= 256'd0;
            packet_valid <= 1'b0;
            packet_error <= 1'b0;
        end else begin
            packet_valid <= 1'b0;

            if (correction_trigger) begin
                if (crc_syndrome == 16'h0000) begin
                    // CASE 1: Perfect Packet
                    clean_payload_out <= packet_buffer[271:16];
                    packet_error <= 1'b0;
                    packet_valid <= 1'b1;
                end
                else if (error_idx != 9'h1FF) begin
                    // CASE 2: Single Bit Error (Correctable)
                    clean_payload_out <= packet_buffer[271:16];
                    // error_idx = 0..271 bit position from the syndrome LUT (9'h1FF = "no error").
                    // Only payload-region errors ([271:16]) are correctable, i.e. error_idx <= 255.
                    // This guard is equivalent to the old (271 - error_idx) >= 16 for every valid
                    // input, and it also prevents the unsigned underflow of (271 - error_idx) that
                    // Formality flagged (FMR_ELAB-147). With error_idx bounded to 8 bits the payload
                    // index is provably in range [0:255].
                    if (error_idx <= 9'd255) begin
                        clean_payload_out[8'd255 - error_idx[7:0]] <= ~packet_buffer[9'd271 - error_idx];
                    end
                    packet_error <= 1'b0;
                    packet_valid <= 1'b1;
                end
                else begin
                    // CASE 3: Multi-bit Burst Error (Uncorrectable)
                    clean_payload_out <= 256'd0;
                    packet_error <= 1'b1;
                    packet_valid <= 1'b0;
                end
            end
        end
    end

endmodule
