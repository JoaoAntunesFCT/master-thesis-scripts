%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    02-2026 (mm-yyyy)
% Module Name:    gmsk_psd_multi_bt
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB (Communications Toolbox)
% Description:    Algorithm-exploration script (see "Preparation" folder
%                 name): plots the power spectral density of GMSK for
%                 several bandwidth-time (BT) products, normalized to bit
%                 rate, to compare spectral containment. BT = 0.5 is
%                 highlighted as the value chosen for TREX1 Gen 1.
%
% Dependencies:   Communications Toolbox (comm.GMSKModulator, comm.MSKModulator)
%
%////////////////////////////////////////////////////////////////////////////////
%% GMSK Power Spectral Density (PSD) Comparison
clc; clear; close all;

%Parameters
numBits = 10000;             
sps = 32;                    % Samples per Symbol
Rb = 1e3;                    % Bit rate (ex: 1 kbps) - just for scale 
Fs = Rb * sps;               % Sampling frequency
BT_values = [0.2, 0.3, 0.5, 0.7, 100]; %100 represents MSK (no gaussian filter)
colors = lines(length(BT_values)); %different colours

%Setup Plot
figure('Name', 'GMSK PSD Comparison', 'Color', 'w');
hold on;
grid on;
legend_str = {};

%Simulation
for i = 1:length(BT_values)
    bt = BT_values(i);
    
    % 1. Modulate
    if bt >= 10
        gmskMod = comm.MSKModulator('BitInput', true, 'SamplesPerSymbol', sps);
        legend_name = 'MSK (BT \approx \infty)';
    else
        gmskMod = comm.GMSKModulator(...
            'BitInput', true, ...
            'BandwidthTimeProduct', bt, ...
            'SamplesPerSymbol', sps);
        legend_name = ['BT = ' num2str(bt)];
    end
    
    data = randi([0 1], numBits, 1);
    modSignal = gmskMod(data);
    
    %Calculate PSD using Welch's Method (averaged periodogram)
    %window length adjusts resolution vs noise variance
    [pxx, f] = pwelch(modSignal, 500, 250, 1024, Fs, 'centered');
    
    %Normalize Frequency to Bit Rate (f / Rb) for standard comparison
    f_norm = f / Rb;
    
    %Normalize Power (Max = 0 dB)
    pxx_db = 10*log10(pxx / max(pxx));
    
    %Plotting
    if bt == 0.5
        %highlight BT = 0.5
        p = plot(f_norm, pxx_db, 'LineWidth', 2.5, 'Color', 'r'); 
        legend_name = [legend_name ' (TREX1 Gen 1)'];
    else
        p = plot(f_norm, pxx_db, 'LineWidth', 1.0, 'Color', colors(i,:));
    end
    
    legend_str{end+1} = legend_name;
end

%Formatting
title('Power Spectral Density (PSD) of GMSK');
xlabel('Normalized Frequency (f / R_b)');
ylabel('Power / Frequency (dB)');
xlim([-2.5 2.5]); 
ylim([-60 0]); 
legend(legend_str);