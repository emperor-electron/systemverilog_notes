# Floating-Point Arithmetic in Hardware

SystemVerilog gives you `real` and `shortreal`, but **they are simulation-only**.
No synthesis tool infers an FPU from `a * b` where `a` and `b` are `real`. To
put floating point in silicon you build the datapath out of integer operations
on the sign/exponent/mantissa fields yourself, or you instantiate a vendor IP
block.

This document covers the formats, the algorithms, the SystemVerilog-specific
pitfalls, and how to verify the result.

Companion code:
[`examples/arith/fp_pkg.sv`](../examples/arith/fp_pkg.sv) ·
[`fp_add.sv`](../examples/arith/fp_add.sv) ·
[`fp_mul.sv`](../examples/arith/fp_mul.sv) ·
[`fp_classify.sv`](../examples/arith/fp_classify.sv) ·
[`fp_tb.sv`](../examples/tb/fp_tb.sv)

---

## Contents

- [1. `real` and `shortreal` in the language](#1-real-and-shortreal-in-the-language)
- [2. IEEE 754 formats](#2-ieee-754-formats)
- [3. Decoding a float](#3-decoding-a-float)
- [4. Special values](#4-special-values)
- [5. Rounding](#5-rounding)
- [6. The adder](#6-the-adder)
- [7. The multiplier](#7-the-multiplier)
- [8. Comparison and the integer-compare trick](#8-comparison-and-the-integer-compare-trick)
- [9. Conversions](#9-conversions)
- [10. Fused multiply-add](#10-fused-multiply-add)
- [11. Subnormals and flush-to-zero](#11-subnormals-and-flush-to-zero)
- [12. Exception flags](#12-exception-flags)
- [13. Cost, latency, pipelining](#13-cost-latency-pipelining)
- [14. Reduced-precision formats for ML](#14-reduced-precision-formats-for-ml)
- [15. Alternatives to floating point](#15-alternatives-to-floating-point)
- [16. Verification](#16-verification)

---

## 1. `real` and `shortreal` in the language

```systemverilog
real      d;      // 64-bit IEEE 754 binary64 (C `double`)
shortreal f;      // 32-bit IEEE 754 binary32 (C `float`)
realtime  t;      // same as real, used for time
```

Behaviour:

- **Always 2-state.** There is no `X` or `Z` real. An uninitialized `real` is
  `0.0`, which means a real-valued model will never show you an
  uninitialized-signal bug.
- Default initial value `0.0`.
- Cannot be bit-selected, part-selected, or concatenated. Use the conversion
  functions below.
- `real` in an expression with an integer promotes the integer to `real`.
- Assigning `real` to an integral type **rounds to nearest, ties away from
  zero** (not ties-to-even — this differs from IEEE default and from C's
  truncation).

```systemverilog
int i;
i = 2.5;     // 3
i = 3.5;     // 4
i = -2.5;    // -3
i = $rtoi(2.9);   // 2  -- $rtoi truncates toward zero
```

### Bit-level access

```systemverilog
logic [63:0] db;   logic [31:0] fb;
real r;            shortreal s;

db = $realtobits(r);         r = $bitstoreal(db);
fb = $shortrealtobits(s);    s = $bitstoshortreal(fb);

// value conversions (NOT bit reinterpretation)
r  = $itor(42);              i = $rtoi(r);
```

`$realtobits` gives you the raw IEEE encoding — this is the bridge between a
real-number golden model and a bit-accurate RTL implementation, and it is how
the testbench in [`examples/tb/fp_tb.sv`](../examples/tb/fp_tb.sv) works.

### Math functions **[V]**

```systemverilog
$sqrt $pow $exp $ln $log10 $floor $ceil $fabs
$sin $cos $tan $asin $acos $atan $atan2 $hypot
$sinh $cosh $tanh $asinh $acosh $atanh
```

All take and return `real`. All simulation-only.

### What is and is not synthesizable

| Construct | Synthesizable |
|---|---|
| `real`, `shortreal` variables and arithmetic | **no** |
| `$sqrt`, `$exp`, ... | **no** |
| A `real` used in a **parameter/localparam** expression evaluated at elaboration | **yes** — the result is a constant |
| Integer datapath operating on `logic [31:0]` float fields | yes |

That third row is genuinely useful:

```systemverilog
// Elaboration-time: compute fixed-point coefficients from real values
localparam real COEF_R [0:3] = '{0.2929, 0.5, 0.2929, 0.0};
localparam int  FRAC     = 12;
localparam logic signed [15:0] COEF [0:3] = '{
  16'(int'(COEF_R[0] * (2.0 ** FRAC))),
  16'(int'(COEF_R[1] * (2.0 ** FRAC))),
  16'(int'(COEF_R[2] * (2.0 ** FRAC))),
  16'(int'(COEF_R[3] * (2.0 ** FRAC)))
};
```

The `real` math happens in the elaborator; the hardware sees only integers.

---

## 2. IEEE 754 formats

A float is `{sign, exponent, mantissa}` packed MSB-first.

| Format | Total | Sign | Exp | Mant | Bias | Decimal digits | Max | Min normal |
|---|---|---|---|---|---|---|---|---|
| binary16 (`half`, FP16) | 16 | 1 | 5 | 10 | 15 | ~3.3 | 65504 | 6.10e−5 |
| bfloat16 (`bf16`) | 16 | 1 | **8** | **7** | 127 | ~2.4 | 3.39e38 | 1.18e−38 |
| TF32 (NVIDIA) | 19* | 1 | 8 | 10 | 127 | ~3.3 | 3.39e38 | 1.18e−38 |
| binary32 (`float`) | 32 | 1 | 8 | 23 | 127 | ~7.2 | 3.40e38 | 1.18e−38 |
| binary64 (`double`) | 64 | 1 | 11 | 52 | 1023 | ~15.9 | 1.80e308 | 2.23e−308 |
| binary128 (`quad`) | 128 | 1 | 15 | 112 | 16383 | ~34 | 1.19e4932 | 3.36e−4932 |
| FP8 E4M3 | 8 | 1 | 4 | 3 | 7 | ~0.9 | 448 | 1.95e−3 |
| FP8 E5M2 | 8 | 1 | 5 | 2 | 15 | ~0.6 | 57344 | 6.1e−5 |

\* TF32 is stored in a 32-bit container; only 19 bits are significant.

The general parameterization:

```systemverilog
package fp_pkg;
  // A format is fully described by (EXP_W, MAN_W).
  function automatic int bias(int exp_w);  return (1 << (exp_w-1)) - 1;  endfunction

  localparam int FP32_E = 8,  FP32_M = 23;
  localparam int FP16_E = 5,  FP16_M = 10;
  localparam int BF16_E = 8,  BF16_M = 7;
endpackage
```

Note that **bfloat16 is just binary32 with the low 16 mantissa bits chopped
off.** Conversion fp32→bf16 is a truncation (or a round); bf16→fp32 is
zero-padding. That is the entire reason bf16 won in ML accelerators: the
exponent range matches fp32, so no rescaling is needed, and the conversion is
free.

---

## 3. Decoding a float

Given `{s, e, m}` with `E` exponent bits, `M` mantissa bits, `bias = 2^(E-1)-1`:

| `e` | `m` | Class | Value |
|---|---|---|---|
| `0` | `0` | **zero** | `(-1)^s * 0.0` (signed zero) |
| `0` | `≠0` | **subnormal** | `(-1)^s * 2^(1-bias) * 0.m` |
| `1 .. 2^E-2` | any | **normal** | `(-1)^s * 2^(e-bias) * 1.m` |
| `2^E-1` | `0` | **infinity** | `(-1)^s * ∞` |
| `2^E-1` | `≠0` | **NaN** | quiet if `m[M-1]==1`, signalling otherwise |

The **implicit leading 1** is the trick that buys one free bit of precision:
normal numbers always have a leading `1.` that is not stored. Subnormals have a
leading `0.` and a *fixed* exponent of `1-bias`, which is what lets the number
line degrade gracefully to zero instead of falling off a cliff.

```systemverilog
// 1.0f  = 0 01111111 00000000000000000000000 = 32'h3F80_0000
// -2.0f = 1 10000000 00000000000000000000000 = 32'hC000_0000
// 0.1f  = 0 01111011 10011001100110011001101 = 32'h3DCC_CCCD  (inexact!)
// inf   = 0 11111111 00000000000000000000000 = 32'h7F80_0000
// qNaN  = 0 11111111 10000000000000000000000 = 32'h7FC0_0000
```

### Classifier in SystemVerilog

```systemverilog
typedef enum logic [3:0] {
  FP_NEG_INF, FP_NEG_NORM, FP_NEG_SUB, FP_NEG_ZERO,
  FP_POS_ZERO, FP_POS_SUB, FP_POS_NORM, FP_POS_INF,
  FP_SNAN, FP_QNAN
} fp_class_e;

function automatic fp_class_e classify #(...) (input logic [E+M:0] x);
  logic       s     = x[E+M];
  logic [E-1:0] e   = x[E+M-1 -: E];
  logic [M-1:0] m   = x[M-1:0];
  logic exp_all_1   = &e;
  logic exp_all_0   = ~|e;
  logic man_zero    = ~|m;
  ...
endfunction
```

Full version in [`examples/arith/fp_classify.sv`](../examples/arith/fp_classify.sv).

---

## 4. Special values

The rules your hardware must implement, in priority order:

1. **Any NaN input → quiet NaN output.** If an input is a signalling NaN, raise
   the *invalid* flag and quiet it (set the MSB of the mantissa). Most hardware
   emits a canonical qNaN (`0x7FC00000` for fp32) rather than propagating the
   payload; RISC-V mandates the canonical one, x86 propagates.
2. **Invalid operations → qNaN + invalid flag:**
   `∞ − ∞`, `0 × ∞`, `0/0`, `∞/∞`, `sqrt(negative)`, `fmod(x, 0)`.
3. **Infinity propagates:** `∞ + finite = ∞`, `∞ × finite≠0 = ∞`.
4. **Division by zero → ∞ + divide-by-zero flag** (for a nonzero numerator).
5. **Signed zero:** `+0 + -0 = +0` in round-to-nearest (and `-0` in
   round-toward-−∞). `x - x = +0`. `(-0) * (+5) = -0`. `1/(+0) = +∞`,
   `1/(-0) = −∞`. Sign of zero only matters through division and through
   `copysign`, but getting it wrong is a conformance failure.
6. **Comparison with NaN is always false**, including `NaN == NaN`. `!=` is the
   exception: `NaN != NaN` is true.

```systemverilog
// Canonical constants, fp32
localparam logic [31:0] FP32_QNAN  = 32'h7FC0_0000;
localparam logic [31:0] FP32_PINF  = 32'h7F80_0000;
localparam logic [31:0] FP32_NINF  = 32'hFF80_0000;
localparam logic [31:0] FP32_PZERO = 32'h0000_0000;
localparam logic [31:0] FP32_NZERO = 32'h8000_0000;
localparam logic [31:0] FP32_MAX   = 32'h7F7F_FFFF;
localparam logic [31:0] FP32_MIN_N = 32'h0080_0000;   // smallest normal
localparam logic [31:0] FP32_MIN_S = 32'h0000_0001;   // smallest subnormal
```

---

## 5. Rounding

IEEE 754 defines five rounding modes. RISC-V encodes them in `frm[2:0]`:

| Mode | RISC-V `frm` | Behaviour |
|---|---|---|
| RNE — round to nearest, ties to **even** | `000` | **the default**; unbiased |
| RTZ — round toward zero | `001` | truncate |
| RDN — round down (toward −∞) | `010` | floor |
| RUP — round up (toward +∞) | `011` | ceiling |
| RMM — round to nearest, ties to **max magnitude** | `100` | ties away from zero |

### Guard, round, sticky

To round correctly you need three bits below the result LSB:

```
   result LSB │ G │ R │ S
        (L)   │   │   │ └── sticky: OR of every bit shifted out below R
              │   │   └──── round bit: the "half" bit
              │   └──────── guard: needed during normalization, becomes R
              └──────────── the last bit you keep
```

In practice most implementations keep `{L, R, S}` where `S` accumulates
everything below `R`. The increment condition for **round-to-nearest-even** is:

```systemverilog
// L = result LSB, R = round bit, S = sticky (OR of all lower bits)
assign round_up = R & (S | L);
```

- `R=0`: below half → never round up.
- `R=1, S=1`: above half → always round up.
- `R=1, S=0`: exactly half → round up only if `L=1`, i.e. round to the even
  neighbour.

All five modes:

```systemverilog
function automatic logic round_up_f(
    input logic [2:0] frm,   // 000 RNE, 001 RTZ, 010 RDN, 011 RUP, 100 RMM
    input logic       sign,  // sign of the result
    input logic       L, R, S);
  case (frm)
    3'b000:  return  R & (S | L);        // RNE
    3'b001:  return  1'b0;               // RTZ
    3'b010:  return  sign & (R | S);     // RDN: round away only if negative
    3'b011:  return ~sign & (R | S);     // RUP
    3'b100:  return  R;                  // RMM
    default: return  R & (S | L);
  endcase
endfunction
```

**Rounding can overflow the mantissa.** `1.111...1 + ulp` becomes `10.000...0`,
which requires incrementing the exponent and shifting right by one. Because the
new mantissa is all zeros, no re-rounding is needed — but the exponent
increment can itself overflow to infinity. Handle both.

### The sticky bit is not optional

Computing sticky correctly is the most commonly botched part of an FP unit. It
must be the OR of **every** bit shifted out, including through a variable-length
alignment shift of up to `M+3` positions. Two implementations:

```systemverilog
// (a) Shift a wide value and OR the discarded bits. Simple, wide.
logic [2*M+4:0] wide = {mant, {(M+4){1'b0}}};
logic [2*M+4:0] shifted = wide >> shamt;
assign sticky = |(wide & ~({(2*M+5){1'b1}} << shamt));

// (b) Sticky-from-shift-amount: a mask compare. Cheaper.
assign sticky = |(mant & ((1 << shamt) - 1));
```

For alignment shifts that can exceed the mantissa width, clamp the shift amount
to `M+3` and set sticky if the original amount was larger — everything below
that point is sticky anyway.

---

## 6. The adder

Floating-point addition is harder than multiplication. The stages:

```
  1. unpack        split s/e/m, insert implicit 1, detect specials
  2. swap          order operands so |a| >= |b|  (compare exponents, then mantissas)
  3. align         right-shift the smaller mantissa by (ea - eb), accumulate sticky
  4. add/sub       effective operation = op XOR sa XOR sb
  5. normalize     leading-zero count + left shift (subtraction), or
                   right shift by 1 (addition carry-out)
  6. round         GRS -> increment; may renormalize again
  7. pack          reassemble, apply special-case overrides
```

### Why subtraction is the hard case

When two nearly-equal numbers are subtracted, the result can have up to `M`
leading zeros — **massive cancellation**. Normalizing needs a full
leading-zero counter and a barrel shifter across the whole mantissa. This is
the critical path.

The classic optimization is the **two-path adder** (far path / close path):

| Path | Condition | Work needed |
|---|---|---|
| **Far** | `|ea − eb| > 1`, or same-sign add | big alignment shift, but normalization is at most 1 bit |
| **Close** | `|ea − eb| ≤ 1` and effective subtract | alignment is at most 1 bit, but normalization needs a full LZC + shift |

Neither path needs both a large aligner and a large normalizer, so the two run
in parallel and a mux picks the answer — roughly halving the critical path at
the cost of ~1.4× the area. Single-path is fine for a pipelined design where
you can just add a stage.

### Skeleton

```systemverilog
// See examples/arith/fp_add.sv for the complete, tested version.
module fp_add #(parameter int E = 8, parameter int M = 23) (
  input  logic [E+M:0] a, b,
  input  logic         sub,        // 1 => a - b
  input  logic [2:0]   frm,
  output logic [E+M:0] y,
  output logic [4:0]   flags       // NV DZ OF UF NX
);
  localparam int BIAS = (1 << (E-1)) - 1;
  localparam int MW   = M + 1;     // mantissa with implicit bit
  localparam int GW   = MW + 3;    // + guard, round, sticky

  // 1. unpack -----------------------------------------------------------
  logic         sa, sb;
  logic [E-1:0] ea, eb;
  logic [M-1:0] ma, mb;
  assign {sa, ea, ma} = a;
  assign {sb, eb, mb} = b;
  logic sb_eff = sb ^ sub;

  logic a_sub = ~|ea,  b_sub = ~|eb;             // subnormal (or zero)
  logic [MW-1:0] fa = {~a_sub, ma};              // implicit bit
  logic [MW-1:0] fb = {~b_sub, mb};
  // subnormals have an effective exponent of 1, not 0
  logic [E-1:0] eax = a_sub ? 1 : ea;
  logic [E-1:0] ebx = b_sub ? 1 : eb;
  ...
endmodule
```

The `a_sub ? 1 : ea` line is the standard way to fold subnormals into the
normal path: a subnormal's value is `2^(1-bias) * 0.m`, which is the same as
using exponent `1` with a leading `0` in the mantissa.

---

## 7. The multiplier

Much simpler than the adder — no alignment, no massive cancellation.

```
  1. unpack
  2. sign      sy = sa ^ sb
  3. exponent  ey = ea + eb - bias
  4. mantissa  p  = fa * fb          (MW x MW -> 2*MW bits)
  5. normalize p[2MW-1] set => shift right 1, ey++   (product is in [1,4))
  6. round
  7. pack, handle overflow to inf / underflow to subnormal or zero
```

The product of two values in `[1,2)` is in `[1,4)`, so **at most one** bit of
normalization is needed. The sticky bit is the OR of all the bits below the
round position of the `2*MW`-bit product — free, since you already have them.

```systemverilog
localparam int MW = M + 1;
logic [2*MW-1:0] prod;
assign prod = fa * fb;                    // both unsigned -> unsigned multiply

logic norm_shift = prod[2*MW-1];          // product >= 2.0
logic [MW-1:0] mant_pre;
logic          rbit, sticky;
always_comb begin
  if (norm_shift) begin
    mant_pre = prod[2*MW-1 -: MW];
    rbit     = prod[MW-1];
    sticky   = |prod[MW-2:0];
  end else begin
    mant_pre = prod[2*MW-2 -: MW];
    rbit     = prod[MW-2];
    sticky   = |prod[MW-3:0];
  end
end
```

### Exponent arithmetic needs signed intermediate

```systemverilog
// ea + eb - BIAS can go negative (underflow) or exceed 2^E-2 (overflow).
// Compute it in a wider SIGNED value or the wrap will silently produce a
// plausible-looking wrong answer.
logic signed [E+2:0] exp_sum;
assign exp_sum = signed'({2'b00, eax}) + signed'({2'b00, ebx})
               - signed'(E'(BIAS)) + signed'({{(E+2){1'b0}}, norm_shift});

logic overflow  = (exp_sum >= signed'((1 << E) - 1));
logic underflow = (exp_sum <= 0);
```

This is exactly the trap from
[docs/17](17-signed-unsigned-arithmetic.md#8-the-trap-catalogue): `ea + eb -
BIAS` on `logic [E-1:0]` operands evaluates at `E` bits and wraps. Always widen
and sign the exponent path.

---

## 8. Comparison and the integer-compare trick

IEEE 754 formats are designed so that, **for values of the same sign**, the
bit pattern interpreted as an unsigned integer orders identically to the float.
That gives a cheap comparator:

```systemverilog
// Total-order compare of two IEEE floats using one integer comparator.
function automatic logic fp_lt #(int W = 32) (input logic [W-1:0] a, b);
  // Map to a monotonic unsigned key:
  //   positive: flip the sign bit       (0x3F80.. -> 0xBF80..)
  //   negative: flip every bit          (0xBF80.. -> 0x407F..)
  logic [W-1:0] ka = a[W-1] ? ~a : (a | (1 << (W-1)));
  logic [W-1:0] kb = b[W-1] ? ~b : (b | (1 << (W-1)));
  return ka < kb;
endfunction
```

Caveats: this gives a *total order* including NaN (which sorts at the ends) and
distinguishes `+0` from `−0`. IEEE comparison requires `+0 == −0` and requires
every comparison with NaN to be false, so a conforming comparator needs:

```systemverilog
logic a_nan = (&a[W-2 -: E]) && |a[M-1:0];
logic b_nan = ...;
logic both_zero = (~|a[W-2:0]) && (~|b[W-2:0]);
assign eq = !a_nan && !b_nan && ((a == b) || both_zero);
assign lt = !a_nan && !b_nan && !both_zero && fp_lt(a, b);
assign unordered = a_nan || b_nan;      // raises NV for signalling compares
```

The same monotonic-key trick is what makes it legal to **sort float arrays with
an integer sorter** and to use floats as keys in a radix sort.

---

## 9. Conversions

### Float → integer

```
 1. classify: NaN or |x| too large -> saturate + invalid flag
 2. shift the mantissa by (exp - bias - M); left if positive, right if negative
 3. round per the current mode (RTZ for C-style casts, RNE for fcvt with rm)
 4. negate if the sign bit is set (two's complement)
 5. saturate to the destination range
```

IEEE says out-of-range conversions raise *invalid* and the result is
implementation-defined; RISC-V mandates saturation to the min/max integer, x86
returns the "integer indefinite" value. Pick one and document it.

### Integer → float

```
 1. absolute value (watch the most-negative input! see docs/17)
 2. leading-zero count -> exponent = bias + (W-1-lzc)
 3. left-shift to normalize, capture GRS from the bits shifted past
 4. round; may increment the exponent
```

A 32-bit integer does not fit in fp32's 24-bit mantissa, so `int -> float` is
**lossy and must round**. `int -> double` is exact.

### Float → float

- **Widening** (fp16→fp32, bf16→fp32) is always exact. Re-bias the exponent and
  zero-pad the mantissa. Subnormals in the narrow format become normals in the
  wide one, which requires a normalizing shift — the only non-trivial part.
- **Narrowing** must round, and can overflow to infinity or underflow to
  subnormal/zero. This is the "double rounding" hazard: rounding fp64→fp32→fp16
  can differ from fp64→fp16 directly.

```systemverilog
// fp32 -> bf16 with round-to-nearest-even. The whole conversion.
function automatic logic [15:0] fp32_to_bf16(input logic [31:0] x);
  logic [15:0] lsb_and_round;
  logic        round_up;
  if ((&x[30:23]) && |x[22:0]) return 16'h7FC0;      // NaN -> canonical qNaN
  round_up = x[15] & (|x[14:0] | x[16]);             // R & (S | L)
  return x[31:16] + 16'(round_up);
endfunction
```

That is genuinely the entire bf16 conversion — a 16-bit add. Hence its
popularity.

---

## 10. Fused multiply-add

`fma(a, b, c) = a*b + c` computed with **one** rounding at the end, instead of
rounding the product and then rounding the sum.

Why it matters in hardware:

- **More accurate:** the product is kept at full `2*MW` bits before the add.
- **Cheaper than mul+add:** one rounder, one normalizer.
- **Enables Newton–Raphson division and sqrt** to converge with provably correct
  final rounding.
- It is the core of every systolic matrix unit.

Cost: the aligner must handle the addend being far above or far below the
product, so the internal datapath is roughly `3*MW` bits wide, and the
normalizer must span it. An FMA is ~1.5–2× the area of a standalone multiplier
and has a longer critical path — which is why they are always pipelined 3–5
deep.

```
  align window for c relative to a*b:
  |<-- MW -->|<------- 2*MW ------->|<-- MW -->|
     c above        product             c below (becomes sticky)
```

---

## 11. Subnormals and flush-to-zero

Subnormal (denormal) support is expensive:

- **Input side:** a subnormal operand needs a leading-zero count and a
  normalizing shift before it can enter the normal datapath — an extra shifter
  and often an extra pipeline stage.
- **Output side:** a result that underflows must be shifted *right* into the
  subnormal range and re-rounded, which means a second rounding step.

So most hardware offers **flush-to-zero (FTZ)** and **denormals-are-zero (DAZ)**
modes:

| Mode | Effect |
|---|---|
| DAZ | subnormal *inputs* are treated as `±0` |
| FTZ | subnormal *results* are replaced by `±0` (with the underflow flag) |

GPUs and ML accelerators almost universally run FTZ+DAZ. CPUs implement full
subnormals, sometimes with a microcode trap that costs hundreds of cycles.
RISC-V `F`/`D` extensions **require** full subnormal support in hardware.

Decide this at the top of your design and parameterize it:

```systemverilog
module fp_add #(parameter int E = 8, parameter int M = 23,
                parameter bit SUBNORMAL_EN = 1'b1) (...);
```

With `SUBNORMAL_EN = 0` the input normalizer and output denormalizer are
removed by constant propagation, and you get a noticeably smaller unit.

---

## 12. Exception flags

Five sticky flags, in RISC-V `fflags` bit order (bit 4 down to bit 0):

| Bit | Flag | Raised when |
|---|---|---|
| 4 | **NV** invalid | NaN input to an arithmetic op, `∞−∞`, `0×∞`, `0/0`, `sqrt(−x)`, out-of-range float→int |
| 3 | **DZ** divide by zero | exact `x/0` with `x` finite nonzero |
| 2 | **OF** overflow | rounded result exceeds the max finite value |
| 1 | **UF** underflow | tiny **and** inexact (the definition matters — see below) |
| 0 | **NX** inexact | the rounded result differs from the exact result |

**Underflow has two legal definitions** (before or after rounding) and IEEE
permits either, but it is only signalled when the result is *both* tiny *and*
inexact. A subnormal result that happens to be exact does **not** raise UF. Test
suites check this.

Overflow also forces a specific result depending on rounding mode:

| Mode | Overflowing positive result |
|---|---|
| RNE, RMM | `+∞` |
| RTZ | `+MAX_FINITE` |
| RDN | `+MAX_FINITE` |
| RUP | `+∞` |

---

## 13. Cost, latency, pipelining

Rough numbers for an fp32 unit in a modern process, relative to a 32-bit integer
adder:

| Unit | Area | Typical pipeline depth @ ~1 GHz |
|---|---|---|
| int32 add | 1× | 0–1 |
| int32 multiply | ~15× | 1–3 |
| fp32 add (single path) | ~12× | 3 |
| fp32 add (two path) | ~17× | 2 |
| fp32 multiply | ~20× | 3 |
| fp32 FMA | ~30× | 4–5 |
| fp32 divide (SRT radix-4) | ~10× | 10–15 (iterative, not pipelined) |
| fp32 sqrt | ~12× | 10–20 (iterative) |
| bf16 multiply | ~4× | 1–2 |
| fp32 add, subnormals disabled | ~0.8× of the FTZ-enabled version | −1 stage |

Division and square root are **not** pipelined in practice — they use an
iterative SRT or Newton–Raphson loop with a `valid`/`ready` handshake. If your
algorithm divides in the inner loop, compute a reciprocal once and multiply.

Pipeline cut points for an adder, in order of value:

1. after unpack + exponent compare (before the aligner)
2. after align + add (before the LZC)
3. after normalize (before round)
4. after round (before pack)

---

## 14. Reduced-precision formats for ML

| Format | Where used | Why |
|---|---|---|
| **bf16** | TPU, most training accelerators | fp32 exponent range → drop-in for fp32 training with no loss scaling; conversion is a truncate |
| **fp16** | GPU tensor cores, inference | more mantissa than bf16, but the narrow exponent needs loss scaling during training |
| **TF32** | NVIDIA Ampere+ | fp32 range + fp16 precision; a compromise that keeps fp32 storage |
| **FP8 E4M3** | forward pass / weights | more mantissa; no infinities in the OCP spec, max = 448 |
| **FP8 E5M2** | gradients | more range, which gradients need |
| **MXFP / block float** | newest accelerators | a shared exponent per block of 32 values; storage close to int8 with float-like range |

The engineering point: in a matrix unit, the **multiplier** runs at the narrow
format but the **accumulator** runs at fp32 (or wider). A bf16×bf16→fp32 MAC is
the standard tensor-core primitive because the multiplier is tiny (8×8
mantissa) while the accumulation keeps enough precision that a 1024-deep dot
product does not lose its low bits.

```systemverilog
// bf16 multiply, fp32 accumulate -- the tensor-core primitive
module bf16_mac (
  input  logic        clk, rst_n, en,
  input  logic [15:0] a, b,
  input  logic        acc_clear,
  output logic [31:0] acc
);
  logic [31:0] a32, b32, prod;
  assign a32 = {a, 16'b0};              // bf16 -> fp32 is zero-padding
  assign b32 = {b, 16'b0};
  fp_mul #(.E(8), .M(23)) u_mul (.a(a32), .b(b32), .frm(3'b000), .y(prod), .flags());
  logic [31:0] sum;
  fp_add #(.E(8), .M(23)) u_add (.a(acc), .b(prod), .sub(1'b0), .frm(3'b000),
                                 .y(sum), .flags());
  always_ff @(posedge clk)
    if (!rst_n || acc_clear) acc <= 32'h0000_0000;
    else if (en)             acc <= sum;
endmodule
```

---

## 15. Alternatives to floating point

Before you build an FPU, check whether you need one. In most DSP and control
applications you do not.

| Approach | When it wins |
|---|---|
| **Fixed point** | The dynamic range is known and bounded. 10–30× cheaper. See [docs/18](18-fixed-point-arithmetic.md). |
| **Block floating point** | A vector shares one exponent. FFT butterflies, audio codecs. Most of float's range at near-fixed-point cost. |
| **Logarithmic number system** | Multiply/divide become add/subtract; add becomes a table lookup. Wins when multiplies dominate overwhelmingly. |
| **Posits / type III unum** | Tapered precision — more accuracy near 1.0. Interesting, but tooling and standardization are thin. |
| **Integer with explicit scaling** | The honest version of fixed point, with rescaling in software. |

The decision rule: compute the **dynamic range** your data actually spans
(`max|x| / min|x≠0|`). If it fits in `2^W` for a tolerable `W`, use fixed point
with `W` integer bits and spend the saved area on more parallel lanes.

---

## 16. Verification

Floating-point hardware is where random testing pays for itself, because the
corner cases are numerous, individually rare, and individually catastrophic.

### 1. Directed corner cases — always run these

```
±0, ±smallest subnormal, ±largest subnormal, ±smallest normal, ±1.0,
±largest finite, ±∞, qNaN, sNaN, and every adjacent pair of those.
Plus: a+b where a == -b (exact cancellation), a+b where ea-eb == 1
(the close-path boundary), a*b that rounds up into an exponent increment,
a*b that overflows exactly at the boundary, results that land exactly on
a tie (to check RNE vs RMM).
```

### 2. Golden model via `real`

For fp32, `real` (binary64) has enough headroom to compute the exact result and
round it once — as long as you round yourself rather than relying on the
assignment. For fp64 you need a wider reference; use DPI-C to MPFR.

```systemverilog
// Compare RTL fp32 add against a shortreal reference
shortreal ra, rb, rref;
logic [31:0] a, b, dut_y, ref_y;

ra = $bitstoshortreal(a);
rb = $bitstoshortreal(b);
rref = ra + rb;                        // simulator uses the host FPU
ref_y = $shortrealtobits(rref);

if (dut_y !== ref_y) begin
  // NaN payloads may legitimately differ -- compare classes, not bits
  if (!(is_nan(dut_y) && is_nan(ref_y)))
    $error("a=%h b=%h dut=%h ref=%h", a, b, dut_y, ref_y);
end
```

Two caveats: the simulator's `shortreal` arithmetic may be performed in
extended precision on x87 (double rounding), and it always uses RNE, so this
reference can only check your RNE path.

### 3. DPI-C to the host FPU with explicit rounding control

```systemverilog
import "DPI-C" function int unsigned c_fadd(input int unsigned a,
                                            input int unsigned b,
                                            input int          rm);
```

```c
#include <fenv.h>
#include <string.h>
unsigned c_fadd(unsigned a, unsigned b, int rm) {
  float fa, fb, fy;
  memcpy(&fa, &a, 4);  memcpy(&fb, &b, 4);
  int modes[5] = {FE_TONEAREST, FE_TOWARDZERO, FE_DOWNWARD, FE_UPWARD, FE_TONEAREST};
  fesetround(modes[rm]);
  feclearexcept(FE_ALL_EXCEPT);
  fy = fa + fb;
  unsigned y;  memcpy(&y, &fy, 4);
  return y;
}
```

This checks four of the five modes directly. RMM has no C equivalent — check it
against a hand-written reference.

### 4. Berkeley TestFloat

[TestFloat](http://www.jhauser.us/arithmetic/TestFloat.html) generates the
standard corner-case vector set for every IEEE operation, format, and rounding
mode, including the exception flags. It is the de-facto conformance suite; if
you are claiming IEEE 754 compliance, run it. Dump its vectors to a file and
feed them through a `$readmemh`-driven testbench.

### 5. Constrained-random with a corner-biased distribution

```systemverilog
class fp32_stim;
  rand logic [31:0] v;
  rand bit          use_special;
  constraint c_mix { use_special dist {1 := 40, 0 := 60}; }
  constraint c_val {
    use_special -> v inside {32'h0000_0000, 32'h8000_0000,
                             32'h0000_0001, 32'h007F_FFFF,
                             32'h0080_0000, 32'h7F7F_FFFF,
                             32'h7F80_0000, 32'hFF80_0000,
                             32'h7FC0_0000, 32'h7F80_0001,
                             32'h3F80_0000, 32'hBF80_0000};
    // Bias the "random" ones toward similar exponents so the close path and
    // the cancellation cases actually get hit.
    !use_special -> v[30:23] inside {[8'd100 : 8'd155]};
  }
endclass
```

Uniform random 32-bit patterns almost never produce two operands with close
exponents, so they almost never exercise the close path or massive
cancellation — the exact places bugs live. Constrain the exponent difference
explicitly.

### 6. Formal

FP units are a good formal target for the *structural* properties even when the
full function is out of reach:

```systemverilog
// Result is never a signalling NaN
assert property (@(posedge clk) !(is_snan(y)));
// NaN in -> NaN out
assert property (@(posedge clk) (is_nan(a) || is_nan(b)) |-> is_qnan(y));
// Adding zero of the right sign is the identity
assert property (@(posedge clk) (b == 32'h0000_0000 && !is_nan(a) && frm != RDN)
                                |-> (y == a));
// Commutativity
assert property (@(posedge clk) fp_add(a,b) == fp_add(b,a));
```
