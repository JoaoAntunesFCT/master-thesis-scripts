##################################################################################
# Company:        NOVA SST
# Engineer:       Joao Reis Antunes
# 
# Create Date:    07/2026 (mm-yyyy)
# Module Name:    synth_trex1_multicorner_ihp130.tcl
# Project Name:   TREX1 Digital Baseband Chain
# Target Devices: IHP SG13G2 (130 nm) open-source PDK (multi-corner: setup @ sg13g2_stdcell_slow_1p08V_125C, hold @ sg13g2_stdcell_fast_1p32V_m40C)
# Description:    Design Compiler multi-corner synthesis script, IHP SG13G2 node. Same flow and RTL as the SAED14 baseline; only the library set, corners, and output tag change.
# 
# Dependencies:   Sources baseband.sdc; requires precompiled SG13G2 .db files in DB_DIR (produced separately via make_sg13g2_db.tcl, since this install cannot read the shipped .lib directly). Produces the .svf/.mapped.v netlist consumed by verify_trex1_ihp130.tcl (same RUN_TAG).
# 
##################################################################################

################################################################################
# synth_trex1_multicorner_ihp130.tcl -- DC multi-corner (BC-WC min/max) synthesis
#                                        IHP SG13G2 (130 nm)  [plan v12, sec 9]
#
# REV 4 -- consumes precompiled .db (read_db works on this install; Liberty does
# NOT -- LCSH-3 for read_lib, DB-1 for .lib in link_library, because there is no
# Library Compiler here). Generate the three .db with make_sg13g2_db.tcl on a
# tool that HAS Library Compiler, copy them into DB_DIR below, then run this.
# SAED14 worked only because it shipped .db; IHP ships .lib, so the .db must be
# produced once, elsewhere.
#
# Flow otherwise IDENTICAL to SAED14. Native voltage, shipped Liberty corners,
# no re-characterization (plan v12 sec 9.2). Confirmed from the .lib headers:
# library()==operating_conditions()==filename stem, e.g.
# sg13g2_stdcell_slow_1p08V_125C (nom 1.08 V / 125 C).
#
# Corner mapping (SG13G2 ships exactly three std-cell corners):
#     setup @ SLOW  sg13g2_stdcell_slow_1p08V_125C = MAX
#     hold  @ FAST  sg13g2_stdcell_fast_1p32V_m40C = MIN
#     typ (1.20V/25C) bracketed.
#
# Run from a FRESH dc_shell / design_vision:  source synth_trex1_multicorner_ihp130.tcl
################################################################################
# ---- 0. Knobs ---------------------------------------------------------------
set DESIGN     trex1_rx_frontend_top
set RTL_DIR    /home/trex1u06/SNPS_workspace/TREX1
# Dir holding the precompiled SG13G2 .db (confirmed via read_db + list_libs).
set DB_DIR     /home/trex1u06/SNPS_workspace/TREX1/opensource_libs
set SDC_FILE   $RTL_DIR/baseband.sdc
set OUT_DIR    /home/trex1u06/SNPS_workspace/synthesis
set RUN_TAG    _sg13g2_10mhz

set MAX_LIB    sg13g2_stdcell_slow_1p08V_125C   ;# SETUP (MAX): slow / low-V / hot
set MIN_LIB    sg13g2_stdcell_fast_1p32V_m40C   ;# HOLD  (MIN): fast / high-V / cold
set TYP_LIB    sg13g2_stdcell_typ_1p20V_25C     ;# nominal (link only, bracketed)

file mkdir $OUT_DIR/netlist $OUT_DIR/reports
set NL   $OUT_DIR/netlist/${DESIGN}${RUN_TAG}_mcmm
set RPT  $OUT_DIR/reports/mcmm${RUN_TAG}

# ---- 0.5 GUARD: the .db must exist ------------------------------------------
foreach s [list $MAX_LIB $MIN_LIB $TYP_LIB] {
  set p "$DB_DIR/${s}.db"
  if {![file exists $p] || [file size $p] == 0} {
    error "MISSING/empty $p -- generate .db with make_sg13g2_db.tcl (needs Library Compiler) and copy here."
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

# ---- 4.5 GUARD: confirm we linked to REAL SG13G2 cells, not GTECH -----------
if {[sizeof_collection [get_lib_cells -quiet ${MAX_LIB}/*]] == 0} {
  error "LINK did not resolve SG13G2 cells from ${MAX_LIB} -- check DB_DIR/search_path. Aborting before compile."
}
echo "LINK ok: SG13G2 cells resolved from ${MAX_LIB}"

# ---- 5. Operating conditions (names confirmed == stems) ---------------------
if {[catch {
  set_operating_conditions -analysis_type on_chip_variation \
    -max ${MAX_LIB} -max_library ${MAX_LIB} \
    -min ${MIN_LIB} -min_library ${MIN_LIB}
} oc_err]} {
  echo "WARN sec 5: set_operating_conditions failed -> $oc_err"
  echo "WARN sec 5: continuing on per-corner .db PVT (set_min_library split active)."
}

# ---- 6. Constraints + fixes (same as SAED14 baseline) -----------------------
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