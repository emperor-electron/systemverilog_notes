# Clock Domain Crossing

A signal crossing between two clocks with no fixed phase relationship will
eventually be sampled while it is changing. When that happens the capturing
flop's output may sit between logic levels for an unbounded time before
resolving to 0 or 1 — arbitrarily, and not necessarily to the value that was
being written.

CDC is the area where "it simulates fine" means least. A plain RTL simulation
resolves every signal to a definite value at a definite time, so it shows none
of this. CDC bugs are found by design rules, by linting, and by constraints —
not by running the testbench again.

Companion code, all verified:
[`cdc_bit.sv`](../examples/rtl/cdc_bit.sv) ·
[`cdc_pulse.sv`](../examples/rtl/cdc_pulse.sv) ·
[`cdc_handshake.sv`](../examples/rtl/cdc_handshake.sv) ·
[`async_fifo.sv`](../examples/rtl/async_fifo.sv) ·
[`reset_sync.sv`](../examples/rtl/reset_sync.sv) ·
[`gray_counter.sv`](../examples/rtl/gray_counter.sv) ·
simulated by [`async_fifo_tb.sv`](../examples/tb/async_fifo_tb.sv),
proved in [`formal/cdc_handshake_fv.sby`](../formal/cdc_handshake_fv.sby)
and [`formal/gray_counter_fv.sby`](../formal/gray_counter_fv.sby)

---

## Contents

- [1. Metastability](#1-metastability)
- [2. The two-flop synchronizer](#2-the-two-flop-synchronizer)
- [3. The four kinds of crossing](#3-the-four-kinds-of-crossing)
- [4. Crossing a level](#4-crossing-a-level)
- [5. Crossing a pulse](#5-crossing-a-pulse)
- [6. Crossing a bus: handshake](#6-crossing-a-bus-handshake)
- [7. Crossing a stream: the async FIFO](#7-crossing-a-stream-the-async-fifo)
- [8. Reset crossing](#8-reset-crossing)
- [9. Reconvergence](#9-reconvergence)
- [10. What you must tell the tools](#10-what-you-must-tell-the-tools)
- [11. Verifying a crossing](#11-verifying-a-crossing)
- [12. Bug catalogue](#12-bug-catalogue)
- [13. Checklist](#13-checklist)

---

## 1. Metastability

A flip-flop guarantees a valid output only if its input is stable for a setup
time before the clock edge and a hold time after it. An asynchronous input
violates that window sooner or later, by definition — there is no phase
relationship to prevent it.

The result is not a wrong value. It is **no value**: the output hovers near the
switching threshold and decays toward 0 or 1 with a time constant set by the
process. The decay is exponential, so the probability of still being undecided
after time *t* falls off as e^(−t/τ), but it never reaches zero.

The standard figure of merit:

```
              e^(t_r / τ)
  MTBF  =  ─────────────────
            T₀ · f_clk · f_data
```

| Symbol | Meaning |
|---|---|
| `t_r` | resolution time available — the slack left in the cycle after the first flop |
| `τ` | settling time constant of the flop (a library parameter, tens of ps) |
| `T₀` | metastability window width (a library parameter) |
| `f_clk` | capturing clock frequency |
| `f_data` | rate at which the asynchronous input changes |

The three things this tells you are all worth internalising:

1. **MTBF is exponential in the time you give it and only linear in
   everything else.** Buying resolution time is overwhelmingly the most
   effective lever. That is what the second flop is for.
2. **It is never zero.** "Safe" means an MTBF of centuries, not a guarantee.
3. **It gets worse with clock frequency and with data toggle rate**, so a
   crossing that was fine at 100 MHz may not be at 500 MHz.

---

## 2. The two-flop synchronizer

[`cdc_bit.sv`](../examples/rtl/cdc_bit.sv):

```systemverilog
(* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

always_ff @(posedge dclk or negedge drst_n) begin
  if (!drst_n) sync_q <= {STAGES{INIT}};
  else         sync_q <= {sync_q[STAGES-2:0], d};
end

assign q = sync_q[STAGES-1];
```

The first flop is *expected* to go metastable. The second flop samples it a full
clock period later, by which time the first has almost certainly resolved. The
"almost certainly" is the MTBF above, and the "full clock period" is `t_r`.

**What it does:** gives the first flop a whole cycle to settle, converting an
unbounded-probability event into a negligible-probability one.

**What it does not do:**

- It does not tell you *which* value you got. If the input changes near the
  edge, you may get the old value or the new one — either is correct behaviour.
  Your design must work with both.
- It does not preserve timing. The crossing costs 1–2 destination cycles of
  latency, and that latency is not constant.
- It does not work on a bus. See §3.
- It does not help if the input is not stable long enough to be sampled at all.

### `ASYNC_REG`

The attribute tells the tools these two flops must be placed adjacent and their
interconnect kept minimal, so that as much of the cycle as possible is left for
settling. Without it the placer may put them far apart, spend most of the period
on routing, and leave `t_r` — the term in the *exponent* — small.

It also tells the tools not to optimise the chain away, retime through it, or
merge equivalent synchronisers.

- Vivado / Xilinx: `(* ASYNC_REG = "TRUE" *)`
- Intel / Quartus: `(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION ..." *)`
- ASIC flows: use the library's dedicated synchroniser cells instead.

### How many stages?

Two is standard. Three is used when the clock is very fast, the MTBF budget is
strict, or the domain is safety-critical. The parameter exists in `cdc_bit` so
the decision is per-instance rather than global.

---

## 3. The four kinds of crossing

**Never put a synchronizer on each bit of a bus.** Each bit resolves
independently, so on a cycle where several bits change, some arrive and some do
not, and the destination sees a value that was never sent. Going from `0111` to
`1000`, every bit changes, and the receiver can observe any of the 16 values in
between.

The right technique depends on what you are crossing:

| What is crossing | Technique | Module |
|---|---|---|
| A slow-moving level (1 bit) | two-flop synchronizer | [`cdc_bit`](../examples/rtl/cdc_bit.sv) |
| A single-cycle pulse (1 bit) | toggle + edge detect | [`cdc_pulse`](../examples/rtl/cdc_pulse.sv) |
| A bus, occasionally | 4-phase handshake | [`cdc_handshake`](../examples/rtl/cdc_handshake.sv) |
| A bus, continuously | async FIFO with Gray pointers | [`async_fifo`](../examples/rtl/async_fifo.sv) |

The unifying idea behind the last two: **only 1-bit control signals ever
actually cross.** The data is held stable in the source domain and read by the
destination only when the control signals say it is safe. The bus itself is
never synchronised, because a bus cannot be.

---

## 4. Crossing a level

Use `cdc_bit` directly when the signal changes rarely and stays put.

**The obligation:** the level must remain stable for at least two destination
clock edges, so that it cannot be missed entirely. If the destination clock is
slower than the source, a signal asserted for one source cycle can fall
completely between two destination edges and never be seen.

```systemverilog
cdc_bit #(.STAGES(2)) u_sync (
  .dclk(dclk), .drst_n(drst_n), .d(cfg_enable), .q(cfg_enable_dsync));
```

Good for: configuration bits, mode selects, status flags, "the other side is
ready" levels. Bad for: anything pulse-shaped — use `cdc_pulse`.

---

## 5. Crossing a pulse

A single-cycle pulse cannot be synchronised directly, so convert it into
something that *can* be: a level that toggles.
[`cdc_pulse.sv`](../examples/rtl/cdc_pulse.sv):

```systemverilog
// Source: flip a level on every input pulse. A level crosses safely.
always_ff @(posedge sclk or negedge srst_n) begin
  if (!srst_n)      toggle_q <= 1'b0;
  else if (s_pulse) toggle_q <= ~toggle_q;
end

cdc_bit #(.STAGES(2)) u_sync (.dclk(dclk), .drst_n(drst_n),
                              .d(toggle_q), .q(sync_q));

// Destination: an edge on the synchronized level is a pulse.
always_ff @(posedge dclk or negedge drst_n)
  if (!drst_n) sync_q2 <= 1'b0; else sync_q2 <= sync_q;

assign d_pulse = sync_q ^ sync_q2;
```

Each source pulse flips the level; each flip produces exactly one destination
pulse, regardless of which direction it flipped. That is why the edge detector
is an XOR rather than a rising-edge detector.

**The obligation:** source pulses must be spaced further apart than the
synchroniser latency — at least two destination clock periods. Two pulses closer
than that toggle the level twice before the destination sees either, and the
destination sees *nothing*, because the level ends up back where it started.

This is a silent failure mode. If the source rate is not guaranteed by
construction, you need the handshake instead, which provides backpressure.

---

## 6. Crossing a bus: handshake

[`cdc_handshake.sv`](../examples/rtl/cdc_handshake.sv) is the four-phase
request/acknowledge protocol. Only `req` and `ack` cross; `data_q` sits still in
the source domain and the destination reads it directly.

```systemverilog
assign s_ready = !req_q && !ack_sync;

always_ff @(posedge sclk or negedge srst_n) begin
  if (!srst_n) begin
    req_q <= 1'b0; data_q <= '0;
  end else if (s_valid && s_ready) begin
    req_q  <= 1'b1;
    data_q <= s_data;          // stable from here until ack returns
  end else if (req_q && ack_sync) begin
    req_q  <= 1'b0;
  end
end
```

The destination detects the rising edge of the synchronised request, latches the
data at that moment, and raises `ack`:

```systemverilog
d_valid <= req_sync && !req_sync_q;             // rising edge of req
if (req_sync && !req_sync_q) d_data <= data_q;  // safe: stable by now
ack_q   <= req_sync;                            // 4-phase: follow req
```

By the time `req_sync` rises, `data_q` has been stable for at least two
destination clock edges — the synchroniser delay is itself the settling time for
the data bus. That is the entire trick, and it depends completely on one
property:

> **`data_q` must never change while `req_q` is asserted.**

This is a pure source-domain logic property, so it can be proved.
[`formal/cdc_handshake_fv.sby`](../formal/cdc_handshake_fv.sby) proves it
unboundedly:

```systemverilog
always @(posedge sclk)
  if (f_past && srst_n && $past(srst_n) && $past(req_q) && req_q)
    f_data_stable : assert (data_q == $past(data_q));
```

Deleting the `&& s_ready` from the source's accept condition makes it fail at
step 4, which is the check that the property is not vacuous.

**Cost:** a full round trip — source to destination and back — so roughly
2 × (2 source cycles + 2 destination cycles). Throughput is one transfer per
round trip, which is why this is for occasional transfers (configuration
writes, interrupts, command descriptors) and not for streaming.

### What the proof deliberately does not cover

Yosys formal is single-clock: `prep` produces one transition relation stepped by
one clock, so a genuine two-clock crossing — where the entire question is what
happens when edges land arbitrarily close together — is outside what this flow
can express. The harness ties `sclk` and `dclk` together, which removes exactly
the phenomenon a CDC proof would be about.

So the proof covers the **design rule**, not the crossing. Metastability
settling, MTBF and sample timing are electrical properties, handled by
`ASYNC_REG`, a `set_max_delay -datapath_only` constraint and a CDC linter. No
logic proof addresses them, and a CDC proof that claims otherwise is worse than
no proof at all.

---

## 7. Crossing a stream: the async FIFO

For continuous data, a handshake per beat is far too slow. The async FIFO gives
one transfer per clock in both domains.

The memory itself is not the hard part — it is dual-port RAM, written in one
domain and read in the other, and never read at an address that is being
written. The hard part is the **pointer comparison**: each side must know how
far the other has got, and that means a multi-bit counter has to cross.

**Gray coding is what makes it possible.** In Gray code, exactly one bit changes
per increment ([`gray_counter.sv`](../examples/rtl/gray_counter.sv), proved
unboundedly in [`formal/gray_counter_fv.sby`](../formal/gray_counter_fv.sby)).
Synchronising a value where only one bit changes is safe bit-by-bit, because the
only ambiguity is whether that one bit has arrived yet — so the receiver either
sees the old count or the new one. Both are legal: they are values the counter
genuinely held.

That is the whole argument, and it is worth stating precisely because it is the
one case where synchronising a bus *is* allowed:

> Synchronising a multi-bit value bit-by-bit is safe **iff** at most one bit
> can change per source clock, and any of the values that might be reconstructed
> is acceptable.

A stale pointer is always the conservative direction: the write side seeing an
old read pointer thinks the FIFO is fuller than it is, and the read side seeing
an old write pointer thinks it is emptier. Both err toward not transferring,
which is safe. The flags may be pessimistic; they are never wrong in the
dangerous direction.

### The full-flag combinational loop

A bug found in this repository's own `async_fifo` while writing it:

```
wbin_next → wgray_next → wfull → wbin_next
```

Computing the full flag combinationally from the next pointer, and then gating
the next pointer on the full flag, closes a combinational loop. The fix is to
**register the flags**. They are then one cycle pessimistic, which is the safe
direction anyway.

The testbench catches the consequence rather than the loop:
[`async_fifo_tb.sv`](../examples/tb/async_fifo_tb.sv) runs four clock ratios and
checks no beat is lost, and that the write side gates combinationally on the
*live* `wfull`.

### Depth

An async FIFO needs enough depth to cover the synchroniser latency in both
directions, or it will report full/empty spuriously and throttle. Four entries
is the practical minimum for a two-flop synchroniser; anything shallower spends
all its time in the flag latency.

---

## 8. Reset crossing

Reset is a clock-domain crossing and is routinely forgotten.

A reset asserted asynchronously and *released* asynchronously lets flops at
different points in the reset tree leave reset on different clock cycles,
because the release edge violates recovery/removal time at some flops and not
others. The design then starts from an inconsistent state — some flops have
begun, some have not.

[`reset_sync.sv`](../examples/rtl/reset_sync.sv) — **asynchronous assert,
synchronous release**:

```systemverilog
(* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

always_ff @(posedge clk or negedge arst_n) begin
  if (!arst_n) sync_q <= '0;                          // async assert
  else         sync_q <= {sync_q[STAGES-2:0], 1'b1};  // sync release
end

assign rst_n = sync_q[STAGES-1];
```

Assertion is asynchronous so reset works with no clock running — which matters,
because at power-on there may not be one. Release is shifted through two flops
clocked by the destination clock, so every consumer in that domain sees the same
release edge, safely away from its clock edge.

**One reset synchroniser per clock domain.** A reset generated in domain A and
used in domain B is a crossing like any other, and needs its own synchroniser in
B. Resets that cross without one produce start-up failures that appear on a few
parts, at a few temperatures, and never in simulation.

---

## 9. Reconvergence

Two signals that cross the same boundary independently and are then combined in
the destination domain can produce a value neither domain ever held — even
though each crossing is individually correct.

```systemverilog
// BOTH of these are correct crossings on their own
cdc_bit u_a (.dclk(dclk), .d(flag_a), .q(a_sync));
cdc_bit u_b (.dclk(dclk), .d(flag_b), .q(b_sync));

// ...and this is a bug
assign start = a_sync && !b_sync;
```

Each synchroniser has its own independent chance of taking an extra cycle, so
`a_sync` and `b_sync` can be up to a cycle apart even if `flag_a` and `flag_b`
changed together. A transient combination appears, briefly, that was never
intended. If it happens to be the one the destination is waiting for, it fires.

**Fixes, in order of preference:**

1. **Cross one signal, not two.** Encode the combination in the source domain
   and synchronise the result.
2. **Cross a Gray-coded group**, so only one bit changes at a time.
3. **Use a handshake** and read both values from held source registers.

This is the class of bug CDC linters are best at, because it is structural and
invisible in simulation.

---

## 10. What you must tell the tools

RTL alone does not make a crossing safe. Three things need saying:

### Constrain the crossing

The path from the source flop to the first synchroniser flop is asynchronous, so
its normal setup/hold analysis is meaningless. But it must not be left
completely unconstrained either, because skew between two related crossing
signals still matters.

```tcl
# Preferred: bound the delay without requiring a setup relationship.
set_max_delay -datapath_only -from [get_clocks src_clk] \
                             -to   [get_clocks dst_clk] 4.0

# Blunter: exclude the relationship entirely.
set_clock_groups -asynchronous -group {src_clk} -group {dst_clk}
```

`-datapath_only` is the important flag: it bounds the data path delay while
ignoring the clock relationship, which is exactly the semantics of a CDC path.
A bare `set_false_path` also stops the analysis, but it stops *bounding* the
delay too, which lets the router produce arbitrary skew between related signals.

### Preserve the synchroniser

`ASYNC_REG` on the flops, as in §2. Check the synthesis report to confirm the
chain survived.

### Run a CDC linter

Structural CDC analysis (Questa CDC, Spyglass CDC, Vivado's `report_cdc`) finds
what simulation and timing analysis both miss: unsynchronised crossings,
bit-by-bit bus synchronisation, reconvergence, and missing reset synchronisers.

```tcl
report_cdc -details -file cdc.rpt
```

This is not optional on any design with more than one clock. It is the primary
verification method for CDC — the testbench is not.

---

## 11. Verifying a crossing

**Ordinary simulation does not test CDC.** Every signal resolves at a definite
time, so the crossing always appears to work. Even at "random" clock ratios, the
simulator's edges are exact rationals and never land in the danger window.

What actually helps:

| Method | Finds |
|---|---|
| CDC lint | missing synchronisers, bus crossings, reconvergence — **the main method** |
| Metastability injection | designs that assume a particular resolution |
| Multi-ratio simulation | protocol bugs, flag latency, depth problems |
| Formal (single-domain) | the source-side design rules the crossing rests on |
| Static timing with CDC constraints | skew between related crossing signals |

**Metastability injection** is the one simulation technique that earns its
keep: the simulator randomly delays the synchroniser output by one extra cycle,
modelling the case where the first flop resolved late. A design that breaks
under injection has a real bug. Most tools support it directly; a hand-rolled
version randomly inverts the first stage's output when the input changed near
the edge.

**Multi-ratio simulation** is what
[`async_fifo_tb.sv`](../examples/tb/async_fifo_tb.sv) does: four clock ratios,
per-domain monitors, and a check that no beat is lost. It will not find
metastability, but it does find flag-latency and depth bugs, and it exercises
the protocol in ways a single ratio does not.

**Formal**, as §6 sets out, proves the single-domain obligations — data held
stable while a request is outstanding, Gray counters changing one bit at a time
— and nothing about the crossing itself.

---

## 12. Bug catalogue

| Bug | Symptom | Fix |
|---|---|---|
| Bus synchronised bit-by-bit | receiver sees values never sent | handshake, or Gray + one-bit-per-change |
| Pulse sent to `cdc_bit` | pulse occasionally vanishes | `cdc_pulse` |
| Pulses closer than sync latency | pulses vanish in pairs, silently | handshake with backpressure |
| Reconvergent synchronised signals | rare spurious trigger | cross one signal, or Gray-code the group |
| Reset released asynchronously | random start-up state, a few parts only | `reset_sync` per domain |
| Missing `ASYNC_REG` | MTBF collapses; works in the lab, fails in volume | add the attribute, check the report |
| Combinational logic between sync stages | reintroduces the settling problem | synchronise first, then compute |
| Combinational full/empty feedback | combinational loop | register the flags |
| Async FIFO too shallow | spurious full/empty, throttling | depth ≥ 4 for a 2-flop sync |
| `set_false_path` instead of `set_max_delay` | unbounded skew between related signals | `-datapath_only` |

Two entries deserve emphasis because they look harmless:

**Combinational logic between synchroniser stages.** Any gate inserted between
the two flops eats into `t_r` — the term in the exponent — and can also glitch.
Synchronise first, compute afterwards.

**Synchronising the same source signal twice** into the same domain creates two
independently-resolving copies that can disagree. Synchronise once and fan out
the result.

---

## 13. Checklist

**Structure**
- [ ] Every crossing identified and classified: level, pulse, bus, or stream.
- [ ] No multi-bit bus synchronised bit-by-bit, unless Gray-coded with at most
      one bit changing per source clock.
- [ ] Levels are stable for ≥ 2 destination clock edges.
- [ ] Pulses are spaced further apart than the synchroniser latency, *by
      construction* — or use a handshake.
- [ ] No combinational logic between synchroniser stages.
- [ ] Each source signal synchronised into a given domain exactly once.
- [ ] Reconvergence checked: signals combined after crossing came from one
      crossing, not several.

**Data**
- [ ] Bus data held stable for the entire time its control signal is
      outstanding — and asserted, since this one is provable.
- [ ] Async FIFO deep enough to absorb synchroniser latency (≥ 4).
- [ ] FIFO flags registered, not combinational.

**Reset**
- [ ] One reset synchroniser per clock domain.
- [ ] Async assert, sync release.
- [ ] No reset crosses a domain boundary unsynchronised.

**Tools**
- [ ] `ASYNC_REG` (or the flow's equivalent) on every synchroniser.
- [ ] `set_max_delay -datapath_only` on crossings, not a bare false path.
- [ ] CDC lint run and clean, or every waiver justified in writing.
- [ ] Multi-ratio simulation for protocol behaviour.

---

## See also

- [docs/23: Structural techniques](23-structural-design-techniques.md) — Gray,
  Johnson and ring counters
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) — why a
  clock may never come from logic, glitch-free clock muxing, reset for test
- [docs/25: Formal with sby](25-formal-verification-with-sby.md) — what the
  flow can and cannot express, including the single-clock limitation
- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — the
  constraint side
- [docs/16: Verification architecture](16-verification-architecture.md) — the
  per-domain monitor structure the async FIFO testbench uses
