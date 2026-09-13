# Lexical Elements and Literals

## Identifiers

```systemverilog
a_name  _leading  n123  has$dollar        // simple: [a-zA-Z_][a-zA-Z0-9_$]*
\bus[3].data      \a+b                    // escaped: backslash ... whitespace
```

Escaped identifiers exist so that netlists from other tools (which may contain
`[`, `.`, `/`) round-trip. The terminating whitespace **is** part of the token —
`\foo .bar` is the identifier `foo` followed by `.bar`.

SystemVerilog is **case sensitive**. `Clk` and `clk` are different signals, and
because undeclared identifiers default to 1-bit wires, a typo becomes a silent
disconnected net. Put `` `default_nettype none `` at the top of every file and
this class of bug becomes a compile error.

## Comments and attributes

```systemverilog
// line
/* block, does not nest */
(* full_case, parallel_case *)  case (x) ...      // attribute: a tool hint
(* keep = "true" *) logic [7:0] debug_bus;
(* ram_style = "block" *) logic [31:0] mem [0:1023];
```

Attributes are syntactically part of the language but semantically opaque —
each tool defines its own. They never change simulation behaviour, which is
exactly why `(* full_case *)` is dangerous: it tells synthesis to treat unlisted
cases as don't-care while the simulator still models them as "hold the previous
value", creating a sim/synth mismatch. Use `unique case` / a `default` branch
instead, which both tools see.

## Number literals

```
[size] ['[s]base] value
```

| Field | Notes |
|---|---|
| `size` | decimal, in **bits**. Omitted → "unsized" (at least 32 bits) |
| `s` | marks the literal **signed** |
| `base` | `b`/`B` binary, `o`/`O` octal, `d`/`D` decimal, `h`/`H` hex |
| `value` | digits, plus `x`/`z`/`?` for non-decimal bases; `_` anywhere |

```systemverilog
8'b1010_1010     8'o252      8'd170      8'hAA        // all 170
8'sd170          // signed 8-bit: the pattern 1010_1010 read as -86
4'bz             // 4'bzzzz -- x and z fill LEFTWARD to the declared size
4'b1z            // 4'b001z -- but only 0/x/z extend; a leading 1 does not
16'h1            // 16'h0001
'0 '1 'x 'z      // unsized fill: replicate to whatever width the context needs
'hFF             // unbased unsized: 32 bits, unsigned
```

**The extension rule for `x`/`z` literals** catches people: if the leftmost
specified digit is `x` or `z`, it extends leftward; otherwise the value is
zero-extended. So `8'bx` is `8'bxxxxxxxx` but `8'b1x` is `8'b0000_001x`.

### Signedness of literals

| Literal | Signed? | Why it matters |
|---|---|---|
| `42` | **signed**, ≥32 bits | Adding it to an expression drags the whole thing to 32-bit signed |
| `8'd42` | unsigned | |
| `8'sd42` | signed | |
| `-8'd42` | **unsigned** | unary minus on an unsigned value; the result is `8'd214` |
| `'0` `'1` | unsigned | |

See [docs/17](17-signed-unsigned-arithmetic.md#2-what-is-signed-what-is-unsigned).

### Real literals

```systemverilog
3.14      1.0e-9      1E6      0.5        // must have a digit on both sides
.5        // ILLEGAL
5.        // ILLEGAL
1e6       // legal (exponent form needs no decimal point)
```

## String literals

```systemverilog
"hello"                       // a packed 40-bit vector, or a `string` value
"a\nb\t\"q\"\\ \101 \x41"     // \n \t \\ \" \ddd (octal) \xhh (hex)
"" == 8'h00                   // empty string in a vector context

string s = "abc";
s.len()  s.getc(i)  s.putc(i,c)  s.substr(a,b)  s.toupper()  s.tolower()
s.atoi() s.atohex() s.atoreal() s.itoa(i) s.hextoa(i) s.realtoa(r)
s.compare(t) s.icompare(t)
{s, "-suffix"}                // concatenation works on strings
```

Assigning a string literal to a fixed-width vector **right-justifies and
zero-pads on the left**, truncating from the left if too long:

```systemverilog
logic [31:0] v = "AB";        // 32'h0000_4142
logic [7:0]  w = "AB";        // 8'h42  -- 'A' silently lost
```

## Time literals

```systemverilog
#10        // 10 time units (per the enclosing timeunit/timescale)
#10ns  #1.5us  #100ps  #2fs  #1s  #3ms
##3        // 3 clocking-block cycles (only in a clocking domain / SVA)
```

```systemverilog
module m;
  timeunit      1ns;
  timeprecision 1ps;     // prefer these over `timescale: they are scoped
  ...
endmodule
```

`` `timescale `` is file-ordered and leaks across files depending on
compilation order — a genuine source of "it works in one regression and not
another". `timeunit`/`timeprecision` are module-scoped and deterministic.

## Structure literals (assignment patterns)

```systemverilog
'{1, 2, 3}                       // array or struct, positional
'{a:1, b:2}                      // struct, by field name
'{default: '0}                   // fill everything
'{int: 0, string: ""}            // by type
'{3{1'b1}}                       // replication inside a pattern
logic [7:0] m [0:3] = '{8'h1, 8'h2, 8'h3, 8'h4};
```

Note the leading apostrophe: `'{...}` is an assignment pattern (typed,
element-wise) while `{...}` is a concatenation (untyped, bitwise). They are
different operators and are not interchangeable.

## Compiler directives

```systemverilog
`define WIDTH 8
`define MAX(a,b) (((a) > (b)) ? (a) : (b))       // parenthesize EVERY argument
`define REG(name) logic [`WIDTH-1:0] name``_q;   // `` is token paste
`undef WIDTH

`ifdef SIMULATION ... `elsif FPGA ... `else ... `endif
`ifndef FOO_SVH
`define FOO_SVH
  ...
`endif

`include "defs.svh"
`default_nettype none          // top of every file
`default_nettype wire          // bottom of every file, to be a good citizen
`line 42 "gen.sv" 0
`resetall
`pragma protect ...
`__FILE__  `__LINE__
```

Macros are **textual, unscoped, and order-dependent**. Anything that is a value
belongs in a `localparam`; anything that is a type belongs in a `typedef`; both
belong in a package. Reserve macros for:

- conditional compilation (`` `ifdef ``),
- include guards,
- generating repetitive *syntax* that parameters cannot express (e.g. a
  register-field declaration macro).
