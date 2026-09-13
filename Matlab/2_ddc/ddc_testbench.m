%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    ddc_testbench
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Stimulus and capture harness for ddc_receiver_model.m; see
%                 the detailed header below for the default test scenario
%                 and how to switch to the NCO receiver path.
%
% Dependencies:   ddc_receiver_model.m
%
%////////////////////////////////////////////////////////////////////////////////
% ============================================================================
%  ddc_testbench.m  -  Testbench for the DDC receiver front-end reference model
% ----------------------------------------------------------------------------
%  Stimulus + capture harness for ddc_receiver_model.m. It generates a complex
%  ADC tone, releases the datapath enable partway through the capture window
%  (the "trigger"), runs the golden model, and renders the pipeline taps in the
%  familiar stacked logic-analyser layout (raw ADC -> mixer -> CIC -> baseband,
%  plus NCO phase and the control/trigger strobes). The plot is the reference
%  picture used to sign off the fixed-point / RTL implementation against this
%  model: an implementation is considered correct when its capture reproduces
%  these waveforms.
%
%  DEFAULT SCENARIO  (fs/4 receiver test)
%     Fs              = 10 MHz      ADC / system sample rate
%     ADC tone        = 2.49 MHz    near +Fs/4 (= 2.5 MHz), so the fs/4 mixer
%                                   folds it to -10 kHz baseband
%     mode_sel        = 0           fs/4 fixed mixer path
%     decimation_rate = 6           CIC rate R = 6  -> 1.667 MHz output rate
%     adc_res_sel     = 3           full 10-bit ADC
%     fcw             = 0xFD6FA4    signed -168028  ->  NCO at -100.15 kHz
%                                   (f_res = Fs/2^24 = 0.596 Hz/LSB)
%                                   (probe only: the phase accumulator free-runs
%                                    even though the fs/4 path is selected)
%
%  Switch to the NCO receiver test by setting cfg.mode_sel = 1 and choosing an
%  ADC tone near the NCO frequency (e.g. 0.11 MHz); everything else is identical.
% ============================================================================

clear;  close all;

% ---------------------------------------------------------------------------
%  Configuration
% ---------------------------------------------------------------------------
cfg.Fs          = 10e6;                % ADC / system sample rate [Hz]
cfg.fcw         = hex2signed('FD6FA4', 24);   % NCO FCW (signed 24-bit)
cfg.R           = 6;                   % CIC decimation rate
cfg.adc_res_sel = 3;                   % 3 = full 10-bit ADC
cfg.mode_sel    = 0;                   % 0 = fs/4 path, 1 = NCO path

N          = 8192;                     % samples in capture window
trig       = 4096;                     % enable / trigger sample (1-based idx+..)
f_adc      = 2.49e6;                   % ADC input tone [Hz]  (near +Fs/4 = 2.5 MHz)
adc_ampl   = 460;                      % ADC tone amplitude (< 10-bit full scale)

% ---------------------------------------------------------------------------
%  Stimulus: complex ADC tone (I = cosine, Q = sine, positive frequency).
%  Rounded to integers, as delivered by a real ADC / DDS source.
% ---------------------------------------------------------------------------
n        = (0:N-1).';
raw_i_in = round(adc_ampl * cos(2*pi * f_adc/cfg.Fs * n));
raw_q_in = round(adc_ampl * sin(2*pi * f_adc/cfg.Fs * n));

% Enable / trigger: datapath released at sample "trig".
enable       = zeros(N,1);
enable(trig+1:end) = 1;               % high from the trigger sample onward
trigger      = zeros(N,1);
trigger(trig+1) = 1;                  % 1-clock trigger marker

% ---------------------------------------------------------------------------
%  Run the golden model
% ---------------------------------------------------------------------------
dbg = ddc_receiver_model(cfg, raw_i_in, raw_q_in, enable);

% ---------------------------------------------------------------------------
%  Render the Vivado-ILA-style capture
% ---------------------------------------------------------------------------
plot_ila(cfg, dbg, enable, trigger, trig, N);

% Save a copy next to the scripts (comment out if not wanted).
try
    print(gcf, 'ddc_ila_capture.png', '-dpng', '-r120');
catch
    % printing is optional; ignore if running without a display driver
end

% ============================================================================
%  Local helpers
% ============================================================================

function v = hex2signed(hexstr, nbits)
% Parse a hex string as an nbits two's complement value.
    u = hex2dec(hexstr);
    half = 2^(nbits-1);
    if u >= half
        v = u - 2^nbits;
    else
        v = u;
    end
end

function plot_ila(cfg, dbg, enable, trigger, trig, N)
% Seven stacked panels matching the reference logic-analyser capture.

    x      = 0:N-1;
    BLUE   = [0.12 0.47 0.71];         % I channel
    ORANGE = [0.87 0.35 0.11];         % Q channel
    PURPLE = [0.29 0.16 0.53];         % NCO phase
    GREEN  = [0.10 0.62 0.42];         % baseband_valid
    BLACK  = [0.10 0.10 0.10];         % enable / trigger

    figure('Color','w','Position',[80 40 980 1180]);

    % ---- title + parameter subtitle --------------------------------------
    sgtitle('Vivado ILA — DDC / Receiver Chain — iladata\_test1', ...
            'FontWeight','bold','FontSize',15);
    subtitle_txt = sprintf(['fcw=0x%06X   ·   decimation\\_rate=%d   ·   ' ...
        'adc\\_res\\_sel=%d   ·   mode\\_sel=%d   ·   rst\\_n=1'], ...
        mod(cfg.fcw, 2^24), cfg.R, cfg.adc_res_sel, cfg.mode_sel);
    annotation('textbox',[0 0.945 1 0.03],'String',subtitle_txt, ...
        'HorizontalAlignment','center','EdgeColor','none', ...
        'Color',[0.35 0.35 0.35],'FontSize',10);

    np = 7;                              % number of panels
    ax = gobjects(np,1);

    % 1) Raw ADC in ---------------------------------------------------------
    ax(1) = subplot(np,1,1);  hold on;
    plot(x, dbg.aligned_i, 'Color', BLUE,   'LineWidth', 0.6);
    plot(x, dbg.aligned_q, 'Color', ORANGE, 'LineWidth', 0.6);
    panel_title('ADC samples into the down-converter');
    ylabel({'Raw ADC in','[9:0]'});
    legend({'raw\_i\_in  (I)','raw\_q\_in  (Q)'}, ...
           'Orientation','horizontal','Location','northeast','Box','off');

    % 2) Mixer out ----------------------------------------------------------
    ax(2) = subplot(np,1,2);  hold on;
    plot(x, dbg.mixer_i, 'Color', BLUE,   'LineWidth', 1.0);
    plot(x, dbg.mixer_q, 'Color', ORANGE, 'LineWidth', 1.0);
    panel_title('After NCO complex mix (down-conversion)');
    ylabel({'Mixer out','[22:0]'});
    legend({'mixer\_i','mixer\_q'},'Orientation','horizontal', ...
           'Location','northeast','Box','off');
    annotation_trigger(trig);

    % 3) CIC out ------------------------------------------------------------
    ax(3) = subplot(np,1,3);  hold on;
    plot(x, dbg.cic_i, 'Color', BLUE,   'LineWidth', 1.0);
    plot(x, dbg.cic_q, 'Color', ORANGE, 'LineWidth', 1.0);
    panel_title('After CIC decimation filter');
    ylabel({'CIC out','[23:0]'});
    legend({'cic\_i','cic\_q'},'Orientation','horizontal', ...
           'Location','northeast','Box','off');

    % 4) Baseband out -------------------------------------------------------
    ax(4) = subplot(np,1,4);  hold on;
    plot(x, dbg.base_i, 'Color', BLUE,   'LineWidth', 1.0);
    plot(x, dbg.base_q, 'Color', ORANGE, 'LineWidth', 1.0);
    panel_title('Final baseband I/Q');
    ylabel({'Baseband out','[23:0]'});
    legend({'i\_out','q\_out'},'Orientation','horizontal', ...
           'Location','northeast','Box','off');

    % 5) NCO phase ----------------------------------------------------------
    ax(5) = subplot(np,1,5);  hold on;
    plot(x, dbg.phase, 'Color', PURPLE, 'LineWidth', 0.8);
    panel_title('NCO phase accumulator (sawtooth)');
    ylabel({'NCO phase','[23:0]'});

    % 6) control (enable + baseband_valid) ---------------------------------
    ax(6) = subplot(np,1,6);  hold on;
    hv = area(x, dbg.valid_level, 'FaceColor', GREEN, 'FaceAlpha', 0.85, ...
         'EdgeColor', GREEN);
    he = plot(x, enable, 'Color', BLACK, 'LineWidth', 1.0);
    panel_title('');
    ylabel('control');
    ylim([-0.15 1.25]);  yticks([0 1]);
    legend([he hv], {'enable','baseband\_valid'}, ...
           'Orientation','horizontal','Location','northeast','Box','off');

    % 7) TRIGGER ------------------------------------------------------------
    ax(7) = subplot(np,1,7);  hold on;
    plot(x, trigger, 'Color', BLACK, 'LineWidth', 1.0);
    ylabel('TRIGGER');
    ylim([-0.15 1.25]);  yticks([0 1]);
    xlabel('Sample in Window');

    % ---- common cosmetics + trigger line on every panel ------------------
    for k = 1:np
        axes(ax(k));  %#ok<LAXES>
        xlim([0 N]);
        grid on;  box off;
        set(ax(k),'XGrid','off','YGrid','on','GridAlpha',0.15, ...
            'Color',[0.99 0.99 0.98]);
        yl = ylim;
        line([trig trig], yl, 'Color', ORANGE, 'LineStyle','--', ...
             'LineWidth', 1.0);
        if k < np
            set(ax(k),'XTickLabel',[]);
        end
    end
end

function panel_title(str)
    if ~isempty(str)
        title(str,'FontWeight','normal','FontSize',10, ...
              'HorizontalAlignment','left','Units','normalized', ...
              'Position',[0.005 1.02 0]);
    end
end

function annotation_trigger(trig)
% Small "trigger / enable" callout on the mixer panel (axis-normalized coords).
    text(0.12, 0.62, sprintf('trigger / enable\n(sample %d)', trig), ...
        'Units','normalized','Color',[0.87 0.35 0.11],'FontSize',9, ...
        'HorizontalAlignment','left','VerticalAlignment','middle');
end