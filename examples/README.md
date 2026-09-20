# Examples

All 73 example files analyse cleanly under `xvlog` and are latch-checked by
yosys, and every one is exercised by the testbenches in [`tb/`](tb/). `make`
from the repository root runs everything.

One module per file, named after the module. XSIM has no library-search switch,
so `make` analyses every source explicitly (packages first), but the convention
still pays off for readability and for tools that do search.

Simulation is **XSIM** (Vivado Simulator) throughout — 4-state, full SVA,
`shortreal`, clocking blocks. Formal proofs are **SymbiYosys**; see
[`../formal/`](../formal/) and
[docs/25](../docs/25-formal-verification-with-sby.md), which also lists the ten
modules Yosys's frontend cannot read.

---

## `rtl/` — synthesizable building blocks

### Sequential basics

| File | What it shows |
|---|---|
| [counter.sv](rtl/counter.sv) | up/down counter with load and wrap flags; the `always_comb`/`always_ff` split with a hold-by-default next-state |
| [shift_register.sv](rtl/shift_register.sv) | PISO/SIPO; a shift written as a concatenation |
| [reset_sync.sv](rtl/reset_sync.sv) | async assert, **synchronous release** — why a reset tree needs this |

### Clock domain crossing

| File | What it shows |
|---|---|
| [cdc_bit.sv](rtl/cdc_bit.sv) | 2-flop level synchronizer |
| [cdc_pulse.sv](rtl/cdc_pulse.sv) | toggle method: a single-cycle pulse crosses safely |
| [cdc_handshake.sv](rtl/cdc_handshake.sv) | 4-phase handshake for a multi-bit bus — only 1-bit signals actually cross |
| [async_fifo.sv](rtl/async_fifo.sv) | dual-clock FIFO with Gray pointers. Also documents the combinational loop you get if the full flag is *not* registered |

### Flow control

| File | What it shows |
|---|---|
| [sync_fifo.sv](rtl/sync_fifo.sv) | single-clock FIFO; the extra-MSB pointer trick for full-vs-empty |
| [skid_buffer.sv](rtl/skid_buffer.sv) | registers a valid/ready handshake **in both directions** with no throughput loss — the standard pipeline stage |

### Arbitration and encoding

| File | What it shows |
|---|---|
| [arb_fixed.sv](rtl/arb_fixed.sv) | `r & (~r + 1)` — a whole priority arbiter in one expression |
| [arb_round_robin.sv](rtl/arb_round_robin.sv) | masked-priority round robin: two priority arbiters and a mux |
| [arb_weighted.sv](rtl/arb_weighted.sv) | weighted round robin with per-agent credits |
| [priority_encoder.sv](rtl/priority_encoder.sv) | a `for` loop that unrolls into a priority mux chain |
| [onehot_decoder.sv](rtl/onehot_decoder.sv) | index to one-hot |
| [lzc.sv](rtl/lzc.sv) | leading-zero count — the critical block in an FP normalizer |
| [popcount.sv](rtl/popcount.sv) | population count via `$countones` |
| [gray_codec.sv](rtl/gray_codec.sv) | binary↔Gray; the prefix-XOR decode |
| [gray_counter.sv](rtl/gray_counter.sv) | Gray counter for a CDC pointer, with the single-bit-change assertion |

### Sequence generation

| File | What it shows |
|---|---|
| [lfsr_galois.sv](rtl/lfsr_galois.sv) | Galois form: one XOR on the critical path regardless of tap count |
| [lfsr_fibonacci.sv](rtl/lfsr_fibonacci.sv) | Fibonacci form, for comparison |
| [crc_parallel.sv](rtl/crc_parallel.sv) | N bits per cycle; a `for` loop that unrolls a bit-serial CRC into an XOR network at elaboration |

### Memory

| File | What it shows |
|---|---|
| [ram_sp.sv](rtl/ram_sp.sv) | single-port, read-first — the inference template |
| [ram_sp_wf.sv](rtl/ram_sp_wf.sv) | single-port, write-first |
| [ram_sdp.sv](rtl/ram_sdp.sv) | simple dual-port |
| [ram_tdp.sv](rtl/ram_tdp.sv) | true dual-port, two clocks |
| [ram_be.sv](rtl/ram_be.sv) | byte enables via an indexed part-select |
| [regfile.sv](rtl/regfile.sv) | 2R1W with a write-through bypass and a hardwired zero register |

### State machines

| File | What it shows |
|---|---|
| [fsm_two_process.sv](rtl/fsm_two_process.sv) | registered state, combinational next-state and outputs |
| [fsm_one_process.sv](rtl/fsm_one_process.sv) | everything registered, assigned at transition time |
| [fsm_three_process.sv](rtl/fsm_three_process.sv) | registered outputs decoded from `next` — glitch-free **and** aligned |
| [fsm_onehot.sv](rtl/fsm_onehot.sv) | explicit one-hot with `unique case (1'b1)` |
| [fsm_safe.sv](rtl/fsm_safe.sv) | illegal-state recovery, and what happens without it |

The first four implement the same controller, so they can be compared directly
— and [fsm_tb.sv](tb/fsm_tb.sv) checks that three of them produce *identical*
waveforms, which is the point: the choice between them is about timing and
maintainability, not behaviour. See
[docs/26](../docs/26-fsm-coding-styles.md).

### Serial interfaces

| File | What it shows |
|---|---|
| [uart_tx.sv](rtl/uart_tx.sv) | 8N1 transmitter |
| [uart_rx.sv](rtl/uart_rx.sv) | 8N1 receiver: recovers the bit clock from the start edge and samples at each bit's **midpoint** |

### Pipelining and timing closure

| File | What it shows |
|---|---|
| [pipe_delay.sv](rtl/pipe_delay.sv) | parameterized N-cycle delay line — the latency-matching block, and the source of most pipeline bugs when it is missing. `LATENCY(0)` degenerates to a wire on purpose; `RESET(0)` keeps datapath flops out of the reset tree and retimable |
| [pipe_ctrl.sv](rtl/pipe_ctrl.sv) | valid propagation, global stall, and flush. Shows why `flush` must be tested **before** `en`, with the assertion that catches it |
| [adder_tree.sv](rtl/adder_tree.sv) | recursive balanced tree: depth `ceil(log2(N))` instead of `N-1`, handles non-power-of-two `N`, and `PIPE(1)` gives one balanced register per level for free |
| [csa_accumulator.sv](rtl/csa_accumulator.sv) | carry-save accumulation: two gate levels per accumulate **regardless of width**, because the carry is never propagated. The 3:2 compressor a Wallace tree is built from |
| [acc_interleaved.sv](rtl/acc_interleaved.sv) | breaking a feedback loop by interleaving — the general answer to "my accumulator's adder is too slow", since a loop cannot be pipelined |
| [fanout_replicate.sv](rtl/fanout_replicate.sv) | register replication for a high-fanout control signal, with the `dont_touch`/`preserve` attributes that stop synthesis merging the copies back |
| [operand_isolation.sv](rtl/operand_isolation.sv) | stop a wide datapath switching when its result is unused; hold-vs-zero modes and when each wins |

### Structural techniques

| File | What it shows |
|---|---|
| [bin2bcd.sv](rtl/bin2bcd.sv) | double dabble: binary to decimal with an adder and a shift per bit, no division. Why the magic number is 3 |
| [mul_const.sv](rtl/mul_const.sv) | multiply by a constant with no multiplier; CSD recoding done in the elaborator turns `×255` from 8 adders into 2 |
| [div_const.sv](rtl/div_const.sv) | divide by a constant via a reciprocal multiply — and the product-width trap that makes it silently return zeros |
| [sort_network.sv](rtl/sort_network.sv) | a fixed compare-exchange mesh: sorting with no control logic and no variable latency |
| [ring_counter.sv](rtl/ring_counter.sv) | one-hot counter with zero decode, and a self-correcting variant that recovers from any illegal state |
| [srl_delay.sv](rtl/srl_delay.sv) | a delay line that maps to one LUT per 16–32 stages — and the three conditions that silently forfeit it |
| [rom_table.sv](rtl/rom_table.sv) | a ROM whose contents are computed by a constant function at elaboration, so the derivation is the source |
| [useq.sv](rtl/useq.sv) | a microcoded sequencer: control as a table rather than a `case`. Also documents the wait-state polarity bug that let it run the whole protocol in six cycles |

### DSP

| File | What it shows |
|---|---|
| [mac_pipelined.sv](rtl/mac_pipelined.sv) | signed MAC shaped to map onto a hard DSP block; guard-bit budget with an assertion that checks it |
| [fir_systolic.sv](rtl/fir_systolic.sv) | transposed-form FIR: critical path is one multiply + one add regardless of tap count. Full-precision accumulation, rounded once at the output |
| [cordic_sincos.sv](rtl/cordic_sincos.sv) | sine/cosine with **no multiplier** — adds and shifts only. Tables generated from the documented formula; accurate to 1.1e-7 with 24 iterations |

---

## `arith/` — arithmetic

### Language demonstrations (runnable, self-checking)

| File | What it shows |
|---|---|
| [signedness_demo.sv](arith/signedness_demo.sv) | **every trap from [docs/17](../docs/17-signed-unsigned-arithmetic.md)**, as 40 assertions against the LRM. Prints each result so you can see the rule, not just trust it |
| [width_rules_tb.sv](arith/width_rules_tb.sv) | the two-pass width algorithm: `$bits` of every expression form, where a wide destination rescues an operand, and where it does not |

Both deliberately contain the width and signedness mismatches a linter is meant
to flag — with `lint_off` pragmas and a comment saying so, because the warnings
are the subject matter.

### Fixed point

| File | What it shows |
|---|---|
| [fixed_pkg.sv](arith/fixed_pkg.sv) | rescale, four rounding modes, saturation, guard-bit sizing, and `fx_from_real` — quantizing a `real` literal at **elaboration time** so synthesis only sees integers |
| [sat_add.sv](arith/sat_add.sv) | saturating signed add; the overflow test is `s[W] != s[W-1]` |
| [sat_narrow.sv](arith/sat_narrow.sv) | saturating width reduction; a value fits iff every discarded bit equals the kept sign bit |
| [requantize.sv](arith/requantize.sv) | round-half-to-even then saturate. Documents the signedness bug that made every negative output positive |

### Division

| File | What it shows |
|---|---|
| [div_restoring.sv](arith/div_restoring.sv) | multi-cycle shift-subtract divider; one adder shared between the compare and the subtract. Documents the off-by-one where `valid_o` led the data |
| [div_signed.sv](arith/div_signed.sv) | signed wrapper. Truncates toward zero, remainder takes the dividend's sign, and takes the magnitude in **unsigned** arithmetic so the most-negative input works |

### Floating point

| File | What it shows |
|---|---|
| [fp_pkg.sv](arith/fp_pkg.sv) | format descriptors down to FP8, all five RISC-V rounding modes as one `round_up` function, exception-flag struct |
| [fp_classify.sv](arith/fp_classify.sv) | decode into class + normalized fields; folds subnormals into the normal path |
| [fp_add.sv](arith/fp_add.sv) | IEEE 754 adder, parameterized over (E, M), full subnormal support, all five rounding modes. Explains why OR-ing the sticky into the LSB is sufficient for correct rounding with only three extra bits |
| [fp_mul.sv](arith/fp_mul.sv) | IEEE 754 multiplier. Pre-normalizes subnormal inputs; the exponent path is signed and wider, because `ea + eb - BIAS` at E bits wraps silently |

Both are **bit-exact against the host FPU** over 365,768 vectors. They are
parameterized, so the same source gives fp16, bf16, fp32, or FP8 — but only the
fp32 configuration is covered by the reference model in
[`tb/fp_tb.sv`](tb/fp_tb.sv).

---

## `tb/` — testbenches

| File | Tool | What it demonstrates |
|---|---|---|
| [fp_tb.sv](tb/fp_tb.sv) | XSIM | Using the host FPU as a golden reference via `shortreal`. Six stimulus phases, including the constrained close-exponent case that uniform random almost never reaches |
| [arith_tb.sv](tb/arith_tb.sv) | XSIM | Divider, saturation, CORDIC, FIR, and MAC, each against an independent reference |
| [fifo_tb.sv](tb/fifo_tb.sv) | XSIM | The **layered architecture** of [docs/16](../docs/16-verification-architecture.md): interface with clocking blocks, driver, passive monitor, queue scoreboard. Shows why a monitor needs its own all-input clocking block, and why a driver cannot trust a sampled flag |
| [async_fifo_tb.sv](tb/async_fifo_tb.sv) | XSIM | Two unrelated clocks at four ratios; per-domain monitors; why the write side must gate combinationally on the live `wfull` |
| [skid_buffer_tb.sv](tb/skid_buffer_tb.sv) | XSIM | A valid/ready driver needs no shadow model — and a **throughput** assertion, which is the check that actually matters here |
| [rtl_smoke_tb.sv](tb/rtl_smoke_tb.sv) | XSIM | Exhaustive checks where the state space allows, known-answer vectors (CRC-32), and structural properties (LFSR maximal length, arbiter fairness) |
| [techniques_tb.sv](tb/techniques_tb.sv) | XSIM | The structural-technique modules, each against an independent reference: insertion sort, the `*` and `/` operators being replaced, a recomputed reciprocal table, and a forced-corruption test of ring-counter self-correction |
| [fsm_tb.sv](tb/fsm_tb.sv) | XSIM | Three FSM styles compared cycle-for-cycle under stalling stimulus, and fault injection of all 12 illegal encodings of a one-hot state vector. Also two testbench traps worth knowing: driving stimulus on the sampling edge, and letting X reach a DUT whose test has not started yet |
| [pipeline_tb.sv](tb/pipeline_tb.sv) | XSIM | Modelling a pipeline as a reference shift register and comparing under a random stall pattern — a far stronger check than spot-checking frozen values. Also flush-while-stalled, adder trees at six values of N, and two loop-breaking accumulators bit-exact against a plain one |

Every testbench has a global timeout, prints a definite PASS/FAIL, and
`$fatal`s on failure so a regression cannot report success by accident.

---

## `../formal/` — SymbiYosys proofs

16 modules, 37 tasks, run by `make formal` or `formal/run_all.sh`.

| Proof | Mode | What it settles |
|---|---|---|
| [arb_fixed_fv](../formal/arb_fixed_fv.sv) | bmc + cover | **exhaustive** equivalence with an independent lowest-set-bit reference |
| [priority_encoder_fv](../formal/priority_encoder_fv.sv) | bmc + cover | **exhaustive** equivalence with a reference |
| [lzc_fv](../formal/lzc_fv.sv) | bmc + cover | **exhaustive** over all 2³² inputs |
| [gray_codec_fv](../formal/gray_codec_fv.sv) | bmc + cover | round-trip identity, and one-bit-change across every adjacent pair including the wrap |
| [bin2bcd_fv](../formal/bin2bcd_fv.sv) | bmc + cover | legal digits **and** correct value |
| [mul_const_fv](../formal/mul_const_fv.sby) | bmc | **exhaustive** equivalence with `*` |
| [div_const_fv](../formal/div_const_fv.sby) | bmc | **exhaustive** equivalence with `/` and `%` |
| [sort_network_fv](../formal/sort_network_fv.sv) | bmc + cover | sortedness + multiset preservation at W=1 — **complete for all widths** |
| [ring_counter_fv](../formal/ring_counter_fv.sv) | **prove** + bmc + cover | one-hot preserved *and* reachable |
| [gray_counter_fv](../formal/gray_counter_fv.sv) | **prove** + bmc + cover | at most one bit changes per cycle, for all time |
| [pipe_ctrl_fv](../formal/pipe_ctrl_fv.sv) | **prove** + cover | equivalence with a reference shift register; flush wins over stall |
| [skid_buffer_fv](../formal/skid_buffer_fv.sv) | **prove** + bmc + cover | no loss, no duplication, no reordering, for all time |
| [div_restoring_fv](../formal/div_restoring_fv.sv) | **prove** + bmc + cover | `q*d + r == n` and `r < d` |
| [sync_fifo_fv](../formal/sync_fifo_fv.sv) | bmc + cover | flags, level and data integrity to depth 30 — induction stated as not closing rather than claimed |
| [fsm_three_process_fv](../formal/fsm_three_process_fv.sv) | **prove** + bmc + cover | registered outputs stay aligned with their state, for all time; and bounded equivalence with the combinational-output style |
| [fsm_safe_fv](../formal/fsm_safe_fv.sv) | **recover** + prove + bmc + cover | recovery from all 12 illegal encodings, by BMC from a free initial state |

Properties that need a module's internal state live **inside** that module under
`` `ifdef FORMAL ``, not in the harness. That is forced: a hierarchical reference
into a submodule silently reads the wrong net in this flow rather than erroring.
See [docs/25](../docs/25-formal-verification-with-sby.md).
