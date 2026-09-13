##################################################################################
# Company:        NOVA SST
# Engineer:       Joao Reis Antunes
# 
# Create Date:    07/2026 (mm-yyyy)
# Module Name:    synth_trex1_multicorner_sky130.tcl
# Project Name:   TREX1 Digital Baseband Chain
# Target Devices: SkyWater SKY130 (130 nm), sky130_fd_sc_hd high-density std-cell library (multi-corner: setup @ ss_100C_1v60, hold @ ff_n40C_1v95)
# Description:    Design Compiler multi-corner synthesis script, SKY130 node. Same flow and RTL as the SAED14/SG13G2 baselines; only the library set, corners, and output tag change.
# 
# Dependencies:   Sources baseband.sdc; requires precompiled SKY130 .db files in DB_DIR. Produces the .svf/.mapped.v netlist consumed by verify_trex1_sky130.tcl (same RUN_TAG).
# 
##################################################################################

################################################################################
# synth_trex1_multicorner_sky130.tcl -- DC multi-corner (BC-WC min/max) synthesis
#                                        SkyWater SKY130  [plan v12/v13, sec 9]
#
# Third node. IDENTICAL flow to the SG13G2 rev-4 script; only the library set,
# corners, RUN_TAG and DB_DIR change. Consumes precompiled .db (this install has
# no working Library Compiler -- read_lib->LCSH-3, .lib in link_library->DB-1),
# exactly like the SG13G2 flow. SKY130 open_pdks ships Liberty (.lib) only, so if
# you do NOT already have .db, produce them once on a tool WITH Library Compiler
# (see make_sg13g2_db.tcl, retargeted) and copy them into DB_DIR.
#
# Library: sky130_fd_sc_hd (high-density digital), NATIVE 1.8 V (plan v12 sec 9.2).
# Corner trio (confirm the exact .db names available in your DB_DIR):
#     setup @ SLOW  sky130_fd_sc_hd__ss_100C_1v60 = MAX  (slow / low-V / hot)
#     hold  @ FAST  sky130_fd_sc_hd__ff_n40C_1v95 = MIN  (fast / high-V / cold)
#     typ (1.80V/25C) sky130_fd_sc_hd__tt_025C_1v80 (bracketed, link only)
#
# Run from a FRESH dc_shell / design_vision:  source synth_trex1_multicorner_sky130.tcl
################################################################################
# ---- 0. Knobs ---------------------------------------------------------------
set DESIGN     trex1_rx_frontend_top
set RTL_DIR    /home/trex1u06/SNPS_workspace/TREX1
# Dir holding the SKY130 .db (set to wherever your sky130_fd_sc_hd .db live;
# same convention as the SG13G2 opensource_libs dir).
set DB_DIR     /home/trex1u06/SNPS_workspace/TREX1/opensource_libs
set SDC_FILE   $RTL_DIR/baseband.sdc
set OUT_DIR    /home/trex1u06/SNPS_workspace/synthesis
set RUN_TAG    _sky130_10mhz

set MAX_LIB    sky130_fd_sc_hd__ss_100C_1v60    ;# SETUP (MAX): slow / 1.60V / 100C
set MIN_LIB    sky130_fd_sc_hd__ff_n40C_1v95    ;# HOLD  (MIN): fast / 1.95V / -40C
set TYP_LIB    sky130_fd_sc_hd__tt_025C_1v80    ;# nominal 1.80V/25C (link only, bracketed)

file mkdir $OUT_DIR/netlist $OUT_DIR/reports
set NL   $OUT_DIR/netlist/${DESIGN}${RUN_TAG}_mcmm
set RPT  $OUT_DIR/reports/mcmm${RUN_TAG}

# ---- 0.5 GUARD: the .db must exist ------------------------------------------
foreach s [list $MAX_LIB $MIN_LIB $TYP_LIB] {
  set p "$DB_DIR/${s}.db"
  if {![file exists $p] || [file size $p] == 0} {
    error "MISSING/empty $p -- put the SKY130 .db in DB_DIR (produce via Library Compiler if you only have .lib)."
  }
}

# ---- 1. Libraries -----------------------------------------------------------
set_app_var search_path [concat $search_path $DB_DIR $RTL_DIR]
set_app_var target_library ${MAX_LIB}.db
set_app_var link_library [list "*" ${MAX_LIB}.db ${MIN_LIB}.db ${TYP_LIB}.db]
set_app_var auto_wire_load_selection false

# ---- 2. Two-library min/max pairing -----------------------------------------
set_min_library ${MAX_LIB}.db -min_version ${MIN_LIB}.db

# ---- 3. SVF for Formality ---------------------------------------------------
set_svf ${NL}.svf

# ---- 4. Read + elaborate RTL (IDENTICAL RTL across all techs) ---------------
set_app_var hdlin_sverilog_std 2009
analyze -format sverilog [glob $RTL_DIR/*.sv]
analyze -format verilog  [glob $RTL_DIR/*.v]
elaborate $DESIGN
current_design $DESIGN
link

# ---- 4.5 GUARD: confirm we linked to REAL SKY130 cells, not GTECH -----------
if {[sizeof_collection [get_lib_cells -quiet ${MAX_LIB}/*]] == 0} {
  error "LINK did not resolve SKY130 cells from ${MAX_LIB} -- check DB_DIR/search_path. Aborting before compile."
}
echo "LINK ok: SKY130 cells resolved from ${MAX_LIB}"

# ---- 5. Operating conditions ------------------------------------------------
# Wrapped in catch: if the opcond group name differs from the library stem, or
# is absent, the per-corner .db PVT + set_min_library split still gives
# setup@slow / hold@fast. Confirm names via list_libs / the .db header if needed.
if {[catch {
  set_operating_conditions -analysis_type on_chip_variation \
    -max ${MAX_LIB} -max_library ${MAX_LIB} \
    -min ${MIN_LIB} -min_library ${MIN_LIB}
} oc_err]} {
  echo "WARN sec 5: set_operating_conditions failed -> $oc_err"
  echo "WARN sec 5: continuing on per-corner .db PVT (set_min_library split active)."
}

# ---- 6. Constraints + fixes (same as SAED14/SG13G2 baseline) ----------------
source $SDC_FILE
set_dont_touch [get_cells -hierarchical *rst_n_meta_reg*]
set_dont_touch [get_cells -hierarchical *rst_n_sync_reg*]
set_load 0.5 [all_outputs]
set_max_fanout 32 [current_design]
# Hold: ANALYZE now, FIX in P&R.
# set_fix_hold [all_clocks]

# ---- 7. Sanity + compile ----------------------------------------------------
redirect ${RPT}_check_timing.rpt {check_timing}
compile_ultra -no_autoungroup

# ---- 7.5 GUARD: a real mapped netlist has non-zero area ---------------------
set _area [get_attribute [current_design] area]
if {$_area <= 0} {
  echo "WARN: post-compile area is $_area -- looks unmapped. Inspect ${RPT}_qor.rpt."
} else {
  echo "post-compile area = $_area (mapped OK)"
}

# ---- 8. Reports: setup (max @slow) AND hold (min @fast) ---------------------
redirect ${RPT}_qor.rpt        {report_qor}
redirect ${RPT}_setup_slow.rpt {report_timing -delay_type max -nworst 2 -max_paths 20}
redirect ${RPT}_hold_fast.rpt  {report_timing -delay_type min -nworst 2 -max_paths 20}
redirect ${RPT}_constraint.rpt {report_constraint -all_violators}
redirect ${RPT}_area.rpt       {report_area -hierarchy}
redirect ${RPT}_power.rpt      {report_power}

# ---- 9. Write outputs -------------------------------------------------------
write -format ddc     -hierarchy -output ${NL}.ddc
write -format verilog -hierarchy -output ${NL}.mapped.v
write_sdc ${NL}.mapped.sdc
set_svf -off
echo "=== multi-corner${RUN_TAG} done: setup @ ${MAX_LIB}, hold @ ${MIN_LIB} ==="