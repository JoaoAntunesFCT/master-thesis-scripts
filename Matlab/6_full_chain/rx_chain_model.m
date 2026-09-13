%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    rx_chain_model
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Floating-point behavioral model of the FULL TREX1 receive
%                 chain end to end: IQ corrector -> NCO/mixer -> CIC -> FIR
%                 -> AGC -> CFO estimate/derotate -> Symbol Timing Recovery
%                 -> GMSK demod -> Packet Engine. Combines the individual
%                 per-block models (iq_corrector_model.m, ddc_receiver_model.m,
%                 sync_model.m, gmsk_demod_model.m, pe_engine_model.m) --
%                 each the algorithmic foundation for its corresponding RTL
%                 block -- into one cross-check tool for comparing signal
%                 shapes against a full-chain Vivado ILA capture taken from
%                 the resulting hardware. See the detailed header below for
%                 exactly what is and is not bit-exact.
%
% Dependencies:   rx_chain_testbench.m
%
% Revision:
% Additional Comments:
%
%////////////////////////////////////////////////////////////////////////////////
function probe = rx_chain_model(raw_i, raw_q, cfg)
%RX_CHAIN_MODEL  Floating-point behavioural model of the TREX1 RX chain.
%
%   probe = RX_CHAIN_MODEL(raw_i, raw_q, cfg)
%
% Companion file: rx_chain_testbench.m (builds a stimulus, calls this
% function, and renders the same 5-figure layout used for the Vivado ILA
% captures, for direct visual comparison).
%
% SCOPE / WHAT THIS MODEL IS FOR
%   This is a cross-check tool: it reproduces the SAME algorithmic chain
%   defined by the individual per-block models above, using the same
%   scaling/shift constants those models established (and which the RTL
%   implementation carries forward), so that signal SHAPES and relative
%   magnitudes can be compared against a
%   real Vivado ILA capture rendered by generate_graphs6.py. It is NOT a
%   bit-exact fixed-point simulation:
%     - All arithmetic is done in double precision. Right-shifts (>>>) are
%       reproduced as floor(x / 2^k) to match Verilog's arithmetic-shift
%       (truncating, not rounding) semantics, but there is no fixed-point
%       overflow/wraparound modelling beyond the specific bit-slices noted
%       below.
%     - Multi-cycle pipeline latencies (e.g. the 5-stage IQ corrector
%       pipeline, the 5-stage STR pipeline) are collapsed to their
%       single-step algorithmic equivalent. The RTL's own header comments
%       state this explicitly does not change loop dynamics (only the
%       control-word update latency, which is negligible relative to the
%       loop's symbol-rate update period) - see trex1_str_top.v and
%       iq_corrector_ll_lms.sv headers.
%     - Two RTL bit-slice quirks ARE reproduced exactly because they
%       materially change the signal's appearance, not just its timing:
%         (1) the DDC->sync width adapter takes the LOW 12 bits of the
%             24-bit baseband word (sync_i_in = i_out_baseband[11:0]),
%             not a scaled-down version of it;
%         (2) the CIC's fixed >>>13 output truncation (cic_decimator_
%             4th_order.v), which is independent of the runtime
%             decimation rate.
%
% INPUTS
%   raw_i, raw_q : real row/column vectors, same length N. Signed ADC-scale
%                  samples (e.g. -511..511 for a 10-bit signed front end),
%                  one sample per system-clock tick.
%   cfg          : struct of parameters. Call cfg = rx_chain_model() with
%                  NO input arguments to get the default parameter set
%                  (matching the parameters later carried into the RTL
%                  instantiation in trex1_rx_frontend_top.v /
%                  ddc_frontend_top.v / iq_corrector_ll_lms.sv), then
%                  override individual
%                  fields before calling the model.
%
% OUTPUT
%   probe : struct of column vectors, ALL of length N (one sample per
%           system-clock tick, exactly like a Vivado ILA capture): every
%           decimated/gated signal simply HOLDS its last register value
%           between updates, matching how ILA waveforms look. Field names
%           deliberately mirror the ILA probe names used in
%           generate_graphs6.py so the same plotting code structure can be
%           reused against either source:
%             i_imb, q_imb                         (raw ADC input)
%             dbg_iq_i_out, dbg_iq_q_out            (IQ corrector output)
%             w_phase_reg, w_gain_reg, calib_phase  (corrector LMS state)
%             fault_acc, fault_period_sum, fault_detected
%             dbg_mixer_i, dbg_mixer_q              (NCO mixer output)
%             dbg_cic_i, dbg_cic_q                  (CIC output)
%             baseband_valid_out
%             i_out_baseband, q_out_baseband        (post-FIR)
%             sync_i_out, sync_q_out, sync_valid_out (post-STR)
%             dbg_raw_angle, cir, ciq, phi, dphi    (CFO derotator state)
%             dbg_freq_dev                          (GMSK discriminant)
%             rx_bit_out, rx_bit_valid
%             dbg_bit_count, dbg_pe_enable
%             payload_preview, dbg_crc_syndrome, dbg_error_idx
%             packet_error_out
%
% USAGE
%   cfg = rx_chain_model();            % defaults
%   N   = 8192;
%   [raw_i, raw_q] = deal(zeros(N,1)); % <- build your own stimulus
%   probe = rx_chain_model(raw_i, raw_q, cfg);

    if nargin == 0
        probe = default_cfg();
        return;
    end

    raw_i = double(raw_i(:));
    raw_q = double(raw_q(:));
    N = numel(raw_i);
    assert(numel(raw_q) == N, 'raw_i and raw_q must be the same length');

    if nargin < 3 || isempty(cfg)
        cfg = default_cfg();
    end

    %% ---------------------------------------------------------------
    %  Pre-allocate every probe as a length-N column (register-hold model)
    %% ---------------------------------------------------------------
    z  = zeros(N,1);
    lg = false(N,1);
    probe = struct( ...
        'i_imb', raw_i, 'q_imb', raw_q, ...
        'dbg_iq_i_out', z, 'dbg_iq_q_out', z, ...
        'w_phase_reg', z, 'w_gain_reg', z, 'calib_phase', z, ...
        'fault_acc', z, 'fault_period_sum', z, 'fault_detected', lg, ...
        'dbg_mixer_i', z, 'dbg_mixer_q', z, ...
        'dbg_cic_i', z, 'dbg_cic_q', z, ...
        'baseband_valid_out', lg, ...
        'i_out_baseband', z, 'q_out_baseband', z, ...
        'sync_i_out', z, 'sync_q_out', z, 'sync_valid_out', lg, ...
        'dbg_raw_angle', z, 'cir', z, 'ciq', z, 'phi', z, 'dphi', z, ...
        'dbg_freq_dev', z, ...
        'rx_bit_out', lg, 'rx_bit_valid', lg, ...
        'dbg_bit_count', z, 'dbg_pe_enable', lg, ...
        'payload_preview', z, 'dbg_crc_syndrome', z, 'dbg_error_idx', z, ...
        'packet_error_out', lg);

    %% ---------------------------------------------------------------
    %  Stage state (all persist across the sample loop)
    %% ---------------------------------------------------------------
    % -- IQ corrector (iq_corrector_ll_lms.sv) --
    dc_acc_i = 0; dc_acc_q = 0;
    w_phase  = 0; w_gain   = 0;
    calib_phase = 0; cycle_counter = 0;
    fault_acc = 0; fault_period_sum = 0; fault_period_cnt = 0;
    fault_strong_cnt = 0; fault_confirm_cnt = 0;
    cooldown_cnt = 0; blanking_cnt = 0;

    % -- NCO + complex mixer (ddc_nco_cmix.v) --
    phase_acc = 0;

    % -- CIC (cic_decimator_4th_order.v), one instance per channel --
    int1_i=0; int2_i=0; int3_i=0; int4_i=0;
    int1_q=0; int2_q=0; int3_q=0; int4_q=0;
    comb1_i=0; comb2_i=0; comb3_i=0; comb4_i=0;
    comb1_q=0; comb2_q=0; comb3_q=0; comb4_q=0;
    dec_cnt = 0;
    cic_i_out = 0; cic_q_out = 0;

    % -- FIR (fir_csd_filter.v): 73-tap symmetric, Q1.15 --
    taps = fir_taps();
    fir_buf_i = zeros(73,1); fir_buf_q = zeros(73,1);
    baseband_i = 0; baseband_q = 0;

    % -- AGC (trex1_ff_agc.v) --
    win_len = cfg.agc_window;
    pwr_win  = zeros(win_len,1); pwr_acc = 0;
    dly_i = zeros(win_len,1); dly_q = zeros(win_len,1);
    agc_fill = 0;
    agc_i = 0; agc_q = 0; agc_valid_prev = false;

    % -- CFO estimator + derotator (trex1_cfo_top.v / trex1_cfo_derotate.v) --
    lag = cfg.sps;                      % "fine" estimator, lag = SPS
    cfo_hist_i = zeros(lag,1); cfo_hist_q = zeros(lag,1); cfo_hist_ptr = 1;
    cfo_acc_i = 0; cfo_acc_q = 0; cfo_acc_n = 0;
    accum_len = cfg.preamble_syms * cfg.sps;
    phi = 0; dphi = 0; raw_angle = 0; cir_val = 0; ciq_val = 0;

    % -- STR (trex1_str_top.v Rev4, collapsed to its algorithmic equivalent) --
    W0   = cfg.str_w0; WMIN = cfg.str_wmin; WMAX = cfg.str_wmax;
    KP_SHIFT = cfg.str_kp_shift;
    eta = 0; Wc = W0; str_ip = 0; str_qp = 0; ontime = true;
    yi_onp = 0; yq_onp = 0; yi_mid = 0; yq_mid = 0;
    str_i = 0; str_q = 0;

    % -- GMSK demod (trex1_gmsk_demod.v) --
    demod_i_prev = 0; demod_q_prev = 0; demod_have_prev = false;
    freq_dev = 0; rx_bit = false;   % held registers, updated only on str_valid

    % -- Packet engine (trex1_pe_datapath.v + trex1_packet_engine_top.v) --
    synd_lut = syndrome_lut_table();
    pn9 = pn9_reset();                  % 9'h1FF: all ones, as a 1x9 logical (bit0..bit8)
    crc = false(1,16);                  % 16'h0000, as a 1x16 logical (bit0..bit15)
    pkt_buf = false(1,272);
    bit_count = 0; pe_enable = false; pe_enable_d = false;
    payload_preview = 0; packet_error = false;

    %% ---------------------------------------------------------------
    %  Main sample loop (one iteration = one system-clock tick)
    %% ---------------------------------------------------------------
    for n = 1:N
        i_in = raw_i(n);
        q_in = raw_q(n);

        % ===== 1. IQ CORRECTOR (iq_corrector_ll_lms.sv) =====================
        % -- 3-phase gear-shift step size --
        if calib_phase == 0
            mu_shift = cfg.calib_shift_p0;
        elseif calib_phase == 1
            mu_shift = cfg.calib_shift_p1;
        elseif calib_phase == 2
            mu_shift = cfg.calib_shift_p2;
        else
            mu_shift = cfg.track_shift;
        end
        if calib_phase < 3
            cycle_counter = cycle_counter + 1;
            if calib_phase == 0 && cycle_counter >= cfg.calib_cycles_p0
                if cfg.calib_cycles_p1 > 0, calib_phase = 1;
                elseif cfg.calib_cycles_p2 > 0, calib_phase = 2;
                else, calib_phase = 3; end
                cycle_counter = 0;
            elseif calib_phase == 1 && cycle_counter >= cfg.calib_cycles_p1
                if cfg.calib_cycles_p2 > 0, calib_phase = 2; else, calib_phase = 3; end
                cycle_counter = 0;
            elseif calib_phase == 2 && cycle_counter >= cfg.calib_cycles_p2
                calib_phase = 3;
            end
        end

        % -- Stage 0: DC blocker, with the silence-squelch fix --
        input_silent = (abs(i_in) + abs(q_in)) < cfg.signal_min;
        if input_silent
            i_ac = 0; q_ac_raw = 0;                 % squelched: force AC path to 0
        else
            dc_acc_i = dc_acc_i + i_in - ashr(dc_acc_i, 10);
            dc_acc_q = dc_acc_q + q_in - ashr(dc_acc_q, 10);
            i_ac = i_in - ashr(dc_acc_i, 10);
            q_ac_raw = q_in - ashr(dc_acc_q, 10);
        end

        % -- Stages 1-3: phase multiply, gain multiply, saturate (collapsed) --
        q_ortho = q_ac_raw + (w_phase * i_ac) / (2^30);
        q_full  = q_ortho + (w_gain * q_ortho) / (2^30);
        BW = cfg.bit_width;
        qmax = 2^(BW-1) - 1;
        q_sat = min(max(q_full, -qmax-1), qmax);
        i_out_corr = i_ac;                          % I channel is never corrected
        q_out_corr = q_sat;

        % -- Stage 4-5: log-log LMS weight update --
        abs_i = abs(i_out_corr); abs_q = abs(q_out_corr);
        err_gain = abs_i - abs_q;
        log2_abs_i = msb_pos(abs_i); log2_abs_q = msb_pos(abs(q_ac_raw));
        log2_sum = log2_abs_i + log2_abs_q;
        product_sign = xor(i_out_corr < 0, err_gain < 0);
        is_zero = (abs_i == 0) || (abs(q_ac_raw) == 0);
        raw_delta_phase = max(1, ashr(2^log2_sum, mu_shift));
        if is_zero
            delta_phase = 0;
        elseif product_sign
            delta_phase = -raw_delta_phase;
        else
            delta_phase = raw_delta_phase;
        end
        scaled_eg = err_gain * 256;
        delta_gain = ashr(scaled_eg, mu_shift);
        if delta_gain == 0 && err_gain ~= 0
            delta_gain = sign(err_gain);
        end
        w_phase = clamp(w_phase - delta_phase, -858993459, 858993459);
        w_gain  = clamp(w_gain  + delta_gain, -6442450943, 6442450943);

        % -- Fault detector (integrate-and-dump; disabled thresholds by
        %    default, mirrored structurally but does not fire in the
        %    default config since FAULT_THR is effectively infinite) --
        signal_strong = (abs_i + abs_q) > cfg.signal_min;
        in_cooldown = cooldown_cnt > 0; in_blanking = blanking_cnt > 0;
        if cooldown_cnt > 0, cooldown_cnt = cooldown_cnt - 1; end
        if calib_phase == 3 && ~in_cooldown && ~in_blanking
            if signal_strong
                fault_acc = fault_acc + err_gain;
                fault_strong_cnt = fault_strong_cnt + 1;
            end
            fault_period_cnt = fault_period_cnt + 1;
            if fault_period_cnt >= cfg.dds_period
                fault_period_sum = fault_acc;
                fault_acc = 0; fault_period_cnt = 0; fault_strong_cnt = 0;
            end
        else
            fault_acc = 0; fault_period_sum = 0; fault_period_cnt = 0; fault_strong_cnt = 0;
        end
        fault_detected = false;   % never fires with FAULT_THR at its default (disabled) value

        probe.dbg_iq_i_out(n) = i_out_corr;
        probe.dbg_iq_q_out(n) = q_out_corr;
        probe.w_phase_reg(n)  = w_phase;
        probe.w_gain_reg(n)   = w_gain;
        probe.calib_phase(n)  = calib_phase;
        probe.fault_acc(n)    = fault_acc;
        probe.fault_period_sum(n) = fault_period_sum;
        probe.fault_detected(n)   = fault_detected;

        % ===== 2. NCO + COMPLEX MIXER (ddc_nco_cmix.v) ======================
        phase_acc = mod(phase_acc + cfg.fcw, 2^24);
        theta = 2*pi*phase_acc/2^24;
        lo_amp = 2047;
        cos_lo = lo_amp*cos(theta);
        sin_lo = lo_amp*sin(theta);
        mixer_i = i_out_corr*cos_lo - q_out_corr*sin_lo;
        mixer_q = q_out_corr*cos_lo + i_out_corr*sin_lo;
        probe.dbg_mixer_i(n) = mixer_i;
        probe.dbg_mixer_q(n) = mixer_q;

        % ===== 3. CIC DECIMATOR, 4th order (cic_decimator_4th_order.v) =====
        int1_i = int1_i + mixer_i; int2_i = int2_i + int1_i;
        int3_i = int3_i + int2_i; int4_i = int4_i + int3_i;
        int1_q = int1_q + mixer_q; int2_q = int2_q + int1_q;
        int3_q = int3_q + int2_q; int4_q = int4_q + int3_q;

        dec_cnt = dec_cnt + 1;
        comb_strobe = (dec_cnt >= cfg.decim_rate);
        baseband_valid = false;
        if comb_strobe
            dec_cnt = 0;
            diff1_i = int4_i - comb1_i; comb1_i = int4_i;
            diff2_i = diff1_i - comb2_i; comb2_i = diff1_i;
            diff3_i = diff2_i - comb3_i; comb3_i = diff2_i;
            diff4_i = diff3_i - comb4_i; comb4_i = diff3_i;
            diff1_q = int4_q - comb1_q; comb1_q = int4_q;
            diff2_q = diff1_q - comb2_q; comb2_q = diff1_q;
            diff3_q = diff2_q - comb3_q; comb3_q = diff2_q;
            diff4_q = diff3_q - comb4_q; comb4_q = diff3_q;
            cic_i_out = ashr(diff4_i, 13);           % fixed >>>13, matches RTL exactly
            cic_q_out = ashr(diff4_q, 13);

            % ===== 4. FIR, 73-tap symmetric (fir_csd_filter.v) ===========
            fir_buf_i = [cic_i_out; fir_buf_i(1:end-1)];
            fir_buf_q = [cic_q_out; fir_buf_q(1:end-1)];
            baseband_i = sum(fir_buf_i .* taps) / 32768;   % Q1.15 -> real
            baseband_q = sum(fir_buf_q .* taps) / 32768;
            baseband_valid = true;
        end
        probe.dbg_cic_i(n) = cic_i_out;
        probe.dbg_cic_q(n) = cic_q_out;
        probe.baseband_valid_out(n) = baseband_valid;
        probe.i_out_baseband(n) = baseband_i;
        probe.q_out_baseband(n) = baseband_q;

        % ===== 5. WIDTH ADAPTER: 24-bit baseband -> 12-bit sync input =======
        % Exact bit-slice per trex1_rx_frontend_top.v: sync_i_in =
        % i_out_baseband[11:0] - the LOW 12 bits, not a scaled-down version.
        % This is reproduced exactly (not approximated) because it is what
        % gives the "sync/derotate" panel its characteristic noisy look.
        sync_i_in = 0; sync_q_in = 0;
        if baseband_valid
            sync_i_in = low_bits_signed(baseband_i, 12);
            sync_q_in = low_bits_signed(baseband_q, 12);
        end

        % ===== 6. AGC, feed-forward (trex1_ff_agc.v) ========================
        agc_valid = false;
        if baseband_valid
            inst_power = sync_i_in^2 + sync_q_in^2;
            pwr_acc = pwr_acc + inst_power - pwr_win(end);
            pwr_win = [inst_power; pwr_win(1:end-1)];

            if pwr_acc > cfg.agc_thr_p18db,      shift_val = 3; shift_dir = 1;
            elseif pwr_acc > cfg.agc_thr_p12db,   shift_val = 2; shift_dir = 1;
            elseif pwr_acc > cfg.agc_thr_p06db,   shift_val = 1; shift_dir = 1;
            elseif pwr_acc < cfg.agc_thr_m18db,   shift_val = 3; shift_dir = 0;
            elseif pwr_acc < cfg.agc_thr_m12db,   shift_val = 2; shift_dir = 0;
            elseif pwr_acc < cfg.agc_thr_m06db,   shift_val = 1; shift_dir = 0;
            else,                                 shift_val = 0; shift_dir = 0;
            end

            dly_i = [sync_i_in; dly_i(1:end-1)];
            dly_q = [sync_q_in; dly_q(1:end-1)];
            if agc_fill < win_len, agc_fill = agc_fill + 1; end
            if agc_fill >= win_len
                delayed_i = dly_i(end); delayed_q = dly_q(end);
                if shift_dir == 0
                    agc_i = delayed_i * (2^shift_val);
                else
                    agc_i = ashr(delayed_i, shift_val);
                end
                if shift_dir == 0
                    agc_q = delayed_q * (2^shift_val);
                else
                    agc_q = ashr(delayed_q, shift_val);
                end
                agc_valid = true;
            end
        end

        % ===== 7. CFO ESTIMATOR + DEROTATOR =================================
        % trex1_cfo_top.v (lag-SPS "fine" autocorrelation, integrate-and-dump
        % over PREAMBLE_SYMS*SPS samples) feeding trex1_cfo_derotate.v
        % (vectoring CORDIC -> phase accumulator -> rotating CORDIC).
        % The two CORDICs are algorithmically equivalent to atan2()/complex
        % rotation in floating point; that substitution is made here.
        derot_i = 0; derot_q = 0; derot_valid = false;
        if agc_valid
            % lag-SPS autocorrelation accumulator (blue estimator)
            old_i = cfo_hist_i(cfo_hist_ptr); old_q = cfo_hist_q(cfo_hist_ptr);
            cfo_hist_i(cfo_hist_ptr) = agc_i; cfo_hist_q(cfo_hist_ptr) = agc_q;
            cfo_hist_ptr = mod(cfo_hist_ptr, lag) + 1;
            % r = x[n] * conj(x[n-lag])
            r_i = agc_i*old_i + agc_q*old_q;
            r_q = agc_q*old_i - agc_i*old_q;
            cfo_acc_i = cfo_acc_i + r_i; cfo_acc_q = cfo_acc_q + r_q;
            cfo_acc_n = cfo_acc_n + 1;
            if cfo_acc_n >= accum_len
                cir_val = cfo_acc_i; ciq_val = cfo_acc_q;
                raw_angle = atan2(ciq_val, cir_val) / (2*pi) * 65536;  % full circle = 2^16
                dphi = ashr(raw_angle, cfg.lag_log2);                  % /lag -> per-sample CFO
                cfo_acc_i = 0; cfo_acc_q = 0; cfo_acc_n = 0;
            end

            phi = mod(phi + dphi + 32768, 65536) - 32768;   % wraps mod 2*pi, signed 16-bit
            ang = -phi/65536*2*pi;
            cos_phi = cos(ang); sin_phi = sin(ang);
            derot_i = agc_i*cos_phi - agc_q*sin_phi;
            derot_q = agc_i*sin_phi + agc_q*cos_phi;
            derot_valid = true;
        end
        probe.dbg_raw_angle(n) = raw_angle;
        probe.cir(n) = cir_val;
        probe.ciq(n) = ciq_val;
        probe.phi(n) = phi;
        probe.dphi(n) = dphi;

        % ===== 8. STR: pipelined interpolating Gardner loop (trex1_str_top.v)
        % Collapsed to its algorithmic equivalent - the RTL's own header
        % explicitly states the 5-stage pipeline vs. single-cycle update
        % "has no effect on loop dynamics" since the loop updates once per
        % symbol, far slower than the pipeline depth.
        str_valid = false;
        if derot_valid
            etaz = eta;
            strobe = etaz < Wc;
            eta_next = eta - Wc + (strobe * 65536);

            di = derot_i - str_ip; dq = derot_q - str_qp;
            mu = min(255, floor(eta/32));

            if strobe
                yi = str_ip + (di*mu)/256;
                yq = str_qp + (dq*mu)/256;
                if ontime
                    str_i = yi; str_q = yq; str_valid = true;
                    ted0 = (yi - yi_onp) * yi_mid;
                    ted1 = (yq - yq_onp) * yq_mid;
                    ted = ted0 + ted1;
                    Wc_new = W0 + ashr(ted, KP_SHIFT);
                    Wc = clamp(Wc_new, WMIN, WMAX);
                    yi_onp = yi; yq_onp = yq;
                else
                    yi_mid = yi; yq_mid = yq;
                end
                ontime = ~ontime;
            end
            str_ip = derot_i; str_qp = derot_q;
            eta = eta_next;
        end
        % str_i/str_q are plain registers in RTL: they hold their last
        % written value between symbol strobes (this is exactly what the
        % real ILA capture shows as a staircase in the "Sync/derotate"
        % panel), so they are recorded every cycle, not gated by str_valid.
        probe.sync_i_out(n) = str_i;
        probe.sync_q_out(n) = str_q;
        probe.sync_valid_out(n) = str_valid;

        % ===== 9. GMSK DEMOD, cross-product discriminator (trex1_gmsk_demod.v)
        rx_bit_valid = false;
        if str_valid
            if demod_have_prev
                freq_dev = str_q*demod_i_prev - str_i*demod_q_prev;
                rx_bit = freq_dev > 0;
                rx_bit_valid = true;
            end
            demod_i_prev = str_i; demod_q_prev = str_q;
            demod_have_prev = true;
        end
        % freq_dev/rx_bit are likewise plain held registers between updates.
        probe.dbg_freq_dev(n) = freq_dev;
        probe.rx_bit_out(n) = rx_bit;
        probe.rx_bit_valid(n) = rx_bit_valid;

        % ===== 10. PACKET ENGINE (trex1_pe_datapath.v + trex1_packet_engine_top.v)
        % Simplification vs. the real bench: the real chain is opened by an
        % external one-shot `packet_start` pulse (from the test wrapper /
        % VIO), which this tone-calibration testbench has no equivalent of.
        % Here the 272-bit window is instead auto-retriggered immediately
        % after each close, giving the same free-running, repeating
        % bit_count sawtooth seen in the real ILA capture (Figure 3),
        % continuously running the PN9/CRC/syndrome-LUT logic over
        % whatever bit stream the demodulator is currently producing - on
        % a pure calibration tone (no real packet), that stream is
        % effectively noise, exactly as in the reference capture.
        do_correction = false;
        if pe_enable && rx_bit_valid
            dewhitened_bit = xor(rx_bit, pn9(9));
            fb = xor(pn9(9), pn9(5));
            pn9 = [pn9(2:9), fb];

            fbc = xor(crc(16), dewhitened_bit);
            new_crc = crc;
            new_crc(16) = crc(15); new_crc(15) = crc(14);
            new_crc(14) = crc(13); new_crc(13) = crc(12);
            new_crc(12) = xor(crc(11), fbc);
            new_crc(11) = crc(10); new_crc(10) = crc(9);
            new_crc(9)  = crc(8);  new_crc(8)  = crc(7);
            new_crc(7)  = crc(6);  new_crc(6)  = crc(5);
            new_crc(5)  = xor(crc(4), fbc);
            new_crc(4)  = crc(3);  new_crc(3)  = crc(2);
            new_crc(2)  = crc(1);  new_crc(1)  = fbc;
            crc = new_crc;

            pkt_buf = [pkt_buf(2:272), dewhitened_bit];

            if bit_count == 271
                bit_count = 0;
                pe_enable = false;
                do_correction = true;
            else
                bit_count = bit_count + 1;
            end
        elseif ~pe_enable
            pe_enable = true; bit_count = 0;
            pn9 = pn9_reset(); crc = false(1,16);
        end

        if do_correction
            crc_val = bits2dec(crc);
            payload = pkt_buf(1:256);
            if crc_val == 0
                packet_error = false;
                payload_preview = bits2dec(payload(1:32));
            else
                eidx = syndrome_lookup(synd_lut, crc_val);
                if eidx <= 255
                    payload(eidx+1) = ~payload(eidx+1);
                    packet_error = false;
                    payload_preview = bits2dec(payload(1:32));
                else
                    packet_error = true;   % payload discarded, preview holds its old value
                end
            end
        end

        probe.dbg_bit_count(n)     = bit_count;
        probe.dbg_pe_enable(n)     = pe_enable;
        probe.dbg_crc_syndrome(n)  = bits2dec(crc);
        probe.dbg_error_idx(n)     = syndrome_lookup(synd_lut, bits2dec(crc));
        probe.payload_preview(n)   = payload_preview;
        probe.packet_error_out(n)  = packet_error;
    end
end

%% =====================================================================
%  Local helper functions
%% =====================================================================
function y = ashr(x, k)
%ASHR  Verilog-style arithmetic right shift ( >>> ): floor(x / 2^k).
    y = floor(x ./ (2.^k));
end

function y = clamp(x, lo, hi)
    y = min(max(x, lo), hi);
end

function p = msb_pos(val)
%MSB_POS  Algorithmic reference for the RTL priority encoder later built
%   from it: position of the highest set bit of an 11-bit unsigned value
%   (0 if none set).
    val = max(0, round(val));
    if val <= 0
        p = 0;
    else
        p = min(10, floor(log2(val)));
    end
end

function y = low_bits_signed(x, nbits)
%LOW_BITS_SIGNED  Take the low NBITS bits of X and reinterpret as signed
%   two's complement - mirrors a raw Verilog bit-slice such as
%   i_out_baseband[11:0], NOT a scaled-down / rounded version of X.
    m = 2^nbits;
    u = mod(round(x), m);
    y = u - m*(u >= m/2);
end

function pn9 = pn9_reset()
    pn9 = true(1,9);   % 9'h1FF: all ones
end

function d = bits2dec(bitsvec)
%BITS2DEC  Row vector of logicals, MSB first, -> unsigned decimal value.
    d = 0;
    for k = 1:numel(bitsvec)
        d = d*2 + double(bitsvec(k));
    end
end

function idx = syndrome_lookup(lut, syndrome)
%SYNDROME_LOOKUP  Ports syndrome_lut.v exactly (272-entry single-bit-error
%   table; anything else, including 0x0000, maps to 511 = 9'h1FF).
    hit = find(lut(:,1) == syndrome, 1);
    if isempty(hit)
        idx = 511;
    else
        idx = lut(hit,2);
    end
end

function lut = syndrome_lut_table()
%SYNDROME_LUT_TABLE  Verbatim port of syndrome_lut.v's case statement
%   (272 single-bit-error syndromes -> bit position 0..271).
    lut = [ ...
        0x36F4 0;
        0x1B7A 1;
        0x0DBD 2;
        0x82D6 3;
        0x416B 4;
        0xA4BD 5;
        0xD656 6;
        0x6B2B 7;
        0xB19D 8;
        0xDCC6 9;
        0x6E63 10;
        0xB339 11;
        0xDD94 12;
        0x6ECA 13;
        0x3765 14;
        0x9FBA 15;
        0x4FDD 16;
        0xA3E6 17;
        0x51F3 18;
        0xACF1 19;
        0xD270 20;
        0x6938 21;
        0x349C 22;
        0x1A4E 23;
        0x0D27 24;
        0x829B 25;
        0xC545 26;
        0xE6AA 27;
        0x7355 28;
        0xBDA2 29;
        0x5ED1 30;
        0xAB60 31;
        0x55B0 32;
        0x2AD8 33;
        0x156C 34;
        0x0AB6 35;
        0x055B 36;
        0x86A5 37;
        0xC75A 38;
        0x63AD 39;
        0xB5DE 40;
        0x5AEF 41;
        0xA97F 42;
        0xD0B7 43;
        0xEC53 44;
        0xF221 45;
        0xFD18 46;
        0x7E8C 47;
        0x3F46 48;
        0x1FA3 49;
        0x8BD9 50;
        0xC1E4 51;
        0x60F2 52;
        0x3079 53;
        0x9C34 54;
        0x4E1A 55;
        0x270D 56;
        0x978E 57;
        0x4BC7 58;
        0xA1EB 59;
        0xD4FD 60;
        0xEE76 61;
        0x773B 62;
        0xBF95 63;
        0xDBC2 64;
        0x6DE1 65;
        0xB2F8 66;
        0x597C 67;
        0x2CBE 68;
        0x165F 69;
        0x8F27 70;
        0xC39B 71;
        0xE5C5 72;
        0xF6EA 73;
        0x7B75 74;
        0xB9B2 75;
        0x5CD9 76;
        0xAA64 77;
        0x5532 78;
        0x2A99 79;
        0x9144 80;
        0x48A2 81;
        0x2451 82;
        0x9620 83;
        0x4B10 84;
        0x2588 85;
        0x12C4 86;
        0x0962 87;
        0x04B1 88;
        0x8650 89;
        0x4328 90;
        0x2194 91;
        0x10CA 92;
        0x0865 93;
        0x803A 94;
        0x401D 95;
        0xA406 96;
        0x5203 97;
        0xAD09 98;
        0xD28C 99;
        0x6946 100;
        0x34A3 101;
        0x9E59 102;
        0xCB24 103;
        0x6592 104;
        0x32C9 105;
        0x9D6C 106;
        0x4EB6 107;
        0x275B 108;
        0x97A5 109;
        0xCFDA 110;
        0x67ED 111;
        0xB7FE 112;
        0x5BFF 113;
        0xA9F7 114;
        0xD0F3 115;
        0xEC71 116;
        0xF230 117;
        0x7918 118;
        0x3C8C 119;
        0x1E46 120;
        0x0F23 121;
        0x8399 122;
        0xC5C4 123;
        0x62E2 124;
        0x3171 125;
        0x9CB0 126;
        0x4E58 127;
        0x272C 128;
        0x1396 129;
        0x09CB 130;
        0x80ED 131;
        0xC47E 132;
        0x623F 133;
        0xB517 134;
        0xDE83 135;
        0xEB49 136;
        0xF1AC 137;
        0x78D6 138;
        0x3C6B 139;
        0x9A3D 140;
        0xC916 141;
        0x648B 142;
        0xB64D 143;
        0xDF2E 144;
        0x6F97 145;
        0xB3C3 146;
        0xDDE9 147;
        0xEAFC 148;
        0x757E 149;
        0x3ABF 150;
        0x9957 151;
        0xC8A3 152;
        0xE059 153;
        0xF424 154;
        0x7A12 155;
        0x3D09 156;
        0x9A8C 157;
        0x4D46 158;
        0x26A3 159;
        0x9759 160;
        0xCFA4 161;
        0x67D2 162;
        0x33E9 163;
        0x9DFC 164;
        0x4EFE 165;
        0x277F 166;
        0x97B7 167;
        0xCFD3 168;
        0xE3E1 169;
        0xF5F8 170;
        0x7AFC 171;
        0x3D7E 172;
        0x1EBF 173;
        0x8B57 174;
        0xC1A3 175;
        0xE4D9 176;
        0xF664 177;
        0x7B32 178;
        0x3D99 179;
        0x9AC4 180;
        0x4D62 181;
        0x26B1 182;
        0x9750 183;
        0x4BA8 184;
        0x25D4 185;
        0x12EA 186;
        0x0975 187;
        0x80B2 188;
        0x4059 189;
        0xA424 190;
        0x5212 191;
        0x2909 192;
        0x908C 193;
        0x4846 194;
        0x2423 195;
        0x9619 196;
        0xCF04 197;
        0x6782 198;
        0x33C1 199;
        0x9DE8 200;
        0x4EF4 201;
        0x277A 202;
        0x13BD 203;
        0x8DD6 204;
        0x46EB 205;
        0xA77D 206;
        0xD7B6 207;
        0x6BDB 208;
        0xB1E5 209;
        0xDCFA 210;
        0x6E7D 211;
        0xB336 212;
        0x599B 213;
        0xA8C5 214;
        0xD06A 215;
        0x6835 216;
        0xB012 217;
        0x5809 218;
        0xA80C 219;
        0x5406 220;
        0x2A03 221;
        0x9109 222;
        0xCC8C 223;
        0x6646 224;
        0x3323 225;
        0x9D99 226;
        0xCAC4 227;
        0x6562 228;
        0x32B1 229;
        0x9D50 230;
        0x4EA8 231;
        0x2754 232;
        0x13AA 233;
        0x09D5 234;
        0x80E2 235;
        0x4071 236;
        0xA430 237;
        0x5218 238;
        0x290C 239;
        0x1486 240;
        0x0A43 241;
        0x8129 242;
        0xC49C 243;
        0x624E 244;
        0x3127 245;
        0x9C9B 246;
        0xCA45 247;
        0xE12A 248;
        0x7095 249;
        0xBC42 250;
        0x5E21 251;
        0xAB18 252;
        0x558C 253;
        0x2AC6 254;
        0x1563 255;
        0x8EB9 256;
        0xC354 257;
        0x61AA 258;
        0x30D5 259;
        0x9C62 260;
        0x4E31 261;
        0xA310 262;
        0x5188 263;
        0x28C4 264;
        0x1462 265;
        0x0A31 266;
        0x8110 267;
        0x4088 268;
        0x2044 269;
        0x1022 270;
        0x0811 271;
        ];
    lut(:,1) = hex2dec_vec(lut(:,1));
end

function d = hex2dec_vec(hexcol)
%HEX2DEC_VEC  The literal table above encodes hex values as MATLAB
%   hexadecimal numeric literals (0xNNNN), which both MATLAB and Octave
%   already parse directly as doubles - this pass-through exists only so
%   the table is easy to re-generate/verify against syndrome_lut.v later.
    d = hexcol;
end

function taps = fir_taps()
%FIR_TAPS  73-tap symmetric linear-phase FIR, verbatim from
%   fir_csd_filter.v (Q1.15 integers; caller divides by 32768).
    half = [0, 1, 3, 6, 11, 17, 23, 30, 35, 36, 33, 23, 5, -23, -60, -105, ...
            -155, -207, -253, -287, -302, -288, -240, -150, -15, 167, 394, ...
            660, 957, 1273, 1594, 1903, 2184, 2422, 2603, 2715, 2754];
    taps = [half, fliplr(half(1:end-1))]';   % 37 + 36 = 73 taps, symmetric about C36
end

function cfg = default_cfg()
%DEFAULT_CFG  Parameters later carried into the actual RTL instantiation in
%   trex1_rx_frontend_top.v / ddc_frontend_top.v / iq_corrector_ll_lms.sv.
%   Override individual fields after calling this.
    cfg = struct();

    % -- IQ corrector (iq_corrector_ll_lms.sv instance parameters) --
    cfg.bit_width       = 10;     % signed range +-511
    cfg.calib_shift_p0  = 3;
    cfg.calib_shift_p1  = 6;
    cfg.calib_shift_p2  = 9;
    cfg.track_shift     = 12;
    cfg.calib_cycles_p0 = 200000;
    cfg.calib_cycles_p1 = 0;
    cfg.calib_cycles_p2 = 0;
    cfg.dds_period      = 10;
    cfg.signal_min      = 64;

    % -- DDC (ddc_frontend_top.v / ddc_nco_cmix.v / cic_decimator_4th_order.v)
    cfg.decim_rate = 12;           % CIC decimation rate R
    cfg.fcw        = 0;            % 24-bit NCO frequency control word
                                    % (set from the testbench to choose the
                                    % down-conversion frequency)

    % -- AGC (trex1_ff_agc.v instance: AGC_WINDOW=100) --
    cfg.agc_window    = 100;
    cfg.agc_thr_p18db = 100000000;
    cfg.agc_thr_p12db = 25000000;
    cfg.agc_thr_p06db = 6250000;
    cfg.agc_thr_m06db = 390600;
    cfg.agc_thr_m12db = 97600;
    cfg.agc_thr_m18db = 24400;

    % -- CFO estimator/derotator (trex1_cfo_top.v / trex1_cfo_derotate.v) --
    cfg.sps           = 16;   % samples per symbol -> also the "fine" lag
    cfg.preamble_syms = 32;   % ACCUM_LEN = preamble_syms * sps
    cfg.lag_log2      = 4;    % lag = 2^lag_log2 = 16 = sps

    % -- STR (trex1_str_top.v Rev4) --
    cfg.str_kp_shift = 11;
    cfg.str_w0    = 8192;    % 2/16 in Q0.16 (2 strobes/symbol)
    cfg.str_wmin  = 6144;    % 0.75*W0
    cfg.str_wmax  = 10240;   % 1.25*W0
end