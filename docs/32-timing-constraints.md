# Timing Constraints

RTL describes what the hardware does. Constraints describe **what it must do it
by**, and without them a synthesis tool has no target and a timing report has no
meaning. An unconstrained design does not fail timing — it reports nothing, and
ships broken.

This document is about the timing environment: defining clocks, describing the
world outside the chip, and the relationship between an RTL construct and the
constraint it obliges you to write.
[docs/22 §12](22-timing-closure-and-optimization.md#12-constraints-multicycle-and-false-paths)
covers the *exceptions* — multicycle and false paths — and when they are
justified; this one covers everything that has to be right before an exception
means anything.

The syntax is SDC (Synopsys Design Constraints), a Tcl dialect understood by
Design Compiler, Genus, Vivado, Quartus and the open tools.

---

## Contents

- [1. The four things a tool needs](#1-the-four-things-a-tool-needs)
- [2. Defining clocks](#2-defining-clocks)
- [3. Generated and derived clocks](#3-generated-and-derived-clocks)
- [4. Clock uncertainty and latency](#4-clock-uncertainty-and-latency)
- [5. Asynchronous clock groups](#5-asynchronous-clock-groups)
- [6. Input and output delay](#6-input-and-output-delay)
- [7. Exception precedence](#7-exception-precedence)
- [8. What the RTL obliges you to constrain](#8-what-the-rtl-obliges-you-to-constrain)
- [9. Checking the constraints themselves](#9-checking-the-constraints-themselves)
- [10. Checklist](#10-checklist)

---

## 1. The four things a tool needs

Static timing analysis computes, for every path, whether data launched by one
clock edge arrives before the capturing edge. To do that it needs:

1. **Every clock defined**, with period and waveform.
2. **The relationship between clocks** — synchronous, or asynchronous and not to
   be timed together.
3. **The world outside the block** — how late inputs arrive and how early
   outputs are needed.
4. **The exceptions** — paths that are not single-cycle, or not real.

Miss the first and paths go unanalysed. Miss the second and the tool either
wastes effort on impossible relationships or misses real ones. Miss the third
and the I/O is unconstrained, which is the most common real-world gap. Miss the
fourth and the tool chases paths that do not matter.

> **Unconstrained is not "passing".** A path with no clock at its endpoint is
> simply not reported. Always check the *unconstrained paths* section of the
> report, not just the worst negative slack.

---

## 2. Defining clocks

```tcl
# A primary clock: on a port, from an oscillator or pad.
create_clock -name clk_sys -period 5.0 [get_ports clk_i]

# Explicit waveform: rise at 0, fall at 2.0 -- a 40% duty cycle
create_clock -name clk_ddr -period 5.0 -waveform {0 2.0} [get_ports clk_ddr_i]
```

`-period` is in the units of the library (usually ns). The default waveform is
50% duty: `{0 period/2}`.

**Name every clock.** Without `-name`, the clock takes the name of the object it
is attached to, and every later constraint that refers to it becomes dependent
on a port name that may change.

**A virtual clock** has no source object and exists only to describe the timing
of something outside the design:

```tcl
create_clock -name clk_virt_in -period 5.0          # no port argument
set_input_delay -clock clk_virt_in 2.0 [get_ports data_i]
```

Use one when the external device's clock is not physically connected to this
block, which is the normal case for I/O timing on an ASIC.

---

## 3. Generated and derived clocks

Any clock produced *inside* the design from another clock must be declared, or
the tool will not know the two are related and will time them as if they were
independent.

```tcl
# A divide-by-2 produced by RTL
create_generated_clock -name clk_div2 -source [get_ports clk_i] -divide_by 2 \
  [get_pins u_div/clk_out_reg/Q]

# A PLL output: usually created automatically by the vendor flow
create_generated_clock -name clk_x4 -source [get_pins u_pll/CLKIN] \
  -multiply_by 4 [get_pins u_pll/CLKOUT0]
```

The tool then knows `clk_div2` and `clk_i` share a source and can compute the
real edge relationship between them.

### Divided clocks versus clock enables

This is the point where RTL and constraints meet, and the RTL choice is almost
always the one to change.

```systemverilog
// A DERIVED CLOCK: needs a create_generated_clock, adds a clock domain,
// adds skew, complicates DFT, and cannot be gated cleanly.
always_ff @(posedge clk) clk_div2 <= ~clk_div2;
always_ff @(posedge clk_div2) ...        // a second clock domain

// A CLOCK ENABLE: one clock domain, no new constraints, scan-friendly.
always_ff @(posedge clk) if (tick) ...
```

**Prefer the enable.** A clock produced by logic has skew relative to its
parent, needs its own tree, is hard to balance, and breaks scan unless bypassed
in test mode. [docs/24](24-dft-clocking-and-x-discipline.md) covers why a clock
may never come from combinational logic, and what an ICG cell does when you do
need to gate one.

Reserve generated clocks for things that genuinely are clocks: PLL and MMCM
outputs, and clocks that leave the chip.

---

## 4. Clock uncertainty and latency

```tcl
set_clock_uncertainty -setup 0.15 [get_clocks clk_sys]
set_clock_uncertainty -hold  0.05 [get_clocks clk_sys]

set_clock_latency -source 1.2 [get_clocks clk_sys]     # off-chip, to the pad
set_clock_latency 0.4 [get_clocks clk_sys]             # on-chip, pad to leaf
```

**Uncertainty** is the margin that covers jitter, and — before the clock tree is
built — the skew the tree will eventually have. Pre-CTS it should include an
estimate of skew; post-CTS the real skew is known and uncertainty drops to
jitter plus a guard band. Forgetting to reduce it post-CTS leaves the design
over-constrained and the tool working on paths that already pass.

**Latency** is insertion delay. `-source` is from the true origin to the
definition point; the plain form is from the definition point to the flops. Both
matter for I/O timing and for relationships between clocks with different tree
depths.

Between two clocks, what matters is the *difference*. Two domains with equal
latency need none of this to be exact; a fast domain feeding a slow one with a
much deeper tree does.

---

## 5. Asynchronous clock groups

Clocks with no fixed phase relationship must be declared as such, or the tool
will try to time paths between them against an arbitrary and meaningless edge
relationship — usually the worst possible one, which is unachievable.

```tcl
set_clock_groups -asynchronous \
  -group {clk_sys clk_sys_div2} \
  -group {clk_usb} \
  -group {clk_ddr}
```

Clocks in the *same* group are timed against each other; clocks in different
groups are not. Note `clk_sys` and its divided version share a group, because
they are genuinely related.

`-logically_exclusive` and `-physically_exclusive` are for clocks that exist on
the same net but never at the same time — the two inputs of a clock mux. Use
those rather than `-asynchronous` for a mux, because they describe the actual
situation.

### This is not the CDC constraint

`set_clock_groups -asynchronous` stops the *analysis* between domains. It does
not bound the delay on the crossing path, so the router is free to produce
arbitrary skew between two signals crossing together. For the crossings
themselves:

```tcl
set_max_delay -datapath_only -from [get_clocks clk_a] \
                             -to   [get_clocks clk_b] 4.0
```

`-datapath_only` bounds the data path while ignoring the clock relationship,
which is exactly the semantics of a CDC path. See
[docs/28 §10](28-clock-domain-crossing.md#10-what-you-must-tell-the-tools) — and
note that `ASYNC_REG` on the synchroniser flops is doing separate and equally
necessary work.

---

## 6. Input and output delay

This is the most commonly missed constraint, because a block with no I/O
constraints reports clean timing while its interfaces are entirely unanalysed.

```tcl
# Data arrives at data_i up to 2.0ns after the launching clock edge
set_input_delay -clock clk_sys -max 2.0 [get_ports data_i]
set_input_delay -clock clk_sys -min 0.4 [get_ports data_i]

# The external device needs dout stable 1.5ns before its capture edge
set_output_delay -clock clk_sys -max 1.5 [get_ports data_o]
set_output_delay -clock clk_sys -min -0.2 [get_ports data_o]
```

The mental model: these numbers describe **the other side of the boundary**.
`set_input_delay -max` is how much of the period is already spent before the
signal reaches your port, so the remainder is what your logic gets.

```
     |<--------------- period --------------->|
     |<-- input_delay -->|<-- your logic -->|setup|
```

- `-max` constrains **setup**: the biggest external delay leaves the least time
  inside.
- `-min` constrains **hold**: the smallest external delay risks data arriving
  too early and racing through.

**Both are required.** Specifying only `-max` leaves hold unanalysed at the
boundary, and hold failures cannot be fixed later by slowing the clock.

For source-synchronous interfaces, the data is accompanied by its own clock, so
constrain against that clock (created with `create_clock` on the incoming clock
port) rather than the internal one.

---

## 7. Exception precedence

When several exceptions match a path, they do not combine. A fixed precedence
applies, strongest first:

| Priority | Exception |
|---|---|
| 1 (highest) | `set_false_path` |
| 2 | `set_max_delay` / `set_min_delay` |
| 3 | `set_multicycle_path` |
| 4 (lowest) | the default single-cycle relationship |

Within one type, the more specific object wins: `-from`/`-to` on a pin beats one
on a clock. The practical consequences:

- **A false path silences everything else on that path.** A `set_max_delay` you
  wrote for a CDC crossing does nothing if a broad `set_false_path` between the
  same clocks also matches. This is the usual reason a CDC delay bound turns out
  not to be applied.
- **Broad exceptions are dangerous** precisely because they win. `-from
  [get_clocks a] -to [get_clocks b]` covers every path between the domains,
  including ones you did not think about.

Always check what was actually applied:

```tcl
report_exceptions                          # Vivado
report_timing -from ... -to ...            # and read the "ignored" notes
check_timing                               # unconstrained endpoints, and more
```

---

## 8. What the RTL obliges you to constrain

Most constraint bugs start as an RTL decision. The table is worth keeping in
mind while writing the RTL, because the left column is almost always avoidable.

| RTL construct | Constraint it obliges | Better RTL |
|---|---|---|
| Clock from a flop output | `create_generated_clock` + its own tree | a clock enable ([§3](#3-generated-and-derived-clocks)) |
| Clock through a mux | `set_clock_groups -physically_exclusive` | a glitch-free mux, still constrained |
| Clock gated by logic | generated clock + DFT bypass | an ICG cell, or an enable |
| Signal crossing domains | `set_max_delay -datapath_only` + `ASYNC_REG` | — this one is correct, just constrain it |
| Config register read by the datapath | `set_multicycle_path` (setup **and** hold) | — fine, if the RTL guarantees the slow change |
| Combinational path between blocks | `set_max_delay`, or nothing and hope | register the interface ([docs/30](30-flow-control-and-handshakes.md)) |
| Async reset | recovery/removal analysis; release must be synchronised | [`reset_sync.sv`](../examples/rtl/reset_sync.sv) |

Two entries deserve repeating because they cause silent failures:

**A multicycle path needs a `-hold` constraint too.** Relaxing setup by N cycles
without adjusting hold is the classic multicycle mistake, and produces either
hold violations or gratuitous buffering. See
[docs/22 §12](22-timing-closure-and-optimization.md#12-constraints-multicycle-and-false-paths).

**A multicycle is a claim about the RTL.** If the constraint says a path has four
cycles, the RTL must *guarantee* the source cannot change faster than that.
Assert it, so the claim is checked where it is made:

```systemverilog
a_cfg_slow: assert property (@(posedge clk) disable iff (!rst_n)
  $changed(cfg_reg) |=> $stable(cfg_reg)[*3])
  else $error("cfg_reg changed faster than its multicycle constraint allows");
```

---

## 9. Checking the constraints themselves

Constraints are code, and they are code nothing type-checks. A typo in a
`get_pins` pattern matches nothing, applies to nothing, and reports nothing.

```tcl
check_timing                    # unconstrained endpoints, missing I/O delay,
                                # combinational loops, unclocked registers
report_clocks                   # every clock, its period and its source
report_clock_interaction        # which domain pairs are timed, and how
report_exceptions               # what was applied, and what was overridden
report_cdc                      # Vivado's structural CDC checks
all_registers -clock clk_sys    # sanity: is this clock reaching anything?
```

Two habits that catch most of it:

**Make an empty match an error.** A constraint that matched nothing is almost
always a bug, not a no-op:

```tcl
set pins [get_pins u_div/clk_out_reg/Q]
if {[llength $pins] == 0} { error "clk_div2 source pin not found" }
create_generated_clock -name clk_div2 -source [get_ports clk_i] -divide_by 2 $pins
```

**Diff the reports, not the constraints.** `report_clock_interaction` before and
after a change tells you what actually moved. A constraint file diff tells you
what you intended.

> Constraints must survive RTL edits. A `get_pins` path through a hierarchy is
> broken by a rename or a retime; a `get_cells` pattern matching `cfg_reg*` is
> broken by a signal called `cfg_register`. Prefer matching on things the RTL
> guarantees — a named generate block ([docs/06](06-modules-parameters-generate.md))
> is far more stable than an inferred register name.

---

## 10. Checklist

**Environment**
- [ ] Every clock defined, and named with `-name`.
- [ ] Every generated clock declared, with the right `-source`.
- [ ] Clock groups declared for every genuinely asynchronous pair.
- [ ] Uncertainty set, and reduced after CTS rather than left at the pre-CTS
      estimate.
- [ ] `set_input_delay` and `set_output_delay` on every port, **both** `-max`
      and `-min`.

**Exceptions**
- [ ] Every false path justified by a structural argument in the RTL, in a
      comment next to the constraint.
- [ ] Every multicycle has a matching `-hold`.
- [ ] Every multicycle's assumption asserted in the RTL.
- [ ] No broad false path shadowing a CDC `set_max_delay`.

**Crossings**
- [ ] `set_max_delay -datapath_only` on CDC paths, not a bare false path.
- [ ] `ASYNC_REG` on synchroniser flops, and confirmed in the synthesis report.

**Verification**
- [ ] `check_timing` run and clean.
- [ ] Unconstrained-path count is zero, and checked — not inferred from a clean
      worst-slack number.
- [ ] Every constraint confirmed to match something.

---

## See also

- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — reading a
  timing report, the path taxonomy, and when an exception is justified
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) — why a
  clock may never come from logic, ICG cells, glitch-free clock muxing
- [docs/28: Clock domain crossing](28-clock-domain-crossing.md) — the CDC
  constraints and what they do not cover
- [docs/21: Pipelining](21-pipelining.md) — adding a stage instead of relaxing a
  constraint
- [docs/30: Flow control](30-flow-control-and-handshakes.md) — registering an
  interface so it needs no `set_max_delay`
