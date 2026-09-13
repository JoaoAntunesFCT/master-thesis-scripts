% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    05-2026 (mm-yyyy)
% Script Name:    cosine_sine
% Project Name:   TREX1 Digital Baseband Chain
% Description:    Generates the 1024-sample I/Q stimulus used by
%                 tb_trex1_sync_chain.v / nexys_a7_test_top.v: a 150-sample
%                 low-amplitude noise floor followed by a constant-amplitude
%                 rotating-phase tone (standing in for a residual CFO on the
%                 preamble/payload) that exercises AGC gain-stepping, CFO
%                 acquisition, and Gardner timing-error convergence. Packs
%                 each sample into a 12-bit I / 12-bit Q two's-complement hex
%                 word and writes it out as a Vivado .coe ROM initialization
%                 file.
%
% Output:         stimulus_data.coe, loaded into rom_stimulus (Block Memory
%                 Generator) in nexys_a7_test_top.v.

N = 1024;
I_data = zeros(N, 1);
Q_data = zeros(N, 1);

phase = 0; phase_inc = 0.314159;
for k = 1:N
    if k < 150 % Noise floor
        I_data(k) = 20; Q_data(k) = 20;
    else       % Preamble/Payload
        I_data(k) = round(800 * cos(phase));
        Q_data(k) = round(800 * sin(phase));
        phase = phase + phase_inc;
    end
end

% Write to .coe file for Vivado
fid = fopen('stimulus_data.coe', 'w');
fprintf(fid, 'memory_initialization_radix=16;\n');
fprintf(fid, 'memory_initialization_vector=\n');
for k = 1:N
    % Combine 12-bit I and 12-bit Q into one 24-bit hex string
    % Handle two's complement for negative numbers
    I_hex = dec2hex(mod(I_data(k), 4096), 3);
    Q_hex = dec2hex(mod(Q_data(k), 4096), 3);

    if k == N
        fprintf(fid, '%s%s;\n', I_hex, Q_hex);
    else
        fprintf(fid, '%s%s,\n', I_hex, Q_hex);
    end
end
fclose(fid);
