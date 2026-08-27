# TREX1 — GMSK Receiver Chain (Master's Thesis)

This repository holds the source files developed for a Master's thesis on a
digital GMSK receiver chain (**TREX1**, Gen 1 specification, 62.5 kBaud
symbol rate): IQ imbalance correction, digital down-conversion, symbol
synchronization, GMSK demodulation, and packet-level error detection/
correction, developed and cross-checked in MATLAB and implemented in
Verilog/SystemVerilog RTL.

The receiver was brought up and validated on a Nexys A7-100T (Artix-7) FPGA
at 100 MHz, and is separately targeted for digital synthesis (Design
Compiler, Sky130 / IHP130 open PDKs) at 10 MHz for the ASIC-oriented part of
the thesis. **These are two distinct, independently-configured targets of
the same architecture** (different clock rate, different CIC decimation
factor) — see [Status & validation](#status--validation) below for exactly
what has been verified where.

## Repository structure

The `MATLAB/` and `FPGA/` folders mirror the same block breakdown, numbered
so the MATLAB model and its RTL counterpart for a given block sit in
correspondingly-named folders. A third folder, `Digital_Synthesis/`, holds
the ASIC synthesis and verification flow (Design Compiler, Formality,
SpyGlass) that consumes the RTL from `FPGA/07_complete_chain`.

```
.
├── MATLAB/
│   ├── 01_adc_frontend/
│   ├── 02_iq_corrector/
│   ├── 03_ddc/
│   ├── 04_sync/
│   ├── 05_gmsk_demod/
│   ├── 06_packet_engine/
│   └── 07_complete_chain/
│       ├── rx_chain_model.m         # full-chain behavioural model (all blocks)
│       └── tb_rx_chain_model.m      # testbench: 100 MHz + 10 MHz configs, plots
│
├── FPGA/
│   ├── 01_adc_frontend/
│   │   └── adc_format_aligner.v
│   ├── 02_iq_corrector/
│   │   └── iq_corrector_ll_lms.sv
│   ├── 03_ddc/
│   │   ├── ddc_frontend_top.v
│   │   ├── ddc_nco_cmix.v
│   │   ├── ddc_fs4_mixer.v
│   │   ├── cic_decimator_4th_order.v
│   │   └── fir_csd_filter.v
│   ├── 04_sync/
│   │   ├── trex1_sync_hw_top.v
│   │   ├── trex1_ff_agc.v
│   │   ├── trex1_cfo_top.v
│   │   ├── trex1_cfo_derotate.v
│   │   ├── trex1_blue_autocorr.v
│   │   └── trex1_str_top.v
│   ├── 05_gmsk_demod/
│   │   └── trex1_gmsk_demod.v
│   ├── 06_packet_engine/
│   │   ├── trex1_packet_engine_top.v
│   │   ├── trex1_pe_datapath.v
│   │   └── syndrome_lut.v
│   └── 07_complete_chain/
│       ├── trex1_rx_frontend_top.v            # RTL top: instantiates all blocks
│       ├── fpga_merged_test_wrapper.v         # FPGA bring-up / ILA test harness
│       ├── gmsk_rom_playback.v                # on-chip stimulus ROM playback
│       └── nexys_a7.xdc                       # FPGA constraints (100 MHz)
│
└── Digital_Synthesis/
    ├── constraints/
    │   ├── baseband.sdc                       # Design Compiler timing constraints (10 MHz)
    │   └── baseband.sgdc                      # SpyGlass CDC/RDC clock & reset facts
    ├── synthesis/
    │   ├── synth_trex1_multicorner.tcl        # DC multicorner synthesis (generic / SAED14 reference)
    │   ├── synth_trex1_multicorner_sky130.tcl # DC multicorner synthesis (SkyWater Sky130)
    │   └── synth_trex1_multicorner_ihp130.tcl # DC multicorner synthesis (IHP SG13G2 / 130 nm)
    ├── verification/
    │   ├── verify_trex1.tcl                   # Formality RTL-vs-gate equivalence (generic / SAED14)
    │   ├── verify_trex1_sky130.tcl            # Formality RTL-vs-gate equivalence (Sky130)
    │   └── verify_trex1_ihp130.tcl            # Formality RTL-vs-gate equivalence (IHP SG13G2)
    └── waivers/
        ├── lint_rtl_waivers.swl               # SpyGlass lint rule waivers
        └── cdc_waivers.swl                    # SpyGlass CDC waivers
```

## Block descriptions

| Block | RTL | Description |
|---|---|---|
| ADC front-end | `adc_format_aligner.v` | Aligns/sign-extends the raw ADC bus for a configurable ADC resolution (7–10 bit). |
| IQ corrector | `iq_corrector_ll_lms.sv` | Leaky-integrator DC blocker + adaptive log-log LMS phase/gain imbalance correction, with a gear-shifted (coarse → tracking) step size and an integrate-and-dump fault detector. |
| DDC | `ddc_frontend_top.v`, `ddc_nco_cmix.v`, `ddc_fs4_mixer.v`, `cic_decimator_4th_order.v`, `fir_csd_filter.v` | 24-bit NCO + complex mixer (selectable vs. a fixed-Fs/4 mixer), 4th-order CIC decimator, and a 73-tap symmetric linear-phase FIR channel filter. |
| Sync | `trex1_sync_hw_top.v`, `trex1_ff_agc.v`, `trex1_cfo_top.v`, `trex1_cfo_derotate.v`, `trex1_blue_autocorr.v`, `trex1_str_top.v` | Feed-forward AGC (windowed power estimate, coarse power-of-two gain steps), CFO estimation (lag-N autocorrelation) and CORDIC-based derotation, and a pipelined interpolating Gardner symbol-timing-recovery loop. |
| GMSK demodulator | `trex1_gmsk_demod.v` | Cross-product (differential) frequency discriminator with a hard-decision slicer. |
| Packet engine | `trex1_packet_engine_top.v`, `trex1_pe_datapath.v`, `syndrome_lut.v` | PN9 de-whitening, bit-serial CRC-16, and single-bit error correction via a 272-entry syndrome lookup table. |
| Complete chain | `trex1_rx_frontend_top.v` + FPGA bring-up harness | Top-level integration of every block above, plus the FPGA test wrapper and ILA stimulus playback used for hardware bring-up. |

## Digital synthesis & verification

`Digital_Synthesis/` targets the same RTL top (`trex1_rx_frontend_top`)
across three ASIC PDKs — a generic/SAED14 reference, SkyWater Sky130, and
IHP SG13G2 (130 nm) — using a common flow:

- **`synthesis/`** — Design Compiler multicorner synthesis scripts, one per
  PDK. All three synthesize the same golden RTL; per the scripts' own
  comments, the three implementations are expected to land on the same
  compare-point count (~19,1xx), with any delta attributable to library/
  mapping differences rather than the RTL itself.
- **`verification/`** — Formality RTL-vs-gate equivalence checking, one
  script per PDK, using DC's SVF guidance to reconcile synthesis-introduced
  register merges/inversions. As the scripts themselves note, equivalence
  proves netlist == RTL; it does **not** prove that rate-dependent constants
  (CIC output shift, NCO `fcw`, decimation rate) are the functionally
  *correct* values for the target clock — that's covered separately by
  simulation (the `tb_rx_chain_model.m` cross-check), not by equivalence
  checking.
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
  - the **100 MHz / decimation-12 FPGA configuration**, and
  - the **10 MHz / decimation-10 ASIC configuration**,

  producing two independent 5-figure sets (`matlab_*.png` and
  `matlab_10mhz_*.png`) for visual comparison against Vivado ILA captures
  and against each other.

Run with either MATLAB or GNU Octave (validated on Octave 8.4):

```matlab
tb_rx_chain_model
```

## Status & validation

| Configuration | Clock | Decimation | Validation |
|---|---|---|---|
| FPGA (Nexys A7-100T) | 100 MHz | 12 | Hardware-validated: bring-up, debugging, and fixes (symbol-timing-recovery rewrite, packet-engine bit-rate gating, stimulus/ROM fixes, IQ-corrector DC-blocker fix) confirmed against real Vivado ILA captures. |
| ASIC synthesis target | 10 MHz | 10 | Synthesized (Design Compiler / Sky130 / IHP130); cross-checked in MATLAB against the same algorithm, **not yet hardware-validated**. |

The 10 MHz configuration is architecturally identical to the 100 MHz one
but numerically distinct (different decimation rate and calibration
timing constants) — treat its MATLAB output as a simulation cross-check
for the synthesis run, not as independently hardware-proven the way the
100 MHz results are.

## Requirements

- **MATLAB** R2018b+ (for `sgtitle`) or **GNU Octave** 6+
- **Xilinx Vivado** (FPGA implementation, tested on a Nexys A7-100T)
- **Synopsys Design Compiler** + **Sky130** / **IHP130** open PDKs (ASIC synthesis)
- **Synopsys Formality** (RTL-vs-gate equivalence checking)
- **Synopsys SpyGlass** (RTL lint and CDC sign-off)

## License

_TBD._

## Citation

If you reference this work, please cite the accompanying thesis
(citation details to be added on publication).
