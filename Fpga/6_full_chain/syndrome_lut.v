`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:        NOVA SST
// Engineer:       Joao Reis Antunes
//
// Create Date:    05-2026 (mm-yyyy)
// Module Name:    syndrome_lut
// Project Name:   TREX1 Digital Baseband Chain
// Target Devices: Xilinx Artix-7 (Nexys A7 FPGA board)
// Description:    Combinational lookup table for the CRC-16 (x^16+x^12+x^5+1)
//                 single-bit-error corrector used by the packet engine. Maps
//                 the 16-bit received syndrome to the bit position (0..271)
//                 of the single flipped bit in the 272-bit (256 payload + 16
//                 CRC) packet. Syndrome 0x0000 (no error) and any syndrome not
//                 present in the table (uncorrectable, i.e. more than one bit
//                 flipped) both map to the sentinel value 9'h1FF.
//
// Dependencies:   Instantiated by trex1_packet_engine_top.v (u_lut).
//
//////////////////////////////////////////////////////////////////////////////////


`timescale 1ns / 1ps

module syndrome_lut (
    input  wire [15:0] crc_syndrome,
    output reg  [8:0]  error_idx
);

    // One entry per correctable single-bit-error position: crc_syndrome is
    // the syndrome produced by the CRC-16 (x^16+x^12+x^5+1) generator when
    // exactly one bit at position error_idx (0=MSB of the 272-bit frame) is
    // flipped. The table was generated offline by simulating a single bit
    // flip at each position and recording the resulting syndrome.
    always @(*) begin
        case(crc_syndrome)
            16'h0000: error_idx = 9'h1FF; // No Error
            16'h36F4: error_idx = 9'd0;
            16'h1B7A: error_idx = 9'd1;
            16'h0DBD: error_idx = 9'd2;
            16'h82D6: error_idx = 9'd3;
            16'h416B: error_idx = 9'd4;
            16'hA4BD: error_idx = 9'd5;
            16'hD656: error_idx = 9'd6;
            16'h6B2B: error_idx = 9'd7;
            16'hB19D: error_idx = 9'd8;
            16'hDCC6: error_idx = 9'd9;
            16'h6E63: error_idx = 9'd10;
            16'hB339: error_idx = 9'd11;
            16'hDD94: error_idx = 9'd12;
            16'h6ECA: error_idx = 9'd13;
            16'h3765: error_idx = 9'd14;
            16'h9FBA: error_idx = 9'd15;
            16'h4FDD: error_idx = 9'd16;
            16'hA3E6: error_idx = 9'd17;
            16'h51F3: error_idx = 9'd18;
            16'hACF1: error_idx = 9'd19;
            16'hD270: error_idx = 9'd20;
            16'h6938: error_idx = 9'd21;
            16'h349C: error_idx = 9'd22;
            16'h1A4E: error_idx = 9'd23;
            16'h0D27: error_idx = 9'd24;
            16'h829B: error_idx = 9'd25;
            16'hC545: error_idx = 9'd26;
            16'hE6AA: error_idx = 9'd27;
            16'h7355: error_idx = 9'd28;
            16'hBDA2: error_idx = 9'd29;
            16'h5ED1: error_idx = 9'd30;
            16'hAB60: error_idx = 9'd31;
            16'h55B0: error_idx = 9'd32;
            16'h2AD8: error_idx = 9'd33;
            16'h156C: error_idx = 9'd34;
            16'h0AB6: error_idx = 9'd35;
            16'h055B: error_idx = 9'd36;
            16'h86A5: error_idx = 9'd37;
            16'hC75A: error_idx = 9'd38;
            16'h63AD: error_idx = 9'd39;
            16'hB5DE: error_idx = 9'd40;
            16'h5AEF: error_idx = 9'd41;
            16'hA97F: error_idx = 9'd42;
            16'hD0B7: error_idx = 9'd43;
            16'hEC53: error_idx = 9'd44;
            16'hF221: error_idx = 9'd45;
            16'hFD18: error_idx = 9'd46;
            16'h7E8C: error_idx = 9'd47;
            16'h3F46: error_idx = 9'd48;
            16'h1FA3: error_idx = 9'd49;
            16'h8BD9: error_idx = 9'd50;
            16'hC1E4: error_idx = 9'd51;
            16'h60F2: error_idx = 9'd52;
            16'h3079: error_idx = 9'd53;
            16'h9C34: error_idx = 9'd54;
            16'h4E1A: error_idx = 9'd55;
            16'h270D: error_idx = 9'd56;
            16'h978E: error_idx = 9'd57;
            16'h4BC7: error_idx = 9'd58;
            16'hA1EB: error_idx = 9'd59;
            16'hD4FD: error_idx = 9'd60;
            16'hEE76: error_idx = 9'd61;
            16'h773B: error_idx = 9'd62;
            16'hBF95: error_idx = 9'd63;
            16'hDBC2: error_idx = 9'd64;
            16'h6DE1: error_idx = 9'd65;
            16'hB2F8: error_idx = 9'd66;
            16'h597C: error_idx = 9'd67;
            16'h2CBE: error_idx = 9'd68;
            16'h165F: error_idx = 9'd69;
            16'h8F27: error_idx = 9'd70;
            16'hC39B: error_idx = 9'd71;
            16'hE5C5: error_idx = 9'd72;
            16'hF6EA: error_idx = 9'd73;
            16'h7B75: error_idx = 9'd74;
            16'hB9B2: error_idx = 9'd75;
            16'h5CD9: error_idx = 9'd76;
            16'hAA64: error_idx = 9'd77;
            16'h5532: error_idx = 9'd78;
            16'h2A99: error_idx = 9'd79;
            16'h9144: error_idx = 9'd80;
            16'h48A2: error_idx = 9'd81;
            16'h2451: error_idx = 9'd82;
            16'h9620: error_idx = 9'd83;
            16'h4B10: error_idx = 9'd84;
            16'h2588: error_idx = 9'd85;
            16'h12C4: error_idx = 9'd86;
            16'h0962: error_idx = 9'd87;
            16'h04B1: error_idx = 9'd88;
            16'h8650: error_idx = 9'd89;
            16'h4328: error_idx = 9'd90;
            16'h2194: error_idx = 9'd91;
            16'h10CA: error_idx = 9'd92;
            16'h0865: error_idx = 9'd93;
            16'h803A: error_idx = 9'd94;
            16'h401D: error_idx = 9'd95;
            16'hA406: error_idx = 9'd96;
            16'h5203: error_idx = 9'd97;
            16'hAD09: error_idx = 9'd98;
            16'hD28C: error_idx = 9'd99;
            16'h6946: error_idx = 9'd100;
            16'h34A3: error_idx = 9'd101;
            16'h9E59: error_idx = 9'd102;
            16'hCB24: error_idx = 9'd103;
            16'h6592: error_idx = 9'd104;
            16'h32C9: error_idx = 9'd105;
            16'h9D6C: error_idx = 9'd106;
            16'h4EB6: error_idx = 9'd107;
            16'h275B: error_idx = 9'd108;
            16'h97A5: error_idx = 9'd109;
            16'hCFDA: error_idx = 9'd110;
            16'h67ED: error_idx = 9'd111;
            16'hB7FE: error_idx = 9'd112;
            16'h5BFF: error_idx = 9'd113;
            16'hA9F7: error_idx = 9'd114;
            16'hD0F3: error_idx = 9'd115;
            16'hEC71: error_idx = 9'd116;
            16'hF230: error_idx = 9'd117;
            16'h7918: error_idx = 9'd118;
            16'h3C8C: error_idx = 9'd119;
            16'h1E46: error_idx = 9'd120;
            16'h0F23: error_idx = 9'd121;
            16'h8399: error_idx = 9'd122;
            16'hC5C4: error_idx = 9'd123;
            16'h62E2: error_idx = 9'd124;
            16'h3171: error_idx = 9'd125;
            16'h9CB0: error_idx = 9'd126;
            16'h4E58: error_idx = 9'd127;
            16'h272C: error_idx = 9'd128;
            16'h1396: error_idx = 9'd129;
            16'h09CB: error_idx = 9'd130;
            16'h80ED: error_idx = 9'd131;
            16'hC47E: error_idx = 9'd132;
            16'h623F: error_idx = 9'd133;
            16'hB517: error_idx = 9'd134;
            16'hDE83: error_idx = 9'd135;
            16'hEB49: error_idx = 9'd136;
            16'hF1AC: error_idx = 9'd137;
            16'h78D6: error_idx = 9'd138;
            16'h3C6B: error_idx = 9'd139;
            16'h9A3D: error_idx = 9'd140;
            16'hC916: error_idx = 9'd141;
            16'h648B: error_idx = 9'd142;
            16'hB64D: error_idx = 9'd143;
            16'hDF2E: error_idx = 9'd144;
            16'h6F97: error_idx = 9'd145;
            16'hB3C3: error_idx = 9'd146;
            16'hDDE9: error_idx = 9'd147;
            16'hEAFC: error_idx = 9'd148;
            16'h757E: error_idx = 9'd149;
            16'h3ABF: error_idx = 9'd150;
            16'h9957: error_idx = 9'd151;
            16'hC8A3: error_idx = 9'd152;
            16'hE059: error_idx = 9'd153;
            16'hF424: error_idx = 9'd154;
            16'h7A12: error_idx = 9'd155;
            16'h3D09: error_idx = 9'd156;
            16'h9A8C: error_idx = 9'd157;
            16'h4D46: error_idx = 9'd158;
            16'h26A3: error_idx = 9'd159;
            16'h9759: error_idx = 9'd160;
            16'hCFA4: error_idx = 9'd161;
            16'h67D2: error_idx = 9'd162;
            16'h33E9: error_idx = 9'd163;
            16'h9DFC: error_idx = 9'd164;
            16'h4EFE: error_idx = 9'd165;
            16'h277F: error_idx = 9'd166;
            16'h97B7: error_idx = 9'd167;
            16'hCFD3: error_idx = 9'd168;
            16'hE3E1: error_idx = 9'd169;
            16'hF5F8: error_idx = 9'd170;
            16'h7AFC: error_idx = 9'd171;
            16'h3D7E: error_idx = 9'd172;
            16'h1EBF: error_idx = 9'd173;
            16'h8B57: error_idx = 9'd174;
            16'hC1A3: error_idx = 9'd175;
            16'hE4D9: error_idx = 9'd176;
            16'hF664: error_idx = 9'd177;
            16'h7B32: error_idx = 9'd178;
            16'h3D99: error_idx = 9'd179;
            16'h9AC4: error_idx = 9'd180;
            16'h4D62: error_idx = 9'd181;
            16'h26B1: error_idx = 9'd182;
            16'h9750: error_idx = 9'd183;
            16'h4BA8: error_idx = 9'd184;
            16'h25D4: error_idx = 9'd185;
            16'h12EA: error_idx = 9'd186;
            16'h0975: error_idx = 9'd187;
            16'h80B2: error_idx = 9'd188;
            16'h4059: error_idx = 9'd189;
            16'hA424: error_idx = 9'd190;
            16'h5212: error_idx = 9'd191;
            16'h2909: error_idx = 9'd192;
            16'h908C: error_idx = 9'd193;
            16'h4846: error_idx = 9'd194;
            16'h2423: error_idx = 9'd195;
            16'h9619: error_idx = 9'd196;
            16'hCF04: error_idx = 9'd197;
            16'h6782: error_idx = 9'd198;
            16'h33C1: error_idx = 9'd199;
            16'h9DE8: error_idx = 9'd200;
            16'h4EF4: error_idx = 9'd201;
            16'h277A: error_idx = 9'd202;
            16'h13BD: error_idx = 9'd203;
            16'h8DD6: error_idx = 9'd204;
            16'h46EB: error_idx = 9'd205;
            16'hA77D: error_idx = 9'd206;
            16'hD7B6: error_idx = 9'd207;
            16'h6BDB: error_idx = 9'd208;
            16'hB1E5: error_idx = 9'd209;
            16'hDCFA: error_idx = 9'd210;
            16'h6E7D: error_idx = 9'd211;
            16'hB336: error_idx = 9'd212;
            16'h599B: error_idx = 9'd213;
            16'hA8C5: error_idx = 9'd214;
            16'hD06A: error_idx = 9'd215;
            16'h6835: error_idx = 9'd216;
            16'hB012: error_idx = 9'd217;
            16'h5809: error_idx = 9'd218;
            16'hA80C: error_idx = 9'd219;
            16'h5406: error_idx = 9'd220;
            16'h2A03: error_idx = 9'd221;
            16'h9109: error_idx = 9'd222;
            16'hCC8C: error_idx = 9'd223;
            16'h6646: error_idx = 9'd224;
            16'h3323: error_idx = 9'd225;
            16'h9D99: error_idx = 9'd226;
            16'hCAC4: error_idx = 9'd227;
            16'h6562: error_idx = 9'd228;
            16'h32B1: error_idx = 9'd229;
            16'h9D50: error_idx = 9'd230;
            16'h4EA8: error_idx = 9'd231;
            16'h2754: error_idx = 9'd232;
            16'h13AA: error_idx = 9'd233;
            16'h09D5: error_idx = 9'd234;
            16'h80E2: error_idx = 9'd235;
            16'h4071: error_idx = 9'd236;
            16'hA430: error_idx = 9'd237;
            16'h5218: error_idx = 9'd238;
            16'h290C: error_idx = 9'd239;
            16'h1486: error_idx = 9'd240;
            16'h0A43: error_idx = 9'd241;
            16'h8129: error_idx = 9'd242;
            16'hC49C: error_idx = 9'd243;
            16'h624E: error_idx = 9'd244;
            16'h3127: error_idx = 9'd245;
            16'h9C9B: error_idx = 9'd246;
            16'hCA45: error_idx = 9'd247;
            16'hE12A: error_idx = 9'd248;
            16'h7095: error_idx = 9'd249;
            16'hBC42: error_idx = 9'd250;
            16'h5E21: error_idx = 9'd251;
            16'hAB18: error_idx = 9'd252;
            16'h558C: error_idx = 9'd253;
            16'h2AC6: error_idx = 9'd254;
            16'h1563: error_idx = 9'd255;
            16'h8EB9: error_idx = 9'd256;
            16'hC354: error_idx = 9'd257;
            16'h61AA: error_idx = 9'd258;
            16'h30D5: error_idx = 9'd259;
            16'h9C62: error_idx = 9'd260;
            16'h4E31: error_idx = 9'd261;
            16'hA310: error_idx = 9'd262;
            16'h5188: error_idx = 9'd263;
            16'h28C4: error_idx = 9'd264;
            16'h1462: error_idx = 9'd265;
            16'h0A31: error_idx = 9'd266;
            16'h8110: error_idx = 9'd267;
            16'h4088: error_idx = 9'd268;
            16'h2044: error_idx = 9'd269;
            16'h1022: error_idx = 9'd270;
            16'h0811: error_idx = 9'd271;
            default: error_idx = 9'h1FF; // Uncorrectable Error
        endcase
    end
endmodule
