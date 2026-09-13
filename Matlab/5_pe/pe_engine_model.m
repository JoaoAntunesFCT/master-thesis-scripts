%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    pe_engine_model
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Golden, cycle-accurate reference model of the receive
%                 Packet Engine: PN9 de-whiten, CRC-16 syndrome, single-bit
%                 error correction via syndrome lookup. This model's
%                 syndrome table IS the source the RTL's syndrome ROM is
%                 generated from - see the detailed header below.
%
% Dependencies:   tb_trex1_pe_hdl.m
%
%////////////////////////////////////////////////////////////////////////////////
function dbg = pe_engine_model(raw_bit_in, enable)
% ============================================================================
%  pe_engine_model  -  Packet Engine: de-whiten + CRC-16 + single-bit correct
% ----------------------------------------------------------------------------
%  This function is the GOLDEN, cycle-accurate MATLAB reference model of the
%  receive packet engine. It is the executable specification of the block: the
%  bit-serial arithmetic and the end-of-packet control defined here are the
%  contract a fixed-point / RTL realisation must reproduce bit-for-bit, and a
%  hardware implementation (including the syndrome ROM) is generated from it.
%
%  PACKET FORMAT
%     272-bit packet = 256-bit payload  ||  16-bit CRC
%     Streamed MSB-first, one bit per enabled clock.
%
%  STAGES
%   1. PN9 de-whitener        LFSR x^9 + x^5 + 1, seed 0x1FF.
%                             dewhitened_bit = raw_bit_in XOR pn9_state[8].
%   2. CRC-16 syndrome        LFSR x^16 + x^12 + x^5 + 1, seed 0x0000, run over
%                             all 272 de-whitened bits. A clean packet leaves
%                             syndrome = 0 (the transmit CRC makes the whole
%                             packet divisible by the generator).
%   3. Syndrome -> error idx  A single bit flipped at arrival position i leaves
%                             a unique non-zero CRC residual. The table built
%                             here (inject a unit error at every one of the 272
%                             positions and record its residual) IS the
%                             syndrome ROM the hardware instantiates. Syndrome 0
%                             means no error; a syndrome absent from the table
%                             means a multi-bit / uncorrectable error.
%   4. Correct + strip CRC    On the clock after 'enable' falls, the 272-bit
%                             receive buffer is evaluated:
%                               syndrome == 0            -> accept, valid
%                               syndrome in table        -> flip the indicated
%                                                           payload bit, accept
%                               otherwise                -> drop, packet_error
%                             Output = buffer[271:16] (payload, CRC removed).
%
%  INDEX MAPPING (buffer is shifted left, first bit received -> MSB):
%     LUT arrival index i  <->  physical buffer bit (271 - i)
%     A correctable payload error lands on clean_payload_out[(271-i)-16].
%
%  I/O (per system-clock vectors):
%     raw_bit_in : received (still whitened) bit stream
%     enable     : high while packet bits are being clocked in
%
%  dbg (struct):
%     .crc_syndrome  - 16-bit syndrome register, per clock
%     .packet_valid  - 1-clock accept pulse, per clock
%     .packet_error  - uncorrectable flag, per clock
%     .clean_payload - final 256-bit payload as a logical row (bit 0 = LSB)
%     .payload_hex   - compact hex string ("32x0xA5" style when all bytes equal)
%     .error_idx     - resolved error index (511 = none/uncorrectable)
%     .valid_clk     - clock index at which packet_valid pulsed (0 if none)
% ============================================================================

    N = numel(raw_bit_in);

    % ---- golden syndrome table (this is the source of the RTL syndrome_lut).
    syn_key = zeros(272,1);
    for i = 0:271
        c = zeros(1,16);
        for k = 0:271
            c = crc_step(c, double(k==i));
        end
        syn_key(i+1) = crc_to_int(c);
    end
    % map: syndrome value -> arrival index (linear search kept simple/portable)

    % ---- registers --------------------------------------------------------
    pn9    = ones(1,9);          % PN9 state, seed 0x1FF
    crc    = zeros(1,16);        % CRC-16 syndrome, seed 0x0000
    buffer = zeros(1,272);       % receive shift register, buffer(1)=bit271 .. buffer(272)=bit0
    enable_d = 0;
    clean_payload = zeros(1,256);
    packet_valid  = 0;
    packet_error  = 0;

    dbg.crc_syndrome = zeros(N,1);
    dbg.packet_valid = zeros(N,1);
    dbg.packet_error = zeros(N,1);
    dbg.error_idx    = 511;
    dbg.valid_clk    = 0;

    for n = 1:N
        en = enable(n) ~= 0;
        raw = raw_bit_in(n) ~= 0;

        dewhit = xor(raw, pn9(1));                 % pn9(1) = state[8]

        % -------- next-state datapath (PN9 + CRC + buffer) ----------------
        if en
            n_pn9    = pn9_step(pn9);
            n_crc    = crc_step(crc, dewhit);
            n_buffer = [dewhit, buffer(1:271)];    % shift left, new bit -> MSB
        else
            n_pn9    = ones(1,9);                  % reset between packets
            n_crc    = zeros(1,16);
            n_buffer = buffer;                     % hold captured packet
        end

        % -------- end-of-packet evaluation (uses CURRENT registers) -------
        correction_trigger = (enable_d && ~en);
        n_valid = 0;  n_error = packet_error;  n_payload = clean_payload;
        if correction_trigger
            synd = crc_to_int(crc);
            idx  = lut_lookup(syn_key, synd);      % 511 if not present
            if synd == 0
                n_payload = buffer(2:257);         % buffer[271:16]  (MSB-first)
                n_error = 0;  n_valid = 1;  dbg.error_idx = 511;
            elseif idx ~= 511
                n_payload = buffer(2:257);
                jphys = 271 - idx;                 % physical buffer bit
                if jphys >= 16
                    bpos = jphys - 16;             % clean_payload_out bit index
                    % buffer(1)=bit271 -> buffer bit j is buffer(272-j)
                    n_payload(bpos+1) = ~buffer(272 - jphys);
                end
                n_error = 0;  n_valid = 1;  dbg.error_idx = idx;
            else
                n_payload = zeros(1,256);
                n_error = 1;  n_valid = 0;  dbg.error_idx = 511;
            end
            dbg.valid_clk = n * (n_valid==1);
        end

        % -------- commit --------------------------------------------------
        pn9 = n_pn9;  crc = n_crc;  buffer = n_buffer;  enable_d = en;
        clean_payload = n_payload;  packet_valid = n_valid;  packet_error = n_error;

        dbg.crc_syndrome(n) = crc_to_int(crc);
        dbg.packet_valid(n) = packet_valid;
        dbg.packet_error(n) = packet_error;
    end

    % ---- convert clean_payload bit index: n_payload(k) = clean_payload_out[k-1]
    %      Above we filled n_payload from buffer[271:16] MSB-first; re-map so
    %      that clean_payload(1) is bit 0 (LSB) for byte formatting.
    dbg.clean_payload = payload_lsb_first(clean_payload);
    dbg.payload_hex   = format_payload(dbg.clean_payload);
end

% ============================================================================
%  Helpers
% ============================================================================
function c = crc_step(crc, inbit)
% CRC-16 LFSR update, x^16 + x^12 + x^5 + 1.  crc(16) = MSB (bit15).
    fb = xor(crc(16), inbit);
    c = zeros(1,16);           % c(k) = bit(k-1)
    c(16)=crc(15); c(15)=crc(14); c(14)=crc(13); c(13)=crc(12);
    c(12)=xor(crc(11), fb);
    c(11)=crc(10); c(10)=crc(9); c(9)=crc(8); c(8)=crc(7); c(7)=crc(6); c(6)=crc(5);
    c(5)=xor(crc(4), fb);
    c(4)=crc(3); c(3)=crc(2); c(2)=crc(1);
    c(1)=fb;
end

function v = crc_to_int(crc)
    v = 0;
    for k = 1:16, v = v + crc(k) * 2^(k-1); end
end

function s = pn9_step(s)
% PN9 LFSR update, x^9 + x^5 + 1.  s(1) = state[8] (MSB).
    fb = xor(s(1), s(5));      % state[8] ^ state[4]
    s = [fb, s(1:8)];
end

function idx = lut_lookup(syn_key, synd)
    idx = 511;
    hit = find(syn_key == synd, 1);
    if ~isempty(hit), idx = hit - 1; end
end

function p = payload_lsb_first(msb_first_256)
% Input is buffer[271:16] captured MSB-first: element 1 = payload MSB (bit255).
% clean_payload_out[j] = that MSB-first vector reversed.
    p = fliplr(msb_first_256);   % p(1) = bit0 (LSB)
end

function str = format_payload(p_lsb)
% Compact display. If all 32 bytes are equal, show "32x0xHH"; else full hex.
    nbytes = 32;
    bytes = zeros(1,nbytes);
    for b = 0:nbytes-1
        v = 0;
        for t = 0:7, v = v + p_lsb(8*b+t+1) * 2^t; end
        bytes(b+1) = v;
    end
    if all(bytes == bytes(1))
        str = sprintf('%dx0x%02X', nbytes, bytes(1));
    else
        h = '';
        for b = nbytes:-1:1, h = [h, sprintf('%02X', bytes(b))]; end %#ok<AGROW>
        str = ['0x', h];
    end
end