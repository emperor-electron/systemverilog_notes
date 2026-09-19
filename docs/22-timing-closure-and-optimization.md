# Timing Closure and Optimization

Pipelining ([docs/21](21-pipelining.md)) makes paths shorter by cutting them.
This document is about the other half: making the logic itself faster, smaller,
and cheaper — and about the RTL-level decisions that decide whether a design
closes timing easily or fights you for a month.

The theme throughout: **diagnose before you optimize.** Most failed timing
closure is spent speeding up paths that were not the problem.

Companion code:
[`fanout_replicate.sv`](../examples/rtl/fanout_replicate.sv) ·
[`operand_isolation.sv`](../examples/rtl/operand_isolation.sv) ·
[`adder_tree.sv`](../examples/rtl/adder_tree.sv) ·
[`csa_accumulator.sv`](../examples/rtl/csa_accumulator.sv) ·
[`arb_fixed.sv`](../examples/rtl/arb_fixed.sv) ·
[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv)

---

## Contents

- [1. The constraint you are actually fighting](#1-the-constraint-you-are-actually-fighting)
- [2. Reading a timing report](#2-reading-a-timing-report)
- [3. Diagnose first: the path taxonomy](#3-diagnose-first-the-path-taxonomy)
- [4. Logic restructuring](#4-logic-restructuring)
- [5. Late-arriving signals](#5-late-arriving-signals)
- [6. Redundant number systems](#6-redundant-number-systems)
- [7. Precomputation and speculation](#7-precomputation-and-speculation)
- [8. Control-path techniques](#8-control-path-techniques)
- [9. Fanout and replication](#9-fanout-and-replication)
- [10. Memory paths](#10-memory-paths)
- [11. Reset strategy](#11-reset-strategy)
- [12. Constraints: multicycle and false paths](#12-constraints-multicycle-and-false-paths)
- [13. Physical awareness in RTL](#13-physical-awareness-in-rtl)
- [14. Area efficiency](#14-area-efficiency)
- [15. Power efficiency](#15-power-efficiency)
- [16. The workflow](#16-the-workflow)
- [17. Anti-patterns](#17-anti-patterns)

---

## 1. The constraint you are actually fighting

For a setup check between two flops on the same clock:

```
T_clk  >=  T_cq  +  T_logic  +  T_net  +  T_setup  +  T_skew  +  T_jitter  -  T_slack
           ────    ─────────    ─────    ───────    ──────────────────────
           flop    the gates    wires    flop       clock tree + PLL
           output  you wrote    between  input      (you do not control these
           delay                them     req.        from RTL)
```

Two things people underestimate:

- **`T_net` is not small.** On a modern process, wire delay can exceed gate
  delay on any path that crosses more than a few hundred microns. Gate delay
  shrinks with each node; wire delay does not. This is why "there is no logic on
  this path and it still fails" is a normal report, and why
  [pipelining a long wire](21-pipelining.md#5-where-to-cut) is a legitimate
  optimization.
- **Hold violations are a different problem with different fixes.** Setup fails
  because a path is too *slow* — fix it with the techniques here. Hold fails
  because a path is too *fast* relative to clock skew, and the fix is buffer
  insertion during physical implementation, not RTL. The one RTL-level hold
  issue you can create yourself is a clock-domain crossing without a
  synchronizer (see [docs/20](20-synthesis-subset-and-gotchas.md) G22).

---

## 2. Reading a timing report

Every tool prints roughly the same thing. What to look for, in order:

```
Startpoint: u_ctrl/state_reg[2]          <-- where the path begins
Endpoint:   u_dp/acc_reg[31]             <-- where it must arrive
Path Group: clk
Path Type:  max                          <-- max = setup, min = hold

  Point                          Incr     Path
  ---------------------------------------------------
  state_reg[2]/CK                 0.00    0.00
  state_reg[2]/Q                  0.09    0.09  r    <-- T_cq
  U1234/Z                         0.11    0.20  f
  U1235/Z                         0.14    0.34  f         the logic
  ... 23 more levels ...                                  ^^^^^^^^^
  U1288/Z                         0.13    2.41  r
  acc_reg[31]/D                   0.00    2.41  r
  data arrival time                       2.41
  ---------------------------------------------------
  clock period                            2.00
  clock uncertainty              -0.08     1.92
  library setup time             -0.05     1.87
  data required time                      1.87
  ---------------------------------------------------
  slack (VIOLATED)                       -0.54
```

| Read this | To learn |
|---|---|
| **Slack** | how far off you are. `-0.05 ns` is a placement problem; `-0.54 ns` needs an RTL change |
| **Number of levels of logic** | the single most useful number. 25 levels at 500 MHz is hopeless; 4 levels failing means it is fanout or routing, not depth |
| **Startpoint / endpoint names** | which module, and whether it is control or data |
| **Incr column** | one cell taking 0.4 ns is a high-fanout net or a huge mux, not ordinary logic |
| **Whether the same endpoint appears in the top 50 paths** | a single slow *endpoint* means a local problem; a single slow *startpoint* fanning out to many endpoints means a fanout problem |

Useful queries:

```tcl
# Synopsys / Cadence
report_timing -max_paths 50 -nworst 5 -slack_lesser_than 0
report_timing -delay_type max -path_type full_clock_expanded
report_constraint -all_violators
all_fanout -flat -from [get_nets my_enable] ;# how many loads?

# Vivado
report_timing_summary
report_timing -max_paths 50 -slack_lesser_than 0 -sort_by group
report_high_fanout_nets -max_nets 20
report_design_analysis -logic_level_distribution
```

`report_design_analysis -logic_level_distribution` (or the equivalent histogram
in other tools) is the best single command for deciding whether you have a depth
problem or a routing problem.

---

## 3. Diagnose first: the path taxonomy

Match the symptom to the cause before choosing a fix.

| Symptom | Likely cause | Go to |
|---|---|---|
| Many levels of logic (>15 at a high clock) | genuine depth | [pipelining](21-pipelining.md), [§4](#4-logic-restructuring) |
| Few levels, large per-cell delays | high fanout | [§9](#9-fanout-and-replication) |
| Few levels, large *net* delays, spread endpoints | routing / congestion / distance | [§13](#13-physical-awareness-in-rtl) |
| One late input dominates a wide function | late-arriving signal | [§5](#5-late-arriving-signals) |
| Endpoint is an accumulator | a feedback loop you cannot pipeline | [docs/21 §8](21-pipelining.md#8-loops-cannot-be-pipelined), [§6](#6-redundant-number-systems) |
| Path starts or ends in a RAM | memory access time | [§10](#10-memory-paths) |
| Path is a long priority chain | linear structure | [§4](#4-logic-restructuring), [§8](#8-control-path-techniques) |
| Path goes through a wide mux with a slow select | decode on the select | [§8](#8-control-path-techniques) |
| Startpoint is a reset | reset tree | [§11](#11-reset-strategy) |
| Path crosses clock domains | should not be timed at all | [docs/20](20-synthesis-subset-and-gotchas.md) G22, [§12](#12-constraints-multicycle-and-false-paths) |
| Timing got worse after you pipelined it | reset is blocking retiming | [docs/21 §6](21-pipelining.md#6-retiming-let-the-tool-place-the-registers) |

---

## 4. Logic restructuring

Same function, shallower structure. These are free — no extra latency, usually
no extra area.

### Trees, not chains

```systemverilog
// O(N) deep.
always_comb begin
  acc = '0;
  foreach (a[i]) acc = acc + a[i];
end

// O(log N) deep, same adder count.
adder_tree #(.N(16), .W(16)) u_tree (.clk, .rst_n, .en(1'b1),
                                     .din_flat(a_flat), .dout(acc));
```

The same applies to any associative operation — `&`, `|`, `^`, `min`, `max`:

```systemverilog
// A chain of comparisons. Depth O(N).
always_comb begin
  m = a[0];
  for (int i = 1; i < N; i++) m = (a[i] > m) ? a[i] : m;
end

// Reduction operators are already trees, and $countones maps to a good
// adder tree. Prefer them over hand-written loops.
assign any_err   = |err_vec;        // one OR tree, not a chain
assign parity    = ^data;
assign n_active  = $countones(req);
```

### Reassociate to expose parallelism

```systemverilog
// Serial: a, then b, then c, then d. Depth 3.
assign y = ((a + b) + c) + d;

// Balanced: (a+b) and (c+d) in parallel. Depth 2.
assign y = (a + b) + (c + d);
```

Synthesis will usually do this for you, *when it is legal*. It is not legal for
floating point (rounding differs), and the tool may decline when widths differ
in a way that changes overflow behaviour. Writing the balanced form costs
nothing and removes the uncertainty.

### Factor common subexpressions out of a mux

```systemverilog
// Two adders, each on the critical path, one mux after them.
assign y = sel ? (a + b) : (a + c);

// One adder. The mux moved to the operand, where it is off the carry chain.
assign y = a + (sel ? b : c);
```

This is the most generally useful restructuring there is: **move the mux to the
narrow side of the expensive operator.** A 2:1 mux on a 32-bit operand is one
gate; a 2:1 mux after a 32-bit adder is also one gate, but it is *after* 32 bits
of carry propagation.

### Distribute a comparison

```systemverilog
// A full subtractor's worth of borrow propagation.
assign in_range = (addr >= BASE) && (addr < BASE + SIZE);

// When BASE and SIZE are aligned constants, it is just a bit compare.
// BASE = 32'h4000_0000, SIZE = 32'h1000_0000:
assign in_range = (addr[31:28] == 4'h4);
```

Aligning your address map to power-of-two boundaries turns every decoder in the
design from a pair of comparators into an equality check on a few bits. This is
a specification decision with a large downstream timing effect.

### Narrow before you operate

```systemverilog
// A 32-bit compare where only the low 8 bits can ever differ.
assign hit = (tag == req_tag);                  // 32-bit comparator

// If the upper bits are known equal by construction, say so.
assign hit = (tag[7:0] == req_tag[7:0]);        // 8-bit comparator
```

And the converse trap — do not *widen* unnecessarily. An unsized decimal literal
is at least 32 bits signed and will drag a narrow expression up to 32 bits:

```systemverilog
logic [7:0] a, b;
if (a + b > 200)      ...    // 32-bit add and 32-bit compare
if (a + b > 8'd200)   ...    // 8-bit (and note: this WRAPS -- see docs/17)
if ({1'b0,a} + {1'b0,b} > 9'd200) ...   // 9-bit, correct and narrow
```

See [docs/17](17-signed-unsigned-arithmetic.md#3-the-width-algorithm).

---

## 5. Late-arriving signals

Frequently one input to a block arrives much later than the others — a
comparison result, a hit/miss from a cache, a carry-out, a flag from another
module. The fix is to arrange the logic so that **the late signal passes through
as little as possible.**

### Push it to the last mux

```systemverilog
// `late` gates the address, so it sits in front of the whole decoder.
assign addr   = late ? alt_addr : base_addr;
assign result = decode(addr);          // late -> mux -> decoder. Slow.

// Decode both, select at the end. `late` now drives one mux and nothing else.
assign result_a = decode(base_addr);   // both computed in parallel,
assign result_b = decode(alt_addr);    //   off the critical path
assign result   = late ? result_b : result_a;
```

Cost: two decoders instead of one. That is the trade — **area for depth on the
late signal only.** It is the same idea as speculation ([§7](#7-precomputation-and-speculation)).

### Restructure a priority chain so the late signal is last

```systemverilog
// `late_sel` is evaluated first, so it feeds the whole chain.
always_comb begin
  if      (late_sel) y = d0;
  else if (sel1)     y = d1;
  else if (sel2)     y = d2;
  else               y = d3;
end

// Reorder so the late signal controls only the final mux. Requires knowing the
// selects are mutually exclusive -- assert it.
always_comb begin
  if      (sel1) y_early = d1;
  else if (sel2) y_early = d2;
  else           y_early = d3;
end
assign y = late_sel ? d0 : y_early;

a_excl: assert property (@(posedge clk) disable iff (!rst_n)
  $onehot0({late_sel, sel1, sel2}));
```

### Carry-select: the canonical example

A carry-select adder is exactly this technique applied to a carry. Compute the
upper half twice — once assuming carry-in 0, once assuming 1 — and let the
actual carry pick:

```systemverilog
// Split a 32-bit add so the lower half's carry-out only drives one mux.
logic [16:0] lo;
logic [15:0] hi0, hi1;
logic        cin_hi;

assign lo     = {1'b0, a[15:0]} + {1'b0, b[15:0]};
assign cin_hi = lo[16];
assign hi0    = a[31:16] + b[31:16];            // assume carry-in = 0
assign hi1    = a[31:16] + b[31:16] + 16'd1;    // assume carry-in = 1
assign sum    = {cin_hi ? hi1 : hi0, lo[15:0]};
```

You would not normally write this — the synthesis library has better adders —
but the *pattern* is worth internalizing, because it is how you fix any "one
input arrives late into a wide function" path.

---

## 6. Redundant number systems

When the critical path is a carry chain inside a loop, no amount of
restructuring helps, because the chain is the loop. Change the representation
instead: keep the value as an unresolved `sum + carry` pair, and do the single
carry-propagate add only where you actually need the number.

```systemverilog
// 3:2 compressor: value_in = a + b + c, value_out = sum + (carry << 1).
// Two gate levels, independent of width. No carry chain.
assign sum   = a ^ b ^ c;
assign carry = (a & b) | (b & c) | (a & c);
```

[`csa_accumulator.sv`](../examples/rtl/csa_accumulator.sv) applies it in
an accumulation loop; a Wallace or Dadda tree applies it to a multiplier's
partial products. Either way:

| | Ordinary accumulator | Carry-save accumulator |
|---|---|---|
| Loop delay | O(log W) at best | **two gate levels, any W** |
| Registers | 1 | 2 |
| Value visible directly | yes | no — needs one final add |
| Good when | you read the result often | you accumulate many times, read rarely |

Related ideas with the same flavour: **signed-digit representations** for fast
multipliers (Booth encoding), and **residue number systems** for very wide
addition chains. Both trade a resolution step at the end for a shorter inner
loop.

---

## 7. Precomputation and speculation

### Precompute what you can, when you can

If a value depends only on slowly changing state, compute it once and register
it rather than recomputing it on the critical path:

```systemverilog
// BASE changes only when the CSR is written, but this recomputes every cycle
// and the adder is in the address path.
assign addr = base_csr + offset;

// Precompute the parts that do not change per-transaction.
logic [31:0] base_q;
always_ff @(posedge clk) if (csr_write) base_q <= base_csr;
assign addr = base_q + offset;     // still an adder, but off the CSR path
```

The stronger version: if `offset` comes from a small set, precompute the whole
sum for each and mux:

```systemverilog
// Four possible offsets, known in advance -> four registered sums, one mux.
logic [31:0] addr_pre [0:3];
always_ff @(posedge clk)
  if (csr_write)
    for (int i = 0; i < 4; i++) addr_pre[i] <= base_csr + OFFSETS[i];
assign addr = addr_pre[sel];       // a mux, no adder
```

### Speculate: compute all outcomes, select late

```systemverilog
// Serial: wait for the comparison, then act on it.
assign is_gt  = (a > b);
assign result = is_gt ? f(a) : g(b);        // compare -> mux -> nothing else

// Speculative: f and g run in parallel with the compare.
assign fa     = f(a);
assign gb     = g(b);
assign is_gt  = (a > b);
assign result = is_gt ? fa : gb;            // compare -> one mux
```

This only helps if `f` and `g` do not themselves depend on the comparison, which
is the usual case. It costs an extra copy of the cheaper function.

### Know when it is a loss

Speculation buys depth with area, and area buys congestion. Two copies of a
small function is free; two copies of a multiplier array is a placement problem.
Use it on the *narrow* side: duplicate the decode, not the datapath.

---

## 8. Control-path techniques

### One-hot state, decoded selects

```systemverilog
// Binary state -> every consumer decodes it. The decoder is on every path.
typedef enum logic [2:0] { IDLE, REQ, WAIT, XFER, DONE } state_e;
assign bus_req = (state == REQ) || (state == XFER);     // comparator per use

// One-hot state -> consumers read a bit. No decode at all.
typedef enum logic [4:0] {
  IDLE = 5'b00001, REQ = 5'b00010, WAIT = 5'b00100,
  XFER = 5'b01000, DONE = 5'b10000
} state_e;
assign bus_req = state[1] | state[3];                   // one OR gate
```

One-hot costs one flop per state and buys a decode level on every consumer.
Below about 8–16 states it is usually the right choice, and on an FPGA (where
flops are plentiful and LUT depth is the constraint) it is almost always right.
[`fsm_onehot.sv`](../examples/rtl/fsm_onehot.sv) shows the full pattern with
`unique case (1'b1)`.

### Register FSM outputs

A combinational (Mealy) output puts the next-state logic *and* the output logic
in series on one path. Registering the output splits them:

```systemverilog
// Combinational output: state -> output logic -> consumer, all in one cycle.
always_comb bus_req = (state == REQ);

// Registered: the consumer sees a flop output directly. One cycle later.
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n) bus_req <= 1'b0;
  else        bus_req <= (next == REQ);      // decode NEXT, not current
```

Note `next`, not `state` — decoding the next state keeps the output aligned in
time with the state it describes. Compare
[`fsm_two_process.sv`](../examples/rtl/fsm_two_process.sv) and
[`fsm_one_process.sv`](../examples/rtl/fsm_one_process.sv).

### Priority chains: use the carry trick, or make it a tree

```systemverilog
// A loop that unrolls to an N-deep priority chain.
always_comb begin
  grant = '0;
  for (int i = 0; i < N; i++)
    if (!found && req[i]) begin grant = 1 << i; found = 1'b1; end
end

// The same function as one expression. The adder's CARRY CHAIN does the
// priority propagation, which maps to dedicated carry hardware on every
// FPGA and to a fast adder on ASIC.
assign grant = req & (~req + 1'b1);      // isolate the lowest set bit
```

[`arb_fixed.sv`](../examples/rtl/arb_fixed.sv) is that one line. For very wide
`N`, do it hierarchically: find the first non-zero group with the same trick,
then the first bit within it — a two-level tree instead of a 256-long chain.

### Avoid `unique`/`priority` as an optimization

They are **assertions with a synthesis side effect**. If the promise is wrong,
simulation reports it and synthesis silently assumes it anyway. Use a `default`
branch and let the tool prove exclusivity from the logic; use `unique` only
where you can actually prove one-hot and want the runtime check. Never use the
old `full_case`/`parallel_case` attributes — they have no runtime check at all.
See [docs/05](05-procedural-blocks-and-flow.md#5-unique-unique0-priority).

---

## 9. Fanout and replication

A flop driving 2000 loads scattered across the die cannot meet timing. There is
no logic on the path — the delay is the buffer tree and the wire. This is the
most common "but there's nothing on this path" violation, and it lands on
exactly the signals you least suspect: a global enable, a mode bit, a stall, an
FSM state bit feeding every lane.

### Let the tool do it first

```tcl
set_max_fanout 32 [current_design]          # Synopsys / Vivado
set_db max_fanout 32                        # Genus
```

Most tools will replicate registers automatically given a fanout limit. Try that
before hand-coding.

### Replicate by hand when you must

```systemverilog
// One copy per destination region. Consumers use THEIR OWN copy -- using
// dout[0] everywhere reintroduces the problem and wastes the flops.
fanout_replicate #(.WIDTH(1), .COPIES(4)) u_en_rep (
  .clk, .rst_n, .en(1'b1), .din(global_en), .dout(en_rep));

lane u_lane0 (.en(en_rep[0]), ...);
lane u_lane1 (.en(en_rep[1]), ...);
```

**The catch:** a set of flops with identical inputs is exactly what synthesis's
resource-sharing pass merges back together. Without `dont_touch` / `preserve`
the module is an expensive no-op:

```systemverilog
(* dont_touch = "true" *)      // Synopsys, Vivado
(* preserve *)                 // Intel Quartus
(* syn_preserve = "1" *)       // Synplify
logic [WIDTH-1:0] rep_q;
```

[`fanout_replicate.sv`](../examples/rtl/fanout_replicate.sv) carries all of them;
unknown attributes are ignored rather than an error, so the file is portable.

### Structural alternatives

- **Pipeline the broadcast.** A control signal that can tolerate a cycle of
  delay can go through a small distribution tree of registers — a 1-to-4 fanout
  at each of two levels reaches 16 regions with 2 cycles of latency and no
  fanout problem anywhere.
- **Do not broadcast at all.** If each lane can derive the condition locally
  from data it already has, that is strictly better than distributing it.
- **Push the decision later.** A stall that reaches every stage is worse than an
  elastic pipeline where backpressure propagates one stage per cycle
  ([docs/21 §7](21-pipelining.md#7-elastic-pipelines-and-handshakes)).

---

## 10. Memory paths

| Technique | Effect |
|---|---|
| **Turn on the RAM's output register** | one extra cycle, often 30–40% off the memory path. Infer it with one more pipeline register on `dout` |
| **Register the address** | address decode feeding a RAM is a classic critical path; cut it |
| **Bank the memory** | N banks of depth D/N: shorter word lines, smaller decoders, and N-way parallel access. Costs an address decode and an output mux |
| **Split wide memories** | two 32-bit RAMs beat one 64-bit RAM when only half is read |
| **Avoid the read-modify-write** | byte enables ([`ram_be.sv`](../examples/rtl/ram_be.sv)) instead of read-then-write |
| **Use a register file, not a RAM, for small fast storage** | under ~32 entries with 2+ read ports, flops with async read are faster and often smaller ([`regfile.sv`](../examples/rtl/regfile.sv)) |

```systemverilog
// Banking: the low address bits select the bank, so the decoder in each bank
// is log2(D/N) bits instead of log2(D).
localparam int BANKS = 4, BSEL = $clog2(BANKS);

logic [DW-1:0] bank_out [0:BANKS-1];

for (genvar b = 0; b < BANKS; b++) begin : g_bank
  ram_sp #(.DW(DW), .DEPTH(DEPTH/BANKS)) u_ram (
    .clk, .en(en && (addr[BSEL-1:0] == BSEL'(b))), .we,
    .addr (addr[AW-1:BSEL]),
    .din, .dout(bank_out[b]));
end

// Register the bank select alongside the RAM's own latency, then mux.
logic [BSEL-1:0] bank_sel_q;
always_ff @(posedge clk) bank_sel_q <= addr[BSEL-1:0];
assign dout = bank_out[bank_sel_q];
```

Note the `en` gating per bank: only the addressed bank is enabled, which is a
power win as well as a timing one.

---

## 11. Reset strategy

Reset choices have a large and often unnoticed effect on both timing and area.

| Choice | Timing effect |
|---|---|
| **Asynchronous reset** | the reset net is a high-fanout asynchronous signal; its *release* must be synchronized ([`reset_sync.sv`](../examples/rtl/reset_sync.sv)) or recovery/removal fails |
| **Synchronous reset** | reset becomes an ordinary timed path — it needs the same fanout care as any other high-fanout net, but no special recovery checks |
| **No reset on datapath registers** | removes them from the reset tree entirely, **and unblocks retiming** ([docs/21 §6](21-pipelining.md#6-retiming-let-the-tool-place-the-registers)) |

The single highest-value rule:

> **Reset the control path. Do not reset the data path.**

A 512-bit pipeline register does not need a reset — the valid bit travelling
beside it says whether its contents mean anything. Resetting it costs 512 flops'
worth of reset routing, makes every one of them a larger cell, and prevents the
tool from retiming the stage.

```systemverilog
// Control: reset it. A spurious valid out of reset injects garbage.
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n) valid_q <= 1'b0;
  else        valid_q <= valid_d;

// Data: do not. Contents are meaningless until valid says otherwise -- and
// this register can now be retimed.
always_ff @(posedge clk)
  if (en) data_q <= data_d;
```

Also: **use one reset polarity and style per clock domain.** A mix of active-high
and active-low, or sync and async, in the same domain produces a reset tree the
tool cannot balance.

---

## 12. Constraints: multicycle and false paths

Sometimes the path is fine and the *constraint* is wrong. Sometimes you convince
yourself of that and ship a bug. Both happen often enough to be worth being
careful about.

### Legitimate uses

```tcl
# A configuration register written once at boot and read by combinational
# logic everywhere. It genuinely does not need to meet single-cycle timing.
set_multicycle_path 4 -setup -from [get_cells cfg_reg*] -to [get_cells dp/*]
set_multicycle_path 3 -hold  -from [get_cells cfg_reg*] -to [get_cells dp/*]

# An asynchronous CDC path. The synchronizer handles it; timing analysis of the
# raw crossing is meaningless.
set_false_path -from [get_clocks clk_a] -to [get_clocks clk_b]

# A signal into a 2-flop synchronizer.
set_false_path -to [get_cells u_sync/sync_q_reg[0]]
```

Note the `-hold` line in the multicycle example. **Forgetting it is the classic
multicycle mistake**: relaxing setup by N cycles without adjusting hold tells
the tool the data may arrive up to N cycles *late*, and it will happily insert
hold buffers to make a path that should have been fast. Always specify both.

### Where it goes wrong

| Mistake | Consequence |
|---|---|
| `set_false_path` on a path that *is* real | works in simulation, fails in silicon, intermittently, at temperature |
| Multicycle without the matching `-hold` | hold violations, or gratuitous buffer insertion |
| A multicycle that assumes an enable the RTL does not actually guarantee | the path is exercised back-to-back once and fails |
| `set_false_path` used to silence a report you did not understand | the bug is still there, now invisible |

The rule: **a false path must be justified by a structural argument in the RTL,
not by the fact that it is failing.** If you cannot write down why the path can
never be exercised in a single cycle, it is not a false path. And if the RTL
guarantee is real, express it as an assertion so it stays true:

```systemverilog
// The constraint claims cfg_reg is stable for >= 4 cycles around any use.
// This is what keeps that claim honest as the design changes.
a_cfg_stable: assert property (@(posedge clk) disable iff (!rst_n)
  $changed(cfg_reg) |=> $stable(cfg_reg)[*3])
  else $error("cfg_reg changed faster than its multicycle constraint allows");
```

---

## 13. Physical awareness in RTL

Below a few hundred MHz this section does not matter much. Above that, it
dominates.

### Distance is delay

Two blocks that talk to each other should be adjacent. If they cannot be
(different corners of the die, a path across a memory macro), **put registers in
the path and accept the latency** — a pipelined interconnect is the only thing
that works over distance.

```systemverilog
// A long haul between two distant blocks. Insert skid buffers so the wire is
// broken into segments AND backpressure still works.
skid_buffer #(.DW(DW)) u_hop0 (.clk, .rst_n,
  .in_valid(src_valid), .in_data(src_data), .in_ready(src_ready),
  .out_valid(m_valid),  .out_data(m_data),  .out_ready(m_ready));

skid_buffer #(.DW(DW)) u_hop1 (.clk, .rst_n,
  .in_valid(m_valid),   .in_data(m_data),   .in_ready(m_ready),
  .out_valid(dst_valid),.out_data(dst_data),.out_ready(dst_ready));
```

A skid buffer is the right element for this rather than a plain register,
because it keeps the handshake intact in both directions.

### Hierarchy should follow the floorplan

Keep a block's logic in one module so the tool can place it together. Two
patterns that fight physical implementation:

- **Logic spread across the hierarchy.** A datapath whose stages live in
  different modules at different levels gets placed apart. Keep a pipeline in
  one module.
- **A module that exists only as a wrapper for wires.** It constrains placement
  for no benefit. Flatten it, or give it real content.

### Registered module boundaries

Making every module output registered is the single most effective structural
habit for timing closure at scale. It means:

- no combinational path crosses a hierarchy boundary, so each module can be
  timed, optimized, and even physically implemented independently;
- adding a module to a path costs a known cycle instead of an unknown delay;
- the boundary is a natural place for the tool to retime.

```systemverilog
// Every output is a flop output. Nothing combinational escapes.
module stage #(parameter int DW = 32) (
  input  var logic          clk,
  input  var logic          rst_n,
  input  var logic          valid_i,
  input  var logic [DW-1:0] data_i,
  output var logic          valid_o,
  output var logic [DW-1:0] data_o
);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) valid_o <= 1'b0;
    else        valid_o <= valid_i;

  always_ff @(posedge clk)
    data_o <= transform(data_i);         // no reset: retimable
endmodule
```

The cost is latency, and it is worth it almost every time.

### Congestion

Congestion shows up as unexpectedly large net delays and as placement failing to
converge. RTL causes:

- **Wide crossbars and all-to-all muxes.** An N×N crossbar's wiring grows as
  N². Above about 8×8, pipeline it or use a multi-stage network.
- **Wide broadcast buses.** See [§9](#9-fanout-and-replication).
- **Duplicated wide datapaths from over-eager speculation.** See
  [§7](#7-precomputation-and-speculation).
- **A large memory in the middle of a datapath**, which the datapath then has to
  route around.

---

## 14. Area efficiency

### Resource sharing — trade throughput for area

If a unit is used on fewer than 100% of cycles, one shared copy plus muxes beats
several dedicated copies:

```systemverilog
// Two multipliers, each used half the time.
assign p0 = a0 * b0;
assign p1 = a1 * b1;

// One multiplier, time-multiplexed. Half the area, half the throughput.
assign p = (phase ? a1 : a0) * (phase ? b1 : b0);
always_ff @(posedge clk) begin
  phase <= ~phase;
  if (!phase) p0_q <= p;
  else        p1_q <= p;
end
```

Synthesis does this automatically for operators inside mutually exclusive
branches of the same `case`/`if` — which is a good reason to write mutually
exclusive operations in one `case` rather than as parallel `assign`s:

```systemverilog
// The tool can share ONE adder here, because the branches are exclusive.
always_comb begin
  unique case (op)
    OP_ADD: y = a + b;
    OP_SUB: y = a - b;
    OP_INC: y = a + 1;
    default: y = a;
  endcase
end
```

### Folding — reuse one stage over many cycles

A 64-tap FIR can be 64 multipliers at one sample per cycle, or 8 multipliers at
one sample per 8 cycles, or 1 multiplier at one sample per 64 cycles. Pick from
the throughput requirement, not from the structure of the equation.

### Memory instead of flops

Above roughly 64–128 bits of storage that does not need to be read all at once,
a RAM is dramatically smaller than flops — often 10× or more per bit. The
crossover is lower than people expect. A 32-entry × 32-bit shift register is
1024 flops; as a RAM plus a pointer it is one small block and a counter.

### Prune widths

Every bit of unnecessary width costs a flop and a bit of every adder it touches.
Derive widths from the actual range rather than rounding up to a convenient
number — that is what the guard-bit analysis in
[docs/18](18-fixed-point-arithmetic.md#3-growth-and-how-to-bound-it) is for.

```systemverilog
// Rounded up "to be safe": 32 bits everywhere.
logic [31:0] acc;

// Derived: exactly what the arithmetic needs, and self-documenting.
localparam int unsigned PW    = DW + CW;
localparam int unsigned GUARD = $clog2(NTAP);
localparam int unsigned ACCW  = PW + GUARD;
logic signed [ACCW-1:0] acc;
```

### Let constants propagate

A parameterized module instantiated with constant inputs will have that logic
optimized away — so write the general module and specialize by parameter, rather
than writing several variants. Unused generate branches cost nothing:

```systemverilog
// The unselected branch is not elaborated. This is free specialization.
if (IMPL == FAST) begin : g_impl  fast_unit u (.*);  end
else              begin : g_impl  small_unit u (.*); end
```

---

## 15. Power efficiency

Dynamic power is `α · C · V² · f` — activity × capacitance × voltage² ×
frequency. From RTL you control **activity** and, indirectly, **capacitance**.

### Clock gating — the big one

A gated clock stops both the flop's internal clock power and any downstream
switching. Do not write the gate yourself:

```systemverilog
// WRONG: a glitchy combinational clock. Never do this.
assign gclk = clk & en;
always_ff @(posedge gclk) q <= d;

// RIGHT: a clock enable. The tool inserts a proper integrated clock-gating
// cell, which is glitch-free by construction and gets clock-tree treatment.
always_ff @(posedge clk) if (en) q <= d;
```

Write the enable, let the tool insert the cell. Then help it:

- **Group registers that share an enable.** A clock-gating cell has a cost;
  it pays off across 8+ flops, not across 2. Registers with the same enable in
  the same module get one cell.
- **Gate coarsely as well as finely.** One enable for a whole idle block beats
  per-register enables inside it.
- **Make the enable available.** If the condition exists but is buried, hoist it.

### Operand isolation

Stop a wide datapath from switching when nobody wants its result:

```systemverilog
// A multiplier behind a mux computes on every cycle whether or not the answer
// is used. Hold its operands steady and the array goes quiet.
operand_isolation #(.AW(18), .BW(18), .ZERO_NOT_HOLD(1'b0)) u_iso (
  .clk, .rst_n, .result_used(mul_selected), .a, .b, .product);
```

Two variants, and the difference matters:

| `ZERO_NOT_HOLD` | Behaviour | Best when |
|---|---|---|
| `1` | force operands to `0` when idle; combinational | idle periods are long (one transition in, one out) |
| `0` | latch the last operands; registered | intermittent use (no transitions at all while idle) |

Caveat: the gate is *on the datapath*, so it adds a gate of delay to a path that
may already be critical. If the block is small or rarely idle, this is a net
loss. Measure. See [`operand_isolation.sv`](../examples/rtl/operand_isolation.sv).

### Reduce switching in the encoding

```systemverilog
// A binary counter used only as a CDC pointer flips up to W bits per step.
// Gray code flips exactly one -- less switching, and it is the correct choice
// for crossing a clock domain anyway (docs/20 G22).
gray_counter #(.W(8)) u_ptr (.clk, .rst_n, .en, .bin(bin), .gray(gray));
```

Other activity reductions worth knowing:

- **Bus inversion / sign-magnitude for data that hovers near zero.** A two's
  complement value oscillating around 0 toggles all its high bits
  (`0x0001 → 0xFFFF`); sign-magnitude does not.
- **Do not enable memories you are not reading.** Per-bank `en` gating (see
  [§10](#10-memory-paths)) is a large saving in a banked memory.
- **Register the inputs of a slow, glitchy block.** Glitches propagate and each
  one costs power; a register stops them.

### Leakage and voltage

Mostly not RTL decisions — multi-Vt cell selection, power gating, and voltage
islands are implementation choices. The RTL-level contribution is to make the
design *partitionable*: keep a block that can be powered down in its own module
with registered, enumerable boundaries.

---

## 16. The workflow

```
 1. Get a synthesis run with real constraints. Estimates from RTL are worthless;
    the tool's timing report is the only ground truth.

 2. Read the LOGIC LEVEL DISTRIBUTION, not just the worst path.
      many levels        -> depth problem      -> pipeline, restructure
      few levels, slow   -> fanout or routing  -> replicate, floorplan

 3. Fix the worst PATH GROUP, not the worst path. Fifty failing paths that share
    a startpoint are one problem, not fifty.

 4. Prefer fixes in this order:
      a. constraints that were wrong (a real false path, a missing clock group)
      b. structural RTL   (restructure, move a mux, balance a tree)
      c. pipelining       (costs latency; needs latency matching everywhere)
      d. replication      (costs area and can cost congestion)
      e. physical         (floorplan, hierarchy, retiming settings)
      f. relaxing the clock

 5. Re-run. A fix that moves the critical path somewhere else has told you
    something; a fix that does not move it at all means you fixed the wrong path.

 6. Stop when you have positive slack with margin. Closing to exactly 0.00 ns
    means the next unrelated edit breaks it.
```

The most common process failure is skipping step 1 — optimizing RTL based on a
guess about what is slow. The second most common is skipping step 5.

---

## 17. Anti-patterns

| Anti-pattern | Why it is wrong |
|---|---|
| `assign gclk = clk & en;` | glitchy clock. Use a clock enable |
| `(* full_case, parallel_case *)` | tells synthesis something the simulator does not model, with no runtime check |
| `set_false_path` to silence a report | the path is still real; now the bug is invisible |
| `set_multicycle_path` without `-hold` | creates hold violations or gratuitous buffering |
| Resetting every register "to be safe" | costs area and reset routing, and blocks retiming |
| Async reset with an unsynchronized release | flops leave reset on different cycles |
| Per-bit synchronizers on a multi-bit bus | bits arrive on different cycles; the receiver sees values never sent |
| Adding pipeline stages without matching latencies | the most common functional bug in pipelined designs |
| Registering `valid`/`data` but not using a skid buffer | passes every data check, halves throughput |
| Hand-written buffer trees | the tool does this better; you just blocked it from doing so |
| Optimizing before synthesizing | you will speed up a path that was not critical |
| Rounding all widths up to 32 bits | flops and adder bits you are paying for and never use |
| Hierarchy that does not match the floorplan | placement cannot group what the netlist has scattered |
| `unique case` where exclusivity is not provable | sim/synth mismatch waiting for the one input pattern that breaks it |

---

## See also

- [docs/21: Pipelining](21-pipelining.md) — cutting long paths, and the
  latency-matching discipline that makes it safe
- [docs/05: Procedural blocks](05-procedural-blocks-and-flow.md) — FSM styles,
  latch avoidance, reset templates
- [docs/17: Signed and unsigned arithmetic](17-signed-unsigned-arithmetic.md) —
  width growth, and not paying for bits you do not need
- [docs/18: Fixed point](18-fixed-point-arithmetic.md) — guard-bit budgets, the
  principled way to size a datapath
- [docs/20: Synthesis subset and gotchas](20-synthesis-subset-and-gotchas.md) —
  the 25 numbered gotchas, and lint rules worth enforcing
