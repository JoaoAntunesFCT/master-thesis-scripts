# TREX1 - Digital Baseband Chain (Master's Thesis)

This repository holds the source files developed for a Master's thesis on a
digital GMSK receiver chain (**TREX1**, Gen 1 specification, 62.5 kBaud
symbol rate): IQ imbalance correction, digital down-conversion, symbol
synchronization, GMSK demodulation, and packet-level error detection/
correction, developed and cross-checked in MATLAB and implemented in
Verilog/SystemVerilog RTL.

The receiver was brought up and validated on a Nexys A7-100T (Artix-7) FPGA, and is separately targeted for digital synthesis (Design Compiler, SAED14 / Sky130 / IHP130 PDKs) for the ASIC-oriented part of the thesis. The design was first brought up on the FPGA at the board's native 100 MHz debug clock, taking one ADC sample per clock edge as a simplifying assumption for early validation, since the ADC's true throughput is 10 MS/s. Once FPGA validation was complete, the chain was re-clocked to 10 MHz to match the ADC — a low-risk step, since it only meant slowing the design down rather than tightening its timing. This 10 MHz / decimation-10 configuration is the one carried into both the final full-chain FPGA bring-up and the ASIC synthesis flow, while the earlier 100 MHz / decimation-12 configuration survives only as the early, per-block FPGA bring-up baseline.

## Repository structure

```
.
├-- Matlab/
│   ├-- 1_iq/
│   │   ├-- iq_corrector_model.m               # I/Q imbalance corrector behavioural model
│   │   └-- tb_iq_corrector.m                  # testbench
│   ├-- 1_iq_preparation/
│   │   ├-- iq_corrector_universal.m           # early/general-form corrector used to explore the design space
│   │   ├-- tb_grind_search_excel.m            # parameter sweep, results exported to Excel
│   │   └-- visualize_results.m                # sweep-result plotting
│   ├-- 2_ddc/
│   │   ├-- ddc_receiver_model.m               # DDC behavioural model
│   │   ├-- ddc_testbench.m                    # testbench
│   ├-- 3_sync/
│   │   ├-- sync_model.m                       # AGC + CFO + symbol-timing-recovery behavioural model
│   │   ├-- tb_trex1_sync_hdl.m                # testbench
│   ├-- 4_gmsk/
│   │   ├-- gmsk_demod_model.m                 # GMSK demodulator behavioural model
│   │   ├-- tb_trex1_gmsk_hdl.m                # testbench
│   ├-- 4_gmsk_preparation/
│   │   ├-- gmsk_eye_diagram_multi_bt.m        # exploratory eye-diagram plots across BT values
│   │   └-- gmsk_psd_multi_bt.m                # exploratory PSD plots across BT values
│   ├-- 5_pe/
│   │   ├-- pe_engine_model.m                  # packet-engine behavioural model
│   │   ├-- tb_trex1_pe_hdl.m                  # testbench
│   └-- 6_full_chain/
│       ├-- rx_chain_model.m                   # full-chain behavioural model (all blocks)
│       ├-- rx_chain_testbench.m               # testbench: 100 MHz + 10 MHz configs, plots
│
├-- Fpga/
│   ├-- 1_iq/
│   │   ├-- iq_corrector_ll_lms.sv             # RTL: I/Q imbalance corrector
│   │   └-- fpga_top_tester.sv                 # standalone FPGA test harness for this block
│   ├-- 2_ddc/
│   │   ├-- adc_format_aligner.v               # RTL: ADC bus alignment/sign-extension
│   │   ├-- ddc_nco_cmix.v                     # RTL: NCO + complex mixer
│   │   ├-- ddc_fs4_mixer.v                    # RTL: fixed-Fs/4 mixer alternative
│   │   ├-- cic_decimator_4th_order.v          # RTL: 4th-order CIC decimator
│   │   ├-- fir_csd_filter.v                   # RTL: CSD-encoded compensating FIR
│   │   ├-- ddc_frontend_top.v                 # RTL: DDC top, instantiates the above
│   │   └-- fpga_ddc_test_wrapper.v            # standalone FPGA test harness for this block
│   ├-- 3_sync/
│   │   ├-- trex1_ff_agc.v                     # RTL: feed-forward AGC
│   │   ├-- trex1_cfo_top.v                    # RTL: CFO estimation top
│   │   ├-- trex1_blue_autocorr.v              # RTL: lag-1 autocorrelation + BLUE fine CFO estimator
│   │   ├-- trex1_gardner.v                    # RTL: Gardner timing-error detector (linear interpolation)
│   │   ├-- trex1_farrow.v                     # RTL: cubic Farrow interpolator (evaluated, not the one carried forward - see note below)
│   │   ├-- trex1_str_top.v                    # RTL: symbol-timing-recovery loop top
│   │   ├-- trex1_sync_hw_top.v                # RTL: sync-chain top, instantiates the above
│   │   ├-- nexys_a7_test_top.v                # standalone FPGA test harness for this block
│   │   ├-- tb_trex1_sync_chain.v              # testbench
│   │   ├-- cosine_sine.m                      # MATLAB helper: NCO/CORDIC reference table generation
│   │   └-- stimulus_data.coe                  # ROM initialization data for FPGA stimulus playback
│   ├-- 4_gmsk/
│   │   ├-- trex1_gmsk_demod.v                 # RTL: GMSK discriminator + slicer
│   │   ├-- top_nexys_a7_gmsk.v                # standalone FPGA test harness for this block
│   │   └-- tb_trex1_gmsk_demod.v              # testbench
│   ├-- 5_pe/
│   │   ├-- trex1_pe_datapath.v                # RTL: de-whitening, CRC-16, error correction datapath
│   │   ├-- syndrome_lut.v                     # RTL: single-bit-error syndrome lookup table
│   │   ├-- trex1_packet_engine_top.v          # RTL: packet-engine top
│   │   ├-- nexys_pe_hw_tester.v               # standalone FPGA test harness for this block
│   │   ├-- tb_trex1_packet_engine_top.v       # testbench (top level)
│   │   └-- tb_trex1_pe_datapath.v             # testbench (datapath level)
│   └-- 6_full_chain/
│       ├-- trex1_rx_frontend_top.v            # RTL top: instantiates every block below
│       ├-- adc_format_aligner.v
│       ├-- iq_corrector_ll_lms.sv
│       ├-- ddc_nco_cmix.v
│       ├-- ddc_fs4_mixer.v
│       ├-- cic_decimator_4th_order.v
│       ├-- fir_csd_filter.v
│       ├-- ddc_frontend_top.v
│       ├-- trex1_ff_agc.v
│       ├-- trex1_cfo_top.v
│       ├-- trex1_cfo_derotate.v
│       ├-- trex1_blue_autocorr.v
│       ├-- trex1_gardner.v
│       ├-- trex1_farrow.v
│       ├-- trex1_str_top.v
│       ├-- trex1_sync_hw_top.v
│       ├-- trex1_gmsk_demod.v
│       ├-- trex1_pe_datapath.v
│       ├-- syndrome_lut.v
│       ├-- trex1_packet_engine_top.v
│       ├-- fpga_merged_test_wrapper.v         # FPGA bring-up / ILA test harness
│       └-- gmsk_rom_playback.v                # on-chip stimulus ROM playback
│
├-- Digital Synthesis/
│   ├-- constraints/
│   │   ├-- baseband.sdc                       # Design Compiler timing constraints (10 MHz)
│   │   └-- baseband.sgdc                      # SpyGlass CDC/RDC clock & reset facts
│   ├-- synthesis/
│   │   ├-- synth_trex1_multicorner.tcl        # DC multicorner synthesis (generic / SAED14 reference)
│   │   ├-- synth_trex1_multicorner_sky130.tcl # DC multicorner synthesis (SkyWater Sky130)
│   │   └-- synth_trex1_multicorner_ihp130.tcl # DC multicorner synthesis (IHP SG13G2 / 130 nm)
│   ├-- verification/
│   │   ├-- verify_trex1.tcl                   # Formality RTL-vs-gate equivalence (generic / SAED14)
│   │   ├-- verify_trex1_sky130.tcl            # Formality RTL-vs-gate equivalence (Sky130)
│   │   └-- verify_trex1_ihp130.tcl            # Formality RTL-vs-gate equivalence (IHP SG13G2)
│   └-- waivers/
│       ├-- lint_rtl_waivers.swl               # SpyGlass lint rule waivers
│       └-- cdc_waivers.swl                    # SpyGlass CDC waivers
│
└-- Schematics/
    ├-- 1_iq/
    │   ├-- sch_elaboration.pdf
    │   ├-- sch_synthesis.pdf
    │   └-- sch_implementation.pdf
    ├-- 2_ddc/
    │   ├-- sch_elaboration.pdf
    │   ├-- sch_synthesis.pdf         
    │   └-- sch_implementation.pdf
    ├-- 3_sync/
    │   ├-- sch_elaboration.pdf
    │   ├-- sch_synthesis.pdf
    │   └-- sch_implementation.pdf
    ├-- 4_gmsk/
    │   ├-- sch_elaboration.pdf
    │   ├-- sch_synthesis.pdf
    │   └-- sch_implementation.pdf
    ├-- 5_pe/
    │   ├-- sch_elaboration.pdf
    │   ├-- sch_synthesis.pdf
    │   └-- sch_implementation.pdf
    └-- 6_full_chain/
        ├-- sch_elaboration.pdf
        ├-- sch_synthesis.pdf
        └-- sch_implementation.pdf
```

## Requirements

- **MATLAB** R2018b+ (for `sgtitle`) or **GNU Octave** 6+
- **Xilinx Vivado** (FPGA implementation, tested on a Nexys A7-100T)
- **Synopsys Design Compiler** + **Sky130** / **IHP130** open PDKs (ASIC synthesis)
- **Synopsys Formality** (RTL-vs-gate equivalence checking)
- **Synopsys SpyGlass** (RTL lint and CDC sign-off)

If you reference this work, please cite the accompanying thesis
(citation details to be added on publication).
