##################################################################################
# Company:        NOVA SST
# Engineer:       Joao Reis Antunes
# 
# Create Date:    07/2026 (mm-yyyy)
# Module Name:    verify_trex1.tcl
# Project Name:   TREX1 Digital Baseband Chain
# Target Devices: SAED14 14nm (verifies the SAED14 multi-corner netlist against the golden RTL)
# Description:    Formality RTL-vs-gate equivalence check: proves the SAED14 Design Compiler netlist is logically equivalent to the golden RTL, using DC's SVF guidance to reconcile synthesis-time register merges/inversions.
# 
# Dependencies:   Requires the netlist and .svf produced by synth_trex1_multicorner.tcl with the same RUN_TAG, plus the golden RTL in RTL_DIR (the same sources DC read).
# 
##################################################################################

################################################################################
# verify_trex1.tcl  --  Formality RTL-vs-gate equivalence check (Phase 3)
#
# Proves the DC gate-level netlist is logically equivalent to the golden
# (post-Phase-1) RTL, using DC's SVF guidance to reconcile the register
# merges / constant removals / sequential inversions from synthesis.
#
# Run:   fm_shell -f verify_trex1.tcl        (batch)
#   or:  source verify_trex1.tcl             (inside fm_shell / Formality GUI)
################################################################################
# ---- 0. Knobs ---------------------------------------------------------------
set DESIGN   trex1_rx_frontend_top
set RTL_DIR  /home/trex1u06/SNPS_workspace/TREX1
set SYN_DIR  /home/trex1u06/SNPS_workspace/synthesis
set LIB_DIR  /home/trex1u06/SNPS_workspace/edk/lib/stdcell_rvt/db_nldm
set CORNER   tt0p8v25c   ;# tech-cell library for FM (any corner's .db defines the same cells)
set NLTAG    mcmm        ;# netlist/SVF to verify: "mcmm" (multi-corner) or a corner name (single-corner)
set RUN_TAG  _10mhz      ;# MUST match the synth RUN_TAG -> picks the 10 MHz netlist+SVF,
                         ;#   not the 100 MHz baseline. Set "" for the old files.
set NETLIST  $SYN_DIR/netlist/${DESIGN}${RUN_TAG}_${NLTAG}.mapped.v
set SVF_FILE $SYN_DIR/netlist/${DESIGN}${RUN_TAG}_${NLTAG}.svf
set OUT_DIR  /home/trex1u06/SNPS_workspace/formality/reports
set RPTTAG   ${NLTAG}${RUN_TAG}      ;# report stem: mcmm_10mhz_*
file mkdir $OUT_DIR
# CRITICAL: the SVF and the netlist must come from the SAME compile. Both now
# carry ${RUN_TAG}; if only one does, the merges/inversions won't reconcile and
# you'll get spurious unmatched points. (echo below to eyeball before match.)
echo "FM inputs:  netlist = $NETLIST"
echo "            svf     = $SVF_FILE"
# ---- 1. SVF guidance from DC  (MUST be loaded before match) -----------------
# This is what makes the merges/inversions/constant-prop from compile_ultra
# resolve automatically instead of showing up as failing/unmatched points.
set_svf $SVF_FILE
# ---- 1b. Elaboration message filter -----------------------------------------
# FMR_ELAB-147 at trex1_packet_engine_top.v:110 was the sec 4.2 unsigned-
# underflow part-select; the bound-guard fix (error_idx <= 9'd255) is IN the
# current $RTL_DIR RTL, so this filter should now be a NO-OP. Kept defensively.
# If it actually fires this run, that means the sec 4.2 fix is NOT in $RTL_DIR
# -- stop and check the RTL rather than silencing a real mismatch.
set_mismatch_message_filter -warn FMR_ELAB-147
# ---- 2. Reference = golden (v9-corrected) RTL  (container "r") ---------------
# Same files DC read; hdlin_sverilog_std=2009 to match DC's elaboration.
read_sverilog -r -libname WORK [glob $RTL_DIR/*.sv]
read_verilog  -r -libname WORK [glob $RTL_DIR/*.v]
set_top r:/WORK/$DESIGN
# ---- 3. Implementation = DC gate netlist + tech library  (container "i") ----
read_db $LIB_DIR/saed14rvt_${CORNER}.db
read_verilog -i -netlist -libname WORK $NETLIST
set_top i:/WORK/$DESIGN
# ---- 4. Match compare points ------------------------------------------------
# Expected total this run ~19,112 points (18,412 DFFs from qor + ~700 ports),
# DOWN from the 100 MHz 19,139 -- the v9 calib counters narrowed by ~27 flops.
# A different total than the baseline is correct here, not a regression.
match
redirect $OUT_DIR/${RPTTAG}_unmatched.rpt {report_unmatched_points}
# ---- 5. Verify --------------------------------------------------------------
verify
redirect $OUT_DIR/${RPTTAG}_verify.rpt  {report_status}
# Auto-capture failing points so a NOT VERIFIED result is already diagnosable.
redirect $OUT_DIR/${RPTTAG}_failing.rpt {report_failing_points}
echo "=== Formality done: see $OUT_DIR/${RPTTAG}_verify.rpt ==="
################################################################################
# IF 'verify' returns NOT VERIFIED, do NOT assume the netlist is wrong yet --
# it's usually unmatched points from optimization. Diagnose with:
#
#   report_failing_points     ;# the actual mismatches (also auto-saved above)
#   report_unmatched_points   ;# points FM couldn't pair up
#   diagnose                  ;# FM's guided root-cause
#   analyze_points -all       ;# suggestions (name-based match, etc.)
#
# Common, benign causes here (expected from your compile log):
#   - Constant/merged registers (OPT-1206/1215): should be covered by the SVF.
#     If they show as unmatched, confirm the SVF actually loaded (echo above).
#   - The 2-FF rst_n synchronizer: dont_touch'd, so it stays 1:1 -- fine.
#   - Trimmed reserved/debug regs (pn9_state, dbg_*): may show as unmatched
#     ref points with no impl counterpart -> verify they're genuinely dead
#     (unconnected outputs) before waiving.
################################################################################