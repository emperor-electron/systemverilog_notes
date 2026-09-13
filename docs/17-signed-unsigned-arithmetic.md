# Signed and Unsigned Arithmetic in SystemVerilog

This is the single richest source of silent bugs in the language. The rules are
fully specified (IEEE 1800-2023 §11.6–11.8) and completely mechanical — but they
are *not* the rules of C, and the failure mode is a wrong number rather than a
compile error.

Companion code: [`examples/arith/signedness_demo.sv`](../examples/arith/signedness_demo.sv)
and [`examples/arith/width_rules_tb.sv`](../examples/arith/width_rules_tb.sv).

---

## Contents

- [1. Representation](#1-representation)
- [2. What is signed, what is unsigned](#2-what-is-signed-what-is-unsigned)
- [3. The width algorithm](#3-the-width-algorithm)
- [4. The signedness algorithm](#4-the-signedness-algorithm)
- [5. Extension: sign vs zero](#5-extension-sign-vs-zero)
- [6. Operator-by-operator](#6-operator-by-operator)
- [7. Worked examples](#7-worked-examples)
- [8. The trap catalogue](#8-the-trap-catalogue)
- [9. Overflow detection](#9-overflow-detection)
- [10. Saturation and rounding](#10-saturation-and-rounding)
- [11. What the synthesizer builds](#11-what-the-synthesizer-builds)
- [12. Rules of thumb](#12-rules-of-thumb)

---

## 1. Representation

SystemVerilog signed integers are **two's complement**. For a `W`-bit signed
value the representable range is `-2^(W-1) .. 2^(W-1)-1`, and the encoding is:

```
value = -b[W-1]*2^(W-1) + sum(b[i]*2^i for i in 0..W-2)
```

Consequences that matter in hardware:

- There is **one** zero. Nice.
- The range is **asymmetric**: `-2^(W-1)` has no positive counterpart. So
  `-(-128)` in 8 bits is `-128`, and `abs()` of the most-negative value
  overflows. Every saturating `abs`/negate unit needs a special case.
- Addition and subtraction hardware is **identical** for signed and unsigned.
  The same ripple-carry adder computes both; only the *interpretation* of the
  result, and the *overflow condition*, differ.
- Multiplication hardware **is** different: a signed multiplier must sign-extend
  partial products (or use Baugh–Wooley / Booth encoding). This is why
  `$signed()` on the operands of a `*` actually changes the gates.
- Sign extension is free in hardware (a fanout of the MSB), so widening a signed
  value costs nothing.

```systemverilog
// 4-bit patterns, two interpretations
// bits   unsigned   signed
// 0000      0          0
// 0111      7          7
// 1000      8         -8      <- the asymmetric end
// 1111     15         -1
```

---

## 2. What is signed, what is unsigned

### Types

| Declaration | Signed? |
|---|---|
| `bit`, `bit [N-1:0]` | **unsigned** |
| `logic`, `reg`, `wire`, and all vectors of them | **unsigned** |
| packed `struct` / `union` / packed array | **unsigned** |
| `byte`, `shortint`, `int`, `longint` | **signed** |
| `integer` | **signed** |
| `time` | unsigned |
| `enum` | follows its base type (`enum logic[3:0]` → unsigned; bare `enum` → `int`, signed) |
| `real`, `shortreal` | signed (floating point) |

Override with the keyword: `logic signed [15:0] s;`, `int unsigned u;`.

> The default that bites everyone: **`logic [31:0]` is unsigned, `int` is
> signed.** They are otherwise interchangeable-looking 32-bit things.

### Literals

| Literal | Width | Signed? |
|---|---|---|
| `42` | ≥32, implementation may be wider | **signed** |
| `32'd42` | 32 | unsigned |
| `32'sd42` | 32 | **signed** |
| `8'hFF` | 8 | unsigned (= 255) |
| `8'shFF` | 8 | **signed** (= −1) |
| `'0`, `'1`, `'x`, `'z` | context width | unsigned |
| `'hFF` (unbased, unsized) | 32 | unsigned |
| `-42` | ≥32 | signed (unary minus on a signed literal) |
| `-8'd42` | 8 | **unsigned!** `-(8'd42)` = `8'd214` |

That last row is the classic: `-8'd42` is *not* "negative 42 as a signed 8-bit
value". It is unary minus applied to an unsigned 8-bit 42, which produces the
unsigned 8-bit value 214. The bit pattern happens to be the two's complement of
42, so it often "works" — right up until you use it in a comparison or a
multiply, where the unsigned-ness propagates. Write `-8'sd42` or `8'sd(-42)`.

### Expressions

Some expressions are unsigned no matter what you feed them:

| Expression | Signedness |
|---|---|
| `{a, b}` — any concatenation | **unsigned, always** |
| `{N{a}}` — any replication | **unsigned, always** |
| `v[i]` — bit select | **unsigned** |
| `v[msb:lsb]`, `v[i +: N]` — part select | **unsigned** |
| comparison (`< <= > >= == != === !==`) | unsigned, 1 bit |
| logical (`&& || !`) | unsigned, 1 bit |
| reduction (`& | ^ ~& ~| ~^`) | unsigned, 1 bit |
| `a inside {...}` | unsigned, 1 bit |
| `$signed(x)`, `signed'(x)` | signed |
| `$unsigned(x)`, `unsigned'(x)` | unsigned |
| casting to a signed type: `int'(x)` | signed |

**Selecting any part of a signed vector discards its signedness** — even
`v[W-1:0]`, which selects the whole thing:

```systemverilog
logic signed [7:0] a = -1;   // 8'hFF
logic signed [15:0] x, y;
x = a;          // 16'hFFFF  -- assignment sign-extends
y = a[7:0];     // 16'h00FF  -- part-select is unsigned, zero-extends
```

---

## 3. The width algorithm

Every expression has a width computed in two passes. This is §11.6.1 and it is
worth internalizing, because it is *the* mechanism behind lost carry bits.

### Pass 1 — bottom-up, self-determined widths

Walk the expression tree upward and give each node its intrinsic width:

| Node | Self-determined width |
|---|---|
| Variable / net | its declared width |
| Sized literal | its size |
| Unsized decimal literal | 32 (at least) |
| `a + b`, `a - b`, `a * b`, `a / b`, `a % b` | `max(W(a), W(b))` |
| `a & b`, `a \| b`, `a ^ b`, `a ~^ b` | `max(W(a), W(b))` |
| `~a`, `+a`, `-a` | `W(a)` |
| `a << b`, `a >> b`, `a <<< b`, `a >>> b` | `W(a)` |
| `a ** b` | `W(a)` |
| `c ? a : b` | `max(W(a), W(b))` |
| `{a, b, ...}` | `W(a) + W(b) + ...` |
| `{N{a}}` | `N * W(a)` |
| `a == b`, `a < b`, `a && b`, `!a`, `&a`, `a inside {}` | **1** |
| function call | return type width |
| `$signed(a)`, `$unsigned(a)`, `size'(a)` | `W(a)` / the cast size |

### Pass 2 — top-down, context-determined widths

The **context** is the assignment target (or the port, or the enclosing
operator). The final width is:

```
W_final = max( W_self(expression), W(LHS) )
```

That width is pushed *back down* the tree to every **context-determined**
operand, and each is extended to `W_final` **before** the operator evaluates.

An operand is context-determined unless the table below says otherwise.

### Self-determined operands (the exceptions)

These operands are **never** widened by context — they compute at their own
width and the result enters the parent as a fixed-size thing:

1. Both operands of a **comparison** and of a **logical** operator (`&& || !`).
   (They size against *each other*, but not against the LHS.)
2. The operand of a **reduction** operator.
3. The **right-hand operand of a shift** (`a << b`: `b` is self-determined).
4. The **right-hand operand of a power** (`a ** b`).
5. **All operands of a concatenation or replication.**
6. The **condition** of a ternary (`c ? a : b` — `c` is self-determined; `a`
   and `b` are context-determined).
7. The replication count `N` in `{N{a}}` (must be constant).

Points 3 and 5 are the two that cause real bugs.

### Worked width example

```systemverilog
logic [7:0]  a, b;
logic [15:0] result;

result = a * b;
```

- Pass 1: `W(a)=8`, `W(b)=8`, `W(a*b) = max(8,8) = 8`.
- Pass 2: the context is 16 bits, so `W_final = max(8, 16) = 16`. Both `a` and
  `b` are context-determined, so **both are zero-extended to 16 bits first**,
  then a 16x16 multiply runs and the full product lands in `result`.

So this one is fine — the top-down pass rescues it. The same rescue applies
through any chain of context-determined operands:

```systemverilog
result = (a * b) >> 1;      // fine: >> passes the 16-bit context down to a*b
result = 16'(a) * b;        // fine: explicit
result = a * b + 1;         // fine
assign result = a * b;      // fine
foo u (.p16(a * b));        // fine: the port width is the context
```

Breakage happens wherever the wide context is **absent** or is **cut off**:

```systemverilog
// (1) No context at all: system task arguments are self-determined.
$display("%0d", a * b);     // evaluates at 8 bits, wraps at 256
$display("%0d", 16'(a) * b);            // fix
$display("%0d", int'(a) * int'(b));     // fix

// (2) A narrow named intermediate cuts the chain.
logic [7:0] tmp;
tmp    = a * b;             // truncated HERE
result = tmp;               // too late

// (3) A self-determined position cuts the chain.
result = {a * b};           // concatenation operands are self-determined:
                            //   a*b evaluates at 8 bits, then the 8-bit
                            //   concatenation is zero-extended to 16
result = (a * b) == 16'd300;  // comparison operands are self-determined
                              //   against each other: here a*b DOES widen to
                              //   16 to match the literal -- but it would not
                              //   widen to match an 8-bit LHS

// (4) A shift count is self-determined, so a wide context never reaches it.
result = 1 << n;            // `1` is 32-bit signed -> fine
logic [7:0] one8 = 8'd1;
result = one8 << 9;         // 0: the shift happens at 8 bits, not 16
result = 16'(one8) << 9;    // 512
```

**Practical rule:** the top-down pass only helps along an unbroken chain of
context-determined operands from the assignment target down to the operation.
Anywhere a value passes through a narrow named object, a self-determined
position, or a context-free position (`$display`, a task argument), you must
widen explicitly.

---

## 4. The signedness algorithm

§11.6.2. Simpler than width, and it interacts with it.

> **An operation is signed if and only if *every* context-determined operand is
> signed. A single unsigned operand makes the whole operation unsigned.**

Self-determined operands keep their own signedness and do not vote.

Also:

- The **assignment does not vote.** `logic signed [15:0] x = a + b;` does not
  make `a + b` signed. The RHS is evaluated with its own signedness and the
  result is then reinterpreted into `x`.
- Signedness propagates *down* into context-determined operands together with
  width. If the expression is unsigned, a signed operand is **zero-extended**,
  not sign-extended.

That last point is the heart of it. Mixing one unsigned operand into a signed
expression does not just change the comparison — it changes how the *other*
operands are widened.

```systemverilog
logic signed [3:0] a = -1;    // 4'b1111
logic        [3:0] b =  1;    // 4'b0001
logic signed [7:0] r;

r = a + b;
// The expression is unsigned (b is unsigned).
// Context width = max(4, 4, 8) = 8.
// a is widened as UNSIGNED -> 8'b0000_1111 = 15
// b is widened as UNSIGNED -> 8'b0000_0001 = 1
// sum = 8'b0001_0000 = 16
// r (signed) = 16.     NOT 0.
```

---

## 5. Extension: sign vs zero

Extension happens in exactly two places: (a) widening a context-determined
operand, and (b) an assignment to a wider target.

| Situation | Rule |
|---|---|
| Widening operand in a **signed** expression, operand is **signed** | sign-extend |
| Widening operand in a **signed** expression, operand is unsigned | — impossible; one unsigned operand makes the expression unsigned |
| Widening operand in an **unsigned** expression | zero-extend, *even a signed operand* |
| Assignment, **RHS signed**, LHS wider | sign-extend |
| Assignment, **RHS unsigned**, LHS wider | zero-extend (regardless of LHS signedness) |
| Assignment, LHS narrower | truncate (keep the low bits), no warning by default |

Manual extension idioms:

```systemverilog
localparam int WI = 8, WO = 16;
logic [WI-1:0]        u;
logic signed [WI-1:0] s;
logic [WO-1:0]        zext, sext;

zext = {{(WO-WI){1'b0}},    u};        // explicit zero extension
sext = {{(WO-WI){s[WI-1]}}, s};        // explicit sign extension
sext = WO'(signed'(s));                // same thing, cast form
sext = $signed(s);                     // relies on assignment sign-extension
```

---

## 6. Operator-by-operator

### Addition, subtraction

Same gates for both signednesses. Result width `max(Wa, Wb)` pre-context — so
the carry-out is lost unless the destination is wider **and** the operands get
widened by the top-down pass.

```systemverilog
logic [7:0] a, b;
logic [8:0] sum;
sum = a + b;                    // correct: context 9 bits, both widen, carry kept
sum = {1'b0,a} + {1'b0,b};      // also correct, explicit; works in any context
```

### Multiplication

Result width `max(Wa, Wb)` pre-context, which is almost never what you want.
A `W1 × W2` product needs `W1 + W2` bits (unsigned) or `W1 + W2` bits (signed,
where the extreme case `-2^(W-1) * -2^(W-1)` needs the full width).

```systemverilog
logic [7:0] a, b;  logic [15:0] p;
p = a * b;                      // OK: 16-bit context widens both operands

logic signed [7:0] sa, sb;  logic signed [15:0] sp;
sp = sa * sb;                   // OK: signed*signed = signed, widened to 16

logic signed [7:0] sc;  logic [7:0] uc;  logic signed [15:0] mixed;
mixed = sc * uc;                // WRONG: unsigned multiply, sc zero-extended
mixed = sc * signed'({1'b0, uc});  // right: make uc a 9-bit signed positive
```

Mixed signed×unsigned genuinely needs one extra bit on the unsigned operand to
express it as a signed multiply. That is also what DSP blocks do internally.

### Division and modulus

- Both operands signed → signed division, **truncates toward zero**
  (`-7/2 == -3`, not `-4`).
- `%` takes the sign of the **first** operand: `-7 % 2 == -1`, `7 % -2 == 1`.
- Division by zero yields `X` in 4-state, and is a runtime error in some tools.
- Only division/modulo by a **power-of-two constant** synthesizes cheaply (into
  a shift/mask). Everything else infers a divider — long latency, large area.
  Use a dedicated multi-cycle divider; see
  [`examples/arith/divider_restoring.sv`](../examples/arith/divider_restoring.sv).

Signed division by a power of two is **not** an arithmetic right shift:

```systemverilog
logic signed [7:0] x = -7;
x / 2      // -3   (truncate toward zero)
x >>> 1    // -4   (floor, toward -infinity)
```

To get truncation-toward-zero from a shift, add a bias first:
`(x + (x[7] ? 8'sd1 : 8'sd0)) >>> 1`.

### Shifts

| Op | Fill | Notes |
|---|---|---|
| `<<`, `<<<` | 0 | identical |
| `>>` | 0 | always logical |
| `>>>` | **sign bit if the left operand is signed, else 0** | |

```systemverilog
logic        [7:0] u = 8'hF0;
logic signed [7:0] s = 8'shF0;    // -16
u >>> 2   // 8'h3C  -- unsigned operand, zero fill
s >>> 2   // 8'hFC  -- signed operand, sign fill = -4
$signed(u) >>> 2   // 8'hFC
```

The **right** operand is self-determined and always treated as unsigned for the
shift amount. A negative shift amount is therefore a huge positive one:

```systemverilog
int n = -1;
x << n;      // shifts by 4294967295 -> result is 0. Not "shift right by 1".
```

Shift amounts larger than the width give 0 (or all-sign-bits for `>>>` signed).

### Comparisons

`<  <=  >  >=` are signed **only if both operands are signed**. Otherwise both
are treated as unsigned patterns — and a negative signed value becomes a huge
unsigned one.

```systemverilog
logic signed [7:0] a = -1;
logic        [7:0] b =  1;
if (a < b)  ...       // FALSE. 8'hFF (255) < 1 is false.
if (a < $signed(b)) ...   // TRUE
```

`== != === !==` compare bit patterns after context widening, so signedness
affects them only through the *extension* of narrower operands.

### Unary minus

`-a` has width `W(a)` and the signedness of `a`. On an unsigned operand it is
"two's complement of the bit pattern", which is a well-defined unsigned value:

```systemverilog
logic [3:0] u = 4'd3;
-u            // 4'd13, unsigned. Bit pattern 1101.
logic signed [3:0] s = 4'sd3;
-s            // 4'sd-3. Same bit pattern 1101, different type.
```

Negating the most-negative signed value is a no-op (`-(-8) == -8` in 4 bits).
Saturating negate needs an explicit check.

### Reduction and bitwise

Bitwise operators widen context-determined operands normally (so signedness
affects the fill bits). Reduction operators take a **self-determined** operand
and return 1 unsigned bit.

---

## 7. Worked examples

### 7.1 Average of two unsigned values without overflow

```systemverilog
logic [7:0] a, b, avg;
avg = (a + b) >> 1;          // WRONG: a+b is 8 bits (context is 8), carry lost
avg = ({1'b0,a} + {1'b0,b}) >> 1;   // right
avg = (9'(a) + 9'(b)) >> 1;         // right, cast form
avg = (a & b) + ((a ^ b) >> 1);     // right, no extra bit needed (classic trick)
```

### 7.2 Signed average (rounds toward −∞)

```systemverilog
logic signed [7:0] a, b, avg;
avg = ($signed({a[7],a}) + $signed({b[7],b})) >>> 1;
```

Note `{a[7],a}` is a concatenation → unsigned, so the `$signed()` is doing real
work here, not decoration.

### 7.3 Signed accumulator

```systemverilog
localparam int DW = 16, AW = 24;        // 8 bits of headroom = 256 accumulations
logic signed [DW-1:0] sample;
logic signed [AW-1:0] acc;

always_ff @(posedge clk) begin
  if (!rst_n)      acc <= '0;
  else if (clear)  acc <= AW'(sample);      // cast sign-extends (sample is signed)
  else if (valid)  acc <= acc + AW'(sample);
end
```

`AW'(sample)` sign-extends because `sample` is signed. If `sample` were
`logic [15:0]` you would need `AW'(signed'(sample))`.

### 7.4 Mixed-width signed multiply-accumulate

```systemverilog
localparam int AW_ = 8, BW = 12, PW = AW_ + BW, ACCW = PW + 6;
logic signed [AW_-1:0]  x;
logic signed [BW-1:0]   coeff;
logic signed [PW-1:0]   prod;
logic signed [ACCW-1:0] acc;

always_ff @(posedge clk) begin
  prod <= x * coeff;                 // both signed -> signed mul; context PW
  acc  <= acc + ACCW'(prod);         // sign-extend the product
end
```

### 7.5 The `$display` trap

```systemverilog
logic [7:0] a = 200, b = 100;
$display("%0d", a + b);        // prints 44  (8-bit wrap, no width context)
$display("%0d", 16'(a) + b);   // prints 300
$display("%0d", a + b + 0);    // prints 300 -- the unsized `0` is 32-bit signed,
                               //   which drags the whole expression to 32 bits
```

The `+ 0` trick works but is obscure; prefer an explicit cast.

---

## 8. The trap catalogue

```systemverilog
// ── T1: one unsigned operand poisons the expression ───────────────────────
logic signed [7:0] a = -8;
logic        [7:0] u =  8;
logic signed [8:0] r;
// unsigned expression, context 9 bits: a -> 9'd248, u -> 9'd8, sum = 9'd256
r = a + u;                  // 9'b1_0000_0000, read as signed = -256.  Expected 0.
r = a + signed'({1'b0,u});  // 0. Correct.

// ── T2: part-selects are unsigned ─────────────────────────────────────────
logic signed [15:0] w = -1;
logic signed [31:0] z;
z = w;                      // -1
z = w[15:0];                // 65535
z = signed'(w[15:0]);       // -1

// ── T3: concatenation is unsigned ─────────────────────────────────────────
logic signed [3:0] c = -1;
logic signed [7:0] d;
d = {c};                    // 15  -- braces alone changed the meaning
d = c;                      // -1

// ── T4: -literal is unsigned ──────────────────────────────────────────────
logic signed [7:0] e;
e = -8'd1;                  // bit pattern is right (0xFF), but the EXPRESSION
                            //   is unsigned; in a comparison it is 255
if (-8'd1 < 8'sd0) ...      // FALSE
if (-8'sd1 < 8'sd0) ...     // TRUE

// ── T5: the lost carry / lost product ─────────────────────────────────────
logic [7:0] p, q, t;
logic [15:0] big;
t   = p + q;                // carry lost (8-bit destination -- intended?)
big = p * q;                // fine (16-bit context)
big = (p * q) + 0;          // fine
t   = p * q;  big = t;      // product truncated at `t`

// ── T6: >>> on an unsigned operand ────────────────────────────────────────
logic [7:0] m = 8'hF0;
m >>> 4;                    // 8'h0F. `>>>` did nothing "arithmetic".

// ── T7: signed comparison across a port ───────────────────────────────────
// A module port declared `input logic [7:0] v` is UNSIGNED inside the module
// even if the caller connects a signed net. Signedness does not cross ports.
// Declare the port `input logic signed [7:0] v`.

// ── T8: array reduction methods ───────────────────────────────────────────
byte s[] = '{ 100, 100, 100 };
$display("%0d", s.sum());              // 44  (accumulates in `byte`)
$display("%0d", s.sum() with (int'(item)));  // 300

// ── T9: unary minus on the most-negative value ────────────────────────────
logic signed [7:0] n = -128;
-n;                         // -128

// ── T10: enum arithmetic ──────────────────────────────────────────────────
typedef enum logic [1:0] { A, B, C } e_t;
// e_t base is `logic [1:0]` -> unsigned. Arithmetic on it wraps at 4.
```

---

## 9. Overflow detection

### Unsigned add / subtract

```systemverilog
logic [W-1:0] a, b, sum;
logic         cout, borrow;
assign {cout,  sum} = a + b;          // cout = overflow
assign {borrow, sum} = a - b;         // borrow = 1 means a < b (underflow)
```

Note `{cout, sum} = a + b` works because the LHS concatenation is `W+1` bits
wide, which becomes the context and widens both operands.

### Signed add / subtract

Overflow iff the operands have the same sign and the result's sign differs:

```systemverilog
logic signed [W-1:0] a, b, sum;
logic ovf;
assign sum = a + b;
assign ovf = (a[W-1] == b[W-1]) && (sum[W-1] != a[W-1]);
```

Equivalently, using a one-bit-wider sum, overflow is `s[W] != s[W-1]`:

```systemverilog
logic signed [W:0] wide;
assign wide = W1'(a) + W1'(b);            // W1 = W+1
assign ovf  = (wide[W] != wide[W-1]);
assign sum  = wide[W-1:0];
```

For subtraction: `ovf = (a[W-1] != b[W-1]) && (diff[W-1] != a[W-1])`.

### Multiply

An unsigned `Wa × Wb` product fits in `Wa+Wb` bits, always. A signed product
fits in `Wa+Wb` bits, always — with one bit of slack except for the single case
`-2^(Wa-1) × -2^(Wb-1)`. So the only overflow is when you *narrow* the product,
and then the test is whether the discarded upper bits are all copies of the kept
sign bit:

```systemverilog
// keep the low K bits of a signed product P[PW-1:0]
assign ovf = !( &P[PW-1:K-1] || ~|P[PW-1:K-1] );   // not all 1s and not all 0s
```

---

## 10. Saturation and rounding

### Saturating add (signed)

```systemverilog
module sat_add #(parameter int W = 16) (
  input  logic signed [W-1:0] a, b,
  output logic signed [W-1:0] y,
  output logic                sat
);
  logic signed [W:0] s;
  // Concatenations are unsigned, so wrap them: this is a genuine SIGNED add of
  // two manually sign-extended (W+1)-bit values.
  assign s   = signed'({a[W-1], a}) + signed'({b[W-1], b});
  assign sat = (s[W] != s[W-1]);
  assign y   = sat ? {s[W], {(W-1){~s[W]}}}   // +max or -min
                   : s[W-1:0];
endmodule
```

`{s[W], {(W-1){~s[W]}}}` gives `0111...1` when the true result was positive
(`s[W]==0`) and `1000...0` when it was negative.

### Rounding a fixed-point / shifted result

| Mode | Expression (drop `F` LSBs of signed `x`) | Bias |
|---|---|---|
| Truncate (floor) | `x >>> F` | −0.5 LSB average |
| Round half up | `(x + (1 <<< (F-1))) >>> F` | +0 average, but biased on ties |
| Round half to even | see below | unbiased |
| Round toward zero | `(x + (x[MSB] ? (1<<<F)-1 : 0)) >>> F` | |

Requires `F >= 2` (so that `x[F-2:0]` exists) and `W > F`:

```systemverilog
// Round-half-to-even (convergent), dropping F LSBs
function automatic logic signed [W-F-1:0] round_even
    (input logic signed [W-1:0] x);
  logic guard, round_bit, sticky, inc;
  round_bit = x[F-1];                      // the half bit
  sticky    = |x[F-2:0];                   // anything below it
  guard     = x[F];                        // LSB of the result
  inc       = round_bit & (sticky | guard);
  return (x >>> F) + inc;
endfunction
```

Truncation's −0.5 LSB DC bias is real and accumulates: in a 64-tap FIR that
truncates after every MAC, you get a −32 LSB offset. Round, or accumulate at
full precision and round once at the end (which is what
[`examples/rtl/fir_systolic.sv`](../examples/rtl/fir_systolic.sv) does).

---

## 11. What the synthesizer builds

| Source | Inferred hardware |
|---|---|
| `a + b`, `a - b` | ripple-carry / carry-select adder; identical for both signednesses |
| `{c,s} = a + b + cin` | adder with carry in/out |
| `a * b`, both unsigned | array multiplier, or a DSP block's unsigned mode |
| `a * b`, both signed | signed array multiplier (Baugh–Wooley) or DSP signed mode |
| `a * b`, mixed | the tool zero-extends per the language rules — usually **not** what you meant |
| `a * 2**k` / `a << k` (constant k) | wiring, free |
| `a * C` (constant C) | shift-and-add network; the tool does the CSD encoding |
| `a / 2**k` unsigned | wiring |
| `a / 2**k` signed | shift + a correction adder (truncate-toward-zero) |
| `a / b` variable | full divider — big and slow. Pipeline it yourself. |
| `a % 2**k` | mask |
| `>>> ` by a variable | barrel shifter, `log2(W)` mux stages |
| `acc <= acc + p` in `always_ff` | DSP block accumulator, if widths and pipelining match the block |

To hit a DSP48-style block, match its shape: a signed `18×18` (or `18×27`)
multiply feeding a `48`-bit accumulator, with a register between multiply and
accumulate. `examples/rtl/mac_pipelined.sv` shows the canonical form.

---

## 12. Rules of thumb

1. **Declare signedness explicitly** on every port and signal that participates
   in arithmetic: `logic signed [W-1:0]`. Never rely on the default.
2. **Never mix signed and unsigned in one expression.** Convert at the boundary
   with `signed'({1'b0, u})` — the extra bit keeps the value positive.
3. **Size the destination first**, then let the top-down pass widen the
   operands. `W2'(a) * W2'(b)` when in doubt.
4. **Widen before you shift, mask, or select**, never after.
5. `{...}` is unsigned. If you concatenate in an arithmetic expression, wrap the
   result in `signed'()` when you meant it to be signed.
6. Prefer `signed'(x)` / `unsigned'(x)` casts over `$signed` / `$unsigned` — same
   semantics, but the cast form reads as a type operation and works in
   constant expressions.
7. Give every intermediate a **named `localparam` width** derived from the
   inputs (`localparam int PW = AW + BW;`). Magic numbers in widths are how
   widths drift out of sync.
8. Turn on your tool's width-mismatch lint and treat it as an error. Verilator's
   `-Wall` (`WIDTHEXPAND`/`WIDTHTRUNC`) and most commercial linters catch the
   entire trap catalogue above.
9. In testbenches, check with `===` so an `X` fails loudly rather than
   comparing as "not equal" by accident.
