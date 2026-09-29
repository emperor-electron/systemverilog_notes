# Clocking, Elaboration-Time and Timing Patterns

Twenty-five entries in three groups. The clock-and-reset group is the one with no
software ancestry at all — there is no Gang of Four pattern for metastability. The
elaboration group is where GoF's Creational category lands once you notice that
hardware has no run time. The timing group has no GoF counterpart either, because its
whole subject is two currencies software does not spend: **depth** and **fanout**.

The template, the six currencies and the GoF correspondences are in
[docs/40](40-rtl-design-patterns.md).

---

## Contents

**Clock and reset domains** —
[1 Two-Flop Synchronizer](#1-two-flop-synchronizer) ·
[2 Toggle Synchronizer](#2-toggle-pulse-synchronizer) ·
[3 Req/Ack Synchronizer](#3-reqack-handshake-synchronizer) ·
[4 Async FIFO](#4-async-fifo-gray-pointers) ·
[5 Gray Counter Crossing](#5-gray-coded-counter-crossing) ·
[6 Reset Synchronizer](#6-reset-synchronizer) ·
[7 Reset Sequencer](#7-reset-sequencer) ·
[8 Clock Enable over Derived Clock](#8-clock-enable-over-derived-clock) ·
[9 Glitch-Free Clock Switch](#9-glitch-free-clock-switch)

**Elaboration time** —
[10 Parameterized Generator](#10-parameterized-generator) ·
[11 Configuration Package](#11-configuration-package) ·
[12 Compile-Time Strategy](#12-compile-time-strategy) ·
[13 Inference Template](#13-inference-template) ·
[14 Elaboration-Time Assertion](#14-elaboration-time-assertion) ·
[15 Elaboration-Time Tables](#15-elaboration-time-tables)

**Timing and physical** —
[16 Pipeline Insertion / Retiming](#16-pipeline-insertion--retiming) ·
[17 Registered Boundaries](#17-registered-boundaries) ·
[18 Register Duplication](#18-register-duplication) ·
[19 Tree Reduction](#19-tree-reduction) ·
[20 Lookahead / Precomputation](#20-lookahead--precomputation) ·
[21 One-Hot / AND-OR Mux](#21-one-hot-encoding--and-or-mux) ·
[22 SRL Delay Line](#22-srl-delay-line) ·
[23 Multicycle Datapath](#23-multicycle-datapath) ·
[24 I/O Register Packing](#24-io-register-packing) ·
[25 Minimal Reset](#25-minimal-reset)

---

# Clock and reset domains

Every entry in this group exists because of one physical fact: a flip-flop whose input
changes near its sampling edge can enter a **metastable** state and stay between 0 and
1 for an unbounded time. No amount of logic prevents that; the patterns all work by
giving it time to resolve, or by arranging that a wrong sample is harmless.

## 1. Two-Flop Synchronizer

**Intent.** Give a metastable sample a full cycle to resolve before anything in the
destination domain looks at it.

**Motivation.** A signal from another clock domain will sometimes change inside the
destination flop's setup/hold window. The first flop may go metastable; the second
samples it a cycle later, by which time the probability it is still undecided is
vanishingly small. The number that matters is MTBF, and it is exponential in the
settling time you allow.

**Applicability.** Use it for a **single bit** that carries a **level** and changes
**slowly** relative to the destination clock. All three conditions matter. **Do not use
it** for a multi-bit value — that is
[anti-pattern A4](40-rtl-design-patterns.md#a4-multi-bit-bus-through-per-bit-synchronizers)
and adding stages does not help, because the problem is skew and not metastability.
Do not use it for a pulse shorter than the destination period — that is
[#2](#2-toggle-pulse-synchronizer). And do not use it for two related signals
separately — that is [A5](40-rtl-design-patterns.md#a5-reconvergent-synchronization).

**Structure.** The attribute is part of the pattern, not decoration:

```systemverilog
// cdc_bit.sv
(* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

always_ff @(posedge dclk or negedge drst_n) begin
  if (!drst_n) sync_q <= {STAGES{INIT}};
  else         sync_q <= {sync_q[STAGES-2:0], d};
end
assign q = sync_q[STAGES-1];
```

**Consequences.** *Buys:* an MTBF you can calculate. *Costs:* `STAGES` flops and
`STAGES` cycles of latency; and the destination may see a transition one cycle later
than another observer would — which is exactly why reconvergence is dangerous.

**Implementation.**
1. **`ASYNC_REG` is load-bearing.** Without it the tool may place the two flops far
   apart, and the settling time between them — which is what the MTBF calculation
   assumed — evaporates. Check the synthesis report to confirm the chain survived.
2. **Two stages is the default, not the answer.** Three or more for a very high clock
   ratio or a safety-relevant path; the calculation is in
   [docs/28 §2](28-clock-domain-crossing.md#2-the-two-flop-synchronizer).
3. **Constrain the crossing.** `set_max_delay -datapath_only`, not `set_false_path`: a
   false path stops the analysis *and* stops bounding the delay, which lets the router
   produce arbitrary skew between signals that cross together.
4. **The input must be stable for at least one destination period.** If the source can
   change faster than the destination samples, the destination misses transitions —
   correctly synchronised and still wrong.

**Known uses.** [`cdc_bit.sv`](../examples/rtl/cdc_bit.sv), used by
[`cdc_pulse.sv`](../examples/rtl/cdc_pulse.sv),
[`cdc_handshake.sv`](../examples/rtl/cdc_handshake.sv),
[`async_fifo.sv`](../examples/rtl/async_fifo.sv) and
[`gpio.sv`](../examples/rtl/gpio.sv).

**Related.** [#2](#2-toggle-pulse-synchronizer), [#3](#3-reqack-handshake-synchronizer),
[#6](#6-reset-synchronizer), [docs/28](28-clock-domain-crossing.md).

---

## 2. Toggle (Pulse) Synchronizer

**Intent.** Carry an *event* across domains when a one-cycle pulse would be missed
entirely.

**Motivation.** A one-cycle pulse in a 200 MHz domain is 5 ns. Sampled by a 25 MHz
clock, it is invisible three times out of four. Converting the pulse to a *level
change* — a toggle — makes it a thing that can be synchronised, because a level
survives until the destination has seen it.

**Applicability.** Use it for an occasional single event: a done flag, an interrupt, a
counter increment. **Do not use it** when events can arrive faster than the destination
can sample them — a second toggle before the first is seen cancels it, and the event is
lost silently. The rule is that source pulses must be spaced by more than the
synchroniser's round trip; if they cannot be, you need
[#4 Async FIFO](#4-async-fifo-gray-pointers) or a handshake with back-pressure.

**Structure.** Toggle, synchronise the level, edge-detect back to a pulse:

```systemverilog
// cdc_pulse.sv
always_ff @(posedge sclk or negedge srst_n) begin     // source: flip a level
  if (!srst_n)      toggle_q <= 1'b0;
  else if (s_pulse) toggle_q <= ~toggle_q;
end

cdc_bit #(.STAGES(2)) u_sync (.dclk, .drst_n, .d(toggle_q), .q(sync_q));

always_ff @(posedge dclk or negedge drst_n)           // destination: edge-detect
  if (!drst_n) sync_q2 <= 1'b0;
  else         sync_q2 <= sync_q;
assign d_pulse = sync_q ^ sync_q2;
```

**Consequences.** *Buys:* an event crosses regardless of the clock ratio. *Costs:*
three flops plus the synchroniser; two to three destination cycles of latency; and a
**maximum event rate** that is now part of the module's contract and must be written in
its header.

**Implementation.**
1. **Write the minimum spacing in the header and assert it.** This is the one thing
   that goes wrong. `cdc_pulse.sv` states it: "Source pulses must be spaced further
   apart than the synchroniser's latency."
2. **Do not stretch the pulse instead.** A pulse widened to *N* source cycles and then
   synchronised is not a CDC — it is a race that works most of the time, and the
   destination may see it as two pulses or none.
3. **The toggle must not be reset asymmetrically.** If the source's reset clears
   `toggle_q` and the destination's does not clear its edge detector, a reset generates
   a spurious pulse.
4. **Count events at both ends in the testbench.** The failure mode is a *missing*
   pulse, which no single-event test finds.

**Known uses.** [`cdc_pulse.sv`](../examples/rtl/cdc_pulse.sv), exercised at four clock
ratios in [`async_fifo_tb.sv`](../examples/tb/async_fifo_tb.sv).
Contrast [`pulse_extend.sv`](../examples/rtl/pulse_extend.sv), which widens a pulse
*within* one domain and is not a CDC.

**Related.** [#1](#1-two-flop-synchronizer), [#3](#3-reqack-handshake-synchronizer),
[#4](#4-async-fifo-gray-pointers).

---

## 3. Req/Ack Handshake Synchronizer

**Intent.** Cross a multi-bit value by holding it still and synchronising only the
control.

**Also known as.** MCP (multi-cycle path) formulation, four-phase handshake, closed-loop
CDC.

**Motivation.** A bus cannot be synchronised bit by bit
([A4](40-rtl-design-patterns.md#a4-multi-bit-bus-through-per-bit-synchronizers)). But
if the *data* is guaranteed stable while a single-bit *request* crosses, the
destination can sample the data with no synchroniser at all — the data has been stable
for many destination cycles by the time the request arrives. The acknowledgement coming
back is what tells the source it may change the data again.

**Applicability.** Use it for an occasional multi-bit value: a configuration word, a
measurement, a command. **Do not use it** for a stream: the round trip is four
synchroniser traversals, so throughput is one value per ~6–10 destination cycles.
That is [#4 Async FIFO](#4-async-fifo-gray-pointers)'s job.

**Structure.** The data register is the pattern; the handshake is bookkeeping:

```systemverilog
// cdc_handshake.sv
logic          req_q;
logic [DW-1:0] data_q;      // held stable while req is outstanding
logic          ack_sync;    // ack, synchronized into the source domain
logic          req_sync;    // req, synchronized into the destination domain
```

**Consequences.** *Buys:* an arbitrary-width value crosses safely with one
synchroniser per direction rather than one per bit. *Costs:* the full round-trip
latency per value; a `ready` in the source domain that is only asserted between
transactions; and a data path that the timing tool must be *told* is multi-cycle —
otherwise it tries to close it at the destination clock and fails.

**Implementation.**
1. **The data path needs `set_max_delay -datapath_only`, not `set_false_path`.** The
   path is real and has many cycles to settle, but a bare false path stops bounding the
   delay and lets the bits arrive arbitrarily skewed.
2. **Hold the data until `ack`, not until `req` is seen.** Releasing early is the
   classic bug and it is timing-dependent.
3. **Do not synchronise the data "as well, to be safe".** It adds latency, adds flops,
   and reintroduces the skew problem you just solved.
4. **Formal cannot do this one directly.** The Yosys/SymbiYosys flow here is
   single-clock, so [`cdc_handshake_fv.sby`](../formal/cdc_handshake_fv.sby) proves the
   protocol with the two clocks tied together, and
   [docs/28](28-clock-domain-crossing.md#what-the-proof-deliberately-does-not-cover)
   states what that does and does not establish. Knowing the limit is part of the
   pattern.

**Known uses.** [`cdc_handshake.sv`](../examples/rtl/cdc_handshake.sv)
([`cdc_handshake_fv.sby`](../formal/cdc_handshake_fv.sby)).

**Related.** [#1](#1-two-flop-synchronizer), [#4](#4-async-fifo-gray-pointers),
and [docs/39 §10](39-control-registers-and-safe-reconfiguration.md#10-when-the-ps-is-in-another-clock-domain)
for the case where the data is *quasi-static* and needs no handshake at all, only a
qualifier.

---

## 4. Async FIFO (Gray Pointers)

**Intent.** Stream data continuously between two clock domains.

**Motivation.** A handshake per value is too slow for a stream. A FIFO decouples the
rates, but its pointers are multi-bit values that each domain must read from the other
— which is the bus-crossing problem again. Gray coding solves it: only one bit changes
per increment, so a pointer sampled mid-transition is either the old value or the new
one, never a mixture.

**Applicability.** Use it for any continuous flow across domains. **Do not use it**
where a single value crosses occasionally — the RAM and two pointer synchronisers are
far more than [#3](#3-reqack-handshake-synchronizer) costs — and do not use it where
latency must be deterministic, since occupancy varies.

**Structure.** Gray pointers, synchronised, compared in the local domain:

```systemverilog
// async_fifo.sv -- each side keeps a binary counter for addressing and a Gray
// copy for crossing. The comparison happens locally, after synchronising.
// Only one bit changes per increment, so a mid-transition sample is off by at
// most one -- and being off by one in the SAFE direction is the whole trick:
// `full` may be pessimistic, `empty` may be pessimistic, and neither may lie.
```

**Consequences.** *Buys:* full-rate streaming across unrelated clocks. *Costs:* a
dual-port RAM; two pointer synchronisers (so flags are 2–3 cycles stale); latency
proportional to occupancy; and flags that are *conservative* rather than exact, which
means the FIFO reports full slightly before it is.

**Implementation.**
1. **The write side must gate on the live `wfull`, combinationally.** Registering it
   overruns by one. This is the async FIFO's signature bug.
2. **Pessimism must be in the safe direction, always.** `full` early and `empty` late
   are both safe; the reverse corrupts.
3. **A depth that is not a power of two does not Gray-code.** Either round up or use a
   scheme designed for it; a "nearly Gray" counter has two bits changing somewhere.
4. **Test at several clock ratios, including near-equal.** Equal-but-unrelated clocks
   are the hardest case, because the phase relationship drifts slowly through the
   danger zone. [`async_fifo_tb.sv`](../examples/tb/async_fifo_tb.sv) runs four ratios
   with per-domain monitors.
5. **A per-domain monitor is not optional.** A single monitor sampling both sides has
   to sample one of them in the wrong domain, which is the bug it is meant to find.

**Known uses.** [`async_fifo.sv`](../examples/rtl/async_fifo.sv), with
[`gray_counter.sv`](../examples/rtl/gray_counter.sv)
([`gray_counter_fv.sby`](../formal/gray_counter_fv.sby) proves the single-bit-change
property).

**Related.** [#5](#5-gray-coded-counter-crossing), [#1](#1-two-flop-synchronizer),
[#1 Ring Buffer](43-memory-and-verification-patterns.md#1-ring-buffer),
[#4 FIFO Decoupler](41-structural-and-behavioral-patterns.md#4-fifo-decoupler).

---

## 5. Gray-Coded Counter Crossing

**Intent.** Cross a monotonic count so that a mid-transition sample is off by at most
one.

**Motivation.** A timestamp, a fill level, a frame counter: the destination does not
need the exact instantaneous value, it needs a value that is *never wrong*, only
possibly stale. Binary coding cannot give that — 0111 → 1000 changes four bits, and a
sample in between can be anything. Gray coding changes one bit per increment, so the
sample is one of two adjacent values.

**Applicability.** Use it for a counter that only ever increments (or only ever
decrements) by one, where being off by one is acceptable. **Do not use it** for a value
that can jump — a counter that is loaded, or one that steps by more than one, breaks
the single-bit-change property and the pattern with it. And do not use it for a value
where off-by-one is *not* acceptable; then you need a handshake.

**Structure.** The property, and the proof of it:

```systemverilog
// gray_codec.sv -- the conversion pair.
assign gray = bin ^ (bin >> 1);
// binary back from Gray is a prefix XOR, which is log-depth, not linear.

// gray_counter.sv -- the property that makes the crossing safe, and it is
// proved for every adjacent pair INCLUDING the wrap, in gray_counter_fv.sby:
//   exactly one bit differs between consecutive counts.
```

**Consequences.** *Buys:* a safe multi-bit crossing with no handshake and no latency
penalty beyond the synchroniser. *Costs:* the destination must convert back to binary
if it wants to do arithmetic (a prefix XOR, log depth); the value is stale by the
synchroniser's latency; and the restriction to ±1 steps is absolute.

**Implementation.**
1. **Prove the single-bit-change property, including the wrap.** The wrap is where a
   hand-written Gray counter goes wrong.
   [`gray_codec_fv.sby`](../formal/gray_codec_fv.sby) checks every adjacent pair
   exhaustively.
2. **Increment in binary, then convert.** Incrementing in the Gray domain directly is
   possible but error-prone; keep a binary counter and a Gray copy.
3. **Convert back before comparing for anything but equality.** Gray values do not
   order.
4. **Off-by-one must be safe *in the direction it can be wrong*.** Work out which
   direction, and make sure the consumer's decision is conservative that way.

**Known uses.** [`gray_counter.sv`](../examples/rtl/gray_counter.sv),
[`gray_codec.sv`](../examples/rtl/gray_codec.sv), both proved; used by
[`async_fifo.sv`](../examples/rtl/async_fifo.sv).

**Related.** [#4](#4-async-fifo-gray-pointers), [#1](#1-two-flop-synchronizer),
[`quad_decoder.sv`](../examples/rtl/quad_decoder.sv) — quadrature decoding is a Gray
walk, and an illegal transition there is exactly a two-bit change.

---

## 6. Reset Synchronizer

**Intent.** Assert reset without needing a clock, and release it synchronously.

**Motivation.** Reset has two jobs that pull in opposite directions. It must work when
there is no clock yet — so it has to be asynchronous. And its *release* must not
violate the recovery/removal window of the flops it is releasing — so it has to be
synchronous. A raw asynchronous reset released while the clock is running puts some
flops out of reset one cycle before others, and a state machine can leave reset into an
illegal state.

**Applicability.** Use it once per clock domain, on every design. **Do not** distribute
a raw asynchronous reset to logic, and do not synchronise reset *release* through
ordinary logic — the two-flop shape below is the whole pattern and anything else is a
variation on it.

**Structure.** Async assert, sync release, in five lines:

```systemverilog
// reset_sync.sv
(* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

always_ff @(posedge clk or negedge arst_n) begin
  if (!arst_n) sync_q <= '0;                          // async assert
  else         sync_q <= {sync_q[STAGES-2:0], 1'b1};  // sync release
end
assign rst_n = sync_q[STAGES-1];
```

**Consequences.** *Buys:* reset works before the clock does, and releases cleanly.
*Costs:* `STAGES` flops per domain and `STAGES` cycles of reset extension — which is
free, since reset is already long.

**Implementation.**
1. **One per clock domain.** A reset synchronised to clock A and used in domain B is
   not synchronous to B, and its release is a CDC you did not intend.
2. **`ASYNC_REG` again, for the same reason as [#1](#1-two-flop-synchronizer).**
3. **The asynchronous input needs its own constraint.** `set_false_path` from the reset
   pin to the first flop's asynchronous input is correct here — unlike a data crossing
   — because there is genuinely no timing relationship to bound.
4. **Reset release ordering between domains is a separate problem.** See
   [#7](#7-reset-sequencer).

**Known uses.** [`reset_sync.sv`](../examples/rtl/reset_sync.sv).
[docs/24 §5](24-dft-clocking-and-x-discipline.md) and
[docs/28 §8](28-clock-domain-crossing.md#8-reset-crossing) are the full treatment.

**Related.** [#7](#7-reset-sequencer), [#25 Minimal Reset](#25-minimal-reset),
[#1](#1-two-flop-synchronizer).

---

## 7. Reset Sequencer

**Intent.** Release resets in a defined order when the blocks depend on each other.

**Motivation.** A design where everything leaves reset at once is fine until something
downstream needs something upstream to be *already working*. An interconnect that
starts issuing before the memory controller has calibrated; an IP that samples a clock
before the MMCM has locked. The order is a real dependency, and if it is not explicit
in the design it is implicit in the propagation delays — which is
[anti-pattern A8](40-rtl-design-patterns.md#a8-relying-on-gate-delays-for-timing-or-pulse-shaping).

**Applicability.** Use it when there is a genuine start-up dependency: PLL lock, memory
calibration, an external device's power-good, a link's training. **Do not** invent a
sequence where there is no dependency — a needless sequencer is state to debug and a
reason for the design to hang at start-up — and do not use it in place of a proper
handshake for something that happens more than once.

**Structure.** *Sketch only — depends on the platform's lock and power-good signals.*

```systemverilog
// Sketch. A small FSM, one stage per dependency, each waiting for evidence
// rather than for a delay.
typedef enum logic [2:0] {
  R_WAIT_LOCK, R_HOLD, R_REL_FABRIC, R_REL_IP, R_RUN
} rstate_e;

always_ff @(posedge clk or negedge arst_n) begin
  if (!arst_n) state_q <= R_WAIT_LOCK;
  else unique case (state_q)
    R_WAIT_LOCK : if (mmcm_locked)        state_q <= R_HOLD;
    R_HOLD      : if (hold_done)          state_q <= R_REL_FABRIC;  // counted cycles
    R_REL_FABRIC: if (fabric_ready)       state_q <= R_REL_IP;
    R_REL_IP    :                         state_q <= R_RUN;
    R_RUN       : if (!mmcm_locked)       state_q <= R_WAIT_LOCK;   // re-assert
    default     :                         state_q <= R_WAIT_LOCK;
  endcase
end
```

**Consequences.** *Buys:* a deterministic, reviewable start-up. *Costs:* a small FSM
that is exercised once per power-up and is therefore the least-tested logic in the
design; and a new way for the system to fail — stuck in a wait state, with no output.

**Implementation.**
1. **Wait for *evidence*, not for a delay, wherever evidence exists.** `mmcm_locked` is
   evidence. A counter is a guess that will be wrong on another device.
2. **Every wait needs a timeout.** A sequencer stuck waiting for a lock that never
   comes must say so ([#26 Watchdog](41-structural-and-behavioral-patterns.md#26-watchdog--timeout)),
   or the board looks dead with no diagnosis.
3. **Handle re-assertion.** If the lock drops during operation, the sequence must
   restart — and everything downstream must tolerate being reset again.
4. **Test it, which means being able to force the inputs.** This logic runs once in
   normal operation, so a testbench that only ever starts up cleanly tests none of the
   interesting paths.

**Known uses.** *Sketch only — no sequencer module here,* because the interesting
inputs are platform signals. [docs/24](24-dft-clocking-and-x-discipline.md) covers reset
discipline; [`reset_sync.sv`](../examples/rtl/reset_sync.sv) is the per-domain piece it
would drive.

**Related.** [#6](#6-reset-synchronizer),
[#26 Watchdog](41-structural-and-behavioral-patterns.md#26-watchdog--timeout),
[#25 Minimal Reset](#25-minimal-reset).

---

## 8. Clock Enable over Derived Clock

**Intent.** Run slow logic on the fast clock with a periodic enable, instead of
generating a divided clock in fabric.

**Motivation.** The logic really does only need to run at 1/125th of the clock. The
obvious implementation — divide the clock and use the result as a clock — creates a
clock out of fabric, which arrives late and skewed relative to its source, so every
path between the two is a timing problem the tool cannot fix, and the divided clock has
to be inferred rather than declared. An enable has none of those properties: there is
one clock, one timing graph, and the enable is ordinary data.

**Applicability.** Use it for essentially all rate reduction inside a design: baud
generators, sample clocks, refresh intervals, display multiplexing. **Do not use it**
when you genuinely need a different clock at a pin, or when the power saving from
actually stopping the clock matters — and then use the dedicated clock-gating primitive,
not a LUT.

**Structure.** A counter and a one-cycle tick, with the degenerate case handled:

```systemverilog
// clk_div_en.sv
if (DIV == 0) begin : g_chk
  $error("clk_div_en: DIV must be >= 1");
end
if (DIV == 1) begin : g_passthrough
  assign tick = en;                       // no counter at all
end else begin : g_div
  localparam int unsigned CW = $clog2(DIV);
  logic [CW-1:0] cnt;
  assign tick = en && (cnt == CW'(DIV - 1));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)   cnt <= '0;
    else if (en)  cnt <= tick ? '0 : (cnt + 1'b1);
  end
end
```

**Consequences.** *Buys:* one clock domain, one timing graph, no skew between "fast"
and "slow" logic, and a rate that is a parameter rather than a clock tree. *Costs:*
the flops still toggle (so dynamic power is not saved — clock gating is what saves
that), and every consumer must be enable-aware, which is a discipline that has to hold
everywhere.

**Implementation.**
1. **`tick` is a one-cycle pulse, not a 50% square wave.** Every consumer gates on it;
   nothing clocks from it. If any code does `@(posedge tick)`, the pattern has been
   defeated.
2. **Handle `DIV == 1`.** Without the passthrough branch you get a zero-width counter
   or an off-by-one; degenerate parameters are where parameterised modules break.
3. **A gated `en` must freeze the divider, not just the output.** Otherwise the phase
   of the tick drifts relative to the data.
4. **Declare it to the timing tool if it matters.** A path that is only active on
   `tick` is a [multicycle path](#23-multicycle-datapath), and saying so can buy real
   slack. Not saying so is safe but pessimistic.

**Known uses.** [`clk_div_en.sv`](../examples/rtl/clk_div_en.sv), the baud generator in
[`uart_periph.sv`](../examples/rtl/uart_periph.sv), the SCL generator in
[`i2c_master.sv`](../examples/rtl/i2c_master.sv) (`DIV4`), the digit rate in
[`seven_seg_mux.sv`](../examples/rtl/seven_seg_mux.sv).

**Related.** [#9](#9-glitch-free-clock-switch), [#23 Multicycle Datapath](#23-multicycle-datapath),
[anti-pattern A1](40-rtl-design-patterns.md#a1-derived-or-gated-clocks-built-in-fabric-logic),
[docs/35](35-low-power-architecture.md) for when you do want to stop the clock.

---

## 9. Glitch-Free Clock Switch

**Intent.** Change a clock's source without emitting a runt pulse.

**Motivation.** A LUT multiplexer between two clocks will, at the moment `sel` changes,
produce a fragment of a period — a pulse too short to meet any flop's minimum width,
which puts every flop it reaches into an undefined state. The dedicated primitive
exists precisely because this cannot be done safely in fabric.

**Applicability.** Use the **primitive** — `BUFGMUX`/`BUFGCTRL` on Xilinx, the
equivalent elsewhere — whenever a clock source must change at run time: a reference
switching to a recovered clock, a low-power clock, a test clock. **Do not** build one
in logic, ever. If you find yourself needing to, the usual alternative is to run
everything from the fast clock and use [#8](#8-clock-enable-over-derived-clock) instead,
which removes the need.

**Structure.** *Sketch only — this must be a vendor primitive; a fabric version is
[anti-pattern A1](40-rtl-design-patterns.md#a1-derived-or-gated-clocks-built-in-fabric-logic).*

```systemverilog
// Behind a Primitive Wrapper (#5 in docs/41), which is the only reasonable way
// to have this in portable RTL.
module my_clk_mux (input var logic clk0, clk1, sel, output var logic clk_out);
`ifdef XILINX
  BUFGCTRL u_mux (.I0(clk0), .I1(clk1), .S0(~sel), .S1(sel),
                  .CE0(1'b1), .CE1(1'b1), .IGNORE0(1'b0), .IGNORE1(1'b0),
                  .O(clk_out));
`elsif SIMULATION
  assign clk_out = sel ? clk1 : clk0;   // NOT glitch-free. Simulation only.
`else
  $error("my_clk_mux: no implementation selected");
`endif
endmodule
```

**Consequences.** *Buys:* a clock that can change source safely. *Costs:* a dedicated
global-buffer resource (there are few); several cycles of dead time during the switch,
in which neither clock runs; and the requirement that *both* clocks be running for the
handover to complete — switching away from a stopped clock hangs.

**Implementation.**
1. **Both clocks must be live during the switch.** The primitive's handover
   synchronises to each clock in turn. If the outgoing clock has stopped, it never
   completes.
2. **Reset everything the switched clock feeds, across the switch.** The dead time means
   downstream logic misses edges; treat the switch as a reset event.
3. **The simulation stub is not equivalent, and must say so.** A behavioural mux
   glitches in a way the primitive does not, and the difference only appears in
   hardware.
4. **Declare both clocks and the switch to the timing tool.** `set_clock_groups
   -asynchronous` between them, plus whatever the vendor requires for the primitive.

**Known uses.** *Sketch only.* [docs/24](24-dft-clocking-and-x-discipline.md) has the
rule ("a clock may never come from logic") and the reasoning.

**Related.** [#5 Primitive Wrapper](41-structural-and-behavioral-patterns.md#5-primitive-wrapper),
[#8](#8-clock-enable-over-derived-clock),
[A1](40-rtl-design-patterns.md#a1-derived-or-gated-clocks-built-in-fabric-logic).

---

# Elaboration time

This is GoF's Creational category, relocated. Software defers construction to run time
and pays with indirection; hardware defers it to **elaboration** and pays nothing,
because the choice is resolved before a netlist exists. See
[docs/40 §1](40-rtl-design-patterns.md#1-what-translates-from-gof-and-what-does-not).

## 10. Parameterized Generator

*GoF analogue: **Factory** / **Template Method**.*

**Intent.** Build an N-wide or N-deep structure from one description.

**Motivation.** Eight instances written out by hand are eight places for a typo and one
place that gets missed when the interface changes. `generate` makes the count a
parameter, and the description is then checked once by the compiler rather than eight
times by a reviewer.

**Applicability.** Use it for any repeated structure: lanes of a datapath, stages of a
pipeline, bits of a decoder, taps of a filter. **Do not** parameterise what will never
vary — a parameter with one legal value is a fiction that makes the code harder to read
— and do not nest generate loops so deeply that the instance names become unreadable
(`g_pix[1].g_comp[2].u_med` is about the limit).

**Structure.** A generate loop is a **scope factory**: the body is instantiated once per
iteration in a fresh named scope, with the genvar substituted as a literal.

```systemverilog
// adder_tree.sv -- recursive generation, with the degenerate case checked.
if (N < 1) begin : g_chk
  $error("adder_tree: N must be >= 1");
end
```

**Consequences.** *Buys:* one description, any size; the compiler checks it once.
*Costs:* debugging happens at an instance path rather than a line number; and
elaboration time grows with the instance count, which for a large N is noticeable.

**Implementation.**
1. **Name every generate block.** An unnamed block gets a tool-assigned name that
   changes between tools, so cross-probing and constraints break.
2. **Check the degenerate cases at elaboration** ([#14](#14-elaboration-time-assertion)).
   N=0 and N=1 are where parameterised code breaks, and they are cheap to test:
   [`video_tb.sv`](../examples/tb/video_tb.sv) runs the video set at five
   configurations including a single-component one.
3. **A generate loop replicates; a procedural loop does not — usually.** The real rule
   is that a procedural loop replicates when each iteration writes a *different* lvalue,
   and builds an expression chain when they write the same one.
   [docs/37 §3–§4](37-parameterized-video-pipelines.md) works this out with the
   unrolled output from the tools.
4. **Elaboration-time functions are free.** A package function that computes a bit
   offset leaves a literal in the netlist, not an adder.

**Known uses.** [`adder_tree.sv`](../examples/rtl/adder_tree.sv),
the `vid_axis_*` family (four-deep generate nests over N pixels × P components),
[`sort_network.sv`](../examples/rtl/sort_network.sv),
[`fanout_replicate.sv`](../examples/rtl/fanout_replicate.sv).

**Related.** [#11](#11-configuration-package), [#12](#12-compile-time-strategy),
[#14](#14-elaboration-time-assertion), [docs/37](37-parameterized-video-pipelines.md).

---

## 11. Configuration Package

*GoF analogue: usually given as **Singleton**; that is weak. See
[docs/40 §1](40-rtl-design-patterns.md#1-what-translates-from-gof-and-what-does-not).*

**Intent.** One source of truth for the parameters, types and layout a design shares.

**Motivation.** Two modules that both need to know how a pixel is packed into a wide
bus will compute the bit offset twice, and the two copies will disagree eventually. The
failure does not look like a parameter mistake; it looks like data corruption.

**Applicability.** Use it for anything two or more modules must agree on: a bit layout,
a register map, a pipeline depth, an enum of commands. **Do not** put behaviour in it —
a package function that the DUT *and* its checker both call cannot detect an error in
itself, which is a real gap and one to state explicitly. And do not make it a dumping
ground: a package every module imports is a recompile of everything for any change.

**Structure.** The point is that the *same* function serves both sides:

```systemverilog
// pipe_pkg.sv -- one function, because the datapath's cut mask and the control
// block's stage count are the same number computed twice, and two copies of that
// arithmetic is two chances to disagree.
function automatic int unsigned cuts_below(input logic [3:0] m,
                                          input int unsigned k);
  cuts_below = 0;
  for (int i = 0; i < 4; i++)
    if ((i < int'(k)) && m[i]) cuts_below = cuts_below + 1;
endfunction
```

**Consequences.** *Buys:* agreement by construction. *Costs:* a compile-order
dependency (packages must be analysed first); a recompile radius; and the verification
gap in the note below.

**Implementation.**
1. **A shared accessor cannot test itself.** If the DUT unpacks with
   `pkg::field(cfg)` and the checker packs with `pkg::pack(...)`, a wrong offset
   *cancels out* and no test sees it. Close it with one directed vector of literal
   constants — [`csr_config_tb.sv`](../examples/tb/csr_config_tb.sv) writes literal hex
   words and checks hand-computed results for exactly this reason, and it is the only
   place in that design where the map is pinned to something outside the package.
2. **Reference it fully scoped: `pkg::name`.** The Yosys frontend rejects
   `import pkg::*;` in a module body and crashes on one at compilation-unit scope.
3. **Keep the golden model in the package and out of the RTL.** A reference model that
   no design module calls is a legitimate package member and a very useful one; the
   moment a design module calls it, it stops being a reference.
4. **Analyse packages first.** XSIM has no library search path, so the build must order
   them explicitly.

**Known uses.** [`vid_pkg.sv`](../examples/rtl/vid_pkg.sv) (the video layout
convention), [`pipe_pkg.sv`](../examples/rtl/pipe_pkg.sv),
[`cfg_pkg.sv`](../examples/rtl/cfg_pkg.sv) (register map plus a golden model that no
RTL module calls), [`fp_pkg.sv`](../examples/arith/fp_pkg.sv),
[`fixed_pkg.sv`](../examples/arith/fixed_pkg.sv).

**Related.** [#10](#10-parameterized-generator),
[#8 Interface Bundle](41-structural-and-behavioral-patterns.md#8-interface-bundle),
[docs/07](07-interfaces-and-packages.md).

---

## 12. Compile-Time Strategy

*GoF analogue: **Strategy**, with the binding moved to elaboration.*

**Intent.** Select an implementation at elaboration, at no run-time cost.

**Motivation.** Two implementations of the same function — BRAM or LUTRAM, fast or
small, four stall schemes — should be selectable without forking the file. A parameter
plus `generate if` does it, and because the choice resolves before synthesis, the
unselected branch does not exist in the netlist.

**Applicability.** Use it when there are genuinely several right answers and the choice
belongs to the integrator. It is also the cheapest way to make a **negative control**:
a fault you can switch on with a parameter is a fault you can prove your checks would
catch. **Do not use it** to hide two unrelated modules behind one name, and do not let
the variants' interfaces drift — the moment they differ, callers must know which they
have, and the Strategy is gone.

**Structure.** Four modes in one module, so they can be *measured* rather than argued
about:

```systemverilog
// cfg_pipe_scale.sv -- and note the finding: MODE 0 and MODE 1 share this branch.
// Identical datapath, identical cost. The difference between a correct design and
// a silently corrupting one is the one assignment below.
end else begin : g_shared
  assign shift_s1 = cfg_pkg::scale_shift(cfg);
  ...
  if (CFG_MODE == M_QUIESCE) begin : g_quiesce
    assign safe = !busy && !(x_valid && en);
  end else begin : g_unsafe
    assign safe = 1'b1;
  end
end
```

**Consequences.** *Buys:* one file, several implementations, zero run-time cost, and a
directly comparable measurement of each. *Costs:* every variant must be built and
tested, or the untested ones rot — which multiplies the regression matrix.

**Implementation.**
1. **Build and test every variant.** [`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv)
   has one proof task per mode and the testbench instantiates all five, because a mode
   nobody builds is a mode that does not work.
2. **Use it for the negative control.** `LIVE_CFG=1`, `CFG_MODE=0`, `MODE=0` — each is a
   deliberate fault that a proof or a testbench must catch, and running them is how you
   learn whether your checks work.
3. **`chparam` does not override an explicit instance parameter.** A formal negative
   control that sets a mode with `chparam` on a module instantiated with an explicit
   override silently applies nothing, and the proof passes — which looks exactly like
   evidence of correctness. Mutate the source instead.
4. **Measure the variants side by side.** Two numbers from one build flow are worth more
   than any amount of reasoning about which should be smaller.

**Known uses.** [`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv) (`MODE` 0–4),
[`dot_rs_dp.sv`](../examples/rtl/dot_rs_dp.sv) (`CUTS` as a bit mask, so `4'b0000` is
the combinational reference and `4'b1111` the four-stage pipeline),
[`cfg_pipe_scale.sv`](../examples/rtl/cfg_pipe_scale.sv) (`CFG_MODE`),
[`csr_shadow.sv`](../examples/rtl/csr_shadow.sv) (`MODE`),
[`select_styles.sv`](../examples/rtl/select_styles.sv) (four control structures, three
provably equal and one provably not).

**Related.** [#10](#10-parameterized-generator), [#13](#13-inference-template),
[#5 Primitive Wrapper](41-structural-and-behavioral-patterns.md#5-primitive-wrapper).

---

## 13. Inference Template

*GoF analogue: **Template Method**. You write the skeleton the tool expects and it
fills in the primitive.*

**Intent.** Write RAM, ROM, SRL or DSP logic in the exact shape the synthesiser maps
onto a hard block.

**Motivation.** An FPGA has block RAMs, DSP slices and shift-register LUTs that are
enormously cheaper than the equivalent fabric. The tool will use them, but only if the
RTL matches the pattern it recognises — and the pattern is narrow. Write it a slightly
different way and you silently get flops and LUTs: functionally identical, several times
the area, and a much worse clock.

**Applicability.** Use it for every memory and every wide multiply-accumulate. **Do not
use it** when you need something the primitive cannot do, and do not fight the tool
past one attempt: if inference will not happen, instantiate the primitive behind a
[Primitive Wrapper](41-structural-and-behavioral-patterns.md#5-primitive-wrapper) and
move on.

**Structure.** The shape, and the thing that breaks it:

```systemverilog
// srl_delay.sv -- note what is ABSENT: there is no reset. An SRL has no reset on
// its internal stages, so a reset here would force 32 fabric flops per bit.
always_ff @(posedge clk)
  if (en) sr <= {sr[DEPTH-2:0], din[b]};
assign dout[b] = sr[DEPTH-1];
```

**Consequences.** *Buys:* an order-of-magnitude area saving and the primitive's clock
rate. *Costs:* the RTL is constrained by what the tool recognises, so it is less free
than it looks; the mapping is not guaranteed; and reading the synthesis report becomes
part of the design loop rather than an afterthought.

**Implementation.**
1. **Reset is the usual reason inference fails.** DSP, BRAM and SRL stages have no
   asynchronous reset, so an async reset on a datapath register keeps it out of the hard
   block. This is [#25 Minimal Reset](#25-minimal-reset), and it is the single most
   common cause. [A6](40-rtl-design-patterns.md#a6-asynchronous-reset-on-datapath-registers)
   is the anti-pattern.
2. **Read-first, write-first and no-change are different templates, and mixing them
   fails.** Pick the behaviour, write its template, and say which one in the header:
   [`ram_sp.sv`](../examples/rtl/ram_sp.sv) is read-first and
   [`ram_sp_wf.sv`](../examples/rtl/ram_sp_wf.sv) is write-first, deliberately as two
   files.
3. **Verify the mapping, not just the function.** `stat` after synthesis, or the
   vendor's utilisation report. A testbench cannot tell a BRAM from 4096 flops.
4. **Break the rules deliberately where you must, and say so.**
   [`regfile.sv`](../examples/rtl/regfile.sv) has asynchronous reads precisely because
   it must *not* be a BRAM, and the header says that is the point.

**Known uses.** [`ram_sp.sv`](../examples/rtl/ram_sp.sv),
[`ram_sp_wf.sv`](../examples/rtl/ram_sp_wf.sv),
[`ram_sdp.sv`](../examples/rtl/ram_sdp.sv),
[`ram_be.sv`](../examples/rtl/ram_be.sv),
[`ram_tdp.sv`](../examples/rtl/ram_tdp.sv),
[`srl_delay.sv`](../examples/rtl/srl_delay.sv),
[`mac_pipelined.sv`](../examples/rtl/mac_pipelined.sv) (shaped for a DSP48),
[`rom_table.sv`](../examples/rtl/rom_table.sv).

**Related.** [#25 Minimal Reset](#25-minimal-reset), [#22 SRL Delay Line](#22-srl-delay-line),
[#5 Primitive Wrapper](41-structural-and-behavioral-patterns.md#5-primitive-wrapper),
[docs/29](29-memories-and-inference.md).

---

## 14. Elaboration-Time Assertion

**Intent.** Fail the build on an illegal parameter instead of shipping it.

**Motivation.** A parameterised module has a legal parameter space, and it is almost
never the whole space. `PIPE > LANES` in an interleaved accumulator produces silently
wrong arithmetic; `DIV == 0` produces a zero-width counter; `N == 0` produces an empty
tree. Each is a build-time fact, and there is no reason to discover it in simulation —
let alone in hardware.

**Applicability.** Use it on every parameter with a constraint, which is most of them.
It costs one line and it is the cheapest check in this catalogue. **Do not** use it for
something that is a *warning* rather than an error — a legal but inadvisable
configuration — because a build that always prints warnings trains people to ignore
them.

**Structure.** A generate-scope `$error` or `$fatal`:

```systemverilog
// acc_interleaved.sv -- the pattern's precondition, checked where it is free.
// With fewer lanes than the adder's latency, a context's next issue arrives before
// its previous result is written back, and the accumulation is silently wrong.
if (PIPE < 1 || PIPE > LANES) begin : g_chk
  $error("acc_interleaved: need 1 <= PIPE (%0d) <= LANES (%0d)", PIPE, LANES);
end
```

**Consequences.** *Buys:* an illegal configuration cannot be built. *Costs:* one line,
and one named generate block.

**Implementation.**
1. **Put it in a named generate block.** An unnamed one is a portability problem, and
   the check needs to be in generate scope to be elaboration-time at all.
2. **`$error` continues, `$fatal` stops.** Prefer `$error` so a build reports *all* the
   bad parameters in one pass rather than one per run.
3. **Say the values in the message.** `"need 1 <= PIPE (%0d) <= LANES (%0d)"` tells the
   integrator what to change; `"illegal parameters"` does not.
4. **Check the relationships, not only the ranges.** Most real constraints are between
   two parameters, and those are the ones that produce silent wrongness rather than a
   width error.

**Known uses.** [`acc_interleaved.sv`](../examples/rtl/acc_interleaved.sv)
(`1 <= PIPE <= LANES`), [`adder_tree.sv`](../examples/rtl/adder_tree.sv) (`N >= 1`),
[`clk_div_en.sv`](../examples/rtl/clk_div_en.sv) (`DIV >= 1`).

**Related.** [#10](#10-parameterized-generator), [#12](#12-compile-time-strategy),
[#6 Interface Assertions](43-memory-and-verification-patterns.md#6-interface-assertions-sva-contract)
(the run-time counterpart), [docs/34](34-coding-conventions-and-reuse.md).

---

## 15. Elaboration-Time Tables

*GoF analogue: **Builder**.*

**Intent.** Compute a ROM's contents with a constant function instead of maintaining a
data file.

**Motivation.** A sine table, a reciprocal table, a CRC table, a microcode image: all
are *derived* from something. Keeping the derivation in a script and the result in a
hex file means the file can be lost, can drift from the code that generated it, and
needs the generator archived alongside. A constant function makes the derivation the
source, and then changing a width updates the table automatically.

**Applicability.** Use it for any table that has a formula. **Do not use it** for a
table that has no formula — measured calibration data, a character font — where a file
genuinely is the source; and do not use it for a table so large that elaboration becomes
slow.

**Structure.** The hierarchy of options, worst to best:

```systemverilog
// rom_table.sv states it directly:
//   $readmemh("tbl.hex")   an external file. Can be lost, can drift from the
//                          code that generated it, and needs the generator
//                          script to be archived too.
//   a literal array        correct but unreadable, and unmaintainable when a
//                          parameter changes.
//   a constant FUNCTION    the derivation IS the source. Change the width and
//                          the table follows. This is the one to use.
```

**Consequences.** *Buys:* one source of truth, and a table that tracks its parameters.
*Costs:* elaboration time; a function that must be written in the synthesisable
constant-function subset; and — for a large table — a build that is noticeably slower.

**Implementation.**
1. **Assign to the function name; do not use `return`.** The Yosys frontend rejects
   `return` in a function, and elaboration-time functions are exactly where you want
   both tools to agree.
2. **Handle the entry that has no value.** `1/0` has no representation;
   [`rom_table.sv`](../examples/rtl/rom_table.sv) saturates entry 0 and says so.
3. **Check the table in the testbench by recomputing it independently.**
   [`techniques_tb.sv`](../examples/tb/techniques_tb.sv) recomputes the reciprocal table
   rather than trusting the same function — otherwise the check is circular.
4. **Do not use a local variable with an initialiser inside the function.** Another
   Yosys frontend restriction, and easy to trip over.

**Known uses.** [`rom_table.sv`](../examples/rtl/rom_table.sv) (fixed-point
reciprocal), the microcode image in [`useq.sv`](../examples/rtl/useq.sv),
[`mul_const.sv`](../examples/rtl/mul_const.sv) and
[`div_const.sv`](../examples/rtl/div_const.sv) (the constant recoded at elaboration into
a shift-add structure).

A close relative worth distinguishing: [`crc_parallel.sv`](../examples/rtl/crc_parallel.sv)
uses constant functions at elaboration too, but it is not building a *table* — it is
**unrolling a recurrence** into an XOR network, so the result is combinational logic
rather than stored data. Same mechanism, different output, and the entry it belongs to is
[#10 Parameterized Generator](#10-parameterized-generator).

**Related.** [#11](#11-configuration-package), [#13](#13-inference-template),
[#15 Microcoded Sequencer](41-structural-and-behavioral-patterns.md#15-microcoded-sequencer),
[docs/23](23-structural-design-techniques.md).

---

# Timing and physical

This group spends the two currencies a functional simulation cannot show you:
**depth** (logic levels on the critical path) and **fanout** (loads on one net). A
design can be functionally perfect and unimplementable, which is why every entry here
names a tool measurement rather than a rule of thumb.

The recipe used throughout:

```bash
yosys -p "read_verilog -sv -DSYNTHESIS pkg.sv mod.sv; hierarchy -top mod; \
          proc; opt -fast; flatten; techmap; opt -fast; ltp -noff; stat"
```

`flatten` matters — without it `ltp` stops at the instance boundary and reports a path
that is not the real one. And treat a 10% difference as noise: the mapping the tool
chose is one of many equivalent ones.

## 16. Pipeline Insertion / Retiming

**Intent.** Cut a long combinational path into stages that each meet the clock.

**Motivation.** An expression whose depth exceeds the clock period has to be cut. The
questions are where, how many, and how you know it helped — and the last one is where
most of the value is, because the intuitive answers are frequently wrong.

**Applicability.** Use it when depth is the constraint and latency is affordable. **Do
not use it** on a path inside a feedback loop — registering a recurrence does not
shorten it, and the answers there are
[#21 Interleaving](41-structural-and-behavioral-patterns.md#21-interleaving-c-slowing) or
a carry-save accumulator. And stop when the measurement stops improving.

**Structure.** Make the cut set a *parameter*, so the combinational version and every
pipelined version are the same description:

```systemverilog
// dot_rs_dp.sv -- CUTS is a bit mask. 4'b0000 IS the combinational reference.
if (CUTS[1]) begin : g_cut2
  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n)  sum_q <= '0;
    else if (adv[1])  sum_q <= sum_d;
  end
end else begin : g_wire2
  assign sum_q = sum_d;
end
```

**Consequences.** Measured on that datapath, sweeping the cut set
([docs/38 §3](38-pipeline-staging-and-stalls.md#3-measuring-a-cut-set)):

| cuts enabled | latency | depth (gates) | |
|---|---|---|---|
| none | 0 | 68 | the combinational reference |
| clamp only | 1 | **68** | **a register at the end cuts nothing** |
| tree + clamp | 2 | 44 | |
| products + tree | 2 | **26** | 2.6×, at latency 2 |
| all four | 4 | 25 | two more cycles bought one gate |

*Buys:* depth. *Costs:* latency, flops, and — the part people forget — the control to
go with them.

**Implementation.**
1. **A cut must cross every path in the set exactly once.** A "cut" that some paths
   bypass is not a cut, and the tool will tell you by not improving.
2. **A register at the *end* cuts nothing.** The first row of that table is the whole
   lesson: 68 gates before, 68 gates after, one cycle of latency spent.
3. **Cut after operators, not inside them.** The tool will retime across a boundary if
   you let it; it will not restructure a multiplier because you put a flop in the middle
   of its expression.
4. **The worst stage sets the clock, so balance them.** And measure after each cut
   rather than adding four and hoping.
5. **Diminishing returns are real and measurable.** 25 was the multiplier's own depth.
   Below that you either cut inside an operator or accept the clock it gives you.

**Known uses.** [`dot_rs_dp.sv`](../examples/rtl/dot_rs_dp.sv),
[`adder_tree.sv`](../examples/rtl/adder_tree.sv) (optional register at every level),
[`cordic_sincos.sv`](../examples/rtl/cordic_sincos.sv) (one iteration per stage),
[`fir_systolic.sv`](../examples/rtl/fir_systolic.sv).

**Related.** [#19 Tree Reduction](#19-tree-reduction),
[#17 Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline),
[#18 Global Stall](41-structural-and-behavioral-patterns.md#18-global-stall-pipeline-enable),
[docs/38](38-pipeline-staging-and-stalls.md).

---

## 17. Registered Boundaries

**Intent.** Register every module output, so each block closes timing on its own and
floorplans cleanly.

**Motivation.** A combinational path that starts in one module, crosses two boundaries
and ends in a third is nobody's problem to fix: each module looks fine, the tool reports
a path with three owners, and the fix requires changing all of them. Register the
outputs and every path is inside one module, which is where the person who can fix it
works.

**Applicability.** Use it at hierarchical boundaries you want to close, verify or place
independently — which in a large design is most of them. **Do not use it** on a leaf
module where it doubles the latency of something trivial, and do not use it where the
latency is in a specification you do not control. The cost is a cycle *per boundary*,
and in a deep hierarchy that adds up faster than people expect.

**Structure.** For a stream, the tool is a register slice, and *which* slice depends on
which direction is long:

```systemverilog
// axis_reg_slice.sv -- MODE picks the shape. 1 = forward, 2 = reverse,
// 3 = both (skid). 9 flops for one direction, 18 for both, at DW=8.
axis_reg_slice #(.DW(DW), .MODE(3)) u_bnd ( .clk, .rst_n,
  .s_valid, .s_data, .s_ready,  .m_valid, .m_data, .m_ready );
```

**Consequences.** *Buys:* per-block timing closure; a floorplan that can move blocks
without re-timing paths between them; and a much cleaner incremental build. *Costs:* one
cycle per boundary per direction, and the flops.

**Implementation.**
1. **Registering only the forward path is half a boundary.** `ready` then still crosses
   combinationally, and in a chain of such boundaries the backward path becomes the
   critical path all by itself. Decide which direction is long and pick the slice
   accordingly ([#3 in docs/41](41-structural-and-behavioral-patterns.md#3-forward-register-slice)).
2. **Count the cycles you are adding.** A design with eight registered boundaries has
   eight cycles of latency it did not have, and if any of them is in a control loop that
   matters.
3. **The three-process FSM style gives registered outputs for free.** Computing the next
   state and the next outputs in the same block registers the outputs without a cycle of
   delay, which is the exception to the cost above.
4. **Do not register a *constant* or a parameter-derived tie-off.** It is a flop that can
   never change, and the tool may or may not remove it.

**Known uses.** [`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv) and
[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) are the tools;
[`fsm_three_process.sv`](../examples/rtl/fsm_three_process.sv) is the no-latency-penalty
case. This repository does **not** register every boundary — many modules are
deliberately combinational so their depth can be measured — which is itself the honest
note: the pattern is a large-design discipline, not a universal law.
[docs/34](34-coding-conventions-and-reuse.md) has the convention.

**Related.** [#2 Skid Buffer](41-structural-and-behavioral-patterns.md#2-skid-buffer-full-register-slice),
[#16](#16-pipeline-insertion--retiming), [#18](#18-register-duplication).

---

## 18. Register Duplication

**Intent.** Copy a high-fanout driver so each copy drives a local region.

**Motivation.** One flop driving two thousand loads has a net whose delay is dominated
by routing, and no amount of logic optimisation fixes it — the problem is physical. Four
copies each driving five hundred loads have four short nets. The logic is identical; the
placement is not.

**Applicability.** Use it for a high-fanout *control* signal: a global stall enable, a
reset, a mode bit. **Do not use it** for a signal whose fanout is high because it is on
the critical path *logically* — duplicating a late-arriving signal duplicates its
lateness. And do not do it by hand before checking whether the tool already did: modern
synthesis replicates automatically, and a manual copy plus `dont_touch` can be *worse*
than letting it choose.

**Structure.** The attributes are the pattern — without them the tool merges the copies
straight back:

```systemverilog
// fanout_replicate.sv
for (genvar c = 0; c < int'(COPIES); c++) begin : g_copy
  (* dont_touch = "true" *)               // Synopsys, Vivado
  (* preserve *)                          // Intel Quartus
  (* syn_preserve = "1" *)                // Synplify
  (* keep = "true" *)                     // Vivado (also blocks merging)
  logic [WIDTH-1:0] rep_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n) rep_q <= '0;
    ...
```

**Consequences.** *Buys:* short nets and a placeable design. *Costs:* `COPIES` × the
flops; one cycle of latency if you insert the copies as a new stage rather than
replicating an existing one; and `dont_touch`, which disables other optimisations on
that register.

**Implementation.**
1. **Every vendor spells the attribute differently, so write them all.** A single
   `dont_touch` works on two toolchains out of four and the copies silently merge on the
   others.
2. **The copies must be functionally identical.** If they can diverge — different
   enables, different resets — you have built four registers, not one replicated one, and
   the design's behaviour now depends on which copy a load sees.
3. **Check it worked.** The synthesis report's fanout column, not the source.
4. **Prefer letting the tool do it.** Manual replication is for when you have measured
   that the tool did not, or did it wrong.

**Known uses.** [`fanout_replicate.sv`](../examples/rtl/fanout_replicate.sv). The
motivating case is the global stall enable in
[`dot_rs_global.sv`](../examples/rtl/dot_rs_global.sv), whose cost
[docs/38 §6](38-pipeline-staging-and-stalls.md#6-global-stall) frames as fanout rather
than depth.

**Related.** [#18 Global Stall](41-structural-and-behavioral-patterns.md#18-global-stall-pipeline-enable),
[#17](#17-registered-boundaries), [docs/22](22-timing-closure-and-optimization.md).

---

## 19. Tree Reduction

**Intent.** Combine N terms in log N depth instead of N.

**Motivation.** `a+b+c+d+...` written as a loop accumulating into one variable is a
chain: each add waits for the previous one, so depth is proportional to N. Pairing them
— `(a+b)+(c+d)` — gives depth ⌈log₂N⌉. The result is identical for associative
operations, and the difference is large.

**Applicability.** Use it for any associative reduction: add, OR, AND, XOR, min, max,
comparison. **Do not use it** for a non-associative operation, and be careful with
*floating point*, where addition is not associative and a tree gives a different — often
better, but different — answer from a chain. For fixed point with enough guard bits, the
results are bit-identical.

**Structure.** Pairwise, doubling the stride:

```systemverilog
// dot_rs_dp.sv -- a procedural loop that builds a TREE, because each iteration
// writes a different lvalue. Compare the chain form, which writes one.
for (int s = 1; s < int'(TAPS); s = s * 2)
  for (int i = 0; i + s < int'(TAPS); i = i + 2*s)
    part[i] = part[i] + part[i + s];
sum_d = part[0];
```

**Consequences.** Measured, same arithmetic, chain versus tree
([docs/38 §3](38-pipeline-staging-and-stalls.md#3-measuring-a-cut-set)):

| taps | tree (gates) | chain (gates) |
|---|---|---|
| 4 | **25** | 33 |
| 16 | **43** | 89 |

*Buys:* depth, and the advantage grows with N. *Costs:* essentially nothing in area —
the same number of adders — but the intermediate widths differ, so sizing needs care.

**Implementation.**
1. **Size the intermediates for the tree, not the chain.** A balanced tree's partial
   sums grow by one bit per level: `log2(N)` extra bits total, which is the same as the
   chain needs in total but distributed differently.
2. **Handle N that is not a power of two.** The loop above does, by skipping the
   pairings that would run off the end. A version that assumes a power of two is a bug
   waiting for a parameter change.
3. **A procedural loop builds a tree only if each iteration writes a different
   lvalue.** Writing one accumulator in a loop gives a chain no matter how you nest it.
   [docs/37 §4](37-parameterized-video-pipelines.md) works through why, with the
   unrolled output.
4. **For floating point, decide and document.** A tree changes the rounding. That is
   usually acceptable and must not be accidental.

**Known uses.** [`adder_tree.sv`](../examples/rtl/adder_tree.sv) (recursive, with
optional pipeline registers per level, tested at N = 1, 2, 3, 5, 8, 16),
[`dot_rs_dp.sv`](../examples/rtl/dot_rs_dp.sv),
[`popcount.sv`](../examples/rtl/popcount.sv),
[`lzc.sv`](../examples/rtl/lzc.sv) (proved exhaustively over all 2³² inputs),
[`crc_parallel.sv`](../examples/rtl/crc_parallel.sv).

**Related.** [#16](#16-pipeline-insertion--retiming), [#21](#21-one-hot-encoding--and-or-mux),
[#21 Interleaving](41-structural-and-behavioral-patterns.md#21-interleaving-c-slowing)
(the answer when the reduction is a recurrence instead).

---

## 20. Lookahead / Precomputation

**Intent.** Compute a flag a cycle early and register it, so its consumer sees a flop
instead of a comparator.

**Motivation.** `full` is computed from the pointers, and its consumer needs it to
decide whether to write *this* cycle — so the comparator is in the consumer's critical
path. If instead you compute "will be full after this cycle's write" and register it,
the consumer sees a register output. The logic moved a cycle earlier; the path got
shorter.

**Applicability.** Use it for any flag on a critical path whose next value is
computable from this cycle's state and inputs: FIFO thresholds, "last beat",
almost-full, a comparison against a constant. **Do not use it** when the next value
depends on something not yet known — then the precomputation is a guess, and you need a
speculation-and-recovery scheme, which is a much bigger commitment.

**Structure.** Two forms, and it is worth being clear they differ:

```systemverilog
// (a) A THRESHOLD flag, which is what sync_fifo.sv has. Combinational on the
// level, and it exists because `full` arrives too late for a producer that needs
// a cycle to react.
assign almost_full  = (level >= (AW+1)'(DEPTH - 1));
assign almost_empty = (level <= (AW+1)'(1));
```

```systemverilog
// (b) True lookahead -- sketch. Compute NEXT cycle's flag now and register it, so
// the consumer sees a flop rather than a comparator.
always_comb  full_next = (level_next == DEPTH);
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n) full_q <= 1'b0; else full_q <= full_next;
```

**Consequences.** *Buys:* the comparator leaves the consumer's path. *Costs:* one flop
per flag; a `_next` expression that must account for *every* way the state can change
this cycle — which is where it goes wrong; and a flag that is now about the next cycle,
so every consumer's meaning shifts by one.

**Implementation.**
1. **The `_next` expression must cover every transition.** Missing one — a
   simultaneous read and write, a flush — makes the flag wrong in exactly the corner
   case it exists for.
2. **Do not register a flag the consumer needs *this* cycle.** An async FIFO's write
   side must gate on the live `full`; registering it overruns by one. Lookahead is for
   the *threshold* flags, not the exact ones.
3. **Name the two forms differently.** `almost_full` (a threshold, now) and `full_next`
   (a prediction, next cycle) are different signals and conflating them is a real bug.
4. **A threshold flag's margin is a calculation.** It must be at least the consumer's
   reaction latency, which means the FIFO's interface depends on its user — state it in
   the header.

**Known uses.** Form (a): [`sync_fifo.sv`](../examples/rtl/sync_fifo.sv)
(`almost_full`/`almost_empty`), [`uart_periph.sv`](../examples/rtl/uart_periph.sv),
[`skew_buffer.sv`](../examples/rtl/skew_buffer.sv). Also
[`timer.sv`](../examples/rtl/timer.sv), which counts **down** so the terminal condition
is a NOR rather than a wide comparator — the same instinct applied to the comparison
itself. **Form (b) is a sketch** — no module here registers a predicted flag.

**Related.** [#4 FIFO Decoupler](41-structural-and-behavioral-patterns.md#4-fifo-decoupler),
[#23 Credit-Based Flow Control](41-structural-and-behavioral-patterns.md#23-credit-based-flow-control),
[#16](#16-pipeline-insertion--retiming).

---

## 21. One-Hot Encoding / AND-OR Mux

**Intent.** Make a decode one gate deep by spending a wire per case.

**Motivation.** A priority `if`/`else if` chain over N cases is N levels deep: case N's
output waits for all N−1 tests above it. If the selects are known to be mutually
exclusive, each case can be masked by its own select and the results ORed — constant
depth, at the cost of one AND per case and an OR tree.

**Applicability.** Use it where the selects are **provably** one-hot: a one-hot FSM
state, a decoded address, an arbiter's grant. **Do not use it** where they are not —
and this is the trap, because the two forms are *not equivalent*, and the compiler will
not tell you.

**Structure.** The four forms, and the one that differs:

```systemverilog
// select_styles.sv -- one function, four control structures, and the one
// difference that matters:
//   d_if      if / else-if chain      priority, N levels deep
//   d_casez   casez with don't-cares  priority, N levels deep
//   d_loop    for loop over the bits  priority, N levels deep
//   d_parallel  AND-OR                CONSTANT depth -- and NOT equivalent
//
// What `unique case (1'b1)` compiles to: every lane masked by its own select and
// ORed. Genuinely faster. And it is only correct if the selects really are
// one-hot -- which is what the word `unique` PROMISES, not what it checks.
```

**Consequences.** Constant depth instead of N levels, for one AND per case plus an OR
tree. But the formal proof in
[`select_styles_fv.sby`](../formal/select_styles_fv.sby) **proves the three priority
forms equal for every input and the parallel form not equal to them** — which is the
entire content of the word `unique`, and the reason this entry has a warning rather than
a recommendation.

**Implementation.**
1. **`unique` is a promise you make, not a check the tool performs.** In simulation it
   is an assertion; in synthesis it is a licence to build the parallel form. If the
   promise is false, simulation and hardware disagree — the worst possible failure mode.
2. **Prove or assert the one-hot property.** `$onehot(sel)` at the point of use. If you
   cannot, use the priority form and pay the depth.
3. **One-hot FSM state is the safe case, but only with recovery.** A one-hot state
   vector has 2^N encodings of which N are legal, so a single-event upset lands in an
   illegal one. [`fsm_safe.sv`](../examples/rtl/fsm_safe.sv) recovers in one cycle, and
   [`fsm_tb.sv`](../examples/tb/fsm_tb.sv) injects all 12 illegal encodings by `force`
   to prove it.
4. **Encoding choice is not free either way.** One-hot costs N flops and cheap decode;
   binary costs log N flops and a decoder. The crossover depends on the state count and
   on how much the decode is on the critical path.

**Known uses.** [`select_styles.sv`](../examples/rtl/select_styles.sv) (all four forms,
with the inequivalence proved), [`fsm_onehot.sv`](../examples/rtl/fsm_onehot.sv),
[`fsm_safe.sv`](../examples/rtl/fsm_safe.sv),
[`onehot_decoder.sv`](../examples/rtl/onehot_decoder.sv),
[`arb_fixed.sv`](../examples/rtl/arb_fixed.sv),
[`ring_counter.sv`](../examples/rtl/ring_counter.sv) (one-hot with self-correction).

**Related.** [#19 Tree Reduction](#19-tree-reduction) (the OR tree),
[#19 Arbiter](41-structural-and-behavioral-patterns.md#19-arbiter),
[docs/26 §7](26-fsm-coding-styles.md), [docs/27](27-control-structures.md).

---

## 22. SRL Delay Line

**Intent.** Get a long fixed delay from one LUT per 16–32 stages instead of a flop per
stage.

**Motivation.** A 32-cycle delay on a 16-bit bus is 512 flops as a shift register. On a
Xilinx FPGA the same thing is 16 SRL32s — one LUT each — because a LUT can be configured
as a 32-stage shift register. That is a 32× saving on a structure that appears in every
latency-matching problem.

**Applicability.** Use it for a fixed delay with no taps, or with a tap only at the end:
latency matching a sideband signal against a pipelined datapath, a delay for correlation.
**Do not use it** when you need to read intermediate stages — an SRL has one output —
and do not use it when you need reset, because then it is not an SRL any more.

**Structure.** The critical detail is what is *missing*:

```systemverilog
// srl_delay.sv -- no reset. That is deliberate: an SRL has no reset on its
// internal stages, so a reset here forces DEPTH fabric flops per bit.
if (DEPTH == 0) begin : g_bypass
  assign dout = din;
end else begin : g_srl
  for (genvar b = 0; b < int'(WIDTH); b++) begin : g_bit
    logic [DEPTH-1:0] sr;
    always_ff @(posedge clk)
      if (en) sr <= {sr[DEPTH-2:0], din[b]};
    assign dout[b] = sr[DEPTH-1];
  end
end
```

**Consequences.** *Buys:* one LUT per 16 or 32 stages per bit, instead of a flop per
stage per bit. *Costs:* no reset (so the contents are undefined until DEPTH beats have
passed, which a [valid-bit pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline)
makes harmless); no intermediate taps; a fixed depth; and one common enable for the
whole line.

**Implementation.**
1. **No reset, or it is not an SRL.** This is the pattern's one hard rule, and it is why
   [#25 Minimal Reset](#25-minimal-reset) is a prerequisite rather than a nicety.
2. **Depth 16 and 32 are the sweet spots.** 17 costs the same as 32 on most
   architectures; check the primitive's granularity rather than assuming linearity.
3. **Handle `DEPTH == 0`.** A zero-depth delay is a wire, and a parameterised module
   should say so rather than producing a negative part-select.
4. **Verify the mapping.** `stat` or the utilisation report. A testbench cannot tell an
   SRL from 512 flops, and that is exactly the failure this pattern is guarding against.
5. **Use it for latency matching, not for pulse shaping.** A delay whose *purpose* is a
   timing relationship is [anti-pattern A8](40-rtl-design-patterns.md#a8-relying-on-gate-delays-for-timing-or-pulse-shaping)
   if it is not counted in clocks — an SRL is fine because it counts clocks.

**Known uses.** [`srl_delay.sv`](../examples/rtl/srl_delay.sv), tested at depth 16 with
a random enable pattern in [`techniques_tb.sv`](../examples/tb/techniques_tb.sv).
[`pipe_delay.sv`](../examples/rtl/pipe_delay.sv) is the flop-based sibling for when you
need reset or taps.

**Related.** [#13 Inference Template](#13-inference-template), [#25 Minimal Reset](#25-minimal-reset),
[#17 Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline),
[docs/29](29-memories-and-inference.md).

---

## 23. Multicycle Datapath

**Intent.** Let a path take more than one clock, and tell the timing tool so.

**Motivation.** Some paths are only sampled every N cycles — a datapath behind a
`tick` from [#8](#8-clock-enable-over-derived-clock), a result read once per
transaction. The tool does not know that, so it tries to close the path at the full
clock and fails, or the design is padded with registers that buy nothing. Telling it is
a constraint, and it can buy several times the period.

**Applicability.** Use it where a path's destination genuinely cannot capture every
cycle, and where the enable structure *proves* it. **Do not use it** on a path whose
destination *might* capture every cycle — you have then told the tool a falsehood, and
the failure is silent and intermittent. This is the pattern with the worst
failure mode in the catalogue, because a wrong constraint produces a design that passes
timing and does not work.

**Structure.** *Mostly a constraint, so the RTL half is the discipline that justifies
it.*

```tcl
# The setup relaxation and the HOLD relaxation are both needed. Specifying only
# setup leaves the tool analysing hold at the original relationship, which is
# usually pessimistic but occasionally wrong.
set_multicycle_path -setup 4 -from [get_cells src_reg] -to [get_cells dst_reg]
set_multicycle_path -hold  3 -from [get_cells src_reg] -to [get_cells dst_reg]
```

```systemverilog
// The RTL side: the destination's enable must make the claim true, and the claim
// should be asserted so simulation catches a violation.
always_ff @(posedge clk) if (tick) dst_reg <= f(src_reg);
// a_mc: assert property (@(posedge clk) tick |=> !tick[*DIV-1]);
```

**Consequences.** *Buys:* up to N× the period on the constrained paths, with no
additional logic at all. *Costs:* a constraint that must be maintained alongside the
RTL, and which no functional simulation checks. It is the only pattern here whose
correctness lives outside the HDL.

**Implementation.**
1. **Constrain hold as well as setup.** `-setup N` with no `-hold N-1` is the classic
   mistake, and on a path where source and destination share a clock it is usually
   merely pessimistic — but not always.
2. **Assert the enable's spacing in RTL.** The constraint claims the destination cannot
   capture more often than every N cycles; make that a property the simulation checks,
   or it is an unverified assumption.
3. **Keep the constraint next to the reason.** A `set_multicycle_path` whose
   justification is not written down will be deleted or copied wrongly.
4. **Prefer making it structurally obvious.** A path behind an enable generated by one
   named divider is auditable; a path behind three ANDed conditions is not.

**Known uses.** *Sketch only — the pattern is mostly a constraint.*
[`clk_div_en.sv`](../examples/rtl/clk_div_en.sv) generates the enable that would justify
one; [`i2c_master.sv`](../examples/rtl/i2c_master.sv)'s quarter-SCL datapath is the
natural candidate. [docs/32 §7](32-timing-constraints.md) covers exception precedence,
which is where multicycle constraints interact badly with false paths.

**Related.** [#8](#8-clock-enable-over-derived-clock),
[#20 Resource Sharing](41-structural-and-behavioral-patterns.md#20-resource-sharing-time-multiplexing),
[docs/32](32-timing-constraints.md).

---

## 24. I/O Register Packing

**Intent.** Put the boundary flop in the pad, so pin timing is deterministic.

**Motivation.** A flop placed somewhere in the fabric and connected to a pin has a
routing delay that varies between builds, so the setup/hold window at the pin varies
too. The pad's own register does not move, so its timing is a number in the datasheet
rather than a build artefact. For a source-synchronous interface — DDR memory, a
parallel ADC, an LVDS link — this is the difference between an interface that works and
one that works on three boards out of five.

**Applicability.** Use it on every signal of a timing-critical external interface, and
on `IDDR`/`ODDR` where the interface is double-rate. **Do not** bother for a slow,
asynchronous input — a button, an I2C line — where you are going to synchronise and
debounce it anyway and a few hundred picoseconds is irrelevant.

**Structure.** *Sketch only — needs real pins.* The RTL constraint is that there must
be **nothing** between the flop and the pad:

```systemverilog
// Sketch. The register must be the LAST thing before the port, with no logic
// after it -- an inverter, a mux, even a buffer, and it cannot be packed.
always_ff @(posedge clk) begin
  dq_out_q  <= dq_out_d;
  dq_oe_q   <= dq_oe_d;
  dq_in_q   <= dq_pad;      // and the FIRST thing after, on the way in
end
assign dq_pad = dq_oe_q ? dq_out_q : 1'bz;
```

```tcl
set_property IOB TRUE [get_ports dq[*]]     # Vivado; and check it took
```

**Consequences.** *Buys:* pin timing that is a datasheet number. *Costs:* one flop of
latency each way; no logic may sit between the flop and the pad, which sometimes forces
a restructuring; and the packing must be *verified* in the report, because the tool
declines silently when something prevents it.

**Implementation.**
1. **Nothing between the flop and the pad.** Not a mux, not an inverter. Restructure so
   the flop is last.
2. **Check the report.** `IOB TRUE` is a request; the tool refuses it when the register
   has another load, or a reset it cannot place. A refused request looks exactly like a
   granted one in the source.
3. **A tristate needs its output *enable* registered too,** and packed, or the enable's
   timing becomes the limit instead.
4. **Constrain the interface as well.** `set_input_delay`/`set_output_delay` describe
   what is outside the chip; IOB packing only makes what is inside deterministic.
   [docs/32 §6](32-timing-constraints.md) has the form.

**Known uses.** *Sketch only.* [`gpio.sv`](../examples/rtl/gpio.sv) is the
output-enable-rather-than-tristate half of the discipline, and the closest thing here.
[docs/24](24-dft-clocking-and-x-discipline.md) and
[docs/32](32-timing-constraints.md) cover the rest.

**Related.** [#5 Primitive Wrapper](41-structural-and-behavioral-patterns.md#5-primitive-wrapper)
(where `IOBUF`/`IDDR` should live), [#17](#17-registered-boundaries),
[#1 Two-Flop Synchronizer](#1-two-flop-synchronizer) (what an asynchronous input needs
next).

---

## 25. Minimal Reset

**Intent.** Reset the control state and nothing else.

**Motivation.** A design where every register has an asynchronous reset has a reset net
fanning out to everything — and, on an FPGA, a datapath that cannot be absorbed into the
hard blocks, because DSP, block RAM and SRL stages have no asynchronous reset. The
datapath falls out into fabric: bigger, slower, and for no benefit, because a
[valid-bit pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline)
already makes the uninitialised contents unobservable.

**Applicability.** Use it wherever a valid bit, an enable, or a known start-up sequence
makes the datapath's initial contents unobservable — which is most pipelines and all
memories. **Do not use it** where the datapath's value *is* observable before the first
valid beat, where a safety standard requires a known state, or where DFT wants the
controllability. This is a genuine trade, not a free win.

**Structure.** The contrast in one place:

```systemverilog
// CONTROL -- reset it. The valid bits are what make everything else safe.
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)      valid_q <= '0;
  else if (flush)  valid_q <= '0;
  else if (en)     valid_q <= {valid_q[STAGES-2:0], valid_i};
end

// DATAPATH -- do not. srl_delay.sv, deliberately:
always_ff @(posedge clk)
  if (en) sr <= {sr[DEPTH-2:0], din[b]};
```

**Consequences.** *Buys:* hard-block inference (the reason it exists); a much smaller
reset net; and a design that a flush can clear in one cycle by touching only the control
path. *Costs:* X in simulation until the first valid beat has propagated, which needs
discipline; less DFT controllability; and a reviewer has to understand why the
asymmetry is deliberate — so it must be commented.

**Implementation.**
1. **The valid bit is the precondition, not an optional extra.** Minimal reset without a
   valid-bit pipeline means garbage reaching the output after reset, and nothing to mark
   it.
2. **X-propagation discipline is now part of the design.** A testbench that lets X reach
   a DUT whose test has not started will report failures that are not real, and an
   X-optimistic construct can hide ones that are. [docs/24 §7](24-dft-clocking-and-x-discipline.md)
   is the treatment; [`fsm_tb.sv`](../examples/tb/fsm_tb.sv) records the trap.
3. **Comment the absence.** A missing reset looks like an omission. `srl_delay.sv` says
   why in its header, and that comment is the difference between a pattern and a bug.
4. **Flush clears control only.** The datapath keeps its stale contents, which is fine
   because nothing will look at them — and that is why flush is cheap.

**Known uses.** [`srl_delay.sv`](../examples/rtl/srl_delay.sv) (no reset, deliberately),
[`ram_sp.sv`](../examples/rtl/ram_sp.sv) and the rest of the RAM family (memory arrays
unreset), [`mac_pipelined.sv`](../examples/rtl/mac_pipelined.sv),
[`pipe_ctrl.sv`](../examples/rtl/pipe_ctrl.sv) (the control that makes it safe).

**Related.** [#13 Inference Template](#13-inference-template), [#22 SRL Delay Line](#22-srl-delay-line),
[#17 Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline),
[#6 Reset Synchronizer](#6-reset-synchronizer),
[A6](40-rtl-design-patterns.md#a6-asynchronous-reset-on-datapath-registers).

---

## See also

- [docs/40 — RTL design patterns: the catalogue](40-rtl-design-patterns.md)
- [docs/41 — Structural and behavioural patterns](41-structural-and-behavioral-patterns.md)
- [docs/43 — Memory and verification patterns](43-memory-and-verification-patterns.md)
- [docs/28 — Clock domain crossing](28-clock-domain-crossing.md) — the full treatment of
  the first group
- [docs/24 — DFT, clocking and X discipline](24-dft-clocking-and-x-discipline.md) — why a
  clock may never come from logic, and the X rules Minimal Reset depends on
- [docs/32 — Timing constraints](32-timing-constraints.md) — what each of these patterns
  obliges you to tell the tools
- [docs/22 — Timing closure and optimization](22-timing-closure-and-optimization.md) —
  depth versus delay, and what a high-fanout net actually costs
- [docs/37 — Parameterized video pipelines](37-parameterized-video-pipelines.md) — the
  elaboration group at full stretch, with the loops unrolled
- [docs/38 — Pipeline staging and stall control](38-pipeline-staging-and-stalls.md) —
  where the cut-set and tree-versus-chain numbers were measured
