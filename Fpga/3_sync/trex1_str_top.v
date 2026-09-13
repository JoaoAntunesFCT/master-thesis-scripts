`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_str_top
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Top-level Symbol Timing Recovery (STR) loop. A free-running NCO/phase
//                 accumulator (nco) decrements every input sample by the current
//                 symbol-period estimate (w_control); on underflow it strobes
//                 calc_strobe (and latches the fractional position mu) to pull one
//                 interpolated sample out of trex1_farrow. Because w_control is sized to
//                 underflow roughly twice per symbol, these strobes alternate between an
//                 on-time sample and the mid-symbol sample between them -- exactly the
//                 triple trex1_gardner's timing-error detector (TED) needs. The TED
//                 error is scaled by proportional (kp) and integral (ki) loop-filter
//                 gains and fed back into w_control (the integral term accumulates in
//                 loop_integ), so the strobe rate/phase converges to lock the on-time
//                 strobes onto the true symbol centers.
//
// Dependencies:   Instantiates trex1_farrow.v and trex1_gardner.v. Instantiated by
//                 trex1_sync_hw_top.v; also instantiated directly (bypassing that
//                 wrapper) by tb_trex1_sync_chain.v for standalone testing.
//
//////////////////////////////////////////////////////////////////////////////////

module trex1_str_top #(
    parameter DATA_WIDTH = 12,
    parameter MU_WIDTH = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,

    input  wire signed [15:0] kp,
    input  wire signed [15:0] ki,

    output wire signed [DATA_WIDTH-1:0] i_out,
    output wire signed [DATA_WIDTH-1:0] q_out,
    output wire valid_out
);

    // Nominal per-sample NCO decrement: sets the free-running strobe rate (and hence
    // the assumed symbol period) before any loop-filter correction is applied.
    localparam W_NOMINAL = 24'd2097152;

    reg signed [31:0] loop_integ;  // Loop filter integral (accumulated ki*error) term
    reg signed [24:0] nco;         // Free-running phase accumulator ("eta")
    reg [MU_WIDTH-1:0] mu;         // Fractional symbol position latched at underflow
    reg calc_strobe;               // One-cycle pulse: request a new Farrow sample

    wire signed [(2*DATA_WIDTH):0] ted_err;
    wire ted_valid;

    // FIXED-POINT MATH CORRECTION:
    // Shift by 4 to normalize the 100^2 amplitude and Q15 Kp value to match MATLAB!
    wire signed [31:0] prop_term = (kp * ted_err) >>> 4;
    wire signed [31:0] integ_term = (ki * ted_err) >>> 4;

    // Current symbol-period estimate: nominal decrement plus the loop filter's
    // proportional and (accumulated) integral corrections from the Gardner TED.
    wire signed [31:0] w_control = W_NOMINAL + prop_term + loop_integ;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_integ <= 0;
            nco <= 24'hFFFFFF;
            calc_strobe <= 0;
            mu <= 0;
        end else begin
            calc_strobe <= 0;

            // Integrate the TED error into the loop filter's memory term every time
            // a new error arrives (independent of the NCO's own sample-rate cadence).
            if (ted_valid) loop_integ <= loop_integ + integ_term;

            if (valid_in) begin
                // Underflow: not enough phase left to absorb another full
                // decrement, so wrap the accumulator and strobe a new interpolated
                // sample. mu is the phase remainder at the moment of underflow --
                // the fractional delay within the current symbol interval that
                // trex1_farrow uses to interpolate.
                if (nco < w_control) begin
                    nco <= (nco - w_control) + 24'hFFFFFF;
                    mu <= nco[23:16];
                    calc_strobe <= 1'b1;
                end else begin
                    // No underflow yet: just keep decrementing by the current
                    // symbol-period estimate.
                    nco <= nco - w_control;
                end
            end
        end
    end

    wire signed [DATA_WIDTH-1:0] f_i_out, f_q_out;
    wire f_valid;

    trex1_farrow u_farrow (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
        .i_in(i_in), .q_in(q_in), .mu(mu), .calc_strobe(calc_strobe),
        .i_out(f_i_out), .q_out(f_q_out), .valid_out(f_valid)
    );

    trex1_gardner u_ted (
        .clk(clk), .rst_n(rst_n), .valid_in(f_valid),
        .i_in(f_i_out), .q_in(f_q_out),
        .error_out(ted_err), .error_valid(ted_valid)
    );

    assign i_out = f_i_out;
    assign q_out = f_q_out;
    assign valid_out = f_valid;

endmodule
