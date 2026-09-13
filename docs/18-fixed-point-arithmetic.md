# Fixed-Point Arithmetic

Fixed point is "integers with an agreed-upon binary point". The hardware is an
ordinary integer datapath; the binary point exists only in your head, your
comments, and your parameter names. That is both its strength (free) and its
weakness (nothing checks it for you).

Companion code:
[`examples/arith/fixed_pkg.sv`](../examples/arith/fixed_pkg.sv) ·
[`examples/rtl/fir_systolic.sv`](../examples/rtl/fir_systolic.sv) ·
[`examples/rtl/cordic_sincos.sv`](../examples/rtl/cordic_sincos.sv)

---

## 1. Notation

The two common notations for a signed fixed-point format:

| Notation | Meaning |
|---|---|
| **Q*m*.*n*** | `m` integer bits **plus** 1 sign bit, `n` fraction bits. Total = `m + n + 1`. |
| **Q*n*** (ARM/TI style) | `n` fraction bits in a word of known width. Q15 in 16 bits = Q0.15. |
| **`s`*W*`.`*F*** | total width `W`, `F` fraction bits, signed. What this repo uses. |

For a signed `W`-bit value with `F` fraction bits:

```
resolution (1 LSB) = 2^-F
range              = [ -2^(W-1-F) , 2^(W-1-F) - 2^-F ]
value              = raw_integer * 2^-F
```

| Format | Width | Frac | Resolution | Range |
|---|---|---|---|---|
| s16.15 (Q15) | 16 | 15 | 3.05e−5 | [−1, +0.99997] |
| s16.8 | 16 | 8 | 3.91e−3 | [−128, +127.996] |
| s32.31 (Q31) | 32 | 31 | 4.66e−10 | [−1, +1) |
| s18.17 | 18 | 17 | 7.63e−6 | [−1, +1) |
| u8.8 (unsigned) | 8 | 8 | 3.91e−3 | [0, 0.996] |

Q15 and Q31 — everything in `[−1, 1)` — dominate DSP because the product of two
in-range values is always in range, so a multiply can never overflow.

### Naming convention that keeps you sane

```systemverilog
// Encode the format in the type name and in a localparam pair.
localparam int COEF_W = 18, COEF_F = 17;    // s18.17, range [-1, 1)
localparam int DATA_W = 16, DATA_F = 15;    // s16.15
typedef logic signed [COEF_W-1:0] coef_t;
typedef logic signed [DATA_W-1:0] data_t;
```

---

## 2. The four operations

Let `a` be s`Wa`.`Fa` and `b` be s`Wb`.`Fb`.

### Addition and subtraction — align the points first

```
requires Fa == Fb.  Result is s(max(Wa,Wb)+1).Fa
```

```systemverilog
// a is s16.8, b is s16.12 -> align b down, or a up. Align UP (no precision loss).
logic signed [15:0] a;   // s16.8
logic signed [15:0] b;   // s16.12
logic signed [20:0] sum; // s21.12
assign sum = (21'(a) <<< 4) + 21'(b);
```

`21'(a)` sign-extends because `a` is declared `signed`. `<<< 4` rescales s16.8
to s20.12. The `+1` bit on the result width holds the carry.

### Multiplication — the points add

```
s(Wa).Fa * s(Wb).Fb  ->  s(Wa+Wb).(Fa+Fb)
```

```systemverilog
logic signed [15:0] x;      // s16.15
logic signed [17:0] c;      // s18.17
logic signed [33:0] p;      // s34.32  -- full precision, no rounding yet
assign p = x * c;           // both signed -> signed multiply, context 34 bits

// Bring it back to s16.15: drop (32-15) = 17 fraction bits
logic signed [15:0] y;
assign y = 16'(round_rne(p, 17));
```

**The redundant sign bit.** Multiplying two Q15 values gives a Q30 result in 32
bits — but bit 31 and bit 30 are always the same except for the single case
`(-1) * (-1) = +1`. DSP convention is to shift the product left by one to
produce Q31 and accept that `(-1)*(-1)` saturates to `+0.9999...`:

```systemverilog
assign q31_prod = (q15_a * q15_b) <<< 1;   // the classic "fractional multiply"
```

### Division — the points subtract

```
s(Wa).Fa / s(Wb).Fb  ->  s(?).(Fa-Fb)
```

To get `Fq` fraction bits in the quotient, pre-shift the numerator left by
`Fq - Fa + Fb` before dividing:

```systemverilog
// a: s32.16, b: s32.16, want q: s32.16
logic signed [47:0] num = 48'(a) <<< 16;    // s48.32
logic signed [31:0] q;
assign q = 32'(num / 48'(b));               // (s48.32)/(s32.16) -> s.16
```

Division is expensive; see [`examples/arith/div_restoring.sv`](../examples/arith/div_restoring.sv)
for a multi-cycle implementation, or use a reciprocal-and-multiply approach.

### Shift = scaling by a power of two — free

```systemverilog
// Rescale s16.8 -> s16.12 (gain 16x in the raw integer, same real value)
assign b_s16_12 = a_s16_8 <<< 4;        // may overflow; widen first
// Rescale s16.12 -> s16.8 (lose 4 fraction bits)
assign a_s16_8 = b_s16_12 >>> 4;        // truncates; consider rounding
```

Remember from [docs/17](17-signed-unsigned-arithmetic.md#shifts): `>>>` only
sign-extends if the left operand is **declared signed**.

---

## 3. Growth and how to bound it

Every operation grows the word. Left unchecked, a 10-tap FIR with 16-bit inputs
produces a 36-bit result. You must decide *where* to truncate, and the answer
is: **as late as possible.**

| Operation | Bit growth |
|---|---|
| `a + b` | +1 bit |
| sum of `N` values | `+ceil(log2(N))` bits |
| `a * b` | `Wa + Wb` bits total |
| MAC over `N` taps, `Wa × Wb` inputs | `Wa + Wb + ceil(log2(N))` |
| multiply by a constant `< 1` | no growth in the integer part |
| accumulate `N` times | `+ceil(log2(N))` guard bits |

### Guard bits on an accumulator

```systemverilog
localparam int DW    = 16;                    // input sample width
localparam int CW    = 18;                    // coefficient width
localparam int NTAP  = 64;
localparam int PW    = DW + CW;               // 34: full product
localparam int GUARD = $clog2(NTAP);          // 6
localparam int ACCW  = PW + GUARD;            // 40: cannot overflow, ever

logic signed [ACCW-1:0] acc;
always_ff @(posedge clk)
  acc <= acc + ACCW'(prod);       // sign-extends: prod is signed
```

With `GUARD = ceil(log2(NTAP))` guard bits the accumulator is provably
overflow-free for any input, which means you never need saturation logic in the
inner loop — you saturate once on the way out. That is both smaller and faster
than saturating each step.

If the coefficients are known, you can do better: the true bound is
`sum(|coef_i|) * max|x|`, so

```systemverilog
localparam int GUARD = $clog2(int'($ceil(sum_abs_coef)));   // often 2-3, not 6
```

---

## 4. Rounding

Truncation (`>>>`) is free but has a **−0.5 LSB DC bias**, which accumulates
through a filter chain and shows up as a DC offset in the output spectrum.

| Mode | Expression (drop `F` LSBs of signed `x`) | Cost | Bias |
|---|---|---|---|
| Truncate / floor | `x >>> F` | 0 | −0.5 LSB |
| Round half up | `(x + (1 <<< (F-1))) >>> F` | 1 adder | +0 mean, but ties always go up |
| Round half to even | `(x >>> F) + (x[F-1] & (\|x[F-2:0] \| x[F]))` | 1 adder + OR tree | unbiased |
| Round toward zero | add `2^F - 1` first if negative | 1 adder + mux | biased toward 0 |
| Magnitude truncation | `x >>> F`, then `+1` if negative and inexact | | biased toward 0 |

```systemverilog
// Round-half-to-even, the unbiased choice. Requires F >= 2.
function automatic logic signed [W-F-1:0] rnd_even
    #(int W, int F) (input logic signed [W-1:0] x);
  logic r = x[F-1];                // "half" bit
  logic s = |x[F-2:0];             // sticky: anything below half
  logic l = x[F];                  // LSB of the kept result
  return (W-F)'((x >>> F) + ((r & (s | l)) ? 1 : 0));
endfunction
```

For audio and control loops, an alternative to rounding is **error feedback
(noise shaping)**: add the previous truncation error back in, which pushes the
quantization noise out of the passband. One register and one adder.

```systemverilog
always_ff @(posedge clk) begin
  {y, err} <= x + ACCW'(err);       // err carries the dropped LSBs forward
end
```

---

## 5. Saturation

Wrapping on overflow turns a large positive into a large negative — a
catastrophic discontinuity in a control loop or an audio path. Saturate at
every point where you *narrow* a value.

```systemverilog
// Saturate a WIDE signed value down to NARROW bits.
function automatic logic signed [NARROW-1:0] sat
    #(int WIDE, int NARROW) (input logic signed [WIDE-1:0] x);
  // Overflow iff the discarded bits are not all copies of the kept sign bit.
  logic ovf = !(&x[WIDE-1 : NARROW-1] || ~|x[WIDE-1 : NARROW-1]);
  if (!ovf)      return x[NARROW-1:0];
  else if (x[WIDE-1]) return {1'b1, {(NARROW-1){1'b0}}};   // most negative
  else                return {1'b0, {(NARROW-1){1'b1}}};   // most positive
endfunction
```

The overflow test `!(&top || ~|top)` where `top = x[WIDE-1 : NARROW-1]` (note
the overlap — it includes the kept sign bit) is the canonical one: the value
fits iff every discarded bit equals the sign bit you are keeping.

Always bring a `saturated` flag out to a status register. A saturating DSP chain
that silently clips is very hard to debug from the output alone.

---

## 6. Choosing a format

1. **Find the dynamic range.** Simulate the algorithm in floating point on real
   input data and record `max|x|` at *every* internal node, not just the output.
2. **Integer bits** = `ceil(log2(max|x|)) + 1` (the +1 is the sign bit).
3. **Fraction bits** = whatever the SNR target requires. Each bit buys ~6.02 dB.
   `SNR_dB ≈ 6.02*F + 1.76` for a full-scale sine with uniform quantization
   noise.
4. **Simulate the quantized version** against the float version on the same
   data and measure the actual error. Do not trust the analysis alone —
   correlated quantization noise in feedback loops behaves badly (limit cycles).
5. **Add headroom** where the input is not fully characterized, and saturate.

Worked: a 48 kHz audio path needing 96 dB SNR with signals in `[−1, 1)` →
`F = (96 − 1.76)/6.02 ≈ 16` fraction bits, plus a couple for the internal
accumulator → s24.23 storage, s48.46 accumulator.

---

## 7. A complete parameterized package

See [`examples/arith/fixed_pkg.sv`](../examples/arith/fixed_pkg.sv) for the
full source. The API:

```systemverilog
import fixed_pkg::*;

// All functions are automatic, pure, and synthesizable.
fx_rescale #(.WI(16), .FI(8), .WO(24), .FO(16))  (x)   // change the format
fx_mul_rnd #(...)                                (a,b) // multiply then round
fx_sat     #(.WIDE(40), .NARROW(16))             (acc) // saturating narrow
fx_rnd_even#(.W(34), .F(17))                     (p)   // convergent rounding
fx_from_real(0.7071, 16, 15)                            // elaboration-time const
```

The `fx_from_real` function is worth calling out — it converts a `real` literal
to a fixed-point constant **at elaboration time**, so the `real` arithmetic
never reaches synthesis:

```systemverilog
function automatic logic signed [31:0] fx_from_real
    (input real v, input int w, input int f);
  real scaled = v * (2.0 ** f);
  return 32'(int'(scaled > 0.0 ? scaled + 0.5 : scaled - 0.5));   // round
endfunction

localparam logic signed [17:0] COS45 = 18'(fx_from_real(0.70710678, 18, 17));
```

This is the right way to get coefficient tables into RTL: write them as readable
decimals, let the elaborator quantize them, and keep the real values in a
comment for the next person.

---

## 8. Fixed point vs floating point

| | Fixed | Floating |
|---|---|---|
| Add cost | 1× | ~12× |
| Multiply cost | 1× | ~1.3× (the mantissa multiply dominates) |
| Dynamic range | `2^W` | `2^(2^E)` |
| Precision | uniform absolute | uniform **relative** |
| Latency | 1 cycle | 3–5 cycles |
| Analysis | you must do it | mostly automatic |
| Corner cases | overflow only | NaN, inf, subnormal, signed zero, 5 rounding modes |

Note the multiply row: a floating-point multiplier is only modestly more
expensive than an integer one of the same mantissa width, because the mantissa
multiply is the bulk of both. It is **addition** where floating point costs 10×.
So a design dominated by multiplies with few accumulations (e.g. a pure
elementwise scale) may reasonably use float, while an FIR filter — which is
almost all accumulation — should be fixed point.

Middle ground: **block floating point**, where a whole vector shares one
exponent. You get most of float's range at fixed point's per-element cost, and
you renormalize once per block. This is what FFT implementations do between
stages.
