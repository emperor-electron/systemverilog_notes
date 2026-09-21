# SystemVerilog Notes

An outline of the SystemVerilog HDL (IEEE 1800-2023), with a one-page
cheatsheet, per-topic deep dives, and a library of working, verified example
modules.

Every example is lint-clean, exercised by a self-checking testbench under XSIM,
and — where the tool can read it — proved with SymbiYosys. `make` runs the lot.

---

## Start here

| | |
|---|---|
| **[CHEATSHEET.md](CHEATSHEET.md)** | The whole language in one file. Syntax tables, operator precedence, scheduling regions, and an arithmetic quick reference. Start here, then follow the links. |
| **[docs/](docs/)** | 35 topic deep-dives — the *why* behind each construct, and the failure modes. |
| **[examples/](examples/)** | 68 synthesizable modules, 2 packages, 2 runnable language demos, 10 testbenches and 20 formal proofs, all verified. See [examples/README.md](examples/README.md). |

Three documents on making designs fast, small and buildable rather than merely
correct:

- **[Pipelining](docs/21-pipelining.md)** — the transformation, the
  latency-matching discipline that keeps it safe, retiming, elastic pipelines,
  and the three ways around a feedback loop that cannot be pipelined.
- **[Timing closure and optimization](docs/22-timing-closure-and-optimization.md)**
  — diagnosing *which* path is slow before touching it, then the catalogue of
  structural fixes, plus area and power efficiency.
- **[Structural design techniques](docs/23-structural-design-techniques.md)** —
  replacing expensive operators with structure: constant multiply and divide,
  double dabble, sorting networks, ROMs computed at elaboration, microcode.

And one on the block every digital designer writes:

- **[Control structures](docs/27-control-structures.md)** — what `if`, `case`,
  loops and generate actually build, and what each costs in logic depth.
- **[FSM coding styles](docs/26-fsm-coding-styles.md)** — the four styles and
  what each costs, why registering FSM outputs need not add a cycle, state
  encoding, and what a design does in the state encodings you did not plan for.

And one on turning parts of the chip off:

- **[Low-power architecture](docs/35-low-power-architecture.md)** — power
  domains, isolation, retention and DVFS. None of it appears in the RTL, which
  is why a design can be functionally perfect and broken by power gating.

And two on working on the code rather than writing it:

- **[Debugging and bring-up](docs/33-debugging-and-bringup.md)** — the failure
  is never where the bug is; how to narrow the gap, and how to stop a testbench
  or a proof from reporting green while something is wrong.
- **[Coding conventions and reuse](docs/34-coding-conventions-and-reuse.md)** —
  every convention here, and the specific failure it prevents.

And two on the things around the RTL rather than in it:

- **[The preprocessor and directives](docs/31-preprocessor-and-directives.md)**
  — macro hygiene, and the conditional-compilation strategy that lets one
  source file satisfy two tools with incompatible language subsets.
- **[Timing constraints](docs/32-timing-constraints.md)** — an unconstrained
  design does not fail timing, it reports nothing and ships broken.

And two on the blocks everything else is built out of:

- **[Memories and inference](docs/29-memories-and-inference.md)** — how you
  write a memory decides whether you get a block RAM or ten thousand flops.
- **[Flow control and handshakes](docs/30-flow-control-and-handshakes.md)** —
  the valid/ready contract, skid buffers, FIFO sizing, arbitration, deadlock.

And one on the discipline that ordinary simulation cannot check:

- **[Clock domain crossing](docs/28-clock-domain-crossing.md)** — metastability
  and MTBF, the four kinds of crossing and which technique each needs,
  reconvergence, reset crossing, and why CDC is verified by lint and
  constraints rather than by running the testbench again.

And one on what makes a chip testable at all:

- **[DFT, clocking and X discipline](docs/24-dft-clocking-and-x-discipline.md)**
  — what scan demands of your RTL, why a clock may never come from logic, and
  the difference between X-optimism (hides bugs, ships) and X-pessimism (wastes
  time).

And three on arithmetic, which the cheatsheet cannot do justice to:

- **[Signed and unsigned arithmetic](docs/17-signed-unsigned-arithmetic.md)** —
  the expression width algorithm, the signedness algorithm, and a catalogue of
  thirteen traps with runnable proof of each.
- **[Fixed-point arithmetic](docs/18-fixed-point-arithmetic.md)** — formats,
  bit growth, guard bits, rounding modes, saturation, and how to pick a format.
- **[Floating point in hardware](docs/19-floating-point-hardware.md)** —
  IEEE 754 formats down to FP8, the adder and multiplier algorithms, rounding
  with guard/round/sticky, subnormals, exception flags, reduced-precision ML
  formats, and how to verify any of it.

---

## Contents

### Cheatsheet

[CHEATSHEET.md](CHEATSHEET.md) — 24 sections covering lexical elements,
literals, data types, arrays, structs/unions/enums, operators, assignments,
procedural blocks, control flow, tasks and functions, modules, parameters and
generate, interfaces, packages, processes, classes, randomization, assertions,
coverage, system tasks, DPI, compiler directives, the scheduling model, and
arithmetic. Synthesizable constructs are marked **[S]**, simulation-only
**[V]**.

### Language

| Doc | Topic |
|---|---|
| [01](docs/01-lexical-and-literals.md) | Lexical elements, literals, string and time literals, compiler directives |
| [02](docs/02-data-types.md) | 4-state vs 2-state, nets vs variables, casting, default values |
| [03](docs/03-arrays-structs-enums.md) | Packed vs unpacked, selects, streaming operators, structs, unions, enums, queues, array methods |
| [04](docs/04-operators-and-expressions.md) | Precedence, equality variants, shifts, `inside`, streaming, constant expressions |
| [05](docs/05-procedural-blocks-and-flow.md) | `always_comb`/`always_ff`, blocking vs non-blocking, FSM styles, `case` variants, latch avoidance, reset style |
| [06](docs/06-modules-parameters-generate.md) | Module headers, port styles, parameters, `generate`, hierarchical references, `bind` |
| [07](docs/07-interfaces-and-packages.md) | Interfaces, modports, clocking blocks, virtual interfaces, packages, why to avoid `$unit` |
| [08](docs/08-tasks-and-functions.md) | `automatic` vs `static`, argument directions, synthesizable functions, `let`, recursion |

### Verification

| Doc | Topic |
|---|---|
| [09](docs/09-classes-and-oop.md) | Classes, handles, inheritance, `virtual`, parameterized classes, common patterns |
| [10](docs/10-randomization-and-constraints.md) | `rand`/`randc`, constraint blocks, `dist`, `solve before`, debugging a failed solve |
| [11](docs/11-processes-and-synchronization.md) | `fork` variants, the loop-variable trap, events, semaphores, mailboxes |
| [12](docs/12-assertions-sva.md) | Immediate vs concurrent, sequences, implication, local variables, a checker library |
| [13](docs/13-functional-coverage.md) | Covergroups, bins, crosses, and how to write a coverage model that means something |
| [14](docs/14-dpi-and-system-tasks.md) | Display family, file I/O, query functions, plusargs, DPI-C |
| [15](docs/15-scheduling-and-race-conditions.md) | The region model, why `<=` works, six classic races and their fixes |
| [16](docs/16-verification-architecture.md) | The layered testbench, driver/monitor separation, scoreboards, when to use UVM |

### Arithmetic

| Doc | Topic |
|---|---|
| [17](docs/17-signed-unsigned-arithmetic.md) | Two's complement, width and signedness algorithms, extension rules, per-operator behaviour, 13 traps, overflow detection, saturation, what synthesis builds |
| [18](docs/18-fixed-point-arithmetic.md) | sW.F notation, the four operations, bit growth, guard bits, rounding, saturation, choosing a format, fixed vs float |
| [19](docs/19-floating-point-hardware.md) | `real`/`shortreal` limits, IEEE 754 formats, adder, multiplier, comparison, conversions, FMA, subnormals, flags, cost, ML formats, verification |
| [20](docs/20-synthesis-subset-and-gotchas.md) | What synthesizes, 25 numbered gotchas, a file template, lint rules worth enforcing |

### Performance

| Doc | Topic |
|---|---|
| [21](docs/21-pipelining.md) | What pipelining buys, latency matching, valid/stall/flush, where to cut, retiming, elastic pipelines and skid buffers, why loops cannot be pipelined, hazards and forwarding, variable latency, pipelining memory and arithmetic, a 12-entry bug checklist |
| [22](docs/22-timing-closure-and-optimization.md) | Reading a timing report, a path taxonomy for diagnosis, logic restructuring, late-arriving signals, carry-save, speculation, control-path tricks, fanout replication, memory paths, reset strategy, multicycle/false-path constraints, physical awareness, area and power efficiency, 13 anti-patterns |
| [23](docs/23-structural-design-techniques.md) | Elaboration-time tables, constant multiply (CSD) and constant divide (reciprocal), double dabble, sorting networks and the 0-1 principle, ring/Johnson/LFSR counters, SRL inference, microcoded control |
| [24](docs/24-dft-clocking-and-x-discipline.md) | What scan demands of RTL, generated and derived clocks, clock enables and ICG cells, glitch-free clock muxing, reset for test, memory BIST, X-optimism vs X-pessimism, three checklists |

### Verification

| Doc | Topic |
|---|---|
| [25](docs/25-formal-verification-with-sby.md) | The SymbiYosys flow: bmc/prove/cover, the Yosys frontend subset in full, the harness pattern, closing an induction proof, assume-vs-assert, sequence numbering, reading a counterexample |
| [35](docs/35-low-power-architecture.md) | Where power goes and the hierarchy of savings, power domains, isolation and choosing a clamp value per signal, retention and its cheaper alternatives, level shifters, DVFS ordering, what the RTL must still provide for power intent to be implementable, and why a plain RTL testbench verifies none of it |
| [34](docs/34-coding-conventions-and-reuse.md) | The conventions used throughout this repository and the failure each one prevents: file structure, naming, types, reset policy, parameterisation and degenerate cases, elaboration-time checking, which properties belong in a module versus its harness, lint policy, and a review checklist |
| [33](docs/33-debugging-and-bringup.md) | Making a failure reproducible, chasing an X backwards, bisecting in space and time, reference models, the several ways a testbench reports green while failing, proofs that pass while proving nothing, waveform strategy, gate-level simulation — and a catalogue of every bug found while building this repository, with how each was found |
| [32](docs/32-timing-constraints.md) | The timing environment: defining clocks, generated clocks vs clock enables, uncertainty and latency, asynchronous clock groups, input/output delay, exception precedence and why a broad false path silences a CDC bound, and what each RTL construct obliges you to constrain |
| [31](docs/31-preprocessor-and-directives.md) | Macro hygiene and why the preprocessor has no scoping, conditional compilation, the dual-dialect pattern that lets one source serve XSIM and Yosys, header guards, `default_nettype`, `timescale`, and the table of what to use instead of a macro |
| [30](docs/30-flow-control-and-handshakes.md) | The valid/ready contract and its four rules, why registering a handshake needs a skid buffer, FIFO depth and flag traps, credit-based flow control, pipelines under backpressure, arbitration and fairness, deadlock/livelock/starvation, and the stimulus patterns that find protocol bugs |
| [29](docs/29-memories-and-inference.md) | The block-RAM inference rules and why each one matters, read-first/write-first/no-change, port configurations, byte enables, why a register file breaks the rules deliberately, ROM initialisation, output registers and latency, dual-port collisions, and when to stop inferring and instantiate |
| [28](docs/28-clock-domain-crossing.md) | Metastability and the MTBF equation, the two-flop synchronizer and `ASYNC_REG`, crossing levels/pulses/buses/streams, Gray pointers and why bit-by-bit sync is safe for them, reset crossing, reconvergence, the constraints and lint the RTL cannot replace, and a bug catalogue |
| [27](docs/27-control-structures.md) | What each control structure becomes in hardware: priority chains vs balanced muxes vs parallel AND-OR, the `case` family and why `casex` is banned, `?:` being X-pessimistic while `if` is X-optimistic, loops as spatial unrolling and loop-carried dependencies, generate constructs, and the verification-only forms |
| [26](docs/26-fsm-coding-styles.md) | The four FSM styles compared, decoding `next` so registered outputs cost no latency, Moore vs Mealy, state encoding, illegal-state recovery and how to prove it, `unique`/`priority` synthesis divergence, control/datapath split, FSM patterns and a checklist |

---

## Running it

```bash
make            # lint, then simulate, then prove
make lint       # xvlog analysis + yosys structural checks
make sim        # all 10 testbenches under XSIM
make formal     # all 30 proof tasks under SymbiYosys
make fp         # one target (see the Makefile for the list)
make clean
```

Requires **Vivado** (for XSIM) and the **[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)**
or a separate [SymbiYosys](https://github.com/YosysHQ/sby) install. The Makefile
sources Vivado's settings script from `VIVADO_SETTINGS`; override it if your
install lives elsewhere:

```bash
make VIVADO_SETTINGS=/opt/Xilinx/Vivado/2024.1/settings64.sh
```

### The toolchain

| | Used for | Why |
|---|---|---|
| **XSIM** (Vivado Simulator) | all simulation | 4-state, full SVA, `shortreal`, clocking blocks — everything here needs, in one tool |
| **SymbiYosys** (`sby`) | all formal proofs | BMC, unbounded induction, and reachability, with boolector/z3/yices |
| **xvlog** | lint: syntax, elaboration, undeclared identifiers | ships with XSIM |
| **yosys** | lint: inferred latches | ships with `sby`; xvlog does not report these |

`xvlog` catches every hard error and, with `` `default_nettype none ``, every
typo. It does **not** report width mismatches — see
[docs/20](docs/20-synthesis-subset-and-gotchas.md#4-lint-rules-worth-enforcing)
for what that gap costs and how the formal proofs partly close it.

### Two dialects of assertion, and why

SVA's temporal layer — `assert property` with a clocking event, `|->`, `|=>`,
sequences, `default clocking` — is **not supported by Yosys's open-source
frontend at all**. XSIM runs it happily. So modules that are formally verified
carry their properties twice:

```systemverilog
`ifndef SYNTHESIS
  // Idiomatic SVA. XSIM runs this; `sby` passes -DSYNTHESIS so Yosys skips it.
  a_out_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (out_valid && !out_ready) |=> (out_valid && $stable(out_data)));
`endif

`ifdef FORMAL
  // Immediate assertions with $past -- the only style Yosys accepts.
  always @(posedge clk)
    if (rst_n && fv_past && $past(rst_n))
      f_out_hold : assert (!($past(out_valid) && !$past(out_ready))
                           || (out_valid && out_data == $past(out_data)));
`endif
```

Ten of the fifty modules are outside the formal flow entirely, each for a
specific construct Yosys rejects (`return` in a function, `foreach`, `string`
parameters, unpacked array ports, `$bits()` of a type, named assignment
patterns). They are still linted and simulated.
[docs/25 §3](docs/25-formal-verification-with-sby.md#3-the-yosys-frontend-subset)
has the complete table, including the trap that a **hierarchical reference into
a submodule silently reads the wrong net** rather than erroring.

## What is verified, and how

Nothing here is "should work". Each example is checked against an
independently-written reference, not against itself.

| Test | What it proves |
|---|---|
| `signedness_demo` | 40 checks of the width/signedness rules against the LRM, on two simulators |
| `width_rules_tb` | the two-pass width algorithm, including every self-determined position |
| `fp_tb` | `fp_add` and `fp_mul` are **bit-exact against the host FPU** over 365,768 vectors — directed specials, uniform random, close exponents, exact cancellation, subnormals, and overflow boundaries |
| `arith_tb` | divider vs the simulator's own `/` and `%` (including the most-negative dividend and divide-by-zero); saturation vs 64-bit exact arithmetic; CORDIC vs `$sin`/`$cos` (worst error 1.1e-7 over ±π); systolic FIR vs a direct-form convolution; MAC vs an exact accumulator |
| `fifo_tb` | FIFO data integrity and flag consistency under five backpressure profiles, reaching both full and empty |
| `async_fifo_tb` | dual-clock FIFO across four clock ratios, Gray-pointer single-bit-change property, no lost beats |
| `skid_buffer_tb` | handshake protocol compliance **and full throughput** (3998 beats in 4000 cycles) — the property a naively registered stage fails |
| `rtl_smoke_tb` | arbiters (exhaustive + fairness), encoders (exhaustive), Gray codec, CRC-32 known-answer (`0xCBF43926`), LFSR maximal-length, counter, shift register, UART loopback |
| `pipeline_tb` | delay lines modelled against a reference shift register under a random 40% stall pattern; flush-while-stalled; adder trees for N = 1,2,3,5,8,16 signed and unsigned; carry-save and interleaved accumulators bit-exact against a plain accumulator; operand isolation in both modes |
| `fsm_tb` | the two-process, one-process and three-process styles proved to produce identical waveforms over 64 cycles of arbitrary stalling; explicit one-hot; and all 12 illegal encodings of a one-hot FSM injected by `force`, showing the safe variant recovering in one cycle and the unsafe one absorbing |
| `techniques_tb` | double dabble exhaustive over 8 bits; constant multiply exhaustive with CSD and binary encodings proved equal; constant divide exhaustive for five divisors; a 9-element sorting network against insertion sort; elaboration-computed ROM; SRL delay under a random enable; ring-counter self-correction after forced corruption; the microcoded sequencer walking its protocol |

### Proved (SymbiYosys) — 20 modules, 48 tasks

Formal does what simulation cannot: it *searches* the input space rather than
sampling it.

| Proof | What it settles |
|---|---|
| `arb_fixed`, `priority_encoder`, `lzc`, `gray_codec` | **exhaustive** equivalence with independently written references — `lzc` over all 2³² inputs |
| `mul_const`, `div_const` | **exhaustive** equivalence with `*`, `/` and `%`; CSD and binary encodings proved equal |
| `bin2bcd` | every nibble a legal digit **and** the digits equal the input |
| `sort_network` | sortedness and multiset preservation at W=1 — **complete for every width** by Knuth's 0-1 principle |
| `skid_buffer` | **unbounded**: no loss, no duplication, no reordering, for all time |
| `pipe_ctrl` | **unbounded**: full equivalence with a reference shift register; flush clears even while stalled |
| `div_restoring` | **unbounded**: `q*d + r == n` and `r < d` — the specification of integer division |
| `gray_counter`, `ring_counter` | **unbounded**: single-bit change; one-hot preserved *and* reachable |
| `sync_fifo` | flag/level consistency and data integrity, bounded to depth 30 (the induction is stated as not closing, rather than claimed) |
| `fsm_three_process` | **unbounded**: registered outputs stay aligned with their state — registering them costs no latency; plus bounded equivalence with the combinational-output version |
| `watchdog` | **unbounded**: an expiry is sticky until acknowledged and never spurious — the property that makes a watchdog reset attributable after the fact |
| `pwm` | **unbounded**: 0% duty never goes high and 100% never goes low, under a stable-period assumption |
| `cdc_handshake` | **unbounded**: the bus is held stable for the whole time its request is outstanding — the single-domain rule the crossing rests on. Deliberately *not* a proof that the crossing is safe; see docs/28 |
| `select_styles` | an if-chain, a `casez` and an unrolled loop are the **same circuit**; the parallel AND-OR form is a different one, equal exactly under `$onehot0` — the proof obligation `unique case` silently takes on |
| `fsm_safe` | recovery from **all 12 illegal encodings** of a one-hot FSM, by BMC from a free initial state — and the negative control that makes the proof mean something |

Three genuine bugs were found and fixed by these testbenches while writing
them; each is now documented at the point where it occurred, because the
mistakes are more instructive than the corrections:

- `async_fifo` — a combinational loop through the full flag
  (`wbin_next → wgray_next → wfull → wbin_next`). The flag must be registered.
- `fir_systolic` — the transposed form has **one** cycle of latency, not
  `NTAP`; and its coefficients must be indexed backwards relative to the delay
  line, which a symmetric coefficient set would have hidden.
- `requantize` — `(din >>> F) + WI'(inc)` where `WI'(inc)` is an *unsigned*
  cast, which makes the whole expression unsigned and silently turns `>>>` into
  a logical shift. This is trap T6b in
  [docs/17](docs/17-signed-unsigned-arithmetic.md#8-the-trap-catalogue), and it
  turned every negative filter output into a large positive one.

---

## Conventions used in the examples

```systemverilog
`default_nettype none          // top of every file; a typo becomes an error
module foo #(
  parameter  int unsigned DW = 32,
  localparam int unsigned AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
  input  var logic          clk,
  input  var logic          rst_n,     // active low, async assert
  output var logic [DW-1:0] dout
);
```

- One module per file, named after the module, so library search (`-y`) works.
- `always_comb` with a **default assignment first**, so no path leaves a signal
  unassigned. (`fp_mul` shows what happens when you forget: the tool infers a
  latch.)
- `always_ff` with `<=` only; `always_comb` with `=` only.
- Explicit `signed` on everything that does arithmetic, and a named
  `localparam` for every derived width.
- Assertions inside the RTL, guarded by `` `ifndef SYNTHESIS ``.
- **Reset the control path, not the data path.** A datapath pipeline register
  needs no reset (the valid bit beside it carries the meaning), and resetting it
  costs area, costs reset routing, and blocks retiming — see
  [docs/21 §6](docs/21-pipelining.md#6-retiming-let-the-tool-place-the-registers).
- Suffixes: `_t` type, `_e` enum, `_n` active-low, `_q`/`_d` registered value
  and its next-state input.
