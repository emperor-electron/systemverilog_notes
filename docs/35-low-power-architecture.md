# Low-Power Architecture and Power Intent

[docs/22 §15](22-timing-closure-and-optimization.md#15-power-efficiency) covers
the levers you pull *inside* the RTL: clock gating, operand isolation, encoding
for low activity. This document covers the level above that — turning parts of
the chip off, running them at different voltages, and the fact that **none of
that appears in the RTL at all**.

Power intent lives in a separate file (UPF or CPF). The RTL stays functionally
complete and power-unaware, and the tools insert isolation cells, level shifters
and retention flops from the intent file. That separation is deliberate and it
has a consequence worth stating up front: **a design can be functionally correct
and completely broken by power gating**, because the failure is in the
interaction between two descriptions that are written by different people and
checked by neither one alone.

---

## Contents

- [1. Where the power goes](#1-where-the-power-goes)
- [2. The hierarchy of savings](#2-the-hierarchy-of-savings)
- [3. Power domains](#3-power-domains)
- [4. Isolation](#4-isolation)
- [5. Retention](#5-retention)
- [6. Level shifters and multi-voltage](#6-level-shifters-and-multi-voltage)
- [7. DVFS](#7-dvfs)
- [8. What the RTL must still provide](#8-what-the-rtl-must-still-provide)
- [9. Power-aware verification](#9-power-aware-verification)
- [10. Checklist](#10-checklist)

---

## 1. Where the power goes

```
P_total  =  α · C · V² · f     +     V · I_leak
            └── dynamic ──┘           └ static ┘
```

| Term | Reduce by |
|---|---|
| `α` activity factor | clock gating, operand isolation, encoding |
| `C` switched capacitance | smaller logic, shorter wires, less fanout |
| `V` supply voltage | **the only quadratic term** — voltage scaling, DVFS |
| `f` frequency | run slower, or finish sooner and stop |
| `I_leak` | power gating, multi-Vt cells, lower temperature |

Two consequences drive everything below.

**Voltage is quadratic and everything else is linear.** Halving the voltage
quarters dynamic power. No amount of clock gating competes with that, which is
why multi-voltage and DVFS exist despite their complexity.

**Leakage does not care whether anything is happening.** A block that is idle
but powered still leaks, and at modern nodes leakage can be a third of total
power. Clock gating does nothing for it — the only cure is removing the supply,
which is power gating.

---

## 2. The hierarchy of savings

Ordered by benefit per unit of pain. Work down the list; do not start at the
bottom.

| Technique | Saves | Cost | Where it lives |
|---|---|---|---|
| Do less work (algorithm, architecture) | everything | design time | architecture |
| Clock gating | dynamic | almost none | **RTL** (an enable) |
| Operand isolation | dynamic | small | **RTL** |
| Memory enables | dynamic, a lot | none | **RTL** |
| Low-activity encoding | dynamic | small | **RTL** |
| Multi-Vt cell selection | leakage | timing | synthesis |
| Multi-voltage | dynamic (quadratic) | level shifters, complexity | **power intent** |
| Power gating | leakage | isolation, retention, wake latency | **power intent** |
| DVFS | both | control, characterisation, verification | system |

Note where the line falls. Everything in the top half is ordinary RTL you write
and verify normally. Everything in the bottom half changes what the netlist *is*
and needs its own verification strategy (§9).

**Memory enables deserve their own mention** because they are the largest easy
win in most designs and are frequently missed. A block RAM with `en` tied high
burns read power every cycle regardless of whether anyone uses the result:

```systemverilog
// Burns a read every cycle
always_ff @(posedge clk) dout <= mem[addr];

// Reads only when asked
always_ff @(posedge clk) if (en) dout <= mem[addr];
```

The second form is also what infers correctly ([docs/29](29-memories-and-inference.md)).
Note that `dout` now *holds* when `en` is low, which is a behaviour the readers
must tolerate — and a stale value is not an X, so it will not announce itself.

---

## 3. Power domains

A power domain is a set of instances sharing a supply that can be switched
independently. Once a domain can be off while its neighbour is on, three new
problems appear at every boundary:

1. Outputs of the off domain float, driving X into the on domain → **isolation**.
2. State in the off domain is lost → **retention**, if it is needed after wake.
3. Domains at different voltages cannot drive each other → **level shifters**.

Power intent describes all of this. In UPF:

```tcl
create_power_domain PD_TOP
create_power_domain PD_CPU -elements {u_cpu}

create_supply_port  VDD ; create_supply_net VDD
create_supply_net   VDD_CPU
create_power_switch cpu_sw -domain PD_CPU \
  -input_supply_port  {in  VDD} \
  -output_supply_port {out VDD_CPU} \
  -control_port       {sw_en pwr_ctrl/cpu_on} \
  -on_state {on in {sw_en}}
```

**Partition on architectural boundaries, not on convenience.** A domain should
be something that is genuinely idle for long enough to be worth the wake
latency — an accelerator, a radio, a whole CPU cluster. Gating a small block
costs more in isolation cells, retention flops and always-on routing than it
saves.

**The controller must be always-on.** Whatever decides to turn a domain back on
cannot itself be in that domain. The always-on domain holds the power
controller, the reset logic, and usually a small amount of state.

---

## 4. Isolation

When a domain loses power, its outputs are undriven. Undriven inputs to a
powered domain are not merely unknown — they float near the switching threshold
and can cause **crowbar current** in the receiving gates, which is a power and
reliability problem, not just a functional one.

Isolation cells clamp every crossing signal to a defined value while the source
domain is off:

```tcl
set_isolation cpu_iso -domain PD_CPU \
  -isolation_power_net VDD -isolation_ground_net VSS \
  -clamp_value 0 -applies_to outputs
set_isolation_control cpu_iso -domain PD_CPU \
  -isolation_signal pwr_ctrl/cpu_iso_en -isolation_sense high
```

**The clamp value is a design decision, not a default.** It must be the value
that is *safe* for the receiver, which is rarely "whatever is cheapest":

| Signal | Safe clamp | Why |
|---|---|---|
| `valid`, `req` | 0 | an isolated request must not look like a real one |
| `ready` | 0 (usually) | do not accept transfers into a dead block |
| `rst_n` | 0 | hold the receiver's view in reset |
| An active-low interrupt | 1 | clamping to 0 asserts an interrupt forever |
| Bus data | anything, if qualified by an isolated `valid` | |

Getting one of these backwards produces a spurious transaction at exactly the
moment a block powers down — and it will not appear in an RTL simulation,
because the RTL has no isolation cells in it.

**Isolation must be enabled before the supply goes, and released after it comes
back.** That ordering is the power controller's job and is the most common
sequencing bug.

---

## 5. Retention

A retention flop keeps its value on a separate always-on supply while the main
supply is off. It costs area and leakage of its own, so it is applied
selectively:

```tcl
set_retention cpu_ret -domain PD_CPU \
  -retention_power_net VDD -retention_ground_net VSS
set_retention_control cpu_ret -domain PD_CPU \
  -save_signal  {pwr_ctrl/cpu_save  posedge} \
  -restore_signal {pwr_ctrl/cpu_restore posedge}
```

**Retain the minimum.** Configuration registers and a little control state,
usually. Not the datapath, not the pipeline, not caches — those are cheaper to
refill than to retain.

The alternatives are worth considering first, because both are cheaper:

- **Save to always-on memory** before powering down, restore after. Slower, but
  no retention cells and no extra leakage in the retained flops.
- **Just start over.** If the block can be reinitialised in a few microseconds
  and it is off for milliseconds, retention is solving a problem you do not
  have.

**The save/restore sequence is where the bugs are.** Save must happen after the
domain is quiescent and before isolation and power-down; restore must happen
after power is stable and before isolation is released. A retained flop whose
save fired mid-transaction restores a state that never legally existed.

---

## 6. Level shifters and multi-voltage

Two domains at different voltages cannot drive each other directly: a 0.7 V
signal into a 1.0 V gate may not reach the threshold, and a 1.0 V signal into a
0.7 V gate can forward-bias its protection.

```tcl
set_level_shifter cpu_ls -domain PD_CPU -applies_to outputs \
  -rule both -location self
```

Two practical points:

**Level shifters have real delay**, and it varies with both supplies. A
multi-voltage crossing needs its own timing analysis at every corner *pair*,
which multiplies the corner count.

**Combine with isolation where both are needed.** A crossing from a gated
low-voltage domain to an always-on high-voltage one needs an enable-level-shifter
— one cell doing both jobs, which is cheaper and has less delay than two in
series.

**Keep crossings few and registered.** Every crossing is a cell, a timing
analysis and a verification obligation. Cross at a registered, handshaked
boundary and the count stays small — which is the same advice as for clock
domains ([docs/28](28-clock-domain-crossing.md)), for the same reason.

---

## 7. DVFS

Dynamic voltage and frequency scaling exploits the quadratic term at run time:
lower the frequency when the workload allows, then lower the voltage, because a
slower circuit needs less of it.

The order matters and is not symmetric:

- **Slowing down:** reduce frequency *first*, then voltage.
- **Speeding up:** raise voltage *first*, wait for it to settle, then frequency.

Getting this backwards means running fast at a voltage that cannot support the
critical path, which is a timing failure that appears only during a transition.

**"Race to idle" is often better than DVFS**, and is worth checking before
committing to the complexity. Running at full speed and then power-gating can
beat running slowly forever, because leakage accrues the whole time the block is
on. Which wins depends on the leakage-to-dynamic ratio and the wake latency —
measure rather than assume.

From the RTL's point of view, DVFS mostly means the design must tolerate
**frequency changes without losing state**, and that every clock crossing
remains valid at every ratio — which it does, if the crossings were built
correctly, because a correct CDC makes no assumption about relative frequency.

---

## 8. What the RTL must still provide

Power intent is a separate file, but it is not independent of the RTL. Several
things must exist in the design for the intent to be implementable:

**Explicit enables for everything gateable.** Write the enable; let the tool
insert the ICG cell. A clock produced by logic is not a gated clock, it is a
generated clock and a DFT problem ([docs/24](24-dft-clocking-and-x-discipline.md),
[docs/32 §3](32-timing-constraints.md#3-generated-and-derived-clocks)).

**A quiescence indication per domain.** Something must be able to say "this
block has no outstanding transactions and can be powered down". A block with an
in-flight memory read that loses power produces a response to nobody, or a hang
in the requester waiting for one. This is a real RTL feature that must be
designed in — usually a `busy`/`idle` output derived from the same state that
drives backpressure ([docs/30](30-flow-control-and-handshakes.md)).

**Clean reset semantics on wake.** A domain coming back must reset to a defined
state or restore a retained one; the two paths must not partially mix. This
interacts with the reset synchroniser: the domain's reset is itself in another
domain and crosses in ([docs/28 §8](28-clock-domain-crossing.md#8-reset-crossing)).

**No combinational paths across a gateable boundary.** A combinational path from
a gated domain into an always-on one cannot be isolated at a register boundary
and forces isolation cells into the middle of a timing path. Register the
interface.

**Domain boundaries that match module boundaries.** Power intent is applied to
instances. A domain that is "half of `u_core`" is not expressible without
restructuring the RTL.

---

## 9. Power-aware verification

**Ordinary RTL simulation does not model power.** There is no supply in the RTL,
so nothing floats, nothing is isolated, and nothing is retained — a design with
completely broken power intent simulates perfectly.

Power-aware simulation reads the UPF alongside the RTL and models the supplies:
signals in an off domain become X, isolation cells clamp, retention cells hold.
That turns power-intent bugs into ordinary simulation failures.

What it finds, all of which are invisible otherwise:

| Bug | Symptom in power-aware sim |
|---|---|
| Missing isolation | X propagating out of an off domain |
| Wrong clamp value | a spurious request or interrupt at power-down |
| Isolation released too early | X for a few cycles after wake |
| Missing retention | a register comes back at its reset value |
| Save/restore out of sequence | a state that never legally existed |
| Powering down while busy | an outstanding transaction never completes |
| Missing level shifter | usually a static check, not a simulation one |

The essential test sequence is not the interesting workload — it is the
**power transition itself**, exercised from every state the block can be in:

1. Run the block into a representative state.
2. Assert quiescence and wait for it.
3. Save, isolate, power down.
4. Stay down; confirm the always-on side still works.
5. Power up, release isolation, restore, reset as applicable.
6. Confirm the block resumes correctly — including outstanding transactions
   completing or being correctly abandoned.

Repeat with the power-down request arriving **while the block is busy**, which
is where the quiescence logic gets tested rather than assumed.

**Static checks catch the structural half.** UPF/CPF consistency checkers verify
that every crossing has isolation and level shifting where required, that
control signals come from an always-on domain, and that the intent is
self-consistent — before any simulation runs. Run them first; they are fast and
they catch the missing-cell class entirely.

> The pattern here is the same as CDC ([docs/28 §11](28-clock-domain-crossing.md#11-verifying-a-crossing)):
> a structural checker is the primary method, simulation is secondary, and a
> plain RTL testbench contributes nothing at all. Whenever the property depends
> on something the RTL does not model, the testbench is not the tool.

---

## 10. Checklist

**Before reaching for power gating**
- [ ] Clock gating applied and confirmed in the synthesis report.
- [ ] Memory enables driven, not tied high.
- [ ] Operand isolation on wide idle datapaths.
- [ ] "Race to idle" compared against DVFS with real numbers.

**Domains**
- [ ] Domain boundaries match module boundaries.
- [ ] Domains are idle long enough to repay the wake latency.
- [ ] The power controller, reset logic and wake source are always-on.
- [ ] No combinational paths across a gateable boundary.

**Cells**
- [ ] Every domain-crossing output isolated, with a clamp value chosen per
      signal — and active-low signals checked individually.
- [ ] Retention applied to the minimum state, with save/restore ordering
      specified.
- [ ] Level shifters on every multi-voltage crossing, combined with isolation
      where both apply.

**RTL support**
- [ ] A quiescence/idle indication per gateable domain.
- [ ] Outstanding transactions cannot be stranded by a power-down.
- [ ] Wake reset semantics defined, and reset crossings synchronised.

**Verification**
- [ ] UPF/CPF static consistency check run and clean.
- [ ] Power-aware simulation run over the transition sequence, from several
      starting states.
- [ ] Power-down requested while busy, at least once.
- [ ] Timing closed at every voltage corner pair, including level-shifter delay.

---

## See also

- [docs/22: Timing closure and optimization](22-timing-closure-and-optimization.md)
  — the RTL-level power levers, in detail
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) — ICG
  cells, why a clock may not come from logic, and scan
- [docs/28: Clock domain crossing](28-clock-domain-crossing.md) — reset
  crossing, and the same structural-checker-first argument
- [docs/29: Memories](29-memories-and-inference.md) — memory enables and what
  holding a `dout` means
- [docs/30: Flow control](30-flow-control-and-handshakes.md) — where a
  quiescence signal comes from
- [docs/32: Timing constraints](32-timing-constraints.md) — generated clocks,
  and multi-corner analysis
