##################################################################################
# Company:        NOVA SST
# Engineer:       Joao Reis Antunes
# 
# Create Date:    07/2026 (mm-yyyy)
# Module Name:    verify_trex1_sky130.tcl
# Project Name:   TREX1 Digital Baseband Chain
# Target Devices: SkyWater SKY130 (130 nm) (verifies the SKY130 multi-corner netlist against the golden RTL)
# Description:    Formality RTL-vs-gate equivalence check, SKY130 node. Same golden reference RTL as the SAED14/SG13G2 checks -- any new mismatch points at the SKY130 library/mapping, not the RTL.
# 
# Dependencies:   Requires the netlist and .svf produced by synth_trex1_multicorner_sky130.tcl with the same RUN_TAG, plus the golden RTL in RTL_DIR and the precompiled SKY130 .db in DB_DIR.
# 
##################################################################################

################################################################################
# verify_trex1_sky130.tcl  --  Formality RTL-vs-gate equivalence (Phase 3)
#                              SkyWater SKY130  [plan v12/v13, sec 9]
#
# Third node. IDENTICAL to the SG13G2 verify script; only the tech .db, RUN_TAG
# and report stem change. Reads the precompiled SKY130 .db via read_db.
#
# KEY: reference RTL is the SAME golden RTL as SAED14/SG13G2 -> expect the SAME
# compare-point total (~19,1xx), any delta being DC library/mapping variance,
# not RTL. One reference, three implementations.
#
# Run AFTER a REAL (mapped) SKY130 synth netlist exists:
#   fm_shell -f verify_trex1_sky130.tcl        (batch)
#   source  verify_trex1_sky130.tcl            (inside fm_shell / Formality GUI)
################################################################################
# ---- 0. Knobs ---------------------------------------------------------------
set DESIGN   trex1_rx_frontend_top
set RTL_DIR  /home/trex1u06/SNPS_workspace/TREX1
set SYN_DIR  /home/trex1u06/SNPS_workspace/synthesis
# Same DB_DIR as the SKY130 synth script.
set DB_DIR   /home/trex1u06/SNPS_workspace/TREX1/opensource_libs
set CELL_LIB sky130_fd_sc_hd__tt_025C_1v80   ;# any corner defines the same cells; typ is fine
set NLTAG    mcmm            ;# multi-corner
set RUN_TAG  _sky130_10mhz   ;# MUST match the SKY130 synth RUN_TAG
set NETLIST  $SYN_DIR/netlist/${DESIGN}${RUN_TAG}_${NLTAG}.mapped.v
set SVF_FILE $SYN_DIR/netlist/${DESIGN}${RUN_TAG}_${NLTAG}.svf
set OUT_DIR  /home/trex1u06/SNPS_workspace/formality/reports
set RPTTAG   ${NLTAG}${RUN_TAG}      ;# report stem: mcmm_sky130_10mhz_*
file mkdir $OUT_DIR
echo "FM inputs:  netlist = $NETLIST"
echo "            svf     = $SVF_FILE"
echo "            celllib = $DB_DIR/${CELL_LIB}.db"
# ---- 1. SVF guidance from DC  (MUST be loaded before match) -----------------
set_svf $SVF_FILE
# ---- 1b. Elaboration message filter (sec 4.2 fix is in $RTL_DIR) ------------
set_mismatch_message_filter -warn FMR_ELAB-147
# ---- 2. Reference = golden (v9-corrected) RTL  (container "r") ---------------
read_sverilog -r -libname WORK [glob $RTL_DIR/*.sv]
read_verilog  -r -libname WORK [glob $RTL_DIR/*.v]
set_top r:/WORK/$DESIGN
# ---- 3. Implementation = SKY130 gate netlist + tech .db  (container "i") -----
read_db $DB_DIR/${CELL_LIB}.db
read_verilog -i -netlist -libname WORK $NETLIST
set_top i:/WORK/$DESIGN
# ---- 4. Match ---------------------------------------------------------------
match
redirect $OUT_DIR/${RPTTAG}_unmatched.rpt {report_unmatched_points}
# ---- 5. Verify --------------------------------------------------------------
verify
redirect $OUT_DIR/${RPTTAG}_verify.rpt  {report_status}
redirect $OUT_DIR/${RPTTAG}_failing.rpt {report_failing_points}
echo "=== Formality (SKY130) done: see $OUT_DIR/${RPTTAG}_verify.rpt ==="
################################################################################
# NOT VERIFIED -> report_failing_points / report_unmatched_points / diagnose.
# Reference RTL is identical to SAED14/SG13G2, so any NEW failing/unmatched point
# points at the SKY130 library or its DC mapping, NOT the RTL. Compare against
# mcmm_10mhz_*.rpt (SAED14) / mcmm_sg13g2_10mhz_*.rpt to isolate.
################################################################################