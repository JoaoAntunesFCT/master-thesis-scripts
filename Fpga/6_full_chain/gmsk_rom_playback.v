`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    gmsk_rom_playback
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    BRAM-based single-shot test stimulus ROM. Plays back a
//                 pre-generated GMSK-modulated waveform once when pulsed with
//                 'start', producing sample data plus preamble/packet timing
//                 windows aligned to the stored waveform. Test-bench-only
//                 module: it is not part of the RX signal chain itself, it
//                 drives the RX chain's ADC-equivalent input during bring-up.
//
// Dependencies:   Instantiated by fpga_merged_test_wrapper.v (u_gmsk_rom) as
//                 an alternate stimulus source alongside the free-running DDS.
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// gmsk_rom_playback - BRAM ROM for modulated GMSK test stimulus
//
// Stores 64912 samples of GMSK-modulated data at 1.1 MHz IF, 100 MHz.
// Single-shot playback: assert 'start' for one cycle to begin, plays through
// once and stops. Generates preamble_active and packet_active timing signals
// aligned to the stored waveform.
//
// Provide EITHER the I-only or IQ .mem file at synthesis via MEM_FILE.
//   I-only:  DATA_WIDTH=10,  MEM_FILE="gmsk_stimulus_i.mem"
//   I+Q:     DATA_WIDTH=20,  MEM_FILE="gmsk_stimulus_iq.mem"
//            then split: i_out = data_out[9:0], q_out = data_out[19:10]
// ============================================================================
module gmsk_rom_playback #(
    parameter DATA_WIDTH = 10,
    // DEPTH was 64912 (packet ends at PKT_END=64712, only 200 trailing zero
    // samples). That is far shorter than the RX pipeline latency (AGC window +
    // FIR group delay + STR pipeline, ~2000-2500 cycles - see
    // fpga_merged_test_wrapper's inject_delay_vio comment), so the source mux
    // fell over to the free-running DDS tone WHILE the last packet symbols
    // (including the CRC bits) were still draining through the DDC/STR/demod
    // pipeline, corrupting them. Padded with 3200 extra zero (quiet) samples
    // so rom_valid - and the all-zero ADC input - stays asserted long enough
    // for the whole pipeline to flush the real packet before DDS takes over.
    // The .mem file must be regenerated/extended to match (64912 + 3200
    // trailing "00000" lines = 68112 total).
    parameter DEPTH      = 68112,
    parameter ADDR_WIDTH = 17,       // ceil(log2(68112)) = 17
    parameter MEM_FILE   = "gmsk_stimulus_i.mem",
    // Timing markers (sample indices from the Python generator) - unchanged;
    // only the trailing quiet region (PKT_END..DEPTH) was extended.
    parameter PRE_START  = 200,
    parameter PRE_END    = 12488,
    parameter PKT_START  = 12488,
    parameter PKT_END    = 64712
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,              // pulse high for 1 cycle to begin playback

    output reg  [DATA_WIDTH-1:0] data_out,
    output reg  valid_out,
    output reg  preamble_active,    // high during preamble window
    output reg  packet_active,      // high during packet window
    output reg  done                // pulses when playback finishes
);

    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    initial $readmemh(MEM_FILE, mem);

    reg [ADDR_WIDTH-1:0] addr;
    reg running;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr            <= 0;
            running         <= 0;
            data_out        <= 0;
            valid_out       <= 0;
            preamble_active <= 0;
            packet_active   <= 0;
            done            <= 0;
        end else begin
            done <= 0;

            if (start && !running) begin
                running <= 1;
                addr    <= 0;
            end

            if (running) begin
                data_out        <= mem[addr];
                valid_out       <= 1;
                preamble_active <= (addr >= PRE_START) && (addr < PRE_END);
                packet_active   <= (addr >= PKT_START) && (addr < PKT_END);

                if (addr == DEPTH - 1) begin
                    running   <= 0;
                    valid_out <= 0;
                    done      <= 1;
                end else begin
                    addr <= addr + 1;
                end
            end else begin
                valid_out       <= 0;
                preamble_active <= 0;
                packet_active   <= 0;
            end
        end
    end

endmodule
