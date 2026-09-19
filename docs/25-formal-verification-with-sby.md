# Formal Verification with SymbiYosys

Simulation samples the input space. Formal verification *searches* it — it
either proves a property holds for every reachable state, or hands you the
shortest sequence of inputs that breaks it.

This document covers the flow used in [`formal/`](../formal/): SymbiYosys (`sby`)
driving Yosys and an SMT solver. It also covers, in detail, **what the
open-source SystemVerilog frontend cannot read**, because that constraint shapes
how every property in this repository is written.

Everything here is verified: 14 modules, 30 proof tasks, all passing —
`make formal`.

---

## Contents

- [1. What formal actually does](#1-what-formal-actually-does)
- [2. The three modes](#2-the-three-modes)
- [3. The Yosys frontend subset](#3-the-yosys-frontend-subset)
- [4. Writing properties Yosys can read](#4-writing-properties-yosys-can-read)
- [5. The harness pattern](#5-the-harness-pattern)
- [6. When induction fails](#6-when-induction-fails)
- [7. Assume versus assert](#7-assume-versus-assert)
- [8. Proof techniques that pay](#8-proof-techniques-that-pay)
- [9. Reading a counterexample](#9-reading-a-counterexample)
- [10. What is proved in this repository](#10-what-is-proved-in-this-repository)
- [11. When to reach for formal](#11-when-to-reach-for-formal)

---

## 1. What formal actually does

A design is a state machine. Formal tools convert it into a logical formula and
ask a solver a question about *all* of its executions at once.

```
  simulation:  "here are 10,000 input sequences; did any of them break it?"
  formal:      "does ANY input sequence break it? If so, show me the shortest."
```

The difference in practice:

| | Simulation | Formal |
|---|---|---|
| Input space | sampled | searched |
| Finds a 1-in-2^40 corner | only by luck | yes, or proves it cannot happen |
| Says "correct" | never — only "no failure seen" | yes, within the mode's bound |
| Needs a testbench | yes, and stimulus | no stimulus, only properties |
| Scales with | simulation time | state-space complexity |
| Fails on | big designs (too slow) | big designs (solver explodes) |

Formal is not a replacement for simulation. It is overwhelmingly better on
**control logic, protocols, arbiters, FIFOs, encoders and small datapaths**, and
overwhelmingly worse on anything with a wide multiplier or a large memory.

---

## 2. The three modes

Every `.sby` file in [`formal/`](../formal/) declares some combination of three
tasks. Understanding which one you ran is the difference between "proved" and
"did not find a bug in 20 cycles".

### `bmc` — bounded model check

Start from the real reset state, unroll `depth` cycles, ask whether any
assertion can fail within them.

```
[options]
bmc: mode bmc
bmc: depth 24
```

- **A pass means:** no counterexample exists within `depth` cycles.
- **It does not mean:** the property holds forever.
- For **combinational** logic, `depth 2` is an *exhaustive* proof — there is no
  state, so every input pattern is covered.

That last point is worth dwelling on. `formal/lzc_fv.sv` proves the 32-bit
leading-zero counter against an independent reference for all 2³² inputs, in
milliseconds. Simulation cannot enumerate that.

### `prove` — unbounded proof by k-induction

Two checks together:

1. **base case** — BMC from reset for `k` steps;
2. **induction step** — assume the assertions hold for `k` consecutive
   arbitrary states, prove they hold in the next.

If both pass, the property holds for **all time**. This is a real proof.

```
[options]
prove: mode prove
```

The catch is the word *arbitrary*: the induction step does not start from a
reachable state, it starts from any state the assertions permit. Anything your
assertions fail to pin down, the solver is free to invent. See
[§6](#6-when-induction-fails).

### `cover` — reachability

Ask whether a state is reachable at all, and produce a trace that gets there.

```
[options]
cover: mode cover
cover: depth 20
```

**This is not optional.** An `assert` on an antecedent that can never be true
passes vacuously and proves nothing. Every `.sby` here has a `cover` task for
exactly that reason:

```systemverilog
// Proves the FIFO can actually reach full -- so a_no_overflow is not vacuous.
f_c_full  : cover (rst_n && full);
f_c_empty : cover (rst_n && empty && fv_in_seq != '0);
f_c_b2b   : cover (rst_n && do_wr && do_rd);
```

A `cover` failing is usually *more* informative than an `assert` failing: it
means a situation you believed reachable is not, which is either a dead feature
or a wrong assumption.

---

## 3. The Yosys frontend subset

Yosys's open-source SystemVerilog frontend is a **subset**. This is the single
most important practical fact about this flow, and it is not well advertised.

### Rejected outright

| Construct | Workaround |
|---|---|
| **`assert property` with a clocking event** | immediate `assert` inside `always @(posedge clk)` |
| **`\|->` and `\|=>`** (implication) | `$past` and boolean implication |
| **sequences, `##N`, `[*n]`, `throughout`** | express with `$past` and auxiliary state |
| **`default clocking` / `default disable iff`** | put the clock on the `always` block |
| **`return` in a function** | assign to the function name: `f = expr;` |
| **local variable with an initialiser in a function** | declare, then assign |
| **`foreach`** | `for (int i = 0; ...)` |
| **`string` parameters** | avoid, or guard with `` `ifndef YOSYS `` |
| **unpacked array PORTS** | flatten to a packed vector and slice |
| **`$bits(type_name)`** | `$bits` of an *expression* is fine; or write the sum out |
| **named assignment patterns** `'{a:1, b:2}` | positional `'{1, 2}` |
| **hierarchical references into a submodule** | see the warning below |

### Accepted

Enums (with `e'(x)` casts), packed structs and unions, package-scoped types in
ports, size casts `N'(x)`, `signed'(x)`, `always_comb`/`always_ff`/`always_latch`,
generate loops and generate-if, recursive module instantiation, `$past`,
`$rose`, `$fell`, `$stable`, `$onehot`, `$onehot0`, `$countones`, `$initstate`,
`$anyconst`, `$anyseq`, and immediate `assert`/`assume`/`cover`.

### The hierarchical-reference trap

> **A hierarchical reference from a harness into a submodule silently reads the
> wrong net. It does not error — it produces a wrong netlist.**

This is demonstrable with a tautology:

```systemverilog
module sub(input logic clk, input logic [3:0] d, output logic [3:0] q);
  logic [3:0] internal_r = 4'd0;
  always @(posedge clk) internal_r <= d;
  assign q = internal_r;          // q IS internal_r
endmodule

module top_fv(input logic clk, input logic [3:0] d);
  logic [3:0] q;
  sub dut (.clk(clk), .d(d), .q(q));
  always @(posedge clk) a_taut: assert (dut.internal_r == q);   // FAILS
endmodule
```

That assertion cannot be false, and `sby` reports it failing. Adding `flatten`
before `prep` does not help.

**Consequence for how properties are organised here:** anything that needs
internal state lives **inside the module**, under `` `ifdef FORMAL ``. The
harness only drives inputs and constrains the environment. That is also the
canonical SymbiYosys style, so it is the right structure anyway — but it is
worth knowing it is forced rather than chosen.

### Making a module readable by both tools

The SVA in this repository is already guarded by `` `ifndef SYNTHESIS ``, and
the `.sby` scripts pass `-DSYNTHESIS`, so Yosys skips it without any source
change. Modules that also carry formal properties add a separate
`` `ifdef FORMAL `` block:

```systemverilog
`ifndef SYNTHESIS
  // Idiomatic SVA -- XSIM runs these. Yosys cannot parse them at all, which is
  // why they sit behind a guard it also honours.
  a_out_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (out_valid && !out_ready) |=> (out_valid && $stable(out_data)));
`endif

`ifdef FORMAL
  // Immediate assertions with $past -- the only style Yosys accepts.
  always @(posedge clk) begin
    if (rst_n && fv_past && $past(rst_n)) begin
      f_out_hold : assert (!($past(out_valid) && !$past(out_ready))
                           || (out_valid && out_data == $past(out_data)));
    end
  end
`endif
```

Yes, that is the same property twice in two dialects. It is the cost of using an
open-source frontend; a Verific-enabled Yosys reads the SVA directly.

Ten of the fifty modules here remain outside the formal flow entirely —
`fp_add`, `fp_mul`, `fp_classify`, `arb_weighted`, `cordic_sincos`,
`crc_parallel`, `ram_be`, `ram_sp`, `regfile`, `useq` — each for a specific
construct in the table above. They are still linted and simulated.

---

## 4. Writing properties Yosys can read

Everything reduces to **immediate assertions inside a clocked block**, with
`$past` carrying the temporal part.

```systemverilog
// SVA                                    Yosys-compatible equivalent
// ------------------------------------   -------------------------------------
// a |-> b                                assert (!a || b);
// a |=> b                                assert (!$past(a) || b);
// a |=> $stable(x)                       assert (!$past(a) || (x == $past(x)));
// $rose(a) |-> b                         assert (!($past(a)==0 && a) || b);
// always @(posedge clk) ... disable iff  if (rst_n) begin ... end
```

Two pieces of scaffolding are needed almost every time:

```systemverilog
// $past is meaningless in the first cycle; asserting over it yields bogus
// counterexamples at step 0.
logic fv_past = 1'b0;
always @(posedge clk) fv_past <= 1'b1;

always @(posedge clk)
  if (rst_n && fv_past && $past(rst_n)) begin
    f_prop : assert (...);
  end
```

`$past(rst_n)` as well as `rst_n`: a property spanning a cycle boundary must
not be checked across a reset.

---

## 5. The harness pattern

A harness (`formal/<module>_fv.sv`) does two jobs, both of which genuinely
belong to the environment rather than the design.

```systemverilog
module skid_buffer_fv #(parameter int unsigned DW = 4) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic in_valid,
  input  var logic out_ready
);

  // 1. A DEFINED STARTING POINT. Without this the solver may begin in a
  //    fabricated state and report a counterexample that cannot happen.
  //    After cycle 0, rst_n is free -- so reset-during-operation is explored.
  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic [DW-1:0] in_data, out_data;
  logic          in_ready, out_valid;

  skid_buffer #(.DW(DW)) dut (.*);

  // 2. THE ENVIRONMENT'S HALF OF THE CONTRACT. A source that withdraws valid
  //    before the handshake completes violates AXI-Stream, and the buffer is
  //    not required to cope. Omit this and the solver reports that "bug"
  //    instead of looking for a real one.
  always @(posedge clk)
    if (rst_n && past_ok && $past(rst_n))
      if ($past(in_valid) && !$past(in_ready)) assume (in_valid);

endmodule
```

Note the harness inputs are **undriven**. That is deliberate: the solver drives
them, exploring every legal combination. Anything you drive from the harness is
something you are *not* verifying.

---

## 6. When induction fails

This is the part that takes practice, and where most of the learning is.

`prove` runs a base case and an induction step. The base case starting from
reset almost always passes. **The induction step starts from an arbitrary state
satisfying the assertions**, which is very often not a reachable state.

### The diagnosis

```
bmc   PASS      (from the real reset state, to depth N)
prove FAIL      (induction cannot close)
```

That combination means: **no bug found, but the invariant set is too weak.** The
solver constructed a start state that satisfies every assertion yet is not
reachable, and from it reached a violation.

### The fix is a stronger invariant, not a weaker property

Worked example from [`skid_buffer.sv`](../examples/rtl/skid_buffer.sv). The
end-to-end property was:

```systemverilog
f_stream : assert (!out_valid || (out_data == fv_out_seq));
```

BMC passed; induction failed. The solver had invented a state with the *skid
slot* holding the wrong beat — nothing forbade it. Three added invariants
describe the reachable state space exactly, and induction closes:

```systemverilog
// Occupancy is exactly determined by the two observable flags.
f_occupancy: assert ((fv_in_seq - fv_out_seq) ==
                     (DW'(out_valid) + DW'(skid_valid)));
// The skid slot is never occupied while the output register is empty.
f_no_orphan: assert (!skid_valid || out_valid);
// And when it IS occupied, it holds the beat after the one being presented.
f_skid_val : assert (!skid_valid || (skid_data == (fv_out_seq + 1'b1)));
```

Those invariants are not test scaffolding — they are a precise statement of how
the block works, and they are worth reading as documentation.

### When the property is genuinely not an invariant

Sometimes the property *should* fail induction. [`ring_counter`](../examples/rtl/ring_counter.sv)
is self-correcting, so non-one-hot states are states it is *designed* to recover
from. `assert ($onehot(q))` correctly fails induction. Split it:

```systemverilog
// In the module: PRESERVATION -- inductive.
f_onehot_pres : assert (!$onehot($past(q)) || $onehot(q));

// In the harness: the BASE CASE -- checked by BMC from the real reset state.
f_onehot_reachable : assert ($onehot(q));
```

Preservation plus base case gives one-hot for every *reachable* state, which is
what the design actually promises. Conflating the two is the most common
induction mistake.

### If you cannot close it

Say so. A bounded proof at a depth that provably covers the state space is
normal industrial practice for datapath-carrying blocks.
[`sync_fifo_fv.sby`](../formal/sync_fifo_fv.sby) is `bmc` + `cover` only, with
the reason written in the file. What is not acceptable is claiming `prove`
passed when it did not.

---

## 7. Assume versus assert

Getting this backwards is the fastest way to a meaningless result.

| | Meaning | Who it constrains |
|---|---|---|
| `assert` | "the design must guarantee this" | the design under test |
| `assume` | "the environment will never do this" | the solver's input search |
| `cover` | "show me this is reachable" | nothing |

```systemverilog
// The FIFO does not PREVENT an overflow; it only reports `full`. Writing while
// full is a contract violation by the environment, so it is an ASSUMPTION.
always @* begin
  if (full)  assume (!wr_en);
  if (empty) assume (!rd_en);
end
```

Write that as an `assert` instead and the proof fails instantly with a
"counterexample" in which the solver simply drives the illegal input.

**The danger runs the other way too.** An over-strong `assume` silently narrows
the search until the proof is about a design that does not exist. The discipline:

- every `assume` must correspond to a **documented contract** the other side is
  independently verified to obey;
- `cover` the interesting states afterwards — if an assumption is too strong, the
  covers become unreachable and tell you;
- when a block is integrated, the assumptions become assertions on its
  neighbour.

---

## 8. Proof techniques that pay

### Sequence numbering for data integrity

Instead of modelling a buffer, constrain the input so each beat's **payload is
its sequence number**, then assert the output counts up with no gaps. One pair
of counters proves three properties at once:

```systemverilog
always @* assume (in_data == fv_in_seq);      // the producer's contract

always @(posedge clk) begin
  if (in_valid  && in_ready)  fv_in_seq  <= fv_in_seq  + 1'b1;
  if (out_valid && out_ready) fv_out_seq <= fv_out_seq + 1'b1;
end

f_stream : assert (!out_valid || (out_data == fv_out_seq));
//   a gap        => a beat was lost
//   a repeat     => a beat was duplicated
//   out of order => reordering
```

This is sound **because the datapath is data-independent** — the control logic
never inspects the payload, so proving it for one stream proves it for all. That
argument is what makes the trick legitimate; it would *not* be sound for a block
that branches on its data.

Four bits of sequence number suffice for a 2-deep buffer: any loss or
duplication shows up long before the counter wraps.

### An independent reference model

The strongest form. Write the specification as a second implementation and prove
equivalence:

```systemverilog
// formal/arb_fixed_fv.sv -- deliberately NOT written as req & (~req+1).
// A proof against a restatement of the implementation proves nothing.
always @* begin
  ref_grant = '0;
  for (i = 0; i < N; i = i + 1)
    if (req[i] && ref_grant == '0) ref_grant[i] = 1'b1;
end
always @(posedge clk) a_equiv : assert (grant == ref_grant);
```

### Proving the specification directly

For arithmetic, the specification often *is* an equation:

```systemverilog
// formal/div_restoring_fv.sv -- this single line IS integer division.
f_exact : assert (recomposed == {{W{1'b0}}, a_q});   // q*d + r == n
f_rem   : assert (remainder < b_q);
```

### Exploiting a mathematical principle

Sometimes a small proof implies a large one. **Knuth's 0-1 principle**: a
comparator network sorts every input sequence iff it sorts every sequence of 0s
and 1s. So proving [`sort_network`](../examples/rtl/sort_network.sv) at `W = 1`
proves it for *every* element width — 512 patterns instead of 2⁷².

### Keep the parameters small

Proof cost grows with state, confidence does not. A FIFO proved at `DEPTH = 4`
is overwhelmingly likely correct at `DEPTH = 1024`; a FIFO proved at
`DEPTH = 1024` may not terminate. Prove small, simulate large.

---

## 9. Reading a counterexample

```
SBY [skid_buffer_fv_bmc] engine_0: Assert failed in skid_buffer_fv: a_skid_val
SBY [skid_buffer_fv_bmc] summary: failed assertion ... at ...sv:103 step 4
SBY [skid_buffer_fv_bmc] summary: counterexample trace: .../engine_0/trace.vcd
```

You get four things:

1. **which assertion** and **which step** — usually enough on its own;
2. `trace.vcd` — a waveform;
3. `trace_tb.v` — a **generated Verilog testbench** that replays the exact input
   sequence. Often the fastest way in: read the `PI_*` assignments and you have
   the stimulus as a list.
4. `trace.smtc` / `trace.yw` — machine-readable forms.

```bash
# The input sequence, directly:
grep -E "PI_" formal/skid_buffer_fv_bmc/engine_0/trace_tb.v
```

Note that Yosys bit-blasts vectors in the VCD, so a naive parse sees one bit of
a multi-bit signal. `trace_tb.v` does not have that problem.

**Counterexamples are minimal.** The solver reports the *shortest* sequence
reaching the failure — typically 3 to 6 cycles, with no unrelated activity. That
is the single biggest debugging advantage formal has over simulation, where the
failing transaction is buried in a million cycles of traffic.

---

## 10. What is proved in this repository

`make formal` — 14 modules, 30 tasks.

| Module | Mode | What is proved |
|---|---|---|
| `arb_fixed` | bmc + cover | **exhaustive** equivalence with an independent lowest-set-bit reference; one-hot; grant ⊆ req |
| `priority_encoder` | bmc + cover | **exhaustive** equivalence with a reference; the reported bit really is set |
| `lzc` | bmc + cover | **exhaustive** over all 2³² inputs against a reference |
| `gray_codec` | bmc + cover | round-trip identity, and the single-bit-change property across every adjacent pair including the wrap |
| `bin2bcd` | bmc + cover | every nibble is a legal digit **and** the digits equal the input |
| `mul_const` | bmc | **exhaustive** equivalence with `*`; CSD and binary encodings equal |
| `div_const` | bmc | **exhaustive** equivalence with `/` and `%` for D = 1…1000 |
| `sort_network` | bmc + cover | sortedness and multiset preservation at W=1 — **complete for all widths** by the 0-1 principle |
| `ring_counter` | **prove** + bmc + cover | one-hot preserved (induction) and reachable (base case); never stuck |
| `gray_counter` | **prove** + bmc + cover | at most one bit changes per cycle, for all time |
| `pipe_ctrl` | **prove** + cover | full equivalence with a reference shift register; stall holds; flush clears even while stalled |
| `skid_buffer` | **prove** + bmc + cover | no loss, no duplication, no reordering — **for all time** |
| `div_restoring` | **prove** + bmc + cover | `q*d + r == n` and `r < d`; the divide-by-zero convention |
| `sync_fifo` | bmc + cover | flag/level consistency and data integrity, bounded to depth 30 |

5 of those carry unbounded proofs. The `bmc`-only entries on combinational
blocks are exhaustive, which is stronger than any bound.

### Running them

```bash
make formal                      # everything
cd formal && ./run_all.sh        # same thing, with per-task status
sby -f formal/skid_buffer_fv.sby prove    # one task
```

A failing run leaves `formal/<name>_<task>/` containing the logs and the
counterexample.

---

## 11. When to reach for formal

### Where it wins outright

| Target | Why |
|---|---|
| **Arbiters** | fairness and one-hot-ness are universally quantified claims |
| **FIFOs, skid buffers, CDC** | pointer arithmetic has corner cases at wrap that random stimulus rarely hits |
| **Protocol compliance** | AXI-Stream stability, handshake rules — all safety properties |
| **Encoders, decoders, LZC, popcount** | combinational, so BMC is exhaustive |
| **Constant arithmetic** | prove equivalence with the operator you replaced |
| **FSM reachability** | dead states, unreachable branches, lock-up |
| **Sorting networks** | the 0-1 principle turns a small proof into a complete one |

### Where it does not

| Target | Why |
|---|---|
| **Wide multipliers** | the solver explodes; a 32×32 multiply is hard for SMT |
| **Large memories** | state space, though `memory_map` helps for small ones |
| **Floating point** | the exponent/mantissa interaction defeats bit-level solvers. Use a golden model — [`fp_tb.sv`](../examples/tb/fp_tb.sv) checks 365,768 vectors against the host FPU |
| **End-to-end system behaviour** | no property to write |
| **Performance and throughput** | liveness is hard; simulate it ([`skid_buffer_tb.sv`](../examples/tb/skid_buffer_tb.sv) measures beats per cycle directly) |

### The practical split

```
  formal      control logic, protocols, small datapaths, structural invariants
  simulation  data paths, integration, performance, anything with a reference model
  both        the blocks that matter most
```

The blocks in this repository that carry both — `skid_buffer`, `sync_fifo`,
`div_restoring`, `gray_counter` — are the ones where that overlap is worth the
duplication, and the two methods found different things.

---

## See also

- [docs/12: Assertions (SVA)](12-assertions-sva.md) — the full SVA language,
  which XSIM runs and Yosys cannot
- [docs/16: Verification architecture](16-verification-architecture.md) — the
  simulation side
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) — why
  formal's arbitrary initial state substitutes for X-propagation
- [docs/23: Structural techniques](23-structural-design-techniques.md) — most of
  the modules proved here
