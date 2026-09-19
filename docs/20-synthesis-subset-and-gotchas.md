# The Synthesizable Subset, and the Gotcha List

## 1. What synthesizes

| Category | Synthesizable | Not |
|---|---|---|
| **Types** | `logic`, `bit`, `wire`, packed arrays/structs/unions, `enum`, `typedef`, 2-state ints | `real`, `shortreal`, `string`, `chandle`, `event`, class handles |
| **Arrays** | packed arrays, unpacked arrays with constant bounds | dynamic arrays, queues, associative arrays |
| **Blocks** | `always_comb`, `always_ff`, `always_latch`, `assign`, `generate` | `initial` (except memory init), `final`, `fork` |
| **Statements** | `if`, `case`/`casez`, `for`/`foreach` (constant bounds), `while` (statically bounded) | `wait`, `forever`, `#delay`, `@` inside a block body |
| **Operators** | all bitwise/arith/logical/shift/concat/`inside`/streaming | `===`, `!==`, `==?`/`!=?` (mostly) |
| **Subroutines** | `automatic` functions with no time control | tasks with timing, recursion with runtime depth |
| **Hierarchy** | modules, `generate`, parameters, interfaces (tool-dependent) | `bind`, hierarchical references, `program` |
| **Verification** | — | classes, constraints, covergroups, `assert property` (ignored, not an error) |

## 2. The gotcha list

### G1 — `logic` driven from two places

```systemverilog
logic y;
assign y = a;
always_comb y = b;        // ERROR
```

One variable, one driver. `always_comb` and `always_ff` enforce this; plain
`always` does not.

### G2 — Inferred latch

```systemverilog
always_comb
  if (en) y = d;          // no else -> latch
```

Fix: default assignment at the top of the block. See
[docs/05](05-procedural-blocks-and-flow.md#7-avoiding-inferred-latches).

### G3 — Incomplete sensitivity list

```systemverilog
always @(a) y = a & b;    // misses b: simulation ≠ synthesis
always_comb y = a & b;    // correct
```

Classic sim/synth mismatch: synthesis builds an AND gate, simulation builds
something that only updates when `a` changes.

### G4 — Blocking assignment in sequential logic

```systemverilog
always_ff @(posedge clk) begin
  b = a;    // race with any other process reading b
  c = b;
end
```

See [docs/15](15-scheduling-and-race-conditions.md).

### G5 — Async reset that cannot be inferred

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (en)          q <= d;      // something before the reset test
  else if (!rst_n) q <= '0;
end
```

Reset must be the first condition, and must assign constants only.

### G6 — Lost carry / truncated product

```systemverilog
logic [7:0] a, b, sum;
sum = a + b;              // carry lost
logic [7:0] t;
logic [15:0] p;
t = a * b;  p = t;        // product truncated at t
```

See [docs/17](17-signed-unsigned-arithmetic.md#3-the-width-algorithm).

### G7 — Signed/unsigned mixing

```systemverilog
logic signed [7:0] a;
logic        [7:0] u;
r = a + u;                // the whole expression becomes UNSIGNED
```

See [docs/17](17-signed-unsigned-arithmetic.md#8-the-trap-catalogue).

### G8 — `casex` hiding an `X`

```systemverilog
casex (sel)  4'b1xxx: ...   endcase   // an X in `sel` MATCHES
```

Use `casez` or `case ... inside`.

### G9 — `full_case`/`parallel_case` attributes

```systemverilog
(* full_case, parallel_case *) case (s) ... endcase
```

Tells synthesis to assume something the simulator does not model, with no
runtime check. Use `unique`/`priority` (which are checked) or a `default`.

### G10 — `unique`/`priority` promise that is not true

```systemverilog
unique case (state)  // if two items can match, sim errors and synth
  ...                // silently assumes they cannot
endcase
```

Only use `unique` where you can prove exclusivity.

### G11 — `$clog2(1) == 0`

```systemverilog
localparam int AW = $clog2(DEPTH);      // DEPTH=1 -> AW=0 -> [-1:0]
localparam int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);   // fix
```

### G12 — Variable declaration initializers on ASIC

```systemverilog
logic [7:0] cnt = 8'h00;     // works on FPGA, IGNORED on ASIC
```

Write a reset.

### G13 — Undeclared identifier becomes a 1-bit wire

```systemverilog
assign data_ouput = x;       // typo -> a new 1-bit wire, no error
```

Fix: `` `default_nettype none `` at the top of every file.

### G14 — Port width mismatch

```systemverilog
module m (input logic [7:0] a);
m u (.a(wide_16bit_signal));      // silently truncated
```

Fix: turn on the lint. Most tools warn; treat it as an error.

### G15 — `$unit` scope dependence

Types declared in an included header land in whichever compilation unit the
include happened to be part of. Put types in packages.

### G16 — Non-constant part select

```systemverilog
y = v[i : i+3];        // ERROR: bounds must be constant
y = v[i +: 4];         // correct
```

### G17 — Combinational loop through a function

```systemverilog
always_comb y = f(y);   // always_comb is sensitive to y -> infinite loop
```

### G18 — Reading an unpacked array as a value

```systemverilog
logic [7:0] mem [0:3];
logic [31:0] all = mem;        // ERROR
logic [31:0] all = {mem[3], mem[2], mem[1], mem[0]};   // or use a packed array
```

### G19 — Multi-dimensional index order

```systemverilog
logic [3:0][7:0] m [0:9];
m[a][b][c]     // a indexes the UNPACKED dim, b the [3:0], c the [7:0]
```

Unpacked dimensions index first, left to right; then packed, left to right.

### G20 — Shifting by a negative or oversized amount

```systemverilog
x << n;     // n is treated as UNSIGNED; n = -1 means shift by 4294967295 -> 0
```

### G21 — `sum()` overflowing in the element type

```systemverilog
byte a[] = '{100,100,100};
a.sum()                     // 44
a.sum() with (int'(item))   // 300
```

### G22 — Clock domain crossing with no synchronizer

Any signal crossing between two unrelated clocks needs a synchronizer. A
two-flop synchronizer for a single bit; a gray-coded pointer + synchronizer for
a FIFO; a handshake or an async FIFO for a bus. Never synchronize a multi-bit
bus with per-bit two-flop synchronizers — the bits will arrive in different
cycles.

See [`examples/rtl/cdc_bit.sv`](../examples/rtl/cdc_bit.sv) and
[`examples/rtl/async_fifo.sv`](../examples/rtl/async_fifo.sv).

### G23 — Gated clocks written as logic

```systemverilog
assign gclk = clk & en;                     // glitchy
always_ff @(posedge gclk) q <= d;
```

Use a clock-enable on the flop (`if (en) q <= d;`) and let the tool insert a
proper integrated clock gating cell.

### G24 — Reset release not synchronized

An async reset whose *release* is not synchronized to the clock lets different
flops leave reset on different cycles. Use a reset synchronizer.

### G25 — Assertions in the synthesis file list

Most tools ignore `assert property`, but not all, and `$error` inside an
immediate assertion can trip up a parser. Keep them in the RTL but guard the
riskier ones:

```systemverilog
`ifndef SYNTHESIS
  a_check: assert property (...);
`endif
```

## 3. A file template

```systemverilog
// -----------------------------------------------------------------------------
// module_name.sv
// Brief description.
// -----------------------------------------------------------------------------
`default_nettype none

module module_name
  import my_pkg::*;
#(
  parameter  int unsigned DW    = 32,
  parameter  int unsigned DEPTH = 16,
  localparam int unsigned AW    = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
  input  var logic          clk,
  input  var logic          rst_n,
  input  var logic [DW-1:0] din,
  output var logic [DW-1:0] dout
);

  // ---- parameter checks (elaboration time) ---------------------------------
  if (DEPTH < 2) $error("DEPTH must be >= 2");

  // ---- declarations --------------------------------------------------------
  logic [DW-1:0] data_q, data_d;

  // ---- combinational -------------------------------------------------------
  always_comb begin
    data_d = data_q;            // default: hold
    ...
  end

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) data_q <= '0;
    else        data_q <= data_d;
  end

  assign dout = data_q;

  // ---- assertions ----------------------------------------------------------
`ifndef SYNTHESIS
  a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
                           !$isunknown(din));
`endif

endmodule

`default_nettype wire
```

## 4. Lint rules worth enforcing

| Rule | Why |
|---|---|
| No implicit nets (`` `default_nettype none ``) | catches typos |
| No width mismatches in assignments or port connections | catches G6, G14 |
| No inferred latches | catches G2 |
| No mixed blocking/non-blocking per variable | catches G4 |
| No multiple drivers | catches G1 |
| No `casex` | catches G8 |
| No `full_case`/`parallel_case` attributes | catches G9 |
| Every `case` has a `default` | catches incomplete decode |
| Every `always_ff` has a reset for every assigned variable | catches unreset state |
| No signed/unsigned mixing without an explicit cast | catches G7 |
| No hierarchical references in RTL | catches non-synthesizable code |
| All subroutines `automatic` | catches reentrancy bugs |

No single open-source tool catches all of these. This repository's `make lint`
uses the two it has:

```bash
# Vivado's analyser: syntax, elaboration, undeclared identifiers (which
# `default_nettype none` turns every typo into).
xvlog -sv <package files> <rtl files>

# Yosys (ships with SymbiYosys): inferred latches, which xvlog does NOT report.
yosys -p "read_verilog -sv -DSYNTHESIS m.sv; hierarchy -top m; proc"
#   -> "ERROR: Latch inferred for signal ... from always_comb process"
```

**Neither reports width mismatches**, which is the single most valuable check in
the list above and the subject of [docs/17](17-signed-unsigned-arithmetic.md).
That is a real gap in this toolchain, not an oversight: a commercial linter
(Spyglass, Lint, Questa AutoCheck) or Verilator's `-Wall` covers it, and if one
is available it is worth adding purely for `WIDTHEXPAND`/`WIDTHTRUNC`.

The gap is partly closed from the other direction: `examples/arith/width_rules_tb.sv`
and `signedness_demo.sv` pin the language rules down with runnable assertions,
and the formal proofs in `formal/` catch width bugs that change behaviour — a
truncated product or an out-of-range part-select fails an equivalence proof
immediately. `div_const.sv` had exactly such a bug, and formal found it on the
first run.
