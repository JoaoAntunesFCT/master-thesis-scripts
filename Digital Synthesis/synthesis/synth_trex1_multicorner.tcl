##################################################################################
# Company:        NOVA SST
# Engineer:       Joao Reis Antunes
# 
# Create Date:    07/2026 (mm-yyyy)
# Module Name:    synth_trex1_multicorner.tcl
# Project Name:   TREX1 Digital Baseband Chain
# Target Devices: SAED14 14nm rvt standard-cell library (multi-corner: setup @ ss0p72v125c, hold @ ff0p88vm40c, bracketing tt0p8v25c) 
# Description:    Design Compiler multi-corner (best-case/worst-case min-max) synthesis script for the 10 MHz / 10 MS/s re-run. One netlist covers both setup and hold sign-off via the classic BC-WC flow.
# 
# Dependencies:   Sources baseband.sdc; reads RTL from RTL_DIR and the nine SAED14 .db corner libraries from LIB_DIR. Produces the .svf/.mapped.v netlist consumed by verify_trex1.tcl (same RUN_TAG).
# 
##################################################################################

################################################################################
# synth_trex1_multicorner.tcl -- DC multi-corner (BC-WC min/max) synthesis
#
# NOTE ON MCMM: named-scenario MCMM (create_scenario / set_scenario_options) is
# NOT available in this DC install -- `help create_scenario` finds nothing. It's
# a DC-NXT / topographical feature (needs physical libs + topo mode); this is a
# "Design Compiler WLM" flow. For a SINGLE-MODE design the classic best-case/
# worst-case min-max flow gives the equivalent multi-corner sign-off in ONE
# netlist:
#     setup optimized/analyzed at the slow corner  ss0p72v125c (0.72V/125C) = MAX
#     hold           analyzed at the fast corner   ff0p88vm40c (0.88V/-40C) = MIN
# tt0p8v25c (0.8V/25C nominal) is bracketed by these -> no separate pass needed.
#
# Op-cond names confirmed from the .lib files (all match filename stems).
#
# Run from a FRESH design_vision / dc_shell:  source synth_trex1_multicorner.tcl
################################################################################
# ---- 0. Knobs ---------------------------------------------------------------
set DESIGN     trex1_rx_frontend_top
set RTL_DIR    /home/trex1u06/SNPS_workspace/TREX1
set LIB_DIR    /home/trex1u06/SNPS_workspace/edk/lib/stdcell_rvt/db_nldm
set SDC_FILE   $RTL_DIR/baseband.sdc
set MAX_CORNER ss0p72v125c    ;# worst-case SETUP (slow / low-V / hot)
set MIN_CORNER ff0p88vm40c    ;# worst-case HOLD  (fast / high-V / cold)
set OUT_DIR    /home/trex1u06/SNPS_workspace/synthesis
set RUN_TAG    _10mhz         ;# distinguishes this run from the 100 MHz baseline
                              ;#   -> outputs land in netlist/ and reports/ with
                              ;#      this suffix, nothing is clobbered. Set to
                              ;#      "" to reproduce the old overwrite behavior.
file mkdir $OUT_DIR/netlist $OUT_DIR/reports
# Convenience stems so section 8/9 stay readable.
set NL   $OUT_DIR/netlist/${DESIGN}${RUN_TAG}_mcmm
set RPT  $OUT_DIR/reports/mcmm${RUN_TAG}
# ---- 1. Libraries -----------------------------------------------------------
set_app_var search_path [concat $search_path $LIB_DIR $RTL_DIR]
# Map to the MAX (setup-worst) library; all 9 linkable.
set_app_var target_library saed14rvt_${MAX_CORNER}.db
set_app_var link_library [list "*" \
  saed14rvt_tt0p8v25c.db  saed14rvt_tt0p8v125c.db  saed14rvt_tt0p8vm40c.db \
  saed14rvt_ss0p72v25c.db saed14rvt_ss0p72v125c.db saed14rvt_ss0p72vm40c.db \
  saed14rvt_ff0p88v25c.db saed14rvt_ff0p88v125c.db saed14rvt_ff0p88vm40c.db ]
set_app_var auto_wire_load_selection false   ;# pinned zero-interconnect (as baseline)
# ---- 2. Two-library min/max pairing -----------------------------------------
# Tells DC to pull MIN (hold) delays from the ff library while MAX (setup)
# delays come from the ss target library. (help set_min_library confirmed.)
set_min_library saed14rvt_${MAX_CORNER}.db -min_version saed14rvt_${MIN_CORNER}.db
# ---- 3. SVF for Formality ---------------------------------------------------
set_svf ${NL}.svf
# ---- 4. Read + elaborate RTL ------------------------------------------------
# NOTE (v9): ensure $RTL_DIR holds the sec 7.4-edited RTL --
# cic_decimator_4th_order.v (output slice [36:13]), trex1_rx_frontend_top.v
# (DDS_PERIOD 91->10, calib params /10), ddc_fs4_mixer.v + ddc_nco_cmix.v
# (comments). The globs below pick them up automatically.
set_app_var hdlin_sverilog_std 2009
analyze -format sverilog [glob $RTL_DIR/*.sv]
analyze -format verilog  [glob $RTL_DIR/*.v]
elaborate $DESIGN
current_design $DESIGN
link
# ---- 5. Operating conditions: simultaneous setup(max) + hold(min) -----------
# on_chip_variation = modern setup+hold sign-off (per-path min & max derating).
# bc_wc is the simpler classic alternative if OCV errors.
# NOTE: -*_library takes the LOGICAL library name (as in list_libs), no .db.
set_operating_conditions -analysis_type on_chip_variation \
  -max ${MAX_CORNER} -max_library saed14rvt_${MAX_CORNER} \
  -min ${MIN_CORNER} -min_library saed14rvt_${MIN_CORNER}
# ---- 6. Constraints + fixes (same as single-corner baseline) ----------------
# baseband.sdc now defines the 100 ns clock and the sec 7.5.4 ADC input delay
# (31.6 ns on raw_i_in/raw_q_in); nothing rate-specific lives in this script.
source $SDC_FILE
set_dont_touch [get_cells -hierarchical *rst_n_meta_reg*]
set_dont_touch [get_cells -hierarchical *rst_n_sync_reg*]
set_load 0.5 [all_outputs]
set_max_fanout 32 [current_design]
# Hold policy: ANALYZE now, FIX in P&R. Pre-layout hold on zero-interconnect is
# not meaningful (real hold depends on routing delay), so we don't insert hold
# buffers here. Uncomment to let DC attempt a pre-layout hold fix anyway:
# set_fix_hold [all_clocks]
# ---- 7. Sanity + compile ----------------------------------------------------
# check_timing header should now show BOTH corners active. Confirm before compile.
# Also scan this report for unconstrained/missing-input-delay on raw_i_in/
# raw_q_in -- proof the sec 7.5.4 SDC edit actually attached to the ADC ports.
redirect ${RPT}_check_timing.rpt {check_timing}
compile_ultra -no_autoungroup
# ---- 8. Reports: setup (max @ss) AND hold (min @ff) -------------------------
# The report_timing headers should read "Operating Conditions: ss0p72v125c" for
# -delay_type max and "ff0p88vm40c" for -delay_type min -- that's the proof both
# corners are live. At 100 ns, setup should close with very large margin.
redirect ${RPT}_qor.rpt        {report_qor}
redirect ${RPT}_setup_ss.rpt   {report_timing -delay_type max -nworst 2 -max_paths 20}
redirect ${RPT}_hold_ff.rpt    {report_timing -delay_type min -nworst 2 -max_paths 20}
redirect ${RPT}_constraint.rpt {report_constraint -all_violators}
redirect ${RPT}_area.rpt       {report_area -hierarchy}
# report_power added for the live 2 mW spec budget (Open #10).
redirect ${RPT}_power.rpt      {report_power}
# ---- 9. Write outputs -------------------------------------------------------
write -format ddc     -hierarchy -output ${NL}.ddc
write -format verilog -hierarchy -output ${NL}.mapped.v
write_sdc ${NL}.mapped.sdc
set_svf -off
echo "=== multi-corner${RUN_TAG} done: setup @ ${MAX_CORNER}, hold @ ${MIN_CORNER} ==="