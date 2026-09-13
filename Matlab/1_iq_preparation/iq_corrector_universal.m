%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    02-2026 (mm-yyyy)
% Module Name:    iq_corrector_universal
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Early-stage algorithm-exploration model (see the
%                 "Preparation" folder name): runs one IQ-imbalance
%                 adaptive-correction algorithm over a simulated noisy,
%                 drifting channel and reports how fast and how well it
%                 converges. Used to compare four hardware-friendly LMS
%                 variants (Sign-Error, Sign-Sign, Sign-Data, Log-Log)
%                 before committing to the Log-Log LMS design
%
% Dependencies:   tb_grind_search_excel.m
%
%////////////////////////////////////////////////////////////////////////////////
function [conv_time_us, jitter_rms, steady_state_error] = iq_corrector_universal(algo_type, sim_params, algo_params)

    %Simulation Parameters
    N = sim_params.N;              
    Fs = sim_params.Fs;              
    drift_freq = sim_params.drift_freq;        
    SNR_dB = sim_params.SNR_dB;
    calibration_cycles = sim_params.calibration_cycles;
    
    %Target Threshold for Lock Calculation (Table 3.1)
    if isfield(sim_params, 'target_thresh')
        target_thresh = sim_params.target_thresh;
    else
        target_thresh = 0.01; %strict threshold (~40dB IRR)
    end
    
    %Algorithm Tuning
    mu_calib = 0; mu_track = 0; 
    
    if isfield(algo_params, 'mu_calib'), mu_calib = algo_params.mu_calib; end
    if isfield(algo_params, 'mu_track'), mu_track = algo_params.mu_track; end

    %Setup
    t = (0:N-1)'/Fs; 
    
    %Simulating bursty/varying conditions
    block_size = 100;
    num_blocks = ceil(N / block_size);
    random_levels = randi([4 9], num_blocks, 1);
    bit_schedule = repelem(random_levels, block_size);
    bit_schedule = bit_schedule(1:N);

    %Errors (Gain & Phase) - Simulating limits from Thesis (Section 3.1)
    phase_error = 5 * (pi/180) * sin(2*pi*drift_freq*t); % +/- 5 deg drift
    gain_error  = 1.0 + 0.06 * cos(2*pi*drift_freq*t);   % +/- 0.5 dB ripple
    total_ideal_error = sqrt((gain_error - 1.0).^2 + phase_error.^2);

    %Signal & Noise
    data_idx = randi([0 3], N, 1);
    ideal_sig = exp(1j * (data_idx * pi/2 + pi/4));
    
    sig_power = 1.0;
    noise_power = sig_power / (10^(SNR_dB/10));
    noise_std = sqrt(noise_power / 2); 
    noise = noise_std * (randn(N, 1) + 1j * randn(N, 1));

    %Quantization Helpers
    quantize = @(val, n_bits) floor(val .* (2.^(n_bits-1))) ./ (2.^(n_bits-1));
    quant_p2 = @(x) sign(x) .* (2.^round(log2(abs(x) + 1e-12))); 

    %Processing Loop
    weight = complex(0,0);
    w_log = zeros(N,1);
    
    for n = 1:N
        is_calib = (n < calibration_cycles);
        current_bits = bit_schedule(n);
        
        %Channel Impairments
        gain_err = gain_error(n); phase_err = phase_error(n);
        i_val = real(ideal_sig(n)); q_val = imag(ideal_sig(n));
        y_raw = complex(i_val + gain_err*q_val*sin(phase_err), gain_err*q_val*cos(phase_err));
        y_noisy = y_raw + noise(n);
        
        y_n = quantize(y_noisy, current_bits);
        
        %Compensation Filter 
        correction = weight * conj(y_n);
        z_n = quantize(y_n + correction, current_bits);
        
        %Blind Error Signal 
        err = z_n^2; 
        regressor = conj(y_n); 

        %Hardware-Friendly Algorithm Selection
        %  All four variants avoid a full complex multiply in the update:
        %  they replace one or both operands of (error * regressor) with
        %  just its sign, or (LL-LMS) with a power-of-two approximation,
        %  since that's what's cheap to implement in the FPGA fabric.
        switch algo_type
            case 'SE-LMS'
                % Thesis Eq 2.11: Sign-Error
                cur_mu = is_calib * mu_calib + (~is_calib) * mu_track;
                s_real = sign(real(err)); s_imag = sign(imag(err));
                sgn_err = complex(s_real, s_imag);
                delta = sgn_err * regressor * cur_mu; 
                weight = weight - delta;
                
            case 'SS-LMS'
                % Thesis Eq 2.12: Sign-Sign
                cur_mu = is_calib * mu_calib + (~is_calib) * mu_track;
                s_real_e = sign(real(err)); s_imag_e = sign(imag(err));
                sgn_err = complex(s_real_e, s_imag_e);
                s_real_x = sign(real(regressor)); s_imag_x = sign(imag(regressor));
                sgn_dat = complex(s_real_x, s_imag_x);
                delta = sgn_err * sgn_dat * cur_mu;
                weight = weight - delta;
                
            case 'SD-LMS'
                % Thesis Eq 2.13: Sign-Data
                cur_mu = is_calib * mu_calib + (~is_calib) * mu_track;
                s_real_x = sign(real(regressor)); s_imag_x = sign(imag(regressor));
                sgn_dat = complex(s_real_x, s_imag_x);
                delta = err * sgn_dat * cur_mu;
                weight = weight - delta;
                
            case 'LL-LMS'
                % Thesis Eq 2.14: Log-Log (Power of Two)
                cur_mu = is_calib * mu_calib + (~is_calib) * mu_track;
                term1 = quant_p2(err * cur_mu); 
                term2 = quant_p2(regressor);
                delta = term1 * term2;
                weight = weight - delta;
                
            otherwise
                error('Unknown or High-Power Algorithm requested.');
        end
        
        %Safety Clamp: cap |weight| at 0.8 so a bad adaptation step can't
        %run the correction weight away to infinity.
        if abs(weight) > 0.8, weight = (weight/abs(weight))*0.8; end
        w_log(n) = weight;
    end

    %Calculate Metrics
    steady_idx = (N - 20000):N;
    tracking_w = abs(w_log(steady_idx));
    tracking_target = total_ideal_error(steady_idx);
    
    jitter_rms = rms(tracking_w - tracking_target);
    steady_state_error = mean(abs(tracking_w - tracking_target));

    diff_error = abs(abs(w_log) - total_ideal_error);
    lock_indices = find(diff_error < target_thresh);

    % "Locked" means the error stays below threshold, not just touches it
    % once - so require the next 50 samples to also stay under a looser
    % (2x) threshold before accepting a candidate lock point.
    valid_lock = -1;
    if ~isempty(lock_indices)
        for k = 1:length(lock_indices)
            idx = lock_indices(k);
            if idx > N - 50, continue; end
            if all(diff_error(idx:idx+50) < target_thresh * 2.0)
                valid_lock = idx;
                break;
            end
        end
    end
        
    if valid_lock > 0
        conv_time_us = (valid_lock / Fs) * 1e6;
    else
        conv_time_us = NaN;
    end
end