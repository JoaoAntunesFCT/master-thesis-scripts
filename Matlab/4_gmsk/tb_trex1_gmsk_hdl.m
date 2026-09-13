%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    tb_trex1_gmsk_hdl
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Stimulus and capture harness for gmsk_demod_model.m; see
%                 the detailed header below for the fixed 11-bit payload
%                 scenario and expected decoded bit string.
%
% Dependencies:   gmsk_demod_model.m
%
%////////////////////////////////////////////////////////////////////////////////
% ============================================================================
%  gmsk_demod_testbench.m  -  Testbench for the GMSK differential demodulator
% ----------------------------------------------------------------------------
%  Stimulus + capture harness for gmsk_demod_model.m. It builds a complex
%  baseband symbol stream (constant-envelope, phase advanced +/- pi/4 per
%  symbol according to a payload bit pattern), presents one symbol per valid_in
%  strobe on a held sample bus, runs the golden model, and renders the pipeline
%  in the familiar stacked logic-analyser layout (I/Q in, freq_dev, rx_bit,
%  valid). The plot is the reference picture used to sign the fixed-point / RTL
%  demodulator off against this model: an implementation is correct when its
%  capture reproduces these waveforms and decodes the same bit string.
%
%  SCENARIO
%     DATA_WIDTH   = 12       signed I/Q                       [11:0]
%     amplitude    = 800      constant symbol envelope
%     phase step   = +/- pi/4 per symbol  (+ for bit 1, - for bit 0)
%     payload bits = 0 0 1 0 0 1 1 0 0 1 0   -> decodes to "00100110010"
%     symbol bus   = held between strobes (ILA latches the last value)
%     freq_dev     = A^2 * sin(pi/4) ~ 800^2 * 0.7071 ~ +/-452548
%
%  Note: the very first symbol only primes the 1-symbol delay, so the 11
%  decoded bits come from the 11 payload symbols that follow it.
% ============================================================================

clear;  close all;

% ---------------------------------------------------------------------------
%  Configuration
% ---------------------------------------------------------------------------
DATA_WIDTH = 12;                       % (documented; bus is 12-bit)
AMPL       = 800;                      % constant symbol envelope
STEP       = pi/4;                     % phase advance magnitude per symbol
N          = 1024;                     % samples in capture window

payload    = [0 0 1 0 0 1 1 0 0 1 0];  % 11 payload bits -> "00100110010"

% Symbol strobe schedule (system-clock sample index of each fresh symbol).
%   - first strobe primes the 1-symbol delay (no decoded bit)
%   - the following strobes are the 11 payload symbols
prime_n    = 4;                        % priming strobe
first_data = 12;                       % first payload strobe
sym_period = 100;                      % samples held per symbol
data_n     = first_data + sym_period*(0:numel(payload)-1);   % 11 strobes
strobe_n   = [prime_n, data_n];        % 12 strobes total

% ---------------------------------------------------------------------------
%  Symbol phases: prime symbol at phase 0, then accumulate +/- STEP per bit.
% ---------------------------------------------------------------------------
phase   = zeros(1, numel(strobe_n));   % phase of each symbol
for m = 1:numel(payload)
    step_m      = STEP * (2*payload(m) - 1);   % +STEP for bit 1, -STEP for bit 0
    phase(m+1)  = phase(m) + step_m;
end
sym_i = round(AMPL * cos(phase));
sym_q = round(AMPL * sin(phase));

% ---------------------------------------------------------------------------
%  Build the held sample bus and the valid_in strobe train.
% ---------------------------------------------------------------------------
i_in     = zeros(N,1);
q_in     = zeros(N,1);
valid_in = zeros(N,1);

cur_i = sym_i(1);  cur_q = sym_q(1);   % bus holds symbol 0 before first strobe
s     = 1;                             % index into strobe schedule
for n = 1:N
    if s <= numel(strobe_n) && (n-1) == strobe_n(s)
        cur_i = sym_i(s);
        cur_q = sym_q(s);
        valid_in(n) = 1;               % 1-clock symbol strobe
        s = s + 1;
    end
    i_in(n) = cur_i;
    q_in(n) = cur_q;
end

% ---------------------------------------------------------------------------
%  Run the golden model
% ---------------------------------------------------------------------------
dbg = gmsk_demod_model(i_in, q_in, valid_in);

fprintf('Decoded bits @ valid_out: %s\n', dbg.bitstr);

% ---------------------------------------------------------------------------
%  Render the Vivado-ILA-style capture
% ---------------------------------------------------------------------------
plot_ila(i_in, q_in, dbg, N, data_n);

try
    print(gcf, 'gmsk_ila_capture.png', '-dpng', '-r120');
catch
end

% ============================================================================
%  Local helper
% ============================================================================
function plot_ila(i_in, q_in, dbg, N, data_n)
    x      = 0:N-1;
    BLUE   = [0.12 0.47 0.71];
    ORANGE = [0.87 0.35 0.11];
    PURPLE = [0.29 0.16 0.53];
    RED    = [0.84 0.19 0.15];
    BLACK  = [0.10 0.10 0.10];

    figure('Color','w','Position',[80 60 1000 760]);
    sgtitle('Vivado ILA — GMSK demod — iladata','FontWeight','bold','FontSize',15);

    np = 4;
    ax = gobjects(np,1);

    % 1) I/Q in -------------------------------------------------------------
    ax(1) = subplot(np,1,1);  hold on;
    stairs(x, i_in, 'Color', BLUE,   'LineWidth', 1.2);
    stairs(x, q_in, 'Color', ORANGE, 'LineWidth', 1.2);
    title('decoded as signed 12-bit (ILA exported these unsigned)', ...
          'FontWeight','normal','FontSize',10,'Units','normalized', ...
          'Position',[0.005 1.03 0],'HorizontalAlignment','left');
    ylabel({'I / Q in','[11:0]'});
    legend({'i\_in (signed)','q\_in (signed)'},'Orientation','horizontal', ...
           'Location','northeast','Box','off');

    % 2) freq_dev_out -------------------------------------------------------
    ax(2) = subplot(np,1,2);  hold on;
    stairs(x, dbg.freq_dev, 'Color', PURPLE, 'LineWidth', 1.2);
    yline_compat(0, RED);
    title('slicer threshold at 0 (>0 → bit 1)','FontWeight','normal', ...
          'FontSize',10,'Units','normalized','Position',[0.005 1.03 0], ...
          'HorizontalAlignment','left');
    ylabel({'freq\_dev\_out','[24:0]'});

    % 3) rx_bit_out ---------------------------------------------------------
    ax(3) = subplot(np,1,3);  hold on;
    stairs(x, dbg.rx_bit, 'Color', BLACK, 'LineWidth', 1.2);
    ylabel('rx\_bit\_out');
    ylim([-0.2 1.6]);  yticks([0 1]);
    % Bit labels centred over each decoded symbol region.
    edges = [data_n, N];
    for m = 1:numel(data_n)
        xc = (edges(m) + edges(m+1)) / 2;
        text(xc, 1.32, sprintf('%d', dbg.bits(m)), 'FontWeight','bold', ...
             'FontSize',11,'HorizontalAlignment','center');
    end

    % 4) valid_out ----------------------------------------------------------
    ax(4) = subplot(np,1,4);  hold on;
    stairs(x, dbg.valid_out, 'Color', BLACK, 'LineWidth', 1.0);
    ylabel('valid\_out');
    ylim([-0.2 1.4]);  yticks([0 1]);
    xlabel('Sample in Window');

    % ---- common cosmetics -------------------------------------------------
    for k = 1:np
        axes(ax(k)); %#ok<LAXES>
        xlim([0 N]);  box off;
        set(ax(k),'XGrid','on','YGrid','on','GridAlpha',0.12, ...
            'GridLineStyle',':','Color',[0.99 0.99 0.98]);
        if k < np, set(ax(k),'XTickLabel',[]); end
    end

    % ---- decoded-bits footer ---------------------------------------------
    annotation('textbox',[0 0.005 1 0.035], ...
        'String', sprintf('decoded bits @ valid\\_out:  %s', dbg.bitstr), ...
        'HorizontalAlignment','center','EdgeColor','none', ...
        'Color',[0.35 0.35 0.35],'FontSize',11);
end

function yline_compat(yval, colour)
% yline() replacement that works on older MATLAB / Octave.
    xl = xlim;
    line(xl, [yval yval], 'Color', colour, 'LineStyle','--', 'LineWidth', 1.0);
end