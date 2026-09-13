`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_rx_frontend_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Structural top level for the complete TREX1 receive chain:
//                 I/Q corrector -> DDC front end -> sync chain (AGC/CFO/STR)
//                 -> GMSK demod -> packet engine. Purely structural wiring
//                 plus a 24-to-12-bit truncation and a 272-bit symbol counter;
//                 see the revision-history note below for chain evolution.
//
// Dependencies:   Instantiates iq_corrector_ll_lms.sv (u_iq_corrector),
//                 ddc_frontend_top.v (u_ddc), trex1_sync_hw_top.v (u_sync),
//                 trex1_gmsk_demod.v (u_gmsk_demod), and
//                 trex1_packet_engine_top.v (u_pe). Instantiated by
//                 fpga_merged_test_wrapper.v (u_rx_chain).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : trex1_rx_frontend_top  (Rev 4 - Complete RX Chain)
// Description : Structural integration of the full TREX1 receive chain:
//     IQ Corrector -> DDC Frontend -> Sync Chain -> GMSK Demod -> Packet Engine
//
// Signal chain:
//   raw_i/q_in [9:0]     -> I/Q Corrector    -> i/q_corrected [9:0]       @ 10 MHz
//                         -> DDC Frontend     -> i/q_baseband [23:0]       @ fs/R
//                         -> [trunc 24->12]    -> sync_i/q_in [11:0]       @ fs/R
//                         -> Sync Chain       -> sync_i/q_out [11:0]      @ symbol rate
//                         -> GMSK Demod       -> rx_bit_out [1b]          @ symbol rate
//                         -> Bit Counter      -> pe_enable [1b]           (272-bit window)
//                         -> Packet Engine    -> clean_payload_out [255:0] @ packet rate
//
// No datapath logic in this module - purely structural instantiation and
// wiring, plus the 24->12 bit truncation (assign) and 272-bit counter.
//
// Revision History:
//   Rev 1: IQ + DDC only
//   Rev 2: + Sync chain with 24->12 truncation
//   Rev 3: + GMSK demod
//   Rev 4: + Packet engine with bit counter
//   Rev 5: + 2-FF reset synchronizer (rst_n -> rst_n_sync) for ASIC hardening
//          (SpyGlass CDC Open Item #5 / Reset_sync04)
// ============================================================================
module trex1_rx_frontend_top (
    input  wire               clk,              // 10 MHz system clock (was 100 MHz)
    input  wire               rst_n,            // active-low reset
    input  wire               enable,           // DDC datapath enable

    // -- ADC interface (raw samples from analogue front-end) --
    input  wire [9:0]         raw_i_in,
    input  wire [9:0]         raw_q_in,

    // -- DDC configuration --
    input  wire               mode_sel,         // 0 = fs/4, 1 = NCO
    input  wire [23:0]        fcw,              // NCO frequency control word
    input  wire signed [11:0] cos_lo,           // LO cosine from external DDS LUT
    input  wire signed [11:0] sin_lo,           // LO sine from external DDS LUT
    input  wire [3:0]         decimation_rate,
    input  wire [1:0]         adc_res_sel,

    // -- Sync configuration --
    input  wire               preamble_flag,    // from MAC / VIO
    input  wire signed [15:0] str_kp,           // STR proportional gain
    input  wire signed [15:0] str_ki,           // STR integral gain

    // -- Packet Engine trigger --
    input  wire               packet_start,     // one-shot trigger from MAC / VIO

    // -- I/Q corrector status --
    output wire               iq_tracking,      // corrector in tracking mode
    output wire               iq_fault,         // fault detected pulse
    output wire [1:0]         iq_calib_phase,

    // -- Debug probes - I/Q corrector --
    output wire signed [9:0]  dbg_iq_i_out,     // corrected I into DDC
    output wire signed [9:0]  dbg_iq_q_out,     // corrected Q into DDC

    // -- Debug probes - DDC internals --
    output wire signed [22:0] dbg_mixer_i, dbg_mixer_q,
    output wire signed [23:0] dbg_cic_i, dbg_cic_q,
    output wire        [23:0] dbg_phase_out,
    output wire               dbg_baseband_valid,

    // -- Debug probes - Sync internals --
    output wire signed [11:0] dbg_agc_i_out, dbg_agc_q_out,
    output wire               dbg_agc_valid_out,

    // -- Debug probes - GMSK demod --
    output wire signed [24:0] dbg_freq_dev,

    // -- Debug probes - Packet Engine --
    output wire [8:0]         dbg_bit_count,
    output wire               dbg_pe_enable,
    output wire [15:0]        dbg_crc_syndrome,
    output wire [8:0]         dbg_error_idx,

    // -- DDC baseband output (available for tapping) --
    output wire signed [23:0] i_out_baseband,
    output wire signed [23:0] q_out_baseband,
    output wire               baseband_valid_out,

    // -- Sync symbol-rate output --
    output wire signed [11:0] sync_i_out,
    output wire signed [11:0] sync_q_out,
    output wire               sync_valid_out,

    // -- CFO outputs (to downstream CORDIC, when integrated) --
    output wire signed [33:0] cfo_coarse_i, cfo_coarse_q,
    output wire               cfo_coarse_valid,
    output wire signed [33:0] cfo_fine_i, cfo_fine_q,
    output wire               cfo_fine_valid,

    // -- GMSK demodulator output --
    output wire               rx_bit_out,
    output wire               rx_bit_valid,

    // -- Packet Engine outputs (to MAC / RX FIFO) --
    output wire [255:0]       clean_payload_out,
    output wire               packet_valid,
    output wire               packet_error
);

    // ====================================================================
    // 0. RESET SYNCHRONIZER - ASIC hardening (Open Item #5, Option A)
    //    rst_n (raw, top-level pin) is asynchronous assert / synchronous
    //    deassert via a 2-FF synchronizer. rst_n_sync is what every
    //    submodule and internal register in this block now uses.
    //
    //    Assertion:   immediate (async clear on the synchronizer FFs
    //                 themselves, so rst_n_sync drops within <1ns of
    //                 rst_n asserting - no assertion latency added).
    //    Deassertion: synchronous, 2 clk cycles after rst_n releases
    //                 (standard 2-FF release synchronizer - eliminates
    //                 the multi-point "first synchronization" issue
    //                 SpyGlass flagged as Reset_sync04).
    // ====================================================================
    (* ASYNC_REG = "TRUE" *) reg rst_n_meta, rst_n_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_meta <= 1'b0;
            rst_n_sync <= 1'b0;
        end else begin
            rst_n_meta <= 1'b1;
            rst_n_sync <= rst_n_meta;
        end
    end

    // ====================================================================
    // 1. I/Q CORRECTOR - runs at full ADC rate, every clock
    //    No enable gating - converges immediately on reset release.
    //    DDC is enabled separately after corrector reaches tracking.
    // ====================================================================
    wire signed [9:0] i_corrected, q_corrected;

    iq_corrector_ll_lms #(
        .BIT_WIDTH        (10),
        .CALIB_SHIFT_P0   (3),
        .TRACK_SHIFT      (12),
        .CALIB_CYCLES_P0  (200000),
        .CALIB_CYCLES_P1  (0),        // intermediate phases disabled
        .CALIB_CYCLES_P2  (0),
        .DDS_PERIOD       (10),       // 1 MHz IF at 10 MHz -> 10 samples/period
        .FAULT_THR        (32'h7FFFFFFF), // disabled for initial integration
        .FAULT_CONFIRM    (3),
        .FAULT_COOLDOWN   (200000),
        .FAULT_BLANKING   (200),
        .SIGNAL_MIN       (64)
    ) u_iq_corrector (
        .clk            (clk),
        .rst_n          (rst_n_sync),
        .i_in           (raw_i_in),
        .q_in           (raw_q_in),
        .i_out          (i_corrected),
        .q_out          (q_corrected),
        .is_tracking    (iq_tracking),
        .fault_detected (iq_fault),
        .calib_phase    (iq_calib_phase)
    );

    assign dbg_iq_i_out = i_corrected;
    assign dbg_iq_q_out = q_corrected;

    // ====================================================================
    // 2. DDC FRONTEND - receives corrected samples
    //    10-bit signed in -> 24-bit signed baseband out @ fs/R
    // ====================================================================
    ddc_frontend_top u_ddc (
        .clk               (clk),
        .rst_n             (rst_n_sync),
        .enable            (enable),
        .adc_res_sel       (adc_res_sel),
        .raw_i_in          (i_corrected),   // <- from corrector
        .raw_q_in          (q_corrected),   // <- from corrector
        .mode_sel          (mode_sel),
        .fcw               (fcw),
        .cos_lo            (cos_lo),
        .sin_lo            (sin_lo),
        .decimation_rate   (decimation_rate),
        .mixer_i_out       (dbg_mixer_i),
        .mixer_q_out       (dbg_mixer_q),
        .cic_i_out         (dbg_cic_i),
        .cic_q_out         (dbg_cic_q),
        .phase_out         (dbg_phase_out),
        .baseband_valid_out(baseband_valid_out),
        .i_out_baseband    (i_out_baseband),
        .q_out_baseband    (q_out_baseband)
    );

    assign dbg_baseband_valid = baseband_valid_out;

    // ====================================================================
    // 3. WIDTH ADAPTER: DDC 24-bit -> Sync 12-bit
    //    Simple bit-select [11:0] - the FIR output signal lives in the low
    //    bits of the 24-bit baseband word, not the top bits, at the gain
    //    levels this filter chain produces.
    //    See design note in Section 15.3 of the integration plan for
    //    rationale on truncation vs saturating truncation.
    // ====================================================================
    wire signed [11:0] sync_i_in = i_out_baseband[11:0]; // was [23:12]: FIR signal lives in low bits
    wire signed [11:0] sync_q_in = q_out_baseband[11:0]; // was [23:12]

    // ====================================================================
    // 4. SYNC CHAIN - AGC -> CFO -> STR
    //    12-bit baseband in @ fs/R -> 12-bit symbol-rate out
    // ====================================================================
    // Internal wires for AGC debug (not exposed by trex1_sync_hw_top
    // directly - we tap the final STR output instead)
    wire signed [11:0] sync_i_int, sync_q_int;
    wire               sync_valid_int;

    trex1_sync_hw_top #(
        .DATA_WIDTH     (12),
        .AGC_WINDOW     (100),
        .SPS            (16),
        .PREAMBLE_SYMS  (32)
    ) u_sync (
        .clk               (clk),
        .rst_n             (rst_n_sync),
        .hw_i_in           (sync_i_in),
        .hw_q_in           (sync_q_in),
        .hw_valid_in       (baseband_valid_out),  // DDC strobe drives sync
        .hw_preamble_flag  (preamble_flag),
        .kp_val            (str_kp),
        .ki_val            (str_ki),
        .cfo_correct_en    (1'b1),
        .hw_i_out          (sync_i_int),
        .hw_q_out          (sync_q_int),
        .hw_valid_out      (sync_valid_int),
        .cfo_coarse_i      (cfo_coarse_i),
        .cfo_coarse_q      (cfo_coarse_q),
        .cfo_coarse_valid  (cfo_coarse_valid),
        .cfo_fine_i        (cfo_fine_i),
        .cfo_fine_q        (cfo_fine_q),
        .cfo_fine_valid    (cfo_fine_valid)
    );

    assign sync_i_out     = sync_i_int;
    assign sync_q_out     = sync_q_int;
    assign sync_valid_out = sync_valid_int;

    // AGC debug: tap the sync chain input (post-truncation, pre-AGC)
    assign dbg_agc_i_out    = sync_i_in;
    assign dbg_agc_q_out    = sync_q_in;
    assign dbg_agc_valid_out = baseband_valid_out;

    // ====================================================================
    // 5. GMSK DEMODULATOR - cross-product frequency discriminator
    //    12-bit symbol-rate in -> 1-bit hard decision out
    // ====================================================================
    wire               gmsk_bit_out;
    wire               gmsk_valid_out;
    wire signed [24:0] gmsk_freq_dev;

    trex1_gmsk_demod #(
        .DATA_WIDTH     (12)
    ) u_gmsk_demod (
        .clk            (clk),
        .rst_n          (rst_n_sync),
        .valid_in       (sync_valid_int),   // <- from STR
        .i_in           (sync_i_int),       // <- from STR
        .q_in           (sync_q_int),       // <- from STR
        .rx_bit_out     (gmsk_bit_out),
        .valid_out      (gmsk_valid_out),
        .freq_dev_out   (gmsk_freq_dev)
    );

    assign rx_bit_out   = gmsk_bit_out;
    assign rx_bit_valid = gmsk_valid_out;
    assign dbg_freq_dev = gmsk_freq_dev;

    // ====================================================================
    // 6. BIT COUNTER - gates PE enable for exactly 272 rx_bit_valid pulses
    //    packet_start (one-shot) opens the window; it closes automatically
    //    after 272 symbol-rate bits (256 payload + 16 CRC).
    // ====================================================================
    reg [8:0] bit_count;
    reg       pe_enable;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            bit_count <= 9'd0;
            pe_enable <= 1'b0;
        end else begin
            if (packet_start && !pe_enable) begin
                pe_enable <= 1'b1;
                bit_count <= 9'd0;
            end
            if (gmsk_valid_out && pe_enable) begin
                if (bit_count == 9'd271) begin
                    bit_count <= 9'd0;
                    pe_enable <= 1'b0;
                end else begin
                    bit_count <= bit_count + 9'd1;
                end
            end
        end
    end

    assign dbg_bit_count = bit_count;
    assign dbg_pe_enable = pe_enable;

    // ====================================================================
    // 7. PACKET ENGINE - PN9 de-whitener + CRC-16 + syndrome LUT
    //    1-bit serial in -> 256-bit payload out
    // ====================================================================
    // Internal wires for debug visibility
    wire [255:0] pe_payload;
    wire         pe_valid;
    wire         pe_error;

    trex1_packet_engine_top u_pe (
        .clk              (clk),
        .rst_n            (rst_n_sync),
        .enable           (pe_enable),
        .bit_valid        (gmsk_valid_out),   // one strobe per recovered symbol
        .raw_bit_in       (gmsk_bit_out),     // <- from GMSK demod
        .clean_payload_out(pe_payload),
        .packet_valid     (pe_valid),
        .packet_error     (pe_error),
        .dbg_crc_syndrome (dbg_crc_syndrome),
        .dbg_error_idx    (dbg_error_idx)
    );

    assign clean_payload_out = pe_payload;
    assign packet_valid      = pe_valid;
    assign packet_error      = pe_error;

endmodule
