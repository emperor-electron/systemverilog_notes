# FSM Coding Styles

A finite state machine is the one block every digital designer writes, and the
one where coding style has consequences that survive all the way to silicon:
where the outputs glitch, how deep the critical path is, what happens after a
single-event upset, and whether the thing can be proved correct at all.

This document covers the four styles worth knowing, when each is the right
answer, and the traps that are specific to FSMs rather than to RTL in general.

The running example in every module below is the same controller — wait for
`start`, request a bus, wait for `grant`, transfer `len` beats, pulse `done` —
so the styles can be compared directly rather than described in the abstract.

Companion code, all verified:
[`fsm_two_process.sv`](../examples/rtl/fsm_two_process.sv) ·
[`fsm_one_process.sv`](../examples/rtl/fsm_one_process.sv) ·
[`fsm_three_process.sv`](../examples/rtl/fsm_three_process.sv) ·
[`fsm_onehot.sv`](../examples/rtl/fsm_onehot.sv) ·
[`fsm_safe.sv`](../examples/rtl/fsm_safe.sv) ·
simulated by [`fsm_tb.sv`](../examples/tb/fsm_tb.sv),
proved in [`formal/fsm_three_process_fv.sby`](../formal/fsm_three_process_fv.sby)
and [`formal/fsm_safe_fv.sby`](../formal/fsm_safe_fv.sby)

---

## Contents

- [1. The state type](#1-the-state-type)
- [2. The four styles](#2-the-four-styles)
- [3. Registering the outputs costs nothing](#3-registering-the-outputs-costs-nothing)
- [4. Moore and Mealy](#4-moore-and-mealy)
- [5. State encoding](#5-state-encoding)
- [6. Illegal states and what to do about them](#6-illegal-states-and-what-to-do-about-them)
- [7. `unique`, `priority`, and the synthesis divergence](#7-unique-priority-and-the-synthesis-divergence)
- [8. Splitting control from datapath](#8-splitting-control-from-datapath)
- [9. Common patterns](#9-common-patterns)
- [10. Verifying an FSM](#10-verifying-an-fsm)
- [11. Checklist](#11-checklist)

---

## 1. The state type

Always a `typedef enum`, never a set of `localparam`s.

```systemverilog
typedef enum logic [2:0] {
  S_IDLE = 3'd0,
  S_REQ  = 3'd1,
  S_XFER = 3'd2,
  S_DONE = 3'd3
} state_e;

state_e state, next;
```

**Size the base type explicitly.** `enum { A, B, C }` defaults to `int` — a
32-bit state register, which synthesis will usually trim but which makes every
waveform and every `$display` wrong-looking, and which changes what `$bits()`
reports. `enum logic [2:0]` says what you mean.

What the enum buys over `localparam`:

| | `localparam` | `typedef enum` |
|---|---|---|
| Waveform display | raw bits | state names, in every viewer |
| Assigning a value not in the list | silent | error (with a cast required) |
| `case` completeness checking | none | tools can warn |
| `.name()` for messages | write your own decoder | built in |

That third row is the one that catches bugs. An `enum`-typed variable can only
be assigned from the same enum type; assigning `3'd5` to it is an error unless
you write `state_e'(3'd5)`. You lose that protection the moment you add the
cast, which is why the cast should make you suspicious.

`.name()` is worth using in every FSM error message:

```systemverilog
$error("unexpected %s with start=%b", state.name(), start);
```

It is a simulation-only method — it disappears under synthesis along with the
`$error`, so it costs nothing.

> **Enum X-propagation.** An enum variable holding X prints as an empty string
> from `.name()` in most simulators rather than `X`. If a state name renders as
> blank in a log, the state is X, not a state you forgot to add to the list.

---

## 2. The four styles

### Style 1 — two-process

Registered state, combinational next-state, combinational outputs.
[`fsm_two_process.sv`](../examples/rtl/fsm_two_process.sv)

```systemverilog
// process 1: the state register, and nothing else
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) state <= S_IDLE;
  else        state <= next;
end

// process 2: the next-state function, pure combinational
always_comb begin
  next = state;                 // DEFAULT: hold. This one line prevents latches.
  unique case (state)
    S_IDLE: if (start)     next = S_REQ;
    S_REQ:  if (grant)     next = S_XFER;
    S_XFER: if (last_beat) next = S_DONE;
    S_DONE:                next = S_IDLE;
    default:               next = S_IDLE;
  endcase
end

// outputs, decoded from the current state
always_comb begin
  bus_req = 1'b0;               // defaults first, every output, every time
  done    = 1'b0;
  unique case (state)
    S_REQ, S_XFER: bus_req = 1'b1;
    S_DONE:        done    = 1'b1;
    default: ;
  endcase
end
```

The `next = state;` default is the whole latch-avoidance trick: after it, every
path through the block assigns `next`, so there is nothing to infer.

**Good for:** reading. Transitions are in one place, outputs in another, and
you can see the whole state graph at a glance.
**Bad for:** timing, if the outputs drive anything far. The output is
combinational logic hanging off the state register, so its arrival time is
state-register clock-to-out *plus* the decode, and it glitches while the decode
settles.

### Style 2 — one-process

Everything registered, inside the single `always_ff`.
[`fsm_one_process.sv`](../examples/rtl/fsm_one_process.sv)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= S_IDLE; bus_req <= 1'b0; done <= 1'b0;
  end else begin
    done <= 1'b0;                          // default: a one-cycle pulse
    unique case (state)
      S_IDLE: if (start) begin state <= S_REQ;  bus_req <= 1'b1; end
      S_REQ:  if (grant)       state <= S_XFER;
      S_XFER: if (last_beat) begin
                state <= S_DONE; bus_req <= 1'b0; done <= 1'b1;
              end
      S_DONE:                  state <= S_IDLE;
      default:                 state <= S_IDLE;
    endcase
  end
end
```

Outputs are flops, so they are glitch-free and fast off the register. They are
also *aligned* with the state rather than a cycle late, because each output is
assigned on the transition into the state it belongs to — `bus_req <= 1'b1`
happens on the same edge as `state <= S_REQ`.

**The cost is that alignment is now your job.** Every output must be set on
every path that enters a state and cleared on every path that leaves it. The
`bus_req <= 1'b0` in the `S_XFER` branch above is not decoration; forget it and
the request stays asserted forever. In a 12-state machine with six outputs that
is 72 opportunities to forget, and nothing warns you.

**Good for:** small machines, and pulse outputs where the "default then
override" idiom reads naturally.
**Bad for:** anything big enough that the output bookkeeping stops fitting in
your head.

### Style 3 — three-process

Registered state, combinational next-state, **registered outputs decoded from
`next`**. [`fsm_three_process.sv`](../examples/rtl/fsm_three_process.sv)

```systemverilog
// processes 1 and 2 exactly as in the two-process style, then:
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    bus_req <= 1'b0;
    done    <= 1'b0;
  end else begin
    bus_req <= (next == S_REQ) || (next == S_XFER);
    done    <= (next == S_DONE);
  end
end
```

This is the default to reach for. You get the two-process style's readable,
centralised output decode *and* the one-process style's glitch-free registered
outputs, with the bookkeeping done by the decode rather than by you.

**Good for:** almost everything, and especially any output that leaves the
module.
**Bad for:** nothing much — it costs one flop per output bit, and it puts the
next-state logic and the output decode in parallel rather than in series, which
usually *helps* timing.

### Style 4 — explicit one-hot

One flop per state, next-state written as an OR of the transitions *into* each
state. [`fsm_onehot.sv`](../examples/rtl/fsm_onehot.sv)

```systemverilog
always_comb begin
  next = state;
  unique case (1'b1)               // note: case on the constant, not on state
    state[0]: if (start)     next = S_REQ;    // S_IDLE
    state[1]: if (grant)     next = S_XFER;   // S_REQ
    state[2]: if (last_beat) next = S_DONE;   // S_XFER
    state[3]:                next = S_IDLE;   // S_DONE
    default:                 next = S_IDLE;
  endcase
end
```

`unique case (1'b1)` over a one-hot vector synthesises to a parallel mux rather
than a priority chain, and reads as "whichever of these is true".

The alternative spelling, used in [`fsm_safe.sv`](../examples/rtl/fsm_safe.sv),
writes each next-state bit as a boolean equation:

```systemverilog
next[I_IDLE] = (state[I_IDLE] & ~start) |  state[I_DONE];
next[I_REQ]  = (state[I_IDLE] &  start) | (state[I_REQ] & ~grant);
```

Every next-state bit is a two- or three-term function of one or two state bits,
**no matter how many states there are**. That is the property that makes one-hot
close timing on wide FSMs: a binary-encoded 30-state machine needs a full 5-to-30
decode in front of every transition term, while a one-hot one never needs a
decode at all. The price is 30 flops instead of 5.

### Picking one

| | two-process | one-process | three-process | one-hot |
|---|---|---|---|---|
| Output timing | combinational off state | registered, aligned | registered, aligned | either |
| Output glitches | yes | no | no | depends |
| Output bookkeeping | automatic (decode) | manual, per path | automatic (decode) | automatic |
| Extra latency | none | none | none | none |
| Flops | ⌈log₂N⌉ | ⌈log₂N⌉ + outputs | ⌈log₂N⌉ + outputs | N + outputs |
| Best for | small, internal | small, pulse-heavy | **default** | wide FSMs, FPGA |

---

## 3. Registering the outputs costs nothing

The standard objection to registering FSM outputs is that it adds a cycle of
latency. That is true of the naive version, and only of the naive version:

```systemverilog
always_ff @(posedge clk) bus_req <= (state == S_REQ);   // ONE CYCLE LATE
always_ff @(posedge clk) bus_req <= (next  == S_REQ);   // ALIGNED
```

Because `state <= next` happens on the same edge, decoding `next` puts
`bus_req` and `state` in the same cycle. The register absorbs the cycle that the
decode would otherwise have added.

This is worth proving rather than asserting, and it is:
[`formal/fsm_three_process_fv.sby`](../formal/fsm_three_process_fv.sby) drives
`fsm_two_process` and `fsm_three_process` from identical stimulus and checks
their outputs are equal **in the same cycle**, for 30 cycles of arbitrary
stalling. [`fsm_tb.sv`](../examples/tb/fsm_tb.sv) does the same in simulation
across all three styles and compares 64 cycles.

Inside the module the alignment is stated as an inductive invariant, which
`prove` closes unboundedly:

```systemverilog
`ifdef FORMAL
  always @* begin
    f_req_aligned  : assert (bus_req == ((state == S_REQ) || (state == S_XFER)));
    f_done_aligned : assert (done    ==  (state == S_DONE));
  end
`endif
```

It is inductive in one step and needs no helper invariants: `bus_req(t+1)` is
decoded from `next(t)`, and `state(t+1)` *is* `next(t)`, so the two land
together by construction.

> **Why that proof is `bmc` and the invariant is `prove`.** The cross-module
> equivalence cannot be proved by induction here, because induction starts from
> an arbitrary state in which the two DUTs' internal `state` and `cnt`
> registers hold unrelated values. Closing it needs the invariant
> `a.state == b.state`, and stating that needs hierarchical references into
> both instances — which the Yosys frontend silently mis-resolves
> ([docs/25](25-formal-verification-with-sby.md)). So the equivalence is
> bounded and the per-module alignment claim is unbounded. Between them they
> cover the statement.

---

## 4. Moore and Mealy

**Moore**: outputs are a function of state alone.
**Mealy**: outputs are a function of state *and the current inputs*.

```systemverilog
// Moore  -- changes only when the state changes
assign done = (state == S_DONE);

// Mealy  -- changes the instant `beat_ack` does
assign ack_now = (state == S_XFER) && beat_ack;
```

Mealy saves a cycle of latency, which is why handshake logic is full of it: a
`ready` that waits for the state to change is a `ready` that costs a cycle per
transfer. It also puts an input pin straight through combinational logic onto an
output pin, so the path is input-to-output with no register in it, and the
output glitches whenever the input does.

**The registered-Mealy compromise** gets the decision made early and the output
clean, by folding the input into the next-state logic instead:

```systemverilog
always_ff @(posedge clk) ack_q <= (next == S_XFER) && beat_ack_next;
```

Rules of thumb:

- Crossing a module boundary → Moore, registered. Always.
- Inside one module, one level of logic away → Mealy is fine and often correct.
- A Mealy output feeding another FSM's input → you have built a combinational
  path between two state machines. It will work and it will be the first thing
  to fail timing.
- **Never** let a Mealy output feed back into its own FSM's next-state logic
  through external combinational logic. That is a combinational loop with extra
  steps.

---

## 5. State encoding

| Encoding | Bits for N states | Next-state depth | Output decode | Where |
|---|---|---|---|---|
| Binary | ⌈log₂N⌉ | deep (full decode) | deep | ASIC, area-critical |
| Gray | ⌈log₂N⌉ | deep | deep | one-bit-at-a-time transitions, CDC |
| One-hot | N | shallow, constant | trivial (one bit) | FPGA, wide FSMs |
| Johnson | N/2 | shallow | 2 bits | counters, low-power |

**On an FPGA, one-hot is usually free.** Flops come in the same slices as the
LUTs you would otherwise spend on decode, so trading 5 flops for 30 costs
nothing you were using. Both Vivado and Quartus default to one-hot for FSMs they
infer, above a size threshold.

**On an ASIC, flops cost area and leakage**, and binary usually wins below a few
dozen states.

You can ask the tool rather than hand-code it:

```systemverilog
(* fsm_encoding = "one_hot" *) state_e state;   // Vivado
```

with `"binary"`, `"gray"`, `"sequential"`, `"johnson"`, `"auto"` and `"none"`
also accepted. This only works when the tool **recognises** the FSM — a state
register buried in a `struct`, written from two processes, or carrying a
non-state field alongside, often is not recognised, and the attribute is then
silently ignored. Check the synthesis report for the FSM extraction table rather
than assuming.

> **Gray-coded states are not a CDC solution.** Gray coding guarantees one bit
> changes per *legal transition*; it says nothing about a state vector sampled
> asynchronously, which can be caught mid-transition and land anywhere. If
> another clock domain needs to know the state, synchronise a handshake or an
> explicitly Gray-coded *counter* ([docs/23](23-structural-design-techniques.md)),
> not the FSM's state register.

---

## 6. Illegal states and what to do about them

A 4-state one-hot FSM has 16 encodings, of which 4 are legal. Those other 12 are
not hypothetical: they are reachable by a single-event upset, a marginal reset, a
setup violation on one bit of the state vector, or a metastable capture on an
input feeding the next-state logic.

What the design does in those encodings is either a decision you make or a
decision the synthesiser makes for you.

### The default branch

Every `case` on a state gets a `default`, and it goes to a recovery state:

```systemverilog
default: next = S_IDLE;
```

Without it, the encodings you did not list are don't-cares, and the synthesiser
is entitled to build whatever is cheapest — which can and does include an
absorbing state.

**The default branch alone is not enough for a hand-written one-hot machine.**
The OR-of-transitions form has no `case` to attach a default to, and all-zeros is
naturally absorbing: no transition term is true, so `next` is all-zeros again,
forever. See [`fsm_safe.sv`](../examples/rtl/fsm_safe.sv):

```systemverilog
next[I_IDLE] = (state[I_IDLE] & ~start) | state[I_DONE];
next[I_REQ]  = (state[I_IDLE] &  start) | (state[I_REQ] & ~grant);
// ... and then, LAST:
if (SAFE && !$onehot(state)) next = (NS'(1) << I_IDLE);
```

The recovery term must **overwrite**, not OR in. ORing `S_IDLE` into an illegal
state produces a state that is still illegal — two bits set — rather than
recovering from it.

### Proving recovery

This is the case formal is unreasonably good at and simulation is bad at. None
of the 12 illegal encodings is reachable from reset, so no amount of
constrained-random stimulus will ever visit one; a testbench can only get there
by forcing the state register, which means hand-picking which to try.

[`formal/fsm_safe_fv.sby`](../formal/fsm_safe_fv.sby) covers all 12 at once —
but getting it to do so took two corrections worth recording, because both
failure modes are silent.

**Trap 1: the property was vacuous.** The obvious harness asserts both of these
in the same proof:

```systemverilog
f_legal_reachable : assert (!state_err);                        // (1)
f_recovers_in_one : assert (!($past(state_err) && state_err));  // (2)
```

and proves nothing. Induction **assumes** every asserted property in the
preceding steps, so (1) at step *t−1* hands (2) the assumption
`!$past(state_err)`, and (2) becomes vacuously true.

**Trap 2: induction was the wrong mode.** Splitting (2) into its own task still
was not enough. Induction assumes (2) itself at earlier steps, and since a legal
state never *leads* to an illegal one, the solver cannot construct a trace that
enters one — the illegal encodings stay unreachable inside the proof.

What works is **BMC with a free initial state**:

```
recover: mode bmc
recover: depth 3
```

```systemverilog
always @* assume (rst_n);                    // reset must not do the recovering
always @(posedge clk)
  if (past_ok) f_recovers_in_one : assert (!state_err);
```

BMC proves every step rather than assuming earlier ones, and a state register
with no initialiser is left **free at step 0** — so `state` there ranges over all
16 encodings, the 12 illegal ones included. Reset is assumed inactive so that
recovery has to be the next-state logic's own doing.

Both traps were caught by the same thing: **a negative control.** Rebuilding the
harness against `.SAFE(1'b0)` must make the proof fail. The first two versions
passed with the recovery term removed, which is how they were found to be
proving nothing. The final version fails as it should:

```
failed assertion fsm_safe_fv.f_recovers_in_one at fsm_safe_fv.sv:69 step 2
```

> **Run the negative control on every safety property.** A proof that passes
> against a design you have deliberately broken is not a proof.

### Where the reachability assertion belongs

Note what [`fsm_safe.sv`](../examples/rtl/fsm_safe.sv) does *not* assert:

```systemverilog
// NOT in the module:
a_onehot: assert property (@(posedge clk) $onehot(state));
```

It is true of every reachable state, but this is the one module whose job is to
behave well where it is false. Asserting it inside would fire on every fault
injection and on every formal step starting from an arbitrary state — punishing
the design for the tolerance it was built to have. The reachability claim belongs
to the caller, so it lives in the formal harness and the testbench;
`ring_counter.sv` is split for the same reason. What stays in the module is its
actual contract: *however* it got into an illegal encoding, it leaves on the next
edge.

### Vendor safe-FSM attributes

```systemverilog
(* fsm_safe_state = "reset_state" *) state_e state;
```

Vivado accepts `"reset_state"`, `"power_on_state"`, `"default_state"` and
`"auto_safe_state"`. It is worth setting — and it is not a substitute for RTL
you can prove, because it applies only when the tool actually infers an FSM, and
it is silently ignored by every other toolchain.

---

## 7. `unique`, `priority`, and the synthesis divergence

```systemverilog
unique case (state)     // claim: exactly one branch matches
priority case (state)   // claim: at least one matches; first wins
unique0 case (state)    // claim: at most one matches
case (state)            // no claim
```

These are **assertions, not directives.** `unique` tells the simulator to report
an error at run time if zero or two branches match, and tells synthesis it may
assume that never happens.

That asymmetry is where the trouble is. Consider:

```systemverilog
unique case (state)
  S_IDLE: next = S_REQ;
  S_REQ:  next = S_XFER;
endcase                        // no default, and S_XFER/S_DONE unlisted
```

- **Simulation**: reaching `S_XFER` reports a `unique` violation and `next`
  keeps its old value, which infers a latch or holds a stale state.
- **Synthesis**: told that case is impossible, builds logic that does something
  arbitrary there.

The two need not agree, and the failure appears only in the state you claimed
was unreachable. **`unique` plus a `default` is the combination to use** — the
`default` makes the behaviour defined for the tools, and the `unique` still
catches the overlapping-branch bug it is good at.

> Never use `full_case` or `parallel_case`. They are the old Verilog pragmas
> that make this divergence *permanent* by telling synthesis to ignore cases
> without telling simulation anything at all. `unique`/`priority` replaced them
> precisely because they are checked at run time.

On `casex` and `casez` in FSMs: `casex` treats X in the *case expression* as a
wildcard, so an X state matches the first branch and the FSM sails on as if
nothing happened. That is X-optimism at its worst
([docs/24](24-dft-clocking-and-x-discipline.md)). Use `casez` if you need
wildcards, and prefer `inside` or explicit masks where you can.

---

## 8. Splitting control from datapath

The most common way an FSM becomes unmaintainable is absorbing the datapath
into itself — a state per beat, a state per byte, a state per retry.

The fix is a counter beside the FSM and a flag into it:

```systemverilog
logic [CW-1:0] cnt;
logic          last;

assign last = (cnt <= CW'(1));       // one comparator, not one state per beat

// in the FSM:
S_XFER: if (beat_ack) begin
          cnt_d = cnt - 1'b1;
          if (last) next = S_DONE;
        end
```

A 256-beat transfer is now four states and an 8-bit counter instead of 259
states. The FSM describes the *protocol*; the counter counts.

Note `last` is computed from `cnt`, not from `cnt_d`. Deciding on the
pre-decrement value keeps the comparator off the next-state critical path — it
is a register output, available at the start of the cycle, rather than the
output of the subtractor.

When the sequencing gets long and regular rather than branchy, the next step
after a counter is a table: see
[docs/23 §8](23-structural-design-techniques.md#8-table-driven-and-microcoded-control)
and [`useq.sv`](../examples/rtl/useq.sv).

---

## 9. Common patterns

### One-cycle pulse output

```systemverilog
always_ff @(posedge clk) begin
  done <= 1'b0;                       // default, overridden below
  if (state == S_XFER && last_beat) done <= 1'b1;
end
```

The default-then-override idiom is what makes it exactly one cycle. Assert it in
the module so it stays that way: `a_done_pulse: assert property (done |=> !done);`

### Waiting for a handshake

```systemverilog
S_REQ: if (grant) next = S_XFER;      // hold in S_REQ until granted
```

The default `next = state` is doing the waiting. **Wait in one place.** The most
common FSM bug this document can warn about is a state that both waits for a
condition and falls through on another path — [`useq.sv`](../examples/rtl/useq.sv)
originally branched on its wait conditions being *true* rather than false, so
every wait state fell through and the whole protocol ran in six cycles. Every
data check still passed; only the state trace showed it.

### Timeout

```systemverilog
logic [TW-1:0] tmo;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)                  tmo <= '0;
  else if (state != next)      tmo <= '0;       // restart on every transition
  else if (!(&tmo))            tmo <= tmo + 1'b1;
end

// in the FSM:
S_REQ: if (grant)     next = S_XFER;
       else if (&tmo) next = S_ERROR;
```

Saturating rather than wrapping matters: a wrapping counter re-arms and fires
again, so an FSM stuck with a stuck timeout oscillates instead of stopping.

### Retry with a limit

```systemverilog
S_ERROR: if (retries == MAX_RETRY) next = S_FAIL;
         else                      next = S_REQ;   // retries incremented on entry
```

Always bound the retry count. An unbounded retry loop is a livelock that passes
every functional test, because the test provides a working target.

### Reset state

The reset state must be reachable from every state, and every state must be
reachable from reset. The first is what recovery means; the second is what
`cover` checks.

Use **asynchronous assert, synchronous deassert** for the FSM's reset — see
[`reset_sync.sv`](../examples/rtl/reset_sync.sv) and
[docs/24](24-dft-clocking-and-x-discipline.md). An FSM that comes out of reset
one cycle apart from its datapath is a class of bug that only appears on silicon.

---

## 10. Verifying an FSM

Four properties cover most of what an FSM can get wrong.

```systemverilog
// 1. The state is always legal.
a_legal: assert property (@(posedge clk) disable iff (!rst_n)
  state inside {S_IDLE, S_REQ, S_XFER, S_DONE});

// 2. It always makes progress -- no state is a black hole.
a_no_hang: assert property (@(posedge clk) disable iff (!rst_n)
  (state == S_DONE) |=> (state == S_IDLE));

// 3. Outputs agree with the state they describe.
a_aligned: assert property (@(posedge clk) disable iff (!rst_n)
  bus_req == ((state == S_REQ) || (state == S_XFER)));

// 4. Every state is actually reachable -- a cover, not an assert.
c_run: cover property (@(posedge clk) disable iff (!rst_n)
  (state == S_IDLE) ##1 (state == S_REQ) [*1:$]
  ##1 (state == S_XFER) [*1:$] ##1 (state == S_DONE));
```

Number 4 is the one people skip and the one that finds dead states. An assertion
that never fires because its state is unreachable is worse than no assertion —
it reports green. Cover every state and every transition you believe in; a
`cover` that cannot be reached is a bug in the design or in your understanding
of it, and either is worth knowing.

### The two dialects

Yosys supports **no part of SVA's temporal layer** — no clocking event on
`assert property`, no `|->`, no `|=>`, no sequences. Formally verified modules in
this repository therefore carry properties twice: idiomatic SVA under
`` `ifndef SYNTHESIS `` for XSIM, and immediate assertions under `` `ifdef FORMAL ``
for Yosys, with `-DSYNTHESIS` passed by sby.
See [docs/25](25-formal-verification-with-sby.md).

### Fault injection in simulation

`force`/`release` is how you get a testbench into an illegal state, and it has
a timing artefact worth knowing:

```systemverilog
$assertoff(0, u_safe1);          // suspend the design's own assertions
force u_safe1.state = 4'b0000;
@(negedge clk);
release u_safe1.state;
@(negedge clk);
chk("recovered", !s1_err);
$asserton(0, u_safe1);
```

`force` holds the register against its own `always_ff`, so the injected encoding
is **still the sampled value at the following clock edge** — the design cannot
update a register it is not allowed to drive. An in-module "recovers in one
cycle" property therefore looks violated by an artefact of the injection rather
than by the design, which is why the design's assertions are suspended across
the window and recovery is checked from a port instead.

### Two testbench traps this repository walked into

**Driving stimulus on the same edge the FSM samples.** All three style modules
appeared to disagree by a cycle until the stimulus moved to `negedge`. That was
a race in the testbench, not a difference between the designs — it is the first
thing to suspect when two implementations of one FSM "differ by one cycle".

**Leaving a DUT's inputs undriven until its own test runs.** `fsm_safe` and
`fsm_onehot` are instantiated for the whole simulation. With their inputs left
at X until their tests began, X propagated into their state registers during the
*earlier* tests and quietly failed their one-hot assertions. Drive every DUT
input from time 0, even ones the current test does not care about.

> That second one also exposed a gap in the build: a concurrent assertion that
> fails calls `$error`, which XSIM reports and then carries on from, so a
> testbench whose own checks all pass still prints `PASS` with failing
> assertions scrolling past above it. The Makefile now fails a simulation that
> prints `PASS` while any SVA assertion failed. Grepping for the PASS line alone
> hides exactly the failures the assertions were written to catch.

---

## 11. Checklist

**Structure**
- [ ] State is a `typedef enum` with an explicitly sized base type.
- [ ] `next = state;` (or a full set of defaults) at the top of every
      combinational block.
- [ ] Every `case` on the state has a `default`, and it recovers.
- [ ] `unique` is paired with a `default`, never with `full_case`.
- [ ] Counters and datapath live outside the FSM; the FSM has states for the
      protocol, not for the data.

**Outputs**
- [ ] Outputs that leave the module are registered.
- [ ] Registered outputs are decoded from `next`, not `state` — otherwise they
      are a cycle late.
- [ ] Every output is assigned on every path (one-process style) or has a
      default (everything else).
- [ ] Pulse outputs are asserted to be one cycle wide.

**Robustness**
- [ ] Illegal encodings recover, and it is proved, with a negative control.
- [ ] No Mealy output crosses a module boundary.
- [ ] Reset is async-assert / sync-deassert, and the reset state is reachable
      from everywhere.
- [ ] Timeouts saturate rather than wrap; retries are bounded.

**Verification**
- [ ] Legality, progress and output alignment are asserted.
- [ ] Every state and every transition has a `cover`.
- [ ] The build fails on a failing assertion, not just on a missing PASS.

---

## See also

- [docs/05: Procedural blocks](05-procedural-blocks-and-flow.md) — the shorter
  FSM section this one expands, plus the `case` variants in full
- [docs/12: Assertions](12-assertions-sva.md) — the SVA used above
- [docs/20: Synthesis subset](20-synthesis-subset-and-gotchas.md) — latch
  inference, and what the linters here do and do not catch
- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — registering
  outputs, late-arriving signals, fanout on state bits
- [docs/23: Structural techniques](23-structural-design-techniques.md) — when an
  FSM should be a table instead
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) — scan,
  reset discipline, X-optimism
- [docs/25: Formal with sby](25-formal-verification-with-sby.md) — the proof
  setup, induction, and the hierarchical-reference trap
