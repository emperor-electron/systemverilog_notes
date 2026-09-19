# Structural Design Techniques

Techniques for getting a function into hardware *cheaply* — by choosing a
structure rather than writing the obvious operator and hoping synthesis rescues
it. Most of these replace something expensive (a divider, a sort, a decoder,
a table of flops) with something that is almost free.

The recurring theme: **move work from run time to elaboration time, and from
arithmetic into structure.**

Companion code, all verified:
[`bin2bcd.sv`](../examples/rtl/bin2bcd.sv) ·
[`mul_const.sv`](../examples/rtl/mul_const.sv) ·
[`div_const.sv`](../examples/rtl/div_const.sv) ·
[`sort_network.sv`](../examples/rtl/sort_network.sv) ·
[`ring_counter.sv`](../examples/rtl/ring_counter.sv) ·
[`srl_delay.sv`](../examples/rtl/srl_delay.sv) ·
[`rom_table.sv`](../examples/rtl/rom_table.sv) ·
[`useq.sv`](../examples/rtl/useq.sv) ·
simulated by [`techniques_tb.sv`](../examples/tb/techniques_tb.sv),
proved in [`formal/`](../formal/)

---

## Contents

- [1. Elaboration-time computation](#1-elaboration-time-computation)
- [2. Multiply by a constant](#2-multiply-by-a-constant)
- [3. Divide by a constant](#3-divide-by-a-constant)
- [4. Binary to BCD: double dabble](#4-binary-to-bcd-double-dabble)
- [5. Sorting networks](#5-sorting-networks)
- [6. Counters that are not binary counters](#6-counters-that-are-not-binary-counters)
- [7. Shift registers in LUTs](#7-shift-registers-in-luts)
- [8. Table-driven and microcoded control](#8-table-driven-and-microcoded-control)
- [9. Choosing between them](#9-choosing-between-them)

---

## 1. Elaboration-time computation

The elaborator is a full programming language that runs before synthesis sees
anything. Whatever it computes becomes a constant, and constants are free.

Three ways to get a table into RTL, worst to best:

| Method | Problem |
|---|---|
| `$readmemh("tbl.hex")` | an external file that can be lost, can drift from the script that generated it, and forces you to archive the generator too |
| a literal array | correct, unreadable, and wrong the moment a parameter changes |
| **a constant function** | the derivation *is* the source; change a parameter and the table follows |

```systemverilog
// A reciprocal table, 1/x in Q(FRAC). The elaborator runs the division; the
// hardware is a lookup table. Full version: examples/rtl/rom_table.sv
function automatic logic [DW-1:0] recip(input int unsigned i);
  logic [63:0] num;
  if (i == 0) begin
    recip = '1;                                 // 1/0 -> saturate
  end else begin
    num   = (64'd1 << FRAC) + (64'(i) >> 1);    // +i/2 rounds to nearest
    recip = DW'(num / 64'(i));
  end
endfunction

logic [DW-1:0] rom [0:(1<<AW)-1];
for (genvar i = 0; i < (1 << AW); i++) begin : g_init
  localparam logic [DW-1:0] E = recip(i);       // folded at elaboration
  assign rom[i] = E;
end
```

The `localparam` per entry is worth the extra line: it makes the constant-ness
explicit, so a reviewer can see at a glance that no division reaches the
hardware.

The same trick already appears elsewhere in this repo:
[`crc_parallel.sv`](../examples/rtl/crc_parallel.sv) unrolls a bit-serial CRC
into an XOR network, [`cordic_sincos.sv`](../examples/rtl/cordic_sincos.sv)
generates its arctangent table from the documented formula, and
[docs/18](18-fixed-point-arithmetic.md#7-a-complete-parameterized-package)
quantizes `real` coefficient literals into fixed-point constants.

### Two caveats

- `real` arithmetic is fine in a constant function — it happens in the
  elaborator. It is *not* fine anywhere a signal is involved.
- Elaboration-time functions are exactly where tool subsets bite hardest.
  Yosys's open-source frontend rejects `return`, and a local variable with an
  initialiser, inside a function. Writing `f = expr;` instead of `return expr;`
  costs nothing and keeps the module usable in formal — see
  [docs/25](25-formal-verification-with-sby.md).

---

## 2. Multiply by a constant

A constant multiply is a sum of shifted copies. No multiplier required.

```systemverilog
y = x * 10;                       // what you write
y = (x << 3) + (x << 1);          // what it costs: one adder
```

Two encodings, with very different adder counts:

| Encoding | Terms | `C = 7` | `C = 255` |
|---|---|---|---|
| **Binary** | one per set bit — `popcount(C)` | 3 | 8 |
| **CSD** (canonical signed digit) | terms may be *subtracted* | **2** | **2** |

Canonical signed digit — also called non-adjacent form — collapses every run of
ones into a single subtract-and-carry:

```
  7 = 0b0111  ->  8 - 1        = (x<<3) - x
 15 = 0b1111  ->  16 - 1       = (x<<4) - x
255 = 0b11111111 -> 256 - 1    = (x<<8) - x
```

The recoding is a few lines, and it runs in the elaborator:

```systemverilog
// Repeatedly: if the low bit is set, emit a digit. ...11 becomes a SUBTRACT
// with a carry into the next position; ...01 becomes an ADD.
// Full version: examples/rtl/mul_const.sv
while (v != 0 && i < MW) begin
  if (v[0]) begin
    if (v[1]) v = v + 1;                              // subtract here, carry up
    else      begin add_mask[i] = 1'b1; v = v - 1; end // add here
  end
  v = v >> 1;
  i = i + 1;
end
```

Then the datapath is one shifted term per set mask bit:

```systemverilog
always_comb begin
  acc = '0;
  for (i = 0; i < MW; i = i + 1) begin
    // Intermediates may go NEGATIVE when a subtract precedes a larger add.
    // Harmless: two's complement addition is exact modulo 2^OUT_W and the true
    // product fits, so the final value is right regardless of term order.
    if (ADD_MASK[i]) acc = acc + (OUT_W'(din) << i);
    if (SUB_MASK[i]) acc = acc - (OUT_W'(din) << i);
  end
end
```

### When to bother

Synthesis usually does this itself when it sees `x * 8'd7`. Write it out when:

- you want the CSD form **guaranteed** rather than hoped for;
- the constant arrives as a parameter the tool will not treat as constant;
- you need the adder count up front for an area budget;
- the multiplier count is the binding constraint (a filter with many fixed
  coefficients — see [`fir_systolic.sv`](../examples/rtl/fir_systolic.sv)).

`mul_const` is **proved exhaustively** against `*` for every 8-bit input, for
every constant tested — and the CSD and binary encodings are proved equal to
each other, which is the actual claim being made.

---

## 3. Divide by a constant

A variable divider is a multi-cycle machine
([`div_restoring.sv`](../examples/arith/div_restoring.sv)). Dividing by a
*constant* needs none: multiply by a fixed-point reciprocal and shift.

```
q = floor(n / D)   ==   (n * M) >> S      for a suitable M and S
```

Getting `M` and `S` right so this is **exact** — not approximate, not off by one
near multiples of `D` — is the whole problem. The construction
(Granlund & Montgomery; Hacker's Delight ch. 10):

```
L = ceil(log2(D))
S = W + L
M = ceil(2^S / D)          == floor(2^S / D) + 1   for D not a power of two
```

Then `floor(n*M / 2^S) == floor(n/D)` for every `0 <= n < 2^W`. The rounding
*up* in `M` is what makes the truncation never fall the wrong way.

```systemverilog
localparam int unsigned L   = clog2_ceil(D);
localparam int unsigned S   = W + L;
localparam int unsigned MWD = W + 2;      // M < 2^(W+1), so W+2 is ample
localparam int unsigned PW  = S + W;      // see the warning below

localparam logic [MWD-1:0] M = MWD'(((64'd1 << S) / 64'(D)) + 64'd1);

logic [PW-1:0] prod;
assign prod = num * M;
assign quot = prod[S +: W];               // >> S, keep W bits
assign rem  = num - W'(quot * W'(D));     // itself a constant multiply
```

> **The product register must reach the top of the shift, not merely hold the
> product.** The result is taken from `prod[S +: W]`, so `prod` needs `S + W`
> bits. Sizing it as `W + MWD` is enough for the product's *value* but leaves
> the part-select reading past the top whenever `L > 2`, which silently returns
> zeros. This was a real bug in the first version of `div_const.sv`; formal
> found it immediately, and random simulation would have too, because it fails
> for *every* input. The subtler failure — an off-by-one in `M` or `S` that
> breaks only inputs near multiples of `D` — is the one only a proof catches.

Cost: one `W × (W+2)` multiply (one DSP block) and a shift, versus `W` cycles of
a restoring divider. If `D` is a power of two it degenerates to wiring.

`div_const` is **proved exhaustively** for `D` = 1, 2, 3, 5, 7, 8, 10, 11, 12,
100, 255 and 1000 at `W = 16` — every one of 65536 inputs per divisor, proved
rather than enumerated.

### Signed division by a constant

Same idea, with two corrections: the reciprocal must be sign-extended, and
SystemVerilog's signed division truncates toward zero while the shift floors
toward −∞ (see
[docs/17](17-signed-unsigned-arithmetic.md#division-and-modulus)). The fix is to
add `1` to the quotient when the dividend is negative and the division was
inexact. Get that wrong and `-1/3` comes out as `-1` instead of `0`.

---

## 4. Binary to BCD: double dabble

Displaying a number in decimal needs division by 10. For a display update, a
divider is absurd.

**Double dabble** (shift-and-add-3) does it with an adder and a shift per bit:

```
for each bit of the input, MSB first:
    for each BCD digit:  if digit >= 5, add 3
    shift the whole {bcd, bin} register left by one
```

Why 3: doubling a digit `d >= 5` must produce a carry into the next digit —
the result should be `2d - 10` with a carry out. A plain shift gives `2d`.
Pre-adding 3 makes the shift produce `2d + 6`, which is exactly
`(2d - 10) + 16` — the correct low digit, plus a carry out of the nibble.

```systemverilog
// Unrolled: pure combinational logic. Full version: examples/rtl/bin2bcd.sv
always_comb begin
  acc = '0;
  for (i = IN_W - 1; i >= 0; i = i - 1) begin
    for (d = 0; d < DIGITS; d = d + 1)
      if (acc[d*4 +: 4] >= 4'd5)
        acc[d*4 +: 4] = acc[d*4 +: 4] + 4'd3;
    acc = {acc[DIGITS*4-2:0], bin[i]};
  end
end
```

Folded in time it is one adder and one shift register, `IN_W` cycles — which is
what a display refresh actually wants.

Digit count: `floor(IN_W * log10(2)) + 1`, computable with the integer ratio
`30103/100000`:

```systemverilog
parameter int unsigned DIGITS = (IN_W * 30103) / 100000 + 1;
```

**Two properties, and checking only the first is a common mistake:** every
output nibble must be a legal digit (0–9), *and* the digits read as decimal must
equal the input. A converter that clamped each digit to 9 satisfies the first; a
carelessly written second check is satisfied by producing `0x0A` for ten. Both
are proved in [`formal/bin2bcd_fv.sv`](../formal/bin2bcd_fv.sv).

---

## 5. Sorting networks

A software sort has data-dependent control flow. Hardware cannot, without a
sequencer. A **sorting network** is a fixed mesh of compare-exchange cells: no
loop, no control, no variable latency, and it pipelines trivially.

```
odd-even transposition, N = 4:

   stage 0    stage 1    stage 2    stage 3
  ┌──┬──┐              ┌──┬──┐
0─┤     ├──────────────┤     ├────────────── 0   (smallest)
  │ CE  │    ┌──┬──┐   │ CE  │    ┌──┬──┐
1─┤     ├────┤     ├───┤     ├────┤     ├─── 1
  └──┴──┘    │ CE  │   └──┴──┘    │ CE  │
  ┌──┬──┐    │     │   ┌──┬──┐    │     │
2─┤     ├────┤     ├───┤     ├────┤     ├─── 2
  │ CE  │    └──┴──┘   │ CE  │    └──┴──┘
3─┤     ├──────────────┤     ├────────────── 3   (largest)
  └──┴──┘              └──┴──┘
```

Each stage compares alternating adjacent pairs: even stages `(0,1)(2,3)…`, odd
stages `(1,2)(3,4)…`. Depth `N`, comparators `N(N-1)/2`.

```systemverilog
// Every lane must be driven in every stage, including the ones not paired --
// otherwise always_comb infers a latch. The three-way generate-if covers it.
for (genvar p = 0; p < int'(N); p++) begin : g_stage
  for (genvar i = 0; i < int'(N); i++) begin : g_lane
    if (((i % 2) == (p % 2)) && (i + 1 < int'(N))) begin : g_lo
      always @* cur[p+1][i] = (cur[p][i] <= cur[p][i+1]) ? cur[p][i] : cur[p][i+1];
    end else if ((i > 0) && (((i-1) % 2) == (p % 2))) begin : g_hi
      always @* cur[p+1][i] = (cur[p][i-1] <= cur[p][i]) ? cur[p][i] : cur[p][i-1];
    end else begin : g_pass
      always @* cur[p+1][i] = cur[p][i];
    end
  end
end
```

### Better networks

| Network | Depth | Comparators | Use |
|---|---|---|---|
| Odd-even transposition | `N` | `N(N-1)/2` | small `N`, obvious correctness |
| **Batcher odd-even merge** | `O(log²N)` | `O(N log²N)` | the practical choice above `N ≈ 8` |
| **Bitonic** | `O(log²N)` | `O(N log²N)` | regular wiring, GPU/FFT-friendly |
| AKS | `O(log N)` | — | theoretical only; constants are enormous |

For `N = 16`, Batcher is 10 stages against 16 — and the gap widens fast.

### The 0-1 principle: why formal is the right tool here

**Knuth's 0-1 principle: a comparator network sorts every input sequence if and
only if it sorts every sequence of 0s and 1s.**

So proving the network for `W = 1` proves it for *every* element width — 8-bit,
32-bit, floating-point keys, anything the comparator orders consistently.

That matters because exhaustive simulation of a 9-element 8-bit network is 2⁷²
vectors. At `W = 1` the entire input space is 2⁹ = 512 patterns, and the
principle carries the result to all widths for free. That is what
[`formal/sort_network_fv.sv`](../formal/sort_network_fv.sv) does, and it is why
that proof is *complete* rather than a sample.

Two properties are needed, not one: **sortedness** and **multiset
preservation**. A network that overwrote every element with zero would pass
sortedness alone.

The usual reason to want this is a **median filter** — `N = 9` for a 3×3 image
kernel — where only `dout[N/2]` is used and much of the network can then be
pruned by the tool.

---

## 6. Counters that are not binary counters

A binary counter plus a decoder costs `log2(N)` flops, a carry chain, and a
decoder at every consumer. Sometimes something else is cheaper.

| Counter | Flops | Decode | Good for |
|---|---|---|---|
| Binary | `log2 N` | needed everywhere | when you need the *value* |
| **Ring (one-hot)** | `N` | **none** — read your bit | `N ≲ 16`, especially on FPGA |
| **Johnson (twisted ring)** | `N/2` | 2-input decode | half the flops of a ring |
| **Gray** | `log2 N` | needed | CDC pointers, low switching ([docs/22](22-timing-closure-and-optimization.md)) |
| **LFSR** | `log2 N` | needed | when the *order* does not matter |

### Ring counter, and self-correction

```systemverilog
// A plain rotate preserves whatever it starts with -- so a single upset leaves
// it permanently wrong, possibly all-zero and silently dead.
assign inject = SELF_CORRECT ? (~|q[N-2:0]) : q[N-1];

always_ff @(posedge clk or negedge rst_n)
  if      (!rst_n) q <= {{(N-1){1'b0}}, 1'b1};
  else if (en)     q <= {q[N-2:0], inject};
```

`~|q[N-2:0]` is 1 exactly when the lower `N-1` bits are empty. In normal one-hot
operation that is identical to rotating; from **any** illegal state it recovers
within `N` cycles, because extra bits shift out of the top with zeros behind
them, and once the low bits are empty a fresh 1 is injected.

Cost: one `N-1` input NOR. Benefit: no unreachable dead state — which matters
for SEU tolerance and for DFT, because a state machine that can lock up is one
scan cannot always get out of ([docs/24](24-dft-clocking-and-x-discipline.md)).

### The LFSR-as-counter trick

If you need `N` distinct states and do not care what *order* they come in — a
refresh counter, a test-pattern index, a hash probe sequence, a cache-way
victim selector — an LFSR is smaller and faster than a binary counter, because
it has **no carry chain**. See
[`lfsr_galois.sv`](../examples/rtl/lfsr_galois.sv), whose Galois form keeps one
XOR on the critical path regardless of width.

The catch: it never visits the all-zero state, so the period is `2^W - 1`, not
`2^W`. If you need a power-of-two period, add the zero state explicitly or use a
binary counter.

### Proving it

One-hot-ness is **not** provable as a plain invariant by induction — and
understanding why is instructive. Induction starts from an *arbitrary* state
satisfying the assertions, and for a self-correcting counter non-one-hot states
are real states it is designed to recover from. The property must be split:

- **preservation** (inductive): if it was one-hot, it stays one-hot;
- **base case** (BMC from reset): it actually *is* one-hot.

Together those give one-hot for every *reachable* state, which is what the
design promises. See
[docs/25 §6](25-formal-verification-with-sby.md#6-when-induction-fails).

---

## 7. Shift registers in LUTs

An FPGA LUT can be configured as a 16- or 32-stage shift register — Xilinx
SRL16/SRL32E, Intel's ALM shift mode. **One LUT for 16 or 32 stages of a 1-bit
delay, instead of 16 or 32 flip-flops.**

A 32-bit bus delayed by 32 cycles is 1024 flops written the obvious way, or 32
LUTs as an SRL. That is a 16–32× reduction on what is otherwise pure overhead.

**Three conditions, all easy to break:**

1. **No reset.** An SRL has no reset input. One `if (!rst_n) sr <= '0;` and the
   tool falls back to flip-flops. This is the usual reason an SRL fails to
   appear.
2. **No intermediate taps.** Only the last stage may be read. Reading `sr[3]` of
   a 16-deep line forces the whole thing into flops, or splits it.
3. **One common enable, or none.** Per-stage enables cannot map.

```systemverilog
// One independent shift register per bit -- a packed vector shifted as a whole
// is the pattern the inference rule looks for.
for (genvar b = 0; b < int'(WIDTH); b++) begin : g_bit
  logic [DEPTH-1:0] sr;
  always_ff @(posedge clk)        // deliberately NO reset: condition 1
    if (en) sr <= {sr[DEPTH-2:0], din[b]};
  assign dout[b] = sr[DEPTH-1];   // only the last stage: condition 2
end
```

Condition 1 is the same rule as **"reset the control path, not the data path"**
from [docs/21](21-pipelining.md#3-latency-matching), arrived at from a
completely different direction. A datapath delay line needs no reset because the
valid bit beside it carries the meaning — and here that also buys a 16×
area reduction.

**When not to use it:** an SRL is not resettable and not readable mid-line, so
it cannot hold state you need to inspect or clear. Use
[`pipe_delay`](../examples/rtl/pipe_delay.sv) when you need either. On ASIC
there is no SRL and this degenerates to an ordinary shift register — which is
fine, just not a win.

---

## 8. Table-driven and microcoded control

A `case`-statement FSM is right up to roughly 15 states. Past that it stops being
readable, every new state touches both the next-state logic and the output
logic, and the output decode grows into a critical path.

A **microcoded sequencer** stores each step as a ROM word whose fields *are* the
control outputs plus the next-address information.

```systemverilog
typedef struct packed {
  logic           bus_req;    // control outputs...
  logic           wr_en;
  logic           done;
  logic           branch;     // if the selected condition holds, go to targ
  logic [2:0]     csel;       // which condition
  logic [PCW-1:0] targ;
} uword_t;
```

The microprogram then reads as a listing of the protocol:

```systemverilog
//     bus_req wr_en  done   branch csel   targ
0: begin end                                              // idle / entry
1: w = '{1'b1,   1'b0,  1'b0,  1'b0,  3'd5,  PCW'(0)};    // request bus
2: w = '{1'b1,   1'b0,  1'b0,  1'b1,  3'd2,  PCW'(2)};    // wait !grant
3: w = '{1'b1,   1'b1,  1'b0,  1'b0,  3'd5,  PCW'(0)};    // write
4: w = '{1'b1,   1'b0,  1'b0,  1'b1,  3'd3,  PCW'(4)};    // wait !ack
5: w = '{1'b0,   1'b0,  1'b1,  1'b0,  3'd5,  PCW'(0)};    // signal done
6: w = '{1'b0,   1'b0,  1'b0,  1'b1,  3'd4,  PCW'(6)};    // halt (spin)
default:
   w = '{1'b0,   1'b0,  1'b0,  1'b1,  3'd4,  PCW'(6)};    // trap -> halt
```

What this buys:

- **adding a step is a table edit**, not a logic edit;
- **control outputs are a ROM read** — no decode depth;
- the sequence is *data*, so it can be diffed against the protocol document line
  by line;
- the same engine runs any sequence, so it is reusable;
- `default` traps, so no address can wander outside the microprogram.

This is how DMA engines, memory-controller initialisation sequences and link
training are actually built.

> **A wait state is "branch back to myself while the condition is NOT yet
> true".** That is why the condition mux provides *inverted* selects. The first
> version of the table above branched on the condition being true, so every wait
> state fell straight through and the sequencer ran the whole protocol in six
> cycles regardless of the handshakes — every data check still passed. If you
> take one thing from this section, take that the *table* now needs testing as
> carefully as logic would.

**The cost is indirection.** A bug is now either in the engine or in the table,
and a waveform shows a program counter instead of a named state. Worth it past
the crossover, a liability below it.

---

## 9. Choosing between them

| You need | Reach for | Instead of |
|---|---|---|
| a table of constants | a constant **function** | `$readmemh`, literal arrays |
| `× C`, C constant | shift-add, CSD-encoded | a multiplier |
| `÷ C`, C constant | reciprocal multiply | a divider |
| `÷ 2^k` | a shift | anything |
| decimal display | double dabble | `÷ 10` |
| median / small sort | a sorting network | a sequencer |
| `≤ 16` states, no value needed | a ring counter | binary counter + decoder |
| `N` states, order irrelevant | an LFSR | a binary counter |
| a long FPGA delay line | an SRL (no reset, no taps) | flip-flops |
| `> 15` protocol steps | microcode | a `case` FSM |
| a CDC pointer | Gray code | binary |

And the two rules that cut across all of them:

1. **If a parameter determines it, compute it at elaboration.** The elaborator
   is free; the hardware is not.
2. **Prefer a fixed structure to a sequencer.** A network, a tree or a table has
   no control logic to get wrong, no variable latency to match, and no hazards
   — see [docs/21 §9](21-pipelining.md#9-hazards-and-forwarding).

---

## See also

- [docs/21: Pipelining](21-pipelining.md) — latency matching, retiming, and why
  loops resist pipelining
- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — logic
  restructuring, fanout, area and power
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) — the
  rules that make a design testable
- [docs/25: Formal with sby](25-formal-verification-with-sby.md) — how the
  proofs referenced here are set up, and what the tool cannot read
- [docs/18: Fixed point](18-fixed-point-arithmetic.md) — the arithmetic these
  structures operate on
