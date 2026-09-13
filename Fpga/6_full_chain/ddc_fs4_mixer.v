`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    ddc_fs4_mixer
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Fixed-frequency complex mixer that shifts the input spectrum
//                 down by exactly Fs/4 via multiplication by the 4-state
//                 sequence {+1, -j, -1, +j}, avoiding any multiplier hardware.
//                 Alternate ("mode_sel=0") mixer path to ddc_nco_cmix; see the
//                 design note below for the sequence table and bit widths.
//
// Dependencies:   Instantiated by ddc_frontend_top.v (u_fs4_mixer).
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// Module : ddc_fs4_mixer
// Description : Fixed-frequency complex mixer implementing multiplication by
//               e^{-j*pi/2*n} = {+1, -j, -1, +j, ...}
//               This shifts the input spectrum DOWN by exactly Fs/4 (2.5 MHz at Fs=10 MS/s).
//               Not the active path at the corrected rate: the 1 MHz IF uses
//               the NCO mixer (mode_sel=1), since Fs/4 = 2.5 MHz != 1 MHz.
//
// Shift direction: -Fs/4
//   Input at f_in -> baseband output at (f_in - Fs/4)
//   Rate-independent: the {+1,-j,-1,+j} sequence depends only on n mod 4.
//
// Sequence table (correct -Fs/4):
//   n mod 4 = 0 : multiply by +1  -> ( I,  Q)
//   n mod 4 = 1 : multiply by -j  -> ( Q, -I)
//   n mod 4 = 2 : multiply by -1  -> (-I, -Q)
//   n mod 4 = 3 : multiply by +j  -> (-Q,  I)
//
// Original bug: states 1 and 3 were swapped, implementing +Fs/4 instead of
// -Fs/4: the wanted signal was shifted to its image and aliased to an
// out-of-band frequency after CIC decimation -> ~-130 dBFS output.
//
// Bit widths:
//   i_in / q_in  : 10-bit signed (ADC resolution)
//   i_out / q_out: 11-bit signed (one guard bit for two's complement negation)
//
// Latency: 1 clock cycle (registered output)
// ============================================================================

module ddc_fs4_mixer (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire signed [9:0]  i_in,
    input  wire signed [9:0]  q_in,
    output reg  signed [10:0] i_out,
    output reg  signed [10:0] q_out
);

    reg [1:0] seq_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq_cnt <= 2'b00;
            i_out   <= 11'd0;
            q_out   <= 11'd0;
        end else if (enable) begin
            seq_cnt <= seq_cnt + 1'b1;
            case (seq_cnt)
                //                                  Multiplier
                2'b00: begin i_out <=  i_in;  q_out <=  q_in;  end  // x +1
                2'b01: begin i_out <=  q_in;  q_out <= -i_in;  end  // x -j
                2'b10: begin i_out <= -i_in;  q_out <= -q_in;  end  // x -1
                2'b11: begin i_out <= -q_in;  q_out <=  i_in;  end  // x +j
            endcase
        end
    end

endmodule
