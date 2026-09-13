##################################################################################
# Company:        NOVA SST
# Engineer:       Joao Reis Antunes
# 
# Create Date:    07/2026 (mm-yyyy)
# Module Name:    verify_trex1_ihp130.tcl
# Project Name:   TREX1 Digital Baseband Chain
# Target Devices: IHP SG13G2 (130 nm) (verifies the SG13G2 multi-corner netlist against the golden RTL) 
# Description:    Formality RTL-vs-gate equivalence check, IHP SG13G2 node. Same golden reference RTL as the SAED14 check, so the compare-point total should match; any new mismatch points at the SG13G2 library/mapping, not the RTL.
# 
# Dependencies:   Requires the netlist and .svf produced by synth_trex1_multicorner_ihp130.tcl with the same RUN_TAG, plus the golden RTL in RTL_DIR and the precompiled SG13G2 .db in DB_DIR.
# 
##################################################################################

################################################################################
# verify_trex1_ihp130.tcl  --  Formality RTL-vs-gate equivalence (Phase 3)
#                              IHP SG13G2 (130 nm)  [plan v12, sec 9]
#
# Uses precompiled .db (found in the PDK tree; this install can't make/read
# Liberty -- LCSH-3/DB-1). read_db works fine here. The golden RTL reference is
# the SAME as SAED14 -> compare-point total should match (~19,112).
#
# Run AFTER a REAL (mapped) SG13G2 synth netlist exists:
#   fm_shell -f verify_trex1_ihp130.tcl        (batch)
#   source  verify_trex1_ihp130.tcl            (inside fm_shell / Formality GUI)
################################################################################
# ---- 0. Knobs ---------------------------------------------------------------
set DESIGN   trex1_rx_frontend_top
set RTL_DIR  /home/trex1u06/SNPS_workspace/TREX1
set SYN_DIR  /home/trex1u06/SNPS_workspace/synthesis
# Dir holding the precompiled SG13G2 .db (same as the synth script's DB_DIR).
set DB_DIR   /home/trex1u06/SNPS_workspace/TREX1/opensource_libs
set CELL_LIB sg13g2_stdcell_typ_1p20V_25C   ;# any corner defines the same cells
set NLTAG    mcmm            ;# multi-corner
set RUN_TAG  _sg13g2_10mhz   ;# MUST match the IHP synth RUN_TAG
set NETLIST  $SYN_DIR/netlist/${DESIGN}${RUN_TAG}_${NLTAG}.mapped.v
set SVF_FILE $SYN_DIR/netlist/${DESIGN}${RUN_TAG}_${NLTAG}.svf
set OUT_DIR  /home/trex1u06/SNPS_workspace/formality/reports
set RPTTAG   ${NLTAG}${RUN_TAG}      ;# report stem: mcmm_sg13g2_10mhz_*
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
# ---- 3. Implementation = SG13G2 gate netlist + tech .db  (container "i") -----
read_db $DB_DIR/${CELL_LIB}.db
read_verilog -i -netlist -libname WORK $NETLIST
set_top i:/WORK/$DESIGN
# ---- 4. Match ---------------------------------------------------------------
# Expect ~19,112 points -- SAME as SAED14 (same reference RTL).
match
redirect $OUT_DIR/${RPTTAG}_unmatched.rpt {report_unmatched_points}
# ---- 5. Verify --------------------------------------------------------------
verify
redirect $OUT_DIR/${RPTTAG}_verify.rpt  {report_status}
redirect $OUT_DIR/${RPTTAG}_failing.rpt {report_failing_points}
echo "=== Formality (SG13G2) done: see $OUT_DIR/${RPTTAG}_verify.rpt ==="
################################################################################
# NOT VERIFIED -> report_failing_points / report_unmatched_points / diagnose.
# Because the reference RTL is identical to SAED14, any NEW failing/unmatched
# point that did NOT appear in SAED14 (mcmm_10mhz_*.rpt) points at the SG13G2
# library or its DC mapping, NOT the RTL.
################################################################################