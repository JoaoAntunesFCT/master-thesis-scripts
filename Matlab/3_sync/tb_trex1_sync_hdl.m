%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    tb_trex1_sync_hdl
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Testbench for sync_model.m. Builds a packet-framed
%                 stimulus (preamble + data, with a deliberate residual
%                 CFO) and renders the sync-block ILA-style figure plus a
%                 diagnostics figure. See the detailed header below for why
%                 this stimulus needs explicit preamble framing.
%
% Dependencies:   sync_model.m
%
%////////////////////////////////////////////////////////////////////////////////
%TB_SYNC_MODEL  Testbench for sync_model.m. Just run it - no arguments.
%
% Builds a packet-framed stimulus - a preamble region (unmodulated tone,
% long enough to complete one full CFO accumulation window) followed by a
% data region - with a deliberate frequency offset baked in, so the CFO
% estimator has something real to lock onto and the derotator/STR have
% something to do. This is a DIFFERENT stimulus shape than
% rx_chain_testbench.m's continuous calibration tone, because sync_model's
% CFO stage is preamble-gated and one-shot (see sync_model.m's header) -
% a stimulus with no preamble framing would never produce a CFO estimate
% at all.
%
% Renders a figure in the SAME layout/colours as generate_graphs.py's
% sync-block ILA figure (hw_i_out/hw_q_out, hw_valid_out, cfo_coarse_i),
% for direct visual comparison against a real ILA capture of
% trex1_sync_hw_top. Saved as matlab_sync.png.

clear; clc; close all;

%% ---------------------------------------------------------------------
%  1. Configuration & stimulus
%% ---------------------------------------------------------------------
cfg = sync_model();

sps        = cfg.sps;                          % 16 samples/symbol
accum_len  = cfg.preamble_syms * cfg.sps;      % 512 samples = 1 CFO window
N_preamble = accum_len + 3*sps;                % a little extra past the
                                                 % window so cfo_*_valid
                                                 % actually asserts and is
                                                 % visible before the data
                                                 % region begins
N_data     = 2048;
N          = N_preamble + N_data;

n = (0:N-1)';
amp = 180;

% Deliberate residual carrier frequency offset left after down-conversion,
% expressed as a fraction of the symbol rate so the derotator/STR have a
% real, non-trivial angle to track (matches the kind of residual CFO the
% upstream DDC would leave behind after down-conversion).
f_cfo_frac = 1/280;    % cycles per baseband sample

i_ideal = amp*cos(2*pi*f_cfo_frac*n);
q_ideal = amp*sin(2*pi*f_cfo_frac*n);

hw_i_in = round(i_ideal);
hw_q_in = round(q_ideal);

adc_max = 2^(cfg.bit_width-1) - 1;
hw_i_in = max(min(hw_i_in, adc_max), -adc_max-1);
hw_q_in = max(min(hw_q_in, adc_max), -adc_max-1);

preamble_flag = false(N,1);
preamble_flag(1:N_preamble) = true;

%% ---------------------------------------------------------------------
%  2. Run the model
%% ---------------------------------------------------------------------
fprintf('Running sync_model over %d samples (preamble = first %d samples)...\n', ...
        N, N_preamble);
tic; probe = sync_model(hw_i_in, hw_q_in, preamble_flag, cfg); toc

x = (0:N-1)';

%% ---------------------------------------------------------------------
%  3. Plot - mirrors generate_graphs.py's palette/panel layout exactly
%% ---------------------------------------------------------------------
BLUE = [0.165 0.471 0.839]; ORANGE = [0.922 0.408 0.204];
AQUA = [0.106 0.686 0.478]; DIGC = [0.227 0.227 0.220];
set(0, 'DefaultAxesFontSize', 9, 'DefaultAxesColor', [0.988 0.988 0.984]);

trig_x = find(diff([0; double(preamble_flag)]) == -1, 1);  % preamble->data edge
if isempty(trig_x), trig_x = N_preamble; end

fig = figure('Color','w','Position',[50 50 1250 800]);

% NOTE: trigger markers below use line(), not plot(). line() always adds
% to the current axes without needing hold on and without resetting axis
% limits - plot() clears the axes and re-autoscales unless hold is on,
% which is a trap here since each subplot below only draws its data once.

subplot(4,1,1);
plot(x, probe.hw_i_out, 'Color', BLUE); hold on;
plot(x, probe.hw_q_out, 'Color', ORANGE);
if ~isempty(trig_x), line([trig_x trig_x], ylim, 'Color', ORANGE, 'LineStyle', '--'); end
ylabel({'STR output','hw\_i/q\_out [11:0]'});
legend('hw\_i\_out','hw\_q\_out','Location','eastoutside');
title('Symbol Timing Recovery''s final synchronized I/Q output', ...
      'FontSize', 9, 'FontWeight','normal', 'Color',[0.32 0.32 0.31]);

subplot(4,1,2);
stairs(x, double(probe.hw_valid_out), 'Color', DIGC);
if ~isempty(trig_x), line([trig_x trig_x], [-0.4 1.4], 'Color', ORANGE, 'LineStyle', '--'); end
ylim([-0.4 1.4]); yticks([0 1]); ylabel('hw\_valid\_out');
title('One strobe per recovered symbol', ...
      'FontSize', 9, 'FontWeight','normal', 'Color',[0.32 0.32 0.31]);

subplot(4,1,3);
stairs(x, probe.cfo_coarse_i, 'Color', AQUA);
if ~isempty(trig_x), line([trig_x trig_x], ylim, 'Color', ORANGE, 'LineStyle', '--'); end
ylabel({'cfo\_coarse\_i','[33:0]'});
title('CFO lag-1 autocorrelation accumulator (trex1\_blue\_autocorr, coarse estimator)', ...
      'FontSize', 9, 'FontWeight','normal', 'Color',[0.32 0.32 0.31]);

subplot(4,1,4);
stairs(x, double(preamble_flag), 'Color', DIGC);
if ~isempty(trig_x), line([trig_x trig_x], [-0.4 1.4], 'Color', ORANGE, 'LineStyle', '--'); end
ylim([-0.4 1.4]); yticks([0 1]); ylabel('preamble\_flag');
xlabel('Sample in Window');

sync_title = ['MATLAB Model ' char(8212) ' Sync (AGC ' char(8594) ' CFO ' char(8594) ' STR)'];
if exist('sgtitle', 'builtin') || exist('sgtitle', 'file')
    sgtitle(sync_title, 'FontWeight','bold', 'FontSize', 13);
else
    % Octave has no sgtitle() (MATLAB R2018b+ only) - annotation fallback.
    annotation('textbox', [0 0.955 1 0.04], 'String', sync_title, ...
               'EdgeColor','none', 'HorizontalAlignment','center', ...
               'FontWeight','bold', 'FontSize', 13);
end
print(fig, 'matlab_sync.png', '-dpng', '-r150');

%% ---------------------------------------------------------------------
%  4. Extra diagnostic figure: derotator + fine-estimator internals
%     (not in the reference ILA capture, but useful for deeper debugging)
%% ---------------------------------------------------------------------
fig2 = figure('Color','w','Position',[50 50 1250 800]);
subplot(4,1,1);
plot(x, probe.agc_i_out, 'Color', BLUE); hold on;
plot(x, probe.agc_q_out, 'Color', ORANGE);
ylabel('AGC out'); legend('agc\_i','agc\_q','Location','eastoutside');

subplot(4,1,2);
stairs(x, probe.cfo_fine_i, 'Color', BLUE); hold on;
stairs(x, probe.cfo_fine_q, 'Color', ORANGE);
ylabel({'cfo\_fine','(feeds derotator)'}); legend('fine\_i','fine\_q','Location','eastoutside');

subplot(4,1,3);
plot(x, probe.phi, 'Color', AQUA); ylabel('phi [15:0]');

subplot(4,1,4);
plot(x, probe.dphi, 'Color', DIGC); ylabel('dphi [16:0]');
xlabel('Sample in Window');

internals_title = ['MATLAB Model ' char(8212) ' Sync internals (AGC / fine CFO / derotator)'];
if exist('sgtitle', 'builtin') || exist('sgtitle', 'file')
    sgtitle(internals_title, 'FontWeight','bold', 'FontSize', 13);
else
    annotation('textbox', [0 0.955 1 0.04], 'String', internals_title, ...
               'EdgeColor','none', 'HorizontalAlignment','center', ...
               'FontWeight','bold', 'FontSize', 13);
end
print(fig2, 'matlab_sync_internals.png', '-dpng', '-r150');

%% ---------------------------------------------------------------------
%  5. Summary
%% ---------------------------------------------------------------------
fprintf('\n--- Summary ---\n');
fprintf('agc_valid pulses       : %d\n', sum(probe.agc_valid_out));
idx_c = find(probe.cfo_coarse_valid, 1);
idx_f = find(probe.cfo_fine_valid, 1);
if isempty(idx_c), idx_c_str = '(never)'; else, idx_c_str = num2str(idx_c); end
if isempty(idx_f), idx_f_str = '(never)'; else, idx_f_str = num2str(idx_f); end
fprintf('cfo_coarse_valid first asserted at sample : %s\n', idx_c_str);
fprintf('cfo_fine_valid   first asserted at sample : %s\n', idx_f_str);
if ~isempty(idx_c)
    fprintf('cfo_coarse_i/q AT that instant (lag-1)  : %.0f / %.0f\n', ...
            probe.cfo_coarse_i(idx_c), probe.cfo_coarse_q(idx_c));
end
if ~isempty(idx_f)
    fprintf('cfo_fine_i/q   AT that instant (lag-16) : %.0f / %.0f\n', ...
            probe.cfo_fine_i(idx_f), probe.cfo_fine_q(idx_f));
end
fprintf(['(Both correctly reset to 0 once the preamble ends - see\n' ...
         ' sync_model.m''s header on the preamble-gated, one-shot\n' ...
         ' accumulate-then-hold-then-reset behaviour this model defines\n' ...
         ' and trex1_blue_autocorr.v''s RTL later implemented. The values\n' ...
         ' above, not the final-sample values, are the meaningful CFO\n' ...
         ' estimate.)\n']);
fprintf('hw_valid_out (STR) pulses   : %d\n', sum(probe.hw_valid_out));
fprintf('Figures saved: matlab_sync.png, matlab_sync_internals.png\n');