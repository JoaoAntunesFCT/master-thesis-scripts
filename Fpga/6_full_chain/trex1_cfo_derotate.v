`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    trex1_cfo_derotate
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Closes the CFO (carrier-frequency-offset) correction loop
//                 using two CORDIC engines: a vectoring CORDIC extracts the
//                 per-sample phase increment (CFO) from the lag-N autocorrelation
//                 produced by trex1_cfo_top, a phase accumulator integrates it,
//                 and a rotating CORDIC de-rotates the live I/Q by the negative
//                 of that accumulated phase. See the design note below for the
//                 CORDIC angle format and pipeline details.
//
// Dependencies:   Instantiated by trex1_sync_hw_top.v (u_derot); consumes the
//                 fine (lag-SPS) autocorrelation output of trex1_cfo_top.v.
//
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// trex1_cfo_derotate
//
// Closes the CFO loop that trex1_cfo_top only *estimated*.  Inserted between
// the AGC and the STR:   AGC -> cfo_derotate -> STR.
//
//   1. A vectoring CORDIC takes the lag-1 autocorrelation (coarse_i,coarse_q)
//      and returns its phase = per-sample carrier phase increment dphi (the CFO).
//   2. A phase accumulator ramps phi(n) = phi(n-1) + dphi each input sample.
//   3. A rotating CORDIC de-rotates (i_in,q_in) by -phi(n).
//
// Angle format: full circle = 2^16 (signed 17-bit headroom). 14 CORDIC stages.
// CORDIC processing gain (~1.647) is left on the rotated output and clamped to
// DATA_WIDTH; the demod is differential so a constant gain is harmless.
//
// If enable=0 the block is a transparent passthrough (i_out=i_in, etc.), so you
// can A/B test with/without CFO correction from a VIO bit.
// ============================================================================
module trex1_cfo_derotate #(
    parameter DATA_WIDTH = 12,
    parameter ACC_WIDTH  = 34,       // width of coarse_i/coarse_q  ((2*DW)+10)
    parameter VW          = 24,      // vectoring CORDIC internal width (resolution)
    parameter LAG_LOG2    = 4,       // coarse autocorr is lag-2^LAG_LOG2 (16) => /16 to get per-sample CFO
    parameter STAGES      = 14
)(
    input  wire clk,
    input  wire rst_n,
    input  wire enable,

    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] i_in,
    input  wire signed [DATA_WIDTH-1:0] q_in,

    input  wire signed [ACC_WIDTH-1:0]  coarse_i,
    input  wire signed [ACC_WIDTH-1:0]  coarse_q,
    input  wire coarse_valid,

    output reg  signed [DATA_WIDTH-1:0] i_out,
    output reg  signed [DATA_WIDTH-1:0] q_out,
    output reg  valid_out
);
    // full-circle = 65536
    localparam signed [16:0] ATAN0=8192, ATAN1=4836, ATAN2=2555, ATAN3=1297,
        ATAN4=651, ATAN5=326, ATAN6=163, ATAN7=81, ATAN8=41, ATAN9=20,
        ATAN10=10, ATAN11=5, ATAN12=3, ATAN13=1;
    function signed [16:0] atan_k(input integer k);
        case(k)
          0:atan_k=ATAN0; 1:atan_k=ATAN1; 2:atan_k=ATAN2; 3:atan_k=ATAN3;
          4:atan_k=ATAN4; 5:atan_k=ATAN5; 6:atan_k=ATAN6; 7:atan_k=ATAN7;
          8:atan_k=ATAN8; 9:atan_k=ATAN9; 10:atan_k=ATAN10; 11:atan_k=ATAN11;
          12:atan_k=ATAN12; default:atan_k=ATAN13;
        endcase
    endfunction
    localparam signed [16:0] QUARTER = 17'sd16384;   // pi/2
    localparam signed [16:0] HALF    = 17'sd32768;    // pi

    integer s;

    // ============ 1. VECTORING CORDIC : phase of (coarse_i,coarse_q) ============
    // reduce the wide autocorr to a workable magnitude (sign-preserving)
    localparam SHV = ACC_WIDTH - VW;
    reg signed [VW-1:0] vx [0:STAGES];
    reg signed [VW-1:0] vy [0:STAGES];
    reg signed [16:0]           vz [0:STAGES];
    reg [STAGES:0]              vv;

    (* mark_debug = "true" *) wire signed [VW-1:0] cir = coarse_i[ACC_WIDTH-1:SHV];
    (* mark_debug = "true" *) wire signed [VW-1:0] ciq = coarse_q[ACC_WIDTH-1:SHV];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vx[0]<=0; vy[0]<=0; vz[0]<=0; vv[0]<=0;
        end else begin
            vv[0] <= coarse_valid;
            // quadrant pre-rotation so x>=0
            if (cir >= 0) begin vx[0]<= cir; vy[0]<= ciq; vz[0]<= 0;     end
            else if (ciq >= 0) begin vx[0]<= ciq; vy[0]<=-cir; vz[0]<= QUARTER; end
            else            begin vx[0]<=-ciq; vy[0]<= cir; vz[0]<=-QUARTER; end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s=0;s<STAGES;s=s+1) begin vx[s+1]<=0; vy[s+1]<=0; vz[s+1]<=0; vv[s+1]<=0; end
        end else begin
            for (s=0;s<STAGES;s=s+1) begin
                vv[s+1] <= vv[s];
                if (vy[s] >= 0) begin               // rotate to drive y->0
                    vx[s+1] <= vx[s] + (vy[s] >>> s);
                    vy[s+1] <= vy[s] - (vx[s] >>> s);
                    vz[s+1] <= vz[s] + atan_k(s);
                end else begin
                    vx[s+1] <= vx[s] - (vy[s] >>> s);
                    vy[s+1] <= vy[s] + (vx[s] >>> s);
                    vz[s+1] <= vz[s] - atan_k(s);
                end
            end
        end
    end

    // latched per-sample phase increment (CFO)
    // coarse autocorr is lag-2^LAG_LOG2, so its phase = lag * (per-sample CFO).
    // Divide by the lag to recover the per-sample phase increment.
    (* mark_debug = "true" *) reg signed [16:0] dphi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        dphi <= 0;
        else if (vv[STAGES]) dphi <= vz[STAGES] >>> LAG_LOG2;
    end

    // raw vectoring CORDIC angle output (before lag divide)
    (* mark_debug = "true" *) wire signed [16:0] dbg_raw_angle = vz[STAGES];

    // ============ 2. PHASE ACCUMULATOR (16-bit => wraps mod 2*pi) ============
    (* mark_debug = "true" *) reg signed [15:0] phi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            phi <= 0;
        else if (valid_in && enable) phi <= phi + dphi;   // free-runs with CFO
    end

    // ============ 3. ROTATING CORDIC : de-rotate (i_in,q_in) by -phi ============
    reg signed [DATA_WIDTH+2:0] rx [0:STAGES];
    reg signed [DATA_WIDTH+2:0] ry [0:STAGES];
    reg signed [16:0]           rz [0:STAGES];
    reg [STAGES:0]              rv;

    wire signed [16:0] tgt = -{{1{phi[15]}}, phi};   // de-rotate, sign-extended to 17b
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx[0]<=0; ry[0]<=0; rz[0]<=0; rv[0]<=0; end
        else begin
            rv[0] <= valid_in;
            // fold target angle into [-pi/2, pi/2]
            if (tgt > QUARTER) begin           // > pi/2 : pre-rotate -pi
                rx[0]<=-i_in; ry[0]<=-q_in; rz[0]<= tgt - HALF;
            end else if (tgt < -QUARTER) begin // < -pi/2 : pre-rotate +pi
                rx[0]<=-i_in; ry[0]<=-q_in; rz[0]<= tgt + HALF;
            end else begin
                rx[0]<= i_in; ry[0]<= q_in; rz[0]<= tgt;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s=0;s<STAGES;s=s+1) begin rx[s+1]<=0; ry[s+1]<=0; rz[s+1]<=0; rv[s+1]<=0; end
        end else begin
            for (s=0;s<STAGES;s=s+1) begin
                rv[s+1] <= rv[s];
                if (rz[s] >= 0) begin               // drive z->0
                    rx[s+1] <= rx[s] - (ry[s] >>> s);
                    ry[s+1] <= ry[s] + (rx[s] >>> s);
                    rz[s+1] <= rz[s] - atan_k(s);
                end else begin
                    rx[s+1] <= rx[s] + (ry[s] >>> s);
                    ry[s+1] <= ry[s] - (rx[s] >>> s);
                    rz[s+1] <= rz[s] + atan_k(s);
                end
            end
        end
    end

    localparam signed [DATA_WIDTH:0] MAXV =  (1<<(DATA_WIDTH-1))-1;
    localparam signed [DATA_WIDTH:0] MINV = -(1<<(DATA_WIDTH-1));
    wire signed [DATA_WIDTH+2:0] rxo = rx[STAGES];
    wire signed [DATA_WIDTH+2:0] ryo = ry[STAGES];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin i_out<=0; q_out<=0; valid_out<=0; end
        else if (!enable) begin                 // transparent passthrough
            i_out<=i_in; q_out<=q_in; valid_out<=valid_in;
        end else begin
            valid_out <= rv[STAGES];
            i_out <= (rxo>MAXV)?MAXV[DATA_WIDTH-1:0]:(rxo<MINV)?MINV[DATA_WIDTH-1:0]:rxo[DATA_WIDTH-1:0];
            q_out <= (ryo>MAXV)?MAXV[DATA_WIDTH-1:0]:(ryo<MINV)?MINV[DATA_WIDTH-1:0]:ryo[DATA_WIDTH-1:0];
        end
    end
endmodule
