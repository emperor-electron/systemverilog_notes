# SystemVerilog Notes

An outline of the SystemVerilog HDL (IEEE 1800-2023), with a one-page
cheatsheet, per-topic deep dives, and a library of working, verified example
modules.

Every example in this repository is lint-clean under Verilator `-Wall` and is
exercised by a self-checking testbench. `make` runs the whole thing.

---

## Start here

| | |
|---|---|
| **[CHEATSHEET.md](CHEATSHEET.md)** | The whole language in one file. Syntax tables, operator precedence, scheduling regions, and an arithmetic quick reference. Start here, then follow the links. |
| **[docs/](docs/)** | 22 topic deep-dives — the *why* behind each construct, and the failure modes. |
| **[examples/](examples/)** | 50 synthesizable modules, 2 packages, 2 runnable language demos, and 7 testbenches, all verified. See [examples/README.md](examples/README.md). |

Two documents on making designs fast rather than merely correct:

- **[Pipelining](docs/21-pipelining.md)** — the transformation, the
  latency-matching discipline that keeps it safe, retiming, elastic pipelines,
  and the three ways around a feedback loop that cannot be pipelined.
- **[Timing closure and optimization](docs/22-timing-closure-and-optimization.md)**
  — diagnosing *which* path is slow before touching it, then the catalogue of
  structural fixes, plus area and power efficiency.

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

---

## Running it

```bash
make            # lint everything, then run every test
make lint       # Verilator -Wall over all 54 example files
make sim        # run all 9 testbenches
make fp         # just the floating-point regression
make clean
```

Requires [Verilator](https://verilator.org) 5.x and
[Icarus Verilog](https://steveicarus.github.io/iverilog/) 12+. Both are open
source; on Debian/Ubuntu, `apt install verilator iverilog`, or use the
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) for current
builds.

### Why two simulators

Neither one alone is sufficient, and the reason is worth internalizing:

| | Icarus Verilog | Verilator |
|---|---|---|
| Value system | **4-state** — models `X` propagation | 2-state |
| `shortreal` / `$bitstoshortreal` | **yes** | no |
| Clocking blocks | no | **yes** (with `--timing`) |
| Concurrent assertions | booleans only — `\|->` and `\|=>` are **rejected** | **full SVA** |
| Speed | modest | **very fast** |
| Linting | minimal | **excellent** |

Verilator's 2-state engine cannot find an uninitialized-register bug, and
evaluates `x ? a : b` by simply taking one branch — so "passes in Verilator"
says nothing about X-safety. Conversely, Icarus rejects the implication
operators outright, so any module whose assertions use `|->` or `|=>` has to be
simulated in Verilator — which is why `pipeline_tb` and the FIFO tests run
there. The language demos detect a 2-state engine and
skip the one check it cannot model; `make xcheck` runs them on Verilator to show
exactly that happening. See [docs/02](docs/02-data-types.md).

### Tool flags that are easy to get wrong

```bash
# Icarus: -y alone silently finds nothing, because the default library
# suffix is .v -- you need -Y.sv as well.
iverilog -g2012 -gsupported-assertions -Y.sv -y examples/rtl -o out tb.sv

# Verilator: -y needs file name == module name, which is why this repo uses
# one module per file.
verilator --binary --timing --timescale 1ns/1ps -y examples/rtl tb.sv
```

---

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
