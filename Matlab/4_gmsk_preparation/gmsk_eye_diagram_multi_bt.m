%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    02-2026 (mm-yyyy)
% Module Name:    gmsk_eye_diagram_multi_bt
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB (Communications Toolbox)
% Description:    Algorithm-exploration script (see "Preparation" folder
%                 name): sweeps the GMSK Gaussian filter's bandwidth-time
%                 (BT) product and plots an eye diagram for each value, to
%                 visualize how BT trades spectral containment against
%                 inter-symbol interference (a tighter filter narrows the
%                 spectrum but closes the eye).
%
% Dependencies:   Communications Toolbox (comm.GMSKModulator, comm.MSKModulator)
%
%////////////////////////////////////////////////////////////////////////////////
%% GMSK Eye Diagram Gradient (Multi-BT)
clc; clear; close all;

%Parameters
numBits = 2000;              
sps = 32;                   
BT_values = [0.2, 0.3, 0.4, 0.5, 0.7, 100]; %(100 = infinite BW)
data = randi([0 1], numBits, 1);

figure('Name', 'GMSK BT Gradient', 'Color', 'w', 'Position', [100 100 1200 700]);
sgtitle('Impact of BT Product on GMSK Eye Diagram');

%Simulation Loop
for i = 1:length(BT_values)
    bt = BT_values(i);
    
    %Modulate
    %Note: BT of 100 effectively removes the Gaussian filter (MSK case)
    if bt >= 10
        % Standard MSK (BT = infinity equivalent)
        gmskMod = comm.MSKModulator('BitInput', true, 'SamplesPerSymbol', sps);
    else
        % GMSK with specific BT
        gmskMod = comm.GMSKModulator(...
            'BitInput', true, ...
            'BandwidthTimeProduct', bt, ...
            'SamplesPerSymbol', sps);
    end
    
    modSignal = gmskMod(data);
    
    %Manual Eye Diagram Construction
    %real part (In-phase)
    sig_real = real(modSignal);
    
    %remove first/last few symbols to avoid transient filters
    start_idx = 4 * sps + 1;
    end_idx = length(sig_real) - 4 * sps;
    truncated_sig = sig_real(start_idx:end_idx);
    
    %reshape signal into 2-symbol chunks for plotting
    %this creates the "overlapping" effect of the eye diagram
    sampsPerTrace = sps * 4; % 4 symbols per trace
    
    numTraces = floor(length(truncated_sig) / sampsPerTrace);
    truncated_sig = truncated_sig(1 : numTraces * sampsPerTrace);
    
    traces = reshape(truncated_sig, sampsPerTrace, []);
    
    %Plotting
    subplot(2, 3, i);
    %use a low alpha (transparency) to simulate the 'density' of a CRT scope
    plot(traces, 'b', 'Color', [0, 0.45, 0.74, 0.05]); 
    
    %Formatting
    title(['BT = ' num2str(bt)]);
    axis tight;
    ylim([-1.5 1.5]);
    grid on;
    xlabel('Time (4 Symbols)');
    if mod(i,3) == 1; ylabel('Amplitude'); end
end