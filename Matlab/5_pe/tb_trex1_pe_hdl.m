%////////////////////////////////////////////////////////////////////////////////
% Company:        NOVA SST
% Engineer:       Joao Reis Antunes
%
% Create Date:    03-2026 (mm-yyyy)
% Module Name:    tb_trex1_pe_hdl
% Project Name:   TREX1 Digital Baseband Chain
% Tool Versions:  MATLAB
% Description:    Stimulus and capture harness for pe_engine_model.m; builds
%                 a full TX packet (payload + CRC-16 + PN9 whitening),
%                 injects a single-bit error, and verifies the model
%                 recovers the original payload. See the detailed header
%                 below for the exact scenario.
%
% Dependencies:   pe_engine_model.m
%
%////////////////////////////////////////////////////////////////////////////////
% ============================================================================
%  pe_engine_testbench.m  -  Testbench for the receive Packet Engine
% ----------------------------------------------------------------------------
%  Stimulus + capture harness for pe_engine_model.m. It builds a transmit
%  packet exactly as the air interface would (256-bit payload -> append CRC-16
%  -> PN9 whiten), injects a single bit error, streams the 272 whitened bits
%  MSB-first into the golden model, and renders the result in the Vivado-ILA
%  style. The plot is the reference picture used to sign the fixed-point / RTL
%  packet engine off against this model: an implementation is correct when it
%  reproduces these signals and recovers the same payload.
%
%  SCENARIO
%     payload  = 32 x 0xA5   (256 bits)
%     CRC-16   = x^16 + x^12 + x^5 + 1
%     whitening= PN9  x^9 + x^5 + 1, seed 0x1FF
%     channel  = single-bit error injected at whitened index 128
%               (arrives at position 143 -> CRC syndrome 0xB64D -> LUT idx 143)
%     result   = error corrected, CRC stripped, packet accepted
%                clean_payload_out = 32 x 0xA5, packet_valid=1, packet_error=0
%
%  NOTE ON THE WAVEFORM: the ILA capture is aligned to the accept event (the
%  trigger). packet_valid is a single-clock pulse in hardware; it is drawn a
%  few samples wide here purely for visibility, matching the reference capture.
% ============================================================================

clear;  close all;

PAYLOAD_LEN = 256;
CRC_LEN     = 16;
TOTAL_LEN   = PAYLOAD_LEN + CRC_LEN;      % 272
ERR_INDEX   = 128;                        % injected bit-error position

% ---------------------------------------------------------------------------
%  TX: payload = {32 x 0xA5}
% ---------------------------------------------------------------------------
A5 = [1 0 1 0 0 1 0 1];                   % 0xA5, bit7..bit0
payload = zeros(1, PAYLOAD_LEN);          % payload(i+1) = tx_payload[i]
for i = 0:PAYLOAD_LEN-1
    payload(i+1) = A5(8 - mod(i,8));
end

% TX CRC-16 over payload[255..0]
crc = zeros(1,16);
for i = PAYLOAD_LEN-1:-1:0
    crc = crc_tx(crc, payload(i+1));
end
fprintf('TX CRC-16 = 0x%04X\n', bits2int(crc));

% clean packet[271:0]: [271:16]=payload, [15:0]=CRC
clean = zeros(1, TOTAL_LEN);              % clean(k+1) = packet bit k
for j = 0:PAYLOAD_LEN-1, clean(16+j+1) = payload(j+1); end
for k = 0:CRC_LEN-1,     clean(k+1)     = crc(k+1);     end

% PN9 whitening
pn9 = ones(1,9);
whit = zeros(1, TOTAL_LEN);
for i = TOTAL_LEN-1:-1:0
    whit(i+1) = xor(clean(i+1), pn9(1));  % XOR with state[8]
    pn9 = pn9_tx(pn9);
end
whit(ERR_INDEX+1) = ~whit(ERR_INDEX+1);   % inject single-bit error

% ---------------------------------------------------------------------------
%  Stream MSB-first into the model, with a few trailing disabled clocks so the
%  end-of-packet correction fires.
% ---------------------------------------------------------------------------
Nstream   = TOTAL_LEN + 8;
raw_bit_in = zeros(Nstream,1);
enable     = zeros(Nstream,1);
for k = 0:TOTAL_LEN-1
    raw_bit_in(k+1) = whit(TOTAL_LEN-1-k +1);  % MSB (bit271) first
    enable(k+1)     = 1;
end

dbg = pe_engine_model(raw_bit_in, enable);

fprintf('RX syndrome  = 0x%04X\n', dbg.crc_syndrome(TOTAL_LEN));
fprintf('error_idx    = %d\n', dbg.error_idx);
fprintf('payload      = %s\n', dbg.payload_hex);
acc = any(dbg.packet_valid) && ~any(dbg.packet_error);
fprintf('packet %s\n', ternary(acc,'ACCEPTED','REJECTED'));

% ---------------------------------------------------------------------------
%  Render the Vivado-ILA-style capture (aligned to the accept event)
% ---------------------------------------------------------------------------
plot_ila(dbg, acc);

try
    print(gcf, 'pe_engine_ila_capture.png', '-dpng', '-r120');
catch
end

% ============================================================================
%  TX helpers (the same transmit CRC / PN9 generation later carried into
%  the RTL testbench)
% ============================================================================
function c = crc_tx(crc, inbit)
    fb = xor(crc(16), inbit);
    c = zeros(1,16);
    c(16)=crc(15); c(15)=crc(14); c(14)=crc(13); c(13)=crc(12);
    c(12)=xor(crc(11), fb);
    c(11)=crc(10); c(10)=crc(9); c(9)=crc(8); c(8)=crc(7); c(7)=crc(6); c(6)=crc(5);
    c(5)=xor(crc(4), fb);
    c(4)=crc(3); c(3)=crc(2); c(2)=crc(1);
    c(1)=fb;
end
function s = pn9_tx(s)
    fb = xor(s(1), s(5));
    s = [fb, s(1:8)];
end
function v = bits2int(b)
    v = 0; for k = 1:numel(b), v = v + b(k)*2^(k-1); end
end
function r = ternary(c,a,b), if c, r=a; else, r=b; end, end

% ============================================================================
%  Plot
% ============================================================================
function plot_ila(dbg, accepted)
    N    = 1024;   trig = 512;
    x    = 0:N-1;
    DARK = [0.30 0.28 0.25];
    BLUE = [0.12 0.47 0.90];
    GREEN= [0.10 0.62 0.42];
    RED  = [0.84 0.19 0.15];
    BLACK= [0.10 0.10 0.10];
    ORANGE=[0.95 0.45 0.25];

    figure('Color','w','Position',[70 50 1060 760]);
    sgtitle('Vivado ILA — Packet Engine — iladata','FontWeight','bold','FontSize',15);

    np = 4;  ax = gobjects(np,1);

    % 1) clean_payload_out bus ---------------------------------------------
    ax(1) = subplot(np,1,1);  hold on;
    hi = 1;  lo = -1;
    % pre-trigger value 0x0 (dark), post-trigger payload (blue)
    plot([0 trig],[hi hi],'Color',DARK,'LineWidth',1.6);
    plot([0 trig],[lo lo],'Color',DARK,'LineWidth',1.6);
    plot([trig N],[hi hi],'Color',BLUE,'LineWidth',1.6);
    plot([trig N],[lo lo],'Color',BLUE,'LineWidth',1.6);
    % bus crossover (X) at the trigger
    seam = 8;
    plot([trig-seam trig+seam],[hi lo],'Color',DARK,'LineWidth',1.6);
    plot([trig-seam trig+seam],[lo hi],'Color',DARK,'LineWidth',1.6);
    text(trig/2, 0, '0x0', 'HorizontalAlignment','center','FontSize',11);
    text((trig+N)/2, 0, dbg.payload_hex, 'HorizontalAlignment','center','FontSize',11);
    text(0.02, 1.18, 'recovered payload (hex)','Units','normalized', ...
         'Color',[0.4 0.4 0.4],'FontSize',10);
    ylabel({'clean\_payload\_out','[255:0]'});
    ylim([-2.2 2.2]);  set(ax(1),'YTick',[]);

    % 2) start_pulse --------------------------------------------------------
    ax(2) = subplot(np,1,2);  hold on;
    plot(x, zeros(1,N), 'Color', BLACK, 'LineWidth', 1.4);
    ylabel('start\_pulse');  ylim([-0.4 1.4]);  yticks([0 1]);

    % 3) packet_valid (drawn a few samples wide for visibility) -------------
    ax(3) = subplot(np,1,3);  hold on;
    pv = zeros(1,N);
    if accepted, pv(trig+1 : trig+100) = 1; end
    stairs(x, pv, 'Color', GREEN, 'LineWidth', 1.6);
    ylabel('packet\_valid');  ylim([-0.4 1.4]);  yticks([0 1]);

    % 4) packet_error -------------------------------------------------------
    ax(4) = subplot(np,1,4);  hold on;
    pe = zeros(1,N);
    if ~accepted, pe(trig+1:end) = 1; end
    plot(x, pe, 'Color', RED, 'LineWidth', 1.4);
    ylabel('packet\_error');  ylim([-0.4 1.4]);  yticks([0 1]);
    xlabel('Sample in Window');

    % ---- common cosmetics + trigger marker -------------------------------
    for k = 1:np
        axes(ax(k)); %#ok<LAXES>
        xlim([0 N]);  box off;
        set(ax(k),'XGrid','on','YGrid','off','GridAlpha',0.12, ...
            'GridLineStyle',':','Color',[0.99 0.99 0.98]);
        yl = ylim;
        line([trig trig], yl, 'Color', ORANGE, 'LineStyle','--','LineWidth',1.2);
        if k < np, set(ax(k),'XTickLabel',[]); end
    end

    axes(ax(1));
    text(trig, 2.65, sprintf('ILA trigger\n(sample %d)', trig), ...
        'Color', ORANGE, 'FontSize', 9, 'HorizontalAlignment','center');

    annotation('textbox',[0 0.005 1 0.035], ...
        'String', sprintf(['payload = %s   ·   packet\\_valid asserted, ' ...
                           'packet\\_error low → packet accepted'], dbg.payload_hex), ...
        'HorizontalAlignment','center','EdgeColor','none', ...
        'Color',[0.35 0.35 0.35],'FontSize',11);
end