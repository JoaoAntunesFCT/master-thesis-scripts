%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    ddc_receiver_model
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Golden bit - and cycle-accurate reference model of the DDC
%                 (digital down-converter) receiver front end. See the
%                 detailed header below for the full signal chain and I/O.
%
% Dependencies:   ddc_testbench.m
%
%////////////////////////////////////////////////////////////////////////////////
function dbg = ddc_receiver_model(cfg, raw_i_in, raw_q_in, enable)
% ============================================================================
%  ddc_receiver_model  -  DDC / narrow-band receiver front-end reference model
% ----------------------------------------------------------------------------
%  This function is the GOLDEN, bit- and cycle-accurate MATLAB reference model
%  of the digital down-converter (DDC) receiver chain. It is the executable
%  specification of the design: the fixed-point behaviour defined here (bit
%  widths, sign conventions, CIC guard bits, truncation points, FIR pipeline
%  scheduling and the fs/4 rotation table) is the contract that any downstream
%  fixed-point / RTL realisation is expected to reproduce sample-for-sample.
%  Everything is written in the same integer arithmetic the target hardware
%  uses, so a hardware implementation is a direct transcription of this model
%  and can be verified against the vectors it produces.
%
%  SIGNAL CHAIN (one sample per system clock, Fs = cfg.Fs)
%
%     raw_i/q  ->  ADC format aligner  ->  complex mixer  ->  CIC decimator
%                                              |                    |
%                                    fs/4 table  OR  NCO       (rate = R)
%                                              |                    v
%                                              +--------------->  73-tap FIR  -> baseband I/Q
%
%  MODEL OUTPUT (struct dbg, all vectors sampled at the full system-clock rate,
%  held between decimated updates exactly the way an on-chip logic analyser
%  would latch the buses):
%     .aligned_i/.aligned_q  - 10-bit signed ADC after resolution alignment
%     .mixer_i /.mixer_q     - 23-bit signed complex mixer output  (pre-CIC)
%     .cic_i   /.cic_q       - 24-bit signed CIC output            (pre-FIR)
%     .base_i  /.base_q      - 24-bit signed baseband output       (post-FIR)
%     .phase                 - 24-bit NCO phase accumulator (signed for display)
%     .valid                 - decimation / baseband-valid strobe (1 clk wide)
%     .valid_level           - held-high "streaming" flag, first valid onward
%
%  CONFIG (struct cfg):
%     .Fs              system clock in Hz
%     .fcw             24-bit frequency control word (signed) for the NCO
%     .R               CIC decimation rate (1..15)
%     .adc_res_sel     0:7-bit  1:8-bit  2:9-bit  3:10-bit  ADC resolution
%     .mode_sel        0: fs/4 fixed mixer path   1: NCO complex mixer path
%
%  NOTE ON PROBE ORDERING: the fs/4 mixer, NCO and CIC integrators all advance
%  only while enable is high, mirroring a clock-enabled datapath. The NCO phase
%  accumulator therefore free-runs on the same enable, which is why the phase
%  ramp is observable on the probe even when mode_sel selects the fs/4 path.
% ============================================================================

    N = numel(raw_i_in);

    % ---- resolution-select bit width -------------------------------------
    nbits_tbl = [7 8 9 10];
    nbits     = nbits_tbl(cfg.adc_res_sel + 1);

    % ---- NCO / LO look-up table (12-bit signed, ~72 dB SFDR) -------------
    % The LO cos/sin table matches an upgraded 12-bit DDS: 10b x 12b products.
    LO_AMPL = 2047;                    % 12-bit signed full scale

    % ---- CIC constants ----------------------------------------------------
    %  4th-order, 38-bit integrators (23-bit input + 15 guard bits for R<=15).
    %  Output truncation: keep top 24 of 38 bits  ->  divide by 2^14.
    CIC_ORDER   = 4;                   %#ok<NASGU>  (documented, hard-coded below)
    CIC_TRUNC   = 14;

    % ---- FIR channel filter -------------------------------------------------
    %  73-tap symmetric linear-phase, Q1.15 coefficients (DC gain ~ 1.17).
    %  Output scaling: acc >>> 15 (arithmetic), keep 24 bits.
    h        = fir_coeffs();           % 1x73 double (integer Q1.15 values)
    FIR_TAPS = numel(h);               % 73
    FIR_SHIFT = 15;

    % ---- output storage ---------------------------------------------------
    dbg.aligned_i   = zeros(N,1);
    dbg.aligned_q   = zeros(N,1);
    dbg.mixer_i     = zeros(N,1);
    dbg.mixer_q     = zeros(N,1);
    dbg.cic_i       = zeros(N,1);
    dbg.cic_q       = zeros(N,1);
    dbg.base_i      = zeros(N,1);
    dbg.base_q      = zeros(N,1);
    dbg.phase       = zeros(N,1);
    dbg.valid       = zeros(N,1);
    dbg.valid_level = zeros(N,1);

    % ---- state: fs/4 mixer -----------------------------------------------
    seq_cnt = 0;                       % 2-bit rotation index
    fs4_i   = 0;  fs4_q = 0;           % registered outputs (11-bit signed)

    % ---- state: NCO -------------------------------------------------------
    phase_acc = 0;                     % 24-bit accumulator (unsigned domain)

    % ---- state: registered mixer output ----------------------------------
    mix_i = 0;  mix_q = 0;             % 23-bit signed

    % ---- state: CIC (two independent channels) ---------------------------
    cicI = cic_reset();
    cicQ = cic_reset();
    dec_cnt = 0;                       % shared decimation counter

    % ---- state: FIR delay lines (decimated rate) -------------------------
    dlI = zeros(1, FIR_TAPS);
    dlQ = zeros(1, FIR_TAPS);
    base_i = 0;  base_q = 0;
    seen_valid = false;

    % ======================================================================
    %  Cycle-by-cycle evaluation
    % ======================================================================
    for n = 1:N
        en = enable(n) ~= 0;

        % --- ADC format aligner (combinational) ---------------------------
        aligned_i = align_sample(raw_i_in(n), nbits);
        aligned_q = align_sample(raw_q_in(n), nbits);

        if en
            % --- NCO phase accumulator (24-bit wrap) ----------------------
            % 12-bit LO cos/sin from the top 16 bits of the phase word.
            ph_top = floor(mod(phase_acc, 2^24) / 2^8);      % phase[23:8]
            theta  = 2*pi * ph_top / 2^16;
            cos_lo = round(LO_AMPL * cos(theta));
            sin_lo = round(LO_AMPL * sin(theta));
            phase_acc = mod(phase_acc + cfg.fcw, 2^24);

            % --- fs/4 fixed mixer: multiply by e^{-j*pi/2*n} --------------
            %   n mod 4 = 0 : (+I,+Q)   1 : (+Q,-I)   2 : (-I,-Q)   3 : (-Q,+I)
            switch seq_cnt
                case 0, fs4_i =  aligned_i;  fs4_q =  aligned_q;
                case 1, fs4_i =  aligned_q;  fs4_q = -aligned_i;
                case 2, fs4_i = -aligned_i;  fs4_q = -aligned_q;
                case 3, fs4_i = -aligned_q;  fs4_q =  aligned_i;
            end
            seq_cnt = mod(seq_cnt + 1, 4);

            % --- NCO complex mixer (lower-sideband selection) ------------
            nco_i = aligned_i*cos_lo - aligned_q*sin_lo;
            nco_q = aligned_q*cos_lo + aligned_i*sin_lo;

            % --- mixer output mux (registered) ---------------------------
            if cfg.mode_sel == 0
                mix_i = fs4_i;   mix_q = fs4_q;      % fs/4 path (sign-extended)
            else
                mix_i = nco_i;   mix_q = nco_q;      % NCO path
            end
        end

        % --- CIC decimator (integrators run every enabled clock) ----------
        strobe = false;
        if en
            cicI = cic_integrate(cicI, mix_i);
            cicQ = cic_integrate(cicQ, mix_q);

            if dec_cnt == (cfg.R - 1)
                dec_cnt = 0;
                strobe  = true;
            else
                dec_cnt = dec_cnt + 1;
            end

            if strobe
                cicI = cic_comb(cicI, CIC_TRUNC);
                cicQ = cic_comb(cicQ, CIC_TRUNC);
            end
        end

        % --- FIR channel filter (runs on the decimation strobe) -----------
        if strobe
            dlI = [cicI.dout, dlI(1:end-1)];
            dlQ = [cicQ.dout, dlQ(1:end-1)];
            base_i = fir_eval(h, dlI, FIR_SHIFT);
            base_q = fir_eval(h, dlQ, FIR_SHIFT);
            seen_valid = true;
        end

        % --- probe capture (ILA-style: buses hold between updates) --------
        dbg.aligned_i(n) = aligned_i;
        dbg.aligned_q(n) = aligned_q;
        dbg.mixer_i(n)   = mix_i;
        dbg.mixer_q(n)   = mix_q;
        dbg.cic_i(n)     = cicI.dout;
        dbg.cic_q(n)     = cicQ.dout;
        dbg.base_i(n)    = base_i;
        dbg.base_q(n)    = base_q;
        dbg.phase(n)     = to_signed(phase_acc, 24);
        dbg.valid(n)     = strobe;
        dbg.valid_level(n) = seen_valid;
    end
end

% ============================================================================
%  Local helper functions
% ============================================================================

function y = align_sample(raw, nbits)
% ADC format aligner: interpret the low nbits of the raw word as a two's
% complement number and sign-extend to 10-bit signed. adc_res_sel=3 (nbits=10)
% is a straight pass-through.
    u = mod(round(raw), 2^nbits);          % keep nbits, unsigned pattern
    y = to_signed(u, nbits);               % sign-extend to signed value
end

function s = to_signed(u, nbits)
% Two's complement re-interpretation of an unsigned integer word.
    half = 2^(nbits-1);
    s = mod(u, 2^nbits);
    if s >= half
        s = s - 2^nbits;
    end
end

function c = cic_reset()
% Integrator + comb register file for one CIC channel.
    c.int  = [0 0 0 0];                 % 4 cascaded integrators (38-bit)
    c.cd   = [0 0 0 0];                 % comb delay registers
    c.diff = [0 0 0 0];                 % comb difference outputs
    c.dout = 0;                         % 24-bit truncated output
end

function c = cic_integrate(c, din)
% 4 cascaded accumulators. Uses previous-cycle values (non-blocking semantics).
    p = c.int;
    c.int(1) = p(1) + din;
    c.int(2) = p(2) + p(1);
    c.int(3) = p(3) + p(2);
    c.int(4) = p(4) + p(3);
end

function c = cic_comb(c, trunc)
% 4 cascaded differentiators, clocked on the decimation strobe. All registers
% update simultaneously, so each stage differences the PREVIOUS strobe value.
% Output takes the registered diff4 from the previous strobe, truncated.
    cd   = c.cd;
    diff = c.diff;
    c.dout   = floor(diff(4) / 2^trunc);     % arithmetic >> trunc (drop LSBs)
    ndiff    = [0 0 0 0];
    ncd      = [0 0 0 0];
    ndiff(1) = c.int(4) - cd(1);   ncd(1) = c.int(4);
    ndiff(2) = diff(1)  - cd(2);   ncd(2) = diff(1);
    ndiff(3) = diff(2)  - cd(3);   ncd(3) = diff(2);
    ndiff(4) = diff(3)  - cd(4);   ncd(4) = diff(3);
    c.diff = ndiff;
    c.cd   = ncd;
end

function y = fir_eval(h, dl, shift)
% 73-tap FIR: full multiply-accumulate then arithmetic right shift (Q1.15).
    acc = sum(h .* dl);
    y   = floor(acc / 2^shift);
end

function h = fir_coeffs()
% 73-tap symmetric linear-phase channel filter, Q1.15 integer coefficients.
% Half-length coefficients C00..C36 (C36 is the centre tap); mirrored to 73.
    half = [   0,    1,    3,    6,   11,   17,   23,   30,   35,   36, ...
              33,   23,    5,  -23,  -60, -105, -155, -207, -253, -287, ...
            -302, -288, -240, -150,  -15,  167,  394,  660,  957, 1273, ...
            1594, 1903, 2184, 2422, 2603, 2715, 2754 ];   % C00 .. C36
    h = [half, fliplr(half(1:end-1))];                    % 73 taps, symmetric
end