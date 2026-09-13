%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    rx_chain_testbench
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Testbench for rx_chain_model.m. Builds an imbalance-
%                 injected calibration-tone stimulus and runs it through
%                 BOTH the 100 MHz FPGA baseline and the 10 MHz ASIC
%                 synthesis configuration, rendering the same 5-figure ILA-
%                 style layout for each. See the detailed header below for
%                 exactly how the two configurations differ and why.
%
% Dependencies:   rx_chain_model.m
%
%////////////////////////////////////////////////////////////////////////////////
function rx_chain_testbench()
%rx_chain_testbench  Testbench for rx_chain_model.m. Just run it (F5, or
%   type rx_chain_testbench at the prompt) - it takes no arguments.
%
% Builds a continuous-tone, I/Q-imbalance-injected stimulus -- the same
% calibration-bench approach later carried into the fpga_merged_test_wrapper.v
% RTL testbench (a DDS_PERIOD-based IF tone with injected gain/phase/DC
% imbalance - alpha/beta/dc_i/dc_q, the same knobs as the wrapper's
% imbalance injector) -- runs it through
% rx_chain_model, and renders the SAME 5-figure layout used for the
% Vivado ILA captures (generate_graphs6.py), with matching titles, panel
% groupings, and colours, so the two can be compared side by side.
%
% This script now runs TWO independent configurations, back to back:
%
%   1. FPGA / 100 MHz baseline (nexys_a7.xdc, decimation_rate=12,
%      DDS_PERIOD=10) - this is the configuration validated against real
%      hardware ILA captures throughout bring-up. Output files:
%         matlab_1_ddc.png ... matlab_5_derot.png
%      (unchanged filenames/content vs. the original single-config
%      version of this script.)
%
%   2. ASIC / 10 MHz synthesis target (baseband.sdc, decimation_rate=10,
%      DDS_PERIOD=10, calibration cycle counts /10 to keep the same
%      wall-clock calibration duration at 1/10th the clock rate) - the
%      configuration used for the Design Compiler / sky130 / ihp130
%      synthesis runs. Output files:
%         matlab_10mhz_1_ddc.png ... matlab_10mhz_5_derot.png
%
% These are two DIFFERENT, independently-configured runs of the same
% algorithm, not a "before/after" of the same one - see rx_chain_model.m
% and the two config-builder functions below for exactly which parameters
% differ and why. The 100 MHz outputs are unchanged from the earlier
% single-config version of this script; the 10 MHz outputs are additive,
% intended to sit in the thesis's digital-synthesis section.
%
% Usage:  just run this script. All 10 figures are both displayed and
% saved as PNGs in the current folder.
%
% TUNING NOTES (from validating the 100 MHz run against the reference
% ILA captures - the same notes apply proportionally to the 10 MHz run):
%   - The CFO estimator only produces its first angle estimate after
%     AGC_WINDOW (100) + PREAMBLE_SYMS*SPS (512) valid samples have
%     accumulated - with decim_rate=12 (100 MHz config) that is roughly
%     7300 raw samples, so in an 8192-sample run (matching a typical ILA
%     capture depth) the "CFO Derotator Internals" figure will be mostly
%     flat until near the end. Increase N below to see it settle into
%     steady operation. The 10 MHz config's decim_rate=10 shifts this
%     slightly but the same effect applies.
%   - w_phase_reg/w_gain_reg convergence speed and whether they oscillate
%     at equilibrium or drift monotonically toward it depends strongly on
%     alpha/beta/dc_i/dc_q below relative to calib_shift_p0 (the coarse
%     step size). If your real bench uses different imbalance injection
%     values, set them here to match for a closer comparison - the
%     defaults below are illustrative, not measured from real hardware.
%   - IMPORTANT CAVEAT: unlike the 100 MHz/decimation-12 configuration,
%     which is validated against real hardware ILA captures throughout
%     this bring-up, the 10 MHz/decimation-10 ASIC configuration has NOT
%     been hardware-validated - it is architecturally the same design but
%     a numerically different configuration. Treat its output as a
%     simulation cross-check for the synthesis run, not as independently
%     hardware-proven the way the 100 MHz figures are.

clear; clc; close all;

N   = 8192;     % same length as a typical ILA capture, used for both runs
amp = 200;      % raw ADC amplitude (matches the ~200-count front-end seen
                % in the reference capture's "Front-end I/Q" panel)

% -- I/Q imbalance injection (the same alpha/beta/dc_i/dc_q approach later
%    carried into fpga_merged_test_wrapper.v's RTL imbalance injector). Same
%    imbalance used for both runs so the two are a fair comparison of
%    "same analog impairment, different clock/decimation configuration". --
imb.alpha = 1.05;    % gain imbalance
imb.beta  = 0.03;    % phase/cross-coupling imbalance
imb.dc_i  = 3;        % DC offset, I
imb.dc_q  = -2;       % DC offset, Q

%% =======================================================================
%  RUN 1 - FPGA / 100 MHz baseline (unchanged from the original script)
%% =======================================================================
cfg_100 = cfg_100mhz();
run_and_plot(cfg_100, imb, N, amp, '', 'MATLAB Model (100 MHz FPGA baseline) - ');

%% =======================================================================
%  RUN 2 - ASIC / 10 MHz synthesis target
%% =======================================================================
cfg_10 = cfg_10mhz();
run_and_plot(cfg_10, imb, N, amp, '10mhz_', 'MATLAB Model (10 MHz ASIC target) - ');

fprintf('\nAll done.\n');
fprintf('  100 MHz figures: matlab_1_ddc.png ... matlab_5_derot.png\n');
fprintf('  10 MHz figures : matlab_10mhz_1_ddc.png ... matlab_10mhz_5_derot.png\n');
end


%% =========================================================================
%  Local functions
%% =========================================================================
function cfg = cfg_100mhz()
%CFG_100MHZ  FPGA / Vivado baseline: nexys_a7.xdc, 100 MHz, decimation=12.
%   This is rx_chain_model()'s own default config, used as-is - it is the
%   configuration validated against real hardware throughout bring-up.
    cfg = rx_chain_model();
    cfg.fs = 100e6;
end

function cfg = cfg_10mhz()
%CFG_10MHZ  ASIC / Design Compiler target: baseband.sdc, 10 MHz,
%   decimation=10. Per synth_trex1_multicorner.tcl's own comments:
%     - clock: 100 ns period (10 MHz), vs. the FPGA's 10 ns (100 MHz)
%     - decimation_rate: 12 -> 10
%     - DDS_PERIOD: reduced to 10 for this run (see caveat below)
%     - calibration cycle counts: /10, so CALIB_CYCLES_P0 keeps the same
%       WALL-CLOCK calibration duration (200000 cycles @ 100 MHz = 2 ms;
%       20000 cycles @ 10 MHz = 2 ms too) rather than taking 10x longer
%       in real time at the slower clock.
%
%   CAVEAT: synth_trex1_multicorner.tcl's comment describes this run as
%   changing "DDS_PERIOD 91->10". The 100 MHz FPGA RTL we verified
%   directly (trex1_rx_frontend_top.v's instantiation of
%   iq_corrector_ll_lms) uses DDS_PERIOD=10, not 91, so that comment's
%   "before" value does not match the FPGA baseline as built. This
%   config uses the explicitly-stated TARGET value (10) for the 10 MHz
%   run, matching the .tcl comment's stated destination; the discrepancy
%   in its stated starting point is flagged here rather than silently
%   resolved, since its origin (an earlier draft value? a different
%   parameterisation?) was not confirmed against the project files.
    cfg = rx_chain_model();
    cfg.fs           = 10e6;
    cfg.decim_rate   = 10;      % 12 -> 10, per baseband.sdc / .tcl
    cfg.dds_period   = 10;      % per .tcl's stated target for this run
    cfg.calib_cycles_p0 = round(cfg.calib_cycles_p0 / 10);
    cfg.calib_cycles_p1 = round(cfg.calib_cycles_p1 / 10);
    cfg.calib_cycles_p2 = round(cfg.calib_cycles_p2 / 10);
end

function run_and_plot(cfg, imb, N, amp, file_prefix, title_prefix)
%RUN_AND_PLOT  Build the stimulus for CFG, run rx_chain_model, and render
%   the 5-figure layout, saving PNGs named matlab_<file_prefix>N_name.png.
    fs      = cfg.fs;
    f_if    = fs / cfg.dds_period;   % calibration tone frequency
    f_cfo   = -fs * 3e-4;            % deliberate small residual offset
                                      % (scaled with fs so both runs leave
                                      % a comparable fraction-of-fs CFO for
                                      % the derotator/STR to work with)
    cfg.fcw = round(mod((f_if - f_cfo)/fs * 2^24, 2^24));

    n = (0:N-1)';
    i_ideal = amp*cos(2*pi*f_if/fs*n);
    q_ideal = amp*sin(2*pi*f_if/fs*n);

    raw_i = round(i_ideal + imb.dc_i);
    raw_q = round(imb.alpha*q_ideal + imb.beta*i_ideal + imb.dc_q);

    adc_max = 2^(cfg.bit_width-1) - 1;
    raw_i = max(min(raw_i, adc_max), -adc_max-1);
    raw_q = max(min(raw_q, adc_max), -adc_max-1);

    fprintf('\n[%s] Running rx_chain_model over %d samples (fs=%.0f Hz, decim=%d)...\n', ...
            strtrim(title_prefix), N, fs, cfg.decim_rate);
    tic; probe = rx_chain_model(raw_i, raw_q, cfg); toc

    x = (0:N-1)';   % "Sample in Window", same x-axis convention as the ILA plots

    % -- Plot styling (mirrors generate_graphs6.py's palette) --
    BLUE=[0.165 0.471 0.839]; ORANGE=[0.922 0.408 0.204]; GREEN=[0.106 0.686 0.478];
    RED=[0.890 0.286 0.282]; PURPLE=[0.424 0.294 0.847]; TEAL=[0.059 0.608 0.557];
    DIGC=[0.227 0.227 0.220];
    set(0, 'DefaultAxesFontSize', 9, 'DefaultAxesColor', [0.988 0.988 0.984]);

    if exist('sgtitle', 'builtin') || exist('sgtitle', 'file')
        capfig = @(t) sgtitle(t, 'FontWeight','bold', 'FontSize', 13);
    else
        % Octave compatibility: sgtitle was added in MATLAB R2018b and has
        % no built-in Octave equivalent - fall back to an annotation.
        capfig = @(t) annotation('textbox', [0 0.955 1 0.04], 'String', t, ...
                      'EdgeColor','none', 'HorizontalAlignment','center', ...
                      'FontWeight','bold', 'FontSize', 13);
    end

    % ---- Figure 1 - DDC Front-End ----
    figure('Color','w','Position',[50 50 1250 850]);
    subplot(5,1,1); plot(x, probe.i_imb, 'Color', BLUE); hold on;
                    plot(x, probe.q_imb, 'Color', ORANGE);
                    ylabel('Front-end I/Q [9:0]'); legend('i\_imb','q\_imb','Location','eastoutside');
    subplot(5,1,2); plot(x, probe.dbg_iq_i_out, 'Color', BLUE); hold on;
                    plot(x, probe.dbg_iq_q_out, 'Color', ORANGE);
                    ylabel('IQ-corrected [9:0]'); legend('i\_out','q\_out','Location','eastoutside');
    subplot(5,1,3); plot(x, probe.dbg_mixer_i, 'Color', BLUE); hold on;
                    plot(x, probe.dbg_mixer_q, 'Color', ORANGE);
                    ylabel('Mixer out [22:0]'); legend('mixer\_i','mixer\_q','Location','eastoutside');
    subplot(5,1,4); plot(x, probe.dbg_cic_i, 'Color', BLUE); hold on;
                    plot(x, probe.dbg_cic_q, 'Color', ORANGE);
                    ylabel('CIC out [23:0]'); legend('cic\_i','cic\_q','Location','eastoutside');
    subplot(5,1,5); stairs(x, double(probe.baseband_valid_out), 'Color', TEAL);
                    ylim([-0.4 1.4]); yticks([0 1]); ylabel('baseband\_valid\_out');
                    xlabel('Sample in Window');
    capfig([title_prefix 'DDC Front-End']);
    print(gcf, sprintf('matlab_%s1_ddc.png', file_prefix), '-dpng', '-r150');

    % ---- Figure 2 - Baseband, Sync & GMSK Demod ----
    figure('Color','w','Position',[50 50 1250 850]);
    subplot(6,1,1); plot(x, probe.i_out_baseband, 'Color', BLUE); hold on;
                    plot(x, probe.q_out_baseband, 'Color', ORANGE);
                    ylabel('Baseband [23:0]'); legend('i\_out','q\_out','Location','eastoutside');
    subplot(6,1,2); stairs(x, probe.sync_i_out, 'Color', BLUE); hold on;
                    stairs(x, probe.sync_q_out, 'Color', ORANGE);
                    ylabel('Sync/derotate [11:0]'); legend('sync\_i','sync\_q','Location','eastoutside');
    subplot(6,1,3); stairs(x, probe.dbg_freq_dev, 'Color', PURPLE); hold on;
                    plot([x(1) x(end)], [0 0], '--', 'Color', RED);   % zero-slicer line
                    ylabel('GMSK freq\_dev [24:0]');
    subplot(6,1,4); stairs(x, double(probe.sync_valid_out), 'Color', TEAL);
                    ylim([-0.4 1.4]); yticks([0 1]); ylabel('sync\_valid\_out');
    subplot(6,1,5); stairs(x, double(probe.rx_bit_out), 'Color', DIGC);
                    ylim([-0.4 1.4]); yticks([0 1]); ylabel('rx\_bit\_out');
    subplot(6,1,6); stairs(x, double(probe.rx_bit_valid), 'Color', GREEN);
                    ylim([-0.4 1.4]); yticks([0 1]); ylabel('rx\_bit\_valid');
                    xlabel('Sample in Window');
    capfig([title_prefix 'Baseband, Sync & GMSK Demod']);
    print(gcf, sprintf('matlab_%s2_demod.png', file_prefix), '-dpng', '-r150');

    % ---- Figure 3 - Packet Engine & Control ----
    figure('Color','w','Position',[50 50 1250 950]);
    subplot(6,1,1); stairs(x, probe.dbg_bit_count, 'Color', TEAL);
                    ylabel('bit\_count [8:0]');
    subplot(6,1,2); stairs(x, probe.payload_preview, 'Color', DIGC);
                    ylabel('payload\_preview [31:0]');
    subplot(6,1,3); stairs(x, probe.dbg_crc_syndrome, 'Color', BLUE);
                    ylabel('crc\_syndrome [15:0]');
    subplot(6,1,4); stairs(x, probe.dbg_error_idx, 'Color', BLUE);
                    ylabel('error\_idx [8:0]');
    subplot(6,1,5); stairs(x, double(probe.dbg_pe_enable), 'Color', DIGC); hold on;
                    stairs(x, double(probe.packet_error_out), 'Color', RED);
                    ylim([-0.4 1.4]); yticks([0 1]); ylabel('pe\_enable / packet\_error');
                    legend('pe\_enable','packet\_error\_out','Location','eastoutside');
    subplot(6,1,6); stairs(x, double(probe.fault_detected), 'Color', RED);
                    ylim([-0.4 1.4]); yticks([0 1]); ylabel('fault\_detected');
                    xlabel('Sample in Window');
    capfig([title_prefix 'Packet Engine & Control']);
    print(gcf, sprintf('matlab_%s3_packet.png', file_prefix), '-dpng', '-r150');

    % ---- Figure 4 - IQ Corrector: LMS Weights & Fault Detector ----
    figure('Color','w','Position',[50 50 1250 850]);
    subplot(6,1,1); plot(x, probe.w_phase_reg, 'Color', PURPLE); ylabel('w\_phase\_reg [31:0]');
    subplot(6,1,2); plot(x, probe.w_gain_reg, 'Color', TEAL);    ylabel('w\_gain\_reg [33:0]');
    subplot(6,1,3); stairs(x, probe.calib_phase, 'Color', DIGC); ylabel('calib\_phase [1:0]');
    subplot(6,1,4); stairs(x, probe.fault_acc, 'Color', RED);    ylabel('fault\_acc [31:0]');
    subplot(6,1,5); stairs(x, probe.fault_period_sum, 'Color', ORANGE); ylabel('fault\_period\_sum [31:0]');
    subplot(6,1,6); stairs(x, double(probe.fault_detected), 'Color', RED);
                    ylim([-0.4 1.4]); yticks([0 1]); ylabel('fault\_detected');
                    xlabel('Sample in Window');
    capfig([title_prefix 'IQ Corrector - LMS Weights & Fault Detector']);
    print(gcf, sprintf('matlab_%s4_iqcorr.png', file_prefix), '-dpng', '-r150');

    % ---- Figure 5 - CFO Derotator Internals ----
    figure('Color','w','Position',[50 50 1250 750]);
    subplot(4,1,1); plot(x, probe.dbg_raw_angle, 'Color', PURPLE); ylabel('raw\_angle [16:0]');
    subplot(4,1,2); plot(x, probe.cir, 'Color', BLUE); hold on;
                    plot(x, probe.ciq, 'Color', ORANGE);
                    ylabel('derot I/Q taps [23:0]'); legend('cir','ciq','Location','eastoutside');
    subplot(4,1,3); plot(x, probe.phi, 'Color', TEAL); ylabel('phi [15:0]');
    subplot(4,1,4); plot(x, probe.dphi, 'Color', GREEN); ylabel('dphi [16:0]');
                    xlabel('Sample in Window');
    capfig([title_prefix 'CFO Derotator Internals']);
    print(gcf, sprintf('matlab_%s5_derot.png', file_prefix), '-dpng', '-r150');

    % ---- Quick numeric summary ----
    fprintf('  baseband_valid pulses : %d\n', sum(probe.baseband_valid_out));
    fprintf('  sync_valid pulses     : %d\n', sum(probe.sync_valid_out));
    fprintf('  rx_bit_valid pulses   : %d\n', sum(probe.rx_bit_valid));
    fprintf('  max |mixer|           : %.0f\n', max(abs(probe.dbg_mixer_i)));
    fprintf('  max |cic|             : %.0f\n', max(abs(probe.dbg_cic_i)));
    fprintf('  max |baseband|        : %.0f\n', max(abs(probe.i_out_baseband)));
    fprintf('  w_phase_reg range     : [%.0f, %.0f]\n', min(probe.w_phase_reg), max(probe.w_phase_reg));
    fprintf('  w_gain_reg range      : [%.0f, %.0f]\n', min(probe.w_gain_reg), max(probe.w_gain_reg));
    fprintf('  any packet_error_out  : %d\n', any(probe.packet_error_out));
end