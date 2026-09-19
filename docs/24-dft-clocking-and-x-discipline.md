# DFT, Clocking, and X Discipline

Three topics that share a root cause: **the RTL decides whether the chip can be
tested, whether the clock tree can be built, and whether a bug shows up in
simulation or in silicon.** None of them are things you can add later.

Companion code:
[`ring_counter.sv`](../examples/rtl/ring_counter.sv) ·
[`reset_sync.sv`](../examples/rtl/reset_sync.sv) ·
[`cdc_bit.sv`](../examples/rtl/cdc_bit.sv) ·
[`signedness_demo.sv`](../examples/arith/signedness_demo.sv)

---

## Contents

- [1. Why DFT constrains RTL](#1-why-dft-constrains-rtl)
- [2. Scan, and what it demands](#2-scan-and-what-it-demands)
- [3. Generated and derived clocks](#3-generated-and-derived-clocks)
- [4. Clock enables and gating cells](#4-clock-enables-and-gating-cells)
- [5. Clock multiplexing](#5-clock-multiplexing)
- [6. Reset architecture for test](#6-reset-architecture-for-test)
- [7. Memories and DFT](#7-memories-and-dft)
- [8. X-optimism and X-pessimism](#8-x-optimism-and-x-pessimism)
- [9. X discipline in practice](#9-x-discipline-in-practice)
- [10. Checklists](#10-checklists)

---

## 1. Why DFT constrains RTL

A fabricated chip has manufacturing defects — a bridged pair of wires, an open
via, a transistor that switches slowly. Functional tests find almost none of
them, because they exercise a tiny fraction of the nodes. **Scan test** finds
them by turning every flip-flop in the design into a shift-register stage,
loading an arbitrary state, pulsing the clock once, and shifting the result out.

That works only if the test equipment can *control every flip-flop* and
*observe every flip-flop*. Everything in this section follows from those two
requirements.

The cost of getting it wrong is not a slower chip — it is a chip you cannot
test, which means you cannot tell a good die from a bad one, which means you
ship field failures. DFT problems are found at tape-out, when fixing them means
an RTL change and a full re-run.

---

## 2. Scan, and what it demands

In scan mode, flops are re-wired into chains:

```
  scan_in ──► FF ──► FF ──► FF ──► ... ──► FF ──► scan_out
                (every flop in the design, in some order)
```

Each flop becomes a mux plus a flop: in functional mode it takes `D`, in scan
mode it takes the previous flop's `Q`. The insertion tool does that
automatically — **provided the RTL lets it.**

### The requirements

| Requirement | Why | What breaks it |
|---|---|---|
| **Every clock controllable from a pin** | the tester must pulse each chain exactly once | a clock generated inside the RTL |
| **Every reset controllable from a pin** | an uncontrolled reset can wipe the loaded pattern | a reset driven by internal logic |
| **No latches** | latches are transparent; they do not shift | an unintended `always_comb` latch |
| **No combinational loops** | the value never settles, so the capture is unpredictable | `always_comb y = f(y)` |
| **No internal tri-state** | a bus with no active driver floats to `X` during shift | `assign bus = en ? d : 'z;` inside the chip |
| **No dead states** | a locked-up FSM cannot be scanned out of in some flows | a ring counter without self-correction |
| **Memories have a functional write path** | BIST and initialisation both need one | `initial $readmemh` as the only way in |

### Observability is half of it

Controllability gets a value in; **observability** gets the result out. A signal
that feeds nothing observable is untestable no matter what you do to it:

```systemverilog
// Untestable: `debug_count` is written but never read by anything the tester
// can see. A stuck-at fault on it is invisible.
logic [31:0] debug_count;
always_ff @(posedge clk) if (event_seen) debug_count <= debug_count + 1;
```

If you keep a counter for debug, bring it out to a register the CPU can read, or
accept that it is dead silicon. Synthesis will often delete it for you, which is
its own surprise.

---

## 3. Generated and derived clocks

**The rule: a clock comes from a pin, a PLL, or a clock-management cell. Never
from RTL logic.**

### What not to write

```systemverilog
// (a) Gated clock. Glitchy: any transition on `en` while clk is high produces
//     a spurious edge. Also invisible to the clock tree and to scan.
assign gclk = clk & en;
always_ff @(posedge gclk) q <= d;

// (b) Divided clock. A flop output is not a clock: it arrives late, it has no
//     balanced tree, and static timing cannot relate it to the source clock
//     without a `create_generated_clock` you now have to remember to write.
always_ff @(posedge clk) clk_div2 <= ~clk_div2;
always_ff @(posedge clk_div2) slow_q <= d;      // a second clock domain,
                                                //   created by accident

// (c) Clock from a mux with no glitch protection -- see section 5.
assign clk_sel = use_fast ? clk_fast : clk_slow;

// (d) Clock from combinational logic of any kind.
assign clk_local = clk ^ invert_bit;
```

Every one of these creates a clock the test infrastructure cannot reach. In
scan mode the tester drives the primary clock pin; a clock derived through RTL
logic either does not toggle at all (so those flops never shift) or toggles at
the wrong time (so the chain corrupts).

### What to write instead

```systemverilog
// (a) and (d) -> a clock ENABLE. One clock domain, fully scannable.
always_ff @(posedge clk) if (en) q <= d;

// (b) -> an enable pulse at the divided rate, still on the source clock.
logic [1:0] divcnt;
logic       tick;
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n) divcnt <= '0;
  else        divcnt <= divcnt + 1'b1;
assign tick = (divcnt == '0);                  // 1 cycle in 4

always_ff @(posedge clk) if (tick) slow_q <= d;
```

The enable-based form is better than a divided clock for reasons beyond DFT: one
clock domain instead of two, no CDC between them, one clock tree to balance, and
static timing analyses it without any extra constraints.

**When you genuinely need a slower clock** — for power, or to drive an external
device — generate it in the PLL/MMCM/clock-divider cell the technology provides,
declare it with `create_generated_clock`, and treat the boundary as a real clock
domain crossing ([docs/20](20-synthesis-subset-and-gotchas.md) G22).

---

## 4. Clock enables and gating cells

Clock gating is worth real power ([docs/22 §15](22-timing-closure-and-optimization.md#15-power-efficiency)),
and it is entirely compatible with DFT — *if you let the tool insert it.*

```systemverilog
// Write the enable. The tool infers an INTEGRATED CLOCK GATING cell (ICG),
// which is glitch-free by construction, gets proper clock-tree treatment, and
// has a test-enable input the DFT flow wires to scan_enable.
always_ff @(posedge clk) if (en) q <= d;
```

An ICG is a latch plus an AND, arranged so the enable is only sampled while the
clock is low:

```
        ┌─────────┐
  en ──►│D       Q├──┐
        │  latch  │  │    ┌───┐
  clk ─●│G        │  └───►│AND├──► gclk
       ││         │       │   │
       │└─────────┘  ┌───►└───┘
       └─────────────┘
       (plus an OR with scan_enable, so scan always clocks)
```

That `scan_enable` OR is why hand-rolled clock gating breaks test: your
`clk & en` has no test input, so during scan shift the gated flops do not clock
and their chain segment dies.

### Helping the tool

- **Group registers that share an enable.** An ICG has a cost; it pays off
  across roughly 8+ flops, not across 2.
- **Gate coarsely as well as finely.** One enable for an idle block beats
  per-register enables inside it.
- **Do not hide the enable.** If the condition exists but is buried behind three
  levels of logic, hoist it so the tool can recognise it.

---

## 5. Clock multiplexing

Occasionally you really must switch a block between two clocks. A plain mux
produces a runt pulse if it switches while either clock is high. The standard
solution is a **glitch-free clock mux**: synchronize the select into each
domain, and only enable a clock once the other has been confirmed off.

```systemverilog
// Sketch only -- use the technology's clock-mux cell if there is one, because
// this needs careful constraint and timing treatment.
// Each side: two flops on the NEGATIVE edge of its own clock, and it may only
// turn on once the other side reports off.
logic sel_a_q1, sel_a_q2, sel_b_q1, sel_b_q2;

always_ff @(negedge clk_a or negedge rst_n)
  if (!rst_n) {sel_a_q2, sel_a_q1} <= 2'b00;
  else        {sel_a_q2, sel_a_q1} <= {sel_a_q1, ~sel && ~sel_b_q2};

always_ff @(negedge clk_b or negedge rst_n)
  if (!rst_n) {sel_b_q2, sel_b_q1} <= 2'b00;
  else        {sel_b_q2, sel_b_q1} <= {sel_b_q1,  sel && ~sel_a_q2};

assign clk_out = (clk_a && sel_a_q2) || (clk_b && sel_b_q2);
```

Negative-edge sampling is what guarantees the enable changes while its clock is
low, so the final AND-OR can never produce a runt. Both clocks must be running
for the switch to complete — if one is stopped, the mux hangs in the safe state,
which is usually what you want but must be designed for.

For DFT, the mux needs a test override that forces a known selection.

---

## 6. Reset architecture for test

Reset choices interact with DFT as much as with timing
([docs/22 §11](22-timing-closure-and-optimization.md#11-reset-strategy)).

| Requirement | Reason |
|---|---|
| **Reset must be controllable from a pin in test mode** | otherwise the tester cannot establish a known state, and an internally-driven reset can fire mid-pattern and wipe it |
| **Asynchronous resets need a test-mode bypass** | during scan shift, an async reset that fires asynchronously corrupts the chain. The DFT flow muxes `scan_reset` in |
| **One polarity and style per clock domain** | a mixed tree cannot be balanced, and recovery/removal checks multiply |
| **Reset release must be synchronized** | [`reset_sync.sv`](../examples/rtl/reset_sync.sv) — otherwise flops leave reset on different cycles |

```systemverilog
// The shape DFT expects: the functional reset is OR'd with a test reset that
// the tester controls directly. Usually inserted by the DFT tool, but it has to
// be possible -- which means the reset must reach the flops through a net the
// tool can find, not through scattered ad-hoc logic.
assign rst_n_int = test_mode ? scan_rst_n : func_rst_n;
```

And the rule from [docs/21](21-pipelining.md#3-latency-matching) applies here
too, for a third reason: **do not reset datapath pipeline registers.** Fewer
resets means a smaller reset tree, easier recovery/removal closure, retiming
stays possible — and the scan chain does not have to fight an async reset on
every flop.

---

## 7. Memories and DFT

Scan chains cannot reach inside a RAM. Memories are tested by **BIST** — a small
engine that writes patterns, reads them back, and compares.

What the RTL must provide:

- **A functional write path.** `initial $readmemh(...)` is not one. If the only
  way to initialise a memory is a simulation construct, BIST cannot use it and
  neither can the boot sequence.
- **A way to isolate the memory.** BIST needs to drive the address/data/enable
  pins directly, so there must be a mux point — again usually tool-inserted, but
  the RTL must not make it impossible (for example by burying the RAM behind
  logic with no clean boundary).
- **Known behaviour on collision.** [`ram_sdp.sv`](../examples/rtl/ram_sdp.sv)
  leaves same-address read/write undefined; that is fine functionally if nothing
  relies on it, but a BIST pattern that hits it will report a mismatch.

```systemverilog
// Acceptable: a preload path that is real logic, usable by BIST, boot code and
// simulation alike.
always_ff @(posedge clk)
  if (init_en)      mem[init_addr] <= init_data;
  else if (we)      mem[addr]      <= din;
```

---

## 8. X-optimism and X-pessimism

`X` is a *modelling device*, not a value that exists in silicon. Real hardware
always has some voltage on every node; `X` means "this simulation cannot tell
you what it is." Two ways that model diverges from reality, in opposite
directions.

### X-optimism: simulation is more certain than hardware

The simulator resolves an `X` into a definite value where the hardware would do
something unpredictable. **This hides bugs.**

```systemverilog
// (a) casex -- the classic. An X in the case EXPRESSION matches a branch.
//     An unreset control signal silently takes a real path.
casex (state)
  4'b1xxx: do_something();     // matches even when `state` is genuinely X
endcase

// (b) A comparison against X in an `if`. `if (x)` with x === 1'bx is FALSE,
//     so the else branch runs -- a decision was made from no information.
if (maybe_x) a(); else b();    // takes b(), deterministically

// (c) Two-state types. `bit` cannot hold X at all, so an uninitialised
//     register reads as 0 and the reset bug simulates perfectly.
bit [7:0] counter;             // starts at 0 -- in simulation only
```

**Fixes:** use `casez` (or `case ... inside`) rather than `casex`; use `logic`
not `bit` in RTL; and assert `!$isunknown()` on control signals at module
boundaries.

### X-pessimism: simulation is less certain than hardware

Gate-level simulation propagates `X` where the real circuit settles to a
definite value. **This produces false failures** and floods the log.

```systemverilog
// A mux with an X select. RTL: the ternary merges bitwise, so bits where the
// two arms AGREE keep their value -- reasonably faithful.
y = sel ? 4'b1100 : 4'b1010;   // -> 4'b1xx0 when sel is X

// The same mux at gate level, built from AND-OR, produces X on ALL four bits,
// because each gate sees an X input independently. The real silicon picks one
// input and gives a definite answer.
```

X-pessimism is why gate-level simulation of a reset sequence often shows the
whole chip as `X` for hundreds of cycles, and why teams end up force-initialising
the netlist just to make it run.

### The asymmetry that matters

| | Effect | Consequence |
|---|---|---|
| **X-optimism** | bug hidden | ships |
| **X-pessimism** | false failure | wastes time |

X-optimism is the dangerous one. A design that "passes" because the simulator
resolved an unknown into the branch you wanted is a design that will fail on
silicon, intermittently, at temperature.

### What each tool here can tell you

| | XSIM | SymbiYosys (yosys) |
|---|---|---|
| Value system | **4-state** — models `X` propagation | **2-valued** — no `X` at all |
| Finds unreset registers | yes, if the `X` reaches an assertion or a `$display` | no — but see below |

The formal flow has no `X`, which sounds like a loss and is not: **formal starts
from an arbitrary state**, which is a strictly stronger way to ask the same
question. Where simulation needs an `X` to notice that a register was never
initialised, induction simply tries every possible initial value and reports one
that breaks the property. That is exactly how
[`ring_counter`](../examples/rtl/ring_counter.sv)'s self-correction is verified
— see [docs/25 §6](25-formal-verification-with-sby.md#6-when-induction-fails).

`examples/arith/signedness_demo.sv` includes a live X-merge check
(`x ? 4'b1100 : 4'b1010` must give `4'b1xx0`) which XSIM passes, and which
detects and skips itself on a 2-state engine.

---

## 9. X discipline in practice

### Reset the control path

The single highest-value rule, and the same one that
[docs/21](21-pipelining.md#3-latency-matching) and
[docs/22](22-timing-closure-and-optimization.md#11-reset-strategy) arrive at from
timing and area:

> **Reset everything that makes a decision. Reset nothing that merely carries
> data.**

A datapath register holding `X` is harmless — the valid bit beside it says the
contents are meaningless. A *control* register holding `X` steers the design
into an undefined state, and that is what propagates.

### Assert against X at the boundaries

```systemverilog
// The trip-wire. In a 4-state simulator this finds an enormous class of bugs:
// unreset registers, latency mismatches, uninitialised memory reads.
a_no_x_when_valid: assert property (@(posedge clk) disable iff (!rst_n)
  valid |-> !$isunknown(data))
  else $error("valid asserted over undefined data");

// And on control, unconditionally after reset.
a_state_known: assert property (@(posedge clk) disable iff (!rst_n)
  !$isunknown(state));
```

Put these at every module boundary. They cost nothing in synthesis
(`` `ifndef SYNTHESIS ``) and they turn a silent `X` into a named failure at the
exact cycle and module where it originated, instead of three blocks downstream.

### Do not "fix" X with initial values

```systemverilog
// Tempting, and wrong for ASIC: this makes simulation agree with a power-on
// state the silicon does not have.
logic [7:0] state = 8'h00;
```

On an FPGA this is legitimate — the bitstream really does set it. On an ASIC it
is a simulation-only lie that hides the missing reset. See
[docs/02](02-data-types.md#default-values-and-initialization).

### X-propagation analysis

The rigorous version of all this is **X-propagation** (or "X-prop") analysis: a
mode in which the tool deliberately models `X` pessimistically at every
decision point, so an unknown cannot be optimistically resolved. Commercial
simulators offer it as a switch. The open-source substitute available here is
formal's arbitrary-initial-state search, which covers the same ground for the
modules the frontend can read.

---

## 10. Checklists

### DFT

- [ ] No clock generated, gated, divided, inverted or muxed in RTL
- [ ] Every clock reaches its flops from a pin or a clock cell
- [ ] Every reset is controllable in test mode
- [ ] No inferred latches anywhere (`always_comb` with a default assignment)
- [ ] No combinational loops
- [ ] No internal tri-state; `Z` only at I/O pads
- [ ] FSMs have a `default` branch that recovers; no dead states
- [ ] Ring/one-hot counters are self-correcting
- [ ] Memories have a functional write path, not only `initial`
- [ ] Debug counters are readable by something, or deleted

### Clocking

- [ ] Clock domains enumerated and written down
- [ ] Clock enables, never gated clocks, in RTL
- [ ] Registers sharing an enable grouped so one ICG serves many
- [ ] Any real clock division done in a PLL/MMCM, with `create_generated_clock`
- [ ] Every domain crossing has a synchronizer
      ([`cdc_bit.sv`](../examples/rtl/cdc_bit.sv)) or a proper handshake
- [ ] No multi-bit bus crossing through per-bit synchronizers
- [ ] Reset release synchronized per domain
      ([`reset_sync.sv`](../examples/rtl/reset_sync.sv))

### X discipline

- [ ] `logic`, not `bit`, in RTL
- [ ] `casez` / `case ... inside`, never `casex`
- [ ] Every control register reset; datapath registers deliberately not
- [ ] `!$isunknown()` assertions on control and on valid-qualified data
- [ ] No declaration initialisers standing in for a reset (ASIC)
- [ ] At least one 4-state simulation over the reset and power-on sequence
- [ ] Formal run from an arbitrary initial state where the frontend allows it

---

## See also

- [docs/20: Synthesis subset and gotchas](20-synthesis-subset-and-gotchas.md) —
  G22 (CDC), G23 (gated clocks), G24 (reset release)
- [docs/21: Pipelining](21-pipelining.md) — reset the control path, not the data
  path
- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — reset
  strategy, clock gating for power
- [docs/25: Formal with sby](25-formal-verification-with-sby.md) — arbitrary
  initial state as a stronger substitute for X-propagation
- [docs/02: Data types](02-data-types.md) — 4-state vs 2-state, and why it
  matters
