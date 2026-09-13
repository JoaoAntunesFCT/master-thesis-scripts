`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    cic_decimator_4th_order
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    4th-order CIC (cascaded integrator-comb) decimator with a
//                 runtime-selectable decimation rate (1-15). Integrator section
//                 runs every enable clock; comb section runs on a decimated
//                 strobe. See the design-note block below for the two-strobe
//                 timing fix and the output truncation/scaling rationale.
//
// Dependencies:   Instantiated by ddc_frontend_top.v (u_cic_i, u_cic_q - one
//                 per I/Q channel).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : cic_decimator_4th_order
// Description : 4th-order CIC decimator, selectable rate 1-15.
//
// Key timing fix vs previous version:
//   The comb section has 4 registered stages (each clocked on comb_strobe).
//   If valid_out is driven from the same always block as the comb registers,
//   it arrives at the FIR 6-7 cycles late (after comb pipeline + d_out reg),
//   making the effective FIR strobe period 7x12=84 instead of 12.
//
//   Fix: two separate strobes:
//     comb_strobe  - registered from the counter, clocks the comb section.
//                    Purely internal.
//     valid_out    - registered ONE cycle after comb_strobe, so d_out is
//                    stable when valid_out is seen by the FIR.
//                    The FIR latches d_in on the cycle AFTER valid_out,
//                    so d_out must be stable for one full clock after
//                    comb_strobe. Using comb_strobe delayed by 1 is sufficient.
//
//   This gives FIR enable period = exactly R system clocks.
//
// Integrators: 38-bit (23-bit input + 15 guard bits provisioned; R=10, N=4)
// Output truncation: diff4[36:13] -> 24-bit (divides by 2^13, R=10).
//   CIC gain at R=10, N=4 is R^N = 10^4 ~ 2^13.29; /2^13 restores near-unity
//   (1.22x). Was [37:14] under the R=12 / 100 MS/s dimensioning -- see sec 7.4.
//
// Input width: signed [22:0] (23-bit, from 10b ADC × 12b LO mixer output)
// ============================================================================

module cic_decimator_4th_order (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire [3:0]         rate,
    input  wire signed [22:0] d_in,
    output reg                valid_out,
    output reg  signed [23:0] d_out
);

    // -----------------------------------------------------------------------
    // Decimation counter - fires comb_strobe every R clocks
    // -----------------------------------------------------------------------
    reg [3:0] dec_cnt;
    reg       comb_strobe;   // internal: clocks the comb section

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_cnt     <= 4'd0;
            comb_strobe <= 1'b0;
        end else if (enable) begin
            if (dec_cnt == (rate - 4'd1)) begin
                dec_cnt     <= 4'd0;
                comb_strobe <= 1'b1;
            end else begin
                dec_cnt     <= dec_cnt + 4'd1;
                comb_strobe <= 1'b0;
            end
        end else begin
            comb_strobe <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // valid_out = comb_strobe delayed by 1 clock so d_out is stable.
    // The FIR's always block latches d_in on the posedge after valid_out,
    // meaning d_out must be written and stable before that edge.
    // comb_strobe writes d_out (via the comb always block below);
    // valid_out fires one cycle later - d_out is fully settled.
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_out <= 1'b0;
        else        valid_out <= comb_strobe;
    end

    // -----------------------------------------------------------------------
    // Integrator section - 4 cascaded accumulators, runs every enable clock
    // 38-bit registers: 23-bit input + ceil(4*log2(12)) = 15 guard bits
    // -----------------------------------------------------------------------
    reg signed [37:0] int1, int2, int3, int4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int1 <= 38'd0; int2 <= 38'd0;
            int3 <= 38'd0; int4 <= 38'd0;
        end else if (enable) begin
            int1 <= int1 + d_in;
            int2 <= int2 + int1;
            int3 <= int3 + int2;
            int4 <= int4 + int3;
        end
    end

    // -----------------------------------------------------------------------
    // Comb section - 4 cascaded differentiators, clocked on comb_strobe.
    // d_out is written in the same always block so it is updated exactly
    // one clock after comb_strobe (the registered valid_out cycle).
    // -----------------------------------------------------------------------
    reg signed [37:0] comb1_d, comb2_d, comb3_d, comb4_d;   // delayed (prev) values
    reg signed [37:0] diff1,   diff2,   diff3,   diff4;      // difference outputs

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comb1_d <= 38'd0; diff1 <= 38'd0;
            comb2_d <= 38'd0; diff2 <= 38'd0;
            comb3_d <= 38'd0; diff3 <= 38'd0;
            comb4_d <= 38'd0; diff4 <= 38'd0;
            d_out   <= 24'd0;
        end else if (comb_strobe) begin
            // Stage 1: diff = int4 - int4_prev
            diff1   <= int4  - comb1_d;
            comb1_d <= int4;
            // Stage 2
            diff2   <= diff1 - comb2_d;
            comb2_d <= diff1;
            // Stage 3
            diff3   <= diff2 - comb3_d;
            comb3_d <= diff2;
            // Stage 4
            diff4   <= diff3 - comb4_d;
            comb4_d <= diff3;
            // Output: drop 13 LSBs, keep bits [36:13] (24 bits) of the accumulator.
            // diff4 here is the REGISTERED value from the previous comb_strobe
            // (all registers update simultaneously on this edge, so diff4 still
            // holds the N-1 value when this line executes - correct pipelining).
            d_out   <= diff4[36:13];
        end
    end

endmodule
