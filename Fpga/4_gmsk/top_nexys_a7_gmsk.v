`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    top_nexys_a7_gmsk
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Nexys A7 board-level top wrapper for standalone hardware
//                 testing of the trex1_gmsk_demod discriminator. Synchronizes
//                 the board reset button, divides the 100MHz onboard clock down
//                 to a 1MHz sample-enable pulse, feeds the DUT a small
//                 hard-coded I/Q ROM test pattern on that pulse, and drives the
//                 decoded bit / valid flag out to onboard LEDs. An ILA core is
//                 also instantiated for on-chip debug capture.
//
// Dependencies:   Instantiates trex1_gmsk_demod (GMSK cross-product FM
//                 discriminator) and ila_0 (Vivado Integrated Logic Analyzer
//                 debug core).
//
//////////////////////////////////////////////////////////////////////////////////

module top_nexys_a7_gmsk(
    input wire clk_100mhz, // Nexys A7 onboard clock
    input wire btnC,       // Center button for reset
    output wire led0,      // rx_bit_out
    output wire led1       // valid_out
);

    // --- 1. Synchronize Reset ---
    // Run everything on the 100MHz hardware clock
    wire clk = clk_100mhz;
    reg rst_n = 0;
    always @(posedge clk) begin
        rst_n <= ~btnC; // Button is active high, rst_n is active low
    end

    // --- 2. Clock Enable Generator (1 MHz Pulse) ---
    // Instead of a new clock, we generate a 1-cycle high pulse every 100 cycles.
    // This pulse stands in for the symbol-timing-recovery "new sample ready"
    // strobe, giving the DUT one valid I/Q pair per symbol period (here,
    // 100 MHz / 100 = 1 Msample/s) while the demod logic itself still runs
    // on the full 100MHz clock.
    reg [6:0] clk_div = 0;
    reg en_1mhz = 0;

    always @(posedge clk) begin
        if (clk_div == 99) begin
            en_1mhz <= 1'b1;
            clk_div <= 0;
        end else begin
            en_1mhz <= 1'b0;
            clk_div <= clk_div + 1;
        end
    end

    // --- 3. I/Q ROM Injection ---
    // Small hard-coded I/Q sequence used to exercise the DUT on real
    // hardware without a live RF front end. rom_index walks through the
    // case table below once per 1MHz enable pulse, then wraps back to 0.
    reg [2:0] rom_index = 0;
    reg signed [11:0] i_in = 0;
    reg signed [11:0] q_in = 0;
    reg valid_in = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rom_index <= 0;
            valid_in  <= 0;
            i_in      <= 0;
            q_in      <= 0;
        end else if (en_1mhz) begin
            // Only update data and assert valid_in when the 1MHz pulse hits
            valid_in <= 1'b1;
            case(rom_index)
                3'd0: begin i_in <= 12'd565;  q_in <= 12'd565; end
                3'd1: begin i_in <= 12'd0;    q_in <= 12'd800; end
                3'd2: begin i_in <= -12'd565; q_in <= 12'd565; end
                3'd3: begin i_in <= 12'd0;    q_in <= 12'd800; end
                3'd4: begin i_in <= 12'd565;  q_in <= 12'd565; end
                3'd5: begin i_in <= 12'd0;    q_in <= 12'd800; end
                3'd6: begin i_in <= 12'd565;  q_in <= 12'd565; end
                default: begin i_in <= 0; q_in <= 0; end
            endcase

            if (rom_index < 6)
                rom_index <= rom_index + 1;
            else
                rom_index <= 0;
        end else begin
            // Pull valid_in low for the other 99 clock cycles
            valid_in <= 1'b0;
        end
    end

    // --- 4. Instantiate your DUT ---
    // freq_dev_out is DATA_WIDTH=12 here, so its width is 2*12+1 = 25 bits
    // (see trex1_gmsk_demod for the bit-width rationale).
    wire [24:0] freq_dev_out;

    trex1_gmsk_demod #(
        .DATA_WIDTH(12)
    ) dut (
        .clk(clk),            // Driven by true 100MHz clock
        .rst_n(rst_n),
        .valid_in(valid_in),  // Driven by 1MHz pulse
        .i_in(i_in),
        .q_in(q_in),
        .rx_bit_out(led0),
        .valid_out(led1),
        .freq_dev_out(freq_dev_out)
    );

    // --- 5. Instantiate the ILA ---
    // Captures the I/Q inputs, raw frequency deviation, and decoded
    // bit/valid outputs for on-chip debug via Vivado Hardware Manager.
    ila_0 debug_core (
        .clk(clk),               // Driven by true 100MHz clock
        .probe0(i_in),
        .probe1(q_in),
        .probe2(freq_dev_out),
        .probe3(led0),
        .probe4(led1)
    );

endmodule
