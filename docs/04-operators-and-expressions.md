# Operators and Expressions

The width and signedness rules are in
[docs/17](17-signed-unsigned-arithmetic.md); this document covers behaviour.

## 1. Precedence

From highest to lowest. Same-row operators associate left to right except
where noted.

```
 1   () [] :: .
 2   + - ! ~ & ~& | ~| ^ ~^ ^~ ++ --      (unary)
 3   **                                    (right assoc)
 4   * / %
 5   + -                                   (binary)
 6   << >> <<< >>>
 7   < <= > >= inside dist
 8   == != === !== ==? !=?
 9   & ~&
10   ^ ~^ ^~
11   | ~|
12   &&
13   ||
14   ?:                                    (right assoc)
15   -> <->
16   = += -= *= /= %= &= |= ^= <<= >>= <<<= >>>= :=  :/  <=
17   {} {{}}
```

Two precedence facts cause most real bugs:

```systemverilog
a & b == c        // parses as  a & (b == c)      -- equality binds TIGHTER
a | b << 2        // parses as  a | (b << 2)      -- fine, but not obvious
!a == b           // parses as  (!a) == b
if (a & mask == 0)   // almost certainly wrong; you meant ((a & mask) == 0)
```

Parenthesize bitwise operations against comparisons, always.

## 2. Arithmetic

| Op | Notes |
|---|---|
| `+` `-` | identical gates for signed/unsigned; only overflow detection differs |
| `*` | signed and unsigned multipliers are **different hardware** |
| `/` | truncates toward zero for signed; `X` on divide-by-zero in 4-state |
| `%` | sign follows the **left** operand: `-7 % 2 == -1` |
| `**` | `2 ** 3 == 8`; real if either operand is real; `0**0 == 1` |

Synthesizability: `+ - *` always; `/ %` only by a constant power of two (becomes
wiring/masking) — anything else infers a full divider. `**` only with a constant
base of 2 or a constant exponent.

```systemverilog
x << 3        // preferred over x * 8
x >> 3        // preferred over x / 8 (unsigned)
x & 8'h07     // preferred over x % 8 (unsigned)
```

## 3. Relational and equality

| Op | Result on `X`/`Z` input | Synthesizable |
|---|---|---|
| `<` `<=` `>` `>=` | `X` | yes |
| `==` `!=` | `X` | yes |
| `===` `!==` | 0 or 1 — compares `X`/`Z` literally | **no** |
| `==?` `!=?` | `X`/`Z` in the **right** operand are wildcards | no (mostly) |

```systemverilog
4'b1x01 ==  4'b1x01     // X
4'b1x01 === 4'b1x01     // 1
4'b1101 ==? 4'b11?1     // 1   (? in the right operand matches anything)
4'b1x01 ==? 4'b1101     // X   (an X on the LEFT still poisons it)
```

Use `==` in RTL (so that `X` propagates and tells you about the bug) and `===`
in testbench checks (so that an `X` result fails the comparison loudly instead
of returning `X`, which then gets treated as false by `if`).

```systemverilog
// In a scoreboard: this catches X, the == version does not
if (actual !== expected) $error(...);
```

## 4. Logical, bitwise, reduction

```systemverilog
// Logical: operands are reduced to 1/0/X first; result is 1 bit
a && b      a || b      !a

// Bitwise: element-wise across the (widened) operands
a & b       a | b       a ^ b       a ~^ b   (xnor)      ~a

// Reduction: one operand, result is 1 bit
&v          // AND of all bits: 1 iff all bits are 1
|v          // OR:  1 iff any bit is 1  -- the idiomatic "is nonzero"
^v          // XOR: parity
~&v  ~|v  ~^v
```

Idioms:

```systemverilog
if (|vec)        // vec != 0          -- one gate, no comparator
if (&vec)        // vec == all ones
if (~|vec)       // vec == 0
assign parity = ^data;
assign any_err = |err_vector;
```

`&&` short-circuits; `&` does not. That matters when the right operand has a
side effect or an out-of-range index:

```systemverilog
if (idx < N && arr[idx])   // safe
if (idx < N &  arr[idx])   // arr[idx] is always evaluated
```

## 5. Shifts

```systemverilog
a << n        // logical left, zero fill
a >> n        // logical right, ZERO fill always
a <<< n       // arithmetic left = logical left
a >>> n       // arithmetic right: sign fill IFF `a` is signed
```

```systemverilog
logic        [7:0] u = 8'hF0;
logic signed [7:0] s = 8'shF0;
u >>> 2    // 8'h3C   (zero fill -- `u` is unsigned)
s >>> 2    // 8'hFC   (sign fill)
$signed(u) >>> 2       // 8'hFC
```

The shift **amount** is self-determined and treated as unsigned. A negative
shift amount is therefore an enormous positive one and the result is 0:

```systemverilog
int n = -1;
x << n;      // shift by 4294967295 -> 0.  NOT a right shift.
```

Shifting by more than the width gives 0 (or all sign bits for signed `>>>`).

Synthesis: a shift by a **constant** is free (wiring). A shift by a **variable**
is a barrel shifter — `log2(W)` stages of 2:1 muxes, `W * log2(W)` muxes total.

## 6. Conditional

```systemverilog
cond ? a : b
```

The condition is self-determined and reduced to 1/0/X. If it is `X` or `Z`, the
result is the **bitwise merge** of `a` and `b`: each bit is the common value
where they agree, and `X` where they differ.

```systemverilog
logic c = 1'bx;
c ? 4'b1100 : 4'b1010    // 4'b1xx0
```

That is genuinely useful: it means an `X` on a mux select produces `X` only on
the bits that actually differ, which keeps `X` propagation from being overly
pessimistic — and it means a mux with identical inputs is immune to an `X`
select.

Chained ternaries synthesize to a **priority** mux:

```systemverilog
assign y = sel0 ? a : sel1 ? b : sel2 ? c : d;   // priority chain
// vs. a parallel mux:
always_comb
  unique case (1'b1)
    sel0: y = a;
    sel1: y = b;
    sel2: y = c;
    default: y = d;
  endcase
```

## 7. `inside`

```systemverilog
a inside {1, 3, 5}
a inside {[10:20]}
a inside {[10:20], 25, other_array}          // an array member expands
!(a inside {...})
```

`inside` uses **wildcard equality** (`==?`), so `X`/`Z` in the set are
don't-cares:

```systemverilog
op inside {4'b10??}      // matches 1000, 1001, 1010, 1011
```

It is synthesizable and is the cleanest way to write a range check or an
opcode-group decode:

```systemverilog
assign is_branch = opcode inside {OP_BEQ, OP_BNE, OP_BLT, OP_BGE};
assign in_range  = addr inside {[BASE : BASE + SIZE - 1]};
```

## 8. Increment, decrement, assignment operators

```systemverilog
i++   ++i   i--   --i
x += 1;  x -= 1;  x *= 2;  x /= 2;  x %= n;
x &= m;  x |= m;  x ^= m;  x <<= 1;  x >>= 1;  x <<<= 1;  x >>>= 1;
```

These are statements *and* expressions, but the language does **not** define
an evaluation order for multiple side effects in one expression. `a[i++] = i;`
is unspecified. Keep increments as standalone statements.

In `always_ff`, `i++` is a **blocking** assignment. Do not use it on a signal
you intend to be a flop:

```systemverilog
always_ff @(posedge clk) cnt++;         // blocking -- works, but inconsistent
always_ff @(posedge clk) cnt <= cnt+1;  // do this
```

## 9. Streaming operators

```systemverilog
{>> N {expr}}     // pack: left to right, in N-bit blocks
{<< N {expr}}     // pack: right to left (reverse the block order)
```

`N` defaults to 1 (individual bits).

```systemverilog
logic [31:0] w = 32'hAABB_CCDD;
{<<{w}}         // 32'hBB33_DD55 -- every bit reversed
{<<8{w}}        // 32'hDDCC_BBAA -- byte swap (endian conversion)
{<<4{w}}        // nibble swap
```

As an **unpack** target on the left of an assignment:

```systemverilog
logic [7:0] a, b, c, d;
{>>{a, b, c, d}} = w;      // distribute w across a,b,c,d
```

Both directions are synthesizable — they are pure wiring.

## 10. `$` in expressions

```systemverilog
q[$]           // last element of a queue
a ##[1:$] b    // unbounded range in SVA
x inside {[5:$]}   // open-ended range: "5 or more"
```

## 11. Constant expressions

An expression is constant if it can be evaluated at elaboration. Constant
expressions are required for: packed dimensions, parameter values, replication
counts, part-select bounds, `case` item labels in a `generate case`, and array
sizes.

```systemverilog
localparam int W = 8;
localparam int D = 1 << W;
localparam int AW = $clog2(D);
localparam int PW = f(W);              // constant functions are allowed

function automatic int f(int w);       // must be automatic, no side effects,
  return (w <= 1) ? 1 : w * 2;         // no time control, no hierarchical refs
endfunction
```

Constant functions are the right way to express derived widths and lookup
tables that would otherwise be unreadable macro soup:

```systemverilog
function automatic int clog2_min1(int n);
  return (n <= 1) ? 1 : $clog2(n);     // $clog2(1) == 0, which breaks widths
endfunction
localparam int PTR_W = clog2_min1(DEPTH);
```
