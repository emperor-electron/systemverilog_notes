# Pipelining

Pipelining is the single highest-leverage technique in RTL design: it trades
latency and a modest amount of area for throughput and clock frequency, and
unlike most optimizations it scales — you can keep applying it until the wires
themselves become the limit.

It is also where most functional bugs in otherwise-correct datapaths come from,
and almost all of them are the same bug: **one signal got delayed and another
did not.**

Companion code:
[`pipe_delay.sv`](../examples/rtl/pipe_delay.sv) ·
[`pipe_ctrl.sv`](../examples/rtl/pipe_ctrl.sv) ·
[`adder_tree.sv`](../examples/rtl/adder_tree.sv) ·
[`acc_interleaved.sv`](../examples/rtl/acc_interleaved.sv) ·
[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) ·
[`mac_pipelined.sv`](../examples/rtl/mac_pipelined.sv) ·
[`fir_systolic.sv`](../examples/rtl/fir_systolic.sv) ·
tested by [`pipeline_tb.sv`](../examples/tb/pipeline_tb.sv)

---

## Contents

- [1. What pipelining actually buys](#1-what-pipelining-actually-buys)
- [2. The basic transformation](#2-the-basic-transformation)
- [3. Latency matching](#3-latency-matching)
- [4. Valid, stall, and flush](#4-valid-stall-and-flush)
- [5. Where to cut](#5-where-to-cut)
- [6. Retiming: let the tool place the registers](#6-retiming-let-the-tool-place-the-registers)
- [7. Elastic pipelines and handshakes](#7-elastic-pipelines-and-handshakes)
- [8. Loops cannot be pipelined](#8-loops-cannot-be-pipelined)
- [9. Hazards and forwarding](#9-hazards-and-forwarding)
- [10. Variable-latency stages](#10-variable-latency-stages)
- [11. Pipelining memory accesses](#11-pipelining-memory-accesses)
- [12. Pipelining arithmetic](#12-pipelining-arithmetic)
- [13. The bug checklist](#13-the-bug-checklist)
- [14. What it costs](#14-what-it-costs)

---

## 1. What pipelining actually buys

A synchronous design's clock period must satisfy, roughly:

```
T_clk  >=  T_cq  +  T_logic  +  T_setup  +  T_skew  +  T_jitter
           ^^^^^^     ^^^^^^^^^^^^^^^^^^     ^^^^^^^^^^^^^^^^^^
           flop       the part you control   fixed overhead
```

`T_logic` is the combinational delay between two registers. Pipelining cuts a
long `T_logic` into `N` shorter ones. Two consequences that people conflate:

| | Effect |
|---|---|
| **Throughput** | unchanged in *operations per cycle* (still one), but the cycle is shorter, so **operations per second goes up** |
| **Latency** | goes **up** in cycles, and usually slightly up in absolute time too (each stage pays `T_cq + T_setup` again) |

So pipelining is the right move when you care about **aggregate throughput**
(a filter, a crypto core, a packet path) and the wrong move when you care about
**response time on a single item** (an interrupt path, a bus turnaround, a
feedback control loop).

### Diminishing returns

The fixed overhead per stage does not shrink. If `T_cq + T_setup ≈ 100 ps` and
your logic is `2 ns`:

| Stages | `T_logic` per stage | `T_clk` | Speedup | Latency |
|---|---|---|---|---|
| 1 | 2000 ps | 2100 ps | 1.00× | 1 cycle, 2.1 ns |
| 2 | 1000 ps | 1100 ps | 1.91× | 2 cycles, 2.2 ns |
| 4 | 500 ps | 600 ps | 3.50× | 4 cycles, 2.4 ns |
| 8 | 250 ps | 350 ps | 6.00× | 8 cycles, 2.8 ns |
| 16 | 125 ps | 225 ps | 9.33× | 16 cycles, 3.6 ns |

Past about 8 stages you are mostly buying flip-flops. And in reality the split
is never even, so the worst stage sets the clock — which is why
[balancing](#5-where-to-cut) matters more than depth.

---

## 2. The basic transformation

Start with a combinational path that is too long:

```systemverilog
// One deep combinational path: multiply, then add, then saturate.
always_comb begin
  prod = a * b;
  sum  = prod + c;
  y    = sat(sum);
end
```

Cut it with registers:

```systemverilog
logic signed [PW-1:0]   prod_q;
logic signed [SW-1:0]   sum_q;

always_ff @(posedge clk) begin
  prod_q <= a * b;          // stage 1
  sum_q  <= prod_q + c_q;   // stage 2   <-- note c_q, NOT c
  y_q    <= sat(sum_q);     // stage 3
end
```

The `c_q` is the whole lesson. `c` arrived at the same time as `a` and `b`, but
it is consumed one stage later, so it must be delayed by one cycle. Using `c`
directly compiles, simulates, synthesizes, and is wrong — it pairs each product
with the *next* operand.

That is what [`pipe_delay`](../examples/rtl/pipe_delay.sv) is for.

---

## 3. Latency matching

**Rule: when you add a stage, every signal that travels with the data gets the
same delay.** Not just the obvious payload — the valid bit, the transaction tag,
byte enables, the destination ID, the "this one was an error" flag.

```systemverilog
// A 3-deep datapath. Everything alongside it is delayed by the same amount,
// from one parameter, so the depth can never drift between signals.
localparam int unsigned LAT = 3;

pipe_delay #(.WIDTH($bits(tag_t)), .LATENCY(LAT)) u_tag (
  .clk, .rst_n, .en(pipe_en), .din(tag_in),  .dout(tag_out));

pipe_delay #(.WIDTH(4), .LATENCY(LAT)) u_be (
  .clk, .rst_n, .en(pipe_en), .din(be_in),   .dout(be_out));

pipe_delay #(.WIDTH(1), .LATENCY(LAT), .RESET(1'b1)) u_vld (
  .clk, .rst_n, .en(pipe_en), .din(vld_in),  .dout(vld_out));
```

Three details in that snippet that matter:

1. **One `LAT` parameter, used everywhere.** The moment you write `3` in two
   places, someone will change one of them.
2. **`LATENCY(0)` is legal** and degenerates to a wire, so a parent can
   parameterize the depth down to nothing without conditional instantiation.
3. **`RESET(1'b1)` on the valid, `RESET(1'b0)` on the data.** The valid bit
   *must* reset — a spurious valid out of reset injects garbage. The payload
   need not: whether its contents mean anything is exactly what the valid bit
   says. Leaving reset off a 512-bit datapath removes 512 flops from the reset
   tree, which is a real saving in area and routing.

> **Reset the control path. Do not reset the data path.**

### Bundle the pipeline into a struct

Once a stage carries more than two or three things, a packed struct is better
than parallel `pipe_delay` instances — one register, one reset, and adding a
field touches one place:

```systemverilog
typedef struct packed {
  logic                  valid;
  logic [TAG_W-1:0]      tag;
  logic [3:0]            be;
  logic                  err;
  logic signed [DW-1:0]  data;
} stage_t;

stage_t s1, s2, s3;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    // '0 covers every field, including ones added later.
    s1 <= '0;  s2 <= '0;  s3 <= '0;
  end else if (pipe_en) begin
    s1       <= in;
    s2       <= s1;
    s2.data  <= stage2_transform(s1.data);   // transform in place
    s3       <= s2;
    s3.data  <= stage3_transform(s2.data);
  end
end
```

The `s2 <= s1; s2.data <= f(s1.data);` pattern works because both are
non-blocking assignments in the same block and the later one wins for the bits
it covers — a legitimate and very readable "copy the bundle, override one
field". Confirm your lint accepts it; some flows flag the partial overlap.

---

## 4. Valid, stall, and flush

A pipeline needs three control mechanisms. [`pipe_ctrl`](../examples/rtl/pipe_ctrl.sv)
packages them.

### Valid

Without a valid bit, the first `N` results out of an `N`-deep pipeline are
garbage and nothing downstream can tell. The valid bit is just the data's
shadow, shifted the same way:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if      (!rst_n) valid_q <= '0;
  else if (en)     valid_q <= {valid_q[STAGES-2:0], valid_i};
end
assign valid_o = valid_q[STAGES-1];
assign busy    = |valid_q;          // anything still in flight?
```

`busy` is what tells you when a drained pipeline's accumulated result is
meaningful.

### Stall

A stall is a **global** clock enable. Every stage freezes together:

```systemverilog
always_ff @(posedge clk) if (en) stage_q <= stage_d;
```

Freezing stages *independently* is how beats get duplicated (a downstream stage
re-samples a held value) or dropped (an upstream stage advances into a frozen
one). If you find yourself wanting per-stage enables, what you actually want is
an [elastic pipeline](#7-elastic-pipelines-and-handshakes).

### Flush

Flush kills in-flight work — a mispredicted branch, an aborted transaction, an
error. **It only has to clear the valid bits:**

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if      (!rst_n) valid_q <= '0;
  else if (flush)  valid_q <= '0;        // flush BEFORE en
  else if (en)     valid_q <= {valid_q[STAGES-2:0], valid_i};
end
```

The datapath registers keep their stale contents, and that is fine, because
nothing will look at them. This is why flush is cheap.

**Note the priority: `flush` is tested before `en`.** An aborted pipeline must
clear even while stalled. Get that backwards and the stale beats sit there and
reappear when the stall lifts — a bug that only shows up when a flush and a
stall coincide, which is to say rarely and then catastrophically.

```systemverilog
// The property that catches it:
a_flush_clears: assert property (@(posedge clk) disable iff (!rst_n)
  flush |=> (valid_q == '0));
```

---

## 5. Where to cut

The worst stage sets the clock, so a badly balanced 4-stage pipeline can be
slower than a well-balanced 2-stage one.

### Find the real critical path first

Do not guess. Synthesize and read the timing report. The path that is slow is
very often not the one you assumed — a wide mux, a priority chain, or a
high-fanout enable beats "the multiplier" more often than people expect.

### Good cut points

| Cut here | Why |
|---|---|
| **After a wide multiply, before the add** | the multiply is usually the single biggest lump |
| **Before a leading-zero count / normalizer** | LZC + barrel shift is the classic FP critical path |
| **After address decode, before the memory** | decode and RAM access are each substantial |
| **After the memory, before the consumer** | a registered RAM output is nearly free and often already there |
| **At a module boundary** | makes the cut visible in the hierarchy and survives refactoring |
| **Across a long wire** | see [docs/22](22-timing-closure-and-optimization.md) — wire delay does not shrink with process |

### Bad cut points

- **In the middle of a carry chain.** You cannot usefully register bit 17 of a
  32-bit adder; register the operands or the result instead and let
  [retiming](#6-retiming-let-the-tool-place-the-registers) redistribute.
- **Inside a feedback loop.** See [section 8](#8-loops-cannot-be-pipelined).
- **Somewhere that forces you to duplicate control logic.** If a cut means two
  copies of the FSM, cut elsewhere.

### Balance by counting levels, not by feel

```systemverilog
// A deliberately unbalanced pipeline: stage 1 does almost nothing, stage 2
// does a multiply AND an add AND a saturate. Clock is set by stage 2.
always_ff @(posedge clk) begin
  a_q <= a;                                   // stage 1: a wire
  y_q <= sat(a_q * b_q + c_q);                // stage 2: everything
end

// Balanced: each stage is one substantial operation.
always_ff @(posedge clk) begin
  prod_q <= a_q * b_q;                        // stage 1: multiply
  sum_q  <= prod_q + c_qq;                    // stage 2: add
  y_q    <= sat(sum_q);                       // stage 3: saturate
end
```

---

## 6. Retiming: let the tool place the registers

**Retiming** (also "register balancing" or "register retiming") is a synthesis
transformation that moves registers across combinational logic without changing
the cycle-by-cycle behaviour at the module boundary. It is one of the few
optimizations that reliably does better than a human, because it works on the
post-mapping netlist where the real delays are known.

The idiom: **put the registers where they are easy to reason about, and let the
tool move them where they need to be.**

```systemverilog
// Write this: three registers bunched at the output of a big multiplier.
// It is obviously correct and trivially latency-matched.
module mult_pipe #(parameter int W = 18, parameter int PIPE = 3) (
  input  var logic                clk,
  input  var logic signed [W-1:0] a, b,
  output var logic signed [2*W-1:0] p
);
  logic signed [2*W-1:0] stage [0:PIPE-1];

  always_ff @(posedge clk) begin
    stage[0] <= a * b;
    for (int i = 1; i < PIPE; i++) stage[i] <= stage[i-1];
  end
  assign p = stage[PIPE-1];
endmodule
```

Retiming will pull `stage[1]` and `stage[2]` *back into* the multiplier array,
turning one slow stage plus two idle ones into three balanced stages. You get a
pipelined multiplier without writing a pipelined multiplier.

### Enabling it

It is off or limited by default in most flows, because it perturbs names and can
increase area:

```tcl
# Synopsys Design Compiler
set_optimize_registers true -design mult_pipe
# or the older: optimize_registers

# Cadence Genus
set_db retime_optimize_registers true
retime -min_delay

# Xilinx Vivado
set_property -name {STEPS.SYNTH_DESIGN.ARGS.RETIMING} -value 1 \
    -objects [get_runs synth_1]
# and per-module:
(* retiming_backward = 1 *) logic signed [2*W-1:0] stage [0:PIPE-1];

# Intel Quartus (on by default in Hyper-Retiming for Stratix 10+)
set_global_assignment -name ALLOW_REGISTER_RETIMING ON
```

### What blocks retiming

Retiming cannot move a register that has observable side effects. In practice:

| Blocker | Fix |
|---|---|
| **A reset on the register** | asynchronous resets are the big one — the tool must preserve reset behaviour exactly. Omit the reset on pure datapath pipeline registers |
| **An initial value** | same reason |
| **A clock enable that differs between stages** | use one common enable |
| **`dont_touch` / `preserve`** | remove it |
| **The register is a module output** | retime inside the module, or flatten the boundary |
| **Anything reads the intermediate stage** | including an assertion or a debug port |

That first row is the important one, and it is the same conclusion as
[section 3](#3-latency-matching) from a different direction: **do not reset
datapath pipeline registers.** Doing so costs area, costs reset routing, *and*
blocks the optimization that would have made the pipeline fast.

```systemverilog
// Retimable: no reset, one common enable.
always_ff @(posedge clk) if (en) stage[i] <= prev;

// NOT retimable: the async reset must be preserved bit-for-bit.
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) stage[i] <= '0;
  else if (en) stage[i] <= prev;
end
```

---

## 7. Elastic pipelines and handshakes

A fixed-latency pipeline with a global stall works when one agent controls the
whole path. When producer and consumer are independent — different modules,
different rates, variable latency — you want a **valid/ready handshake** and an
**elastic** pipeline, where each stage can hold a beat independently.

### The protocol

```
  valid   source asserts when it has data
  ready   sink asserts when it can accept
  transfer happens on any cycle where BOTH are high
```

Two rules that make it composable:

1. **The source must not withdraw `valid`, or change the payload, until the
   transfer completes.** Otherwise a stalled sink loses the beat.
2. **`ready` must not depend combinationally on `valid`** in a way that creates
   a loop through the sink and back.

```systemverilog
// The property that catches rule 1 -- worth asserting on every such interface.
a_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
  (valid && !ready) |=> (valid && $stable(data)))
  else $error("payload changed or valid dropped before handshake");
```

### Why you need a skid buffer

Registering `valid` and `data` is easy. `ready` flows *backwards*, and
registering it too adds a cycle of latency to the backpressure signal — during
which the upstream may still send a beat the downstream has already refused.
That beat has to go somewhere. The somewhere is the "skid" slot.

[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) is that block: both
directions registered, no combinational path from `out_ready` to `in_ready`, and
**full throughput maintained** — one beat per cycle. Cost is `2 × DW` flops.

```systemverilog
// Insert one wherever a valid/ready path gets too long, including
// purely to break a long WIRE.
skid_buffer #(.DW(DW)) u_skid (
  .clk, .rst_n,
  .in_valid  (a_valid), .in_data  (a_data), .in_ready  (a_ready),
  .out_valid (b_valid), .out_data (b_data), .out_ready (b_ready)
);
```

The property that actually distinguishes a correct skid buffer from a naive
registered stage is **throughput**, not data integrity — a design that stalls
one cycle per beat passes every data check and halves your bandwidth. Assert it:

```systemverilog
// In the testbench: with both sides unthrottled, expect ~1 beat per cycle.
if (beats < (cycles * 99) / 100) $error("throughput regression");
```

### Choosing between them

| | Fixed-latency + global stall | Elastic (valid/ready) |
|---|---|---|
| Area | lower | 2 flops per stage per bit |
| Latency | deterministic | deterministic only if never stalled |
| Composability | poor — one stall wire fans out to everything | good — purely local |
| Variable-latency stages | no | yes |
| Best for | a tight DSP datapath you own end to end | module boundaries, NoCs, anything crossing a hierarchy |

A common and good compromise: fixed-latency inside a block, a skid buffer at
each boundary.

---

## 8. Loops cannot be pipelined

This is the hard limit, and it catches everyone once.

```systemverilog
always_ff @(posedge clk) if (valid) acc <= acc + din;
```

You cannot pipeline that adder. Pipelining works by cutting a path with a
register, but this path is a **cycle**: the result is needed as an input on the
very next clock. Insert a register and the accumulator is simply wrong.

The bound is structural: **the minimum clock period of a feedback loop is the
loop's combinational delay divided by the number of registers already in it.**
For an accumulator that is one adder per one register, and no amount of RTL
cleverness changes it.

There are three ways out.

### (a) Interleave — the general answer

Keep `LANES` partial sums and rotate between them. Lane *k* is touched only
every `LANES` cycles, so the round trip `lane → adder → lane` now has `LANES`
cycles to complete, and `PIPE-1` registers can be dropped into it.

```systemverilog
// Full working version: examples/rtl/acc_interleaved.sv
acc_interleaved #(.DW(18), .ACCW(48), .LANES(4), .PIPE(4)) u_acc (
  .clk, .rst_n, .clear, .valid, .din,
  .total (total),      // sum of the four lanes -- read when `busy` is low
  .busy  (busy)
);
```

Cost: `LANES-1` extra accumulator registers, plus one final reduction (an
[adder tree](#12-pipelining-arithmetic)). Constraint: `LANES >= PIPE`.

This is the same idea as **C-slowing** a design, and it is why a tensor-core MAC
array or an FFT butterfly can accumulate at full rate with a deeply pipelined
adder.

> For **integer and fixed-point** operands this rearrangement is exact, because
> addition is associative. For **floating point** it is not: a different
> summation order gives different rounding. Usually *better* rounding (the
> partial sums stay smaller), but different — so a bit-exact comparison against
> a sequential reference will fail. See [docs/19](19-floating-point-hardware.md).

### (b) Keep the value in redundant form — break the carry chain

The loop delay is a carry-propagate adder. Replace it with a carry-save adder
and there is no carry chain at all: value is held as `S + C`, and adding an
operand is one full adder per bit, *independent of width*.

```systemverilog
// S' = S ^ C ^ din ;  C' = maj(S, C, din) << 1     -- two gate levels
// Full version with the overflow discussion: examples/rtl/csa_accumulator.sv
csa_accumulator #(.W(48)) u_csa (
  .clk, .rst_n, .clear, .valid, .din,
  .total (total)      // the one carry-propagate add, outside the loop
);
```

This does not shorten the loop by pipelining it — it shortens the loop's *logic*
to a fixed two levels. Cost: a second register, and the true value is not
directly visible.

### (c) Unroll — process K items per cycle

If the loop body is cheap but you need more throughput than one item per cycle,
widen instead of deepening:

```systemverilog
// Accumulate 4 inputs per cycle: an adder tree feeds one accumulate.
// The loop still has one adder in it, but it now does 4x the work per trip.
logic signed [ACCW-1:0] group_sum;
adder_tree #(.N(4), .W(DW), .OW(ACCW)) u_tree (
  .clk, .rst_n, .en(1'b1), .din_flat(din4), .dout(group_sum));

always_ff @(posedge clk) if (valid) acc <= acc + group_sum;
```

---

## 9. Hazards and forwarding

Once a pipeline has state that a later stage writes and an earlier stage reads,
back-to-back operations can read a value that has not been written yet — a
**read-after-write (RAW) hazard**.

```systemverilog
// A 2-stage pipeline around a register file:
//   stage 1: read regs[ra]
//   stage 2: write regs[rd]
// Two back-to-back instructions where the second reads what the first writes
// will read the STALE value.
```

Three responses, in increasing order of cost and performance:

### (a) Stall — simplest, slowest

Detect the conflict and freeze until it clears.

```systemverilog
assign hazard = s1_valid && s2_valid && (s1_ra == s2_rd) && s2_writes;
assign pipe_en = !hazard;         // costs a cycle per conflict
```

### (b) Forward (bypass) — the usual answer

Route the not-yet-written value directly to the consumer.

```systemverilog
// Bypass mux: if the stage about to write matches the address being read,
// use the in-flight value instead of the register file's output.
always_comb begin
  if (s2_writes && s2_valid && (s1_ra == s2_rd)) rd_data = s2_result;
  else                                            rd_data = regfile_out;
end
```

[`regfile.sv`](../examples/rtl/regfile.sv) has exactly this bypass built in,
which is why a pipeline using it needs one fewer forwarding path.

The cost is a mux on what is often already the critical path — and with several
pipeline stages you need one comparator and one mux input *per stage*, which is
how forwarding networks become the critical path in real processors.

### (c) Restructure so the hazard cannot occur

Interleaving ([section 8](#8-loops-cannot-be-pipelined)) is a special case:
if consecutive operations touch *different* lanes, there is no conflict to
resolve. Likewise, a systolic array
([`fir_systolic.sv`](../examples/rtl/fir_systolic.sv)) has no hazards at all —
data flows one direction, partial sums the other, and nothing is ever read
before it is written.

That is the general lesson: **a dataflow structure with no shared mutable state
needs no hazard logic.** Reach for it before building a forwarding network.

---

## 10. Variable-latency stages

Some stages do not have a fixed latency: a divider, a cache that may miss, a
square root, an off-chip access. Three ways to fit them into a pipeline.

### (a) Handshake around them

The cleanest. The variable-latency block presents valid/ready in both
directions, and the pipeline naturally stalls behind it.
[`div_restoring.sv`](../examples/arith/div_restoring.sv) does this.

```systemverilog
div_restoring #(.W(32)) u_div (
  .clk, .rst_n,
  .valid_i (issue),  .ready_o (div_ready),     // accepts when idle
  .dividend, .divisor,
  .valid_o (result_valid), .ready_i (downstream_ready),
  .quotient, .remainder, .div_by_zero
);
assign pipe_en = div_ready;      // upstream stalls while the divider works
```

### (b) Pad to the worst case

If the variation is small and bounded, delay everything to the maximum and
throw away the flexibility. Trivially correct, and often the right call:

```systemverilog
// Memory is 1 or 2 cycles depending on the bank. Treat it as always 2.
pipe_delay #(.WIDTH($bits(tag_t)), .LATENCY(2)) u_tag (...);
```

### (c) Out-of-order completion with tags

Issue with a tag, complete whenever, and reorder at the end. This is the
highest-performance and by far the most bug-prone option — you now need a
reorder buffer, and a "never completed" watchdog, because a dropped tag is
otherwise invisible. The out-of-order scoreboard pattern in
[docs/16](16-verification-architecture.md#out-of-order-scoreboards) exists
precisely to test this.

---

## 11. Pipelining memory accesses

A synchronous RAM already *is* a pipeline stage — its output is registered. The
mistakes are around it.

```systemverilog
// Address path and data path must stay aligned across the RAM's own latency.
logic [AW-1:0] addr;
logic [DW-1:0] rdata;
tag_t          tag_out;

ram_sp #(.DW(DW), .DEPTH(DEPTH)) u_ram (
  .clk, .en(rd_en), .we(1'b0), .addr(addr), .din('0), .dout(rdata));

// The RAM has 1 cycle of latency, so everything travelling with the request
// needs 1 cycle too -- including the valid.
pipe_delay #(.WIDTH($bits(tag_t)), .LATENCY(1)) u_tag (
  .clk, .rst_n, .en(1'b1), .din(tag_in), .dout(tag_out));
```

Three practical points:

1. **Register the address too, if decode is slow.** Address decode feeding a RAM
   is a common critical path. Cut it: `addr_q <= decode(...)`, then the RAM. You
   have added a cycle; match it everywhere.
2. **A registered RAM output is usually free.** Block RAMs have an optional
   output register (Xilinx `DOB_REG`, Intel similar). Turning it on adds a cycle
   and often buys 30–40% on `T_clk` for the memory path, because it moves the
   output mux and the routing to the consumer inside the flop. Infer it by
   adding one more pipeline register on `dout`:
   ```systemverilog
   always_ff @(posedge clk) rdata_q <= rdata;    // maps to the RAM's own reg
   ```
3. **Read/write collision semantics change with pipelining.** `ram_sdp.sv` leaves
   same-address read/write undefined; if a pipeline stage now writes what a later
   stage reads, add an explicit bypass rather than relying on the RAM primitive.

---

## 12. Pipelining arithmetic

### Adder trees, not chains

```systemverilog
// A chain: N-1 adders in SERIES. Delay grows as O(N).
always_comb begin
  acc = '0;
  for (int i = 0; i < N; i++) acc = acc + a[i];   // O(N) deep
end

// A balanced tree: same adder count, depth ceil(log2(N)).
// PIPE(1) puts a register at every level -> latency clog2(N), and every
// stage is exactly one adder deep, so it is balanced by construction.
adder_tree #(.N(16), .W(16), .PIPE(1'b1)) u_tree (
  .clk, .rst_n, .en, .din_flat(operands), .dout(sum));
```

For 16 operands that is 15 adders deep versus 4. Synthesis often rebalances a
chain on its own, but only when it is confident about associativity and widths —
writing the tree removes the question. See
[`adder_tree.sv`](../examples/rtl/adder_tree.sv), which recurses at elaboration
and handles non-power-of-two `N`.

### Multipliers: register the boundaries, retime the middle

Do not try to pipeline a multiplier array by hand. Put registers on the inputs
and `PIPE` registers on the output, and let
[retiming](#6-retiming-let-the-tool-place-the-registers) distribute them. To hit
a hard DSP block instead, match its shape — a registered multiply feeding a
registered accumulate:
[`mac_pipelined.sv`](../examples/rtl/mac_pipelined.sv).

### Carry-save for multi-operand addition

Adding many things? Compress to two vectors with 3:2 compressors (no carry
chains), then do **one** carry-propagate add at the end. That is what a Wallace
or Dadda tree is, and the cell is three gates:

```systemverilog
// 3:2 compressor: value_in = a + b + c,  value_out = sum + (carry << 1)
assign sum   = a ^ b ^ c;
assign carry = (a & b) | (b & c) | (a & c);
```

[`csa_accumulator.sv`](../examples/rtl/csa_accumulator.sv) applies it in a loop.

### Multi-cycle instead of pipelined

For something used rarely — a divider, a square root — a multi-cycle iterative
unit with a handshake is smaller and simpler than a pipelined one, and the
throughput does not matter. Reach for a pipeline only when you actually need a
result every cycle.

---

## 13. The bug checklist

Every one of these has bitten a real design.

| # | Bug | Symptom | Guard |
|---|---|---|---|
| 1 | **A sideband signal not delayed** | results paired with the wrong metadata; often only visible under back-to-back traffic | one `LATENCY` parameter, used everywhere |
| 2 | **Valid not reset** | garbage injected in the first cycles after reset | reset the control path always |
| 3 | **Datapath reset that blocks retiming** | timing does not improve after pipelining | no reset on pure datapath registers |
| 4 | **Per-stage enables** | beats duplicated or dropped on a stall | one global `en`, or go elastic |
| 5 | **`en` tested before `flush`** | stale beats reappear when a stall lifts | `flush` first; assert `flush \|=> (valid == 0)` |
| 6 | **Register inserted in a feedback loop** | accumulator/FSM silently wrong | interleave, or use carry-save |
| 7 | **RAW hazard on back-to-back ops** | wrong only when two dependent operations are adjacent | forward, stall, or restructure |
| 8 | **Latency changed, consumer not told** | off-by-one-cycle everywhere downstream | expose latency as a parameter the consumer reads |
| 9 | **`valid` withdrawn before `ready`** | dropped beats under backpressure only | assert payload stability |
| 10 | **Naive registered stage instead of a skid buffer** | every data check passes, throughput halves | assert throughput, not just correctness |
| 11 | **Accumulator read before the pipe drained** | result short by the in-flight beats | gate the read on `busy` |
| 12 | **Floating-point sum reordered** | tiny mismatches against a sequential golden model | expect it; compare with a tolerance or reorder the reference |

Two habits that catch most of these cheaply:

```systemverilog
// (a) Make latency a parameter the CONSUMER can read, not a comment.
module my_stage #(parameter int unsigned DW = 32) (...);
  localparam int unsigned LATENCY = 3;    // consumers use my_stage::LATENCY
  ...
endmodule

// (b) Assert that valid and data move together. A one-line trip-wire for
//     the entire class of latency-matching bugs.
a_data_x_when_valid: assert property (@(posedge clk) disable iff (!rst_n)
  valid_o |-> !$isunknown(data_o))
  else $error("valid asserted over undefined data -- latency mismatch?");
```

That second assertion is remarkably effective in a 4-state simulator: if a
sideband signal is off by a cycle, the uninitialized or flushed slot shows up as
`X` exactly when `valid` says it should be real data. It finds latency-matching
bugs on the first run. It finds nothing in Verilator, which is 2-state — see
[docs/02](02-data-types.md).

---

## 14. What it costs

| Cost | Magnitude |
|---|---|
| **Flops** | one per bit per stage, for the payload *and* every sideband signal |
| **Latency** | one cycle per stage; matters for feedback loops and response time |
| **Verification** | every latency is a new way to be wrong; testbenches need drain phases and `busy` handling |
| **Debug** | a waveform now shows the same transaction in N places at N times |
| **Power** | more flops clocking; partly offset because shorter paths mean less glitching |
| **Area** | the flops, plus the valid/stall/flush control, plus forwarding logic if hazards appear |

Pipelining is cheap in *area* and expensive in *cognitive load*. The techniques
that reduce the cognitive load — one latency parameter, struct-bundled stages,
a valid bit asserted against `$isunknown`, latency exposed as a `localparam` —
are worth more than the flops they cost.

For the other side of the coin — making the logic itself shorter, so you need
fewer stages — see
[docs/22: timing closure and optimization](22-timing-closure-and-optimization.md).
