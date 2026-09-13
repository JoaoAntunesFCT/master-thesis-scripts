`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    fpga_ddc_test_wrapper
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Top-level FPGA test harness for the DDC front-end. Wires a
//                 VIO control/debug core and two Xilinx DDS Compiler IPs
//                 (simulated ADC input, LO sin/cos LUT) to the ddc_frontend_top
//                 DUT, exposing the runtime controls and internal pipeline
//                 stages needed for in-system bring-up and debug via VIO/ILA.
//
// Dependencies:   Instantiates vio_0, dds_adc_sim, dds_lo_lut (Xilinx IP
//                 cores) and ddc_frontend_top.v, which in turn instantiates
//                 adc_format_aligner.v, ddc_fs4_mixer.v, ddc_nco_cmix.v,
//                 cic_decimator_4th_order.v (x2), and fir_csd_filter.v (x2).
//                 Top-level for this test project; not itself instantiated.
//
//////////////////////////////////////////////////////////////////////////////////

// ============================================================================
// Key configuration for NCO test:
//   dds_adc_sim  : 1.1 MHz output, 10-bit, configured as POSITIVE frequency
//                  (positive phase increment in IP customisation).
//   dds_lo_lut   : SIN/COS LUT only, 12-bit output, no internal accumulator.
//   mode_sel     : hardwired 1'b0 (fs/4 path). Change to 1'b1 for NCO test.
//   fcw          : 0xFD6FA4 (= -168028 signed → LO at -1.0015 MHz)
//   decimation_rate : 0xC (= 12)
//   adc_res_sel  : 0x3 (= full 10-bit mode)
//
// Xilinx DDS Compiler AXI-Stream packing (BOTH instances):
//   tdata[15:0]  = cosine channel (I), zero-padded from bit width up to 16
//   tdata[31:16] = sine   channel (Q), zero-padded from bit width up to 16
//   For 10-bit ADC sim : cosine = tdata[9:0],  sine = tdata[25:16]
//   For 12-bit LO LUT  : cosine = tdata[11:0], sine = tdata[27:16]
//
// VIO probe mapping (5 outputs, 1 input):
//   probe_out0 [1]  -> rst_n
//   probe_out1 [1]  -> enable
//   probe_out2 [2]  -> adc_res_sel
//   probe_out3 [4]  -> decimation_rate
//   probe_out4 [24] -> fcw
//   probe_in0  [1]  <- dbg_baseband_valid
//
// Debug probes added in this revision (tapped from ddc_frontend_top outputs):
//   dbg_mixer_i_out / dbg_mixer_q_out  : 23-bit mixer output (pre-CIC)
//   dbg_cic_i_out   / dbg_cic_q_out    : 24-bit CIC output (pre-FIR)
//   These localise where signal amplitude is lost in the pipeline.
// ============================================================================

module fpga_ddc_test_wrapper (
    input wire sys_clk  // 100 MHz board clock
);

    // -----------------------------------------------------------------------
    // VIO-driven control signals.
    // KEEP prevents the synthesiser removing VIO probe_out nets which have
    // no observable logic fanout (only module port connections).
    // -----------------------------------------------------------------------
    (* mark_debug = "true", KEEP = "true" *) wire        rst_n;
    (* mark_debug = "true", KEEP = "true" *) wire        enable;
    (* mark_debug = "true", KEEP = "true" *) wire [1:0]  adc_res_sel;
    (* mark_debug = "true", KEEP = "true" *) wire [3:0]  decimation_rate;
    (* mark_debug = "true", KEEP = "true" *) wire [23:0] fcw;

    // -----------------------------------------------------------------------
    // Pipeline-stage debug probes (driven by DUT)
    // -----------------------------------------------------------------------
    (* mark_debug = "true", KEEP = "true" *) wire signed [22:0] dbg_mixer_i_out;
    (* mark_debug = "true", KEEP = "true" *) wire signed [22:0] dbg_mixer_q_out;
    (* mark_debug = "true", KEEP = "true" *) wire signed [23:0] dbg_cic_i_out;
    (* mark_debug = "true", KEEP = "true" *) wire signed [23:0] dbg_cic_q_out;

    // -----------------------------------------------------------------------
    // mode_sel hardwired to 0 (fs/4 mixer path).
    // Synthesis constant-folds the fs/4 branch of the mode mux - this is
    // intentional and eliminates the VIO constant-propagation problem.
    // Change 1'b0 to 1'b1 and resynthesize to select the NCO path.
    // mark_debug keeps it visible in ILA so the active path is always
    // confirmed in every captured waveform.
    // -----------------------------------------------------------------------
    (* mark_debug = "true", KEEP = "true" *) wire mode_sel;
    assign mode_sel = 1'b0;   // fs/4 path - change to 1'b1 for NCO

    // -----------------------------------------------------------------------
    // DUT observation signals
    // -----------------------------------------------------------------------
    (* mark_debug = "true", KEEP = "true" *) wire        dbg_baseband_valid;
    (* mark_debug = "true", KEEP = "true" *) wire [23:0] dbg_i_out_baseband;
    (* mark_debug = "true", KEEP = "true" *) wire [23:0] dbg_q_out_baseband;
    (* mark_debug = "true", KEEP = "true" *) wire [23:0] dbg_phase_out;
    (* mark_debug = "true", KEEP = "true" *) wire [9:0]  dbg_raw_i_in;
    (* mark_debug = "true", KEEP = "true" *) wire [9:0]  dbg_raw_q_in;

    // -----------------------------------------------------------------------
    // AXI-Stream data buses from Xilinx DDS Compiler instances.
    // -----------------------------------------------------------------------
    wire [31:0] adc_sim_tdata;
    wire [31:0] lo_lut_tdata;

    // ADC simulator: 10-bit output.
    // Cosine (I) in tdata[9:0], Sine (Q) in tdata[25:16].
    // DO NOT swap these - the DDS generates a positive-frequency complex tone
    // (cosine leads sine by 90°) when the IP is configured with a positive
    // phase increment. Swapping would invert the rotation direction and select
    // the wrong mixer sideband.
    assign dbg_raw_i_in = adc_sim_tdata[9:0];    // Cosine → I
    assign dbg_raw_q_in = adc_sim_tdata[25:16];  // Sine   → Q

    // LO LUT: 12-bit output.
    // Cosine in tdata[11:0], Sine in tdata[27:16].
    wire signed [11:0] lo_cos = lo_lut_tdata[11:0];
    wire signed [11:0] lo_sin = lo_lut_tdata[27:16];

    // Top 16 bits of 24-bit NCO phase accumulator fed to LO LUT phase input
    wire [15:0] truncated_phase = dbg_phase_out[23:8];

    // -----------------------------------------------------------------------
    // VIO - 5 probe_outs, 1 probe_in.
    // Regenerate vio_0 IP with probe widths: out[1,1,2,4,24], in[1].
    // -----------------------------------------------------------------------
    vio_0 u_vio (
        .clk       (sys_clk),
        .probe_in0 (dbg_baseband_valid),
        .probe_out0(rst_n),
        .probe_out1(enable),
        .probe_out2(adc_res_sel),
        .probe_out3(decimation_rate),
        .probe_out4(fcw)
    );

    // -----------------------------------------------------------------------
    // ADC simulator - free-running complex DDS, no enable or reset.
    // Configure in IP customisation:
    //   NCO test  : Output Frequency = 1.1 MHz  (POSITIVE, forward-spinning)
    //   fs/4 test : Output Frequency = 24.9 MHz
    // Ensure "Phase Increment" is positive (default). Do not negate.
    // -----------------------------------------------------------------------
    dds_adc_sim u_adc_sim (
        .aclk              (sys_clk),
        .m_axis_data_tvalid(),
        .m_axis_data_tdata (adc_sim_tdata)
    );

    // -----------------------------------------------------------------------
    // LO look-up table - sin/cos only (no internal accumulator), 12-bit.
    // Phase input gated by enable via s_axis_phase_tvalid.
    // Reconfigure from 10-bit to 12-bit output in IP customisation if not done.
    // -----------------------------------------------------------------------
    dds_lo_lut u_lo_lut (
        .aclk               (sys_clk),
        .s_axis_phase_tvalid(enable),
        .s_axis_phase_tdata (truncated_phase),
        .m_axis_data_tvalid (),
        .m_axis_data_tdata  (lo_lut_tdata)
    );

    // -----------------------------------------------------------------------
    // DDC front-end DUT
    // Connected to debug probe outputs for stage-by-stage signal observation.
    // -----------------------------------------------------------------------
    ddc_frontend_top u_dut (
        .clk               (sys_clk),
        .rst_n             (rst_n),
        .enable            (enable),
        .adc_res_sel       (adc_res_sel),
        .raw_i_in          (dbg_raw_i_in),
        .raw_q_in          (dbg_raw_q_in),
        .mode_sel          (mode_sel),
        .fcw               (fcw),
        .cos_lo            (lo_cos),
        .sin_lo            (lo_sin),
        .decimation_rate   (decimation_rate),
        // Debug probe outputs from DUT (NEW)
        .mixer_i_out       (dbg_mixer_i_out),
        .mixer_q_out       (dbg_mixer_q_out),
        .cic_i_out         (dbg_cic_i_out),
        .cic_q_out         (dbg_cic_q_out),
        // Existing observation outputs
        .phase_out         (dbg_phase_out),
        .baseband_valid_out(dbg_baseband_valid),
        .i_out_baseband    (dbg_i_out_baseband),
        .q_out_baseband    (dbg_q_out_baseband)
    );

endmodule
