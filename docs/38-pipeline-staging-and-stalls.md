# Pipeline Staging and Stall Control

Two questions, and they are independent:

1. **How do I cut a long operation into stages?** Which cuts, how many, and how do
   I know whether they helped.
2. **How do I stop a pipeline?** A stall is not one technique but a family of
   them, with an order-of-magnitude spread in area, timing and complexity.

[docs/21](21-pipelining.md) is the general treatment of pipelining: what it buys,
latency matching, retiming, hazards, loops. This document is narrower and more
concrete. It takes one arithmetic expression, cuts it up, and then drives the
result from every stall scheme in turn — measuring each one rather than
describing it.

Companion code, all verified:
[`dot_rs_dp.sv`](../examples/rtl/dot_rs_dp.sv) ·
[`dot_rs_global.sv`](../examples/rtl/dot_rs_global.sv) ·
[`dot_rs_elastic.sv`](../examples/rtl/dot_rs_elastic.sv) ·
[`pipe_ctrl.sv`](../examples/rtl/pipe_ctrl.sv) ·
[`pipe_ripple_ctrl.sv`](../examples/rtl/pipe_ripple_ctrl.sv) ·
[`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv) ·
[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) ·
[`skew_buffer.sv`](../examples/rtl/skew_buffer.sv) ·
[`pipe_pkg.sv`](../examples/rtl/pipe_pkg.sv) ·
measured by [`pipeline_stall_tb.sv`](../examples/tb/pipeline_stall_tb.sv),
proved in [`dot_rs_fv.sby`](../formal/dot_rs_fv.sby),
[`axis_reg_slice_fv.sby`](../formal/axis_reg_slice_fv.sby) and
[`pipe_ripple_ctrl_fv.sby`](../formal/pipe_ripple_ctrl_fv.sby)

---

## Contents

- [1. The two problems, kept apart](#1-the-two-problems-kept-apart)
- [2. Staging: where the cuts go](#2-staging-where-the-cuts-go)
- [3. Measuring a cut set](#3-measuring-a-cut-set)
- [4. One description, any cut set](#4-one-description-any-cut-set)
- [5. The stall taxonomy](#5-the-stall-taxonomy)
- [6. Global stall](#6-global-stall)
- [7. Ripple back-pressure](#7-ripple-back-pressure)
- [8. Register slices: the five ways to cut a handshake](#8-register-slices-the-five-ways-to-cut-a-handshake)
- [9. Never stalling at all](#9-never-stalling-at-all)
- [10. Flush versus drain](#10-flush-versus-drain)
- [11. Reconvergence and the skew buffer](#11-reconvergence-and-the-skew-buffer)
- [12. Verifying a pipeline that stalls](#12-verifying-a-pipeline-that-stalls)
- [13. Checklist](#13-checklist)

---

## 1. The two problems, kept apart

The single most useful structural decision in this whole area is to **write the
datapath with per-stage enables and put the flow control somewhere else.**

```systemverilog
// dot_rs_dp.sv -- the datapath. No valid, no ready, no flush, no `en`.
if (CUTS[1]) begin : g_cut2
  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n)                   sum_q <= '0;
    else if (adv[pipe_pkg::cuts_below(CUTS, 1)]) sum_q <= sum_d;
  end
end
```

Everything in this document then drives that same file:

```systemverilog
// dot_rs_global.sv                       // dot_rs_elastic.sv
pipe_ctrl        #(...) u_ctrl (...);     pipe_ripple_ctrl #(...) u_ctrl (...);
dot_rs_dp #(...) u_dp (.adv({4{en}}));    dot_rs_dp #(...) u_dp (.adv(adv_ctrl));
```

Which makes a point worth stating plainly: **a global stall is the degenerate case
of elastic control** — the case where all the per-stage enables happen to be the
same wire. They are not different kinds of design, they are different values of
`adv`.

The cost of *not* doing this is that `if (en)` gets written into two hundred lines
of datapath, and the day the block needs a valid/ready interface is the day
someone edits two hundred lines of arithmetic. The datapath here is unchanged
between the two wrappers, and the proof that they compute the same thing is
[`dot_rs_fv.sby`](../formal/dot_rs_fv.sby).

---

## 2. Staging: where the cuts go

The operation, as one expression:

```
y = clamp( round( SUM over i of  c[i] * x[i] ) )
```

Four operators of very different cost: `TAPS` multiplies, an adder tree, a
rounding add plus a shift, and a two-sided clamp. The candidate cuts:

```
        x, c                 cut 0            cut 1           cut 2        cut 3
          |                    |                |               |            |
    [ multiply ] -- p --> [ adder tree ] -> [ round ] --> [ clamp ] --> y
                                              + shift
```

### The rules that actually decide it

**Cut across a cut SET, not a path.** A stage boundary must cross every path from
the inputs to the outputs exactly once. Register two of three parallel terms and
the third arrives a cycle early — which in this datapath would mean products from
two different input samples being added together. The tell is a cut that "only
needs a register on one side"; that is not a cut.

**A register at the end cuts nothing.** Cut 3 registers the clamp's *output*,
which shortens nothing: the path from `x` through the multiply, the tree, the
round and the clamp is still one lump of logic feeding that register. Measured
below: cut 3 on its own leaves the longest path exactly where it was and adds a
cycle of latency for no benefit. The same is true of the first register on the
input side. **Registers help where they split logic, not where they terminate
it.**

**The worst stage sets the clock.** A five-stage pipeline with one 3 ns stage and
four 1 ns stages runs at 3 ns. So the question is never "how many stages" but
"what is the longest surviving fragment", which is why this is a measurement and
not a discussion.

**Cut after the expensive operator, not inside it** — unless you have to. A
multiply, a barrel shift, a leading-zero count and a wide comparator are each one
lump you can register around cheaply. Registering *inside* one of them means
knowing its internal structure, and it is usually the wrong move: DSP blocks and
carry chains already have pipeline registers designed into them, and retiming
([docs/21](21-pipelining.md) section 6) redistributes better than a human does.

**A stage that looks too small may still be worth having.** Cut 2, the rounding
add and the shift, is a rounding error next to the multiply. It is a stage
because of what it is *next to*: fusing it into the tree adds a carry-propagate
add after the tree, and fusing it into the clamp puts that add in front of the
comparators. Either fusion makes one stage clearly the worst.

---

## 3. Measuring a cut set

**Do not guess, and do not trust the argument above either.** Every claim in
section 2 is checkable in about a second per data point. This is the whole method:

```bash
yosys -p "read_verilog -sv -DSYNTHESIS examples/rtl/pipe_pkg.sv examples/rtl/dot_rs_dp.sv; \
          chparam -set CUTS 4'b0011 dot_rs_dp; hierarchy -top dot_rs_dp; \
          proc; opt -fast; techmap; opt -fast; ltp -noff"
```

`ltp -noff` reports the **longest topological path that does not pass through a
flop** — in other words the longest surviving combinational fragment, in gates.
`techmap` decomposes the adders and multipliers into a fixed gate structure
first, so the numbers are comparable between runs.

One trap in that command line: `ltp` only looks *within a module*, so a design
with submodules needs a `flatten` before it or the answer comes back
misleadingly short. `dot_rs_dp` has no instances in it, which is why there is no
`flatten` above; the register-slice measurements further down do include one.

For `dot_rs_dp` at `TAPS=4, XW=8, CW=10, CF=8, YW=8`:

| `CUTS` | cuts enabled | latency | longest path (gates) |
|---|---|---|---|
| `0000` | none | 0 | **68** |
| `1000` | clamp only | 1 | **68** |
| `1010` | tree + clamp | 2 | 44 |
| `0001` | products | 1 | 49 |
| `0101` | products + round | 2 | 32 |
| `0011` | products + tree | 2 | **26** |
| `0111` | products + tree + round | 3 | 25 |
| `1111` | all four | 4 | 25 |

Read it line by line, because every row is one of the rules above:

- `1000` **is the register-at-the-end case**: a full cycle of latency bought
  exactly nothing. 68 gates before, 68 after.
- `1010` shows that cutting the tree without cutting the products leaves the
  multiply and the tree fused — 44, most of the original path.
- `0011` is the interesting row: **two cuts get 2.6× and latency 2.**
- `0111` and `1111` get 25. The third and fourth cuts bought one gate of depth
  between them, for two more cycles of latency and two more rows of registers.
  **Diminishing returns are not gradual here; they fall off a cliff after the
  second cut.**
- And 25 is a floor, not a coincidence: it is the multiply. To go below it you
  must cut *inside* the multiplier or let a hard macro do it.

### What the numbers are not

They are topological gate counts after a technology-independent decomposition,
not delays. A real flow weights each gate by its library delay and adds
interconnect, which is where a wide mux can beat a multiplier
([docs/22](22-timing-closure-and-optimization.md)). Use them for *relative*
comparisons of cut sets on the same design — which is exactly the question "did
this cut help" — and read a real timing report before believing an absolute
number.

One methodological note worth having, because it would otherwise look like sloppy
measurement. Running the same sweep with ABC's mapper (`abc -g simple`) gives a
**non-monotone** table: 47, 47, 47, 34, 35, 38, 38, 38 for the same rows. ABC
remaps each combinational cone independently, so changing the cone boundaries
changes the mapping, and differences of a few gates are the mapper's variance
rather than the design's. The `techmap`-only numbers are structural and
comparable; that is why they are the ones tabulated.

---

## 4. One description, any cut set

The sweep above is only cheap because the cut set is a **parameter**, not a
rewrite:

```systemverilog
// bit k of CUTS makes cut k a register; a zero leaves it a wire
parameter logic [3:0] CUTS = 4'b1111

if (CUTS[0]) begin : g_cut1
  always_ff @(posedge clk or negedge rst_n) ... p_q[i] <= p_d[i];
end else begin : g_wire1
  always_comb p_q[i] = p_d[i];
end
```

Three things this buys, beyond the sweep:

**The arithmetic exists once.** `CUTS=4'b0000` *is* the combinational reference
that the pipeline is proved against, so the reference cannot drift from the
design. A separately written reference model agrees with the design whenever it
shares the design's misunderstanding; this one cannot, because it is the same
source text. (What it therefore cannot catch is an arithmetic mistake — that is
what the `longint` model in the testbench is for. See
[section 12](#12-verifying-a-pipeline-that-stalls).)

**The latency is derived, once.** Latency is the number of enabled cuts, and both
the datapath and its control need to know it:

```systemverilog
// pipe_pkg.sv -- one definition, used by the datapath and by both wrappers
function automatic int unsigned cuts_below(input logic [3:0] m, input int unsigned k);
  ...
localparam int unsigned LATENCY = pipe_pkg::cuts_below(CUTS, 4);
```

Two copies of that arithmetic is two chances to disagree, and the failure mode —
a pipeline whose valid bits are a different depth from its data — presents as
data corruption rather than as a parameter mistake. It is the same discipline as
the single layout rule in [docs/37](37-parameterized-video-pipelines.md).

**It is the shape retiming likes.** Operators sit between clean boundaries that
the tool can move, so `retiming` has somewhere to put the registers it wants
([docs/21](21-pipelining.md) section 6).

### What staging costs

| Cost | Scale |
|---|---|
| Registers | one row per cut, per bit — and the *widest* point of the datapath is often mid-pipeline, not at the ports (here the post-product width is 19 bits per tap and the accumulator 22, against 8-bit inputs and an 8-bit output) |
| Latency | one cycle per cut, and every sideband signal must be delayed to match ([docs/21](21-pipelining.md) section 3) |
| Power | more flops clocking every cycle; gate them or accept it ([docs/35](35-low-power-architecture.md)) |
| Verification | the state space grows: a stall can now land in any of `LATENCY` places, which is why [section 12](#12-verifying-a-pipeline-that-stalls) exists |
| Flush | more in-flight work to kill, and more places for a flush to be half-applied |

---
## 5. The stall taxonomy

Five schemes, and the decision is usually made in the first two rows of this
table:

| Scheme | Storage added | Ready-path depth | Fanout of the stall | Bubbles collapse | Rate | Where it belongs |
|---|---|---|---|---|---|---|
| **Global stall** | none | n/a — there is no `ready`, only an input | every register | no | 100% | one block you own end to end |
| **Ripple back-pressure** | none | `O(N)` | 1 per net | yes | 100% | short elastic pipelines |
| **Slices every K stages** | 1–2 slots per slice | `O(K)` | 1 per net | yes | 100% | long pipelines, chip crossings |
| **Half-rate slice** | 1 slot | 1 | 1 per net | yes | **50%** | timing is gone and bandwidth is spare |
| **Never stall** | none | — | — | n/a | 100% | fixed-rate DSP, video, anything with a hard real-time sink |

The three middle rows are all "elastic"; what separates them is where the ready
path's delay goes. And the last row is not a joke — a pipeline that is *not
allowed* to stall is simpler than every other row here, and a great deal of video
and radio hardware is built that way on purpose
([section 9](#9-never-stalling-at-all)).

---

## 6. Global stall

One enable, broadcast. [`dot_rs_global.sv`](../examples/rtl/dot_rs_global.sv) is
the whole thing:

```systemverilog
pipe_ctrl #(.STAGES(LATENCY)) u_ctrl (
  .clk, .rst_n, .en(en), .flush(flush),
  .valid_i(valid_i), .valid_o(valid_o), .valid_q(), .busy(busy));

dot_rs_dp #(...) u_dp (.clk, .rst_n, .adv({4{en}}), .x, .c, .y);
```

**The rule that makes it correct: freeze everything or nothing.** Freezing stages
independently — "stage 3 is busy, so hold stage 3" — either duplicates beats
(stage 4 re-samples a value stage 3 is holding) or drops them (stage 2 advances
into a frozen stage 3). Both are silent. If per-stage enables are what you want,
you want [section 7](#7-ripple-back-pressure), where they are computed by
something that has been proved.

The property, and it is inductive, so it is *proved* rather than sampled:

```systemverilog
// dot_rs_global.sv, `ifdef FORMAL
if (rst_n && fv_past && $past(rst_n) && !$past(flush) && !$past(en)) begin
  f_stall_holds_y : assert (y == $past(y));
  f_stall_holds_v : assert (valid_o == $past(valid_o));
end
```

### What it costs, measured

The stall path itself has no logic in it — `en` goes straight to the register
enables — so its cost is **fanout**, not depth. Measured depth of the control
block alone, with `ltp -noff`:

| `STAGES` | `pipe_ctrl` | `pipe_ripple_ctrl` |
|---|---|---|
| 1 | 2 | 4 |
| 2 | 2 | 5 |
| 4 | 2 | 7 |
| 8 | 3 | 11 |
| 16 | 4 | 19 |
| 32 | 5 | 35 |

`pipe_ctrl`'s growth is not the stall path at all — it is the `busy = |valid_q`
OR-reduction, which is `O(log N)`. The stall path is flat and the thing that
grows instead is the load on one net: at 32 stages of a 64-bit datapath that is
about two thousand register enables on one wire. Synthesis will replicate the
driver, the replication tree costs delay, and the delay appears in a place nobody
cut. **A global stall does not remove the cost of stalling; it moves it from logic
depth into physical design.**

The other two costs are behavioural:

- **Bubbles do not collapse.** A gap in the input stays a gap for the life of the
  beat, because a frozen pipeline freezes its gaps too. If the input is bursty and
  the consumer is rate-limited, this is throughput you have thrown away.
- **There is no backpressure signal.** `en` is an input, so somebody upstream has
  to know when the consumer cannot take data. If that knowledge arrives as a wire
  from three modules away, that wire is the design's real timing problem, and it
  is now a *control* wire with a setup path through everything.

What it buys is worth the price surprisingly often: exact latency, no extra flops,
no protocol, and a datapath that retimes freely.

---

## 7. Ripple back-pressure

Each stage advances if the stage ahead of it can take what it holds.
[`pipe_ripple_ctrl.sv`](../examples/rtl/pipe_ripple_ctrl.sv):

```systemverilog
always_comb begin
  can_take[STAGES-1] = !valid_q[STAGES-1] || m_ready;
  for (int i = int'(STAGES) - 2; i >= 0; i--)
    can_take[i] = !valid_q[i] || can_take[i+1];
end

assign adv     = can_take;
assign s_ready = can_take[0];
```

That is an `N`-input OR chain rooted at `m_ready`, and the measurement above shows
it exactly: depth `N + 3` gates, growing one gate per stage. At four stages it is
free. At thirty-two it is the critical path, and the pipeline that was supposed to
make the design faster is now limited by the logic that stops it.

**Two properties make this scheme work, and both are non-obvious enough to be
worth proving:**

```systemverilog
// pipe_ripple_ctrl.sv, `ifdef FORMAL
assert ((f_n_in - f_n_out) == f_occupancy);                       // exact
for (fi = 1; fi < int'(STAGES); fi = fi + 1)
  assert (!valid_q[fi-1] || valid_q[fi] || can_take[fi]);         // packing
```

The first is beat accounting: everything accepted is either in a stage or has
left. Note that it is an **equality, not a bound** — `(in - out) <= STAGES` is
true and useless, because induction can start from a state where the counters are
already apart with nothing in flight and then break the bound in one step. Saying
exactly *where* every beat is, is state-local, so induction carries it. (The same
lesson, arrived at the same way, is in
[docs/37](37-parameterized-video-pipelines.md) section 8.)

The second is that occupied stages are **contiguous** — beats pack towards the
exit. This is what makes the ready chain sound; without it, induction invents a
pipeline with a hole in the middle and the chain's reasoning collapses.

### What it buys over a global stall

**Bubbles collapse.** If stage 2 is empty and stage 1 holds a beat, stage 1
advances even while the output is stalled, so the pipeline packs itself towards
the exit and a gap in the input does not survive to the output. The cover point
that proves the behaviour is reachable:

```systemverilog
f_c_collapse : cover (rst_n && valid_q[0] && !valid_q[STAGES-1] && adv[0]);
```

**No extra storage.** The pipeline registers *are* the elastic slots. A skid
buffer per stage would do the same job and cost `N` extra rows of flops.

**It composes.** A valid/ready interface at each end and no side-band `en`.

### Fixing the chain rather than abandoning the scheme

The chain is only a problem because it is *long*. Break it with a register slice
every `K` stages and the depth becomes `O(K)`, at one or two slots per break:

```
stages 0..7  --[slice]--  stages 8..15  --[slice]--  stages 16..23
   ready depth 11             11                        11
```

A `FULL` slice's own ready path is constant — measured 6 gates at `DW=32`,
independent of how long the pipeline behind it is — so the break really does reset
the count.

---

## 8. Register slices: the five ways to cut a handshake

A handshake has two directions, and each can be registered or not. Cutting the
forward path is easy; cutting the backward path costs **storage**, because during
the cycle the source has not yet seen `ready` fall it may still send a beat, and
that beat needs somewhere to live. Everything else follows.

**The names vary, so here they are in one place.** What this document calls a
slice mode goes by several names in the literature and in vendor IP: `FWD` is a
*pipeline register* or *forward-registered slice*; `REV` is a *ready-registered*
or *reverse-registered slice*; `FULL` is a *skid buffer*, an *elastic buffer* or a
*fully-registered slice*; `HALF` is a *half-rate buffer*, a *half buffer* or a
*light-weight slice*. The names are not standardised and the structures are, so
identify one by **what it cuts and what it costs** — the two path columns and the
flop count below — rather than by what someone called it.

[`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv) implements all five in
one module so they can be compared rather than argued about. **Measured** —
flop counts from yosys at `DW=8`, everything else from
[`pipeline_stall_tb.sv`](../examples/tb/pipeline_stall_tb.sv):

| `MODE` | flops | beats / 100 cy | latency | forward path | backward path |
|---|---|---|---|---|---|
| 0 `PASS` | 0 | 100 | 0 | combinational | combinational |
| 1 `FWD` | 9 | 99 | 1 | **registered** | combinational |
| 2 `REV` | 9 | 100 | 0 | combinational | **registered** |
| 3 `FULL` | 18 | 99 | 1 | **registered** | **registered** |
| 4 `HALF` | 9 | 50 | 1 | **registered** | **registered** |

The two path columns are not read off the source: the testbench **changes an input
between clock edges and looks at whether an output moves in the same instant.**
That is a direct observation of combinational dependence, and it is worth doing
that way because the answer for `FWD` depends on state (`s_ready = !m_valid ||
m_ready` only depends on `m_ready` while a beat is held) and because a mode can be
accidentally correct.

### Choosing

**`FWD` — the forward register.** The default. One slot, full rate, and the
source still learns about a stall in the same cycle, which is why one slot
suffices. Use it wherever the *data* path is long: after a multiplier, out of a
RAM, across a module boundary you own both sides of.

**`REV` — ready registered.** The mirror image, and the one people forget exists.
Nothing downstream reaches the source combinationally, but the forward path is a
mux (through-or-slot). Use it when the *ready* is the problem and the data path is
short — most usefully to break a long ripple chain like section 7's.

**`FULL` — the skid buffer.** Both directions registered, full rate, two slots.
The standard pipeline-stage element and the right default on any interface you do
not control both ends of, or any path long enough that a repeater is needed.
[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) is not reimplemented inside
`axis_reg_slice`; `MODE=FULL` instantiates it, because it already carries the
proof that it loses, duplicates and reorders nothing.

**`HALF` — the half-rate slice.** One slot, both directions registered, and half
the bandwidth. The cost is not an accident of the implementation — it is forced:

```systemverilog
// axis_reg_slice.sv, MODE_HALF
assign s_ready = !full_q;
assign m_valid = full_q;
always_ff ... if (!full_q) begin if (s_valid) begin full_q <= 1'b1; ... end end
            else if (m_ready) full_q <= 1'b0;
```

The slot cannot be reloaded in the same cycle it drains, because deciding to
reload needs `m_ready`, and using `m_ready` in the load condition is exactly what
would put it back into the `s_ready` path. So it fills on one cycle and empties on
the next, for ever. Its defining property is asserted rather than described, and
proved:

```systemverilog
a_half_rate: assert property (@(posedge clk) disable iff (!rst_n)
  (s_valid && s_ready) |=> !(s_valid && s_ready));
```

Use it when every output must be a register and the bandwidth is genuinely spare:
a configuration bus, a status path, a debug port, a long chip-crossing where you
would otherwise need two slices' worth of area at every repeater. **Do not** use
it in a datapath and then wonder why the throughput is exactly half of the
arithmetic's capability — which is the one mistake this mode invites, and the
reason the rate column in that table exists.

**`PASS` — no register.** Present so that `MODE` can be swept without editing the
instantiation, and so that "what does a slice cost" has a zero to compare against.

### The rate column is the one a data check cannot see

A slice that stalls one cycle per beat passes every data-integrity test ever
written and halves the bandwidth. `HALF` does that *by design*; a broken `FULL`
does it by accident. So measure the rate, always, and assert it:

```systemverilog
ck($sformatf("%s sustains ~1 beat/cycle (got %0d/100)", MODE_NAME[m], rate_beats[m]),
   rate_beats[m] >= 95);
```

(`FWD` and `FULL` measure 99 rather than 100 in a 100-cycle window because of
their one cycle of fill; `REV` and `PASS` measure 100 because a beat can pass
straight through.)

---

## 9. Never stalling at all

The cheapest stall scheme is the one that does not exist. Three real designs where
that is the right answer:

**Fixed-rate sinks.** A video output, a DAC, a radio transmit chain: the consumer
takes one sample per clock for ever and cannot be stalled, so nothing upstream
needs a ready. The pipeline is a fixed-latency function and `valid` is only there
to mark the fill and drain. This is the shape of most of
[docs/37](37-parameterized-video-pipelines.md)'s video blocks internally.

**Credit-based flow control.** The producer is *told in advance* how many beats it
may send, so backpressure never has to travel at the speed of a single beat
([docs/30](30-flow-control-and-handshakes.md)). This converts a timing problem
into a bookkeeping problem, which is a good trade at a chip crossing.

**Rate-limited producers.** If the producer physically cannot exceed the
consumer's rate — a serial interface, a decimated stream, a datapath running at
one beat per `N` cycles — a stall path is dead logic. Prove the rate bound and
delete the handshake. What you must not do is *assume* the bound: write it down as
an assertion, so that the day someone doubles the producer's clock the simulation
fails instead of the silicon.

The thing all three have in common: **the stall discipline is replaced by a
contract, and the contract is checked.** An unchecked "this never stalls" is how a
FIFO ends up overflowing once per hour in the field.

---

## 10. Flush versus drain

Two ways to get rid of work in flight, and they are not interchangeable.

**Drain**: stop offering new beats, wait for `busy` to fall. Costs `LATENCY`
cycles, breaks no contract, and needs no logic at all beyond the `busy` signal.

**Flush**: destroy everything in flight this cycle. Costs nothing in time, and
breaks the valid/ready contract — which is the part that gets missed.

```systemverilog
// pipe_ctrl.sv and pipe_ripple_ctrl.sv both do this:
if      (!rst_n) valid_q <= '0;
else if (flush)  valid_q <= '0;        // flush BEFORE en
else if (en)     valid_q <= {valid_q[STAGES-2:0], valid_i};
```

**Flush is tested before the advance**, because an aborted pipeline must clear
even while stalled. Get that backwards and the stale beats sit in the pipe and
reappear when the stall lifts — a bug that needs a flush and a stall in the same
cycle to show itself.

Only the valid bits need clearing. The datapath registers keep their stale
contents and nobody will look at them, which is what makes flush cheap.

### The contract problem, found by the proof

The accounting property in `pipe_ripple_ctrl` failed in BMC on the first run, and
the counterexample was a flush: the valid bits cleared, the in-flight count went
to zero, and the counters kept their old difference for ever. Re-basing the
counters on flush fixes the accounting — but thinking about *why* they had to be
re-based turned up the real issue:

```systemverilog
assign s_ready = can_take[0] && !flush;
assign m_valid = valid_q[STAGES-1] && !flush;
```

Both ends must be gated during a flush:

- without the gate on `s_ready`, a beat can be **accepted and discarded in the
  same cycle** — the producer counts it as delivered, the consumer never sees it.
  That is not a flush, it is a lost beat.
- without the gate on `m_valid`, the consumer can take a beat in the cycle the
  pipeline is aborted: half an abort.

And now the part that cannot be engineered away: gating `m_valid` makes `valid`
fall without `ready` having been seen, which **violates the valid/ready
contract**. That is unavoidable — an abort is a protocol violation by definition.
So `flush` must be a signal both ends of the stream understand. If it cannot be,
**drain instead of flushing**: stop offering, wait for `busy`, and accept the
latency. The choice is a system decision, not a module decision, and a module that
offers `flush` should say which one its users are expected to arrange.

---

## 11. Reconvergence and the skew buffer

Stalling is not the only thing that goes wrong in a pipeline with structure. When
a pipeline forks and rejoins, the results have to be paired up again:

```
         .------ branch A (3 stages, sometimes stalls) ------.
in ----- |                                                   | ---> out
         '------ branch B (7 stages, never stalls) ----------'
```

Three cases, and only the first is obvious:

1. **Fixed latency difference.** B is four cycles behind A, always. A delay line
   ([`pipe_delay.sv`](../examples/rtl/pipe_delay.sv)) on the short branch, sized
   to the difference. Correct only while the difference is constant.
2. **Variable difference.** If either branch can stall independently, no delay
   line can match them — the skew changes at run time. This is what
   [`skew_buffer.sv`](../examples/rtl/skew_buffer.sv) is for: a small FIFO per
   side, and the join fires when both have a beat.
3. **A join with no storage couples the branches.** The obvious join —
   `m_valid = a_valid && b_valid` with a shared ready — makes every stall in A a
   stall in B and vice versa. Two branches that each stall 5% of the time now
   stall 10%, and a stall anywhere is a stall everywhere. This is how a carefully
   local backpressure scheme quietly becomes a global one.

```systemverilog
// skew_buffer.sv -- the join, and the whole idea
assign m_valid = !a_empty && !b_empty;
assign xfer    = m_valid && m_ready;
assign a_ready = !a_full;
assign b_ready = !b_full;
```

**Sizing is the bandwidth-delay product again** ([docs/30](30-flow-control-and-handshakes.md)):
if A stalls for up to `S` cycles at a time while B keeps producing, `DEPTH` must be
at least `S` or B stalls too. Choosing it by "4 looks about right" is the usual
reason a reconverging pipeline runs at 80% of what its arithmetic could sustain.
The module brings the skew out as a port precisely so the number can be *observed*
rather than assumed:

```
[skew] max skew observed 4 of DEPTH 4; branch A stalled 14 cycles
```

That line is from the testbench, and it is the useful kind of measurement: the
buffer is exactly full at the peak, so `DEPTH=4` is the smallest depth that works
for this traffic and any less would have stalled the fast branch more.

**The pairing property is the one to assert**, because losing it is silent and
permanent:

```systemverilog
a_paired: assert property (@(posedge clk) disable iff (!rst_n)
  (u_fifo_a.do_rd == u_fifo_b.do_rd));
```

A join that reads one FIFO without the other does not drop a beat — it offsets the
two streams by one, for ever, and every subsequent output pairs the wrong things.

**And it does not reorder.** Beat `n` of A is paired with beat `n` of B. If the
branches can complete out of order — variable-latency stages, multiple outstanding
requests — pairing by arrival is wrong and you need tags
([docs/21](21-pipelining.md) section 10), not a skew buffer.

---
## 12. Verifying a pipeline that stalls

A stall multiplies the state space by the number of places it can land. Four
techniques carry most of the weight, and then there is a list of ways to fool
yourself.

### (a) Stall insensitivity, as a differential test

The property that matters is not "the output is right" but **"the output does not
depend on when we stalled."** Push the *same* input sequence through under
different backpressure patterns and require the *same* output sequence:

```systemverilog
// pipeline_stall_tb.sv
for (int trial = 0; trial < 3; trial++) begin
  ... case (trial)
        0:       estep(1'b1, 1'b1);                                  // clean
        1:       estep(1'b1, ($urandom_range(0, 3) != 0));            // backpressure
        default: estep(($urandom_range(0, 3) != 0),                   // ...and gaps
                       ($urandom_range(0, 1) != 0));
      endcase
end
// then: every trial must match the model, and therefore each other
```

A pipeline that loses a beat only when a stall lands in one particular cycle
passes every fixed-pattern test ever written. This is the cheapest test that can
see it.

**And the third pattern is not optional.** Offering the input continuously keeps
the pipeline full, and in a full pipeline **every per-stage enable is the same
signal** — `can_take[i]` collapses to `m_ready` for every `i`. So a datapath stage
registered on the wrong stage's enable is *invisible* without gaps in the input.
Measured: with trials 0 and 1 only, mis-wiring cut 3 to `adv[0]` passed the
testbench; adding gaps failed it. **Bubbles are the stimulus that makes per-stage
control observable.**

### (b) Sequence numbering, for loss, duplication and reordering

Constrain the producer so that each beat's payload *is* its sequence number, then
assert the output counts up with no gaps. One assertion covers three failures: a
gap is a lost beat, a repeat is a duplicate, a step backwards is a reordering.
Sound whenever the control never inspects the payload — which is true of every
slice in [section 8](#8-register-slices-the-five-ways-to-cut-a-handshake), and is
*not* true of anything that branches on its data.

### (c) Occupancy invariants, stated as equalities

Every elastic block here carries the same shape of invariant, and it is what makes
`prove` (induction) close rather than return UNKNOWN:

```systemverilog
// pipe_ripple_ctrl.sv
assert ((f_n_in - f_n_out) == f_occupancy);
// axis_reg_slice.sv
f_occupancy : assert ((fv_in_seq - fv_out_seq) == fv_occ);
```

Two rules learned the hard way (and again in
[docs/37](37-parameterized-video-pipelines.md) section 8):

- **The counters must live inside the module**, beside the state they account for.
  A harness-side counter cannot see the occupancy, so induction has to guess the
  relationship and comes back UNKNOWN.
- **An equality, not a bound.** `(in - out) <= N` is true and useless: induction
  may start from a state where the counters are already `N` apart with nothing in
  flight, and one more beat breaks it. Say exactly where every beat is.

### (d) Negative controls, and what each check cannot see

Every proof here was mutation-tested. The table is more interesting than a list of
passes, because several of the PASS cells are blind spots rather than successes,
and one row is a mutation that *should* pass everything. Knowing which is which is
the difference between a verification plan and a pile of tests.

(The `prove` column checks the properties that are inductive — the clamp, and the
global stall's promise that nothing moves while `en` is low — so it is not
expected to see a staging or arithmetic change at all. It is in the table to show
that it does see the one thing it is for.)

| mutation | testbench | `bmc` (global) | `elastic` | `prove` |
|---|---|---|---|---|
| stage 4 registered on `adv[0]` | FAIL *(only with input gaps)* | **PASS** | FAIL | **PASS** |
| rounding term removed | FAIL | **PASS** | **PASS** | **PASS** |
| clamp removed | FAIL | FAIL | FAIL | FAIL |
| adder tree rewritten as a chain | PASS | PASS | PASS | PASS |

Reading the blind spots:

- **The global-stall equivalence cannot see a per-stage enable mistake**, and
  provably so: `adv = {4{en}}` makes all four enables the same wire, so `adv[0]`
  *is* `adv[3]`. That is why `dot_rs_fv.sby` has a second task driving the elastic
  wrapper, where the enables genuinely differ. The `elastic` task catches it.
- **Neither equivalence task can see an arithmetic mistake**, because both
  instances come from the same source with different `CUTS` — the mutation applies
  to the design *and* the reference. That is the price of a reference that cannot
  drift, and it is the right trade: arithmetic is what the `longint` model in the
  testbench is for, and staging is what these proofs are for. Know which question
  each answers.
- **Nothing functional sees the tree-versus-chain change, and nothing should** —
  it is the same sum. The only check that notices is the depth measurement, and it
  notices loudly:

  | `TAPS` | tree | chain |
  |---|---|---|
  | 4 | 25 | 33 |
  | 16 | **43** | **89** |

  A reduction written as a chain is `O(TAPS)` deep instead of `O(log TAPS)`
  ([docs/21](21-pipelining.md) section 12). At 16 taps the chain is twice the
  depth, every functional check passes, and the only thing that fails is the
  clock. **`ltp` is a verification tool, not just a curiosity.**

The slice proofs were mutation-tested the same way: `FWD` with `s_ready` tied
high, `REV` with a corrupted slot payload, and `HALF` allowed to reload while
draining — each fails exactly the corresponding task.

### (e) Vacuity: the failure mode that looks like success

The first version of `axis_reg_slice_fv.sv` drove the payload from the harness:

```systemverilog
assign s_data = '0;                     // and the module contains
                                        //   always @* assume (s_data == fv_in_seq);
```

Two constraints fighting, and the moment the counter increments the assumption
becomes **unsatisfiable**. Every task then passes — including, as measured, a
deliberately broken `FWD` slice that loses beats. A proof that passes a broken
design is worse than no proof.

The alarm was the cover task:

```
m_fwd=PASS   cover=FAIL      <- with the broken design AND the tied-off payload
```

**An assumption nothing can satisfy makes every assertion pass and every cover
unreachable.** So the covers are not documentation, they are the cheapest vacuity
detector available, and a `cover` task that fails while the proofs pass should be
read as "the proofs are not proving anything" before it is read as a missing
feature. Twenty-seven of the twenty-nine proofs here carry one; the two that do
not (`div_const_fv`, `mul_const_fv`) drive their module directly with no harness,
so there is no assumption that could be unsatisfiable in the first place.

### (f) Testbench traps specific to handshakes

Three of these cost real time while writing
[`pipeline_stall_tb.sv`](../examples/tb/pipeline_stall_tb.sv):

**Decide what an edge will do BEFORE it happens.** A transfer happens on the
posedge where `valid && ready`. Sampling that condition *after* the edge reads the
post-transfer state: an output beat gets counted twice (valid is still high for the
*next* beat) and an input beat gets advanced too early. The discipline that works:

```systemverilog
task automatic step(input logic want_valid, input logic want_ready);
  if (!s_valid || took) s_valid = want_valid;   // protocol: hold until accepted
  m_ready = want_ready;
  #1;                                           // let combinational readys settle
  if (m_valid && m_ready) begin ...check the output beat... end
  took = s_valid && s_ready;                    // what the coming posedge will do
  @(negedge clk);                               // the posedge happens in here
  if (took) s_data = s_data + 1'b1;             // advance only after it happened
endtask
```

Getting the order wrong made every payload skip by one, which looks exactly like a
DUT that drops beats.

**Probe for a CHANGE, not a level.** The combinational-path measurement toggles an
input between edges and looks at an output. The first version asked "is `s_ready`
high?" and reported the skid buffer as combinational, because its `s_ready` was
already high for its own reasons. Record, change, compare:

```systemverilog
was_sr  = s_ready;
m_ready = 1'b1;
#1;
comb_bwd[M] = (s_ready !== was_sr);
```

**And the one that is not my fault but is my problem.** `while (got_n < int'(NSEQ))`
never executes its body under XSIM — a `while` condition containing a cast is
evaluated as false, silently
([docs/37](37-parameterized-video-pipelines.md) section 13). This is the second
time it has eaten a testbench in this repository. The collector looked fine, ran
zero times, and the testbench printed PASS. Declare the bound as a signed `int`
and compare it bare.

---

## 13. Checklist

**Staging**
- [ ] The critical path measured before cutting, not guessed.
- [ ] Each cut crosses every path from input to output exactly once.
- [ ] No cut whose only effect is to register an output (it buys nothing and costs
      a cycle).
- [ ] The longest surviving fragment measured after cutting, and it is the
      expensive operator rather than something accidental.
- [ ] Diminishing returns checked: the cut set with the best depth-per-cycle
      chosen, not the deepest pipeline that would fit.
- [ ] Reductions written as trees, and the depth measured (`O(log N)`, not
      `O(N)`).
- [ ] Latency derived from the cut set in one place, and used by both the datapath
      and the control.
- [ ] Every sideband signal delayed to match, counters included
      ([docs/21](21-pipelining.md) section 3).

**Choosing a stall scheme**
- [ ] Datapath written with per-stage enables; flow control in its own module.
- [ ] Global stall only where one agent owns the whole path — and its fanout
      acknowledged as a physical-design cost.
- [ ] Ripple chain depth checked against the pipeline length, and broken with
      slices if it is on the critical path.
- [ ] Slice mode chosen from which path needs cutting, not by habit.
- [ ] `HALF` used only where the bandwidth is genuinely spare, and its 50% written
      down where the next reader will see it.
- [ ] If the design never stalls, that contract is asserted rather than assumed.

**Correctness**
- [ ] Freeze everything or nothing: no ad-hoc per-stage enable in a
      globally-stalled pipeline.
- [ ] Flush tested before the advance, so an aborted pipeline clears while
      stalled.
- [ ] Flush gates both ends, and the fact that it breaks the valid/ready contract
      is stated where its users will read it — or drain instead.
- [ ] Reconvergent branches joined through a buffer sized to the skew, not a bare
      AND of valids.
- [ ] Pairing asserted at every join.

**Verification**
- [ ] The same input sequence run under several backpressure patterns, with the
      output sequences required to match.
- [ ] At least one pattern with **gaps in the input**, or per-stage control is
      untested.
- [ ] Throughput measured, not just data integrity.
- [ ] Occupancy stated as an equality, with the counters inside the module.
- [ ] Every proof negative-controlled, and the blind spots written down.
- [ ] A cover task alongside every proof task, read as a vacuity alarm.

---

## See also

- [docs/21: Pipelining](21-pipelining.md) — the general treatment: what pipelining
  buys, latency matching, retiming, hazards, loops, variable-latency stages
- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — what a
  high-fanout stall net actually costs, and why depth is not delay
- [docs/25: Formal verification](25-formal-verification-with-sby.md) — task
  layout, negative controls, why properties live where the state is
- [docs/26: FSM coding styles](26-fsm-coding-styles.md) — the control/datapath
  split this document leans on
- [docs/30: Flow control and handshakes](30-flow-control-and-handshakes.md) — the
  valid/ready contract, FIFO sizing, credit schemes, deadlock
- [docs/33: Debugging and bring-up](33-debugging-and-bringup.md) — why the build
  fails on a failing assertion even when the testbench prints PASS
- [docs/35: Low-power architecture](35-low-power-architecture.md) — clock gating a
  stalled pipeline instead of merely disabling it
- [docs/37: Parameterized video pipelines](37-parameterized-video-pipelines.md) —
  the same invariant and measurement discipline on a wider datapath, and the XSIM
  traps referenced above
- [docs/39: Control registers and safe reconfiguration](39-control-registers-and-safe-reconfiguration.md)
  — stalling a pipeline is one problem; reconfiguring one with beats in flight is
  another. Quiescing uses the drain of §10, and it is measured there that under an
  unbroken input stream the drain never comes
