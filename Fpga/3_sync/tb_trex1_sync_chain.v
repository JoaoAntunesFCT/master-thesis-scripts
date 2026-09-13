`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    tb_trex1_sync_chain
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Standalone testbench for the AGC -> CFO -> STR sync chain. Drives the
//                 chain with a weak noise floor, then a strong preamble burst (a CW
//                 tone standing in for a residual carrier frequency offset) to exercise
//                 AGC gain-stepping, CFO acquisition, and Gardner timing-error
//                 convergence, followed by a payload phase where the CFO estimator
//                 holds its last estimate while the STR loop keeps tracking.
//
// Dependencies:   Instantiates trex1_ff_agc.v, trex1_cfo_top.v, and trex1_str_top.v
//                 directly (does not go through trex1_sync_hw_top.v).
//
//////////////////////////////////////////////////////////////////////////////////

module tb_trex1_sync_chain;

    //---------------------------------------------------------
    // System Parameters
    //---------------------------------------------------------
    localparam DATA_WIDTH = 12;
    localparam CLK_PERIOD = 1000; // 1 MHz clock (1000 ns)
    localparam AGC_WINDOW = 100;
    localparam SPS = 16;
    localparam PREAMBLE_SYMS = 32;

    //---------------------------------------------------------
    // Global Signals
    //---------------------------------------------------------
    reg clk;
    reg rst_n;

    //---------------------------------------------------------
    // Stimulus Inputs (Raw Baseband)
    //---------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] tb_i_in;
    reg signed [DATA_WIDTH-1:0] tb_q_in;
    reg tb_valid_in;
    reg tb_preamble_flag;

    //---------------------------------------------------------
    // 1. AGC Interconnects
    //---------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] agc_i_out;
    wire signed [DATA_WIDTH-1:0] agc_q_out;
    wire agc_valid_out;
    wire [31:0] dbg_power_accum;
    wire [2:0]  dbg_shift_val;
    wire        dbg_shift_dir;

    trex1_ff_agc #(
        .DATA_WIDTH(DATA_WIDTH),
        .WINDOW_SIZE(AGC_WINDOW)
    ) u_agc (
        .clk(clk), .rst_n(rst_n),
        .i_data_in(tb_i_in), .q_data_in(tb_q_in), .valid_in(tb_valid_in),
        .i_data_out(agc_i_out), .q_data_out(agc_q_out), .valid_out(agc_valid_out),
        .dbg_power_accum(dbg_power_accum), .dbg_shift_val(dbg_shift_val), .dbg_shift_dir(dbg_shift_dir)
    );

    // Preamble Flag Delay Line (Matches AGC latency)
    // Same matched-delay trick as trex1_sync_hw_top.v, reproduced locally here since
    // this testbench instantiates the AGC directly instead of going through that
    // wrapper.
    reg [AGC_WINDOW-1:0] flag_delay_pipe;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) flag_delay_pipe <= 0;
        else if (tb_valid_in) flag_delay_pipe <= {flag_delay_pipe[AGC_WINDOW-2:0], tb_preamble_flag};
    end
    wire sync_preamble_active = flag_delay_pipe[AGC_WINDOW-1];

    //---------------------------------------------------------
    // 2. CFO Estimator Interconnects
    //---------------------------------------------------------
    wire signed [(2*DATA_WIDTH)+9:0] coarse_i, coarse_q, fine_i, fine_q;
    wire coarse_valid, fine_valid;

    trex1_cfo_top #(
        .DATA_WIDTH(DATA_WIDTH), .SPS(SPS), .PREAMBLE_SYMS(PREAMBLE_SYMS)
    ) u_cfo (
        .clk(clk), .rst_n(rst_n),
        .preamble_active(sync_preamble_active),
        .valid_in(agc_valid_out), .i_in(agc_i_out), .q_in(agc_q_out),
        .coarse_i(coarse_i), .coarse_q(coarse_q), .coarse_valid(coarse_valid),
        .fine_i(fine_i), .fine_q(fine_q), .fine_valid(fine_valid)
    );

    //---------------------------------------------------------
    // 3. Symbol Timing Recovery (STR) Interconnects
    //---------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] str_i_out, str_q_out;
    wire str_valid_out;

    // Fixed-point representations for Kp=0.005 and Ki=1e-5 (Scaled for hardware testing)
    // In a real system, these would come from an SPI configuration register
    reg signed [15:0] kp_val = 16'd163; // ~0.005 in Q15
    reg signed [15:0] ki_val = 16'd1;   // Smallest integral step

    trex1_str_top #(
        .DATA_WIDTH(DATA_WIDTH), .MU_WIDTH(8)
    ) u_str (
        .clk(clk), .rst_n(rst_n),
        .valid_in(agc_valid_out), .i_in(agc_i_out), .q_in(agc_q_out),
        .kp(kp_val), .ki(ki_val),
        .i_out(str_i_out), .q_out(str_q_out), .valid_out(str_valid_out)
    );

    //---------------------------------------------------------
    // Clock & Test Stimulus
    //---------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    integer k;
    real phase, phase_inc;

    initial begin
        clk = 0; rst_n = 0;
        tb_i_in = 0; tb_q_in = 0;
        tb_valid_in = 0; tb_preamble_flag = 0;

        // Simulating a Frequency Offset tone + some arbitrary base phase
        phase = 0.0;
        phase_inc = 0.314159265; // ~50 kHz at 1 MS/s

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 5);

        $display("==================================================");
        $display("   STARTING TREX1 MASTER SYNC CHAIN TESTBENCH     ");
        $display("==================================================");

        // STAGE 1: Noise Floor (Weak Signal)
        // Below the AGC's THRESH_M* thresholds -- exercises the amplify (left-shift)
        // path and keeps the CFO/STR blocks quiescent (preamble flag still low).
        $display("Time: %0t | Injecting weak noise floor...", $time);
        tb_valid_in = 1; tb_preamble_flag = 0;
        for (k = 0; k < 150; k = k + 1) begin
            tb_i_in = 12'd20; tb_q_in = 12'd20;
            #(CLK_PERIOD);
        end

        // STAGE 2: Preamble Burst (Strong Signal triggering AGC, CFO, and STR)
        // Amplitude 800 drives the AGC into its attenuate path; the rotating I/Q
        // tone (phase_inc per sample) models a CFO for the CFO estimator to acquire,
        // and gives the STR loop a continuous stream to lock timing onto.
        $display("Time: %0t | Injecting STRONG Preamble Burst (Amplitude 800)...", $time);
        tb_preamble_flag = 1;
        for (k = 0; k < (SPS * PREAMBLE_SYMS + 50); k = k + 1) begin
            tb_i_in = $rtoi(800.0 * $cos(phase));
            tb_q_in = $rtoi(800.0 * $sin(phase));
            phase = phase + phase_inc;
            #(CLK_PERIOD);
        end

        // STAGE 3: Payload (CFO stops estimating, STR keeps tracking)
        // Same tone continues so the STR loop's timing-error detector still has a
        // clean signal to track, but with tb_preamble_flag low the CFO estimator's
        // preamble-gated averaging window is closed.
        $display("Time: %0t | End of Preamble. Transitioning to Payload...", $time);
        tb_preamble_flag = 0;
        for (k = 0; k < 200; k = k + 1) begin
            tb_i_in = $rtoi(800.0 * $cos(phase));
            tb_q_in = $rtoi(800.0 * $sin(phase));
            phase = phase + phase_inc;
            #(CLK_PERIOD);
        end

        tb_valid_in = 0;
        #(CLK_PERIOD * 50);

        $display("==================================================");
        $display("FINAL PIPELINE METRICS");
        $display("==================================================");
        $display("AGC Delay Handshake:  %b (Should be 0, showing it cleared)", sync_preamble_active);
        $display("CFO Coarse Valid:     %b", coarse_valid);
        $display("CFO Fine Valid:       %b", fine_valid);
        $display("STR Symbols Output?:  Yes, check 'str_valid_out' in Vivado.");
        $display("==================================================");
        $finish;
    end

endmodule
