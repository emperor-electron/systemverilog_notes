# Flow Control and Handshakes

Two blocks that produce and consume data at rates neither controls need a
protocol for saying "I have something" and "I can take it". Almost every modern
on-chip interface — AXI, AXI-Stream, Avalon, TileLink, and most internal buses
— is built on the same two-signal handshake, and almost every bug in one comes
from the same short list of rule violations.

This document covers the valid/ready contract, the buffering that makes it fast,
backpressure and deadlock, arbitration, and how to verify all of it.

Companion code, all verified:
[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) ·
[`sync_fifo.sv`](../examples/rtl/sync_fifo.sv) ·
[`pipe_ctrl.sv`](../examples/rtl/pipe_ctrl.sv) ·
[`arb_fixed.sv`](../examples/rtl/arb_fixed.sv) ·
[`arb_round_robin.sv`](../examples/rtl/arb_round_robin.sv) ·
[`arb_weighted.sv`](../examples/rtl/arb_weighted.sv) ·
simulated by [`skid_buffer_tb.sv`](../examples/tb/skid_buffer_tb.sv) and
[`fifo_tb.sv`](../examples/tb/fifo_tb.sv),
proved in [`formal/skid_buffer_fv.sby`](../formal/skid_buffer_fv.sby),
[`formal/sync_fifo_fv.sby`](../formal/sync_fifo_fv.sby) and
[`formal/pipe_ctrl_fv.sby`](../formal/pipe_ctrl_fv.sby)

---

## Contents

- [1. The valid/ready contract](#1-the-validready-contract)
- [2. The rule everyone breaks](#2-the-rule-everyone-breaks)
- [3. Registering a handshake: the skid buffer](#3-registering-a-handshake-the-skid-buffer)
- [4. FIFOs as flow control](#4-fifos-as-flow-control)
- [5. Credit-based flow control](#5-credit-based-flow-control)
- [6. Pipelines under backpressure](#6-pipelines-under-backpressure)
- [7. Arbitration](#7-arbitration)
- [8. Deadlock, livelock and starvation](#8-deadlock-livelock-and-starvation)
- [9. Verifying flow control](#9-verifying-flow-control)
- [10. Checklist](#10-checklist)

---

## 1. The valid/ready contract

```systemverilog
output logic          valid;    // producer: "data is on the bus now"
output logic [DW-1:0] data;     // producer: the payload
input  logic          ready;    // consumer: "I will take it this cycle"
```

A **transfer happens on any rising clock edge where `valid && ready`.** That is
the entire protocol, and it has exactly four rules:

1. **`valid` must not depend combinationally on `ready`.** The producer decides
   whether it has data without asking whether the consumer wants it.
2. **Once `valid` is asserted it must stay asserted, with `data` unchanged,
   until the transfer completes.** No withdrawing an offer.
3. **`ready` may depend on `valid`, or not.** The consumer is allowed to look
   before deciding.
4. **Neither side may assume anything about the other's timing.** Any number of
   cycles may pass in either state.

Rules 1 and 3 together are what make the protocol composable without
combinational loops, and rule 2 is what makes it safe to register.

### Why rule 1 exists

If the producer's `valid` depended on `ready`, and the consumer's `ready`
depended on `valid` (which rule 3 permits), the two would form a combinational
loop through the interface. The asymmetry is deliberate: **`ready` may look at
`valid`; `valid` may never look at `ready`.**

```systemverilog
// LEGAL: consumer looks at valid
assign ready = !full || (valid && can_forward);

// ILLEGAL: producer looks at ready -- and if the consumer also looks
// at valid, this is a combinational loop across a module boundary
assign valid = has_data && ready;
```

The illegal form is also wrong even when it does not loop: it makes `valid`
disappear when `ready` drops, violating rule 2.

### Why rule 2 exists

A consumer that sees `valid` may begin work — allocate a buffer entry, start a
lookup — before it asserts `ready`. If the producer can withdraw, that work is
wasted or, worse, half-committed. "Valid is sticky" is what lets a consumer
pipeline its own accept decision.

This also rules out the common shortcut of recomputing `data` every cycle from
a source that is still moving. Once you assert `valid`, the payload is frozen.

---

## 2. The rule everyone breaks

**The naive way to register a handshake breaks it.**

The temptation, when `valid`/`data` arrive too late in the cycle, is to drop in
a register:

```systemverilog
// BROKEN
always_ff @(posedge clk) begin
  out_valid <= in_valid;
  out_data  <= in_data;
end
assign in_ready = out_ready;     // combinational path straight through
```

Two things are now wrong. The `ready` path is still combinational end to end, so
nothing was gained on that side; and when `out_ready` drops, the beat already
captured in `out_valid` has nowhere to go while a new one is arriving behind it.
Data is lost.

The other naive fix — registering `ready` as well — loses throughput instead:
the producer learns about backpressure a cycle late, so it must conservatively
stall every other cycle, giving 50% throughput.

**Registering a handshake without losing data or throughput requires one extra
storage slot.** That is a skid buffer, and it is the reason the module exists.

---

## 3. Registering a handshake: the skid buffer

[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) breaks the combinational path
in *both* directions while sustaining one transfer per cycle.

```systemverilog
// Accept input whenever the skid slot is free.
assign in_ready = !skid_valid;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    out_valid <= 1'b0; skid_valid <= 1'b0; ...
  end else begin
    if (skid_valid) begin
      // Drain the skid slot into the output register when it frees up.
      if (!out_valid || out_ready) begin
        out_valid  <= 1'b1;
        out_data   <= skid_data;
        skid_valid <= 1'b0;
      end
    end else if (!out_valid || out_ready) begin
      // Output register is free: take directly from the input.
      out_valid <= in_valid;
      if (in_valid) out_data <= in_data;
    end else if (in_valid) begin
      // Output register is busy and the input has a beat: park it.
      skid_valid <= 1'b1;
      skid_data  <= in_data;
    end
  end
end
```

The insight is in the name. When `out_ready` drops, one beat is already
committed to the output register and one more may be arriving; the skid slot
catches the second so the input can be told to stop *next* cycle rather than
this one. `in_ready` therefore depends only on a register, never on `out_ready`.

**Cost:** two data registers, a couple of flags, and one cycle of latency.
**Benefit:** both directions registered, full throughput preserved.

Throughput is the property that actually matters and the one a naive
implementation fails, so it is asserted rather than assumed:
[`skid_buffer_tb.sv`](../examples/tb/skid_buffer_tb.sv) measures **3998 beats in
4000 cycles**.

### Proving it

[`formal/skid_buffer_fv.sby`](../formal/skid_buffer_fv.sby) proves **unbounded**
— for all time, not for 4000 cycles — that there is no loss, no duplication and
no reordering. The technique is worth reusing: make the payload *be* a sequence
number, so one assertion covers all three failures at once.

```systemverilog
always @* assume (in_data == fv_in_seq);        // payload IS the counter
f_stream    : assert (!out_valid || (out_data == fv_out_seq));
f_occupancy : assert ((fv_in_seq - fv_out_seq) ==
                      (DW'(out_valid) + DW'(skid_valid)));
f_no_orphan : assert (!skid_valid || out_valid);
f_skid_val  : assert (!skid_valid || (skid_data == (fv_out_seq + 1'b1)));
```

A gap in the sequence is loss, a repeat is duplication, out of order is
reordering. The last three properties are the **inductive invariants**: the
first assertion alone passes BMC and fails `prove`, not because the design is
wrong but because the inductive hypothesis is too weak. Adding the occupancy and
skid-contents invariants closes it.

This is only sound because the datapath is **data-independent** — the control
logic never inspects the payload, so proving it for one stream of values proves
it for all. That argument has to be checked, not assumed; it is false for
anything that routes or filters on content.

---

## 4. FIFOs as flow control

A FIFO is a skid buffer with depth. It decouples producer and consumer *rates*
rather than just their timing, which is what you need when either side bursts.

```systemverilog
assign in_ready  = !full;
assign out_valid = !empty;
```

**Depth is a bandwidth-delay product, not a guess.** Size it from the burst
length you must absorb, or from the round-trip latency of the backpressure
signal — not from a round number. Two common cases:

- Absorbing a burst of B beats while the consumer drains at rate r: depth
  ≥ B × (1 − r).
- Covering a credit round trip of L cycles at full rate: depth ≥ L.

**Almost-full is what you actually use.** A `full` flag that arrives the cycle
the FIFO fills is too late if the producer is several pipeline stages away:

```systemverilog
assign almost_full = (level >= THRESH);   // THRESH = DEPTH - in-flight beats
```

Set `THRESH` so that everything already in flight toward the FIFO still fits
when `almost_full` asserts. Getting this wrong is a slow leak — it works until
the pipeline in front of the FIFO gets deeper.

([`sync_fifo.sv`](../examples/rtl/sync_fifo.sv) uses a fixed `DEPTH - 1`, i.e. a
one-beat margin, which is right for a directly-attached producer and not enough
for one several stages away. Parameterise the threshold when the distance is
more than zero stages.)

### The flag traps

**Flags computed combinationally from the next pointer can form a loop.** The
async FIFO in this repository had exactly that bug:
`wbin_next → wgray_next → wfull → wbin_next`
([docs/28 §7](28-clock-domain-crossing.md#7-crossing-a-stream-the-async-fifo)).
Register the flags. They become one cycle pessimistic, which is the safe
direction.

**Full and empty must be distinguishable.** With a pointer pair of exactly
log₂(DEPTH) bits, full and empty look identical — both have `wr_ptr == rd_ptr`.
The standard fix is one extra bit, as in `sync_fifo.sv`:

```systemverilog
assign empty = (wr_ptr == rd_ptr);                     // equal, including MSB
assign full  = (wr_ptr[AW] != rd_ptr[AW]) &&           // wrapped exactly once
               (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
assign level = wr_ptr - rd_ptr;                        // and the level is free
```

[`formal/sync_fifo_fv.sby`](../formal/sync_fifo_fv.sby) checks flag/level
consistency and data integrity to depth 30. Its induction does **not** close,
and the `.sby` file says so rather than quietly dropping the `prove` task — a
bounded proof stated as bounded is worth more than an unbounded claim that is
not true.

---

## 5. Credit-based flow control

When the consumer is far away — across a long wire, a clock domain, or a chip
boundary — `ready` arrives too late to be useful. Credits move the accounting to
the producer:

```systemverilog
// Producer keeps a count of how many beats the consumer can still accept.
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)  credits <= INITIAL_CREDITS;
  else         credits <= credits - (send ? 1 : 0) + (credit_return ? 1 : 0);
end

assign send = has_data && (credits != 0);
```

The consumer returns a credit whenever it frees a buffer entry. The producer
never needs to know the round-trip latency — only that it must not send without
a credit.

| | valid/ready | credits |
|---|---|---|
| Latency tolerance | poor: `ready` is a per-cycle decision | good: decoupled entirely |
| Buffer required | one slot (skid) | one full round trip of entries |
| Complexity | trivial | counter each side, plus init and reset agreement |
| Where | inside a block, short wires | chip-to-chip, NoC, PCIe, across domains |

The two pitfalls are both about agreement: **initial credits must exactly match
the consumer's buffer depth** (too many overflows it, too few throttles
forever), and **reset must be coordinated** — a producer that resets alone comes
back believing in credits the consumer no longer has reserved.

---

## 6. Pipelines under backpressure

A pipeline with a valid bit per stage needs one rule: **stall the whole pipeline
together.** [`pipe_ctrl.sv`](../examples/rtl/pipe_ctrl.sv):

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)      valid_q <= '0;
  else if (flush)  valid_q <= '0;
  else if (en)     valid_q <= {valid_q[STAGES-2:0], valid_i};
end
```

A per-stage enable would let stages slip relative to each other — data in stage
3 pairing with a valid bit from stage 2 — which is the bug the single `en`
prevents. Everything travelling alongside the data must be delayed by the same
amount; that is what [`pipe_delay.sv`](../examples/rtl/pipe_delay.sv) is for
([docs/21](21-pipelining.md)).

**Flush must win over stall.** Note the ordering above: `flush` is tested before
`en`. An aborted pipeline has to clear even while stalled, or the stale beats
reappear when the stall lifts — a branch misprediction that gets executed a
hundred cycles later. This is proved, not assumed:

```systemverilog
a_flush_clears: assert property (@(posedge clk) disable iff (!rst_n)
  flush |=> (valid_q == '0));
```

[`formal/pipe_ctrl_fv.sby`](../formal/pipe_ctrl_fv.sby) proves **unbounded**
equivalence with a reference shift register, including flush-while-stalled.

For a long pipeline with backpressure, the practical structure is to let it run
freely and absorb the slack in a FIFO at the output, sized for the pipeline
depth, with `almost_full` as the stall signal. Propagating `ready` back up
through N stages combinationally does not close timing; propagating it
sequentially costs N cycles of response time and needs the same FIFO anyway.

---

## 7. Arbitration

When several producers share one consumer, something has to choose.

### Fixed priority — [`arb_fixed.sv`](../examples/rtl/arb_fixed.sv)

Lowest index wins. One line, minimal logic, and **starves** every requester below
a persistently busy one. Correct when the priorities are genuinely a
specification (an error path over a data path), wrong as a default.

The classic trick for "isolate the lowest set bit" is worth knowing:

```systemverilog
assign grant = req & (~req + 1'b1);      // == req & -req
```

### Round robin — [`arb_round_robin.sv`](../examples/rtl/arb_round_robin.sv)

Fair by construction: after granting requester *i*, priority moves to *i+1*. The
standard implementation is two fixed-priority arbiters and a mask:

```systemverilog
assign masked_req = req & mask;

arb_fixed #(.N(N)) u_hi (.req(masked_req), .grant(grant_masked));
arb_fixed #(.N(N)) u_lo (.req(req),        .grant(grant_unmasked));

// Prefer a winner above the pointer; wrap around if there is none.
assign grant = (|masked_req) ? grant_masked : grant_unmasked;

// For a one-hot grant g, ~((g - 1) | g) is exactly "bits above the set bit".
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n)               mask <= '1;
  else if (update && valid) mask <= ~((grant - 1'b1) | grant);
```

Two arbiters, one mask, one mux — and no requester waits more than N grants.
That bound is the definition of fairness and is what
[`rtl_smoke_tb.sv`](../examples/tb/rtl_smoke_tb.sv) checks.

### Weighted round robin — [`arb_weighted.sv`](../examples/rtl/arb_weighted.sv)

Each requester gets `WEIGHT[i]` consecutive grants before the pointer moves on
— the deficit-counter scheme. Use when the sharers have genuinely different
bandwidth entitlements rather than different urgencies.

### Properties every arbiter needs

```systemverilog
a_onehot:       assert property ($onehot0(grant));         // at most one winner
a_only_req:     assert property ((grant & ~req) == '0);    // only to requesters
a_grant_if_req: assert property ((|req) |-> (|grant));     // no idle cycles
```

These are in [`arb_round_robin.sv`](../examples/rtl/arb_round_robin.sv) already.
The third is the one that catches real bugs — an arbiter that sometimes grants
nobody while requests are pending wastes bandwidth invisibly.

`arb_fixed` is additionally proved **exhaustively** equivalent to an independent
lowest-set-bit reference in
[`formal/arb_fixed_fv.sby`](../formal/arb_fixed_fv.sby).

---

## 8. Deadlock, livelock and starvation

| | What it is | Typical cause |
|---|---|---|
| **Deadlock** | nothing can proceed, ever | circular dependency between two flows |
| **Livelock** | activity continues, no progress | unbounded retry without backoff |
| **Starvation** | some flows progress, one never does | fixed priority under sustained load |

**The classic deadlock** is two paths sharing buffering in opposite directions:
a request channel blocked because the response channel is full, and the response
channel blocked because the target is waiting to issue a request. Each is
waiting for the other to drain.

The standard fixes:

- **Separate buffering per direction.** Requests and responses must never share
  a queue.
- **Never let a response depend on a new request being accepted.** A block that
  must issue before it can retire has a cycle by construction.
- **Order the resources** and acquire them in a fixed global order, which makes
  a cycle impossible.
- **Guarantee sink capacity.** Only issue a request if the buffer for its
  response is already reserved — credits (§5) enforce this naturally.

**Livelock** comes from unbounded retry. Bound every retry count, and add
backoff if the retriers are symmetric — two agents retrying in lockstep at the
same interval can collide indefinitely.

**Starvation** is what round robin exists to prevent. If a fixed-priority
arbiter is the right answer for correctness, add a timeout that promotes a
long-waiting requester.

All three are **liveness** properties, and none is caught by the safety
assertions in §7 — those only say that nothing *bad* happens. The cheap way to
check liveness in this flow is `cover`:

```systemverilog
c_low_prio_wins: cover property (@(posedge clk) grant[N-1]);
c_drains:        cover property (@(posedge clk) busy ##[1:$] !busy);
```

A `cover` that cannot be reached is exactly the deadlock you were looking for.

---

## 9. Verifying flow control

### Assertions on the interface

Write these once, `bind` them to every handshake port pair, and they will find
most protocol bugs before a testbench does:

```systemverilog
// Rule 2: valid is sticky and data is frozen until the transfer completes.
a_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
  (valid && !ready) |=> (valid && $stable(data)));

// No transfer while in reset.
a_no_xfer_in_reset: assert property (@(posedge clk)
  !rst_n |-> !(valid && ready));

// Liveness, as a cover rather than an assert.
c_transfer: cover property (@(posedge clk) valid && ready);
c_backpressure: cover property (@(posedge clk) valid && !ready);
```

`bind` keeps them out of the RTL: see
[docs/06](06-modules-parameters-generate.md).

### Stimulus that finds the bugs

A driver that always asserts `valid` and a consumer that always asserts `ready`
test almost nothing. The interesting cases are the corners:

| Pattern | Finds |
|---|---|
| Random `valid` gaps | producer-side stalls handled |
| Random `ready` gaps | backpressure handled |
| `ready` low for a long burst | buffering depth, skid behaviour |
| Both maximal | **throughput** — the property naive designs fail |
| `ready` deasserting mid-burst | rule 2 violations |

[`fifo_tb.sv`](../examples/tb/fifo_tb.sv) uses five backpressure profiles and
reaches both full and empty. [`skid_buffer_tb.sv`](../examples/tb/skid_buffer_tb.sv)
adds the throughput assertion, which is the check that actually matters for a
skid buffer and the one a plain protocol check would pass.

> **A monitor needs its own clocking block with all-input direction, and a
> driver cannot trust a sampled flag** — both are consequences of the scheduling
> regions, and both are demonstrated in `fifo_tb.sv`. See
> [docs/15](15-scheduling-and-race-conditions.md) and
> [docs/16](16-verification-architecture.md).

### Formal

Flow control is unusually well suited to formal, because the properties are
short and the state space is small. The sequence-numbering technique in §3
proves loss, duplication and reordering in one assertion, unboundedly. Three of
this repository's proofs do exactly this: `skid_buffer`, `pipe_ctrl` and
`sync_fifo`.

---

## 10. Checklist

**Protocol**
- [ ] `valid` never depends combinationally on `ready`.
- [ ] `valid` and `data` are stable from assertion until the transfer completes.
- [ ] No transfers during reset, on either side.
- [ ] Every handshake port pair has protocol assertions bound to it.

**Buffering**
- [ ] Any registered handshake uses a skid buffer, not a plain register.
- [ ] Throughput measured, not assumed — a correct-but-50% stage is a common
      and invisible regression.
- [ ] FIFO depth derived from a burst length or a round-trip latency.
- [ ] `almost_full` threshold accounts for every beat already in flight.
- [ ] FIFO flags registered, not combinational from the next pointer.

**Pipelines**
- [ ] One enable for the whole pipeline, not one per stage.
- [ ] Flush takes priority over stall.
- [ ] Every sideband signal delayed by the same amount as the data.

**Arbitration and liveness**
- [ ] Arbiter grants are one-hot, only to requesters, and never idle while
      requests are pending.
- [ ] Fixed priority used only where the priority is a specification.
- [ ] Retry counts bounded; backoff where retriers are symmetric.
- [ ] Request and response paths have separate buffering.
- [ ] `cover` properties for the liveness cases — including the low-priority
      requester eventually winning.

---

## See also

- [docs/21: Pipelining](21-pipelining.md) — latency matching, elastic pipelines
- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — why
  `ready` does not propagate combinationally through a deep pipeline
- [docs/25: Formal with sby](25-formal-verification-with-sby.md) — the sequence
  numbering technique and closing an induction proof
- [docs/28: Clock domain crossing](28-clock-domain-crossing.md) — handshakes and
  FIFOs across clock domains
- [docs/29: Memories](29-memories-and-inference.md) — the storage under a FIFO
- [docs/16: Verification architecture](16-verification-architecture.md) — driver
  and monitor structure for a handshake interface
