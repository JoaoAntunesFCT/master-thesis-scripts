%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    gmsk_demod_model
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Golden, cycle-accurate reference model of the GMSK/MSK
%                 1-bit-delay differential (quadricorrelator) demodulator.
%                 See the detailed header below for the discriminator math
%                 and pipeline timing.
%
% Dependencies:   tb_trex1_gmsk_hdl.m
%
%////////////////////////////////////////////////////////////////////////////////
function dbg = gmsk_demod_model(i_in, q_in, valid_in)
% ============================================================================
%  gmsk_demod_model  -  1-bit-delay GMSK / MSK differential demodulator
% ----------------------------------------------------------------------------
%  This function is the GOLDEN, cycle-accurate MATLAB reference model of the
%  GMSK hard-decision demodulator. It is the executable specification of the
%  block: the arithmetic and the sample-by-sample pipeline scheduling defined
%  here (1-symbol delay, complex cross-multiply, zero-threshold slicer, and the
%  two-stage valid pipeline) are the contract a fixed-point / RTL realisation
%  must reproduce bit-for-bit. A hardware implementation is a direct
%  transcription of this model and is verified against the vectors it produces.
%
%  PRINCIPLE  (differential / quadricorrelator FM discriminator)
%     For a complex baseband symbol stream z[n] = I[n] + jQ[n], the instantaneous
%     frequency (phase advance per symbol) is recovered from the product of the
%     current symbol with the conjugate of the previous symbol:
%
%         z[n] * conj(z[n-1]) = A^2 * exp( j*(phi[n] - phi[n-1]) )
%
%     The imaginary part is the frequency-deviation discriminant:
%
%         freq_dev = Im{ z[n] * conj(z[n-1]) }
%                  = Q[n]*I[n-1] - I[n]*Q[n-1]
%                  = A^2 * sin( phi[n] - phi[n-1] )
%
%     For GMSK/MSK the transmit modulator advances the phase by +pi/2 (or the
%     GMSK-shaped equivalent) for a '1' and -pi/2 for a '0', so the sign of
%     freq_dev is the transmitted bit. The slicer is therefore a comparison
%     against zero:  freq_dev > 0  ->  rx_bit = 1,  else  0.
%
%  I/O (all vectors sampled at the full system-clock rate; a new symbol is
%  presented whenever valid_in is high, and buses / registered outputs hold
%  their value between strobes exactly as an on-chip logic analyser latches them):
%     i_in, q_in   - signed 12-bit I/Q sample bus            (held per symbol)
%     valid_in     - 1-clock strobe marking a fresh symbol
%
%  dbg (struct) returned probes:
%     .freq_dev   - signed 25-bit discriminator output       (held)  [24:0]
%     .rx_bit     - hard-decision bit                         (held)
%     .valid_out  - 1-clock strobe marking a fresh decoded bit
%     .bits       - column vector of decoded bits, in valid_out order
%     .bitstr     - the decoded bits as a char string (MSB-first, in time)
%
%  PIPELINE (clocks after a symbol strobe on valid_in):
%     stage 1 : i_prev/q_prev latch, cross products latch, mult_valid set
%     stage 2 : freq_dev / rx_bit latch, valid_out pulses
%  The first symbol only primes the 1-symbol delay (no previous symbol yet),
%  so it produces no valid_out; decoding starts on the second symbol.
%
%  BIT WIDTHS (documented; MATLAB uses double, values stay exact):
%     i_in/q_in     signed [11:0]
%     cross_q_i     signed [23:0]   = Q[n]*I[n-1]
%     cross_i_q     signed [23:0]   = I[n]*Q[n-1]
%     freq_dev      signed [24:0]   = cross_q_i - cross_i_q
% ============================================================================

    N = numel(i_in);

    dbg.freq_dev  = zeros(N,1);
    dbg.rx_bit    = zeros(N,1);
    dbg.valid_out = zeros(N,1);

    % ---- registered state -------------------------------------------------
    i_prev = 0;  q_prev = 0;  delay_valid = 0;      % 1-symbol delay line
    cross_q_i = 0;  cross_i_q = 0;  mult_valid = 0; % pipeline stage 1
    freq_dev = 0;   rx_bit = 0;     valid_out = 0;  % pipeline stage 2

    bits = [];

    for n = 1:N
        vin = valid_in(n) ~= 0;

        % -------- capture NEXT-state (non-blocking semantics) --------------
        n_i_prev = i_prev;  n_q_prev = q_prev;  n_delay_valid = delay_valid;
        n_cross_q_i = cross_q_i;  n_cross_i_q = cross_i_q;
        n_mult_valid = mult_valid;

        % -------- stage 1: 1-symbol delay + complex cross multiply ---------
        if vin
            n_i_prev = i_in(n);
            n_q_prev = q_in(n);
            n_delay_valid = 1;
            if delay_valid
                n_cross_q_i = q_in(n) * i_prev;    % Q[n] * I[n-1]
                n_cross_i_q = i_in(n) * q_prev;    % I[n] * Q[n-1]
                n_mult_valid = 1;
            end
        else
            n_mult_valid = 0;
        end

        % -------- stage 2: subtract + zero-threshold slicer ---------------
        n_valid_out = mult_valid;
        n_freq_dev  = freq_dev;      % hold unless a new product is ready
        n_rx_bit    = rx_bit;
        if mult_valid
            n_freq_dev = cross_q_i - cross_i_q;
            n_rx_bit   = double(n_freq_dev > 0);
        end

        % -------- commit registers ----------------------------------------
        i_prev = n_i_prev;  q_prev = n_q_prev;  delay_valid = n_delay_valid;
        cross_q_i = n_cross_q_i;  cross_i_q = n_cross_i_q;
        mult_valid = n_mult_valid;
        freq_dev = n_freq_dev;  rx_bit = n_rx_bit;  valid_out = n_valid_out;

        % -------- probe capture (held buses, ILA style) -------------------
        dbg.freq_dev(n)  = freq_dev;
        dbg.rx_bit(n)    = rx_bit;
        dbg.valid_out(n) = valid_out;
        if valid_out
            bits(end+1,1) = rx_bit; %#ok<AGROW>
        end
    end

    dbg.bits   = bits;
    dbg.bitstr = sprintf('%d', bits);
end