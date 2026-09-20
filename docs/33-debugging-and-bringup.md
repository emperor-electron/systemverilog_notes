# Debugging and Bring-Up

Most of what makes hardware debugging hard is that the failure you see is not
where the bug is. A wrong value appears fifty cycles and three modules
downstream of the mistake; an X surfaces long after the register that was never
reset; a proof passes because it was asking nothing.

This document is about narrowing that gap: how to find the cause rather than the
symptom, how to make failures reproducible, and how to keep a testbench from
reporting green while something is wrong.

Every example here is a bug that was actually hit while building this
repository. They are worth more than invented ones because the way each was
*found* is the transferable part.

---

## Contents

- [1. Make the failure reproducible first](#1-make-the-failure-reproducible-first)
- [2. Chasing an X](#2-chasing-an-x)
- [3. Bisecting in space and time](#3-bisecting-in-space-and-time)
- [4. Reference models](#4-reference-models)
- [5. Testbenches that report green while failing](#5-testbenches-that-report-green-while-failing)
- [6. Proofs that pass while proving nothing](#6-proofs-that-pass-while-proving-nothing)
- [7. Waveforms](#7-waveforms)
- [8. Gate-level simulation](#8-gate-level-simulation)
- [9. A worked catalogue](#9-a-worked-catalogue)
- [10. Checklist](#10-checklist)

---

## 1. Make the failure reproducible first

Before understanding anything, make the failure happen on demand. Everything
else depends on it.

```systemverilog
// Print the seed, always, on every run.
initial $display("seed = %0d", $urandom(seed));
```

Most simulators take a seed on the command line (`xsim -sv_seed 12345`). Print
it in the transcript so a failing regression run can be repeated exactly. A
failure you cannot reproduce is a failure you cannot fix, and a "fix" you cannot
test.

**Give every testbench a global timeout.** Every one in this repository has:

```systemverilog
initial begin
  #200ms;
  $fatal(1, "GLOBAL TIMEOUT");
end
```

Without it, a deadlocked design produces a simulation that runs until the disk
fills, which in a regression looks like infrastructure trouble rather than a
design bug. With it, a hang is a deterministic, attributable failure.

**Shrink before you dig.** A 400,000-vector failure is a 3-vector failure that
has not been minimised yet. Reduce the parameters (`DEPTH`, `WIDTH`, the number
of iterations) until the failure still reproduces but the waveform fits on a
screen. Most of the proofs and testbenches here run at deliberately small widths
for exactly this reason — `select_styles_fv` uses `W=4` because 4 bits is enough
to be exhaustive and small enough to read.

---

## 2. Chasing an X

X propagation is the most common bring-up failure and the one with the clearest
method.

**Work backwards, not forwards.** Find the first cycle where the X appears, then
find its driver, then repeat. The temptation is to start at the output and
reason forwards about what *should* happen; the X is upstream, and following it
backwards is mechanical.

The usual sources, in rough order of frequency:

| Source | Tell |
|---|---|
| A register with no reset, read before written | X from cycle 0, in a specific register |
| A memory read before write | X appears on a data path several cycles after the read |
| An incomplete `case` or `if` with no `else` | X appears only in one mode |
| An out-of-range array index | X appears only at certain addresses |
| An undriven testbench signal | X in a DUT whose test has not started yet |
| A `$readmemh` file shorter than the array | X in the tail of a memory only |

That fifth row was a real bug here. `fsm_tb.sv` instantiates five DUTs for the
whole simulation but only drove each one's inputs when its own test began — so
`fsm_safe` and `fsm_onehot` had X inputs during the *first* test, X propagated
into their state registers, and their one-hot assertions failed. **Drive every
DUT input from time 0, even ones the current test does not care about.**

### Catch X at the boundary

Do not wait for an X to reach an output. Assert against it where it enters:

```systemverilog
a_no_x_in: assert property (@(posedge clk) disable iff (!rst_n)
  !$isunknown({valid, ready, addr}))
  else $error("X on control inputs");
```

Control signals only — `$isunknown` on a data bus that is legitimately X when
`valid` is low will cry wolf. Qualify it:

```systemverilog
a_data_known: assert property (@(posedge clk) disable iff (!rst_n)
  valid |-> !$isunknown(data));
```

### Remember which direction your code is optimistic

- `if (x)` treats X as **false** and silently takes the `else` branch.
- `casex` treats X in the case expression as a **wildcard** — an X state matches
  the first branch and the FSM sails on.
- `?:` merges both arms bitwise and **propagates** X.
- `===` and `!==` compare X literally and never produce X.

So `if` and `casex` *hide* X, and `?:` reveals it. See
[docs/27 §4](27-control-structures.md#4-the-conditional-operator) for the
measured behaviour and [docs/24 §8](24-dft-clocking-and-x-discipline.md#8-x-optimism-and-x-pessimism)
for why X-optimism is the dangerous direction.

> **Do not zero a memory just to clean up the waveform.** X in an uninitialised
> memory is the honest model, and it propagates, which is the point. Silencing
> it hides exactly the read-before-write bug you are looking for
> ([docs/29 §10](29-memories-and-inference.md#10-reset-x-and-simulation)).

---

## 3. Bisecting in space and time

When the symptom is a wrong value rather than an X, the question is *where* the
data stopped being right.

**In space:** compare against a reference at each boundary. If a pipeline has
four stages and the output is wrong, check stage 2. Two comparisons locate the
stage; one per stage does not.

**In time:** find the *first* failing cycle, not a representative one. A
scoreboard that prints every mismatch produces thousands of lines, and lines
2 through 9000 are consequences. Cap the output:

```systemverilog
task automatic chk(input string what, input logic ok);
  if (!ok) begin
    errors++;
    if (errors <= 30) $display("  FAIL  %s", what);   // first 30 only
  end
endtask
```

That is the `chk` used by every testbench here. The cap is not cosmetic — it is
what keeps the first failure visible.

**In the design:** when a module's output is wrong but its inputs look right,
print its internal state, not more of its outputs. The `useq` bug in this
repository was invisible at the interface: the sequencer produced every expected
data value and every data check passed. Tracing `pc` showed it running the
entire protocol in six cycles — it branched on its wait conditions being *true*
rather than false, so every wait state fell through. **A design that produces
the right answers for the wrong reason passes an output-only check.**

---

## 4. Reference models

The strongest testbench structure is "compute it a second way and compare",
because it turns debugging into a search for a difference rather than a search
for a mistake.

| Reference | Used for |
|---|---|
| The simulator's own operators | `div_restoring` vs `/` and `%` |
| The host FPU via `shortreal` | `fp_add`/`fp_mul`, bit-exact over 365,768 vectors |
| An independent algorithm | sorting network vs insertion sort |
| A behavioural model of the same spec | pipelines vs a reference shift register |
| The design's own simpler variant | CSD constant multiply vs binary encoding |

**The reference must be independently written.** A "reference" derived from the
same reasoning as the design reproduces the same mistake and confirms it.

The most reusable trick here is modelling a **pipeline as a shift register**.
`pipeline_tb.sv` originally asserted something that was not a property at all —
"pd3 still holds its old value after a stall lifts" — and passed for the wrong
reason. Replacing it with a reference shift register under a random 40% stall
is both simpler and much stronger: it checks every cycle rather than one
hand-picked condition.

> Two claims in this repository's own documentation were wrong until a runnable
> demo contradicted them: that a shift's left operand is self-determined (it is
> context-determined), and the X behaviour of `?:` versus `if`. **Write the demo
> even when you are sure.**

---

## 5. Testbenches that report green while failing

A passing testbench is a claim, and there are several ways for it to be false.

**Assertions that fail without failing the test.** A concurrent SVA assertion
that fails calls `$error`, which XSIM reports and then *carries on from*. A
testbench whose own checks all pass therefore prints `PASS` with failing
assertions scrolling past above it. This repository's Makefile was doing exactly
that until a real X bug surfaced it; the sim rule now fails on both conditions:

```make
echo "$$out" | grep -q ": PASS" || { echo "*** DID NOT PASS ***"; exit 1; }
if echo "$$out" | grep -qE "^Error:"; then
  echo "*** printed PASS but SVA assertions FAILED ***"; exit 1
fi
```

**Checks that never ran.** A `chk` inside a branch that was never taken passes
by not existing. Count the comparisons and assert the count:

```systemverilog
chk("equivalence monitor actually ran", compares > 50);
$display("  %0d cycles compared across three styles", compares);
```

**Stimulus that races the clock.** All three FSM style modules in `fsm_tb.sv`
appeared to disagree by one cycle until the stimulus moved from `posedge` to
`negedge`. That was a race in the testbench, not a difference between the
designs. **Drive on one edge and sample on the other**, and suspect this first
whenever two implementations of one thing "differ by a cycle".

**Expectations written against the broken design.** When a test is written after
the design and fails, the tempting fix is to adjust the test. The `useq`
expectations here were written against a sequencer that was skipping all its
wait states, and they passed. If a test needs changing to pass, write down *why*
the old expectation was wrong before changing it.

**Fault injection that is not cleaned up.** `force` holds a register against its
own `always_ff`, so an injected value is still the sampled value at the
*following* clock edge — the design cannot update a register it is not allowed
to drive. An in-module "recovers in one cycle" property then looks violated by
an artefact. Suspend design assertions across the window and check recovery from
a port:

```systemverilog
$assertoff(0, u_dut);
force u_dut.state = 4'b0000;
@(negedge clk); release u_dut.state;
@(negedge clk); chk("recovered", !err);
$asserton(0, u_dut);
```

---

## 6. Proofs that pass while proving nothing

Formal has its own version of the green-but-wrong failure, and it is quieter
because there is no waveform to notice.

**Always run a negative control.** Break the design deliberately and confirm the
proof fails. Every safety property in this repository was checked this way, and
two of them were found to be proving nothing:

- The first `fsm_safe` recovery harness asserted both "the state is always
  legal" and "an illegal state never survives a cycle" in the same proof.
  Induction **assumes** every asserted property in the preceding steps, so the
  first hands the second the assumption that the previous state was legal, and
  the second becomes vacuously true. It passed with the recovery logic removed.
- Splitting them into separate tasks was still not enough, because induction
  assumes the property itself at earlier steps and a legal state never *leads*
  to an illegal one — so the solver could not construct a trace that entered
  one. What worked was **BMC with a free initial state**: BMC proves every step
  rather than assuming earlier ones, and a register with no initialiser is left
  unconstrained at step 0, so it ranges over all 16 encodings.

**Cover what you assert.** An assertion whose antecedent is unreachable reports
green. Pair every qualified assertion with a `cover` showing the qualifier can
be true:

```systemverilog
f_par_onehot0  : assert (!$onehot0(req) || (d_par == d_if));
f_c_par_differs: cover  (!$onehot0(req) && (d_par != d_if));
```

**A failing `prove` with a passing `bmc` is usually not a bug.** It generally
means the inductive hypothesis is too weak — induction starts from an arbitrary
state, including unreachable ones. The fix is to add invariants that exclude
them, not to weaken the property. `skid_buffer` needed three
([docs/25](25-formal-verification-with-sby.md)).

**Say so when induction does not close.** `sync_fifo_fv` runs `bmc` at depth 30
plus `cover`, with the reason written into the `.sby` file. A bounded proof
stated as bounded is worth more than an unbounded claim that is not true.

---

## 7. Waveforms

A waveform is for confirming a hypothesis, not for forming one. Opening one with
no question in mind is how an afternoon disappears.

**Dump selectively.** Dumping everything in a large design is slow and produces
a file you cannot navigate.

```systemverilog
initial begin
  $dumpfile("dump.vcd");
  $dumpvars(1, tb.u_dut);        // depth 1: this level only
  $dumpvars(0, tb.u_dut.u_fsm);  // depth 0: everything below this one module
end
```

**Add the signals you wish you had.** A decoded state name, a cycle counter, a
transaction ID — these cost nothing under `` `ifndef SYNTHESIS `` and turn an
unreadable waveform into a readable one:

```systemverilog
`ifndef SYNTHESIS
  // enum .name() renders as text in the viewer, not as bits
  state_e state_dbg; assign state_dbg = state;
  int     cycle;     always_ff @(posedge clk) cycle <= cycle + 1;
`endif
```

If a state name renders as an empty string, the state is X, not a value you
forgot to add to the enum.

**Prefer a printed transaction log for protocol bugs.** Handshake problems are
easier to see as a list of transfers than as a wall of toggling signals:

```systemverilog
always_ff @(posedge clk)
  if (valid && ready) $display("%0t: xfer %h", $time, data);
```

---

## 8. Gate-level simulation

After synthesis, the netlist is re-simulated — with the same testbench, and
optionally with real delays back-annotated from an SDF file.

```bash
xelab -sdfmax /tb/u_dut=dut.sdf tb -s gls
```

It is slow and it is not a substitute for RTL simulation or STA. It exists to
catch the specific class of problem that neither of those can see:

| Finds | Why RTL sim misses it |
|---|---|
| X-optimism in the RTL | gates propagate X where `if`/`casex` hid it |
| Reset that never actually initialises everything | RTL flops may have initial values gates do not |
| Missing or wrong constraints | a path with real delay now violates |
| Scan chain and test-mode wiring | does not exist in RTL |
| Synthesis pragma mistakes | `full_case` divergence becomes visible |
| Clock gating and ICG behaviour | RTL models the enable, not the cell |

**Almost every GLS failure at time zero is a reset problem.** Gate-level flops
start at X and only a real reset clears them, whereas RTL flops may have
initialisers that quietly paper over an incomplete reset. If GLS is X-locked at
startup and RTL is not, the RTL reset is incomplete — that is a real bug that
would have appeared on silicon.

**The X-optimism catch is the main reason to bother.** An `if` with an X
condition takes the `else` branch in RTL and produces X in gates
([§2](#2-chasing-an-x)). A design that depends on that difference works in
simulation and does not work in hardware; GLS is where it shows up.

Run GLS at least: after the first synthesis, after any reset or clocking change,
and before tapeout. Zero-delay GLS (no SDF) catches the X and connectivity
problems cheaply; SDF-annotated GLS catches the timing-dependent ones and is
much slower.

---

## 9. A worked catalogue

Every one of these was found while building this repository, by the method in
the third column.

| Bug | Symptom | Found by |
|---|---|---|
| `div_const` product register sized to hold the product, not to reach the top of the shift | zeros for divisors with L > 2 | **formal**, first run |
| `useq` branched on wait conditions being true | every data check passed; protocol ran in 6 cycles | tracing an **internal** signal (`pc`) |
| `async_fifo` combinational loop through the full flag | elaboration | the tool, immediately |
| `requantize` unsigned cast made `>>>` a logical shift | every negative output became large positive | a **directed** negative-value test |
| `fir_systolic` latency is 1, not `NTAP`; coefficients indexed backwards | wrong output | an **impulse** test with asymmetric coefficients |
| `fp_mul` inferred latch on `dn_mask` | lint | yosys latch check |
| `fsm_tb` DUT inputs undriven until their own test | one-hot assertions failed, test still printed PASS | **the build**, after it was taught to fail on SVA errors |
| `fsm_tb` stimulus on the sampling edge | three identical designs "disagreed" | instrumenting all three side by side |
| `fsm_safe` recovery proof vacuous, twice | proof passed | **negative control** |
| `pipeline_tb` asserted a non-property | passed for the wrong reason | replacing it with a reference model |

Two patterns recur and are worth extracting:

**The interface can look perfect while the design is wrong.** `useq` produced
every correct output value. Check internal state when behaviour is right but
suspicious.

**A check that has never failed has not been shown to work.** Break the design
on purpose — negative controls for proofs, and at least one deliberate
mutation for a new testbench — before trusting a green result.

---

## 10. Checklist

**Before debugging**
- [ ] The failure reproduces on demand, with a printed seed.
- [ ] The case is minimised — smallest width, depth and vector count that still
      fails.
- [ ] Every testbench has a global timeout.

**While debugging**
- [ ] Working backwards from the first failing cycle, not forwards from the
      symptom.
- [ ] Internal state inspected, not just interfaces.
- [ ] Error output capped so the first failure is visible.
- [ ] A hypothesis formed before the waveform is opened.

**Trusting a green result**
- [ ] The build fails on a failing assertion, not just on a missing PASS line.
- [ ] Check counts asserted, so a skipped check cannot pass silently.
- [ ] Stimulus driven on the opposite edge from sampling.
- [ ] Every qualified assertion paired with a `cover` of its qualifier.
- [ ] A negative control run for every safety proof.
- [ ] Any bounded proof documented as bounded.

**Before tapeout**
- [ ] Zero-delay gate-level simulation clean from a real reset.
- [ ] SDF-annotated gate-level simulation run on the critical modes.
- [ ] No RTL behaviour depending on `if`/`casex` X-optimism.

---

## See also

- [docs/15: Scheduling and races](15-scheduling-and-race-conditions.md) — why
  driving and sampling on the same edge is a race
- [docs/16: Verification architecture](16-verification-architecture.md) —
  drivers, monitors and scoreboards
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) —
  X-optimism versus X-pessimism in full
- [docs/25: Formal with sby](25-formal-verification-with-sby.md) — reading a
  counterexample, and closing an induction proof
- [docs/27: Control structures](27-control-structures.md) — the measured X
  behaviour of `?:` versus `if`
- [docs/29: Memories](29-memories-and-inference.md) — X from uninitialised
  memory, and why not to hide it
