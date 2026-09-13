%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    02-2026 (mm-yyyy)
% Module Name:    visualize_results
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Loads the grid-search results exported by
%                 tb_grind_search_excel.m and produces 5 comparison plots
%                 for LL-LMS vs SS-LMS: convergence-time/IRR Pareto front,
%                 robustness vs SNR, tracking-shift and settling-factor
%                 tuning sensitivity, and calibration-shift impact.
%
% Dependencies:   reads IQ_Corrector_LowPower_Results_v3.xlsx, as produced
%                 by tb_grind_search_excel.m
%
%////////////////////////////////////////////////////////////////////////////////
%% visualize_results.m
clc; clear; close all;

%Load Data
filename = 'IQ_Corrector_LowPower_Results_v3.xlsx';

if ~exist(filename, 'file')
    error('Error: File %s not found in the current folder.', filename);
end

T = readtable(filename);

%Data Cleaning (remove NaNs from failed runs)
T = T(~isnan(T.LockTime_Mean_us) & ~isnan(T.Jitter_RMS), :);

%Convert Jitter to IRR (dB): image-rejection ratio improves as residual
%jitter shrinks, hence the -20*log10 (voltage-ratio dB conversion).
T.IRR_dB = -20 * log10(T.Jitter_RMS);

%Official Colors
cLL = [0 0.4470 0.7410]; % Blue (LL-LMS)
cSS = [0.8500 0.3250 0.0980]; % Orange (SS-LMS)
colors = [cLL; cSS];
algos = {'LL-LMS', 'SS-LMS'};

%% FIGURE 1: PARETO FRONTIER
figure('Name', 'Pareto Frontier', 'Color', 'w', 'Position', [100 100 900 600]);
hold on; grid on;

%Success Zone (>35dB)
patch([10 10000 10000 10], [35 35 100 100], [0.4660 0.6740 0.1880], ...
    'FaceAlpha', 0.15, 'EdgeColor', 'none', 'DisplayName', 'Target Zone (>35 dB)');

%Limit Lines
xline(1000, 'r--', 'Max Latency (1ms)', 'LineWidth', 2);
yline(35, 'g--', 'Min Req (35dB)', 'LineWidth', 2);

%Plot Points
for i = 1:length(algos)
    idx = strcmp(T.Algorithm, algos{i});
    scatter(T.LockTime_Mean_us(idx), T.IRR_dB(idx), 80, colors(i,:), ...
        'filled', 'MarkerFaceAlpha', 0.7, 'DisplayName', algos{i});
end

%Visual Adjustments
set(gca, 'XScale', 'log');
xlabel('Convergence Time (\mus) [Log Scale]');
ylabel('Image Rejection Ratio (dB)');
title('Pareto Frontier: Speed vs. Accuracy (Validated)');
legend('show', 'Location', 'southwest');
ylim([20 60]); 
xlim([10 10000]);

%% FIGURE 2: ROBUSTNESS VS SNR
figure('Name', 'Robustness vs SNR', 'Color', 'w', 'Position', [150 150 800 500]);
hold on; grid on;

% Success Zone
patch([0 40 40 0], [35 35 100 100], [0.4660 0.6740 0.1880], ...
      'FaceAlpha', 0.15, 'EdgeColor', 'none', 'HandleVisibility', 'off');

snr_levels = unique(T.SNR_dB);
for i = 1:length(algos)
    m = zeros(length(snr_levels), 1);
    for s = 1:length(snr_levels)
        mask = strcmp(T.Algorithm, algos{i}) & (T.SNR_dB == snr_levels(s));
        if any(mask), m(s) = max(T.IRR_dB(mask)); else, m(s) = NaN; end
    end
    plot(snr_levels, m, '-o', 'LineWidth', 3, 'MarkerSize', 8, ...
        'Color', colors(i,:), 'DisplayName', algos{i});
end

yline(35, 'g--', 'Min Req (35dB)');
xlabel('Channel SNR (dB)'); ylabel('Max Achievable IRR (dB)');
title('Robustness: Performance vs. Noise');
legend('show', 'Location', 'southeast');
ylim([25 55]);

%% FIGURE 3: TUNING SENSITIVITY
figure('Name', 'Tuning Curve', 'Color', 'w', 'Position', [200 200 800 500]);
hold on; grid on;

yline(35, 'g--', 'Min Req (35dB)', 'LineWidth', 2);
target_snr = 20; 
subset = T(T.SNR_dB == target_snr, :);

for i = 1:length(algos)
    sub = subset(strcmp(subset.Algorithm, algos{i}), :);
    [G, track_shifts] = findgroups(sub.Shift_Track);
    avg_irr = splitapply(@mean, sub.IRR_dB, G);
    
    plot(track_shifts, avg_irr, '-s', 'LineWidth', 2.5, 'MarkerSize', 10, ...
        'Color', colors(i,:), 'DisplayName', algos{i});
end

xlabel('Tracking Shift Parameter'); ylabel('Average IRR (dB)');
title(['Tuning Sensitivity (SNR ' num2str(target_snr) 'dB)']);
xticks([18 19]); xlim([17.5 19.5]);
legend('show', 'Location', 'best');

%% FIGURE 4: SETTLING FACTOR IMPACT
figure('Name', 'Settling Factor', 'Color', 'w', 'Position', [250 250 800 500]);
hold on; grid on;

%Reverse Engineer the Factor: CalibCycles was originally computed as
%ceil(settling_factor * 2^Shift_Calib) in the sweep, so dividing back out
%recovers which settling factor produced each row.
T.Est_Factor = round(T.CalibCycles ./ (2.^T.Shift_Calib));
subset_sf = T(T.SNR_dB == 20 & T.Shift_Track == 18, :);

%Simple Bar Plot
[G, algs_sf, facts] = findgroups(subset_sf.Algorithm, subset_sf.Est_Factor);
times = splitapply(@mean, subset_sf.LockTime_Mean_us, G);

%Separate by algorithm for coloring
for i = 1:length(algos)
    mask = strcmp(algs_sf, algos{i});
    bar(facts(mask) + (i-1.5)*0.2, times(mask), 0.3, 'FaceColor', colors(i,:), ...
        'EdgeColor', 'none', 'DisplayName', algos{i});
end

xlabel('Settling Factor (Time Multiplier)'); ylabel('Lock Time (\mus)');
title('Impact of Settling Factor on Latency');
legend('show'); xticks([2 3 4]);

%% FIGURE 5: CALIBRATION SHIFT IMPACT
figure('Name', 'Calib Shift', 'Color', 'w', 'Position', [300 300 800 500]);
hold on; grid on;

subset_cs = T(T.SNR_dB == 20 & T.Shift_Track == 18, :);
[G, algs_cs, shifts] = findgroups(subset_cs.Algorithm, subset_cs.Shift_Calib);
times = splitapply(@mean, subset_cs.LockTime_Mean_us, G);

for i = 1:length(algos)
    mask = strcmp(algs_cs, algos{i});
    plot(shifts(mask), times(mask), '-o', 'LineWidth', 2, 'MarkerSize', 10, ...
        'Color', colors(i,:), 'DisplayName', algos{i});
end

xlabel('Calibration Shift'); ylabel('Lock Time (\mus)');
title('Impact of Calibration Speed (Shift 5 vs 6)');
xticks([5 6]); xlim([4.5 6.5]);
legend('show');

%Data tips

figures = findobj('Type', 'figure');
for f = 1:length(figures)
    figure(figures(f));
    s = findobj(gca, 'Type', 'Scatter'); 
    
    for i = 1:length(s)
        %Tooltip
        row = dataTipTextRow('Algo', T.Algorithm);
        row2 = dataTipTextRow('Shift Calib', T.Shift_Calib);
        row3 = dataTipTextRow('Shift Track', T.Shift_Track);
        row4 = dataTipTextRow('SNR', T.SNR_dB);
        
        %Add to graph
        s(i).DataTipTemplate.DataTipRows(end+1) = row;
        s(i).DataTipTemplate.DataTipRows(end+1) = row2;
        s(i).DataTipTemplate.DataTipRows(end+1) = row3;
        s(i).DataTipTemplate.DataTipRows(end+1) = row4;
    end
end

fprintf('Final English Plots Generated Successfully.\n');