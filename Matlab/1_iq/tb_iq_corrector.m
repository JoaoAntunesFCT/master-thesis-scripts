%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    tb_iq_corrector
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Bit-accurate testbench for iq_corrector_model.m, the
%                 algorithmic reference model that the iq_corrector_ll_lms.sv
%                 RTL was later developed from. Synthesizes a clean tone,
%                 runs it through a software imbalance injector whose
%                 DDS/VIO stimulus approach was later carried into the RTL
%                 top-level tester, feeds the result into the corrector,
%                 and plots before/after I-Q waveforms plus adaptive-weight
%                 convergence.
%
% Dependencies:   iq_corrector_model.m
%
%////////////////////////////////////////////////////////////////////////////////
%% tb_iq_corrector.m
%  Bit-accurate testbench for the Log-Log LMS IQ-imbalance corrector.
%  Produces ONE figure: I/Q constellation before vs after correction.
%
%  The DDS tone + 3-stage imbalance injector + DUT structure below was
%  later carried into fpga_top_tester.sv's RTL testbench.
%  Run in MATLAB or Octave:  >> tb_iq_corrector
%
%  IMPORTANT - calibration length:
%    The corrector only works once the adaptive weights grow large
%    (w_gain must reach ~1e8-1e9 because of the >>>30 scaling). That growth
%    happens during phase-0 calibration at the fast step size. On the FPGA
%    CALIB_CYCLES_P0 = 2,000,000, which is plenty. Here it is set to 500,000
%    so the run finishes in ~1-2 min while still fully converging. Set it
%    back to 2000000 (and N accordingly) for a cycle-exact HW match.

clear; clc; close all;

%% ------------------- VIO control values -------------------
alpha_vio        = 1300;    % Q gain factor  (1024 = unity)
beta_vio         = 150;     % I->Q cross term (phase-like imbalance)
dc_i_vio         = 8;       % DC offset on I
dc_q_vio         = -6;      % DC offset on Q
alpha_drift_vio  = 1900;    % (only used if drift is enabled below)
inject_delay_vio = 1e9;     % drift DISABLED (never reached within N)

%% ------------------- corrector parameters -----------------
params = struct( ...
    'BIT_WIDTH',10, ...
    'CALIB_SHIFT_P0',3,'CALIB_SHIFT_P1',6,'CALIB_SHIFT_P2',9,'TRACK_SHIFT',12, ...
    'CALIB_CYCLES_P0',500000,'CALIB_CYCLES_P1',0,'CALIB_CYCLES_P2',0, ...
    'DDS_PERIOD',1000,'FAULT_THR',500,'FAULT_CONFIRM',3, ...
    'FAULT_COOLDOWN',2000000,'FAULT_BLANKING',2000,'SIGNAL_MIN',64);

%% ------------------- simulation setup ---------------------
N       = 520000;          % total clock cycles (must exceed calibration)
Fs      = 100e6;           % 100 MHz clk
f0      = 2.5e6;           % test tone
A       = 400;             % tone amplitude (< 511 full scale)
rst_len = 5;

n  = (0:N-1).';
w0 = 2*pi*f0/Fs;
dds_i_ideal = arrayfun(@(x) iq_corrector_model.ws(round(A*cos(w0*x)),10), n);
dds_q_ideal = arrayfun(@(x) iq_corrector_model.ws(round(A*sin(w0*x)),10), n);

%% ------------------- injector registers -------------------
inject_counter=0; injected=false; inject_now=0; alpha_active=alpha_vio;
dc_i_reg=0; dc_q_reg=0;
q_mult_alpha=0; i_mult_beta=0; i_imb_delay=0; q_sum_stage=0; i_imb=0; q_imb=0;

dut = iq_corrector_model(params);

ashr = @(x,k) floor(x/2^k);
ws   = @(x,k) iq_corrector_model.ws(x,k);

%% ------------------- logs (only what the plot needs) ------
log_i_imb = zeros(N,1); log_q_imb = zeros(N,1);
log_i_cor = zeros(N,1); log_q_cor = zeros(N,1);
log_wp    = zeros(N,1); log_wg    = zeros(N,1);   % adaptive weights

fprintf('Running %d cycles (calibration = %d)... this can take ~1-2 min.\n', ...
        N, params.CALIB_CYCLES_P0);

%% ------------------- clocked loop -------------------------
for k = 1:N
    rst_n = (k > rst_len);
    dds_i = dds_i_ideal(k); dds_q = dds_q_ideal(k);

    % injection sequencer: starts with a fixed imbalance (alpha_vio/beta_vio/
    % dc_*_vio) and, if inject_delay_vio is ever reached, switches to
    % alpha_drift_vio to simulate a mid-run drift. inject_delay_vio is set
    % to 1e9 above, i.e. far beyond N, so drift injection never actually
    % fires in this run - only the fixed imbalance is exercised.
    if ~rst_n
        next_inject_counter=0; next_injected=false; next_inject_now=0; next_alpha_active=alpha_vio;
    else
        next_inject_now=0; next_inject_counter=inject_counter; next_injected=injected; next_alpha_active=alpha_active;
        if ~injected
            if inject_counter==inject_delay_vio
                next_injected=true; next_inject_now=1; next_alpha_active=alpha_drift_vio;
            else
                next_inject_counter=inject_counter+1; next_alpha_active=alpha_vio;
            end
        else
            next_alpha_active=alpha_drift_vio;
        end
    end

    next_dc_i_reg = ws(dc_i_vio,10);
    next_dc_q_reg = ws(dc_q_vio,10);

    % imbalance injector pipeline: deliberately distorts the clean DDS tone
    % (unequal I/Q gain via alpha_active, a phase-like I->Q cross term via
    % beta_vio, and DC offsets) so the corrector under test has real
    % imbalance to remove. This injector stage's approach was later
    % carried into fpga_top_tester.sv's RTL testbench.
    next_q_mult_alpha = ws( ashr(dds_q,1)*alpha_active, 26);
    next_i_mult_beta = ws( ashr(dds_i,1)*beta_vio    , 26);
    next_i_imb_delay = ws( ashr(dds_i,1)+dc_i_reg    , 10);
    next_q_sum_stage = ws( q_mult_alpha+i_mult_beta, 26);
    next_i_imb  = i_imb_delay;
    next_q_imb  = ws( ashr(q_sum_stage,10)+dc_q_reg, 10);

    % DUT
    [io,qo] = dut.step(i_imb, q_imb, rst_n);

    log_i_imb(k)=i_imb; log_q_imb(k)=q_imb;
    log_i_cor(k)=io;    log_q_cor(k)=qo;
    log_wp(k)=dut.w_phase_reg; log_wg(k)=dut.w_gain_reg;

    % commit injector regs
    inject_counter=next_inject_counter; injected=next_injected; inject_now=next_inject_now; alpha_active=next_alpha_active;
    dc_i_reg=next_dc_i_reg; dc_q_reg=next_dc_q_reg;
    q_mult_alpha=next_q_mult_alpha; i_mult_beta=next_i_mult_beta; i_imb_delay=next_i_imb_delay;
    q_sum_stage=next_q_sum_stage; i_imb=next_i_imb; q_imb=next_q_imb;
end

%% ------------------- the one plot -------------------------
% Time-domain I (cos) and Q (sin) waveforms, before vs after correction.
Tperiod = round(Fs/f0);            % samples per tone period (=40 here)
span    = 4*Tperiod;               % show ~4 periods

w_before = 2000        : 2000+span-1;   % early: imbalanced input
w_after  = N-span+1    : N;             % end:   converged output

figure('Name','I/Q waveforms before / after correction','Color','w','Position',[120 120 1000 560]);

subplot(2,1,1);
plot(0:span-1, log_i_imb(w_before),'-o','MarkerSize',3); hold on;
plot(0:span-1, log_q_imb(w_before),'-o','MarkerSize',3);
grid on; xlabel('sample'); ylabel('amplitude (LSB)');
legend('I','Q','Location','northeast');
title('Before correction  (imbalanced: unequal amplitude / not 90\circ apart)');

subplot(2,1,2);
plot(0:span-1, log_i_cor(w_after),'-o','MarkerSize',3); hold on;
plot(0:span-1, log_q_cor(w_after),'-o','MarkerSize',3);
grid on; xlabel('sample'); ylabel('amplitude (LSB)');
legend('I','Q','Location','northeast');
title('After correction  (equal amplitude, quadrature restored)');

% shared y-scale for a fair comparison
yl = max([abs(log_i_imb(w_before)); abs(log_q_imb(w_before)); ...
          abs(log_i_cor(w_after));  abs(log_q_cor(w_after))]) * 1.1;
subplot(2,1,1); ylim([-yl yl]);
subplot(2,1,2); ylim([-yl yl]);

%% ------------------- weight convergence -------------------
figure('Name','Adaptive weight convergence','Color','w','Position',[140 140 1000 560]);

subplot(2,1,1);
plot(0:N-1, log_wp); grid on;
xlabel('cycle'); ylabel('w\_phase');
title('Phase weight convergence');

subplot(2,1,2);
plot(0:N-1, log_wg); grid on;
xlabel('cycle'); ylabel('w\_gain');
title('Gain weight convergence');