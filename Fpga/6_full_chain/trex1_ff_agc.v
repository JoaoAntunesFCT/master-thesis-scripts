`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_ff_agc
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Feed-forward AGC (automatic gain control). Estimates input
//                 power (sum of I^2+Q^2) over a sliding WINDOW_SIZE-sample
//                 window and, from that moving-average power, applies a coarse
//                 power-of-two gain (left-shift to amplify, right-shift to
//                 attenuate, up to +/-3 bits) to the delayed I/Q samples so the
//                 output settles near a -20 dBFS nominal level. The gain
//                 decision and the sample it is applied to are aligned via a
//                 matching WINDOW_SIZE-deep delay line, so the gain seen by
//                 a sample corresponds to the power measured around it.
//
// Dependencies:   Instantiated by trex1_sync_hw_top.v (u_agc).
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_ff_agc #(
    parameter DATA_WIDTH = 12,
    parameter WINDOW_SIZE = 100,

    // Feedforward Power Thresholds (Linear values of sum(I^2+Q^2) over WINDOW_SIZE)
    parameter THRESH_P18DB = 32'd100000000, // Shift right 3
    parameter THRESH_P12DB = 32'd25000000,  // Shift right 2
    parameter THRESH_P06DB = 32'd6250000,   // Shift right 1
    parameter THRESH_NOM   = 32'd1562500,   // TARGET LEVEL (-20 dBFS)
    parameter THRESH_M06DB = 32'd390600,    // Shift left 1
    parameter THRESH_M12DB = 32'd97600,     // Shift left 2
    parameter THRESH_M18DB = 32'd24400      // Shift left 3
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire signed [DATA_WIDTH-1:0] i_data_in,
    input  wire signed [DATA_WIDTH-1:0] q_data_in,
    input  wire                    valid_in,

    output reg  signed [DATA_WIDTH-1:0] i_data_out,
    output reg  signed [DATA_WIDTH-1:0] q_data_out,
    output reg                     valid_out,

    // Debug outputs
    output wire [31:0] dbg_power_accum,
    output reg  [2:0]  dbg_shift_val,
    output reg         dbg_shift_dir // 0 = left (amplify), 1 = right (attenuate)
);

    // 1. Power Estimation
    wire signed [(2*DATA_WIDTH)-1:0] inst_power_i = i_data_in * i_data_in;
    wire signed [(2*DATA_WIDTH)-1:0] inst_power_q = q_data_in * q_data_in;
    wire [(2*DATA_WIDTH):0]          inst_power   = inst_power_i + inst_power_q;

    // 2. Moving Average Accumulator
    //    Classic running-sum sliding window: add the newest sample's power,
    //    subtract the power sample that is about to fall out of the window
    //    (power_window[WINDOW_SIZE-1]), rather than resumming WINDOW_SIZE
    //    terms every cycle.
    reg [31:0] power_accumulator;
    reg [(2*DATA_WIDTH):0] power_window [0:WINDOW_SIZE-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            power_accumulator <= 0;
            for (i = 0; i < WINDOW_SIZE; i = i + 1) begin
                power_window[i] <= 0;
            end
        end else if (valid_in) begin
            power_window[0] <= inst_power;
            for (i = 1; i < WINDOW_SIZE; i = i + 1) begin
                power_window[i] <= power_window[i-1];
            end
            power_accumulator <= power_accumulator + inst_power - power_window[WINDOW_SIZE-1];
        end
    end

    assign dbg_power_accum = power_accumulator;

    // 3. Instantaneous Feedforward Gain Logic (Coarse Steps)
    //    Threshold values below are pre-computed linear power levels (see
    //    parameter comments above) corresponding to +/-6/12/18 dB around
    //    the -20 dBFS nominal target, so each threshold crossing maps to
    //    exactly one power-of-two gain step.
    always @(*) begin
        if (power_accumulator > THRESH_P18DB) begin
            dbg_shift_val = 3; dbg_shift_dir = 1;
        end else if (power_accumulator > THRESH_P12DB) begin
            dbg_shift_val = 2; dbg_shift_dir = 1;
        end else if (power_accumulator > THRESH_P06DB) begin
            dbg_shift_val = 1; dbg_shift_dir = 1;
        end else if (power_accumulator < THRESH_M18DB) begin
            dbg_shift_val = 3; dbg_shift_dir = 0;
        end else if (power_accumulator < THRESH_M12DB) begin
            dbg_shift_val = 2; dbg_shift_dir = 0;
        end else if (power_accumulator < THRESH_M06DB) begin
            dbg_shift_val = 1; dbg_shift_dir = 0;
        end else begin
            dbg_shift_val = 0; dbg_shift_dir = 0;
        end
    end

    // 4. Delay Line (Vivado SRL Inference)
    //    Advances one stage per valid sample (holds on idle cycles).
    (* shreg_extract = "yes" *) reg signed [DATA_WIDTH-1:0] delay_line_i [0:WINDOW_SIZE-1];
    (* shreg_extract = "yes" *) reg signed [DATA_WIDTH-1:0] delay_line_q [0:WINDOW_SIZE-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < WINDOW_SIZE; i = i + 1) begin
                delay_line_i[i] <= 0; delay_line_q[i] <= 0;
            end
        end else if (valid_in) begin
            delay_line_i[0] <= i_data_in; delay_line_q[0] <= q_data_in;
            for (i = 1; i < WINDOW_SIZE; i = i + 1) begin
                delay_line_i[i] <= delay_line_i[i-1];
                delay_line_q[i] <= delay_line_q[i-1];
            end
        end
    end

    // Valid alignment (BUGFIX):
    //   The old 1-bit valid shift register shifted only on valid_in but cleared
    //   stage 0 on every idle cycle. Since valid_in is a 1-in-N pulse, the strobe
    //   was wiped before it could propagate, so valid_out NEVER fired and the whole
    //   sync chain was starved. Replace with a fill counter: once WINDOW_SIZE valid
    //   samples have entered the delay line, emit one strobe per valid_in, delayed
    //   one cycle to line up with delay_line[WINDOW_SIZE-1].
    reg [$clog2(WINDOW_SIZE+1)-1:0] fill_cnt;
    reg valid_in_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_cnt   <= 0;
            valid_in_d <= 1'b0;
        end else begin
            valid_in_d <= valid_in;
            if (valid_in && fill_cnt != WINDOW_SIZE)
                fill_cnt <= fill_cnt + 1'b1;
        end
    end

    // 5. Apply Gain
    wire signed [DATA_WIDTH-1:0] delayed_i = delay_line_i[WINDOW_SIZE-1];
    wire signed [DATA_WIDTH-1:0] delayed_q = delay_line_q[WINDOW_SIZE-1];
    wire                         delayed_v = valid_in_d & (fill_cnt == WINDOW_SIZE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_data_out <= 0; q_data_out <= 0; valid_out  <= 0;
        end else begin
            valid_out <= delayed_v;
            if (delayed_v) begin
                if (dbg_shift_dir == 0) begin // Amplify
                    i_data_out <= delayed_i << dbg_shift_val;
                    q_data_out <= delayed_q << dbg_shift_val;
                end else begin               // Attenuate
                    i_data_out <= delayed_i >>> dbg_shift_val;
                    q_data_out <= delayed_q >>> dbg_shift_val;
                end
            end
        end
    end

endmodule
