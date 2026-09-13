`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    iq_corrector_ll_lms
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    I/Q imbalance corrector using a Log-Log LMS adaptive filter.
//                 Removes DC offset, then adaptively corrects phase and gain
//                 imbalance between the I and Q ADC paths using a gear-shift
//                 (fast-then-slow step size) calibration schedule, with an
//                 integrate-and-dump fault detector that can force a full
//                 recalibration if the correction degrades. Pipelined across
//                 6 stages (S0-S5) for timing closure - see the design note
//                 below for the pipeline map and bit-width rationale.
// Dependencies:   Instantiated by trex1_rx_frontend_top.v (u_iq_corrector),
//                 ahead of the DDC front end in the receive chain.
//
//////////////////////////////////////////////////////////////////////////////////

// ============================================================
//  IQ Corrector - Log-Log LMS  (PIPELINED for timing closure)
//
//  Pipeline map:
//    Stage 0 (S0): DC blocker
//    Stage 1 (S1): Phase multiply  (w_phase_reg * i_ac)
//    Stage 2 (S2): Phase add + Gain multiply (w_gain_reg * q_ortho)
//    Stage 3 (S3): Gain add + saturation + |I|, |Q|
//    Stage 4 (S4): Log + barrel-shift (delta computation)
//    Stage 5 (S5): Weight update + saturation
//
//  w_gain_reg is [33:0] (34-bit signed) to accommodate large gain
//  corrections without overflow. Required weight for alpha=300 is
//  ~2.59e9, which exceeds the 32-bit signed range (2.15e9 max).
//  34-bit signed covers up to 8.59e9, safely handling alpha >= ~125.
//  w_phase_reg remains [31:0] - phase cross-term corrections are
//  small (< 150M for beta <= 150) and fit comfortably in 32 bits.
// ============================================================
module iq_corrector_ll_lms #(
    parameter int BIT_WIDTH         = 10,

    // ── Gear-shift step sizes ─────────────────────────────────
    parameter int CALIB_SHIFT_P0    = 3,
    parameter int CALIB_SHIFT_P1    = 6,
    parameter int CALIB_SHIFT_P2    = 9,
    parameter int TRACK_SHIFT       = 12,

    // ── Calibration phase cycle budgets ──────────────────────
    parameter int CALIB_CYCLES_P0   = 2000000,
    parameter int CALIB_CYCLES_P1   = 0,
    parameter int CALIB_CYCLES_P2   = 0,

    // ── Fault detector (integrate-and-dump) ──────────────────
    parameter int DDS_PERIOD        = 1000,
    parameter int FAULT_THR         = 500,
    parameter int FAULT_CONFIRM     = 3,
    parameter int FAULT_COOLDOWN    = 2000000,
    parameter int FAULT_BLANKING    = 2000,
    parameter int SIGNAL_MIN        = 64
)(
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic signed [BIT_WIDTH-1:0] i_in,
    input  logic signed [BIT_WIDTH-1:0] q_in,

    output logic signed [BIT_WIDTH-1:0] i_out,
    output logic signed [BIT_WIDTH-1:0] q_out,

    output logic                        is_tracking,

    (* keep = "true", mark_debug = "true" *)
    output logic                        fault_detected,

    (* keep = "true", mark_debug = "true" *)
    output logic [1:0]                  calib_phase
);

    // --------------------------------------------------------
    // Log-Log LMS Priority Encoder
    // --------------------------------------------------------
    // Returns floor(log2(val)): the bit position of the MSB set in val.
    // Used to implement the "log" half of the Log-Log LMS update (an
    // approximate log-domain magnitude in place of a true logarithm,
    // cheap to compute and adequate for a step-size/error estimator).
    function automatic logic [3:0] msb_pos(input logic [10:0] val);
        logic [3:0] pos;
        begin
            if      (val[10]) pos = 10;
            else if (val[9])  pos = 9;
            else if (val[8])  pos = 8;
            else if (val[7])  pos = 7;
            else if (val[6])  pos = 6;
            else if (val[5])  pos = 5;
            else if (val[4])  pos = 4;
            else if (val[3])  pos = 3;
            else if (val[2])  pos = 2;
            else if (val[1])  pos = 1;
            else              pos = 0;
            return pos;
        end
    endfunction

    // --------------------------------------------------------
    // Phase boundary constants
    // --------------------------------------------------------
    localparam int PHASE1_START = CALIB_CYCLES_P0;
    localparam int PHASE2_START = CALIB_CYCLES_P0 + CALIB_CYCLES_P1;
    localparam int TRACK_START  = CALIB_CYCLES_P0 + CALIB_CYCLES_P1 + CALIB_CYCLES_P2;

    // --------------------------------------------------------
    // Weights
    // --------------------------------------------------------
    (* keep = "true", mark_debug = "true" *) logic signed [31:0] w_phase_reg;
    (* keep = "true", mark_debug = "true" *) logic signed [33:0] w_gain_reg;

    // --------------------------------------------------------
    // FSM & counter
    // --------------------------------------------------------
    logic [31:0]        cycle_counter;
    logic [3:0] current_mu_shift;   // max value = TRACK_SHIFT=12, fits in 4 bits
    logic               do_reset;

    // --------------------------------------------------------
    // DC Blocker (S0)
    // --------------------------------------------------------
    logic signed [23:0]          dc_acc_i_in;
    logic signed [23:0]          dc_acc_q_in;
    logic signed [BIT_WIDTH-1:0] i_ac;
    logic signed [BIT_WIDTH-1:0] q_ac;

    // --------------------------------------------------------
    // Squelch: detect a silent raw input ahead of the DC blocker.
    //
    // Root cause (hardware bring-up, DDC non-settling on signal
    // dropout): dc_acc_i_in/dc_acc_q_in is a leaky integrator with
    // pole (1 - 2^-10), i.e. a ~1024-sample time constant. When
    // i_in/q_in drop to exactly 0, the accumulator does NOT reset -
    // it keeps holding its last DC estimate, so
    // i_ac <= i_in - (dc_acc_i_in>>>10) manufactures a small,
    // slowly-decaying phantom AC residual purely from subtracting a
    // stale estimate from a silent input. That residual is enough,
    // after the NCO mixer and the CIC's R^N passband gain, to hold
    // the DDC output at a large, rotating, non-zero value for
    // ~1600+ cycles after the true input goes quiet (measured on
    // hardware via ILA capture).
    //
    // Fix: reuse the existing SIGNAL_MIN threshold (already used by
    // the fault detector's signal_strong check) to detect silence on
    // the raw input, and freeze the DC estimate / zero the AC path
    // instead of letting the leaky integrator bleed out over ~1000+
    // cycles.
    // --------------------------------------------------------
    logic signed [10:0] abs_i_in_raw, abs_q_in_raw;
    logic                input_silent;

    always_comb begin
        abs_i_in_raw = (i_in < 0) ? -i_in : i_in;
        abs_q_in_raw = (q_in < 0) ? -q_in : q_in;
        input_silent = ({1'b0, abs_i_in_raw} + {1'b0, abs_q_in_raw}) < SIGNAL_MIN[11:0];
    end

    // --------------------------------------------------------
    // Stage 1 (S1): Phase multiply
    // --------------------------------------------------------
    logic signed [BIT_WIDTH-1:0] s1_i;
    logic signed [BIT_WIDTH-1:0] s1_q;
    logic signed [41:0]          s1_phase_mult;  // 32b × 10b - uses [31:5] (27b) for DSP fit

    // --------------------------------------------------------
    // Stage 2 (S2): Phase add + Gain multiply
    // --------------------------------------------------------
    logic signed [BIT_WIDTH-1:0] s2_i;
    logic signed [11:0]          s2_q_ortho;
    logic signed [38:0]          s2_gain_mult;  // 27b (w_gain[33:7]) × 12b = 39b; uses [33:7] for single DSP48E1
    logic signed [BIT_WIDTH-1:0] s2_q_raw;      // raw q_ac carried through S2 (pre-correction)

    // --------------------------------------------------------
    // Phase error path: raw Q delayed to Stage 3
    // The corrector never modifies I, so s3_i_out == delayed i_ac.
    // For the phase LMS we need q_ac (pre-correction) at the same
    // pipeline depth. s2_q_raw → s3_q_raw carries it through.
    // --------------------------------------------------------
    logic signed [BIT_WIDTH-1:0] s3_q_raw;      // q_ac delayed to S3 (pre-correction)
    logic signed [10:0]          s3_abs_q_raw;   // |q_ac| for phase delta magnitude

    // --------------------------------------------------------
    // Stage 3 (S3): Gain add + saturation + abs
    // --------------------------------------------------------
    logic signed [BIT_WIDTH-1:0] s3_i_out;
    logic signed [BIT_WIDTH-1:0] s3_q_out;
    logic signed [10:0]          s3_abs_i;
    logic signed [10:0]          s3_abs_q;
    logic signed [11:0]          s3_err_gain;
    logic [3:0]          s3_mu_shift;   // captured for S4 (4b, max=12)

    // --------------------------------------------------------
    // Stage 4 (S4): Log + barrel-shift (delta computation)
    // --------------------------------------------------------
    logic signed [31:0]          s4_delta_phase;
    logic signed [31:0]          s4_delta_gain;

    // Registered copy of err_gain for the fault detector
    (* keep = "true" *) logic signed [11:0] err_gain_reg;
    logic signed [10:0] abs_i_reg;
    logic signed [10:0] abs_q_reg;

    // --------------------------------------------------------
    // Fault detector (integrate-and-dump)
    // --------------------------------------------------------
    (* keep = "true", mark_debug = "true" *) logic signed [31:0] fault_acc;
    (* keep = "true", mark_debug = "true" *) logic signed [31:0] fault_period_sum;
    logic [15:0]        fault_period_cnt;
    logic [15:0]        fault_strong_cnt;
    logic [7:0]         fault_confirm_cnt;
    logic [31:0]        cooldown_cnt;
    logic               in_cooldown;
    logic [31:0]        blanking_cnt;
    logic               in_blanking;
    logic               signal_strong;
    logic [31:0]        fault_sum_abs;
    logic               period_done;
    logic               period_valid;
    logic               period_over;

    // ============================================================
    //  3-Phase Gear-Shift FSM  +  Fault Auto-Recalib
    // ============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter  <= 0;
            calib_phase    <= 2'd0;
            is_tracking    <= 1'b0;
            fault_detected <= 1'b0;
            cooldown_cnt   <= 0;
            blanking_cnt   <= 0;

        end else begin
            fault_detected <= 1'b0;

            if (cooldown_cnt > 0)
                cooldown_cnt <= cooldown_cnt - 1;

            if (do_reset) begin
                calib_phase    <= 2'd0;
                cycle_counter  <= 0;
                is_tracking    <= 1'b0;
                fault_detected <= 1'b1;
                cooldown_cnt   <= FAULT_COOLDOWN[31:0];
                blanking_cnt   <= 0;

            end else if (calib_phase == 2'd3) begin
                is_tracking <= 1'b1;
                if (blanking_cnt > 0)
                    blanking_cnt <= blanking_cnt - 1;

            end else begin
                cycle_counter <= cycle_counter + 1;

                if (calib_phase == 2'd0 && cycle_counter == (PHASE1_START - 1)) begin
                    if      (CALIB_CYCLES_P1 > 0) calib_phase <= 2'd1;
                    else if (CALIB_CYCLES_P2 > 0) calib_phase <= 2'd2;
                    else begin
                        calib_phase <= 2'd3;
                        is_tracking <= 1'b1;
                        blanking_cnt <= FAULT_BLANKING[31:0];
                    end

                end else if (calib_phase == 2'd1 && cycle_counter == (PHASE2_START - 1)) begin
                    if (CALIB_CYCLES_P2 > 0) calib_phase <= 2'd2;
                    else begin
                        calib_phase <= 2'd3;
                        is_tracking <= 1'b1;
                        blanking_cnt <= FAULT_BLANKING[31:0];
                    end

                end else if (calib_phase == 2'd2 && cycle_counter == (TRACK_START - 1)) begin
                    calib_phase <= 2'd3;
                    is_tracking <= 1'b1;
                    blanking_cnt <= FAULT_BLANKING[31:0];
                end
            end
        end
    end

    // ── Step-size mux ──────────────────────────────────────────
    always_comb begin
        case (calib_phase)
            2'd0:    current_mu_shift = CALIB_SHIFT_P0;
            2'd1:    current_mu_shift = CALIB_SHIFT_P1;
            2'd2:    current_mu_shift = CALIB_SHIFT_P2;
            default: current_mu_shift = TRACK_SHIFT;
        endcase
    end

    // ============================================================
    //  Pipelined Datapath
    // ============================================================

    // ── Stage 0: DC Offset Removal ──────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dc_acc_i_in <= 0;
            dc_acc_q_in <= 0;
            i_ac        <= 0;
            q_ac        <= 0;
        end else if (do_reset) begin
            dc_acc_i_in <= 0;
            dc_acc_q_in <= 0;
            i_ac        <= 0;
            q_ac        <= 0;
        end else if (input_silent) begin
            // Squelch: hold the DC estimate (don't drift it further
            // on silence in either direction) and force the AC path
            // to exact zero, rather than subtracting a stale DC
            // estimate from a silent input.
            i_ac <= 0;
            q_ac <= 0;
        end else begin
            dc_acc_i_in <= dc_acc_i_in + i_in - (dc_acc_i_in >>> 10);
            dc_acc_q_in <= dc_acc_q_in + q_in - (dc_acc_q_in >>> 10);
            i_ac <= i_in - BIT_WIDTH'(dc_acc_i_in >>> 10);
            q_ac <= q_in - BIT_WIDTH'(dc_acc_q_in >>> 10);
        end
    end

    // ── Stage 1: Phase Multiply ─────────────────────────────────
    //  Compute: phase_mult = w_phase_reg * i_ac
    //  Pass through i_ac and q_ac for the next stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_i          <= 0;
            s1_q          <= 0;
            s1_phase_mult <= 0;
        end else if (do_reset) begin
            s1_i          <= 0;
            s1_q          <= 0;
            s1_phase_mult <= 0;
        end else begin
            s1_i          <= i_ac;
            s1_q          <= q_ac;
            // w_phase_reg[31:0] × i_ac[9:0]: 32×10 spans 2 DSP48E1s (A-input max 27b).
            // Use top 27 bits [31:5]; compensate by changing the downstream >>> 30 to >>> 25.
            // Drops 5 LSBs of weight precision - < 0.001% effect at convergence.
            s1_phase_mult <= $signed(w_phase_reg[31:5]) * i_ac;
        end
    end

    // ── Stage 2: Phase Add + Gain Multiply ──────────────────────
    //  Compute: q_ortho = q + (phase_mult >>> 30)
    //           gain_mult = w_gain_reg * q_ortho
    //  The gain multiply starts here; its result is used in S3.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_i         <= 0;
            s2_q_ortho   <= 0;
            s2_gain_mult <= 0;
            s2_q_raw     <= 0;
        end else if (do_reset) begin
            s2_i         <= 0;
            s2_q_ortho   <= 0;
            s2_gain_mult <= 0;
            s2_q_raw     <= 0;
        end else begin
            logic signed [11:0] q_ortho_comb;
            // Shift compensated: was >>> 30 for w_phase_reg full 32b; now 27b [31:5] so >>> 25.
            q_ortho_comb  = s1_q + (s1_phase_mult >>> 25);

            s2_i         <= s1_i;
            s2_q_ortho   <= q_ortho_comb;
            // w_gain_reg[33:0] × q_ortho[11:0]: 34×12 spans 2 DSP48E1s on Artix-7 (A max 27b).
            // Use top 27 bits [33:7]; compensate by changing downstream >>> 30 to >>> 23.
            // Drops 7 LSBs of weight precision - < 0.0001% effect at convergence.
            s2_gain_mult <= $signed(w_gain_reg[33:7]) * q_ortho_comb;
            s2_q_raw     <= s1_q;   // raw q_ac, untouched by phase/gain correction
        end
    end

    // ── Stage 3: Gain Add + Saturation + Abs + Error ────────────
    //  Compute: q_out_full = q_ortho + (gain_mult >>> 30)
    //           abs_i, abs_q, err_gain
    //  Outputs i_out, q_out (final corrected samples)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_i_out    <= 0;
            s3_q_out    <= 0;
            s3_abs_i    <= 0;
            s3_abs_q    <= 0;
            s3_err_gain <= 0;
            s3_mu_shift <= 0;
            i_out       <= 0;
            q_out       <= 0;
            err_gain_reg <= 0;
            abs_i_reg    <= 0;
            abs_q_reg    <= 0;
            s3_q_raw     <= 0;
            s3_abs_q_raw <= 0;
        end else if (do_reset) begin
            s3_i_out    <= 0;
            s3_q_out    <= 0;
            s3_abs_i    <= 0;
            s3_abs_q    <= 0;
            s3_err_gain <= 0;
            s3_mu_shift <= 0;
            i_out       <= 0;
            q_out       <= 0;
            err_gain_reg <= 0;
            abs_i_reg    <= 0;
            abs_q_reg    <= 0;
            s3_q_raw     <= 0;
            s3_abs_q_raw <= 0;
        end else begin
            logic signed [15:0] q_full;
            logic signed [BIT_WIDTH-1:0] q_sat;
            logic signed [10:0] ai, aq;

            // Gain add + saturation
            // s2_gain_mult used w_gain_reg[33:7] (27b), so effective Q-format is Q23 (was Q30).
            q_full = 16'(s2_q_ortho) + 16'(s2_gain_mult >>> 23);

            if      (q_full >  16'sd511) q_sat =  10'sd511;
            else if (q_full < -16'sd511) q_sat = -10'sd511;
            else                         q_sat =  q_full[9:0];

            // Output the corrected samples
            i_out <= s2_i;
            q_out <= q_sat;

            // Also latch for error computation
            s3_i_out <= s2_i;
            s3_q_out <= q_sat;

            // Absolute values
            ai = (s2_i < 0)  ? -s2_i  : s2_i;
            aq = (q_sat < 0) ? -q_sat : q_sat;

            s3_abs_i    <= ai;
            s3_abs_q    <= aq;
            // Gain error term: |I| - |Q|. For a well-balanced signal these
            // magnitudes should match on average; a positive/negative bias
            // drives the gain weight update below to shrink/grow q_out.
            s3_err_gain <= $signed({1'b0, ai}) - $signed({1'b0, aq});
            s3_mu_shift <= current_mu_shift;

            // Registered copies for fault detector (1 cycle later)
            err_gain_reg <= $signed({1'b0, ai}) - $signed({1'b0, aq});
            abs_i_reg    <= ai;
            abs_q_reg    <= aq;

            // Raw (pre-correction) Q pipeline for phase LMS
            s3_q_raw     <= s2_q_raw;
            s3_abs_q_raw <= (s2_q_raw < 0) ? -s2_q_raw : s2_q_raw;
        end
    end

    // ── Stage 4: Log + Barrel-Shift (Delta Computation) ─────────
    //  All the log-domain math and variable shifts happen here.
    //  This is now the only stage with barrel shifts, keeping
    //  combinational depth manageable.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_delta_phase <= 0;
            s4_delta_gain  <= 0;
        end else if (do_reset) begin
            s4_delta_phase <= 0;
            s4_delta_gain  <= 0;
        end else begin
            logic [3:0]          li, lq;
            logic [4:0]          lsum;
            logic                psign, is_zero;
            logic signed [31:0]  raw_dp, dp;
            logic signed [31:0]  scaled_eg, dg;

            // Phase error via log-log - use PRE-CORRECTION signals
            // s3_i_out == delayed i_ac (I path is never modified by corrector)
            // s3_q_raw == delayed q_ac (raw input, before phase/gain correction)
            // E[sign(i_ac) XOR sign(q_ac_raw)] is biased when beta≠0,
            // giving the phase LMS a consistent gradient even after gain converges.
            li    = msb_pos(s3_abs_i);
            lq    = msb_pos(s3_abs_q);
            lsum  = li + lq;
            psign = s3_i_out[BIT_WIDTH-1] ^ s3_err_gain[11];
            is_zero = (s3_abs_i == 0) || (s3_abs_q_raw == 0);

            // Log-Log step: magnitude of the phase update grows with the
            // combined "log-magnitude" of I and Q (lsum), shrunk by the
            // current gear-shift mu_shift - a large step early in
            // calibration, a small one once tracking (see mu mux above).
            raw_dp = (32'd1 << lsum) >> s3_mu_shift;
            if (raw_dp == 0) raw_dp = 1;
            dp = is_zero ? 32'd0 : (psign ? -raw_dp : raw_dp);

            // Gain error delta
            scaled_eg = 32'(s3_err_gain) <<< 8;

            // Arithmetic right shift replaces the sign-magnitude abs→shift→renegate
            // chain that caused CARRY4×7 timing violations (17 logic levels → ~6).
            // For LMS the ≤1 LSB rounding difference is inconsequential to convergence.
            dg = scaled_eg >>> s3_mu_shift;

            if (dg == 0 && s3_err_gain != 0)
                dg = (s3_err_gain > 0) ? 1 : -1;

            s4_delta_phase <= dp;
            s4_delta_gain  <= dg;
        end
    end

    // ── Stage 5: Weight Update + Saturation ─────────────────────
    //  Simple add + clamp. Very short combinational path.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_phase_reg <= 0;
            w_gain_reg  <= 0;
        end else if (do_reset) begin
            // do_reset: don't clear weights (preserve calibration
            // if fault detector fires and recalibrates)
            // -- actually original cleared on rst_n only, same here
        end else begin
            logic signed [31:0] nwp;
            logic signed [33:0] nwg;

            // Phase weight moves opposite the phase delta (gradient
            // descent); gain weight moves with the gain delta.
            nwp = w_phase_reg - s4_delta_phase;
            nwg = w_gain_reg  + 34'(s4_delta_gain);

            // Saturate each weight to its documented safe range (see the
            // module-header note on w_gain_reg/w_phase_reg sizing) so a
            // runaway update cannot wrap the accumulator.
            if      (nwp >  32'sd858993459) w_phase_reg <=  32'sd858993459;
            else if (nwp < -32'sd858993459) w_phase_reg <= -32'sd858993459;
            else                            w_phase_reg <=  nwp;

            if      (nwg >  34'sd6442450943) w_gain_reg <=  34'sd6442450943;
            else if (nwg < -34'sd6442450943) w_gain_reg <= -34'sd6442450943;
            else                             w_gain_reg <=  nwg;
        end
    end

    // ============================================================
    //  Fault Detector - Integrate-and-Dump
    // ============================================================

    assign signal_strong = ({1'b0, abs_i_reg} + {1'b0, abs_q_reg}) > SIGNAL_MIN[11:0];

    assign fault_sum_abs = fault_period_sum[31] ? $unsigned(-fault_period_sum)
                                                : $unsigned( fault_period_sum);

    assign in_cooldown  = (cooldown_cnt != 0);
    assign in_blanking  = (blanking_cnt != 0);

    assign period_done  = (fault_period_cnt == (DDS_PERIOD[15:0] - 1));
    assign period_valid = (fault_strong_cnt >= (DDS_PERIOD[15:0] >> 1));
    assign period_over  = (fault_sum_abs > FAULT_THR[31:0]);

    assign do_reset     = (fault_confirm_cnt == FAULT_CONFIRM[7:0])
                          && (calib_phase == 2'd3)
                          && !in_cooldown
                          && !in_blanking;

    // Integrates the gain error over DDS_PERIOD-cycle windows (one full
    // injected-tone period) and only declares a fault if FAULT_CONFIRM
    // consecutive windows all exceed FAULT_THR while the signal is present
    // (period_valid) - filters out single-window noise spikes.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_acc         <= 32'sd0;
            fault_period_sum  <= 32'sd0;
            fault_period_cnt  <= 0;
            fault_strong_cnt  <= 0;
            fault_confirm_cnt <= 0;

        end else if (calib_phase == 2'd3 && !in_cooldown && !in_blanking) begin
            if (signal_strong)
                fault_acc <= fault_acc + $signed({{20{err_gain_reg[11]}}, err_gain_reg});

            if (signal_strong)
                fault_strong_cnt <= fault_strong_cnt + 1;

            if (period_done) begin
                fault_period_sum <= fault_acc
                                    + (signal_strong
                                       ? $signed({{20{err_gain_reg[11]}}, err_gain_reg})
                                       : 32'sd0);

                fault_acc        <= 32'sd0;
                fault_period_cnt <= 0;
                fault_strong_cnt <= 0;

                if (period_valid && period_over) begin
                    if (fault_confirm_cnt < FAULT_CONFIRM[7:0])
                        fault_confirm_cnt <= fault_confirm_cnt + 1;
                end else begin
                    fault_confirm_cnt <= 0;
                end

            end else begin
                fault_period_cnt <= fault_period_cnt + 1;
            end

        end else begin
            fault_acc         <= 32'sd0;
            fault_period_sum  <= 32'sd0;
            fault_period_cnt  <= 0;
            fault_strong_cnt  <= 0;
            fault_confirm_cnt <= 0;
        end
    end

endmodule
