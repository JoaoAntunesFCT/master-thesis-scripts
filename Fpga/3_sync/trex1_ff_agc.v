`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_ff_agc
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Feed-forward AGC. Estimates instantaneous signal power (I^2+Q^2) each
//                 sample and maintains a WINDOW_SIZE-sample moving-average power
//                 accumulator. That average is compared against a bank of dB thresholds
//                 around the nominal target level (-20 dBFS) to pick a coarse
//                 power-of-two gain: left-shift to amplify a weak signal, right-shift to
//                 attenuate a strong one. The raw I/Q data is pushed through a matching
//                 WINDOW_SIZE-deep delay line so the chosen gain is applied once the
//                 corresponding sample re-emerges -- i.e. the gain decision is made
//                 feed-forward, ahead of the sample it will be applied to, rather than
//                 fed back from an already-scaled output.
//
// Dependencies:   Instantiated by trex1_sync_hw_top.v (and directly by
//                 tb_trex1_sync_chain.v); its AGC-normalized i_data_out/q_data_out feed
//                 trex1_cfo_top.v and trex1_str_top.v.
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
    // Instantaneous energy proxy for this sample: I^2 + Q^2 (no sqrt/magnitude taken).
    wire signed [(2*DATA_WIDTH)-1:0] inst_power_i = i_data_in * i_data_in;
    wire signed [(2*DATA_WIDTH)-1:0] inst_power_q = q_data_in * q_data_in;
    wire [(2*DATA_WIDTH):0]          inst_power   = inst_power_i + inst_power_q;

    // 2. Moving Average Accumulator
    // Running (boxcar) sum over the last WINDOW_SIZE samples: each cycle, add the new
    // sample's power and subtract the power sample that is now falling out of the
    // window (the oldest entry, held in power_window[WINDOW_SIZE-1]).
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
    // Priority-encoded thresholds spaced roughly every 6 dB (a ~4x power ratio) above
    // and below the nominal target (THRESH_NOM, -20 dBFS). The first match (checked
    // widest-deviation first) sets both the shift amount and its direction, so the
    // largest correction needed wins; comfortably near nominal falls through to the
    // "no correction" case.
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
    // Matches the WINDOW_SIZE-cycle latency of the power estimate above, so the gain
    // computed from a given window of power samples is applied to data drawn from
    // that same span once it drains out the far end of this shift register.
    (* shreg_extract = "yes" *) reg signed [DATA_WIDTH-1:0] delay_line_i [0:WINDOW_SIZE-1];
    (* shreg_extract = "yes" *) reg signed [DATA_WIDTH-1:0] delay_line_q [0:WINDOW_SIZE-1];
    (* shreg_extract = "yes" *) reg valid_delay [0:WINDOW_SIZE-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < WINDOW_SIZE; i = i + 1) begin
                delay_line_i[i] <= 0; delay_line_q[i] <= 0; valid_delay[i] <= 0;
            end
        end else if (valid_in) begin
            delay_line_i[0] <= i_data_in; delay_line_q[0] <= q_data_in; valid_delay[0] <= 1'b1;
            for (i = 1; i < WINDOW_SIZE; i = i + 1) begin
                delay_line_i[i] <= delay_line_i[i-1];
                delay_line_q[i] <= delay_line_q[i-1];
                valid_delay[i]  <= valid_delay[i-1];
            end
        end else begin
            valid_delay[0] <= 1'b0;
        end
    end

    // 5. Apply Gain
    wire signed [DATA_WIDTH-1:0] delayed_i = delay_line_i[WINDOW_SIZE-1];
    wire signed [DATA_WIDTH-1:0] delayed_q = delay_line_q[WINDOW_SIZE-1];
    wire                         delayed_v = valid_delay[WINDOW_SIZE-1];

    // Arithmetic (sign-preserving) shift right for attenuation; plain shift left for
    // amplification -- dbg_shift_dir/dbg_shift_val come straight from the threshold
    // comparison above.
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
