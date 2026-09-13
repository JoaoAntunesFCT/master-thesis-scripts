`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    iq_corrector_ll_lms
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Pipelined IQ-imbalance corrector using the "Log-Log LMS"
//                 algorithm: a >>10 leaky-integrator DC blocker feeds a
//                 phase/gain correction stage (two adaptive weights,
//                 w_phase_reg and w_gain_reg), driven by a multiply-free
//                 LMS-style weight update that approximates the adaptation
//                 step with floor(log2(|I|)) + floor(log2(|Q|)) followed by
//                 a barrel shift instead of a real multiply. A 3-phase
//                 gear-shift FSM calibrates with 3 progressively slower
//                 step sizes before switching to continuous tracking, and
//                 an integrate-and-dump fault detector watches the
//                 residual error and can force a full recalibration.
//
// Dependencies:   Instantiated by fpga_top_tester.sv (bench harness) as
//                 part of the TREX1 Digital Baseband Chain.
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
    // Barrel-shift amount used in place of an LMS step size (mu);
    // a LARGER shift means a SMALLER effective step. Calibration
    // ramps from the coarsest/fastest step (P0) down to the
    // finest/slowest (P2) before handing off to TRACK_SHIFT for
    // continuous tracking.
    parameter int CALIB_SHIFT_P0    = 3,
    parameter int CALIB_SHIFT_P1    = 6,
    parameter int CALIB_SHIFT_P2    = 9,
    parameter int TRACK_SHIFT       = 12,

    // ── Calibration phase cycle budgets ──────────────────────
    // Number of clock cycles spent in each gear-shift phase before
    // advancing (a phase with a 0-cycle budget is skipped).
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
    // Returns floor(log2(val)) for an 11-bit unsigned magnitude
    // (0 for val==0). This stands in for a real multiply in the
    // weight-update math: adding two log2 values approximates
    // multiplying the two original magnitudes together, and the
    // multiply-free LMS step is then applied as a barrel shift
    // (see Stage 4 below) instead of a genuine multiplier.
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
    // Cumulative cycle_counter value at which the gear-shift FSM
    // advances out of phase 0 / phase 1 / into continuous tracking.
    localparam int PHASE1_START = CALIB_CYCLES_P0;
    localparam int PHASE2_START = CALIB_CYCLES_P0 + CALIB_CYCLES_P1;
    localparam int TRACK_START  = CALIB_CYCLES_P0 + CALIB_CYCLES_P1 + CALIB_CYCLES_P2;

    // --------------------------------------------------------
    // Weights
    // --------------------------------------------------------
    // w_phase_reg: adaptive phase (I/Q cross-term) correction weight.
    // w_gain_reg:  adaptive gain-imbalance correction weight, widened
    //              to 34 bits so it can reach the saturation limit
    //              below without overflowing (see file header).
    (* keep = "true", mark_debug = "true" *) logic signed [31:0] w_phase_reg;
    (* keep = "true", mark_debug = "true" *) logic signed [33:0] w_gain_reg;

    // --------------------------------------------------------
    // FSM & counter
    // --------------------------------------------------------
    logic [31:0]        cycle_counter;
    logic signed [31:0] current_mu_shift;
    logic               do_reset;

    // --------------------------------------------------------
    // DC Blocker (S0)
    // --------------------------------------------------------
    logic signed [23:0]          dc_acc_i_in;
    logic signed [23:0]          dc_acc_q_in;
    logic signed [BIT_WIDTH-1:0] i_ac;
    logic signed [BIT_WIDTH-1:0] q_ac;

    // --------------------------------------------------------
    // Stage 1 (S1): Phase multiply
    // --------------------------------------------------------
    logic signed [BIT_WIDTH-1:0] s1_i;
    logic signed [BIT_WIDTH-1:0] s1_q;
    logic signed [41:0]          s1_phase_mult;

    // --------------------------------------------------------
    // Stage 2 (S2): Phase add + Gain multiply
    // --------------------------------------------------------
    logic signed [BIT_WIDTH-1:0] s2_i;
    logic signed [11:0]          s2_q_ortho;
    logic signed [45:0]          s2_gain_mult;  // 34 (w_gain) + 12 (q_ortho) = 46 bits

    // --------------------------------------------------------
    // Stage 3 (S3): Gain add + saturation + abs
    // --------------------------------------------------------
    logic signed [BIT_WIDTH-1:0] s3_i_out;
    logic signed [BIT_WIDTH-1:0] s3_q_out;
    logic signed [10:0]          s3_abs_i;
    logic signed [10:0]          s3_abs_q;
    logic signed [11:0]          s3_err_gain;
    logic signed [31:0]          s3_mu_shift;   // captured for S4

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
    // calib_phase walks 0 -> 1 -> 2 -> 3, skipping any phase whose
    // CALIB_CYCLES_Px budget is 0; phase 3 is the permanent
    // continuous-tracking state (is_tracking stays asserted). A
    // do_reset pulse from the fault detector below restarts the
    // whole sequence from phase 0 and arms FAULT_COOLDOWN cycles
    // before the fault detector is allowed to fire again.
    always_ff @(posedge clk) begin
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
    // Selects the barrel-shift amount for the current calib_phase
    // (see CALIB_SHIFT_Px / TRACK_SHIFT above).
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
    // Leaky-integrator DC blocker: dc_acc_* accumulates the input
    // sample each cycle while bleeding off ~1/1024 of itself
    // (>>> 10), i.e. a single-pole IIR running estimate of the DC
    // offset with time constant ~2^10 samples. i_ac/q_ac are the
    // AC-coupled (DC-removed) samples that feed the rest of the
    // corrector.
    always_ff @(posedge clk) begin
        if (!rst_n || do_reset) begin
            dc_acc_i_in <= 0;
            dc_acc_q_in <= 0;
            i_ac        <= 0;
            q_ac        <= 0;
        end else begin
            dc_acc_i_in <= dc_acc_i_in + i_in - (dc_acc_i_in >>> 10);
            dc_acc_q_in <= dc_acc_q_in + q_in - (dc_acc_q_in >>> 10);
            i_ac <= i_in - (dc_acc_i_in >>> 10);
            q_ac <= q_in - (dc_acc_q_in >>> 10);
        end
    end

    // ── Stage 1: Phase Multiply ─────────────────────────────────
    //  Compute: phase_mult = w_phase_reg * i_ac
    //  Pass through i_ac and q_ac for the next stage
    always_ff @(posedge clk) begin
        if (!rst_n || do_reset) begin
            s1_i          <= 0;
            s1_q          <= 0;
            s1_phase_mult <= 0;
        end else begin
            s1_i          <= i_ac;
            s1_q          <= q_ac;
            s1_phase_mult <= w_phase_reg * i_ac;
        end
    end

    // ── Stage 2: Phase Add + Gain Multiply ──────────────────────
    //  Compute: q_ortho = q + (phase_mult >>> 30)
    //           gain_mult = w_gain_reg * q_ortho
    //  The gain multiply starts here; its result is used in S3.
    //  (w_phase_reg is a Q30 fixed-point weight, so >>> 30 rescales
    //  the phase_mult product back down to the sample's fixed point
    //  before adding it into q; q_ortho is the phase-corrected,
    //  orthogonalized quadrature sample.)
    always_ff @(posedge clk) begin
        if (!rst_n || do_reset) begin
            s2_i         <= 0;
            s2_q_ortho   <= 0;
            s2_gain_mult <= 0;
        end else begin
            logic signed [11:0] q_ortho_comb;
            q_ortho_comb  = s1_q + (s1_phase_mult >>> 30);

            s2_i         <= s1_i;
            s2_q_ortho   <= q_ortho_comb;
            s2_gain_mult <= w_gain_reg * q_ortho_comb;
        end
    end

    // ── Stage 3: Gain Add + Saturation + Abs + Error ────────────
    //  Compute: q_out_full = q_ortho + (gain_mult >>> 30)
    //           abs_i, abs_q, err_gain
    //  Outputs i_out, q_out (final corrected samples)
    //  (q_full is clamped to the signed BIT_WIDTH range so the
    //  gain correction can never push q_out outside the sample
    //  format; err_gain = |I| - |Q| is the gain-imbalance error
    //  term the LMS weight update drives toward zero.)
    always_ff @(posedge clk) begin
        if (!rst_n || do_reset) begin
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
        end else begin
            logic signed [15:0] q_full;
            logic signed [BIT_WIDTH-1:0] q_sat;
            logic signed [10:0] abs_i_t, abs_q_t;

            // Gain add + saturation
            q_full = 16'(s2_q_ortho) + 16'(s2_gain_mult >>> 30);

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
            abs_i_t = (s2_i < 0)  ? -s2_i  : s2_i;
            abs_q_t = (q_sat < 0) ? -q_sat : q_sat;

            s3_abs_i    <= abs_i_t;
            s3_abs_q    <= abs_q_t;
            s3_err_gain <= $signed({1'b0, abs_i_t}) - $signed({1'b0, abs_q_t});
            s3_mu_shift <= current_mu_shift;

            // Registered copies for fault detector (1 cycle later)
            err_gain_reg <= $signed({1'b0, abs_i_t}) - $signed({1'b0, abs_q_t});
            abs_i_reg    <= abs_i_t;
            abs_q_reg    <= abs_q_t;
        end
    end

    // ── Stage 4: Log + Barrel-Shift (Delta Computation) ─────────
    //  All the log-domain math and variable shifts happen here.
    //  This is now the only stage with barrel shifts, keeping
    //  combinational depth manageable.
    always_ff @(posedge clk) begin
        if (!rst_n || do_reset) begin
            s4_delta_phase <= 0;
            s4_delta_gain  <= 0;
        end else begin
            logic [3:0]          log_abs_i, log_abs_q;
            logic [4:0]          log_sum;
            logic                phase_sign, is_zero;
            logic signed [31:0]  raw_delta_phase, delta_phase;
            logic signed [31:0]  scaled_err_gain, delta_gain;

            // Phase error via log-log: log_abs_i/log_abs_q approximate
            // floor(log2(|I|)) and floor(log2(|Q|)); their sum
            // approximates floor(log2(|I|*|Q|)) without an actual
            // multiply. This magnitude is then right-shifted by the
            // current step size (current_mu_shift, captured as
            // s3_mu_shift) to form the phase weight's update step.
            log_abs_i = msb_pos(s3_abs_i);
            log_abs_q = msb_pos(s3_abs_q);
            log_sum   = log_abs_i + log_abs_q;
            phase_sign = s3_i_out[BIT_WIDTH-1] ^ s3_q_out[BIT_WIDTH-1];
            is_zero = (s3_abs_i == 0) || (s3_abs_q == 0);

            raw_delta_phase = (32'd1 << log_sum) >> s3_mu_shift;
            if (raw_delta_phase == 0) raw_delta_phase = 1;  // guarantee a non-zero nudge
            delta_phase = is_zero ? 32'd0 : (phase_sign ? -raw_delta_phase : raw_delta_phase);

            // Gain error delta: err_gain is pre-scaled by <<< 8 for
            // headroom, then shifted right by the step size. The
            // negate-shift-negate form (rather than a plain >>> on a
            // negative value) avoids the toward-negative-infinity
            // rounding bias of an arithmetic right shift, keeping the
            // step symmetric for positive and negative error.
            scaled_err_gain = 32'(s3_err_gain) <<< 8;

            if (s3_err_gain < 0)
                delta_gain = -((-scaled_err_gain) >>> s3_mu_shift);
            else
                delta_gain =    scaled_err_gain   >>> s3_mu_shift;

            if (delta_gain == 0 && s3_err_gain != 0)
                delta_gain = (s3_err_gain > 0) ? 1 : -1;  // guarantee a non-zero nudge

            s4_delta_phase <= delta_phase;
            s4_delta_gain  <= delta_gain;
        end
    end

    // ── Stage 5: Weight Update + Saturation ─────────────────────
    //  Simple add + clamp. Very short combinational path.
    //  Saturation limits: ±858,993,459 for the 32-bit phase weight
    //  and ±6,442,450,943 for the 34-bit gain weight (see the file
    //  header for why w_gain_reg needs the extra headroom).
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_phase_reg <= 0;
            w_gain_reg  <= 0;
        end else if (do_reset) begin
            // do_reset intentionally leaves the weights untouched here
            // (only rst_n clears them below) so that an auto-recalibration
            // triggered by the fault detector restarts the gear-shift FSM
            // from a previously-converged weight instead of from zero.
        end else begin
            logic signed [31:0] new_w_phase;
            logic signed [33:0] new_w_gain;

            new_w_phase = w_phase_reg - s4_delta_phase;
            new_w_gain  = w_gain_reg  + 34'(s4_delta_gain);

            if      (new_w_phase >  32'sd858993459) w_phase_reg <=  32'sd858993459;
            else if (new_w_phase < -32'sd858993459) w_phase_reg <= -32'sd858993459;
            else                                    w_phase_reg <=  new_w_phase;

            if      (new_w_gain >  34'sd6442450943) w_gain_reg <=  34'sd6442450943;
            else if (new_w_gain < -34'sd6442450943) w_gain_reg <= -34'sd6442450943;
            else                                    w_gain_reg <=  new_w_gain;
        end
    end

    // ============================================================
    //  Fault Detector - Integrate-and-Dump
    // ============================================================
    //  Sums err_gain_reg over one DDS period (DDS_PERIOD cycles),
    //  but only while the input carries enough energy to trust the
    //  measurement. If, for FAULT_CONFIRM consecutive periods, the
    //  summed error magnitude exceeds FAULT_THR while tracking is
    //  active, do_reset pulses and the gear-shift FSM above restarts
    //  calibration (subject to a cooldown so it can't re-trigger
    //  immediately, and a blanking window after entering tracking so
    //  the corrector has time to settle before being judged).

    // Only count/accumulate error while the signal has enough
    // amplitude to make the error measurement meaningful.
    assign signal_strong = ({1'b0, abs_i_reg} + {1'b0, abs_q_reg}) > SIGNAL_MIN[11:0];

    // Magnitude of the completed period's accumulated error.
    assign fault_sum_abs = fault_period_sum[31] ? $unsigned(-fault_period_sum)
                                                : $unsigned( fault_period_sum);

    assign in_cooldown  = (cooldown_cnt != 0);
    assign in_blanking  = (blanking_cnt != 0);

    // End of the current DDS_PERIOD-cycle integration window.
    assign period_done  = (fault_period_cnt == (DDS_PERIOD[15:0] - 1));
    // Require at least half the period to have been "strong" samples
    // before trusting this period's sum.
    assign period_valid = (fault_strong_cnt >= (DDS_PERIOD[15:0] >> 1));
    // Summed error magnitude exceeded the fault threshold.
    assign period_over  = (fault_sum_abs > FAULT_THR[31:0]);

    // Force recalibration once FAULT_CONFIRM consecutive periods have
    // both a valid (strong-enough) measurement and an over-threshold
    // sum, but only while steady-state tracking and outside any
    // cooldown/blanking window.
    assign do_reset     = (fault_confirm_cnt == FAULT_CONFIRM[7:0])
                          && (calib_phase == 2'd3)
                          && !in_cooldown
                          && !in_blanking;

    always_ff @(posedge clk) begin
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
