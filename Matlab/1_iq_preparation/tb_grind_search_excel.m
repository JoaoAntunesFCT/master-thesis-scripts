%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    02-2026 (mm-yyyy)
% Module Name:    tb_grind_search_excel
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Grid-search driver for iq_corrector_universal.m. Sweeps
%                 SNR, drift rate, calibration length and calib/track shift
%                 combinations for the SS-LMS and LL-LMS algorithms, runs
%                 NUM_RUNS Monte-Carlo trials per combination, and exports
%                 the averaged convergence/jitter/lock-rate statistics to
%                 an Excel file for later plotting (visualize_results.m).
%
% Dependencies:   iq_corrector_universal.m
%
% Revision:
% Additional Comments:
%   This is a long-running batch job - the "Dummy run" below times a single
%   simulation first so the estimated total runtime can be printed before
%   committing to the full sweep.
%
%////////////////////////////////////////////////////////////////////////////////
%% tb_grind_search_excel.m
clc; clear; close all;

%Define sweep variables
N_SAMPLES = 100000;

%35dB - Math: 10^(-35/20) = 0.01778
THRESH_LIST = 0.0178; 

%Sensitivity Context: Low SNR focus
SNR_LIST    = [10, 20, 30];    

%Drift Scenarios
DRIFT_LIST  = [10, 50];  

%Tuning: Fast Settling (<200us)
SETTLING_FACTORS = [2, 3, 4];
CALIB_SHIFTS = [5, 6];
TRACK_SHIFTS = [18, 19];

%Algorithms
ALGO_NAMES  = {'SS-LMS','LL-LMS'};

FS = 12e6;
NUM_RUNS = 500; 

fprintf('Estimating total time with Low-Power Focus...\n');
tic;

%Pre-Calculate Batches
valid_shift_combos = 0;
for c = CALIB_SHIFTS
    valid_tracks = TRACK_SHIFTS(TRACK_SHIFTS > c);
    valid_shift_combos = valid_shift_combos + length(valid_tracks);
end

total_sim_batches = length(THRESH_LIST) * length(SNR_LIST) * ...
                    length(DRIFT_LIST) * length(SETTLING_FACTORS) * ...
                    valid_shift_combos * length(ALGO_NAMES);

%Dummy run - times one simulation so we can estimate total sweep runtime
%before committing to it (see fprintf below).
temp_configs = get_shift_configs(8, 12);
p.N = N_SAMPLES; p.Fs = FS; p.SNR_dB = 20; p.drift_freq = 10; 
p.calibration_cycles = 1000; p.target_thresh = 0.01;
iq_corrector_universal('LL-LMS', p, temp_configs('LL-LMS')); 

one_run_time = toc;
total_runs_math = total_sim_batches * NUM_RUNS;
estimated_hours = (total_runs_math * one_run_time) / 3600;

fprintf('Single Run: %.4fs | Total Runs: %d\n', one_run_time, total_runs_math);
fprintf('ESTIMATED TIME: %.2f HOURS\n', estimated_hours);
fprintf('----------------------------------------------------------\n');
fprintf('  STARTING GRID SEARCH\n');
fprintf('==========================================================\n');

data_rows = {};
row_idx = 0;
start_time = tic;
batch_counter = 0;

%Main grid loop
for th_idx = 1:length(THRESH_LIST)
    current_thresh = THRESH_LIST(th_idx);
    for s_idx = 1:length(SNR_LIST)
        current_snr = SNR_LIST(s_idx);
        for d_idx = 1:length(DRIFT_LIST)
            current_drift = DRIFT_LIST(d_idx);
            
            for cs_idx = 1:length(CALIB_SHIFTS)
                calib_shift = CALIB_SHIFTS(cs_idx);
                cycles_for_this_shift = ceil(SETTLING_FACTORS * (2^calib_shift));
                
                for c_idx = 1:length(cycles_for_this_shift)
                    current_cycles = cycles_for_this_shift(c_idx);
                    valid_tracks = TRACK_SHIFTS(TRACK_SHIFTS > calib_shift);
                    
                    for ts_idx = 1:length(valid_tracks)
                        track_shift = valid_tracks(ts_idx);
                        configs = get_shift_configs(calib_shift, track_shift);
                        
                        for a_idx = 1:length(ALGO_NAMES)
                            algo_name = ALGO_NAMES{a_idx};
                            batch_counter = batch_counter + 1;
                            
                            if mod(batch_counter, 1) == 0
                               fprintf('Batch %d/%d | %s | Calib %d -> Track %d\n', ...
                                   batch_counter, total_sim_batches, algo_name, calib_shift, track_shift);
                            end
                            
                            %Simulation
                            temp_jit = zeros(NUM_RUNS, 1);
                            temp_lok = zeros(NUM_RUNS, 1);
                            valid_cnt = 0;
                            
                            for r = 1:NUM_RUNS
                                rng(r, 'twister'); % seed per run: repeatable across sweeps
                                p.N = N_SAMPLES; p.Fs = FS;
                                p.SNR_dB = current_snr; p.drift_freq = current_drift;  
                                p.calibration_cycles = current_cycles; 
                                p.target_thresh = current_thresh; 
                                
                                [t_conv, jitter, ~] = iq_corrector_universal(algo_name, p, configs(algo_name));
                                
                                if ~isnan(t_conv)
                                    valid_cnt = valid_cnt + 1;
                                    temp_lok(valid_cnt) = t_conv;
                                    temp_jit(valid_cnt) = jitter;
                                end
                            end
                            
                            %Stats
                            if valid_cnt == 0
                                avg_lock = NaN; std_lock = NaN; avg_jit = NaN; 
                                lock_rate = 0; pass_rate = 0;
                            else
                                avg_lock = mean(temp_lok(1:valid_cnt));
                                std_lock = std(temp_lok(1:valid_cnt));
                                valid_jitters = temp_jit(1:valid_cnt); 
                                avg_jit  = mean(valid_jitters);
                                lock_rate = (valid_cnt / NUM_RUNS) * 100;
                                pass_rate = (sum(valid_jitters <= current_thresh) / NUM_RUNS) * 100;
                            end
                            
                            row_idx = row_idx + 1;
                            data_rows(row_idx, :) = { ...
                                algo_name, N_SAMPLES, current_thresh, current_snr, ...
                                current_drift, current_cycles, calib_shift, track_shift, ...
                                avg_lock, std_lock, avg_jit, lock_rate, pass_rate
                            };
                        end 
                    end 
                end 
            end 
        end 
    end 
end 

total_time = toc(start_time);
fprintf('\nGrid Search Complete in %.2f seconds.\n', total_time);

% --- EXPORT ---
VarNames = {'Algorithm', 'N_Samples', 'Target_Thresh', 'SNR_dB', 'Drift_Hz', 'CalibCycles', ...
            'Shift_Calib', 'Shift_Track', 'LockTime_Mean_us', 'LockTime_Std_us', ...
            'Jitter_RMS','LockRate_Pct', 'StrictSuccess_Pct'};
ResultsTable = cell2table(data_rows, 'VariableNames', VarNames);
filename = 'IQ_Corrector_LowPower_Results_v3.xlsx';
save('safety_backup_lp.mat', 'ResultsTable', 'data_rows'); 
try
    writetable(ResultsTable, filename);
    fprintf('SUCCESS: Saved to "%s"\n', filename);
catch ME
    fprintf('ERROR Writing Excel: %s\n', ME.message);
end

% --- CONFIG HELPER (Cleaned) ---
% Converts a calib/track "shift" (as used in the RTL, e.g. CALIB_SHIFT_P0)
% into the equivalent floating-point step size mu = 2^-shift, and packages
% it identically for every algorithm so the caller can index by name.
function configs = get_shift_configs(c_shift, t_shift)
    configs = containers.Map();
    mu_c = 2^(-c_shift);
    mu_t = 2^(-t_shift);
    c = struct(); c.mu_calib = mu_c; c.mu_track = mu_t;

    configs('SE-LMS') = c;
    configs('SS-LMS') = c;
    configs('SD-LMS') = c;
    configs('LL-LMS') = c; 
end