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
[`vid_axis_win3.sv`](../examples/rtl/vid_axis_win3.sv) ·
[`median9_net.sv`](../examples/rtl/median9_net.sv) ·
[`vid_axis_median3.sv`](../examples/rtl/vid_axis_median3.sv) ·
[`vid_axis_sobel.sv`](../examples/rtl/vid_axis_sobel.sv) ·
simulated by [`video_tb.sv`](../examples/tb/video_tb.sv) across five
configurations and [`video_filter_tb.sv`](../examples/tb/video_filter_tb.sv)
across five frames, proved in
[`vid_axis_csc_fv.sby`](../formal/vid_axis_csc_fv.sby),
[`vid_axis_win3_fv.sby`](../formal/vid_axis_win3_fv.sby),
[`median9_net_fv.sby`](../formal/median9_net_fv.sby) and
[`vid_axis_sobel_fv.sby`](../formal/vid_axis_sobel_fv.sby)

---

## Contents

- [1. Agree on the layout first](#1-agree-on-the-layout-first)
- [2. Unpack, work, repack](#2-unpack-work-repack)
- [3. Generate loops replicate; procedural loops reduce](#3-generate-loops-replicate-procedural-loops-reduce)
- [4. How the loops unroll](#4-how-the-loops-unroll)
- [5. Widths: computing the accumulator](#5-widths-computing-the-accumulator)
- [6. Signedness in the fixed-point path](#6-signedness-in-the-fixed-point-path)
- [7. Memory geometry falls out of N, P and B](#7-memory-geometry-falls-out-of-n-p-and-b)
- [8. Neighbourhood filters and the halo problem](#8-neighbourhood-filters-and-the-halo-problem)
- [9. A median filter, which has no arithmetic at all](#9-a-median-filter-which-has-no-arithmetic-at-all)
- [10. A Sobel filter, and what its output cannot tell you](#10-a-sobel-filter-and-what-its-output-cannot-tell-you)
- [11. Sideband is not just TLAST](#11-sideband-is-not-just-tlast)
- [12. Testing a claim about all parameter values](#12-testing-a-claim-about-all-parameter-values)
- [13. Tool constraints you will hit](#13-tool-constraints-you-will-hit)
- [14. Checklist](#14-checklist)

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

### One rule, three kinds of bundle

A line buffer hands out `TAPS` rows at once; a window builder hands out
`ROWS × COLS` pixels at once. Both are just *longer pixel arrays in the same
layout*, so flattening `(row, pixel)` into a single pixel index gives one
indexing rule for all three:

```systemverilog
function automatic int unsigned rowpix_lsb(input int unsigned r, n, p,
                                           cols, P, B);
  rowpix_lsb = comp_lsb((r * cols) + n, p, P, B);
endfunction
```

Pass `cols = N` for a row bundle and `cols = N + 2` for a 3-wide window. The
alternative — a second convention for rows, a third for windows — is three
chances to get the same thing wrong.

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
thing out of more inputs.** Section 4.5 sharpens it, because the rule as stated
is not quite the truth — a procedural loop *can* build `N` things, when each
iteration writes a different lvalue.

Note also that the coefficient index reuses `comp_lsb` with `(o, i)` in place of
`(n, p)`. The matrix is row-major with the same shape as the pixel layout
deliberately — one indexing rule in the design rather than two.

---

## 4. How the loops unroll

Everything in section 3 is easier to trust once you have seen what the tools
actually build. Everything below was dumped out of Yosys from the modules in this
repository; the commands are in [4.9](#49-seeing-it-for-yourself).

### 4.1 A generate loop is a scope factory

A `for` with a `genvar` is not a loop at all after elaboration. The tool
**instantiates the body once per iteration**, each time in a fresh named scope,
with the genvar replaced by a literal. This unpack loop:

```systemverilog
logic [B-1:0] pin [N][P];

for (genvar n = 0; n < int'(N); n++) begin : g_unpack_n
  for (genvar p = 0; p < int'(P); p++) begin : g_unpack_p
    assign pin[n][p] = s_tdata[vid_pkg::comp_lsb(n, p, P, B) +: B];
  end
end
```

at `N=2, P=3, B=8` becomes exactly this, and nothing else:

```systemverilog
// g_unpack_n[0].g_unpack_p[0]
assign pin[0][0] = s_tdata[ 0 +: 8];    // comp_lsb(0,0,3,8) = ((0*3)+0)*8 =  0
// g_unpack_n[0].g_unpack_p[1]
assign pin[0][1] = s_tdata[ 8 +: 8];    //                      ((0*3)+1)*8 =  8
// g_unpack_n[0].g_unpack_p[2]
assign pin[0][2] = s_tdata[16 +: 8];    //                      ((0*3)+2)*8 = 16
// g_unpack_n[1].g_unpack_p[0]
assign pin[1][0] = s_tdata[24 +: 8];    //                      ((1*3)+0)*8 = 24
// g_unpack_n[1].g_unpack_p[1]
assign pin[1][1] = s_tdata[32 +: 8];    //                      ((1*3)+1)*8 = 32
// g_unpack_n[1].g_unpack_p[2]
assign pin[1][2] = s_tdata[40 +: 8];    //                      ((1*3)+2)*8 = 40
```

Three things are worth pinning down here.

**The function call is gone.** `vid_pkg::comp_lsb(n, p, P, B)` is evaluated at
elaboration, where `n` and `p` are constants, so it leaves behind a literal bit
offset. A package function used this way costs nothing — it is a *notation*, not
a circuit. A part-select *base* may be a run-time value (it becomes a shifter),
so the call does not have to fold; but the *width* after `+:` must always be a
constant, which is the constraint in
[section 13](#13-tool-constraints-you-will-hit).

**The scope names are real.** `g_unpack_n[0].g_unpack_p[2]` is a hierarchical
path you can reference in a testbench, set a breakpoint on, or find in a timing
report. Unlabelled generate blocks get tool-invented names like `genblk3`, which
is why every generate block in this repository is labelled — the label is the
only thing that makes a synthesis warning about `g_pix[3].g_comp[1]` mean
anything.

**The unpacked array is not replicated.** `pin` is declared once, outside the
loop; the loop only creates the `assign` statements that drive its elements. A
declaration *inside* the loop body would be replicated, once per scope, which is
what section 4.7 uses deliberately.

Here is the repack loop as Yosys writes it back out after elaboration — the same
thing from the other side:

```verilog
  reg [7:0] \pout[0] ;            // the unpacked array, one net per element
  reg [7:0] \pout[1] ;
  ...
  assign packed_out[7:0]   = \pout[0] ;
  assign packed_out[15:8]  = \pout[1] ;
  assign packed_out[23:16] = \pout[2] ;
  assign packed_out[31:24] = \pout[3] ;
  assign packed_out[39:32] = \pout[4] ;
  assign packed_out[47:40] = \pout[5] ;
```

Six wires and six renamings. No logic, exactly as claimed in section 2.

### 4.2 Nested generate loops build N*P of everything

The CSC's two nested genvar loops produce `N*P` scopes, **each with its own copy
of every declaration inside the body**. At `N=2, P=3` that is six scopes:

```
g_pix[0].g_out_comp[0]     g_pix[1].g_out_comp[0]
g_pix[0].g_out_comp[1]     g_pix[1].g_out_comp[1]
g_pix[0].g_out_comp[2]     g_pix[1].g_out_comp[2]
```

and six copies of `acc`, `rounded`, `shifted` and the `always_comb` that drives
them. The multiplier count follows from the nesting: `N*P` engines, each
containing a procedural loop over `P` products. Counted out of Yosys for the real
module:

| N | P | `$mul` | `$add` | predicted: `N*P*P`, `N*P*(P+1)` |
|---|---|---|---|---|
| 1 | 1 | 1 | 2 | 1, 2 |
| 1 | 3 | 9 | 12 | 9, 12 |
| 2 | 3 | 18 | 24 | 18, 24 |
| 4 | 3 | 36 | 48 | 36, 48 |
| 2 | 4 | 32 | 40 | 32, 40 |

`$mul = N*P*P` exactly. That is the number to look at before choosing `N`: a
colour matrix at four pixels per clock is 36 multipliers whatever else you do,
and the generate nest is where that cost is decided.

The `$add` column is `N*P*(P+1)`: `P` accumulate steps plus one for the rounding
term, per engine. Both columns are what the two loop kinds predict — the
generate nest sets the number of *engines*, the procedural loop sets the size of
*each* engine.

### 4.3 A procedural loop is an expression chain

Inside one of those scopes, the procedural loop:

```systemverilog
always_comb begin
  acc = ACCW'($signed(offset[o*CW +: CW]));
  for (int i = 0; i < int'(P); i++)
    acc = acc + (ACCW'($signed(coef[vid_pkg::comp_lsb(o, i, P, CW) +: CW]))
                 * ACCW'($signed({1'b0, pin[n][i]})));
end
```

unrolls, at `P=3`, into three *sequential assignments to the same variable*:

```systemverilog
acc = offset;                     //     the seed
acc = acc + (coef[o][0] * x0);    // i=0  reads the acc above
acc = acc + (coef[o][1] * x1);    // i=1  reads the acc above
acc = acc + (coef[o][2] * x2);    // i=2  reads the acc above
```

and because each line reads the value the previous line wrote, that is a **chain
of three adders**, not a tree:

```
offset --> (+) --> (+) --> (+) --> acc        depth 3, three adders
            ^       ^       ^
          c0*x0   c1*x1   c2*x2
```

This is the loop-carried dependency of [docs/27](27-control-structures.md), and
at `P=3` it does not matter. At `P=16` it is a 16-deep adder chain, and the fix
is to write the reduction as a tree instead — halving the number of live partial
sums each round:

```systemverilog
logic signed [ACCW-1:0] part [P];
always_comb begin
  for (int i = 0; i < int'(P); i++)               // the P products, independent
    part[i] = ACCW'($signed(coef[vid_pkg::comp_lsb(o, i, P, CW) +: CW]))
            * ACCW'($signed({1'b0, pin[n][i]}));
  for (int s = 1; s < int'(P); s = s * 2)         // pairwise, halving each round
    for (int i = 0; i + s < int'(P); i = i + 2*s)
      part[i] = part[i] + part[i + s];
  acc = part[0] + ACCW'($signed(offset[o*CW +: CW]));
end
```

Same adder count, depth `ceil(log2 P)` instead of `P`. Note that the tree version
*also* uses a procedural loop — the difference is not generate-versus-procedural,
it is whether each step depends on the one before.

**At `P=1` the loop body appears once** and there is no adder at all beyond the
offset, which is why the `N=1, P=1` configuration in the testbench sweep is worth
having: it is the only one where a reduction with zero additions has to work.

### 4.4 The two failure modes, unrolled

**A genvar loop cannot accumulate.** This does not compile, and the unrolled form
shows why:

```systemverilog
// WRONG
for (genvar i = 0; i < int'(P); i++) begin : g_sum
  logic signed [ACCW-1:0] acc;
  always_comb acc = acc + (coef[i] * x[i]);     // which acc?
end
```

unrolls to three *independent* scopes, each declaring its own `acc`:

```systemverilog
g_sum[0]: logic acc;  always_comb acc = acc + ...;   // reads itself: a loop
g_sum[1]: logic acc;  always_comb acc = acc + ...;   // a different acc entirely
g_sum[2]: logic acc;  always_comb acc = acc + ...;   // and another
```

There is no variable that spans iterations, because there is no iteration — there
are three scopes. Each `acc` is a combinational loop feeding itself, which is a
zero-delay ring, not an accumulator. To chain across scopes you must name the
neighbour explicitly (`g_sum[i-1].acc`), which is exactly what `pipe_delay.sv`
does and why that module reads the way it does.

**A procedural loop over pixels describes only the last one:**

```systemverilog
// WRONG
always_comb
  for (int n = 0; n < int'(N); n++)
    m_tdata = f(pin[n]);        // one lvalue, N assignments
```

unrolls to

```systemverilog
m_tdata = f(pin[0]);            // dead
m_tdata = f(pin[1]);            // dead
m_tdata = f(pin[2]);            // this is the circuit
```

Last write wins, and the first `N-1` become dead code the synthesiser removes
silently. Nothing warns: the code is legal, it just does not mean what it looks
like.

### 4.5 ...and the rule's real boundary

The rule "procedural loops do not replicate" is a useful lie. What a procedural
loop cannot do is **declare** anything, **instantiate** anything, or accumulate
into one variable and keep the intermediate results. What it *can* do is write a
different lvalue each iteration — and that replicates hardware.
[`median9_net.sv`](../examples/rtl/median9_net.sv):

```systemverilog
logic [3*W-1:0] srow [3];

always_comb
  for (int r = 0; r < 3; r++)
    srow[r] = srt3(din[(3*r+0)*W +: W], din[(3*r+1)*W +: W],
                   din[(3*r+2)*W +: W]);
```

Three different lvalues, so this unrolls to three independent sorters — nine
comparators of real hardware, from a procedural loop:

```systemverilog
srow[0] = srt3(din[0*W +: W], din[1*W +: W], din[2*W +: W]);
srow[1] = srt3(din[3*W +: W], din[4*W +: W], din[5*W +: W]);
srow[2] = srt3(din[6*W +: W], din[7*W +: W], din[8*W +: W]);
```

`sort_network.sv` is the same pattern one level up: its stage loop writes
`cur[p+1][i]` from `cur[p][i]`, a different lvalue every time, and builds a
mesh.

So the honest form of the rule:

| you need | use |
|---|---|
| a declaration, or a module instance, per element | **generate** (genvar) |
| a different array element assigned per element | either; procedural is shorter |
| one value from many inputs (a reduction) | **procedural** |
| a value that feeds the next element | procedural, or `g[i-1].x` across scopes |

### 4.6 A compare-exchange is a mux, not a branch

`srt3` in `median9_net.sv` reads like a software swap, and this is the most
common place to lose confidence that a procedural block is hardware:

```systemverilog
function automatic logic [3*W-1:0] srt3(input logic [W-1:0] a, b, c);
  logic [W-1:0] x0, x1, x2, t;
  x0 = a;  x1 = b;  x2 = c;
  if (x1 < x0) begin t = x0; x0 = x1; x1 = t; end
  if (x2 < x1) begin t = x1; x1 = x2; x2 = t; end
  if (x1 < x0) begin t = x0; x0 = x1; x1 = t; end
  srt3 = {x2, x1, x0};
endfunction
```

Unrolled — writing `x0'` for the value after the first stage, and so on — every
`if` is a *value selection*, not a control decision:

```
stage 1:   x0' = (b < a) ? b : a        x1' = (b < a) ? a : b        x2' = c
stage 2:   x1'' = (x2' < x1') ? x2' : x1'    x2'' = (x2' < x1') ? x1' : x2'
stage 3:   x0''' = (x1'' < x0') ? x1'' : x0'   x1''' = (x1'' < x0') ? x0' : x1''
```

Three comparators, six 2:1 muxes, no state, no sequencing — a fixed mesh whose
depth is 3 for any `W`. The temporary `t` does not exist in hardware; it is an
artefact of writing a swap in one statement order rather than another.

`median9_net` builds the whole 9-input selection network this way, and the
comparator count comes out exactly as the hand analysis predicts. Counted out of
Yosys at `W=8`, both designs optimised the same way:

| | comparators | depth |
|---|---|---|
| `sort_network` with `N=9` (full sort) | **36** | 9 |
| `median9_net` (selection only) | **19** | 6 |

The median does not need the other eight values, and a selection network is
barely half the price of finding them.

### 4.7 Instance arrays: the generate nest as a floor plan

Put a module instance in the body and the generate nest becomes an array of
instances. [`vid_axis_median3.sv`](../examples/rtl/vid_axis_median3.sv):

```systemverilog
for (genvar n = 0; n < int'(N); n++) begin : g_pix
  for (genvar p = 0; p < int'(P); p++) begin : g_comp
    logic [9*B-1:0] patch;                       // declared inside: replicated
    for (genvar r = 0; r < 3; r++) begin : g_prow
      for (genvar c = 0; c < 3; c++) begin : g_pcol
        assign patch[((r * 3) + c)*B +: B] =
          s_win[vid_pkg::rowpix_lsb(r, n + c, p, COLS, P, B) +: B];
      end
    end
    median9_net #(.W(B)) u_med (.din(patch), .med(pout[n][p]));
  end
end
```

At `N=2, P=3` that is what Yosys reports after elaboration — six `patch` wires
and six instances, each named by its scope path:

```verilog
  wire [71:0] \g_pix[0].g_comp[0].patch ;
  wire [71:0] \g_pix[0].g_comp[1].patch ;
  wire [71:0] \g_pix[0].g_comp[2].patch ;
  wire [71:0] \g_pix[1].g_comp[0].patch ;
  wire [71:0] \g_pix[1].g_comp[1].patch ;
  wire [71:0] \g_pix[1].g_comp[2].patch ;
  ...
  \$paramod\median9_net\W=8  \g_pix[0].g_comp[0].u_med  (
    .din(\g_pix[0].g_comp[0].patch ), .med(...));
  \$paramod\median9_net\W=8  \g_pix[1].g_comp[2].u_med  (
    .din(\g_pix[1].g_comp[2].patch ), .med(...));
```

Four levels of nesting in the source; `N*P` instances and `N*P*9` part-selects in
the result. At `N=4, P=3, B=10` it is 12 instances and 228 comparators, in one
clock cycle — which is the honest reason to know what `N` is before agreeing to
it.

### 4.8 Degenerate parameters: loops that run once, or not at all

Generic code is mostly broken at the ends of its parameter range, and the
unrolled view is where you can see it.

**A loop that runs once still creates a scope.** At `N=1` the nest above builds
`g_pix[0].g_comp[0].u_med` — with the `[0]`. Code that referenced `g_pix.u_med`
because "there is only one" stops elaborating the moment `N` becomes 2.

**A loop can run zero times.** The line buffer's memory chain starts at 1:

```systemverilog
for (genvar t = 1; t < int'(TAPS); t++) begin : g_lb
  ram_sdp #(...) u_line (...);
end
```

At `TAPS=1` the body is instantiated zero times: no memories, no scopes, and
`g_lb` does not exist. Everything that reads the loop's outputs must still be
driven — which is why `lb_rd[0]` is assigned unconditionally outside the loop. A
generate loop that runs zero times leaves *undriven nets*, not zeros, and an
undriven `logic` read by an `always_comb` is how a latch gets inferred at one end
of a parameter sweep and nowhere else.

**A generate-if discards the untaken branch entirely.** The parameter checks in
these modules are generate-ifs:

```systemverilog
if (R < 3) begin : g_chk_r
  $error("vid_axis_median3: R must be >= 3, got %0d", R);
end
```

When `R >= 3` the branch is not compiled, not optimised away — it never exists.
That is what makes it safe to write an elaboration-time `$error` there, and it is
also why such a check costs nothing in the configurations that pass it.

**`$clog2(1)` is 0.** Guard every width computed from a parameter that can be 1:

```systemverilog
localparam int unsigned PSUM = (P <= 1) ? 1 : $clog2(P);
localparam int unsigned AW   = (WORDS <= 1) ? 1 : $clog2(WORDS);
```

A zero-width intermediate is an error in some tools and a silent oddity in
others, and `P = 1` (greyscale) and `TAPS = 1` are both real configurations.

### 4.9 Seeing it for yourself

Every dump above came from these two commands. They take a second and they
settle arguments:

```bash
yosys -p "read_verilog -sv -DSYNTHESIS examples/rtl/vid_pkg.sv examples/rtl/vid_axis_median3.sv examples/rtl/median9_net.sv; chparam -set N 2 -set P 3 -set B 8 vid_axis_median3; hierarchy -top vid_axis_median3; write_verilog -noattr /tmp/flat.v"
```

`write_verilog` after `hierarchy` shows the elaborated structure: generate scopes
resolved into names, genvars substituted, part-selects reduced to literal bit
ranges. Add `proc` first to see the `always` blocks turned into assignments.

```bash
yosys -p "read_verilog -sv -DSYNTHESIS examples/rtl/median9_net.sv; hierarchy -top median9_net; proc; opt -fast; stat"
```

`stat` counts cells by type, which is how the multiplier and comparator tables
above were produced. Sweep a parameter with `chparam` and watch the counts move;
if `$mul` does not scale the way your loop nest says it should, the nest is not
what you think it is.

In Vivado the equivalent view is **Open Elaborated Design** — the RTL schematic
uses the same `g_pix[1].g_comp[2].u_med` paths, so a name found in a Yosys dump is
the name to search for there.

---
## 5. Widths: computing the accumulator

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

The same arithmetic, done for a filter with fixed small weights, gets small:
`vid_axis_sobel.sv` needs `B+3` bits, because each gradient is three taps weighted
1, 2, 1 against three weighted 1, 2, 1, so `|Gx| <= 4*(2^B - 1) < 2^(B+2)` — one
more bit for the sign. And `|Gx| + |Gy| <= 8*(2^B - 1) < 2^(B+3)` fits in `B+3`
bits *unsigned*. One expression, two meanings of the same number, which is why
both are named:

```systemverilog
localparam int unsigned GRADW = B + 3;    // signed, one gradient
localparam int unsigned MAGW  = B + 3;    // unsigned, |Gx| + |Gy|
```

---

## 6. Signedness in the fixed-point path

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

The negation in the Sobel path is the same discipline from the other direction:

```systemverilog
ax = MAGW'($unsigned((gx < 0) ? -gx : gx));
```

`gx` is signed, so `-gx` is a signed negation — and it cannot overflow only
because `GRADW` was sized with a bit to spare in section 5. The `$unsigned` is
what stops the sum `ax + ay` from being evaluated signed and losing its top bit.

---

## 7. Memory geometry falls out of N, P and B

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

## 8. Neighbourhood filters and the halo problem

A line buffer solves the *vertical* half of a 3x3 filter: it presents three lines
at the same horizontal position. The horizontal half looks trivial and is not,
because at `N` pixels per clock the neighbours of a pixel are not all in the same
beat — and at `N = 1`, neither of them is:

```
    beat k-1                  beat k                    beat k+1
 [ ... | p_{N-1} ]   [ p_0 | p_1 | ... | p_{N-1} ]   [ p_0 | ... ]
          ^-- left neighbour      the centre pixels      ^-- right neighbour
              of p_0 of beat k                               of p_{N-1}
```

So a 3-wide window over one beat needs **one pixel from each neighbouring beat**,
and the output of [`vid_axis_win3.sv`](../examples/rtl/vid_axis_win3.sv) is
`R × (N+2)` pixels: window column `c` is the neighbourhood centre for output pixel
`c-1`.

### The cost is one beat of lookahead

The window for beat `k` cannot be built until beat `k+1` has arrived. So the
module holds a beat back:

```systemverilog
assign out_ready = !m_tvalid || m_tready;
assign s_tready  = !c_valid || out_ready;
assign load      = s_tvalid && s_tready;
assign emit      = c_valid && out_ready && (c_last || s_tvalid);
```

The `emit` condition is the whole design: a held beat can be described **either**
when its successor is on the wires, **or** when it ends the line, because then the
right neighbour is off the end of the picture and gets replicated instead of
waited for. Three consequences:

- **No throughput cost.** When input is continuous, `load` and `emit` happen on
  the same cycle: the arriving beat supplies the right halo *and* becomes the next
  centre. One output per input, forever, with a single bubble at the start of the
  stream.
- **`s_tready` depends on `m_tready`, and `emit` depends on `s_tvalid`.** That is
  allowed — [docs/30](30-flow-control-and-handshakes.md)'s rule is that VALID may
  not depend on READY, not the reverse — but it does mean a long chain of these
  needs a `skid_buffer` somewhere.
- **A stream that stops mid-line leaves the last beat inside.** Not a bug: the
  window genuinely is not determined yet. It matters for testing, and section 11
  says what to do about it.

### The halo is a whole-pixel copy

```systemverilog
// column 0: the left halo
assign win[vid_pkg::rowpix_lsb(r, 0, 0, COLS, P, B) +: PIXB] =
  c_first ? c_rows[vid_pkg::rowpix_lsb(r, 0, 0, N, P, B) +: PIXB]
          : l_pix[r*PIXB +: PIXB];
```

`+: PIXB`, where `PIXB = P*B` — one part-select moves an entire pixel, with no
loop over components. That is a direct payoff of the pixel-major layout chosen in
section 1: a pixel is a contiguous field. Under a component-major layout this
would be `P` separate copies per halo column, and the number would change with
`N`.

Only **one pixel per row** of the previous beat is stored, not the whole beat:
`R*P*B` bits instead of `R*N*P*B`. The halo is one pixel wide, so that is all
there is to remember.

### Edges: replicate, don't zero

Column 0 repeats column 1 at the start of a line; column `N+1` repeats column `N`
at the end. The alternative — zeros outside the picture — puts a black frame
around every image, and a gradient filter turns a black frame into a bright
outline around the whole picture. Clamp-to-edge matches the line buffer's vertical
`EDGE_REPLICATE`, so the two policies agree and a software model needs exactly one
function:

```systemverilog
function automatic int fpix(input int y, x, p);       // video_filter_tb.sv
  int yy, xx;
  yy = (y < 0) ? 0 : ((y >= int'(FLINES)) ? int'(FLINES) - 1 : y);
  xx = (x < 0) ? 0 : ((x >= int'(FWIDTH)) ? int'(FWIDTH) - 1 : x);
  fpix = fr[yy][xx][p];
endfunction
```

Clamping has one consequence worth knowing, because a test found it the hard way:
**an impulse sitting on the edge is replicated by the edge policy and is no longer
isolated.** At the top-left corner the vertical clamp triples the row and the
horizontal clamp doubles the column, so a single bad pixel becomes six of the nine
taps — a majority, which the median then keeps. That is correct behaviour and a
wrong test expectation ([section 12](#12-testing-a-claim-about-all-parameter-values)).

### Generalising: a halo of H needs H <= N

For a 5-wide filter the halo is two pixels per side, which needs two pixels from
each neighbouring beat — available from a single beat of lookahead only if
`N >= 2`. In general:

```
halo of H pixels per side  =>  window is N + 2H columns
                           =>  requires H <= N
```

Otherwise the window spans more than three beats and one beat of lookahead is not
enough; you need a deeper shift register of beats and the control gets genuinely
harder. `vid_pkg::win_cols(N, halo)` states the geometry; the constraint is the
reason the module is called `win3` rather than `winK`.

### What is proved, and what is simulated

The split follows the standing rule — a module asserts what it guarantees, its
harness assumes what it needs — with one extra twist here:

| property | where | why there |
|---|---|---|
| a beat is never loaded over an unemitted one | in the module | it is about internal state |
| exactly `c_valid + m_tvalid` beats are in flight | in the module | counters must sit beside the state they count ([docs/25](25-formal-verification-with-sby.md)) |
| the halo columns are replicated at line ends | in the module | the window is internal before it is registered |
| the handshake contract upstream | the harness | it is the caller's obligation |
| the centre columns are the beat that was loaded | **simulation** | see below |

That last row is not a choice. Stating it in formal needs the pre-registered
window and the emit condition, both internal, and the Yosys frontend cannot read
into an instance at all: `dut.win` gives *"Don't know how to detect sign and
width for AST_AUTOWIRE node"*, and the same reference inside a function gives
*"Failed to detect width for identifier ...dut.win"*. Exporting the window just to
assert on it would be changing the design to suit the proof. So the mapping is
checked in [`video_filter_tb.sv`](../examples/tb/video_filter_tb.sv) against a
frame model instead — which states it over a whole frame rather than one beat, and
is the better statement anyway.

The flow-accounting property is worth one more note, because the first version of
it did not close:

```systemverilog
// UNKNOWN under induction:
assert ((f_n_in - f_n_out) <= 6'd2);
// PASSES:
assert ((f_n_in - f_n_out) == (6'(c_valid) + 6'(m_tvalid)));
```

The bound is true but not inductive: from an arbitrary state the solver may put
the counters two apart with nothing in flight, and then one more beat breaks it.
Saying exactly **where** each beat in flight is — the holding register, the output
register, or nowhere — is state-local, so induction carries it, and it implies the
bound. Same lesson as `axil_slave_fv` and `axis_upsizer_fv`, one notch sharper:
not just "put the counters inside the module" but "say what they equal, not what
they are less than".

---

## 9. A median filter, which has no arithmetic at all

A 3x3 median is the standard salt-and-pepper denoiser and the cleanest possible
illustration of this family, because it contains no kernel, no multiplier and no
accumulator — only comparisons. Nothing in it can be confused with the CSC.

```
vid_axis_line_buffer  ->  vid_axis_win3  ->  vid_axis_median3
 (3 lines in parallel)     (3 x (N+2))        (N*P median networks)
```

### The network: 19 comparators, not 36

`sort_network.sv` with `N=9` already produces the median — as element 4 of a full
sort, for 36 comparators and 9 stages. But the median does not need the other
eight values. [`median9_net.sv`](../examples/rtl/median9_net.sv) uses Smith's
selection network, which is exact and much cheaper:

| step | what | comparators |
|---|---|---|
| 1 | sort each of the three rows | 3 × 3 = 9 |
| 2 | `lo` = max of the three row minima | 2 |
| | `mid` = median of the three row medians | 3 |
| | `hi` = min of the three row maxima | 2 |
| 3 | median of (`lo`, `mid`, `hi`) | 3 |
| | | **19**, depth 6 |

Measured at `W=8` with both designs optimised identically: 36 comparators for the
full sort, 19 for the selection network (section 4.6).

Step 2 is the part that is not obvious — the overall median can lie neither below
`lo` nor above `hi`, so clamping `mid` into that range is enough. That argument is
short and easy to get subtly wrong, which is why the module carries a proof rather
than an argument.

### Proved two independent ways

[`median9_net_fv.sby`](../formal/median9_net_fv.sby):

**`equiv` — against a full sort, at `W=1`.** The same nine values go through
`sort_network`, whose own proof establishes that it sorts, and the middle element
of a sorted list is the median by definition. At `W=1` the **0-1 principle** makes
this a proof for *every* element width: a comparator network commutes with any
monotone function applied elementwise, so thresholding at each value in turn
reduces the general case to the 0/1 case. Formally, with `t_v(x) = (x >= v)`,

```
t_v(net(x)) = net(t_v(x)) = median(t_v(x)) = t_v(median(x))    for all v
```

which forces `net(x) = median(x)`. Nine 8-bit inputs would be 2^72 simulation
vectors; at `W=1` the whole space is 512 patterns and the principle carries the
result to all widths for free.

**`wide` — against a definition that mentions no algorithm.** Inside the module:

```systemverilog
f_member : assert (fv_member);          // med is one of the nine inputs
f_rank_ge: assert (fv_ge >= 4'd5);      // at least five inputs are >= med
f_rank_le: assert (fv_le >= 4'd5);      // at least five are <= med
```

Those three **characterise** the median exactly: if `v` is one of the nine values
with at least five at or above it and five at or below, then `v` is the median —
if `v` sat strictly below the median in sorted order, five values being `<= v`
would already force the fifth-smallest to equal `v`. No reference model can agree
with the design by sharing its mistake, because there is no model.

Both tasks run at `depth 1`. A stateless network needs no induction: one BMC step
*is* the entire input space. The cover statements need `depth 2` — an assertion in
an `always @(posedge clk)` block is checked in step 0, but a cover point is only
recorded once a clock edge has occurred. Measured, when all three covers came back
"unreached" at depth 1 while a mutated network was failing `equiv` at that same
depth.

### Per component, not per pixel

Each component is filtered independently, so an output pixel can be a mixture of
components taken from different input pixels. That is the conventional (marginal)
median, and what every image-processing library does. The alternative — a *vector*
median picking the input pixel that minimises total distance to the others —
preserves colours exactly, costs `P` multiplies per pair, and is a different
module.

Because a median is invariant under permutation of its inputs, **the row order
does not matter here** — it makes no difference which window row is the top line.
That is emphatically not true of the Sobel filter, which reads the same window.
Two filters, one window, different sensitivity to its layout.

### What the two negative controls showed

Deliberate mutations, each run against everything:

| mutation | `video_filter_tb` | `median9_net_fv` |
|---|---|---|
| drop one compare-exchange from `srt3` | **FAIL** | `equiv` **FAIL**, `wide` **FAIL** |
| gather window column `c` instead of `n + c` | **FAIL** | `equiv` PASS, `wide` PASS |

The second row is the point: **the proof of the kernel says nothing about how the
kernel is wired in.** `median9_net_fv` is a complete proof of a median network,
and it is completely blind to `vid_axis_median3` handing that network the wrong
nine pixels. A proof's scope is exactly the module it was written for.

### Timing

One register stage, and the network is six comparators deep — at `N=4, P=3` that
is 12 copies of it in one cycle, and the obvious place this block misses timing.
The natural cut is after the three row sorts inside `median9_net`, splitting it
3 + 3. It is left unpipelined here because the shape of the generate nest is the
point and a register inside it would double the module's length.

---

## 10. A Sobel filter, and what its output cannot tell you

```
Gx = | -1  0 +1 |    Gy = | -1 -2 -1 |    out = clamp((|Gx| + |Gy|) >> SHIFT)
     | -2  0 +2 |         |  0  0  0 |
     | -1  0 +1 |         | +1 +2 +1 |
```

Same window as the median, same generate-loop shape, and every design decision
different — because this one is a convolution.

### The loop nest mirrors the dataflow, not the data layout

`vid_axis_csc.sv` has `N*P` engines because it produces `P` output components per
pixel. [`vid_axis_sobel.sv`](../examples/rtl/vid_axis_sobel.sv) has **`N`**
engines, because a gradient is one number per pixel: it reads a single component
(`GRAD_COMP`) and writes the result to all `P` outputs. Copying the previous
module's nest would give `P` identical copies of the same arithmetic and `P` times
the area for nothing.

Writing the magnitude to every component keeps the stream's shape — still `N`
pixels of `P` components of `B` bits — so nothing downstream needs reconfiguring
to display, encode or write out the result. The picture is grey, which is what an
edge map is.

### L1 instead of a square root

The true magnitude is `sqrt(Gx^2 + Gy^2)`. `|Gx| + |Gy|` needs no multiplier and
no square root, and it is exact on the axes — but it **overestimates**, by up to
`sqrt(2)` (41%) at 45°, where a horizontal and a vertical edge of equal strength
meet. `max(|Gx|, |Gy|)` errs the other way, up to 29% low on the same diagonal.
Between them, `max + min/2` is within about 12% and costs one shift and one add.

Which to use is a threshold question, not an accuracy question: any of them is
fine behind a threshold that was tuned with the same approximation in place, and
all of them are wrong if the number is reported as a magnitude. Pick one and
**state its error** ([docs/18](18-fixed-point-arithmetic.md)); don't pretend it is
exact.

`SHIFT` deserves more thought than it looks. At `SHIFT=0` any edge stronger than a
quarter of full scale saturates, which gives a usable but blown-out edge map — and
makes the block *much harder to test*, because a saturated output equals a
saturated output whatever the arithmetic did. Measured: with `SHIFT=0` the frame
testbench does not notice a kernel weight changed from 2 to 1. At `SHIFT=3` it
fails immediately. **A configuration that saturates is a configuration that hides
bugs**, and the test should not use it.

### What the output genuinely cannot see

Three mutations of the module, each run against the whole flow:

| mutation | frame testbench | in-module asserts | `mirror` / `transpose` |
|---|---|---|---|
| patch index `w[r][c]` → `w[c][r]` | **PASS** | **FAIL** | blind (see below) |
| kernel weight 2 → 1 | **FAIL** | **FAIL** | **FAIL** |
| `Gx` sign flipped (columns swapped) | **PASS** | **PASS** | **PASS** |

Row 3 first, because it is the simplest: the output is a **magnitude**, so a sign
error in `Gx` is not observable anywhere, by anything. Nothing is wrong with the
verification; the information is not in the output. Gradient *direction* is where
that error would show, and this module does not produce one.

Row 1 is the interesting one. The two Sobel kernels are each other's transpose
(`ky = kx^T`), so

```
|Gx(A^T)| + |Gy(A^T)| = |Gy(A)| + |Gx(A)|
```

— transposing the patch leaves the magnitude **exactly unchanged, for every
input**. A design that exchanges the row and column indices computes precisely the
same function, so no test applied to `m_tdata` can distinguish it. The frame
testbench passes. This is the identity-matrix blind spot from
[section 12](#12-testing-a-claim-about-all-parameter-values) one level deeper:
there the blindness was a property of the *test vector*, here it is a property of
the *function being computed*.

That is also why this module has a `mirror` and a `transpose` proof task, and why
they are honestly labelled as **specification** rather than as checks: they assert
the symmetries an edge magnitude is supposed to have (feed a second instance the
mirrored or transposed window, assert the outputs agree). Measured, with the
orientation assertions temporarily disabled, both tasks PASS on the transposed
design. A property that holds for the bug cannot catch the bug.

What does catch it is asymmetric and lives on the internal gradients:

```systemverilog
assert (!f_rows_same || (gy == '0));    // rows identical  => no vertical edge
assert (!f_cols_same || (gx == '0));    // columns identical => no horizontal one
```

### The mistake inside that fix

The *first* version of those two assertions stated its premises on the internal
tap array:

```systemverilog
// USELESS
assert (!(w[0][0] == w[1][0] && w[1][0] == w[2][0] && ...) || (gy == '0));
```

and passed happily with the indices exchanged. Of course it did: *"`w` is
row-constant implies `gy == 0`"* is a property of the arithmetic **downstream of
the gather**, and says nothing whatever about how `w` was filled.

**A property whose premise reaches the input through the same expression as the
data path cannot test that expression.** The working version computes its premises
at module level from whole-row *slices* of `s_win`, using only the row stride and
no per-tap indexing at all:

```systemverilog
localparam int unsigned ROWB = COLS * P * B;          // bits in one window row

f_rows_same = (s_win[0*ROWB +: ROWB] == s_win[1*ROWB +: ROWB])
           && (s_win[1*ROWB +: ROWB] == s_win[2*ROWB +: ROWB]);

f_cols_same = 1'b1;                                   // each row is one pixel,
for (int r = 0; r < 3; r++)                           // repeated
  if (s_win[r*ROWB +: ROWB] != {COLS{s_win[r*ROWB +: P*B]}})
    f_cols_same = 1'b0;
```

Now the premise and the design read `s_win` through different expressions, and the
transposed design fails in step 0. This was found by a negative control, not by
inspection — which is the argument for running negative controls on assertions and
not only on designs.

### Row order and the sign of Gy

Window row 0 is the newest line, row 2 the oldest — so row 2 is the *top* of the
picture and the `gy` computed in the module is negated relative to the kernel
above. It does not matter, because the output is `|Gy|`. It would matter for a
direction output, which is the usual way this gets discovered.

And one alignment fact that is easy to miss: **the output pixel is centred on the
middle row**, one line above the beat that produced it. A Sobel pipeline on a
3-tap line buffer shifts the picture down by one line unless the sideband is
re-timed to match ([docs/21](21-pipelining.md)).

---
## 11. Sideband is not just TLAST

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

### Start-of-line is not start-of-frame

`vid_axis_win3` needs to know whether the beat it is describing begins a line, so
that it replicates the left halo instead of using stale data. It derives that from
the **previous beat's TLAST**, not from `TUSER[0]`:

```systemverilog
in_first <= s_tlast;        // the next beat loaded starts a line
```

`TUSER[0]` marks the start of a *frame*, which is a strictly weaker piece of
information — every frame starts a line, but most lines do not start a frame. A
module that keyed off `TUSER` would replicate the halo correctly on the first line
of each frame and nowhere else.

The consequence is a requirement on the stream, and it is worth stating plainly:
**every line must end with TLAST, including the last line of a frame.** A
truncated final line leaves the next frame's first beat looking like a
continuation of the last one. The frame testbench sends a complete flush line
rather than two loose beats for exactly this reason.

### A neighbourhood pipeline cannot be drained

This one is structural, and it bit the testbench before it could have bitten a
design. When the stream stops:

- the line buffer is still holding the last beat, because it emits beat `k`'s rows
  when beat `k+1` arrives;
- the window builder is still holding the beat before it, because it needs the
  next beat for the right halo.

Sending extra beats does not fix it — it moves the problem to whatever arrives
last. There is no flush, by construction. A real pipeline either accepts that the
tail of a frame emerges with the head of the next one, or injects a dummy line it
then discards.

In the testbench this appeared as a **TLAST in the wrong place one pass after the
pass that caused it**: two stale beats came out as the first outputs of the next
frame and shifted every check by one beat. The fix there is to reset between
frames, which is also the honest thing to do in hardware if the stream really can
stop mid-frame.

---

## 12. Testing a claim about all parameter values

Genericity is a claim about *all* parameter values, so testing one is close to
testing none. [`video_tb.sv`](../examples/tb/video_tb.sv) instantiates the
arithmetic blocks five times over, in a generate loop, chosen to break different
things:

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

### Frames, not beats, for the neighbourhood filters

[`video_filter_tb.sv`](../examples/tb/video_filter_tb.sv) runs the whole
line buffer → window → median + Sobel chain over five frames. Both filters are
driven from the **same** window, which is the point of splitting the window
builder out: the expensive part, a line of memory per tap, is paid once however
many filters read it. (And the fan-out needs `win_tready = med_tready &&
sob_tready`; forgetting the AND lets the faster consumer see beats the slower one
misses.)

| pass | frame | what it establishes |
|---|---|---|
| 0 | random | every output pixel against a clamped-coordinate frame model |
| 1 | random, with random backpressure | the same, with the handshake exercised |
| 2 | flat | median passes it unchanged; Sobel outputs zero — **no model** |
| 3 | salt and pepper on a flat field | every impulse removed — **no model** |
| 4 | vertical step edge | Sobel lights exactly the two columns at the step — **no model** |

Passes 2 to 4 are the ones worth copying. Pass 3 is the filter's actual job stated
without arithmetic: a lone outlier among eight equal neighbours must vanish. Pass 4
pins the gradient's *orientation* and magnitude from the kernel by hand
(`(1+2+1)*MAXV >> SHIFT`), so it is a claim about the filter rather than a
comparison of two models.

Two things this testbench got wrong before it got them right, both worth
remembering:

- **A flat frame is a weak test and an impulse on the edge is not an impulse.**
  Clamp-to-edge replicates the boundary pixel, so an outlier in the first or last
  column appears two or three times per row of the window — six of nine taps at a
  corner. The median keeps it, correctly. The stimulus now keeps impulses off the
  edge and says why.
- **A saturating configuration hides arithmetic.** See `SHIFT` in section 10.

### The whole mutation matrix

Every deliberate mutation run against every check, in one table. This is the only
honest way to describe what a verification flow catches:

| mutation | frame TB | in-module asserts | module proof | network proof |
|---|---|---|---|---|
| median: drop a compare-exchange | FAIL | — | — | FAIL |
| median: window column `c` for `n+c` | FAIL | — | — | **PASS** |
| Sobel: kernel weight 2 → 1 | FAIL | FAIL | FAIL | — |
| Sobel: patch index `r`↔`c` | **PASS** | FAIL | FAIL | — |
| Sobel: `Gx` sign flipped | **PASS** | **PASS** | **PASS** | — |
| CSC: coefficient index transposed | FAIL | — | `ident` **PASS**, `basis` FAIL | — |

Four of the six rows contain a PASS that looks like a hole. Two of them really are
holes that another check closes (the transposed patch index, the transposed
coefficient index); one is a limit of scope (a kernel proof cannot see its
wiring); and one is not a hole at all but a consequence of what the output
contains (a sign error under an absolute value). Knowing which is which is the
difference between a verification plan and a pile of tests.

---

## 13. Tool constraints you will hit

Every one of these was hit writing the modules in this document, and each cost a
build.

### The Yosys frontend

| Construct | What happens |
|---|---|
| unpacked array **port** | rejected |
| `import pkg::*;` in a module body | rejected |
| `import pkg::*;` at compilation-unit scope | **crashes** with an internal assertion failure |
| `pkg::func(...)` fully scoped | works everywhere — use this |
| **labelled** immediate assert inside a generate loop | "a cell with the same name was already created" — labels are not uniquified by scope, so leave them off |
| `+: WIDTH` where `WIDTH` is a function *argument* | "not a constant" — a part-select width must be an elaboration-time constant |
| reading `arr[idx]` in the `always_comb` that assigns `arr` | infers a latch, even when the index is provably already written |
| indexing a function call result | rejected |
| hierarchical reference into an instance (`dut.win`) | "Don't know how to detect sign and width for AST_AUTOWIRE node" |
| the same reference inside a function | "Failed to detect width for identifier ...dut.win" |
| `break` | "Can't resolve task name `break'" |

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

**A function that needs several outputs returns a packed vector** — and the caller
must *name* the result before indexing it, because a part-select of a call is
rejected:

```systemverilog
logic [3*W-1:0] srow;
srow = srt3(a, b, c);          // then srow[k*W +: W]
// NOT srt3(a, b, c)[k*W +: W]
```

### XSIM: two silent wrong answers

Both of these were found in this work, both produce **no error message**, and both
have minimal reproducers below. They are the reason this section exists.

**1. A `while` condition containing a cast is evaluated as false.**

```systemverilog
localparam int unsigned NBU = 24;
int k;
k = 0;
while (k < int'(NBU)) k++;        // k == 0 afterwards. The loop never runs.
$display("%0d %b", int'(NBU), (k < int'(NBU)));   // prints "24 1"
```

The identical expression is `1` when printed and false as a loop condition.
Probed variants, all in one file:

| form | iterations |
|---|---|
| `while (k < int'(NBU))` — `NBU` is `int unsigned` | **0** |
| `while (k < int'(NBS))` — `NBS` is `int` | **0** |
| `while (k < NBU)` — no cast | 24 |
| `for (int i = 0; i < int'(NBU); i++)` | 24 |
| in an `initial` block rather than a task | **0** |
| inside an automatic task, with or without `@(negedge clk)` in the body | **0** |

This is as bad as a tool bug gets, because the failure mode is a **loop body that
never executes**. In a testbench that means checks that never run: the collector
in `video_filter_tb.sv` was silently dead, the testbench printed PASS, and it
missed a deliberately broken Sobel kernel. It was found only by mutating the
design and noticing that nothing complained.

The fix is to keep casts out of `while` conditions — declare the bound as a signed
`int` and compare bare. The repository contains no other `while` with a cast in it;
that was checked after this was found, and it is worth checking in any codebase
that is simulated with XSIM.

**2. `$past()` of a part-select of a wide vector returns a wrong value.**

```systemverilog
logic [287:0] wide;
logic [7:0]   shadow;
always_ff @(posedge clk) begin
  wide   <= ...;
  shadow <= wide[0 +: 8];        // an ordinary register: the correct answer
end

// FAILS, on a design where the shadow-register version passes:
a: assert property (@(posedge clk) trigger |=> (out == {6{$past(wide[0 +: 8])}}));
```

Probed against known values, the returned value is **none** of: the previous
sample, the current sample, two samples back, zero, or X. Width of the *parent*
matters:

| parent width | `$past(parent[0 +: 8])` |
|---|---|
| 16, 32, 33 bits | correct |
| 40, 48, 63, 64, 65, 128, 288 bits | **wrong** |
| whole vector, `$past(parent)`, any width | correct |

It is not even stable: adding unrelated code to the same file made a failing
assertion pass. Whatever the mechanism, the rule that follows is simple — **take
`$past` of the whole vector, or capture what you need in an ordinary register**:

```systemverilog
logic         flat_q;
logic [B-1:0] flat_val_q;
always_ff @(posedge clk) begin
  flat_q     <= <the antecedent>;
  flat_val_q <= s_win[0 +: B];
end
a_flat_passes: assert property (@(posedge clk) disable iff (!rst_n)
  flat_q |-> (m_tdata == {(N*P){flat_val_q}}));
```

Two registers, no ambiguity, and it works in every tool. Note that the same
`$past`-of-a-slice idiom is used in `formal/vid_axis_csc_fv.sv` and works
correctly **there**, because that harness runs under Yosys and sby — the
constraint is XSIM's, not SystemVerilog's.

XSIM is explicit about one related weakness, which makes the silence about the
second all the stranger: `$past` in an **action block** raises *"Unable to infer clocking event for
system function call past. Please provide explicit clocking event argument as
workaround."* Inside a property it stays silent instead.

### sby and proof depth

| symptom | cause |
|---|---|
| `cover` reports every point "unreached" at `depth 1` | cover points need a clock edge to have happened; assertions in `always @(posedge clk)` are checked in step 0 |
| a two-instance equivalence fails immediately under `prove` | induction starts from an arbitrary state where the two instances' registers are unrelated — make it a `bmc` task |
| a counter-difference bound returns UNKNOWN under `prove` | a bound is not inductive; assert the exact occupancy instead (section 8) |

---

## 14. Checklist

**Layout**
- [ ] One layout rule, written in a package, used by every module.
- [ ] Pixel-major / component-minor unless something external forces otherwise.
- [ ] `TLAST` and `TUSER[0]` meanings documented.
- [ ] Row bundles and windows indexed by the same rule, with a flattened pixel
      index — not a second convention.
- [ ] Package functions referenced fully scoped, not imported.

**Structure**
- [ ] Ports flat; unpacked arrays inside.
- [ ] Unpack and repack in generate loops, so the indexing expression appears
      exactly twice.
- [ ] Generate loops for declarations, instances and replication; procedural
      loops for reductions.
- [ ] A reduction that is deeper than about eight terms written as a tree, not a
      chain.
- [ ] The loop nest chosen from the dataflow (`N` engines or `N*P`?), not copied
      from the previous module.
- [ ] Every generate block labelled; immediate asserts inside them unlabelled.
- [ ] Cell counts swept across a parameter once, and they scale the way the nest
      says they should.

**Degenerate parameters**
- [ ] `N=1` and `P=1` elaborate and work.
- [ ] Loops that run zero times leave nothing undriven.
- [ ] Every `$clog2` of a possibly-1 parameter guarded.

**Arithmetic**
- [ ] Accumulator width computed from `CW + B + ceil(log2 P)` plus sign and
      rounding headroom, not guessed.
- [ ] Every operand widened *and* signed before arithmetic; unsigned components
      extended with an explicit `{1'b0, ...}`.
- [ ] Results clamped, never wrapped.
- [ ] Any approximation (L1 for a magnitude, a truncated shift) documented with
      its worst-case error.

**Memory and windows**
- [ ] Depth from `ceil(MAX_WIDTH / N)`, rounding up.
- [ ] Read/write address collision impossible, and asserted.
- [ ] Line-length requirement stated and checked.
- [ ] Halo `H <= N`, or the lookahead is more than one beat.
- [ ] Edge policy chosen (replicate, not zero) and the same one vertically and
      horizontally.
- [ ] One fan-out `ready` per consumer, ANDed at the producer.

**Sideband**
- [ ] Every signal consulted to interpret a beat is delayed like that beat —
      counters included.
- [ ] Start-of-line derived from the previous `TLAST`, not from `TUSER`.
- [ ] Known which output row the result is centred on, and the sideband re-timed
      to match.
- [ ] Known what happens to the last beat when the stream stops.

**Verification**
- [ ] At least one degenerate configuration (`N=1, P=1`) in the sweep.
- [ ] At least one `B` that is not a multiple of 8.
- [ ] Per-component test values all different.
- [ ] At least one check that uses **no** reference model.
- [ ] Coefficient and window indexing checked with something **asymmetric** —
      identity and transposition symmetries will not catch a transpose.
- [ ] Assertion premises read the input through a *different* expression from the
      data path, or they cannot test the mapping.
- [ ] The test configuration does not saturate.
- [ ] Clamp proved with coefficients left free, not only for the matrices you
      happened to try.
- [ ] Every property negative-controlled: mutate the design, confirm the check
      fails, and write down which checks did *not*.

---

## See also

- [docs/06: Modules, parameters, generate](06-modules-parameters-generate.md) —
  the language rules behind section 4
- [docs/17: Signed and unsigned](17-signed-unsigned-arithmetic.md) — trap T6b,
  which this arithmetic walks straight into
- [docs/18: Fixed point](18-fixed-point-arithmetic.md) — rounding, guard bits,
  saturation
- [docs/21: Pipelining](21-pipelining.md) — latency matching for sideband
- [docs/23: Structural design techniques](23-structural-design-techniques.md) —
  sorting networks, systolic structures, the 0-1 principle
- [docs/25: Formal verification](25-formal-verification-with-sby.md) — task
  layout, negative controls, the Yosys subset
- [docs/27: Control structures](27-control-structures.md) — generate versus
  procedural loops in general, chains versus trees
- [docs/29: Memories](29-memories-and-inference.md) — BRAM aspect ratios and
  inference rules
- [docs/30: Flow control](30-flow-control-and-handshakes.md) — the valid/ready
  contract these blocks obey
- [docs/33: Debugging and bring-up](33-debugging-and-bringup.md) — why the build
  fails on a failing SVA even when the testbench prints PASS
- [docs/34: Coding conventions](34-coding-conventions-and-reuse.md) — degenerate
  parameters, derived widths
- [docs/36: Common peripherals](36-common-peripheral-modules.md) — the same
  parameterisation discipline on simpler blocks
