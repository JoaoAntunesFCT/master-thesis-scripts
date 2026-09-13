%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    sync_model
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Floating-point behavioral model of the receiver
%                 synchronization algorithm -- AGC -> dual CFO
%                 autocorrelation estimate -> CFO derotate -> Symbol Timing
%                 Recovery -- that formed the algorithmic foundation for
%                 the trex1_sync_hw_top.v RTL implementation. See the
%                 detailed header below for full scope and the
%                 preamble-gated, one-shot CFO accumulator behavior this
%                 model defines and the RTL reproduces exactly.
%
% Dependencies:   tb_trex1_sync_hdl.m
%
%////////////////////////////////////////////////////////////////////////////////
function probe = sync_model(hw_i_in, hw_q_in, preamble_flag, cfg)
%SYNC_MODEL  Floating-point behavioural algorithmic reference for the
%   synchronization datapath later implemented as trex1_sync_hw_top
%   (AGC -> CFO estimate/derotate -> Symbol Timing Recovery).
%
%   probe = SYNC_MODEL(hw_i_in, hw_q_in, preamble_flag, cfg)
%
% Companion file: tb_trex1_sync_hdl.m (builds a stimulus, calls this function,
% and renders the SAME panel layout as generate_graphs.py's sync-block ILA
% figure - hw_i_out/hw_q_out, hw_valid_out, cfo_coarse_i - for a direct
% visual comparison).
%
% SCOPE
%   This is the algorithmic foundation for trex1_sync_hw_top.v
%   specifically: AGC (trex1_ff_agc.v),
%   dual CFO autocorrelation estimators - lag-1 "coarse" and lag-SPS
%   "fine" (trex1_blue_autocorr.v x2, via trex1_cfo_top.v) - CFO
%   derotation (trex1_cfo_derotate.v), and Symbol Timing Recovery
%   (trex1_str_top.v Rev4). It does NOT model the DDC/IQ-corrector
%   upstream of it - inputs here are already the decimated baseband
%   stream this block actually receives (hw_i_in/hw_q_in), one valid
%   sample per array element (hw_valid_in is implicitly 1 throughout;
%   this block has no decimation-rate dependency of its own, so unlike
%   rx_chain_model.m there is no separate 100 MHz/10 MHz configuration
%   here - unlike the DDC, this block's behaviour is entirely defined in
%   the decimated symbol-rate domain and is identical for both targets).
%
%   As with rx_chain_model.m: double-precision arithmetic, RTL right-
%   shifts reproduced as floor(x/2^k), and multi-cycle pipeline latencies
%   collapsed to their single-step algorithmic equivalent (matching the
%   STR's own header comment that this does not change loop dynamics).
%   The two CORDICs in trex1_cfo_derotate.v (vectoring + rotating) are
%   replaced with their floating-point equivalent (atan2 / complex
%   rotation) rather than iterated in fixed point.
%
%   IMPORTANT BEHAVIOURAL DETAIL reproduced exactly (this differs from
%   how rx_chain_model.m's simplified continuous-tone bench approximated
%   CFO estimation): trex1_blue_autocorr.v is preamble-gated and
%   ONE-SHOT, not a free-running periodic estimator:
%     - its delay line shifts on every valid sample regardless of
%       preamble_active;
%     - its multiply+accumulate only runs while preamble_active is high;
%     - the accumulator resets to exactly 0 the instant preamble_active
%       drops;
%     - once its internal sample_count reaches ACCUM_LENGTH
%       (PREAMBLE_SYMS*SPS = 512 by default), it STOPS updating and
%       holds its accumulated value with valid_out asserted continuously
%       until preamble_active drops - it does NOT reset and restart.
%   So a correct testbench must actually drive preamble_flag high for at
%   least one accumulation window per "packet" to see a CFO estimate
%   appear at all - see tb_sync_model.m.
%
% INPUTS
%   hw_i_in, hw_q_in : real column vectors, same length N. Baseband I/Q
%                      samples (signed, DATA_WIDTH-bit scale, default 12).
%   preamble_flag    : logical/0-1 column vector, same length N. High
%                      during the preamble region of each packet.
%   cfg              : struct of parameters. Call cfg = sync_model() with
%                      NO input arguments for the default set (matching
%                      the parameters later carried into
%                      trex1_sync_hw_top.v's RTL instantiation), then override
%                      individual fields before calling the model.
%
% OUTPUT
%   probe : struct of column vectors, length N (register-hold semantics,
%           like a Vivado ILA capture - see rx_chain_model.m's header for
%           why). Field names chosen to match the ILA probe set directly
%           where they exist (hw_i_out, hw_q_out, hw_valid_out,
%           cfo_coarse_i/q/valid), plus extra internal signals not in
%           that particular capture but useful for deeper comparison
%           (cfo_fine_*, agc_*, and the derotator's own dbg_raw_angle/
%           cir/ciq/phi/dphi):
%             agc_i_out, agc_q_out, agc_valid_out
%             cfo_coarse_i, cfo_coarse_q, cfo_coarse_valid   (lag-1)
%             cfo_fine_i, cfo_fine_q, cfo_fine_valid         (lag-SPS)
%             dbg_raw_angle, cir, ciq, phi, dphi             (derotator)
%             hw_i_out, hw_q_out, hw_valid_out               (STR output)
%
% USAGE
%   cfg = sync_model();                 % defaults
%   probe = sync_model(hw_i_in, hw_q_in, preamble_flag, cfg);

    if nargin == 0
        probe = default_cfg();
        return;
    end

    hw_i_in = double(hw_i_in(:));
    hw_q_in = double(hw_q_in(:));
    preamble_flag = logical(preamble_flag(:));
    N = numel(hw_i_in);
    assert(numel(hw_q_in) == N && numel(preamble_flag) == N, ...
           'hw_i_in, hw_q_in, and preamble_flag must all be the same length');

    if nargin < 4 || isempty(cfg)
        cfg = default_cfg();
    end

    %% ---------------------------------------------------------------
    %  Pre-allocate probes (register-hold model, one row per input sample)
    %% ---------------------------------------------------------------
    zero_col  = zeros(N,1);
    false_col = false(N,1);
    probe = struct( ...
        'agc_i_out', zero_col, 'agc_q_out', zero_col, 'agc_valid_out', false_col, ...
        'cfo_coarse_i', zero_col, 'cfo_coarse_q', zero_col, 'cfo_coarse_valid', false_col, ...
        'cfo_fine_i', zero_col, 'cfo_fine_q', zero_col, 'cfo_fine_valid', false_col, ...
        'dbg_raw_angle', zero_col, 'cir', zero_col, 'ciq', zero_col, 'phi', zero_col, 'dphi', zero_col, ...
        'hw_i_out', zero_col, 'hw_q_out', zero_col, 'hw_valid_out', false_col);

    %% ---------------------------------------------------------------
    %  Stage state
    %% ---------------------------------------------------------------
    % -- AGC (trex1_ff_agc.v) --
    win_len = cfg.agc_window;
    pwr_win = zeros(win_len,1); pwr_acc = 0;
    dly_i = zeros(win_len,1); dly_q = zeros(win_len,1);
    agc_fill = 0;
    agc_i = 0; agc_q = 0;

    % -- Preamble-flag delay line, matches AGC's own latency --
    flag_pipe = false(win_len,1);

    % -- CFO autocorrelation estimators: lag-1 "coarse", lag-SPS "fine" --
    lag_c = 1; lag_f = cfg.sps;
    accum_len = cfg.preamble_syms * cfg.sps;
    buf_c_i = zeros(lag_c,1); buf_c_q = zeros(lag_c,1);
    buf_f_i = zeros(lag_f,1); buf_f_q = zeros(lag_f,1);
    r_c_i = 0; r_c_q = 0; cnt_c = 0; valid_c = false;
    r_f_i = 0; r_f_q = 0; cnt_f = 0; valid_f = false;

    % -- CFO derotator (trex1_cfo_derotate.v) --
    phi = 0; dphi = 0; raw_angle = 0; cir_val = 0; ciq_val = 0;

    % -- STR (trex1_str_top.v Rev4, collapsed to its algorithmic equivalent) --
    W0 = cfg.str_w0; WMIN = cfg.str_wmin; WMAX = cfg.str_wmax;
    KP_SHIFT = cfg.str_kp_shift;
    eta = 0; Wc = W0; str_ip = 0; str_qp = 0; ontime = true;
    yi_onp = 0; yq_onp = 0; yi_mid = 0; yq_mid = 0;
    str_i = 0; str_q = 0;

    %% ---------------------------------------------------------------
    %  Main sample loop (one iteration = one valid baseband sample)
    %% ---------------------------------------------------------------
    for n = 1:N
        i_in = hw_i_in(n); q_in = hw_q_in(n); pf = preamble_flag(n);

        % ===== 1. AGC (trex1_ff_agc.v) =====================================
        inst_power = i_in^2 + q_in^2;
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

        dly_i = [i_in; dly_i(1:end-1)];
        dly_q = [q_in; dly_q(1:end-1)];
        flag_pipe = [pf; flag_pipe(1:end-1)];
        if agc_fill < win_len, agc_fill = agc_fill + 1; end

        agc_valid = (agc_fill >= win_len);
        if agc_valid
            delayed_i = dly_i(end); delayed_q = dly_q(end);
            if shift_dir == 0, agc_i = delayed_i * (2^shift_val);
            else,              agc_i = ashr(delayed_i, shift_val); end
            if shift_dir == 0, agc_q = delayed_q * (2^shift_val);
            else,              agc_q = ashr(delayed_q, shift_val); end
        end
        sync_preamble_active = flag_pipe(end);   % delayed to match AGC latency

        probe.agc_i_out(n) = agc_i;
        probe.agc_q_out(n) = agc_q;
        probe.agc_valid_out(n) = agc_valid;

        % ===== 2. CFO autocorrelation estimators (trex1_blue_autocorr.v) ===
        % Delay line shifts on every valid sample regardless of preamble;
        % multiply+accumulate is preamble-gated; accumulator resets the
        % instant preamble drops; holds (does not restart) once ACCUM_LEN
        % samples have been integrated. Exact port of the RTL, see header.
        cfo_c_valid = false; cfo_f_valid = false;
        if agc_valid
            % -- coarse, lag-1 --
            old_ci = buf_c_i(end); old_cq = buf_c_q(end);
            buf_c_i = [agc_i; buf_c_i(1:end-1)]; buf_c_q = [agc_q; buf_c_q(1:end-1)];
            if sync_preamble_active
                cross_real = agc_i*old_ci + agc_q*old_cq;
                cross_imag = agc_q*old_ci - agc_i*old_cq;
                if cnt_c < accum_len
                    r_c_i = r_c_i + cross_real; r_c_q = r_c_q + cross_imag;
                    cnt_c = cnt_c + 1; valid_c = false;
                else
                    valid_c = true;
                end
            else
                r_c_i = 0; r_c_q = 0; cnt_c = 0; valid_c = false;
            end
            cfo_c_valid = valid_c;

            % -- fine, lag-SPS --
            old_fi = buf_f_i(end); old_fq = buf_f_q(end);
            buf_f_i = [agc_i; buf_f_i(1:end-1)]; buf_f_q = [agc_q; buf_f_q(1:end-1)];
            if sync_preamble_active
                cross_real = agc_i*old_fi + agc_q*old_fq;
                cross_imag = agc_q*old_fi - agc_i*old_fq;
                if cnt_f < accum_len
                    r_f_i = r_f_i + cross_real; r_f_q = r_f_q + cross_imag;
                    cnt_f = cnt_f + 1; valid_f = false;
                else
                    valid_f = true;
                end
            else
                r_f_i = 0; r_f_q = 0; cnt_f = 0; valid_f = false;
            end
            cfo_f_valid = valid_f;
        end
        probe.cfo_coarse_i(n) = r_c_i; probe.cfo_coarse_q(n) = r_c_q;
        probe.cfo_coarse_valid(n) = cfo_c_valid;
        probe.cfo_fine_i(n) = r_f_i;   probe.cfo_fine_q(n) = r_f_q;
        probe.cfo_fine_valid(n) = cfo_f_valid;

        % ===== 3. CFO DEROTATOR (trex1_cfo_derotate.v) ======================
        % Port wiring per trex1_sync_hw_top.v: the derotator's "coarse_i/q"
        % INPUT PORT is actually wired to the FINE (lag-SPS) estimator's
        % output, matching LAG_LOG2=4 (2^4=16=SPS) - NOT the lag-1 coarse
        % estimator, which is exposed purely as a separate debug output.
        derot_i = 0; derot_q = 0; derot_valid = false;
        if agc_valid
            if cfo_f_valid
                cir_val = r_f_i; ciq_val = r_f_q;
                raw_angle = atan2(ciq_val, cir_val) / (2*pi) * 65536;  % full circle = 2^16
                dphi = ashr(raw_angle, cfg.lag_log2);                  % /lag -> per-sample CFO
            end
            if cfg.cfo_correct_en
                phi = mod(phi + dphi + 32768, 65536) - 32768;   % wraps mod 2*pi, signed 16-bit
                ang = -phi/65536*2*pi;
                c = cos(ang); s = sin(ang);
                derot_i = agc_i*c - agc_q*s;
                derot_q = agc_i*s + agc_q*c;
            else
                derot_i = agc_i; derot_q = agc_q;   % transparent passthrough
            end
            derot_valid = true;
        end
        probe.dbg_raw_angle(n) = raw_angle;
        probe.cir(n) = cir_val;
        probe.ciq(n) = ciq_val;
        probe.phi(n) = phi;
        probe.dphi(n) = dphi;

        % ===== 4. STR: pipelined interpolating Gardner loop (trex1_str_top.v)
        % eta is a free-running phase accumulator (Q0.16) that decrements by
        % the current symbol period Wc each sample; whenever it underflows
        % (strobe) a new interpolated sample is due. Alternating on-time /
        % mid-symbol strobes feed the classic Gardner timing-error detector
        % (ted = correlation between the on-time error and the surrounding
        % mid-symbol samples), which nudges Wc so the strobes converge onto
        % the true symbol centers - this is the loop's only feedback path.
        str_valid = false;
        if derot_valid
            etaz = eta;
            strobe = etaz < Wc;
            eta_next = eta - Wc + (strobe * 65536);

            di = derot_i - str_ip; dq = derot_q - str_qp;
            mu = min(255, floor(eta/32));      % linear interpolation fraction

            if strobe
                yi = str_ip + (di*mu)/256;
                yq = str_qp + (dq*mu)/256;
                if ontime
                    str_i = yi; str_q = yq; str_valid = true;
                    ted0 = (yi - yi_onp) * yi_mid;
                    ted1 = (yq - yq_onp) * yq_mid;
                    ted = ted0 + ted1;                 % Gardner timing error
                    Wc_new = W0 + ashr(ted, KP_SHIFT);  % proportional loop update
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
        probe.hw_i_out(n) = str_i;   % held registers between strobes
        probe.hw_q_out(n) = str_q;
        probe.hw_valid_out(n) = str_valid;
    end
end

%% =========================================================================
%  Local helper functions
%% =========================================================================
function y = ashr(x, k)
%ASHR  Verilog-style arithmetic right shift ( >>> ): floor(x / 2^k).
    y = floor(x ./ (2.^k));
end

function y = clamp(x, lo, hi)
    y = min(max(x, lo), hi);
end

function cfg = default_cfg()
%DEFAULT_CFG  Parameters later carried into trex1_sync_hw_top.v's own RTL
%   instantiation
%   (AGC_WINDOW=100, SPS=16, PREAMBLE_SYMS=32) and its children.
    cfg = struct();
    cfg.bit_width = 12;    % DATA_WIDTH

    % -- AGC (trex1_ff_agc.v) --
    cfg.agc_window    = 100;
    cfg.agc_thr_p18db = 100000000;
    cfg.agc_thr_p12db = 25000000;
    cfg.agc_thr_p06db = 6250000;
    cfg.agc_thr_m06db = 390600;
    cfg.agc_thr_m12db = 97600;
    cfg.agc_thr_m18db = 24400;

    % -- CFO estimator/derotator (trex1_cfo_top.v / trex1_cfo_derotate.v) --
    cfg.sps           = 16;   % also the "fine" estimator's lag
    cfg.preamble_syms = 32;   % ACCUM_LEN = preamble_syms * sps = 512
    cfg.lag_log2      = 4;    % lag = 2^lag_log2 = 16 = sps
    cfg.cfo_correct_en = true;

    % -- STR (trex1_str_top.v Rev4) --
    cfg.str_kp_shift = 11;
    cfg.str_w0   = 8192;    % 2/16 in Q0.16 (2 strobes/symbol)
    cfg.str_wmin = 6144;    % 0.75*W0
    cfg.str_wmax = 10240;   % 1.25*W0
end