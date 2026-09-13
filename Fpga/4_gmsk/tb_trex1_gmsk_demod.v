`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    tb_trex1_gmsk_demod
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Simulation-only testbench for trex1_gmsk_demod. Generates a
//                 7-symbol GMSK-like I/Q waveform (unit amplitude 800, +/-45
//                 degree phase steps per bit) from a known bit pattern and
//                 exercises the DUT with it, one symbol per simulated clock
//                 cycle, to sanity-check the cross-product discriminator and
//                 hard-decision slicer against the intended bit sequence.
//
// Dependencies:   Instantiates trex1_gmsk_demod (GMSK cross-product FM
//                 discriminator). Simulation-only; not part of synthesis.
//
//////////////////////////////////////////////////////////////////////////////////

module tb_trex1_gmsk_demod;

    // Parameters
    localparam DATA_WIDTH = 12;
    localparam CLK_PERIOD = 1000; // 1 MHz Clock

    // Signals
    reg clk;
    reg rst_n;
    reg valid_in;
    reg signed [DATA_WIDTH-1:0] i_in;
    reg signed [DATA_WIDTH-1:0] q_in;

    wire rx_bit_out;
    wire valid_out;
    wire signed [(2*DATA_WIDTH):0] freq_dev_out;

    // Instantiate the DUT (Device Under Test)
    trex1_gmsk_demod #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .i_in(i_in),
        .q_in(q_in),
        .rx_bit_out(rx_bit_out),
        .valid_out(valid_out),
        .freq_dev_out(freq_dev_out)
    );

    // Clock Generation
    always #(CLK_PERIOD/2) clk = ~clk;

    // Test Sequence
    integer i;
    real phase;
    real phase_step;

    // We will inject this specific test pattern:
    // Bits: 1, 1, 1, 0, 0, 1, 0
    reg [0:6] test_pattern = 7'b1110010;

    initial begin
        clk = 0; rst_n = 0;
        valid_in = 0; i_in = 0; q_in = 0;
        phase = 0.0;

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("--- Starting TREX1 GMSK Demodulator Testbench ---");

        // Loop through the test pattern
        for (i = 0; i < 7; i = i + 1) begin
            // If bit is 1, phase rotates +45 degrees (+0.785 rad)
            // If bit is 0, phase rotates -45 degrees (-0.785 rad)
            // This accumulated phase ramp is what gives each symbol-to-symbol
            // transition the sign of instantaneous frequency deviation that
            // the DUT's cross-product discriminator (freq_dev = Q[n]*I[n-1]
            // - I[n]*Q[n-1]) is meant to recover.
            if (test_pattern[i] == 1'b1) begin
                phase_step = 0.785398;
            end else begin
                phase_step = -0.785398;
            end

            phase = phase + phase_step;

            // Generate I and Q (Amplitude 800)
            i_in = $rtoi(800.0 * $cos(phase));
            q_in = $rtoi(800.0 * $sin(phase));
            valid_in = 1'b1;

            // Wait 1 clock cycle (Simulating 1 Sample per Symbol)
            #(CLK_PERIOD);
        end

        // Flush pipeline
        valid_in = 0;
        #(CLK_PERIOD * 5);

        $display("--- Testbench Complete ---");
        $finish;
    end

endmodule
