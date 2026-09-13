`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    fpga_merged_test_wrapper
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    FPGA test harness for the complete TREX1 RX chain: drives a
//                 free-running DDS (or a recorded GMSK ROM playback) through an
//                 I/Q imbalance injector into trex1_rx_frontend_top, with a VIO
//                 for interactive control and an ILA capture trigger on packet
//                 decode events. See the design note below for the stimulus
//                 architecture and build instructions.
//
// Dependencies:   Instantiates trex1_rx_frontend_top.v (u_rx_chain) and
//                 gmsk_rom_playback.v (u_gmsk_rom) from this project, plus
//                 Vivado-generated IP not present in this source folder:
//                 vio_merged (u_vio), dds_adc_sim (u_adc_sim), and dds_lo_lut
//                 (u_lo_lut).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : fpga_merged_test_wrapper
// Description : FPGA test harness for the complete TREX1 RX chain on
//               Nexys A7-100T (Artix-7, 100 MHz system clock).
//
// Stimulus architecture:
//   DDS (IF) → Imbalance Injector (α/β/DC) → trex1_rx_frontend_top
//
// DDS IP instances (same as standalone wrappers):
//   dds_adc_sim : free-running complex DDS simulating ADC output at IF freq.
//                 10-bit output, PINC configured at IP level per bitstream:
//                   M1: 1.1 MHz (PINC = 184549)
//                   M2: 24.9 MHz (PINC = 4177527)
//                   M3: 10.1 MHz (PINC = 1694499)
//   dds_lo_lut  : sin/cos LUT only, 12-bit output, phase input from NCO.
//
// VIO mapping: 13 outputs, 6 inputs
// ILA mapping: ~450 bits, 8192 depth
//
// Build instructions:
//   1. Set mode_sel parameter below (0 for fs/4, 1 for NCO)
//   2. Configure dds_adc_sim IP for the matching IF frequency
//   3. Synthesise, implement, verify WNS > 0 / TNS = 0
//   4. Program and follow the startup sequence in the integration plan
// ============================================================================
module fpga_merged_test_wrapper (
    input wire sys_clk,  // 100 MHz board clock (E3 on Nexys A7)
    output wire [1:0] LED
);

    // ===================================================================
    // MODE SELECTION - change and resynthesize for each bitstream
    // ===================================================================
    // 1'b0 = fs/4 mixer path (for 24.9 MHz IF, bitstream M2)
    // 1'b1 = NCO mixer path  (for 1.1 / 10.1 MHz IF, bitstreams M1/M3)
    (* mark_debug = "true", KEEP = "true" *)
    wire mode_sel;
    assign mode_sel = 1'b1;   // ← NCO path (change to 1'b0 for fs/4)

    // ===================================================================
    // VIO-DRIVEN CONTROL SIGNALS
    // ===================================================================
    (* mark_debug = "true", KEEP = "true" *) wire        rst_n;            // probe_out0
    (* mark_debug = "true", KEEP = "true" *) wire        ddc_enable_vio;   // probe_out1 (now ignored)
    // DDC datapath enable is hardwired ON for this bring-up test - the VIO bit
    // above is left connected (to keep VIO probe widths unchanged) but is no
    // longer used. The DDC is held cleared by its internal reset while rst_n is
    // low, so a constant enable is safe.
    (* mark_debug = "true", KEEP = "true" *) wire        ddc_enable = 1'b1;
    (* mark_debug = "true", KEEP = "true" *) wire [1:0]  adc_res_sel;      // probe_out2
    (* mark_debug = "true", KEEP = "true" *) wire [3:0]  decimation_rate;  // probe_out3
    (* mark_debug = "true", KEEP = "true" *) wire [23:0] fcw;              // probe_out4
    (* mark_debug = "true", KEEP = "true" *) wire [15:0] alpha_vio;        // probe_out5
    (* mark_debug = "true", KEEP = "true" *) wire [15:0] beta_vio;         // probe_out6
    (* mark_debug = "true", KEEP = "true" *) wire [9:0]  dc_i_vio;         // probe_out7
    (* mark_debug = "true", KEEP = "true" *) wire [9:0]  dc_q_vio;         // probe_out8
    (* mark_debug = "true", KEEP = "true" *) wire [15:0] alpha_drift_vio;  // probe_out9
    (* mark_debug = "true", KEEP = "true" *) wire [31:0] inject_delay_vio; // probe_out10
    (* mark_debug = "true", KEEP = "true" *) wire        preamble_flag;    // probe_out11
    (* mark_debug = "true", KEEP = "true" *) wire        packet_start;     // probe_out12

    // STR loop gains - directly from VIO
    (* mark_debug = "true", KEEP = "true" *) wire [15:0] str_kp_vio;       // probe_out13
    (* mark_debug = "true", KEEP = "true" *) wire [15:0] str_ki_vio;       // probe_out14

    // ===================================================================
    // VIO INSTANCE
    // ===================================================================
    // Regenerate vio_merged IP with:
    //   probe_out widths: [1,1,2,4,24,16,16,10,10,16,32,1,1,16,16]
    //   probe_in widths:  [1,2,1,1,1,1]
    vio_merged u_vio (
        .clk        (sys_clk),
        // ── Inputs (reading the FPGA) ──
        .probe_in0  (iq_tracking),          // I/Q corrector reached tracking
        .probe_in1  (iq_calib_phase),       // Current calibration phase
        .probe_in2  (dbg_baseband_valid),   // DDC output strobe
        .probe_in3  (iq_fault),             // Fault detection pulse
        .probe_in4  (packet_valid_out),     // PE: valid packet recovered
        // probe_in5 (packet_error_out) - monitored via ILA trigger instead
        // ── Outputs (controlling the FPGA) ──
        .probe_out0 (rst_n),
        .probe_out1 (ddc_enable_vio),
        .probe_out2 (adc_res_sel),
        .probe_out3 (decimation_rate),
        .probe_out4 (fcw),
        .probe_out5 (alpha_vio),
        .probe_out6 (beta_vio),
        .probe_out7 (dc_i_vio),
        .probe_out8 (dc_q_vio),
        .probe_out9 (alpha_drift_vio),
        .probe_out10(inject_delay_vio),
        .probe_out11(preamble_flag),
        .probe_out12(packet_start),
        .probe_out13(str_kp_vio),
        .probe_out14(str_ki_vio)
    );

    // ===================================================================
    // DDS: ADC SIMULATOR - free-running complex DDS at IF frequency
    // ===================================================================
    wire [31:0] adc_sim_tdata;
    wire signed [9:0] dds_i_ideal = adc_sim_tdata[9:0];    // cosine → I
    wire signed [9:0] dds_q_ideal = adc_sim_tdata[25:16];  // sine   → Q

    dds_adc_sim u_adc_sim (
        .aclk              (sys_clk),
        .m_axis_data_tvalid(),
        .m_axis_data_tdata (adc_sim_tdata)
    );

    // =================================================================
    // GMSK ROM PLAYBACK + SOURCE MUX
    // =================================================================
    // ROM auto-starts 1 cycle after reset release (no VIO pulse needed).
    // Workflow: arm ILA trigger -> toggle rst_n (0->1) -> ROM plays -> ILA captures.
    reg rom_start_latch;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) rom_start_latch <= 1'b1;
        else        rom_start_latch <= 1'b0;
    wire gmsk_start_pulse = rom_start_latch;

    wire [19:0] rom_iq_data;
    wire rom_valid, rom_preamble, rom_packet, rom_done;
    wire signed [9:0] rom_i = $signed(rom_iq_data[9:0]);
    wire signed [9:0] rom_q = $signed(rom_iq_data[19:10]);

    gmsk_rom_playback #(
        // MEM_FILE previously pointed at "C:/Users/offic/chain_RTL_fpga/..." -
        // a leftover copy from an earlier project location, NOT this project
        // (C:/Users/offic/Desktop/Vivado Projects/chain_RTL_fpga). $readmemh
        // resolves this literal path at synth time, so every .mem edit made
        // to the actual project tree was silently having zero effect on the
        // synthesized ROM. Repointed at this project's own root so there is
        // one single source of truth for the ROM stimulus from now on.
        .DATA_WIDTH(20), .MEM_FILE("C:/Users/offic/Desktop/Vivado Projects/chain_RTL_fpga/gmsk_stimulus_iq.mem")
    ) u_gmsk_rom (
        .clk(sys_clk), .rst_n(rst_n), .start(gmsk_start_pulse),
        .data_out(rom_iq_data), .valid_out(rom_valid),
        .preamble_active(rom_preamble), .packet_active(rom_packet),
        .done(rom_done)
    );

    // Source mux: ROM during playback, DDS otherwise
    wire signed [9:0] i_ideal = rom_valid ? rom_i : dds_i_ideal;
    wire signed [9:0] q_ideal = rom_valid ? rom_q : dds_q_ideal;

    // Preamble override: ROM timing during playback, VIO otherwise
    wire preamble_eff = rom_valid ? rom_preamble : preamble_flag;

    // Auto packet_start for PE: fire this many sys_clk cycles after rom_packet
    // rises. This delay must equal the RX pipeline latency (raw ADC -> rx_bit),
    // which is dominated by the AGC 100-sample window and the FIR group delay
    // (~2000-2500 cycles), NOT the old fixed 1000. It is now VIO-TUNABLE via
    // inject_delay_vio so alignment can be swept live in Hardware Manager:
    // step inject_delay_vio in ~192-cycle (one-symbol) increments and watch
    // LED[0] (green) / cap_crc_syndrome == 0 for the aligned value.
    // (Keep alpha/alpha_drift at unity 1024 so the imbalance injector, which
    //  also references inject_delay_vio, stays harmless during this sweep.)
    reg [31:0] pkt_delay_cnt;
    reg        pkt_start_auto;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin pkt_delay_cnt <= 0; pkt_start_auto <= 0; end
        else if (rom_packet && !pkt_start_auto && pkt_delay_cnt < inject_delay_vio)
            pkt_delay_cnt <= pkt_delay_cnt + 1;
        else if (pkt_delay_cnt == inject_delay_vio && !pkt_start_auto)
            pkt_start_auto <= 1;
        else if (!rom_valid) begin pkt_delay_cnt <= 0; pkt_start_auto <= 0; end
    end
    wire packet_start_eff = rom_valid ? pkt_start_auto : packet_start;


    // ===================================================================
    // DDS: LO LOOK-UP TABLE - sin/cos only, 12-bit, phase input
    // ===================================================================
    wire [31:0] lo_lut_tdata;
    wire signed [11:0] lo_cos = lo_lut_tdata[11:0];
    wire signed [11:0] lo_sin = lo_lut_tdata[27:16];

    // Phase comes from the DDC's internal NCO (exposed via dbg_phase_out)
    wire [23:0] dbg_phase_out;
    wire [15:0] truncated_phase = dbg_phase_out[23:8];

    dds_lo_lut u_lo_lut (
        .aclk               (sys_clk),
        .s_axis_phase_tvalid(ddc_enable),
        .s_axis_phase_tdata (truncated_phase),
        .m_axis_data_tvalid (),
        .m_axis_data_tdata  (lo_lut_tdata)
    );

    // ===================================================================
    // IMBALANCE INJECTOR - 3-stage pipeline from fpga_top_tester.sv
    //   Stage A: multiplies (q*alpha, i*beta) + I path + DC
    //   Stage B: sum multiply products (register break)
    //   Stage C: shift + DC → q_imb output
    // ===================================================================
    reg signed [15:0] alpha_active;
    reg signed [25:0] q_mult_alpha;
    reg signed [25:0] i_mult_beta;
    reg signed [9:0]  i_imb_delay;
    reg signed [25:0] q_sum_stage;
    reg signed [15:0] beta_signed;   // registered signed copy of beta_vio; forces Vivado
                                     // to infer a true signed multiplier - $signed({1'b0,beta_vio})
                                     // gets optimized away because Vivado sees bit[16] is always 0.

    // Injection sequencer - applies alpha_drift after inject_delay cycles
    reg [31:0] inject_counter;
    reg        injected;

    (* mark_debug = "true", KEEP = "true" *) reg signed [9:0] i_imb;
    (* mark_debug = "true", KEEP = "true" *) reg signed [9:0] q_imb;
    (* mark_debug = "true", KEEP = "true" *) reg              inject_now;

    // Registered DC offsets
    reg signed [9:0] dc_i_reg, dc_q_reg;

    always @(posedge sys_clk) begin
        dc_i_reg   <= dc_i_vio;
        dc_q_reg   <= dc_q_vio;
        beta_signed <= beta_vio;   // signed [15:0] reg - beta_vio is always 0..32767
    end

    // Injection sequencer
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            inject_counter <= 32'd0;
            injected       <= 1'b0;
            inject_now     <= 1'b0;
            alpha_active   <= 16'd1024;  // unity
        end else begin
            inject_now <= 1'b0;
            if (!injected) begin
                if (inject_counter == inject_delay_vio) begin
                    injected     <= 1'b1;
                    inject_now   <= 1'b1;
                    alpha_active <= alpha_drift_vio;
                end else begin
                    inject_counter <= inject_counter + 1;
                    alpha_active   <= alpha_vio;
                end
            end else begin
                alpha_active <= alpha_drift_vio;
            end
        end
    end

    // 3-stage imbalance injection pipeline
    always @(posedge sys_clk) begin
        // Stage A: multiplies + I path start
        q_mult_alpha <= (q_ideal >>> 1) * alpha_active;
        i_mult_beta  <= (i_ideal >>> 1) * beta_signed;  // beta_signed is reg signed [15:0]: forces signed multiplier.
                                                              // Previous $signed({1'b0,beta_vio}) was optimized away by Vivado
                                                              // (MSB constant 0 → inferred unsigned). A signed REGISTER cannot
                                                              // be optimized away - Vivado must honour the signed declaration.
        i_imb_delay  <= (i_ideal >>> 1) + dc_i_reg;

        // Stage B: sum multiply products
        q_sum_stage  <= q_mult_alpha + i_mult_beta;
        i_imb        <= i_imb_delay;

        // Stage C: shift + DC → output
        q_imb        <= (q_sum_stage >>> 10) + dc_q_reg;
    end

    // ===================================================================
    // DUT: COMPLETE RX CHAIN
    // ===================================================================
    // Status / debug outputs from the DUT
    wire               iq_tracking;
    wire               iq_fault;
    wire [1:0]         iq_calib_phase;
    wire               dbg_baseband_valid;

    (* mark_debug = "true", KEEP = "true" *) wire signed [9:0]  dbg_iq_i_out;
    (* mark_debug = "true", KEEP = "true" *) wire signed [9:0]  dbg_iq_q_out;
    (* mark_debug = "true", KEEP = "true" *) wire signed [22:0] dbg_mixer_i, dbg_mixer_q;
    (* mark_debug = "true", KEEP = "true" *) wire signed [23:0] dbg_cic_i, dbg_cic_q;
    (* mark_debug = "true", KEEP = "true" *) wire signed [23:0] i_out_baseband, q_out_baseband;
    (* mark_debug = "true", KEEP = "true" *) wire               baseband_valid_out;
    (* mark_debug = "true", KEEP = "true" *) wire signed [11:0] sync_i_out, sync_q_out;
    (* mark_debug = "true", KEEP = "true" *) wire               sync_valid_out;
    (* mark_debug = "true", KEEP = "true" *) wire signed [24:0] dbg_freq_dev;
    (* mark_debug = "true", KEEP = "true" *) wire               rx_bit_out;
    (* mark_debug = "true", KEEP = "true" *) wire               rx_bit_valid;
    (* mark_debug = "true", KEEP = "true" *) wire [8:0]         dbg_bit_count;
    (* mark_debug = "true", KEEP = "true" *) wire               dbg_pe_enable;
    (* mark_debug = "true", KEEP = "true" *) wire [15:0]        dbg_crc_syndrome;
    (* mark_debug = "true", KEEP = "true" *) wire [8:0]         dbg_error_idx;
    (* mark_debug = "true", KEEP = "true" *) wire               packet_valid_out;
    (* mark_debug = "true", KEEP = "true" *) wire               packet_error_out;
    (* mark_debug = "true", KEEP = "true" *) wire [31:0]        payload_preview;   // first 32 bits

    wire [255:0] clean_payload_full;
    assign payload_preview = clean_payload_full[255:224];

    // CFO outputs (for future CORDIC integration)
    wire signed [33:0] cfo_coarse_i, cfo_coarse_q;
    wire               cfo_coarse_valid;
    wire signed [33:0] cfo_fine_i, cfo_fine_q;
    wire               cfo_fine_valid;

    trex1_rx_frontend_top u_rx_chain (
        .clk               (sys_clk),
        .rst_n             (rst_n),
        .enable            (ddc_enable),

        // ADC interface - from imbalance injector
        .raw_i_in          (i_imb),
        .raw_q_in          (q_imb),

        // DDC configuration
        .mode_sel          (mode_sel),
        .fcw               (fcw),
        .cos_lo            (lo_cos),
        .sin_lo            (lo_sin),
        .decimation_rate   (decimation_rate),
        .adc_res_sel       (adc_res_sel),

        // Sync configuration
        .preamble_flag     (preamble_eff),
        .str_kp            (str_kp_vio),
        .str_ki            (str_ki_vio),

        // Packet engine trigger
        .packet_start      (packet_start_eff),

        // I/Q corrector status
        .iq_tracking       (iq_tracking),
        .iq_fault          (iq_fault),
        .iq_calib_phase    (iq_calib_phase),

        // Debug - I/Q corrector
        .dbg_iq_i_out      (dbg_iq_i_out),
        .dbg_iq_q_out      (dbg_iq_q_out),

        // Debug - DDC
        .dbg_mixer_i       (dbg_mixer_i),
        .dbg_mixer_q       (dbg_mixer_q),
        .dbg_cic_i         (dbg_cic_i),
        .dbg_cic_q         (dbg_cic_q),
        .dbg_phase_out     (dbg_phase_out),
        .dbg_baseband_valid(dbg_baseband_valid),

        // Debug - Sync
        .dbg_agc_i_out     (),   // connected internally for debug
        .dbg_agc_q_out     (),
        .dbg_agc_valid_out (),

        // Debug - GMSK
        .dbg_freq_dev      (dbg_freq_dev),

        // Debug - PE
        .dbg_bit_count     (dbg_bit_count),
        .dbg_pe_enable     (dbg_pe_enable),
        .dbg_crc_syndrome  (dbg_crc_syndrome),
        .dbg_error_idx     (dbg_error_idx),

        // DDC baseband
        .i_out_baseband    (i_out_baseband),
        .q_out_baseband    (q_out_baseband),
        .baseband_valid_out(baseband_valid_out),

        // Sync output
        .sync_i_out        (sync_i_out),
        .sync_q_out        (sync_q_out),
        .sync_valid_out    (sync_valid_out),

        // CFO outputs
        .cfo_coarse_i      (cfo_coarse_i),
        .cfo_coarse_q      (cfo_coarse_q),
        .cfo_coarse_valid  (cfo_coarse_valid),
        .cfo_fine_i        (cfo_fine_i),
        .cfo_fine_q        (cfo_fine_q),
        .cfo_fine_valid    (cfo_fine_valid),

        // GMSK output
        .rx_bit_out        (rx_bit_out),
        .rx_bit_valid      (rx_bit_valid),

        // Packet engine output
        .clean_payload_out (clean_payload_full),
        .packet_valid      (packet_valid_out),
        .packet_error      (packet_error_out)
    );

    // LED[0] = green = CRC passed;  LED[1] = red = PE ran but CRC failed
    assign LED[0] = (dbg_crc_syndrome == 16'h0000) && (dbg_bit_count == 9'd0) && !dbg_pe_enable;
    assign LED[1] = (dbg_crc_syndrome != 16'h0000) && (dbg_bit_count == 9'd0) && !dbg_pe_enable;

    // ===================================================================
    // DECODE-EVENT ILA TRIGGER  (added for end-to-end packet capture)
    // -------------------------------------------------------------------
    // Single-cycle pulse when the packet engine produces a result -
    // either a valid packet or an uncorrectable error. Arm the ILA and
    // set its trigger to  decode_event == 1  so the capture window lands
    // on the decode instant (crc_syndrome, error_idx, payload_preview,
    // packet_valid_out) instead of the preamble.
    //
    // Also latch the packet result so it survives in the window even if
    // the ILA depth is shorter than the packet: cap_* hold the outcome
    // of the most recent decode until the next reset.
    // ===================================================================
    (* mark_debug = "true", KEEP = "true" *) reg         decode_event;
    (* mark_debug = "true", KEEP = "true" *) reg  [15:0] cap_crc_syndrome;
    (* mark_debug = "true", KEEP = "true" *) reg  [8:0]  cap_error_idx;
    (* mark_debug = "true", KEEP = "true" *) reg  [31:0] cap_payload_preview;
    (* mark_debug = "true", KEEP = "true" *) reg         cap_packet_valid;
    (* mark_debug = "true", KEEP = "true" *) reg         cap_packet_error;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            decode_event        <= 1'b0;
            cap_crc_syndrome    <= 16'd0;
            cap_error_idx       <= 9'h1FF;
            cap_payload_preview <= 32'd0;
            cap_packet_valid    <= 1'b0;
            cap_packet_error    <= 1'b0;
        end else begin
            decode_event <= packet_valid_out | packet_error_out;
            if (packet_valid_out | packet_error_out) begin
                cap_crc_syndrome    <= dbg_crc_syndrome;
                cap_error_idx       <= dbg_error_idx;
                cap_payload_preview <= payload_preview;
                cap_packet_valid    <= packet_valid_out;
                cap_packet_error    <= packet_error_out;
            end
        end
    end

endmodule
