##################################################################################
# Company:        NOVA SST
# Engineer:       Joao Reis Antunes
# 
# Create Date:    07/2026 (mm-yyyy)
# Module Name:    baseband.sdc
# Project Name:   TREX1 Digital Baseband Chain
# Target Devices: Technology-independent (sourced unchanged by the SAED14, IHP SG13G2, and SKY130 synth flows)
# Description:    Design Compiler synthesis constraints (SDC): clock, reset, I/O delays, and multicycle-path exceptions for trex1_rx_frontend_top.
# 
# Dependencies:   Derived from baseband.sgdc (clock/reset facts) and nexys_a7.xdc (multicycle-path intent only, not reused directly). Sourced by synth_trex1_multicorner*.tcl.
# 
##################################################################################

# =============================================================================
# File    : baseband.sdc
# Design  : trex1_rx_frontend_top
# Purpose : Design Compiler synthesis constraints (Phase 2)
# Status  : 10 MHz / 10 MS/s re-run (plan v9, sec 7). Clock @ 100 ns; ADC bus
#           input delay updated to the sec 7.5.4 documented 31.6 ns assumption.
#
# Derived from:
#   - baseband.sgdc      (clock/reset facts, CDC sign-off, Phase 1.2)
#   - nexys_a7.xdc        (multicycle path intent only -- I/O and clock
#                          definitions in that file target the FPGA test
#                          wrapper `fpga_merged_test_wrapper`, not this
#                          synthesis top, and are NOT reused here)
# =============================================================================
current_design trex1_rx_frontend_top
# =============================================================================
# 1. CLOCK DEFINITION
#    Matches baseband.sgdc exactly: clk, 10 MHz, single domain, confirmed
#    in Phase 1.2 CDC sign-off (0 crossings, 0 unwaived errors).
#
#    NOTE (SpyGlass SGDCWRN_115): SpyGlass auto-translates this SDC's
#    create_clock into an SGDC 'clock' command for internal use, which
#    collides with the 'clock -name clk ...' already hand-authored in
#    baseband.sgdc (Phase 1.2). SpyGlass keeps the original baseband.sgdc
#    definition and ignores the SDC2SGDC-translated one for this run --
#    this is expected and harmless (both definitions are numerically
#    identical: 10 MHz / 100.000 ns period), but it means baseband.sgdc,
#    not this file, is the definition SpyGlass actually sees during
#    SpyGlass goals. This SDC's create_clock is what Design Compiler will
#    use directly in Phase 2 (DC doesn't read the SGDC).
# =============================================================================
create_clock -name clk -period 100.000 -waveform {0.000 50.000} [get_ports clk]
# No set_clock_groups needed -- single-clock design, confirmed in CDC phase.
# =============================================================================
# 2. RESET
#    rst_n is asynchronous, active-low. As of v6/v7 the 2-FF synchronizer
#    (rst_n_meta -> rst_n_sync) is in RTL; it is internal logic, not a
#    constraint, so this section is unchanged. set_dont_touch protection on
#    the synchronizer flops is applied in the synthesis scripts (Open #5).
# =============================================================================
set_false_path -from [get_ports rst_n]
# =============================================================================
# 3. I/O DELAYS
#    Derived from trex1_rx_frontend_top.v port list (Rev 4).
#
#    Budget note: the 3.0/2.0 ns figures on the non-ADC dynamic inputs and
#    on all outputs are still PLACEHOLDERS (Open #7) -- those ports interface
#    to an external DDS LUT and MAC/VIO logic elsewhere on-chip, and their
#    real budget depends on integration floorplan. The ADC data bus
#    (raw_i_in/raw_q_in) now carries the documented sec 7.5.4 assumption.
# =============================================================================
# --- 3a. Quasi-static configuration inputs -> false-path -------------------
#     Set once before/at reset release and held constant during normal
#     operation (baseband.sgdc CDC quasi_static candidates). Includes the
#     sec 7.4 runtime config values (mode_sel=1, decimation_rate=10, fcw,
#     adc_res_sel=2'b11). Excluded from setup/hold checking entirely.
set QUASI_STATIC_INPUTS { mode_sel fcw decimation_rate adc_res_sel str_kp str_ki }
set_false_path -from [get_ports $QUASI_STATIC_INPUTS]
# --- 3b-i. ADC data bus -> documented half-cycle input delay (sec 7.5.4) ----
#     raw_i_in/raw_q_in arrive from the ADC over a HALF-CYCLE path. On the
#     21-Jul Ph_S / Bit_ADC capture the last bit settles ~31.6 ns after the
#     ADC launch edge, leaving ~18.4 ns to the capture edge.
#
#     31.6 ns is a DOCUMENTED ASSUMPTION for standalone closure, NOT silicon:
#     pending analog-owner confirmation of
#        (a) launch edge -- rising vs falling; a falling-edge launch would
#            add `-clock_fall` to the -max line below, and
#        (b) worst-corner settle on a full-scale code transition.
#     Taken against the widest (10-bit) mode; the last bit to settle sets it
#     (the ~25 ns inter-bit skew does not average out).
set ADC_INPUTS { raw_i_in raw_q_in }
set_input_delay -clock clk -max 31.600 [get_ports $ADC_INPUTS]
set_input_delay -clock clk -min 2.000  [get_ports $ADC_INPUTS]
#     ^ hold (min): earliest-valid figure still TBD from the analog owner;
#       kept conservative. Pre-layout hold is analyze-only in the synth
#       script (fix deferred to P&R), so this value does not gate the run.
# --- 3b-ii. Other dynamic inputs -> placeholder budget (Open #7) -------------
#     enable, cos_lo/sin_lo (external DDS LUT), preamble_flag, packet_start
#     (MAC/VIO, one-shot). NOT covered by sec 7.5.4 -- no documented number
#     yet, so the 3.0/2.0 ns placeholder stands for this standalone pass.
#     The cos_lo/sin_lo group may change at integration (Open #7).
set DYNAMIC_INPUTS { enable cos_lo sin_lo preamble_flag packet_start }
set_input_delay -clock clk -max 3.000 [get_ports $DYNAMIC_INPUTS]
set_input_delay -clock clk -min 2.000 [get_ports $DYNAMIC_INPUTS]
#     Transition (slew) constraint -- required by SpyGlass sdc_check
#     (Inp_Trans01a) and by DC/STA generally: set_input_delay specifies
#     arrival time, not edge rate, and first-stage gate delay depends on
#     input slew. MUST cover the ADC bus too, or the split above silently
#     drops slew on raw_i_in/raw_q_in. 0.150/0.050 ns are PLACEHOLDERS;
#     replace with set_driving_cell once the upstream drivers are known.
set _ALL_DYN [concat $ADC_INPUTS $DYNAMIC_INPUTS]
set_input_transition -max 0.150 [get_ports $_ALL_DYN]
set_input_transition -min 0.050 [get_ports $_ALL_DYN]
# --- 3c. Outputs -> real output delay ---------------------------------------
#     Functional outputs (iq_tracking/iq_fault/iq_calib_phase,
#     i_out_baseband/q_out_baseband/baseband_valid_out, sync_*, cfo_*,
#     rx_bit_*, clean_payload_out, packet_valid/packet_error) AND the dbg_*
#     diagnostic taps. Still placeholder budget (Open #7).
#
#     ASSUMPTION: dbg_* ports get the same budget as functional outputs
#     rather than false-pathed, so DC does not skip hold-checking on them.
#     If confirmed don't-care in the ASIC (bonded to an unused test pad),
#     switch them to set_false_path -to instead.
set_output_delay -clock clk -max 3.000 [all_outputs]
set_output_delay -clock clk -min 2.000 [all_outputs]
# =============================================================================
# 4. MULTICYCLE PATHS
#    Translated from nexys_a7.xdc sec 4 (Rev 4). Standard SDC, portable as-is.
#    Wildcarded cell patterns reference internal module/instance names
#    (fir_i, fir_q, cic_i, cic_q, pe/*) shared with the core RTL.
#
#    Rate note (v9): these exceptions are expressed as cycle counts (2 setup /
#    1 hold), not tied to the decimation value, so the 12 -> 10 decimation
#    change does NOT alter them. A count of 2 remains conservative for the
#    decimated-rate output-register load.
#
#    CAUTION: compile_ultra may uniquify/flatten hierarchy differently than
#    Vivado. Re-verify these patterns against the post-synthesis netlist
#    (sec 3.4 Closure Loop) -- treat as "intent," not "guaranteed to match."
#
#    FIX (SpyGlass SDC_66, 05-Jul-2026): the correct collection attribute is
#    'full_name' (lowercase), not 'NAME'. Original 'NAME =~' drafts were
#    silently treated as always-false, so these exceptions were NOT applied
#    during constraint sign-off. All corrected to 'full_name =~ "*pattern*"'.
#
#    CIC glob (sec 3.2): differentiator regs are diff1_reg..diff4_reg, so the
#    old '*diff_reg*' matched nothing; corrected to '*diff*_reg*' below.
# =============================================================================
# 4a. FIR I channel: accumulator -> output register
#     Rationale: decimated-rate path, output register only loads on
#     pipe3/valid_out strobe, >= 6 clocks after last accumulator update.
set_multicycle_path -setup -from [get_cells -hierarchical -filter {full_name =~ "*fir_i*acc_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*fir_i*d_out_reg*"}] 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {full_name =~ "*fir_i*acc_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*fir_i*d_out_reg*"}] 1
# 4b. FIR Q channel: accumulator -> output register
set_multicycle_path -setup -from [get_cells -hierarchical -filter {full_name =~ "*fir_q*acc_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*fir_q*d_out_reg*"}] 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {full_name =~ "*fir_q*acc_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*fir_q*d_out_reg*"}] 1
# 4c. CIC I channel
set_multicycle_path -setup -from [get_cells -hierarchical -filter {full_name =~ "*cic_i*diff*_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*cic_i*d_out_reg*"}] 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {full_name =~ "*cic_i*diff*_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*cic_i*d_out_reg*"}] 1
# 4d. CIC Q channel
set_multicycle_path -setup -from [get_cells -hierarchical -filter {full_name =~ "*cic_q*diff*_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*cic_q*d_out_reg*"}] 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {full_name =~ "*cic_q*diff*_reg*"}] -to [get_cells -hierarchical -filter {full_name =~ "*cic_q*d_out_reg*"}] 1
# 4e. Packet engine: syndrome LUT/CRC -> correction logic
#     correction_trigger fires once per 272-bit packet; combinational LUT
#     feeds the dynamic bit-flip mux, both only matter on that one cycle.
set _pe_clean_payload [get_cells -hierarchical -filter {full_name =~ "*pe*clean_payload*"}]
set_multicycle_path -setup -from [get_cells -hierarchical -filter {full_name =~ "*pe*crc*"}] -to $_pe_clean_payload 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {full_name =~ "*pe*crc*"}] -to $_pe_clean_payload 1
# 4f. NOT carried over: FIR partial-sum -> accumulator multicycle
#     (commented out in the source XDC; no evidence it was ever needed on
#     FPGA. Add back only if post-synthesis timing shows a violation here.)
# 4g. IQ corrector LMS update paths run at the full clock rate -- already
#     pipelined in RTL, deliberately NOT multicycle. No constraint needed;
#     documented so it isn't mistaken for an oversight.
# =============================================================================
# 5. NOT CARRIED OVER FROM XDC (FPGA-physical, meaningless for ASIC synth)
#    - set_property PACKAGE_PIN / IOSTANDARD / CFGBVS / CONFIG_VOLTAGE
#    - BITSTREAM.* configuration properties
#    - create_debug_core / connect_debug_port (ILA -- test-wrapper only,
#      trex1_rx_frontend_top has no debug ports in the sign-off RTL)
# =============================================================================