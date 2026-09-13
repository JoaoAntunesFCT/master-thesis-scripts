%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    iq_corrector_model
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Bit-accurate behavioral model of the pipelined Log-Log LMS
%                 IQ-imbalance correction algorithm. This model is the
%                 algorithmic and cycle-accurate foundation from which the
%                 iq_corrector_ll_lms.sv RTL implementation was later
%                 developed, and is used to generate the reference
%                 waveforms the RTL is verified against.
%
% Dependencies:   tb_iq_corrector.m
%
% Revision:
% Additional Comments:
%   NOTE: the pipeline-stage/register names below (s1_i, s2_gain_mult,
%   w_phase_reg, ...) were carried over into the iq_corrector_ll_lms.sv RTL
%   implementation, so the two can be read side-by-side. Keep that mapping
%   in mind when editing the RTL.
%
%////////////////////////////////////////////////////////////////////////////////
classdef iq_corrector_model < handle
% iq_corrector_model  Bit-accurate MATLAB reference model for the Log-Log LMS
%                   IQ-imbalance corrector
%
%   Cycle-exact, fixed-point algorithmic reference for the pipelined Log-Log
%   LMS IQ-imbalance corrector. Every register is modelled with its declared
%   bit width, two's-complement wrapping, arithmetic shifts and saturation;
%   the iq_corrector_ll_lms.sv RTL implementation was developed directly
%   from this model and matches its outputs sample-for-sample (for the same
%   inputs and parameters).
%
%   Usage:
%       dut = iq_corrector_model();                 % default params (BIT_WIDTH=10)
%       dut = iq_corrector_model(struct('CALIB_CYCLES_P0',8000));  % override
%       [io, qo, trk, flt, ph, d] = dut.step(i_in, q_in, rst_n);
%
%   step() advances the pipeline by one clock. Call it once per sample.
%   Return values:
%       io, qo : corrected I/Q outputs (signed 10-bit)
%       trk    : is_tracking flag
%       flt    : fault_detected pulse
%       ph     : calib_phase (0..3)
%       d      : diagnostics struct (weights, err_gain, abs_i/q, etc.)
%
%   NOTE ON BIT-ACCURACY: the corrector datapath is exact. The RTL top
%   tester's DDS/VIO are Xilinx IP whose internal config is not in the
%   source, so the *stimulus* is generated in tb_iq_corrector.m instead;
%   given identical i_in/q_in the corrector math here is identical to RTL.

    properties
        % -------- parameters --------
        BIT_WIDTH
        CALIB_SHIFT_P0, CALIB_SHIFT_P1, CALIB_SHIFT_P2, TRACK_SHIFT
        CALIB_CYCLES_P0, CALIB_CYCLES_P1, CALIB_CYCLES_P2
        DDS_PERIOD, FAULT_THR, FAULT_CONFIRM, FAULT_COOLDOWN, ...
            FAULT_BLANKING, SIGNAL_MIN
        PHASE1_START, PHASE2_START, TRACK_START

        % -------- weights --------
        w_phase_reg = 0     % signed [31:0]
        w_gain_reg  = 0     % signed [33:0]

        % -------- FSM / counters --------
        cycle_counter  = 0
        calib_phase    = 0
        is_tracking    = 0
        fault_detected = 0
        cooldown_cnt   = 0
        blanking_cnt   = 0

        % -------- S0 DC blocker --------
        dc_acc_i_in = 0     % signed [23:0]
        dc_acc_q_in = 0
        i_ac = 0            % signed [9:0]
        q_ac = 0

        % -------- S1 phase multiply --------
        s1_i = 0
        s1_q = 0
        s1_phase_mult = 0   % signed [41:0]

        % -------- S2 phase add + gain multiply --------
        s2_i = 0
        s2_q_ortho = 0      % signed [11:0]
        s2_gain_mult = 0    % signed [45:0]

        % -------- S3 gain add + sat + abs + error --------
        s3_i_out = 0
        s3_q_out = 0
        s3_abs_i = 0        % signed [10:0]
        s3_abs_q = 0
        s3_err_gain = 0     % signed [11:0]
        s3_mu_shift = 0
        i_out = 0
        q_out = 0
        err_gain_reg = 0    % signed [11:0]
        abs_i_reg = 0       % signed [10:0]
        abs_q_reg = 0

        % -------- S4 log + barrel shift --------
        s4_delta_phase = 0  % signed [31:0]
        s4_delta_gain  = 0

        % -------- fault detector --------
        fault_acc         = 0   % signed [31:0]
        fault_period_sum  = 0
        fault_period_cnt  = 0
        fault_strong_cnt  = 0
        fault_confirm_cnt = 0
    end

    methods
        function obj = iq_corrector_model(p)
            if nargin < 1, p = struct(); end
            % Defaults match the parameter set later carried into the
            % fpga_top_tester.sv RTL instantiation.
            % CALIB_CYCLES_P0 default here is the true HW value 2000000;
            % the testbench overrides it with a smaller number so plots
            % show convergence quickly (per-sample math is unchanged).
            def = struct( ...
                'BIT_WIDTH',10, ...
                'CALIB_SHIFT_P0',3,'CALIB_SHIFT_P1',6,'CALIB_SHIFT_P2',9, ...
                'TRACK_SHIFT',12, ...
                'CALIB_CYCLES_P0',2000000,'CALIB_CYCLES_P1',0,'CALIB_CYCLES_P2',0, ...
                'DDS_PERIOD',1000,'FAULT_THR',500,'FAULT_CONFIRM',3, ...
                'FAULT_COOLDOWN',2000000,'FAULT_BLANKING',2000,'SIGNAL_MIN',64);
            f = fieldnames(def);
            for k = 1:numel(f)
                if isfield(p,f{k}), obj.(f{k}) = p.(f{k});
                else,               obj.(f{k}) = def.(f{k}); end
            end
            obj.PHASE1_START = obj.CALIB_CYCLES_P0;
            obj.PHASE2_START = obj.CALIB_CYCLES_P0 + obj.CALIB_CYCLES_P1;
            obj.TRACK_START  = obj.CALIB_CYCLES_P0 + obj.CALIB_CYCLES_P1 + obj.CALIB_CYCLES_P2;
        end

        function [io, qo, trk, flt, ph, d] = step(obj, i_in, q_in, rst_n)
            cur = obj;   % shorthand for current (registered) state

            % ================= combinational =================
            switch cur.calib_phase
                case 0, cur_mu = cur.CALIB_SHIFT_P0;
                case 1, cur_mu = cur.CALIB_SHIFT_P1;
                case 2, cur_mu = cur.CALIB_SHIFT_P2;
                otherwise, cur_mu = cur.TRACK_SHIFT;
            end

            in_cooldown = (cur.cooldown_cnt ~= 0);
            in_blanking = (cur.blanking_cnt ~= 0);
            signal_strong = (cur.abs_i_reg + cur.abs_q_reg) > cur.SIGNAL_MIN;
            fault_sum_abs = abs(cur.fault_period_sum);
            period_done   = (cur.fault_period_cnt == (cur.DDS_PERIOD - 1));
            period_valid  = (cur.fault_strong_cnt >= floor(cur.DDS_PERIOD/2));
            period_over   = (fault_sum_abs > cur.FAULT_THR);
            do_reset = (cur.fault_confirm_cnt == cur.FAULT_CONFIRM) && ...
                       (cur.calib_phase == 3) && ~in_cooldown && ~in_blanking;

            rstd = (~rst_n) || do_reset;   % datapath reset (S0..S4, outputs)

            % ================= S0: DC blocker =================
            % Single-pole high-pass filter (leaky integrator): tracks the
            % running DC average with a >>10 (1/1024) time constant and
            % subtracts it, so a static I/Q DC offset doesn't get mistaken
            % for imbalance by the LMS loop below.
            if rstd
                next_dc_acc_i_in = 0; next_dc_acc_q_in = 0; next_i_ac = 0; next_q_ac = 0;
            else
                next_dc_acc_i_in = iq_corrector_model.ws(cur.dc_acc_i_in + i_in - iq_corrector_model.ashr(cur.dc_acc_i_in,10), 24);
                next_dc_acc_q_in = iq_corrector_model.ws(cur.dc_acc_q_in + q_in - iq_corrector_model.ashr(cur.dc_acc_q_in,10), 24);
                next_i_ac = iq_corrector_model.ws(i_in - iq_corrector_model.ashr(cur.dc_acc_i_in,10), 10);
                next_q_ac = iq_corrector_model.ws(q_in - iq_corrector_model.ashr(cur.dc_acc_q_in,10), 10);
            end

            % ================= S1: phase multiply =================
            % Multiplies the DC-free I sample by the adaptive phase weight
            % to build the cross-term that will be added into Q in S2 -
            % this is what rotates Q back to true quadrature.
            if rstd
                next_s1_i = 0; next_s1_q = 0; next_s1_phase_mult = 0;
            else
                next_s1_i = cur.i_ac; next_s1_q = cur.q_ac;
                next_s1_phase_mult = iq_corrector_model.ws(cur.w_phase_reg * cur.i_ac, 42);
            end

            % ================= S2: phase add + gain multiply =================
            if rstd
                next_s2_i = 0; next_s2_q_ortho = 0; next_s2_gain_mult = 0;
            else
                % q_ortho = Q + (phase correction term >> 30): removes the
                % phase-imbalance component from Q.
                q_ortho = iq_corrector_model.ws(cur.s1_q + iq_corrector_model.ashr(cur.s1_phase_mult,30), 12);
                next_s2_i  = cur.s1_i;
                next_s2_q_ortho = q_ortho;
                next_s2_gain_mult = iq_corrector_model.ws(cur.w_gain_reg * q_ortho, 46);
            end

            % ================= S3: gain add + sat + abs + error =================
            % Applies the adaptive gain correction to q_ortho, saturates to
            % the 10-bit output range, then forms the error signal the LMS
            % update uses: err_gain = |I| - |Q|. If the two are amplitude-
            % matched (properly corrected), err_gain should sit near zero.
            if rstd
                next_s3_i_out=0; next_s3_q_out=0; next_s3_abs_i=0; next_s3_abs_q=0; next_s3_err_gain=0; next_s3_mu_shift=0;
                next_i_out=0; next_q_out=0; next_err_gain_reg=0; next_abs_i_reg=0; next_abs_q_reg=0;
            else
                gain_shifted = iq_corrector_model.ashr(cur.s2_gain_mult, 30);
                q_full = iq_corrector_model.ws( iq_corrector_model.ws(cur.s2_q_ortho,16) + iq_corrector_model.ws(gain_shifted,16), 16);
                if      q_full >  511, q_sat = 511;
                elseif  q_full < -511, q_sat = -511;
                else                   q_sat = iq_corrector_model.ws(q_full,10);
                end
                abs_i = abs(cur.s2_i);
                abs_q = abs(q_sat);
                err_gain = iq_corrector_model.ws(abs_i - abs_q, 12);

                next_i_out   = cur.s2_i;  next_q_out   = q_sat;
                next_s3_i_out= cur.s2_i;  next_s3_q_out= q_sat;
                next_s3_abs_i= abs_i;      next_s3_abs_q= abs_q;
                next_s3_err_gain= err_gain;      next_s3_mu_shift= cur_mu;
                next_err_gain_reg  = err_gain;      next_abs_i_reg  = abs_i;   next_abs_q_reg = abs_q;
            end

            % ================= S4: log + barrel shift =================
            % "Log-Log LMS": instead of a real multiply, the phase-weight
            % update uses floor(log2(|I|)) + floor(log2(|Q|)) as a cheap
            % stand-in for log2(|I|*|Q|), then barrel-shifts that magnitude
            % by the current step size (cur_mu) - this is the RTL's
            % multiplier-free adaptation step, reproduced bit-for-bit here.
            if rstd
                next_delta_phase = 0; next_delta_gain = 0;
            else
                log2_abs_i = iq_corrector_model.msb_pos(cur.s3_abs_i);   % floor(log2(|I|))
                log2_abs_q = iq_corrector_model.msb_pos(cur.s3_abs_q);   % floor(log2(|Q|))
                log2_sum = log2_abs_i + log2_abs_q;
                product_sign  = xor(cur.s3_i_out < 0, cur.s3_q_out < 0);
                is_zero = (cur.s3_abs_i == 0) || (cur.s3_abs_q == 0);

                % (1 << log2_sum) >> mu, with a minimum step of 1 so the
                % weight always moves (keeps the loop from stalling).
                raw_delta_phase = floor( (2^log2_sum) / (2^cur.s3_mu_shift) );
                if raw_delta_phase == 0, raw_delta_phase = 1; end
                if is_zero,       delta_phase = 0;
                elseif product_sign,     delta_phase = -raw_delta_phase;
                else              delta_phase =  raw_delta_phase;
                end

                % Gain step is proportional to err_gain directly (linear,
                % not log): scale by 256 for headroom, then apply the same
                % mu shift. Round-to-nearest-nonzero keeps it from stalling
                % once err_gain is small but still nonzero.
                scaled_eg = cur.s3_err_gain * 256;                 % <<< 8
                if cur.s3_err_gain < 0
                    delta_gain = -floor( (-scaled_eg) / (2^cur.s3_mu_shift) );
                else
                    delta_gain =  floor(  scaled_eg  / (2^cur.s3_mu_shift) );
                end
                if delta_gain == 0 && cur.s3_err_gain ~= 0
                    if cur.s3_err_gain > 0, delta_gain = 1; else, delta_gain = -1; end
                end

                next_delta_phase = iq_corrector_model.ws(delta_phase, 32);
                next_delta_gain = iq_corrector_model.ws(delta_gain, 32);
            end

            % ================= S5: weight update + saturation =================
            % Integrates delta_phase/delta_gain into the persistent weights,
            % then clamps to +/-858993459 and +/-6442450943 - these are the
            % RTL's fixed saturation limits for the 32-bit and 34-bit signed
            % weight registers, so the adaptive loop can't wrap around.
            if ~rst_n
                next_w_phase_reg = 0; next_w_gain_reg = 0;
            elseif do_reset
                next_w_phase_reg = cur.w_phase_reg; next_w_gain_reg = cur.w_gain_reg;   % weights held
            else
                raw_w_phase = iq_corrector_model.ws(cur.w_phase_reg - cur.s4_delta_phase, 32);
                raw_w_gain = iq_corrector_model.ws(cur.w_gain_reg  + cur.s4_delta_gain , 34);
                if      raw_w_phase >  858993459, next_w_phase_reg =  858993459;
                elseif  raw_w_phase < -858993459, next_w_phase_reg = -858993459;
                else                      next_w_phase_reg =  raw_w_phase;
                end
                if      raw_w_gain >  6442450943, next_w_gain_reg =  6442450943;
                elseif  raw_w_gain < -6442450943, next_w_gain_reg = -6442450943;
                else                       next_w_gain_reg =  raw_w_gain;
                end
            end

            % ================= FSM =================
            % Calibration runs in up to 3 phases (0,1,2) with progressively
            % slower step sizes (CALIB_SHIFT_P0/P1/P2), then hands off to
            % continuous tracking (phase 3, TRACK_SHIFT). do_reset restarts
            % calibration from phase 0 whenever the fault detector confirms
            % a persistent fault.
            if ~rst_n
                next_cycle_counter=0; next_calib_phase=0; next_is_tracking=0; next_fault_detected=0; next_cooldown_cnt=0; next_blanking_cnt=0;
            else
                next_cycle_counter=cur.cycle_counter; next_calib_phase=cur.calib_phase; next_is_tracking=cur.is_tracking;
                next_blanking_cnt=cur.blanking_cnt;   next_fault_detected=0;
                if cur.cooldown_cnt > 0, next_cooldown_cnt = cur.cooldown_cnt - 1; else, next_cooldown_cnt = cur.cooldown_cnt; end

                if do_reset
                    next_calib_phase=0; next_cycle_counter=0; next_is_tracking=0; next_fault_detected=1; next_cooldown_cnt=cur.FAULT_COOLDOWN; next_blanking_cnt=0;
                elseif cur.calib_phase == 3
                    next_is_tracking = 1;
                    if cur.blanking_cnt > 0, next_blanking_cnt = cur.blanking_cnt - 1; end
                else
                    next_cycle_counter = cur.cycle_counter + 1;
                    if cur.calib_phase==0 && cur.cycle_counter==(cur.PHASE1_START-1)
                        if     cur.CALIB_CYCLES_P1>0, next_calib_phase=1;
                        elseif cur.CALIB_CYCLES_P2>0, next_calib_phase=2;
                        else,  next_calib_phase=3; next_is_tracking=1; next_blanking_cnt=cur.FAULT_BLANKING; end
                    elseif cur.calib_phase==1 && cur.cycle_counter==(cur.PHASE2_START-1)
                        if cur.CALIB_CYCLES_P2>0, next_calib_phase=2;
                        else, next_calib_phase=3; next_is_tracking=1; next_blanking_cnt=cur.FAULT_BLANKING; end
                    elseif cur.calib_phase==2 && cur.cycle_counter==(cur.TRACK_START-1)
                        next_calib_phase=3; next_is_tracking=1; next_blanking_cnt=cur.FAULT_BLANKING;
                    end
                end
            end

            % ================= fault detector =================
            % Only runs once tracking has started. Accumulates err_gain
            % over one DDS period; if the signal was strong enough to
            % trust (period_valid) and the accumulated error exceeds
            % FAULT_THR for FAULT_CONFIRM consecutive periods, do_reset
            % (above) restarts calibration - this catches a corrector that
            % has drifted or lost lock.
            if ~rst_n
                next_fault_acc=0; next_fault_period_sum=0; next_fault_period_cnt=0; next_fault_strong_cnt=0; next_fault_confirm_cnt=0;
            elseif (cur.calib_phase==3) && ~in_cooldown && ~in_blanking
                next_fault_acc=cur.fault_acc; next_fault_period_sum=cur.fault_period_sum; next_fault_period_cnt=cur.fault_period_cnt;
                next_fault_strong_cnt=cur.fault_strong_cnt; next_fault_confirm_cnt=cur.fault_confirm_cnt;
                err_gain_sample = cur.err_gain_reg;
                if signal_strong
                    next_fault_acc = cur.fault_acc + err_gain_sample;
                    next_fault_strong_cnt  = cur.fault_strong_cnt + 1;
                end
                if period_done
                    if signal_strong, next_fault_period_sum = cur.fault_acc + err_gain_sample;
                    else,             next_fault_period_sum = cur.fault_acc; end
                    next_fault_acc = 0; next_fault_period_cnt = 0; next_fault_strong_cnt = 0;
                    if period_valid && period_over
                        if cur.fault_confirm_cnt < cur.FAULT_CONFIRM
                            next_fault_confirm_cnt = cur.fault_confirm_cnt + 1;
                        end
                    else
                        next_fault_confirm_cnt = 0;
                    end
                else
                    next_fault_period_cnt = cur.fault_period_cnt + 1;
                end
            else
                next_fault_acc=0; next_fault_period_sum=0; next_fault_period_cnt=0; next_fault_strong_cnt=0; next_fault_confirm_cnt=0;
            end

            % ================= commit =================
            obj.dc_acc_i_in=next_dc_acc_i_in; obj.dc_acc_q_in=next_dc_acc_q_in; obj.i_ac=next_i_ac; obj.q_ac=next_q_ac;
            obj.s1_i=next_s1_i; obj.s1_q=next_s1_q; obj.s1_phase_mult=next_s1_phase_mult;
            obj.s2_i=next_s2_i; obj.s2_q_ortho=next_s2_q_ortho; obj.s2_gain_mult=next_s2_gain_mult;
            obj.s3_i_out=next_s3_i_out; obj.s3_q_out=next_s3_q_out; obj.s3_abs_i=next_s3_abs_i; obj.s3_abs_q=next_s3_abs_q;
            obj.s3_err_gain=next_s3_err_gain; obj.s3_mu_shift=next_s3_mu_shift;
            obj.i_out=next_i_out; obj.q_out=next_q_out; obj.err_gain_reg=next_err_gain_reg; obj.abs_i_reg=next_abs_i_reg; obj.abs_q_reg=next_abs_q_reg;
            obj.s4_delta_phase=next_delta_phase; obj.s4_delta_gain=next_delta_gain;
            obj.w_phase_reg=next_w_phase_reg; obj.w_gain_reg=next_w_gain_reg;
            obj.cycle_counter=next_cycle_counter; obj.calib_phase=next_calib_phase; obj.is_tracking=next_is_tracking;
            obj.fault_detected=next_fault_detected; obj.cooldown_cnt=next_cooldown_cnt; obj.blanking_cnt=next_blanking_cnt;
            obj.fault_acc=next_fault_acc; obj.fault_period_sum=next_fault_period_sum; obj.fault_period_cnt=next_fault_period_cnt;
            obj.fault_strong_cnt=next_fault_strong_cnt; obj.fault_confirm_cnt=next_fault_confirm_cnt;

            % ================= outputs =================
            io  = obj.i_out;  qo  = obj.q_out;
            trk = obj.is_tracking; flt = obj.fault_detected; ph = obj.calib_phase;
            d = struct('w_phase',obj.w_phase_reg,'w_gain',obj.w_gain_reg, ...
                       'err_gain',obj.err_gain_reg,'abs_i',obj.abs_i_reg, ...
                       'abs_q',obj.abs_q_reg,'do_reset',do_reset, ...
                       'fault_confirm',obj.fault_confirm_cnt);
        end
    end

    methods (Static)
        function y = ws(x, n)          % wrap to signed n-bit two's complement
            m = 2^n;  y = mod(x, m);
            if y >= m/2, y = y - m; end
        end
        function y = ashr(x, n)        % arithmetic shift right = floor(x/2^n)
            y = floor(x / 2^n);
        end
        function p = msb_pos(v)        % priority encoder over bits 10..0
            p = 0;
            for k = 10:-1:0
                if bitand(v, 2^k) ~= 0, p = k; return; end
            end
        end
    end
end