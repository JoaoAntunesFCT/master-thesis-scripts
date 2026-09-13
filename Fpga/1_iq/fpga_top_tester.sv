`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company:             NOVA SST
// Engineer:            Joao Reis Antunes
//
// Create Date:         05-2026 (mm-yyyy)
// Module Name:         fpga_top_tester
// Project Name:        TREX1 Digital Baseband Chain
// Target Devices:      Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:         Synthesizable bench harness for the IQ-imbalance corrector.
//                      Generates an ideal I/Q tone from a DDS core, applies a
//                      programmable gain/phase imbalance through a 3-stage
//                      pipelined injector (with a VIO-triggered runtime "drift"
//                      step, switched in after a programmable delay, to exercise
//                      the corrector's fault-detector / auto-recalibration path),
//                      and drives the iq_corrector_ll_lms DUT. A VIO exposes
//                      reset, imbalance, and DC-offset controls; ILA-marked
//                      probes expose DUT status for on-chip characterization.
//
// Dependencies:        vio_0 (Vivado VIO IP), dds_compiler_0 (Vivado DDS
//                      Compiler IP), iq_corrector_ll_lms (DUT)
//
// Revision:
// Additional Comments: Unchanged from the original bench harness except
//                      that the imbalance injector's Q path is split
//                      across pipeline stages (multiply -> sum -> shift)
//                      so no single stage combines a multiply, an add,
//                      and a DC-offset add.
//
//////////////////////////////////////////////////////////////////////////////////
module fpga_top_tester(
    input  wire clk_100mhz,
    output wire inject_now_pin
);

    // ── VIO outputs ──────────────────────────────────────────────
    logic               rst_n_vio;
    logic signed [15:0] alpha_vio;
    logic signed [15:0] beta_vio;
    logic signed [9:0]  dc_i_vio;
    logic signed [9:0]  dc_q_vio;
    logic signed [15:0] alpha_drift_vio;
    logic        [31:0] inject_delay_vio;

    // ── DDS ──────────────────────────────────────────────────────
    logic [31:0]        dds_data;
    logic signed [9:0]  dds_i_ideal, dds_q_ideal;

    // ── Injector internals ───────────────────────────────────────
    logic signed [15:0] alpha_active;
    logic signed [25:0] q_mult_alpha;
    logic signed [25:0] i_mult_beta;
    logic signed [9:0]  i_imb_delay;
    logic signed [25:0] q_sum_stage;     // NEW: registered multiply sum

    // ── Injection sequencer ──────────────────────────────────────
    logic [31:0] inject_counter;
    logic        injected;

    // ── ILA probes ───────────────────────────────────────────────
    (* keep = "true", mark_debug = "true" *) logic signed [9:0]  i_imb;
    (* keep = "true", mark_debug = "true" *) logic signed [9:0]  q_imb;
    (* keep = "true", mark_debug = "true" *) logic signed [9:0]  i_corrected;
    (* keep = "true", mark_debug = "true" *) logic signed [9:0]  q_corrected;
    (* keep = "true", mark_debug = "true" *) logic               is_tracking;
    (* keep = "true", mark_debug = "true" *) logic               fault_detected;
    (* keep = "true", mark_debug = "true" *) logic [1:0]         calib_phase;
    (* keep = "true", mark_debug = "true" *) logic               inject_now;

    assign inject_now_pin = inject_now;

    // ── 1. VIO ───────────────────────────────────────────────────
    // Runtime knobs (reset, injected gain/phase imbalance, DC
    // offsets, drift target/delay) plus read-back of DUT status,
    // for interactive bench control via Vivado hardware manager.
    vio_0 vio_inst (
        .clk         (clk_100mhz),
        .probe_out0  (rst_n_vio),
        .probe_out1  (alpha_vio),
        .probe_out2  (beta_vio),
        .probe_out3  (dc_i_vio),
        .probe_out4  (dc_q_vio),
        .probe_out5  (alpha_drift_vio),
        .probe_out6  (inject_delay_vio),
        .probe_in0   (is_tracking),
        .probe_in1   (calib_phase),
        .probe_in2   (fault_detected)
    );

    // ── 2. DDS Compiler ──────────────────────────────────────────
    // Generates the ideal (imbalance-free) I/Q test tone that the
    // injector below then distorts before it reaches the DUT.
    dds_compiler_0 dds_inst (
        .aclk               (clk_100mhz),
        .m_axis_data_tvalid (),
        .m_axis_data_tdata  (dds_data)
    );

    assign dds_i_ideal = dds_data[9:0];
    assign dds_q_ideal = dds_data[25:16];

    // ── 3. Injection Sequencer ───────────────────────────────────
    // Free-running "drift" injector: alpha_active tracks alpha_vio
    // until inject_counter reaches inject_delay_vio, at which point
    // it latches to alpha_drift_vio for the remainder of the run
    // (one-shot, via the 'injected' flag) and pulses inject_now for
    // one cycle. This lets the bench emulate a gain imbalance that
    // steps to a new value mid-run, e.g. to exercise the DUT's
    // fault detector / auto-recalibration path.
    always_ff @(posedge clk_100mhz) begin
        if (!rst_n_vio) begin
            inject_counter <= 0;
            injected       <= 1'b0;
            inject_now     <= 1'b0;
            alpha_active   <= alpha_vio;

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

    // ── 4. Imbalance Injector (3-stage pipeline) ─────────────────
    //
    //  Stage A: multiplies (q*alpha, i*beta) + I half-scale + DC
    //  Stage B: sum the two multiply products (register break)
    //  Stage C: shift + DC add → q_imb output
    //
    //  I path has matching 2-reg delay so I and Q are aligned.

    // Registered DC offsets for cleaner timing
    logic signed [9:0] dc_i_reg, dc_q_reg;

    always_ff @(posedge clk_100mhz) begin
        dc_i_reg <= dc_i_vio;
        dc_q_reg <= dc_q_vio;
    end

    always_ff @(posedge clk_100mhz) begin
        // Stage A: multiplies + I path start
        q_mult_alpha <= (dds_q_ideal >>> 1) * alpha_active;
        i_mult_beta  <= (dds_i_ideal >>> 1) * beta_vio;
        i_imb_delay  <= (dds_i_ideal >>> 1) + dc_i_reg;

        // Stage B: sum the multiply products (breaks the mult+add+shift chain)
        q_sum_stage  <= q_mult_alpha + i_mult_beta;
        i_imb        <= i_imb_delay;

        // Stage C: shift + DC → output
        q_imb        <= (q_sum_stage >>> 10) + dc_q_reg;
    end

    // ── 5. DUT: IQ Corrector ─────────────────────────────────────
    iq_corrector_ll_lms #(
        .BIT_WIDTH        (10),

        .CALIB_SHIFT_P0   (3),
        .CALIB_SHIFT_P1   (6),
        .CALIB_SHIFT_P2   (9),
        .TRACK_SHIFT      (12),

        .CALIB_CYCLES_P0  (2000000),
        .CALIB_CYCLES_P1  (0),
        .CALIB_CYCLES_P2  (0),

        .DDS_PERIOD       (1000),
        .FAULT_THR        (500),
        .FAULT_CONFIRM    (3),
        .FAULT_COOLDOWN   (2000000),
        .FAULT_BLANKING   (2000),
        .SIGNAL_MIN       (64)
    ) dut (
        .clk            (clk_100mhz),
        .rst_n          (rst_n_vio),
        .i_in           (i_imb),
        .q_in           (q_imb),
        .i_out          (i_corrected),
        .q_out          (q_corrected),
        .is_tracking    (is_tracking),
        .fault_detected (fault_detected),
        .calib_phase    (calib_phase)
    );

endmodule
