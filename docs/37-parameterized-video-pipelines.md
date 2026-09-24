# Parameterized Video Pipelines

A video processing block is almost always described by three numbers:

| Parameter | Meaning | Typical |
|---|---|---|
| `N` — pixels per clock | throughput vs clock rate trade | 1, 2, 4, 8 |
| `P` — components per pixel | greyscale, RGB, RGBA, YCbCr | 1, 3, 4 |
| `B` — bits per component | bit depth | 8, 10, 12, 16 |

They multiply into one number the bus cares about — `TDATA` is `N*P*B` bits wide
— and that flattening is the whole problem. A 4-pixel 10-bit RGB stream is 120
bits of `TDATA` in which component 1 of pixel 2 lives at bits 79:70, and no
amount of care makes `s_tdata[79:70]` readable or re-derivable when `N` changes.

This document is about writing that code once, generically, so it is
synthesizable for any `N`, `P` and `B` and readable at all of them. The tool is
the **unpacked array**, used inside the module while the ports stay flat.

Companion code, all verified:
[`vid_pkg.sv`](../examples/rtl/vid_pkg.sv) ·
[`vid_axis_gain.sv`](../examples/rtl/vid_axis_gain.sv) ·
[`vid_axis_csc.sv`](../examples/rtl/vid_axis_csc.sv) ·
[`vid_axis_line_buffer.sv`](../examples/rtl/vid_axis_line_buffer.sv) ·
simulated across five configurations by
[`video_tb.sv`](../examples/tb/video_tb.sv),
proved in [`formal/vid_axis_csc_fv.sby`](../formal/vid_axis_csc_fv.sby)

---

## Contents

- [1. Agree on the layout first](#1-agree-on-the-layout-first)
- [2. Unpack, work, repack](#2-unpack-work-repack)
- [3. Generate loops replicate; procedural loops reduce](#3-generate-loops-replicate-procedural-loops-reduce)
- [4. Widths: computing the accumulator](#4-widths-computing-the-accumulator)
- [5. Signedness in the fixed-point path](#5-signedness-in-the-fixed-point-path)
- [6. Memory geometry falls out of N, P and B](#6-memory-geometry-falls-out-of-n-p-and-b)
- [7. Sideband is not just TLAST](#7-sideband-is-not-just-tlast)
- [8. Testing a claim about all parameter values](#8-testing-a-claim-about-all-parameter-values)
- [9. Tool constraints you will hit](#9-tool-constraints-you-will-hit)
- [10. Checklist](#10-checklist)

---

## 1. Agree on the layout first

Before any code, decide which bits are which, write it down once, and never
compute it again by hand. [`vid_pkg.sv`](../examples/rtl/vid_pkg.sv):

```systemverilog
function automatic int unsigned comp_lsb(input int unsigned n, p, P, B);
  comp_lsb = ((n * P) + p) * B;
endfunction
```

Component-minor, pixel-major. For `N=2, P=3, B=8`:

```
  47        40 39        32 31        24 23        16 15         8 7          0
+------------+------------+------------+------------+------------+------------+
| pix1 comp2 | pix1 comp1 | pix1 comp0 | pix0 comp2 | pix0 comp1 | pix0 comp0 |
+------------+------------+------------+------------+------------+------------+
 \________________ pixel 1 ________/  \________________ pixel 0 ________/
```

**Why this order.** The alternative — every pixel's component 0, then every
pixel's component 1 — is component-major, and it is what you get if you think of
the bus as `P` planes. Pixel-major wins for a streaming bus because a whole pixel
is then a *contiguous field*: extracting pixel `n` is one part-select, and
changing `N` does not move components around within a pixel. Component-major
makes words whose internal meaning shifts every time `N` changes, and `N` is
precisely the parameter most likely to change late.

It is also what Xilinx's AXI4-Stream Video IP uses, which outranks any argument
above the moment you have to interoperate.

Two more conventions worth adopting wholesale, because everything downstream
assumes something and silence is the expensive option:

- `TLAST` = end of line.
- `TUSER[0]` = start of frame, on the first pixel of the first line.

---

## 2. Unpack, work, repack

Every module in this family has the same three-part shape, and it is worth
stating once because the discipline is the entire technique:

```systemverilog
// 1. UNPACK -- flat TDATA into an array whose indices mean something
logic [B-1:0] pin [N][P];

for (genvar n = 0; n < int'(N); n++) begin : g_unpack_n
  for (genvar p = 0; p < int'(P); p++) begin : g_unpack_p
    assign pin[n][p] = s_tdata[vid_pkg::comp_lsb(n, p, P, B) +: B];
  end
end

// 2. WORK -- on pin[n][p], where n and p are what they look like

// 3. REPACK
for (genvar n = 0; n < int'(N); n++) begin : g_pack_n
  for (genvar p = 0; p < int'(P); p++) begin : g_pack_p
    assign packed_out[vid_pkg::comp_lsb(n, p, P, B) +: B] = pout[n][p];
  end
end
```

Steps 1 and 3 are **pure renaming** — continuous assignments on part-selects,
costing nothing in hardware. What they buy is that step 2, which is where the
actual design lives, never contains the expression `((n*P)+p)*B` and therefore
cannot get it wrong.

### Why the ports stay flat

Two independent reasons, and either alone would settle it:

- `TDATA` is a flat vector **by specification**. An unpacked array port is not
  an AXI-Stream interface.
- The Yosys frontend **rejects unpacked array ports**, so an unpacked port would
  put every module here outside the formal flow
  ([docs/25](25-formal-verification-with-sby.md)).

Flatten at the boundary, structure on the inside. This is the same rule as
`select_styles.sv` in [docs/27](27-control-structures.md), for the same reason.

### Packed multidimensional arrays are an alternative

`logic [N-1:0][P-1:0][B-1:0] pix` is a *packed* 3-D array, and it is also
indexable as `pix[n][p]`. It is legitimate, and it has one advantage: it can be
assigned to and from a flat vector in one line, because it *is* a flat vector.

```systemverilog
logic [N-1:0][P-1:0][B-1:0] pix;
assign pix = s_tdata;            // no generate loop needed at all
```

The catch is that the bit order is then fixed by the language rather than chosen
by you, and it is the *opposite* nesting from the layout above unless you declare
the dimensions in the matching order. It also cannot be used where the element
must be a separate signal — a per-element `always_comb` with its own locals, as
in the CSC — because packed elements are slices of one variable.

Rule of thumb: **packed for pure rewiring, unpacked when each element gets its
own logic.** The modules here use unpacked because every element gets an
arithmetic pipeline.

---

## 3. Generate loops replicate; procedural loops reduce

This is the single most useful distinction in parameterized RTL, and
[`vid_axis_csc.sv`](../examples/rtl/vid_axis_csc.sv) needs both in the same
module:

```systemverilog
// GENERATE: replicates hardware. Two nested levels here -> N*P independent
// dot-product engines, all existing simultaneously.
for (genvar n = 0; n < int'(N); n++) begin : g_pix
  for (genvar o = 0; o < int'(P); o++) begin : g_out_comp

    logic signed [ACCW-1:0] acc;

    always_comb begin
      acc = ACCW'($signed(offset[o*CW +: CW]));

      // PROCEDURAL: describes ONE lump of logic. The sum over the P input
      // components is a reduction producing a single value -- an adder tree,
      // not P copies of anything.
      for (int i = 0; i < int'(P); i++)
        acc = acc + (ACCW'($signed(coef[vid_pkg::comp_lsb(o, i, P, CW) +: CW]))
                     * ACCW'($signed({1'b0, pin[n][i]})));
    end
  end
end
```

Getting them the wrong way round fails in two characteristic ways:

- **A genvar loop cannot accumulate.** Each iteration is a separate scope with
  its own declarations, so there is no variable that persists across iterations
  to add into.
- **A procedural loop over pixels describes only the last one.** It assigns the
  same variable `N` times; the final assignment wins and the other `N-1` pixels
  get nothing.

The mnemonic: **a genvar loop makes more things; a procedural loop makes one
thing out of more inputs.**

Note also that the coefficient index reuses `comp_lsb` with `(o, i)` in place of
`(n, p)`. The matrix is row-major with the same shape as the pixel layout
deliberately — one indexing rule in the design rather than two.

---

## 4. Widths: computing the accumulator

An accumulator one bit short is a wrap, and a wrap in a colour matrix looks
exactly like a colour shift — plausible, and not obviously a bug.

So compute it:

```systemverilog
localparam int unsigned PSUM = (P <= 1) ? 1 : $clog2(P);
localparam int unsigned ACCW = CW + B + PSUM + 2;
```

- `CW + B` — one product of a signed `CW`-bit coefficient and a `B`-bit
  component.
- `+ PSUM` — summing `P` of them can grow the result by `ceil(log2 P)` bits.
- `+ 2` — one for the sign, one for the offset and the rounding term.

The `(P <= 1) ? 1 : ...` guard is not decoration. `$clog2(1)` is 0, and a
zero-width intermediate is an error in some tools and a silent oddity in others.
`P = 1` is a real configuration — greyscale — so it has to work.

Name it once and derive the saturation bound from the same place, so the two
cannot disagree:

```systemverilog
localparam logic signed [ACCW-1:0] SAT_MAX = ACCW'((1 << B) - 1);
```

---

## 5. Signedness in the fixed-point path

Video components are unsigned; coefficients and offsets are signed; the
accumulator is signed. That mixture is exactly where
[docs/17](17-signed-unsigned-arithmetic.md)'s trap **T6b** lives: **one unsigned
operand makes the whole expression unsigned**, which silently turns `>>>` into a
logical shift and makes every negative intermediate a large positive one.

So every operand is widened *and* made signed before any arithmetic, and each
step gets a name rather than being one clever line:

```systemverilog
logic signed [ACCW-1:0] acc, rounded, shifted;

acc     = ACCW'($signed(offset[o*CW +: CW]));
acc     = acc + (ACCW'($signed(coef[...])) * ACCW'($signed({1'b0, pin[n][i]})));
rounded = acc + ((CF == 0) ? ACCW'(0) : (ACCW'(1) <<< (CF - 1)));
shifted = rounded >>> CF;                  // arithmetic, because both are signed

if      (shifted < 0)       pout[n][o] = '0;
else if (shifted > SAT_MAX) pout[n][o] = B'(SAT_MAX);
else                        pout[n][o] = shifted[B-1:0];
```

Note `$signed({1'b0, pin[n][i]})` rather than `$signed(pin[n][i])`: the explicit
zero bit is what makes an unsigned component into a non-negative signed value.
`$signed` on its own would reinterpret the top bit as a sign, which turns every
bright pixel negative.

**Clamp, do not wrap.** Clipping a highlight is visible and ordinary; wrapping it
makes a white pixel black, which is far worse and reads as a hardware fault.

---

## 6. Memory geometry falls out of N, P and B

[`vid_axis_line_buffer.sv`](../examples/rtl/vid_axis_line_buffer.sv) is where the
parameters stop being an indexing exercise:

```
line memory WIDTH  =  N * P * B          bits    (one whole beat)
line memory DEPTH  =  ceil(MAX_WIDTH / N) words
number of memories =  TAPS - 1
```

Doubling `N` halves the depth and doubles the width — and that is not free.
Block RAMs come in fixed aspect ratios, so a 4-pixel 10-bit RGB beat is 120 bits
wide and will be built from several BRAMs in parallel whether the depth needs
them or not. Sweeping `N` is the cheapest way to see the shape of that trade-off
before committing ([docs/29](29-memories-and-inference.md)).

**`words_per_line` rounds up.** A line whose width is not a multiple of `N` still
needs a final partial beat, and a depth from truncating division is one word
short for exactly those modes — corrupting one pixel group per line, at the
right-hand edge, in some resolutions only.

### The alignment trick

`TAPS-1` memories in a chain: memory 0 takes the current line, memory `i` takes
what memory `i-1` read, so memory `i` holds the line from `i+1` lines ago.

The part worth copying is that **the write address trails the read address by one
beat.** Reads for word `w` are issued on the beat carrying `w` and arrive a cycle
later; the write of `w` happens on that later beat with the data that has just
arrived. Two consequences, both wanted:

- Every tap is aligned to the same word with **no per-tap delay matching**. The
  naive "read and write the same address" version needs `i` cycles of skew
  correction on tap `i`, and that is where hand-written line buffers go wrong.
- The read and write addresses are never equal, so the same-address read/write
  case — which [`ram_sdp.sv`](../examples/rtl/ram_sdp.sv) documents as
  **undefined**, because the primitive may be read-first or write-first — simply
  never arises.

That second point needs one exception handled: on the very first beat after reset
there is nothing to write yet, and writing anyway puts both addresses at word 0.
The write is gated on the pipeline being primed, and the requirement is asserted
rather than assumed:

```systemverilog
assign do_write = beat && d1_occupied;

a_addr_distinct: assert property (@(posedge clk) disable iff (!rst_n)
  do_write |-> (wcnt != wcnt_d1));
```

That assertion also pins down the module's one requirement on the stream: **a
line must be at least two beats.** With a single-beat line the word counter never
leaves zero and the structure cannot work — pathological for a line buffer, but
better said out loud than returned as quiet nonsense.

> This assertion is what caught the bug. The testbench passed; the build's
> check for failing SVA (added in [docs/33](33-debugging-and-bringup.md)) did
> not.

---

## 7. Sideband is not just TLAST

Everything travelling alongside the pixels has to be delayed by the same amount
as the pixels — the latency-matching discipline of
[docs/21](21-pipelining.md). It is easy to remember for `TLAST` and `TUSER`,
because they are ports. It is easy to forget for internal state.

The line buffer keeps a count of how many lines of history are stored, and uses
it to decide which taps are real. The first version read the *live* counter:

```systemverilog
if (LCW'(t) <= lines_done) ...      // WRONG: one beat too late
```

The end-of-line beat increments `lines_done`, and the very next beat then builds
the rows for the *previous* word while believing an extra line is available — so
the top tap reads a line that was never written and the output is X. The fix is
to pipeline the counter with the data:

```systemverilog
d1_lines <= lines_done;             // the count in force for THIS beat's word
...
if (LCW'(t) <= d1_lines) ...
```

**A counter is as much a sideband signal as TLAST is.** If it is consulted to
interpret a beat, it must be delayed like that beat.

---

## 8. Testing a claim about all parameter values

Genericity is a claim about *all* parameter values, so testing one is close to
testing none. [`video_tb.sv`](../examples/tb/video_tb.sv) instantiates the whole
set five times over, in a generate loop, chosen to break different things:

| Configuration | What it catches |
|---|---|
| `N=1 P=1 B=8` | the fully degenerate case — every loop runs once, every reduction has one term |
| `N=2 P=3 B=8` | ordinary RGB |
| `N=4 P=3 B=10` | `B` not a multiple of 8, so no part-select lands on a byte boundary |
| `N=2 P=4 B=12` | `P != 3`, so a 4×4 matrix |
| `N=1 P=3 B=16` | wide components |

Three kinds of check, in increasing sharpness:

**Against a reference model.** A `longint` reimplementation of the fixed-point
arithmetic. Catches arithmetic mistakes, but a reference written from the same
misunderstanding agrees with the design.

**Identity in, identity out.** Feed the CSC a `P×P` identity with zero offset and
the output must equal the input *bit for bit*. This needs no reference at all, so
it cannot be satisfied by one that made the same mistake — it catches confusion
between the pixel and component axes and any off-by-one in `comp_lsb`.

**Per-component values that all differ.** Gains of 1.25, 1.50, 1.75, … so that a
module applying component 0's gain to every component fails. Uniform test values
are how per-component bugs survive.

### The identity test has a blind spot

Measured, not assumed: transposing the coefficient index in `vid_axis_csc.sv`
(`comp_lsb(o, i, ...)` → `comp_lsb(i, o, ...)`) and re-running the identity proof
**passes cleanly**. The identity matrix is symmetric, so `coef[o][i]` and
`coef[i][o]` address the same values.

Two things do catch it:

- the testbench's *asymmetric* matrix, which fails on every configuration with
  `P > 1`;
- a formal task that assumes the matrix is zero except **one** entry at a
  position the solver chooses freely, and asserts that output component `o0`
  equals input component `i0` while every other output is zero.

```systemverilog
// formal/vid_axis_csc_fv.sv, task `basis`
assume (coef[((o*P)+i)*CW +: CW] ==
        CW'(((IDXW'(o) == o0) && (IDXW'(i) == i0)) ? (1 << CF) : 0));
```

That is a linear map checked on basis vectors: asymmetric, quantified over all
`P*P` positions, and — the point — **containing no arithmetic**, so there is no
expression in the harness that could repeat a mistake made in the design.

### What formal adds over the sweep

The `bmc` and `prove` tasks leave the coefficients **free**, so the clamp
properties inside the module are proved for *every* matrix and offset the block
can be programmed with. "It saturates correctly for BT.709" is a much weaker
claim than "it saturates correctly", and a colour matrix is data.

---

## 9. Tool constraints you will hit

Every one of these was hit writing the modules in this document, and each cost a
build.

| Construct | What happens |
|---|---|
| unpacked array **port** | rejected by the Yosys frontend |
| `import pkg::*;` in a module body | rejected by Yosys |
| `import pkg::*;` at compilation-unit scope | **crashes** Yosys with an internal assertion failure |
| `pkg::func(...)` fully scoped | works everywhere — use this |
| **labelled** immediate assert inside a generate loop | Yosys: "a cell with the same name was already created" — labels are not uniquified by scope, so leave them off |
| `+: WIDTH` where `WIDTH` is a function *argument* | "not a constant" — a part-select width must be an elaboration-time constant |
| reading `arr[idx]` in the `always_comb` that assigns `arr` | infers a latch, even when the index is provably already written |
| indexing a function call result | rejected by Yosys |

The last two are worth expanding.

**Part-select widths must be constant.** A helper that builds a per-component
parameter vector cannot take the slot width as an argument:

```systemverilog
function automatic logic [255:0] mk_gain(input int unsigned P, GWi);
  mk_gain[p*GWi +: GWi] = ...;      // ERROR: 'GWi' is not a constant
```

Declare the helper **inside the generate scope** instead, where the widths are
elaboration-time constants of that instance — and it then returns exactly the
right width per configuration:

```systemverilog
function automatic logic [CP*GW-1:0] mk_gain();
  mk_gain[p*GW +: GW] = ...;        // GW is a localparam: constant
endfunction
localparam logic [CP*GW-1:0] CGAIN = mk_gain();
```

**Do not read the array you are writing.** The obvious way to clamp a
not-yet-available tap to the oldest real one is `row[lines_done]`, and it infers
a latch: that reads the array the block is assigning, with a variable index, so
the result depends on statement order. It happens to be safe (the index is always
an already-written element) but the tool cannot know that and neither can the
next reader. Compute the source as its own mux and the self-reference disappears.

---

## 10. Checklist

**Layout**
- [ ] One layout rule, written in a package, used by every module.
- [ ] Pixel-major / component-minor unless something external forces otherwise.
- [ ] `TLAST` and `TUSER[0]` meanings documented.
- [ ] Package functions referenced fully scoped, not imported.

**Structure**
- [ ] Ports flat; unpacked arrays inside.
- [ ] Unpack and repack in generate loops, so the indexing expression appears
      exactly twice.
- [ ] Generate loops for replication, procedural loops for reduction.
- [ ] Every generate block labelled; immediate asserts inside them unlabelled.

**Arithmetic**
- [ ] Accumulator width computed from `CW + B + ceil(log2 P)` plus sign and
      rounding headroom, not guessed.
- [ ] `$clog2` guarded for `P = 1`.
- [ ] Every operand widened *and* signed before arithmetic; unsigned components
      extended with an explicit `{1'b0, ...}`.
- [ ] Results clamped, never wrapped.

**Memory**
- [ ] Depth from `ceil(MAX_WIDTH / N)`, rounding up.
- [ ] Read/write address collision impossible, and asserted.
- [ ] Line-length requirement stated and checked.

**Sideband**
- [ ] Every signal consulted to interpret a beat is delayed like that beat —
      counters included.

**Verification**
- [ ] At least one degenerate configuration (`N=1, P=1`) in the sweep.
- [ ] At least one `B` that is not a multiple of 8.
- [ ] Per-component test values all different.
- [ ] Identity-in / identity-out checked.
- [ ] Coefficient indexing checked with something **asymmetric** — identity will
      not catch a transpose.
- [ ] Clamp proved with coefficients left free, not only for the matrices you
      happened to try.

---

## See also

- [docs/17: Signed and unsigned](17-signed-unsigned-arithmetic.md) — trap T6b,
  which this arithmetic walks straight into
- [docs/18: Fixed point](18-fixed-point-arithmetic.md) — rounding, guard bits,
  saturation
- [docs/21: Pipelining](21-pipelining.md) — latency matching for sideband
- [docs/27: Control structures](27-control-structures.md) — generate versus
  procedural loops in general
- [docs/29: Memories](29-memories-and-inference.md) — BRAM aspect ratios and
  inference rules
- [docs/30: Flow control](30-flow-control-and-handshakes.md) — the valid/ready
  contract these blocks obey
- [docs/34: Coding conventions](34-coding-conventions-and-reuse.md) — degenerate
  parameters, derived widths
- [docs/36: Common peripherals](36-common-peripheral-modules.md) — the same
  parameterisation discipline on simpler blocks
