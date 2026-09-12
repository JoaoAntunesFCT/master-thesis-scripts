# TREX1 - Digital Baseband Chain (Master's Thesis)

This repository holds the source files developed for a Master's thesis on a
digital GMSK receiver chain (**TREX1**, Gen 1 specification, 62.5 kBaud
symbol rate): IQ imbalance correction, digital down-conversion, symbol
synchronization, GMSK demodulation, and packet-level error detection/
correction, developed and cross-checked in MATLAB and implemented in
Verilog/SystemVerilog RTL.

The receiver was brought up and validated on a Nexys A7-100T (Artix-7) FPGA,
and is separately targeted for digital synthesis (Design Compiler, SAED14 /
Sky130 / IHP130 PDKs) for the ASIC-oriented part of the thesis. The design
was originally dimensioned assuming one ADC sample per clock edge at
100 MHz; it was later discovered that the ADC actually delivers 10 MS/s (the
Nexys A7's 100 MHz board oscillator had been mistaken for the ADC sample
rate). The chain was re-clocked to 10 MHz to match — **this corrected
10 MHz / decimation-10 configuration is the one carried into both the final
full-chain FPGA bring-up and the ASIC synthesis flow**; the original
100 MHz / decimation-12 configuration survives only in the early, per-block
FPGA validation and as a comparison baseline. See
[Status & validation](#status--validation) below for exactly what has been
verified where.

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
│   │   ├-- trex1_farrow.v                     # RTL: cubic Farrow interpolator (evaluated, not the one carried forward — see note below)
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


## Block descriptions

| Block | RTL | Description |
|---|---|---|
| ADC front-end | `adc_format_aligner.v` | Aligns/sign-extends the raw ADC bus for a configurable ADC resolution (7–10 bit). |
| IQ corrector | `iq_corrector_ll_lms.sv` | Leaky-integrator DC blocker + adaptive log-log LMS phase/gain imbalance correction, with a gear-shifted (coarse → tracking) step size and an integrate-and-dump fault detector. |
| DDC | `ddc_frontend_top.v`, `ddc_nco_cmix.v`, `ddc_fs4_mixer.v`, `cic_decimator_4th_order.v`, `fir_csd_filter.v` | 24-bit NCO + complex mixer (selectable vs. a fixed-Fs/4 mixer), 4th-order CIC decimator, and a compensating CSD-encoded FIR channel filter. |
| Sync | `trex1_sync_hw_top.v`, `trex1_ff_agc.v`, `trex1_cfo_top.v`, `trex1_cfo_derotate.v`, `trex1_blue_autocorr.v`, `trex1_str_top.v` | Feed-forward AGC (windowed power estimate, coarse power-of-two gain steps), CFO estimation (lag-1 coarse autocorrelation, lag-1-symbol BLUE fine estimator) and CORDIC-based derotation, and a self-contained interpolating Gardner symbol-timing-recovery loop (linear interpolation). |
| GMSK demodulator | `trex1_gmsk_demod.v` | Cross-product (differential) frequency discriminator with a hard-decision slicer. |
| Packet engine | `trex1_packet_engine_top.v`, `trex1_pe_datapath.v`, `syndrome_lut.v` | PN9 de-whitening, bit-serial CRC-16, and single-bit error correction via a syndrome lookup table. |
| Complete chain | `trex1_rx_frontend_top.v` + FPGA bring-up harness | Top-level integration of every block above, plus the FPGA test wrapper and ILA stimulus playback used for hardware bring-up. In the latest full-chain capture the packet engine's `pe_enable` is held low, so the I/Q corrector → DDC → sync → GMSK discriminator path is exercised end-to-end on hardware while the packet engine itself is verified separately at block level. |

## Digital synthesis & verification

`Digital_Synthesis/` targets the same RTL top (`trex1_rx_frontend_top`)
across three ASIC PDKs — a generic/SAED14 educational reference, SkyWater
Sky130, and IHP SG13G2 (130 nm) — using a common flow, at the corrected
10 MHz (100 ns period) rate:

- **`synthesis/`** — Design Compiler multicorner synthesis scripts, one per
  PDK. All three synthesize the same golden RTL and close setup/hold with
  zero negative slack; formal equivalence compare-point counts land in the
  same ~19,1xx range (19,112 / 19,112 / 19,118), with the small delta
  attributable to library/mapping differences rather than the RTL itself.
- **`verification/`** — Formality RTL-vs-gate equivalence checking, one
  script per PDK, using DC's SVF guidance to reconcile synthesis-introduced
  register merges/inversions. As the scripts themselves note, equivalence
  proves netlist == RTL; it does **not** prove that rate-dependent constants
  (CIC output shift, NCO `fcw`, decimation rate) are the functionally
  *correct* values for the target clock — that's covered separately by
  simulation (the `tb_rx_chain_model.m` cross-check and the 10 MS/s
  functional regression), not by equivalence checking.
- **`constraints/`** — `baseband.sdc` (Design Compiler timing: 10 MHz,
  multicycle exceptions, I/O delays) and `baseband.sgdc` (SpyGlass CDC/RDC
  clock-and-reset facts).
- **`waivers/`** — SpyGlass lint and CDC rule waivers, each with a written
  justification for why the flagged pattern is intentional/safe.

> **Known constraint inconsistency:** `baseband.sdc`'s header states it was
> updated to a 10 MHz / 100 ns clock period and that this is "numerically
> identical" to `baseband.sgdc`'s definition. As currently committed,
> `baseband.sgdc` still defines `clock -name clk -period 10.000` (i.e.
> 10 ns / 100 MHz) — it was not actually updated to match. SpyGlass CDC
> runs against the current `baseband.sgdc` are therefore checking the
> 100 MHz clock definition, not 10 MHz. Worth reconciling before relying on
> a SpyGlass CDC sign-off for the 10 MHz configuration.

## Schematics

`Schematics/` holds the Vivado schematic PDFs for each block across the
three implementation phases — elaboration, synthesis, and implementation —
mirroring the block numbering used in `FPGA/`. These are the full-resolution
originals: the copies embedded in the thesis PDF are cropped to their
content and scaled to fit the page format, so the versions here are the
ones to use for closely inspecting any specific net or cell. There is no
schematic subfolder for `01_adc_frontend`, since that block was not given
its own schematic annex in the thesis.

## MATLAB models

- **`rx_chain_model.m`** — floating-point behavioural model of the full
  chain, ported directly from the RTL (exact FIR/CIC scaling, exact PN9/
  CRC-16 polynomials, the full syndrome LUT, and the IQ corrector's DC-
  blocker silence-squelch fix). See the file header for the documented
  scope: double-precision arithmetic, multi-cycle pipeline latencies
  collapsed to their algorithmic equivalent, and two RTL bit-slice quirks
  (the DDC→sync width truncation and the CIC's fixed output shift)
  reproduced exactly rather than approximated, since those materially
  affect the signal's shape, not just its timing.
- **`tb_rx_chain_model.m`** — builds a continuous-tone, I/Q-imbalance-
  injected stimulus (mirroring the FPGA test wrapper's calibration bench)
  and runs it through both:
  - the **100 MHz / decimation-12 configuration** (the original,
    pre-correction assumption, used for early per-block validation), and
  - the **10 MHz / decimation-10 configuration** (the corrected rate,
    carried into the final full-chain bring-up and the ASIC flow),
- producing two independent 5-figure sets (`matlab_*.png` and
  `matlab_10mhz_*.png`) for visual comparison against Vivado ILA captures
  and against each other.

Run with either MATLAB or GNU Octave (validated on Octave 8.4):

```matlab
tb_rx_chain_model
```

## Status & validation

| Configuration | Clock | Decimation | Validation |
|---|---|---|---|
| Per-block FPGA implementation (Nexys A7-100T) | 100 MHz debug clock | up to 12, block-specific (original, pre-correction assumption) | Hardware-validated per block via ILA/VIO captures, including the bring-up fixes (symbol-timing-recovery rewrite, packet-engine bit-rate gating, stimulus/ROM fixes, IQ-corrector DC-blocker fix). |
| Full-chain FPGA build (Nexys A7-100T) | 10 MHz (corrected) | 10 | Hardware-validated end-to-end: the I/Q corrector → DDC → sync → GMSK discriminator path produces a continuous, valid recovered-bit stream under the corrected clocking. The packet engine's `pe_enable` is held low in this capture, so it is not exercised end-to-end here; its correctness is established separately at block level. One integration item remains open: the packet engine's bit-counting window alignment against the stimulus ROM in the merged build. |
| ASIC synthesis target | 10 MHz | 10 | Synthesised (Design Compiler / SAED14 / Sky130 / IHP130); formally verified (Formality) against the same golden RTL across all three; cross-checked by a dedicated 10 MS/s functional simulation regression. Not yet placed-and-routed or taped out. |

The 10 MHz configuration is architecturally identical to the 100 MHz one
but numerically distinct (different decimation rate and calibration timing
constants). It is the one actually carried forward: the full-chain FPGA
bring-up and the ASIC synthesis target both use it, and the MATLAB model
under this configuration is a simulation cross-check for both, not merely
for the synthesis run in isolation.

## Requirements

- **MATLAB** R2018b+ (for `sgtitle`) or **GNU Octave** 6+
- **Xilinx Vivado** (FPGA implementation, tested on a Nexys A7-100T)
- **Synopsys Design Compiler** + **Sky130** / **IHP130** open PDKs (ASIC synthesis)
- **Synopsys Formality** (RTL-vs-gate equivalence checking)
- **Synopsys SpyGlass** (RTL lint and CDC sign-off)

If you reference this work, please cite the accompanying thesis
(citation details to be added on publication).
