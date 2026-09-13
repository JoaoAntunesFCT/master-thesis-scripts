`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    nexys_a7_test_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Board-level top for the Nexys A7. Derives a 1 MHz sample clock from
//                 the 100 MHz board oscillator, streams a ROM-stored I/Q test vector
//                 into trex1_sync_hw_top, exposes AGC/CFO/STR controls (reset, preamble
//                 flag, loop-filter gains kp/ki) and a recovered-symbol counter through
//                 a Vivado VIO for live interaction, and captures the STR I/Q/valid
//                 outputs plus the CFO coarse estimate with an ILA for on-hardware
//                 debug.
//
// Dependencies:   Instantiates trex1_sync_hw_top.v (the DUT) plus Vivado/Xilinx IP:
//                 BUFG, vio_control (Virtual I/O), rom_stimulus (Block Memory
//                 Generator ROM), ila_monitor (Integrated Logic Analyzer).
//
//////////////////////////////////////////////////////////////////////////////////

module nexys_a7_test_top (
    input wire clk_100mhz_pin  // Connect this to E3 in your .XDC constraints file
);

    //---------------------------------------------------------
    // 1. Clock Generation (100 MHz to 1 MHz)
    //---------------------------------------------------------
    reg [5:0] clk_div = 0;
    reg clk_1mhz_reg = 0;
    wire clk_1mhz;

    // Toggle every 50 cycles -> 100MHz / 100 = 1 MHz
    always @(posedge clk_100mhz_pin) begin
        if (clk_div == 49) begin
            clk_div <= 0;
            clk_1mhz_reg <= ~clk_1mhz_reg;
        end else begin
            clk_div <= clk_div + 1;
        end
    end

    // Put the generated clock on the global clock routing network
    BUFG bufg_inst (
        .I(clk_1mhz_reg),
        .O(clk_1mhz)
    );

    //---------------------------------------------------------
    // THE PROOF COUNTER (Counts how many symbols are recovered)
    //---------------------------------------------------------
    reg [15:0] valid_symbol_count = 0;

    always @(posedge clk_1mhz) begin
        if (!vio_rst_n) begin
            valid_symbol_count <= 0;
        end else if (hw_valid_out) begin
            valid_symbol_count <= valid_symbol_count + 1;
        end
    end

    //---------------------------------------------------------
    // 2. VIO (Virtual Controls from Vivado)
    //---------------------------------------------------------
    wire vio_rst_n;
    wire vio_preamble_flag;
    wire [15:0] vio_kp;
    wire [15:0] vio_ki;

    vio_control u_vio (
      .clk(clk_100mhz_pin),
      // Inputs (Reading the FPGA)
      .probe_in0(valid_symbol_count), // Watch this count up!
      .probe_in1(cfo_coarse_i),       // Watch the CFO calculate!
      // Outputs (Controlling the FPGA)
      .probe_out0(vio_rst_n),
      .probe_out1(vio_preamble_flag),
      .probe_out2(vio_kp),
      .probe_out3(vio_ki)
    );

    //---------------------------------------------------------
    // 3. Data Source (ROM) & Address Counter
    //---------------------------------------------------------
    reg [9:0] rom_addr = 0; // 10 bits for 1024 depth
    wire [23:0] rom_data;

    always @(posedge clk_1mhz) begin
        if (!vio_rst_n) begin
            rom_addr <= 0;
        end else begin
            // Increment address to stream data into the DUT
            rom_addr <= rom_addr + 1;
        end
    end

    rom_stimulus u_rom (
      .clka(clk_1mhz),
      .ena(1'b1),
      .addra(rom_addr),
      .douta(rom_data)
    );

    // ROM word packs I in the upper 12 bits, Q in the lower 12 bits
    wire signed [11:0] hw_i_in = rom_data[23:12];
    wire signed [11:0] hw_q_in = rom_data[11:0];

    //---------------------------------------------------------
    // 4. Your Master Thesis DUT
    //---------------------------------------------------------
    wire signed [11:0] hw_i_out;
    wire signed [11:0] hw_q_out;
    wire hw_valid_out;
    wire signed [33:0] cfo_coarse_i;

    trex1_sync_hw_top #(
        .DATA_WIDTH(12), .AGC_WINDOW(100), .SPS(16), .PREAMBLE_SYMS(32)
    ) DUT (
        .clk(clk_1mhz),
        .rst_n(vio_rst_n),
        .hw_i_in(hw_i_in),
        .hw_q_in(hw_q_in),
        .hw_valid_in(1'b1), // Streaming continuously
        .hw_preamble_flag(vio_preamble_flag),
        .kp_val(vio_kp),
        .ki_val(vio_ki),
        .hw_i_out(hw_i_out),
        .hw_q_out(hw_q_out),
        .hw_valid_out(hw_valid_out),
        .cfo_coarse_i(cfo_coarse_i),
        .cfo_coarse_q(), // Unconnected for brevity, connect if added to ILA
        .cfo_coarse_valid(),
        .cfo_fine_i(),
        .cfo_fine_q(),
        .cfo_fine_valid()
    );

    //---------------------------------------------------------
    // 5. ILA (Hardware Oscilloscope)
    //---------------------------------------------------------
    ila_monitor u_ila (
        .clk(clk_100mhz_pin),
        .probe0(hw_i_out),
        .probe1(hw_q_out),
        .probe2(hw_valid_out),
        .probe3(cfo_coarse_i)
    );

endmodule
