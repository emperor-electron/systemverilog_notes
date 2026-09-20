# SystemVerilog Cheatsheet

A dense outline of IEEE 1800-2023 SystemVerilog. Synthesizable constructs are
marked **[S]**; simulation/verification-only constructs are marked **[V]**.
Deep dives live in [`docs/`](docs/); runnable code lives in [`examples/`](examples/).

---

## Table of contents

1. [Lexical elements](#1-lexical-elements)
2. [Literals](#2-literals)
3. [Data types](#3-data-types)
4. [Arrays](#4-arrays)
5. [Structs, unions, enums](#5-structs-unions-enums)
6. [Operators](#6-operators)
7. [Assignments](#7-assignments)
8. [Procedural blocks](#8-procedural-blocks)
9. [Control flow](#9-control-flow)
10. [Tasks and functions](#10-tasks-and-functions)
11. [Modules and hierarchy](#11-modules-and-hierarchy)
12. [Parameters and generate](#12-parameters-and-generate)
13. [Interfaces](#13-interfaces)
14. [Packages and scope](#14-packages-and-scope)
15. [Processes and synchronization](#15-processes-and-synchronization)
16. [Classes and OOP](#16-classes-and-oop)
17. [Randomization](#17-randomization)
18. [Assertions](#18-assertions)
19. [Coverage](#19-coverage)
20. [System tasks and functions](#20-system-tasks-and-functions)
21. [DPI and program blocks](#21-dpi-and-program-blocks)
22. [Compiler directives](#22-compiler-directives)
23. [Scheduling semantics](#23-scheduling-semantics)
24. [Arithmetic quick reference](#24-arithmetic-quick-reference)
25. [Pipelining and timing idioms](#25-pipelining-and-timing-idioms)
26. [Structural technique idioms](#26-structural-technique-idioms)
27. [Formal verification with sby](#27-formal-verification-with-sby)
28. [FSM idioms](#28-fsm-idioms)

---

## 1. Lexical elements

| Element | Form |
|---|---|
| Line comment | `// ...` |
| Block comment | `/* ... */` |
| Simple identifier | `[a-zA-Z_][a-zA-Z0-9_$]*` — case sensitive |
| Escaped identifier | `\my+weird.name ` (terminated by whitespace) |
| Compiler directive | `` `define ``, `` `ifdef ``, `` `include ``, ... |
| System task/function | `$display`, `$bits`, ... |
| Attribute | `(* keep = 1 *)` — tool hint, ignored semantically |

Keywords are reserved per *language version*; `` `begin_keywords "1800-2023" ``
scopes which set is active.

---

## 2. Literals

```systemverilog
// <size>'<base><value>  — base: b o d h, optional s for signed
8'b1010_1010     // underscores are ignored, purely cosmetic
8'hFF            // 255
8'sd200          // sized signed decimal -> bit pattern 1100_1000 = -56
'0 '1 'x 'z      // unsized fill literals: replicate to context width  [S]
'hFF             // unbased unsized, 32-bit by default
32'dx            // all-x
1_000_000        // unsized decimal -> at least 32 bits, signed
3.14  1.2e-3     // real
10ns 1.5us       // time literal (needs `timeunit`/`timescale`)
"hello"          // string literal: packed 8*N bit vector, or `string` type
```

`'0`/`'1` are the idiomatic width-agnostic fills: `q <= '0;` zeroes any shape,
including structs and unpacked arrays.

---

## 3. Data types

### 3.1 The two value systems

| Family | Values | Members |
|---|---|---|
| 4-state | `0 1 X Z` | `logic`, `reg`, `integer`, `time`, `wire`/net types |
| 2-state | `0 1` | `bit`, `byte`, `shortint`, `int`, `longint` |

2-state types simulate faster and cannot hold `X`, so they *hide* reset bugs
and uninitialized-memory bugs in RTL. **Use 4-state `logic` for RTL** and
2-state for testbench scoreboards, loop counters, and models.

### 3.2 Integral types

| Type | Width | Sign | State |
|---|---|---|---|
| `bit` | 1 (vectorizable) | unsigned | 2 |
| `logic` / `reg` | 1 (vectorizable) | unsigned | 4 |
| `byte` | 8 | **signed** | 2 |
| `shortint` | 16 | **signed** | 2 |
| `int` | 32 | **signed** | 2 |
| `longint` | 64 | **signed** | 2 |
| `integer` | 32 | **signed** | 4 |
| `time` | 64 | unsigned | 4 |

Add `unsigned`/`signed` to override: `int unsigned i;`, `logic signed [15:0] s;`

### 3.3 Nets vs variables

```systemverilog
wire  w;            // net: resolved from all drivers, needs continuous drive
logic v;            // variable: last write wins, one driver (procedural or continuous)
tri / wand / wor / tri0 / tri1 / trireg / supply0 / supply1 / uwire
```

- `logic` may be driven by **one** `assign` **or** procedural code, not both.
- Multiple drivers (bidirectional bus, open-drain) require a **net**.
- Default net type for undeclared identifiers is `wire`; kill that footgun with
  `` `default_nettype none `` at the top of every file. **[S]**

### 3.4 Non-integral types

```systemverilog
real       r;    // 64-bit IEEE-754 double                      [V]
shortreal  f;    // 32-bit IEEE-754 single                       [V]
realtime   t;    //                                              [V]
string     s;    // dynamic, .len() .substr() .atoi() .toupper() [V]
chandle    h;    // opaque pointer from DPI                      [V]
event      e;    // synchronization object                       [V]
void             // function return / "no value"
```

### 3.5 User-defined types

```systemverilog
typedef logic [7:0] byte_t;
typedef byte_t      mem_t [0:255];   // unpacked array type
typedef struct packed { ... } hdr_t;
typedef enum logic [1:0] { ... } state_e;
typedef hdr_t hdr_q_t[$];            // queue of structs
typedef class Foo;                   // forward declaration
```

### 3.6 Casting

```systemverilog
int'(x)            // type cast
8'(x)              // size cast  (truncates or zero/sign-extends)
signed'(x)         // signedness cast
unsigned'(x)
$signed(x) $unsigned(x)              // function form, identical effect
my_struct_t'(bitvec)                 // bit-pattern reinterpret (widths must match)
$cast(dst, src)                      // dynamic/checked cast; task or function form  [V]
```

`'(...)` casts are **static** and checked at elaboration; `$cast` is **dynamic**
and returns 0 on failure (used for downcasting class handles and for
range-checking into enums).

---

## 4. Arrays

### 4.1 Packed vs unpacked

```systemverilog
logic [7:0]       packed_vec;        // packed: contiguous bits, one integral value
logic [3:0][7:0]  packed_2d;         // 32 bits total; packed_2d[2] is 8 bits
logic             unpacked [0:255];  // unpacked: 256 separate 1-bit objects
logic [7:0]       mem [0:1023];      // 1024 entries of 8 bits  <- typical RAM
logic [7:0]       mem [1024];        // same, [0:1023] shorthand
logic [3:0][7:0]  m [0:9];           // 10 entries, each 4x8 packed
```

| | Packed | Unpacked |
|---|---|---|
| Layout | guaranteed contiguous bits | implementation-defined |
| Can be treated as an integer | yes | no |
| Arithmetic / bit-select across whole thing | yes | no |
| Can hold `real`, `string`, structs w/ unpacked | no | yes |
| Dimensions declared | before the name | after the name |
| Synthesis use | buses, sub-fields | memories, register files |

Dimension order: `logic [A][B] name [C][D];` — index as `name[c][d][a][b]`.
Leftmost declared dimension varies slowest.

### 4.2 Selects

```systemverilog
v[3]          // bit select
v[7:4]        // part select (constant)
v[i +: 4]     // indexed part select, width 4, bits [i+3 : i]   <- use this
v[i -: 4]     // bits [i : i-3]
{a, b, c}     // concatenation (always unsigned!)
{4{a}}        // replication
{<<{v}}       // streaming: reverse bit order
{>>{a,b}}     // streaming: pack left-to-right
```

Out-of-bounds read of a packed value yields `X`; of an unpacked array it yields
the default value of the element type. Never rely on it — it is a bug.

### 4.3 Dynamic arrays, queues, associative arrays **[V]**

```systemverilog
int da[];                 da = new[16];  da = new[32](da);  da.delete();
int q[$];                 q.push_back(x); q.push_front(x);
                          x = q.pop_front(); q.insert(i,x); q.delete(i);
                          q = {}; q.size();
int q5[$:5];              // bounded queue, max 6 entries
int aa[string];           aa["k"]=1; aa.exists("k"); aa.first(s); aa.next(s);
                          aa.num(); aa.delete("k");
int aa2[*];               // wildcard index
```

### 4.4 Array manipulation methods **[V]**

```systemverilog
a.size() a.sum() a.product() a.and() a.or() a.xor()
a.min() a.max() a.unique() a.unique_index()
a.find(x) with (x > 3)        a.find_first / find_last / find_index
a.sort()  a.rsort()  a.reverse()  a.shuffle()
q.sum() with (int'(item.valid))   // `item` is the implicit iterator
```

`sum()` accumulates in the **element type's** width — a common overflow trap.
Cast inside the `with`: `a.sum() with (int'(item))`.

---

## 5. Structs, unions, enums

### 5.1 Structs

```systemverilog
typedef struct packed {          // packed: one integral value, MSB = first field
  logic [3:0] opcode;
  logic [1:0] mode;
  logic       en;
} ctrl_t;                        // 7 bits; ctrl_t'(7'h41) reinterprets

typedef struct {                 // unpacked: fields may be any type
  string  name;
  int     data[];
} record_t;

ctrl_t c = '{opcode:4'h3, mode:2'b01, en:1'b1};   // assignment pattern
ctrl_t d = '{default:'0, en:1'b1};                // fill rest with 0
```

Packed structs are the idiomatic way to carry a bundled bus through ports
while keeping named field access. A `packed` struct containing an `X` in any
field makes the whole value non-2-state; that is desirable in RTL.

### 5.2 Unions

```systemverilog
typedef union packed {           // all members must be the same width
  logic [31:0] word;
  ctrl_t [4:0] fields;
} u_t;

typedef union { int i; real r; } tagged_u;        // unpacked, unchecked
typedef union tagged { void Invalid; int Valid; } maybe_t;   // tagged union [V]
```

### 5.3 Enums

```systemverilog
typedef enum logic [2:0] {
  IDLE  = 3'b001,
  RUN   = 3'b010,
  DONE  = 3'b100
} state_e;                       // base type explicit -> controls encoding [S]

typedef enum { A, B, C } simple_e;          // base int, values 0,1,2
typedef enum { R[3] }    rep_e;             // R0 R1 R2
typedef enum { X[1:3] }  rng_e;             // X1 X2 X3
```

Methods: `.first() .last() .next(N) .prev(N) .num() .name()`.
`.name()` returns `""` for a value not in the enum — handy in a `$display` of a
corrupted FSM state.

Enums are **strongly typed**: you cannot assign an arbitrary integer to an enum
variable without a cast. That is exactly the property that makes them the right
FSM state type.

---

## 6. Operators

### 6.1 Precedence (highest to lowest)

```
 1  () [] :: .                            (unary) ! ~ + - & ~& | ~| ^ ~^ ++ --
 2  **
 3  * / %
 4  + -
 5  << >> <<< >>>
 6  < <= > >= inside dist
 7  == != === !== ==? !=?
 8  & ~&
 9  ^ ~^ ^~
10  | ~|
11  &&
12  ||
13  ?:                                    (right associative)
14  -> <->                                (implication)
15  = += -= *= ... <= (assignment)        {} {{}}  (concat, lowest)
```

When in doubt, parenthesize. The classic bug is
`a & b == c` parsing as `a & (b == c)`.

### 6.2 Equality operators

| Op | Name | `X`/`Z` behaviour |
|---|---|---|
| `==` `!=` | logical | returns `X` if either operand has `X`/`Z` |
| `===` `!==` | case | compares `X`/`Z` literally, returns only 0/1 **[V]** |
| `==?` `!=?` | wildcard | `X`/`Z` in the **right** operand are don't-care **[V]** |

`===` is not synthesizable. In RTL use `==`; in a testbench check use `===` so
that an `X` never silently passes a comparison.

### 6.3 Shifts

| Op | Behaviour |
|---|---|
| `<<` `>>` | logical, fills with 0 |
| `<<<` | arithmetic left = logical left |
| `>>>` | arithmetic right: fills with the sign bit **iff the left operand is signed** |

`>>>` on an unsigned operand fills with zeros. This surprises people constantly —
see [docs/17](docs/17-signed-unsigned-arithmetic.md).

### 6.4 Other

```systemverilog
a inside {1, 2, [5:9], arr}       // set membership
a ** b                            // power; real if either operand real
&v  |v  ^v  ~&v  ~|v  ~^v         // unary reduction -> 1 bit
a ?: b                            // ternary; if cond is X, result is bitwise
                                  //   merge of a and b (X where they differ)
++i --i i++ i--                   // increment/decrement (not in expressions
                                  //   with side-effect ordering guarantees)
a <-> b                           // equivalence  [V, assertions]
a -> b                            // implication  [V, assertions]
```

---

## 7. Assignments

```systemverilog
assign y = a & b;                 // continuous, nets/vars, drives forever    [S]
always_comb y = a & b;            // procedural, blocking                     [S]
x = y;                            // blocking: executes immediately            [S]
q <= d;                           // non-blocking: RHS sampled now, LHS
                                  //   updated in NBA region                   [S]
force / release                   // override, sim only                        [V]
assign / deassign                 // procedural continuous assign, avoid        [V]
x += 1;  x <<= 2;  x &= mask;     // compound assignment                       [S]
```

### The rule

> **Sequential logic (`always_ff`): non-blocking `<=`.
> Combinational logic (`always_comb`): blocking `=`.
> Never mix them in one block. Never drive one variable from two blocks.**

This is not style pedantry — it is what makes simulation match synthesis. See
[docs/05](docs/05-procedural-blocks-and-flow.md#why-the-blockingnon-blocking-rule-exists).

---

## 8. Procedural blocks

```systemverilog
always_comb        begin ... end   // [S] combinational: infers sensitivity,
                                   //     runs once at t=0, checks for latches
always_latch       begin ... end   // [S] intentional latch
always_ff @(posedge clk) ...       // [S] flip-flops; tool errors if not inferable
always @(a or b)   ...             //     legacy; use always_comb
always @*          ...             //     legacy; subtly different from always_comb
initial            begin ... end   // [V] (some tools accept for ROM/RAM init) 
final              begin ... end   // [V] runs once at end of simulation
```

`always_comb` vs `always @*`:

| | `always @*` | `always_comb` |
|---|---|---|
| Triggers at time 0 | no | **yes** |
| Sensitive to contents of called functions | no | **yes** |
| Multiple drivers allowed | yes | **no** (compile error) |
| Latch inference checked | no | **yes** (tool warns) |

### Sequential templates **[S]**

```systemverilog
// Synchronous reset
always_ff @(posedge clk) begin
  if (!rst_n) q <= '0;
  else        q <= d;
end

// Asynchronous reset, synchronous release
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) q <= '0;
  else        q <= d;
end
```

The async-reset sensitivity list must contain **only** clock and reset edges,
and the reset must be the first tested condition — otherwise the tool cannot
map it to a flop's async pin.

---

## 9. Control flow

```systemverilog
if (c) ... else if (c2) ... else ...

unique if / unique0 if / priority if           // [S] decision qualifiers

case (sel) 4'b0001: ...  default: ... endcase
casez (sel) 4'b1???: ... endcase               // Z and ? are don't-care
casex (sel) ...                                // X and Z don't-care -- AVOID
case (sel) inside { [0:3] }: ... endcase       // set-membership case
unique case / priority case / unique0 case

for (int i = 0; i < N; i++) ...                // [S] bounds must be static
foreach (arr[i, j]) ...                        // [S] for static arrays
repeat (N) ...                                 // [S] if N static
while (c) ... / do ... while (c);              // [S] if statically bounded
forever ...                                    // [V] (or in always with @)
break / continue / return
```

### Decision qualifiers

| Qualifier | Promise | Tool effect |
|---|---|---|
| `unique` | exactly one branch matches | parallel mux; runtime error if 0 or >1 match |
| `unique0` | at most one matches | parallel mux; error only if >1 |
| `priority` | at least one matches | priority mux; error if none |

These are **assertions, not optimizations**. If the promise is violated the
simulator reports it and synthesis silently assumes it anyway — which is how
sim/synth mismatches are born. Prefer a `default` branch over `priority`, and
only use `unique` where you can prove one-hot.

`casex` treats `X` in the **case expression** as a wildcard, so an unknown value
can match a real branch and mask a bug. Use `casez` (or `case ... inside`).

---

## 10. Tasks and functions

```systemverilog
function automatic logic [7:0] add(input logic [7:0] a, b);
  return a + b;
endfunction

task automatic drive(input int n);
  repeat (n) @(posedge clk);            // tasks may consume time
endtask
```

| | `function` | `task` |
|---|---|---|
| Consumes time | no (unless `void` + `fork`) | yes |
| Return value | yes | no (use `output` args / `ref`) |
| Callable from | expression | statement |
| Synthesizable | yes, if `automatic` and loop-bounded **[S]** | rarely |

- `automatic` = stack-allocated per call. **Always write `automatic`** for
  reentrancy; module-scope subroutines default to `static`, which silently
  breaks recursion and concurrent calls.
- Argument directions: `input` (default), `output`, `inout`, `ref`,
  `const ref`. `ref` requires `automatic`.
- `void'(f(x));` discards a return value explicitly.

---

## 11. Modules and hierarchy

```systemverilog
module counter #(
  parameter int WIDTH = 8,
  parameter logic [WIDTH-1:0] INIT = '0
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en,
  output logic [WIDTH-1:0] q
);
  ...
endmodule
```

### Port connection styles

```systemverilog
counter u0 (clk, rst_n, en, q);                 // positional -- avoid
counter u1 (.clk(clk), .rst_n(rst_n), .en(e), .q(cnt));   // named  <- do this
counter u2 (.clk, .rst_n, .en, .q);             // implicit .name
counter u3 (.*);                                // wildcard -- terse, opaque
counter #(.WIDTH(16)) u4 (.*);                  // parameter override
```

Port direction defaults to `wire` for `input`/`inout`; an `output` may be
`logic` (procedurally driven) or a net. Declare port types explicitly.

Other top-level constructs: `program` **[V]**, `interface`, `package`,
`checker` **[V]**, `primitive` (UDP), `config`, `bind`.

```systemverilog
bind cpu_core my_assertions u_chk (.*);   // attach checker without editing DUT [V]
```

---

## 12. Parameters and generate

```systemverilog
parameter  int P = 4;         // overridable from outside
localparam int L = P * 2;     // derived, not overridable
parameter  type T = logic[7:0];        // type parameter
specparam                     // timing only
`define M 4                   // text macro -- no type, no scope. prefer parameter
```

### Generate **[S]**

```systemverilog
genvar i;
generate
  for (i = 0; i < N; i++) begin : g_lane        // label is REQUIRED for
    lane u_lane (.in(d[i]), .out(q[i]));        //   hierarchical naming
  end

  if (MODE == FAST) begin : g_fast
    fast_unit u (.*);
  end else begin : g_slow
    slow_unit u (.*);
  end

  case (WIDTH)
    8:       byte_unit  u (.*);
    default: wide_unit  u (.*);
  endcase
endgenerate
```

The `generate`/`endgenerate` keywords are optional in SystemVerilog; the
`begin : label` is not, if you want predictable instance paths
(`top.g_lane[3].u_lane`).

Elaboration-time constant functions may compute parameters:

```systemverilog
function automatic int clog2_min1(int n);
  return (n <= 1) ? 1 : $clog2(n);
endfunction
localparam int AW = clog2_min1(DEPTH);
```

---

## 13. Interfaces

```systemverilog
interface axis_if #(parameter int DW = 32) (input logic clk, input logic rst_n);
  logic [DW-1:0] tdata;
  logic          tvalid, tready, tlast;

  modport src  (output tdata, tvalid, tlast, input  tready, input clk, rst_n);
  modport dst  (input  tdata, tvalid, tlast, output tready, input clk, rst_n);

  clocking cb_mon @(posedge clk);              // [V]
    default input #1step output #0;
    input tdata, tvalid, tready, tlast;
  endclocking
  modport mon (clocking cb_mon);

  // Assertions can live in the interface and apply to every instance
  property no_data_change;
    @(posedge clk) disable iff (!rst_n)
      (tvalid && !tready) |=> $stable(tdata);
  endproperty
  assert property (no_data_change);
endinterface
```

Usage:

```systemverilog
module producer (axis_if.src bus);  ...  endmodule

axis_if #(.DW(64)) bus (.clk, .rst_n);
producer u_p (.bus(bus));
consumer u_c (.bus(bus));
```

Interfaces bundle signals, direction (`modport`), timing (`clocking`), and
protocol checks (`assert property`) in one reusable object. Virtual interfaces
(`virtual axis_if`) are how class-based testbenches reach into static RTL.

---

## 14. Packages and scope

```systemverilog
package alu_pkg;
  typedef enum logic [2:0] { OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR } op_e;
  localparam int XLEN = 32;
  function automatic logic [XLEN-1:0] sext(input logic [15:0] v);
    return {{16{v[15]}}, v};
  endfunction
endpackage

import alu_pkg::*;            // wildcard import
import alu_pkg::op_e;         // explicit import
alu_pkg::op_e op;             // scope resolution, no import needed
```

Scope resolution operator `::` also reaches into classes (`C::static_member`),
`std::` (built-in package: `std::randomize`, `std::mailbox`, `std::semaphore`),
and `$unit` (the anonymous compilation-unit scope — avoid relying on it, it is
compilation-order dependent).

Import in the **module header** so that parameters can use imported types:

```systemverilog
module alu import alu_pkg::*; #(parameter int W = XLEN) (...);
```

---

## 15. Processes and synchronization

*Simulation only — none of this section is synthesizable.*

```systemverilog
fork ... join          // wait for all
fork ... join_any      // wait for first
fork ... join_none     // do not wait; children run when parent blocks
wait fork;             // block until all children of this process finish
disable fork;          // kill all children
disable label;         // kill a named block/task

@(posedge clk)  @(negedge x)  @(x)  @(e)   // edge / event
wait (expr);                               // level-sensitive, returns
                                           //   immediately if already true
#10  #(1.5ns)  ##3                         // delay; ##N only in clocking domain
->e   ->>e                                 // trigger event, non-blocking trigger
e1.triggered                               // persistent within a time step
```

### Synchronization objects (`std::`)

```systemverilog
semaphore sem = new(1);   sem.get(1);  sem.put(1);  sem.try_get(1);
mailbox #(pkt_t) mbx = new(4);
mbx.put(p); mbx.get(p); mbx.peek(p); mbx.try_put(p); mbx.num();
```

**`fork`-in-a-loop trap:** with `join_none`, every child sees the *same*
variable unless you copy it into an `automatic` inside the loop body:

```systemverilog
for (int i = 0; i < 4; i++) begin
  automatic int k = i;          // REQUIRED
  fork  do_thing(k);  join_none
end
```

---

## 16. Classes and OOP

*Simulation only — none of this section is synthesizable.*

```systemverilog
class Packet #(type T = logic [7:0]) extends Base implements IDrivable;
  rand  bit [7:0] payload[];
  randc bit [3:0] id;
  local int       secret;         // local / protected / (default) public
  static int      count;          // one per class
  const  int      tag;            // set once in the constructor

  function new(int t = 0);
    super.new();
    tag = t;
    count++;
  endfunction

  virtual function void show();   // virtual -> polymorphic dispatch
    $display("%p", this);
  endfunction

  pure virtual function int size();   // only in a `virtual class`
endclass
```

Key points:

- Handles, not values: `Packet p = new();` — assignment copies the *handle*.
  Deep copy needs a hand-written `copy()` or `clone()`.
- `virtual class` = abstract; cannot be instantiated.
- `interface class` + `implements` gives multiple inheritance of API only.
- `extern` + `class::method` splits declaration from body.
- `this` = current object; `super` = parent class.
- Parameterized classes are *specialized* per parameter set: `Packet#(int)` and
  `Packet#(bit)` are unrelated types with separate statics.
- Garbage collected — no `delete`; drop the last handle.

---

## 17. Randomization

*Simulation only — none of this section is synthesizable.*

```systemverilog
class Cfg;
  rand  bit [7:0] len;
  rand  bit [3:0] kind;
  randc bit [2:0] cycle;              // cyclic: no repeat until all values used
  bit [7:0]       max_len;            // non-rand: a constraint input

  constraint c_len  { len inside {[1:max_len]}; }
  constraint c_kind { kind dist {0 := 50, [1:3] := 10, [4:15] :/ 40}; }
  constraint c_impl { (kind == 0) -> len < 16; }
  constraint c_solv { solve kind before len; }   // steer distribution, not legality
  constraint c_uniq { unique {a, b, c}; }

  function void pre_randomize();  ... endfunction
  function void post_randomize(); ... endfunction
endclass

if (!cfg.randomize()) $fatal(1, "randomize failed");
cfg.randomize() with { len == 64; };          // inline constraint
cfg.randomize(len);                           // randomize a subset; rest are state
cfg.c_kind.constraint_mode(0);                // disable a constraint
cfg.len.rand_mode(0);                         // make a field non-random
std::randomize(x, y) with { x < y; };         // scope randomize, no class needed
```

`:=` sets the weight of **each** value in a range; `:/` divides the weight
**across** the range. Always check the return value of `randomize()` — a failed
solve leaves the object unchanged and is otherwise silent.

---

## 18. Assertions

### Immediate **[V]**

```systemverilog
assert (a == b) else $error("mismatch %0d != %0d", a, b);
assume (req_valid);
cover  (state == DONE);
assert #0 (cond);           // deferred: re-evaluated at end of time step,
                            //   avoids glitch-induced false failures
assert final (cond);        // evaluated at the end of simulation
```

### Concurrent (SVA)

```systemverilog
// Sequences
sequence s_req;  req ##1 !req;  endsequence
sequence s_rng;  a ##[1:5] b;   endsequence           // bounded
sequence s_open; a ##[1:$] b;   endsequence           // unbounded (eventually)
   a[*3]      // consecutive repetition, 3 times
   a[->3]     // goto: 3rd non-consecutive occurrence, ends on it
   a[=3]      // non-consecutive, may have trailing non-a
   a throughout s        s1 within s2       s1 and s2      s1 or s2
   s1 intersect s2       first_match(s)

// Properties
property p_handshake;
  @(posedge clk) disable iff (!rst_n)
    req |-> ##[1:4] ack;            // |-> overlapped: consequent starts same cycle
endproperty                          // |=> non-overlapped: starts next cycle

assert property (p_handshake) else $error("no ack");
cover  property (p_handshake);
assume property (@(posedge clk) !(rd && wr));   // formal constraint
restrict property (...);                        // formal only
expect (...)                                    // procedural blocking wait
```

### Sampled value functions

```systemverilog
$past(x)  $past(x, N)  $past(x, N, en, @(posedge clk))
$rose(x)  $fell(x)  $stable(x)  $changed(x)
$sampled(x)
$onehot(v)  $onehot0(v)  $isunknown(v)  $countones(v)  $countbits(v, 1)
```

All concurrent assertions sample in the **Preponed** region — they see the
values *before* any change at that clock edge, which is why they match
"what a flop would capture" and never race with the RTL.

---

## 19. Coverage

*Simulation only — none of this section is synthesizable.*

```systemverilog
covergroup cg_txn @(posedge clk);
  option.per_instance = 1;
  option.at_least     = 5;

  cp_kind : coverpoint kind {
    bins low     = {[0:3]};
    bins mid[]   = {[4:7]};            // one bin per value
    bins hi      = {[8:$]};
    bins walk    = (0 => 1 => 2);      // transition bin
    ignore_bins  rsvd = {15};
    illegal_bins bad  = {14};
    wildcard bins w   = {4'b1??0};
  }
  cp_len : coverpoint len iff (valid);

  x_kl : cross cp_kind, cp_len {
    ignore_bins none = binsof(cp_kind) intersect {0};
  }
endgroup

cg_txn cg = new();
cg.sample();          // for an event-less covergroup
$get_coverage();  cg.get_inst_coverage();
```

Also: `covergroup ... with function sample(bit[3:0] k)` for explicit sampling
from a class — the idiomatic form in a UVM-style subscriber.

---

## 20. System tasks and functions

```systemverilog
// Display                                                                    [V]
$display $write $strobe $monitor  (+ b/o/h/d suffixes)
   %b %o %d %h %c %s %t %e %f %g %v(strength) %m(hier path) %p(pretty) %0d
$sformatf("x=%0d", x)   $sformat(s, ...)   $swrite(s, ...)
$error $warning $info $fatal(code, ...)     // severity tasks
// Simulation control                                                         [V]
$finish $stop $exit  $time $stime $realtime  $timeformat  $random $urandom
$urandom_range(hi, lo)  $srandom(seed)  $dist_uniform/normal/exponential
// File I/O                                                                   [V]
$fopen $fclose $fdisplay $fwrite $fgets $fscanf $sscanf $feof $fflush $rewind
$readmemh("init.hex", mem)   $readmemb   $writememh   $writememb
// Elaboration-time / query                                                [S]
$bits(x)          // bit width of a type or expression
$clog2(n)         // ceil(log2(n)) -- address width from depth
$size(a, d) $left $right $low $high $increment $dimensions $unpacked_dimensions
$typename(x)
$isunknown(v) $onehot(v) $onehot0(v) $countones(v)
// Math                                                                       [V]
$ceil $floor $sqrt $pow $exp $ln $log10 $sin $cos $atan2 $hypot ...
$itor $rtoi $bitstoreal $realtobits $bitstoshortreal $shortrealtobits
// Assertion control                                                          [V]
$assertoff $asserton $assertkill $assertcontrol
// Coverage                                                                   [V]
$coverage_get $get_coverage $set_coverage_db_name
// PLA / timing                                                            
$setup $hold $recovery $removal $width $skew $period  (in `specify` blocks)
```

`$clog2(1) == 0` — guard it when computing an address width for a depth-1 FIFO.

---

## 21. DPI and program blocks

*Simulation only — none of this section is synthesizable.*

```systemverilog
import "DPI-C" function int c_model(input int a, output int b);
import "DPI-C" context task c_task();          // may call back into SV
export "DPI-C" function sv_callback;
// chandle holds an opaque C pointer across calls

program automatic test (axis_if.dst bus);      // runs in the Reactive region
  initial begin ... end
endprogram
```

Program blocks exist to avoid races between testbench and RTL; modern
class-based testbenches use clocking blocks instead and rarely need `program`.

---

## 22. Compiler directives

```systemverilog
`define W 8
`define MAX(a,b) (((a)>(b))?(a):(b))       // always parenthesize macro args
`undef W
`ifdef SYNTHESIS ... `elsif FOO ... `else ... `endif
`ifndef GUARD_SV
`define GUARD_SV
...
`endif
`include "defs.svh"
`timescale 1ns/1ps                 // file-scoped, order-dependent -- prefer:
timeunit 1ns; timeprecision 1ps;   //   scoped to the module
`default_nettype none              // put at top of EVERY file
`default_nettype wire              //   restore at the bottom
`line `resetall `celldefine `endcelldefine `unconnected_drive `pragma
`__FILE__ `__LINE__
```

Macro gotcha: `` `define ``'d text has no scope and no type. Use `localparam`
and `typedef` in a package for anything that is a value or a type; reserve
macros for conditional compilation and for code that must generate *syntax*.

---

## 23. Scheduling semantics

Within one time slot, the simulator iterates these regions:

```
  Preponed    <- concurrent assertions sample here (values before any change)
  Active      <- blocking assignments, continuous assignments, $display,
                 RHS evaluation of non-blocking assignments
  Inactive    <- #0 delays
  NBA         <- non-blocking assignment updates (LHS written here)
  Observed    <- property expressions evaluated
  Reactive    <- program blocks, clocking block drives
  Re-Inactive / Re-NBA
  Postponed   <- $strobe, $monitor (final settled values)
```

Loops back to Active whenever an event is scheduled there.

**What this buys you:** `always_ff @(posedge clk) q <= d;` reads `d` in Active
and writes `q` in NBA, so a chain of flops all sampling the same edge each see
their input's *old* value — exactly like real hardware. Using `=` instead makes
the result depend on the order the simulator happened to pick.

---

## 24. Arithmetic quick reference

Full treatment: [docs/17 — signed & unsigned](docs/17-signed-unsigned-arithmetic.md),
[docs/18 — fixed point](docs/18-fixed-point-arithmetic.md),
[docs/19 — floating point](docs/19-floating-point-hardware.md).

### Expression width (the two-pass rule)

1. **Pass 1 (bottom-up):** compute the *self-determined* width of every operand.
2. **Pass 2 (top-down):** the expression width is `max(operands, LHS)`; every
   **context-determined** operand is extended to that width *before* the
   operation is performed.

| Expression | Width |
|---|---|
| `a op b` for `+ - * / % & | ^ ~^` | `max(W(a), W(b))`, context-determined |
| `+a`, `-a`, `~a` | `W(a)`, context-determined |
| `a << b`, `a >> b` | `W(a)`; **`b` is self-determined** |
| `a ** b` | `W(a)`; `b` self-determined |
| `a && b`, `a == b`, `a < b`, `!a`, `&a` | **1 bit**; operands self-determined but sized against each other |
| `c ? a : b` | `max(W(a), W(b))`, context-determined |
| `{a, b}` | `W(a)+W(b)`; **self-determined, always unsigned** |
| `{N{a}}` | `N*W(a)`; self-determined, unsigned |

### Signedness

An expression is signed **only if every** context-determined operand is signed.
One unsigned operand makes the whole operation unsigned.

| Construct | Signedness |
|---|---|
| `bit`, `logic`, `wire`, packed arrays/structs | **unsigned** |
| `byte`, `shortint`, `int`, `longint`, `integer` | **signed** |
| unsized decimal literal (`10`) | signed |
| based literal without `s` (`8'd10`) | **unsigned** |
| based literal with `s` (`8'sd10`) | signed |
| any concatenation / replication | **unsigned, always** |
| any part-select or bit-select, even of a signed vector | **unsigned** |
| comparison / reduction / logical result | unsigned (1 bit) |

### The five traps

```systemverilog
logic signed [7:0] a = -8, b;
logic [7:0] u = 8;

b = a + u;              // 1. u is unsigned -> the ADD is unsigned. a becomes 248.
b = a + $signed(u);     //    fix

logic [8:0] sum;
sum = a[7:0] + b[7:0];  // 2. part-selects are unsigned, no sign extension

logic signed [3:0] c = -1;
logic signed [7:0] d;
d = {c};                // 3. concat is unsigned -> d = 8'h0F, not 8'hFF
d = c;                  //    plain assignment DOES sign-extend -> 8'hFF

logic signed [7:0] x = -128;
logic signed [7:0] y;
y = -x;                 // 4. -(-128) overflows back to -128 in 8 bits

logic [7:0] p, q;
logic [15:0] prod;
prod = p * q;           // 5. RHS is 8 bits wide (max of operands), THEN
                        //    zero-extended. Upper 8 bits are lost.
prod = 16'(p) * q;      //    fix: widen an operand first
```

### Width-safe idioms

```systemverilog
sum   = {1'b0, a} + {1'b0, b};                 // unsigned add with carry out
sum   = signed'({a[W-1], a}) + signed'({b[W-1], b});   // signed add, no overflow
prod  = signed'(a) * signed'(b);               // both operands signed -> signed mul
wide  = W2'(narrow);                           // explicit resize
avg   = (a + b) >> 1;                          // unsigned
avg   = $signed(a + b) >>> 1;                  // signed (rounds toward -inf)
```

---

## 25. Pipelining and timing idioms

Full treatment: [docs/21 — pipelining](docs/21-pipelining.md),
[docs/22 — timing closure and optimization](docs/22-timing-closure-and-optimization.md).

### The three parts of a pipeline

```systemverilog
// 1. DATA -- one register per stage.
always_ff @(posedge clk) if (en) s2 <= f(s1);

// 2. VALID -- the data's shadow. Reset it; flush clears it.
always_ff @(posedge clk or negedge rst_n) begin
  if      (!rst_n) valid_q <= '0;
  else if (flush)  valid_q <= '0;                          // flush BEFORE en
  else if (en)     valid_q <= {valid_q[N-2:0], valid_i};
end

// 3. SIDEBAND -- delayed by the SAME parameter, never a literal.
pipe_delay #(.WIDTH($bits(tag_t)), .LATENCY(LAT)) u_tag (
  .clk, .rst_n, .en, .din(tag_in), .dout(tag_out));
```

### Rules

| Rule | Why |
|---|---|
| One `LATENCY` parameter, used everywhere | the moment it appears twice, one copy drifts |
| **Reset the control path, not the data path** | saves area and reset routing, **and unblocks retiming** |
| One global `en`, never per-stage enables | per-stage stalls duplicate or drop beats |
| `flush` tested before `en` | else stale beats reappear when the stall lifts |
| Gate an accumulated result on `busy` | in-flight beats are not in the total yet |
| Expose latency as a `localparam` the consumer reads | not as a comment |

### Retiming: write registers where they are obvious, let the tool move them

```systemverilog
// Bunch them at the output. Retiming pulls them back into the array.
always_ff @(posedge clk) begin                 // NO reset -> retimable
  stage[0] <= a * b;
  for (int i = 1; i < PIPE; i++) stage[i] <= stage[i-1];
end
```

Blocked by: a reset, an initial value, per-stage enables, `dont_touch`, or
anything reading an intermediate stage (including an assertion).

### A loop cannot be pipelined

`acc <= acc + din` has a one-cycle feedback path. Three ways out:

```systemverilog
// (a) INTERLEAVE -- LANES partial sums, so each lane has LANES cycles.
acc_interleaved #(.LANES(4), .PIPE(4)) u (...);   // needs LANES >= PIPE

// (b) CARRY-SAVE -- keep the value as S + C; two gate levels, any width.
assign sum = a ^ b ^ c;                           // 3:2 compressor
assign cry = (a & b) | (b & c) | (a & c);

// (c) UNROLL -- adder tree feeds one accumulate, K items per cycle.
```

### Structural fixes, cheapest first

```systemverilog
// Tree, not chain: O(log N) instead of O(N).
assign y = (a + b) + (c + d);            // not ((a+b)+c)+d

// Move the mux to the NARROW side of the expensive operator.
assign y = a + (sel ? b : c);            // not sel ? (a+b) : (a+c)

// Late-arriving signal: compute both, select at the end.
assign y = late ? f_alt : f_base;        // not decode(late ? x : y)

// Priority chain -> the adder's carry chain does it in one expression.
assign grant = req & (~req + 1'b1);      // isolate the lowest set bit

// One-hot state: consumers read a bit instead of decoding.
assign bus_req = state[1] | state[3];

// Align the address map to powers of two: a decoder becomes a bit compare.
assign in_range = (addr[31:28] == 4'h4);
```

### Fanout

```systemverilog
// Few logic levels but large cell delays => fanout, not depth.
set_max_fanout 32 [current_design]       // let the tool do it first

// By hand, when it must be tied to a floorplan. dont_touch is REQUIRED --
// identical flops are exactly what resource sharing merges back.
(* dont_touch = "true" *) (* preserve *) logic [W-1:0] rep_q;
```

### Elastic vs fixed latency

| | Fixed + global stall | Valid/ready + skid buffer |
|---|---|---|
| Area | lower | 2 flops/stage/bit |
| Composability | poor (one stall fans out everywhere) | good (purely local) |
| Variable-latency stages | no | yes |

```systemverilog
// Register BOTH directions without losing throughput. Also the right element
// for breaking a long wire, because the handshake survives.
skid_buffer #(.DW(DW)) u (.clk, .rst_n,
  .in_valid, .in_data, .in_ready, .out_valid, .out_data, .out_ready);

// The AXI-Stream rule that makes handshakes composable:
a_stable: assert property (@(posedge clk) disable iff (!rst_n)
  (valid && !ready) |=> (valid && $stable(data)));
```

### Power

```systemverilog
assign gclk = clk & en;  always_ff @(posedge gclk) ...   // NEVER: glitchy
always_ff @(posedge clk) if (en) q <= d;                 // clock ENABLE; the
                                                         // tool inserts an ICG
```

### Diagnose before optimizing

| Report says | Cause | Fix |
|---|---|---|
| Many logic levels (>15) | depth | pipeline, restructure |
| Few levels, big cell delays | fanout | replicate |
| Few levels, big net delays | distance / congestion | floorplan, pipeline the wire |
| Endpoint is an accumulator | feedback loop | interleave, carry-save |
| Got worse after pipelining | a reset is blocking retiming | drop the datapath reset |

### The trip-wire assertion

```systemverilog
// In a 4-state simulator this finds latency-matching bugs on the first run:
// a sideband signal off by one cycle shows up as X exactly when valid claims
// the data is real. XSIM is 4-state so this works; useless on a 2-state
// engine -- see docs/02.
a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
  valid_o |-> !$isunknown(data_o));
```

---

## 26. Structural technique idioms

Full treatment: [docs/23](docs/23-structural-design-techniques.md),
[docs/24](docs/24-dft-clocking-and-x-discipline.md).

### Replace the operator with a structure

```systemverilog
y = x * 10;                  // -> (x<<3) + (x<<1)          one adder
y = x * 7;                   // -> (x<<3) - x               CSD: one subtract
q = n / 10;                  // -> (n * M) >> S             one multiply
                             //    L=ceil(log2 D), S=W+L, M=ceil(2^S/D)
                             //    prod needs S+W bits, NOT W+MW
q = n / 8;  r = n % 8;       // -> n >> 3 ;  n & 3'b111     free
bcd = f(bin);                // -> double dabble: per bit, add 3 to any
                             //    digit >= 5, then shift
sorted = sort(a);            // -> compare-exchange network, fixed depth
```

### Compute it at elaboration, not at run time

```systemverilog
// The derivation IS the source. Change a parameter, the table follows.
function automatic logic [DW-1:0] recip(input int unsigned i);
  recip = (i == 0) ? '1 : DW'(((64'd1 << FRAC) + (64'(i) >> 1)) / 64'(i));
endfunction

for (genvar i = 0; i < (1 << AW); i++) begin : g_init
  localparam logic [DW-1:0] E = recip(i);   // folded; no divider in hardware
  assign rom[i] = E;
end
```

### Counters

| Need | Use | Cost |
|---|---|---|
| the value | binary | `log2 N` flops + carry chain + decode at every use |
| ≤16 states, no value | **ring (one-hot)** | `N` flops, **zero decode** |
| half that | Johnson | `N/2` flops, 2-input decode |
| CDC pointer | **Gray** | one bit changes per step |
| N states, order irrelevant | **LFSR** | no carry chain; period `2^W - 1` |

```systemverilog
// Self-correcting ring: recovers from ANY illegal state within N cycles.
assign inject = SELF_CORRECT ? (~|q[N-2:0]) : q[N-1];
always_ff @(posedge clk or negedge rst_n)
  if      (!rst_n) q <= {{(N-1){1'b0}}, 1'b1};
  else if (en)     q <= {q[N-2:0], inject};
```

### FPGA shift registers (SRL): 1 LUT per 16–32 stages

```systemverilog
always_ff @(posedge clk)                  // NO reset, NO taps, ONE enable
  if (en) sr <= {sr[DEPTH-2:0], din};
assign dout = sr[DEPTH-1];                // only the last stage is read
```

Break any of those three and you get flip-flops instead — 16–32× the area.

### Microcode past ~15 states

```systemverilog
typedef struct packed {
  logic bus_req, wr_en, done, branch;   // control outputs ARE the ROM word
  logic [2:0]     csel;
  logic [PCW-1:0] targ;
} uword_t;
// A WAIT is "branch to myself while the condition is NOT yet true" --
// hence the inverted condition selects. Branching on the true sense makes
// every wait state fall through, and every data check still passes.
```

### DFT and clocking: the hard rules

```systemverilog
assign gclk = clk & en;                     // NEVER -- glitchy, unscannable
always_ff @(posedge div_q) ...              // NEVER -- RTL-generated clock
always_ff @(posedge clk) if (en) q <= d;    // ALWAYS -- the tool inserts an ICG
```

- every clock and reset controllable **from a pin** in test mode
- no latches, no combinational loops, no internal tri-state
- FSMs need a recovering `default`; ring counters need self-correction
- memories need a **functional** write path, not just `initial $readmemh`

### X-optimism vs X-pessimism

| | Effect | Consequence |
|---|---|---|
| **X-optimism** (`casex`, `bit` in RTL, 2-state sim) | bug hidden | **ships** |
| **X-pessimism** (gate-level sim) | false failure | wastes time |

```systemverilog
// The trip-wire, at every module boundary:
a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
  valid |-> !$isunknown(data));
```

---

## 27. Formal verification with sby

Full treatment: [docs/25](docs/25-formal-verification-with-sby.md).

### Modes

| Mode | Pass means |
|---|---|
| `bmc` | no counterexample within `depth` cycles of reset. **Exhaustive for combinational logic** |
| `prove` | holds for **all time** (k-induction) |
| `cover` | the state is reachable — guards against vacuous asserts |

### Yosys's frontend rejects all of SVA's temporal layer

```systemverilog
// SVA (XSIM)                        Yosys-compatible
a |-> b                           // assert (!a || b);
a |=> b                           // assert (!$past(a) || b);
a |=> $stable(x)                  // assert (!$past(a) || (x == $past(x)));
@(posedge clk) disable iff (!rst) // always @(posedge clk) if (rst) begin ... end
```

Also rejected: `return` in a function, a local var with an initialiser in a
function, `foreach`, `string` parameters, unpacked array **ports**,
`$bits(type)`, named assignment patterns `'{a:1}`.

> **A hierarchical reference into a submodule silently reads the wrong net.**
> It does not error. Properties needing internal state must live *inside* the
> module, under `` `ifdef FORMAL ``.

### The harness pattern

```systemverilog
logic init = 1'b1;                       // a defined starting point
always @(posedge clk) init <= 1'b0;
always @* if (init) assume (!rst_n);     // after cycle 0, rst_n is free

logic past_ok = 1'b0;                    // $past is junk in cycle 0
always @(posedge clk) past_ok <= 1'b1;
```

Harness inputs are **undriven** — the solver drives them. Anything you drive is
something you are not verifying.

### assume vs assert

```systemverilog
// The FIFO does not PREVENT overflow, it only reports `full`. Writing while
// full is the environment's contract violation -> assume, not assert.
always @* if (full) assume (!wr_en);
```

### bmc passes, prove fails

That means **no bug — the invariant set is too weak**. Induction starts from an
*arbitrary* state; anything unpinned, the solver invents. Add invariants that
describe the reachable state space:

```systemverilog
f_occupancy: assert ((in_seq - out_seq) == (DW'(out_valid) + DW'(skid_valid)));
f_no_orphan: assert (!skid_valid || out_valid);
f_skid_val : assert (!skid_valid || (skid_data == out_seq + 1'b1));
```

And when the property genuinely is not an invariant (a self-correcting counter),
split it: **preservation** (inductive, in the module) + **base case** (BMC from
reset, in the harness).

### Sequence numbering proves data integrity in one assertion

```systemverilog
always @* assume (in_data == in_seq);          // payload IS the sequence number
f_stream : assert (!out_valid || (out_data == out_seq));
//  a gap => loss;  a repeat => duplication;  out of order => reordering
```

Sound only because the datapath is **data-independent** — the control never
inspects the payload.

---

## 28. FSM idioms

Full treatment in [docs/26](docs/26-fsm-coding-styles.md).

### The state type

```systemverilog
typedef enum logic [2:0] { S_IDLE, S_REQ, S_XFER, S_DONE } state_e;
//               ^^^^^^^^ size it. Bare `enum {...}` defaults to 32-bit int.
state_e state, next;
$error("stuck in %s", state.name());     // sim-only, free
```

### The four styles

```systemverilog
// TWO-PROCESS: readable; outputs are combinational and glitch
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n) state <= S_IDLE; else state <= next;

always_comb begin
  next = state;                  // DEFAULT: hold -- prevents the latch
  unique case (state)
    S_IDLE: if (start) next = S_REQ;
    default:           next = S_IDLE;    // not optional
  endcase
end

// ONE-PROCESS: outputs registered, but you clear them on every exit path
always_ff @(posedge clk) begin
  done <= 1'b0;                  // default each cycle => a one-cycle pulse
  unique case (state)
    S_XFER: if (last) begin state <= S_DONE; bus_req <= 1'b0; done <= 1'b1; end
  endcase
end

// THREE-PROCESS: the default choice. Registered AND aligned.
always_ff @(posedge clk) bus_req <= (next == S_REQ);   // decode NEXT
//                                   ^^^^ decoding `state` here is a cycle late

// ONE-HOT: next-state depth is constant in the number of states
next[I_REQ] = (state[I_IDLE] & start) | (state[I_REQ] & ~grant);
```

| | two-proc | one-proc | three-proc | one-hot |
|---|---|---|---|---|
| Glitch-free outputs | no | yes | yes | — |
| Output bookkeeping | automatic | **manual** | automatic | automatic |
| Extra latency | none | none | none | none |
| Use for | small, internal | pulse-heavy | **default** | wide / FPGA |

### Registering outputs costs no latency

```systemverilog
bus_req <= (state == S_REQ);   // ONE CYCLE LATE
bus_req <= (next  == S_REQ);   // ALIGNED -- state <= next on the same edge
```

### Illegal states

```systemverilog
default: next = S_IDLE;                        // every case on a state
if (SAFE && !$onehot(state)) next = S_IDLE;    // one-hot: must OVERWRITE, not OR
(* fsm_safe_state = "reset_state" *)           // Vivado; ignored elsewhere
(* fsm_encoding   = "one_hot" *)               // only if the tool infers the FSM
```

All-zeros is **absorbing** in a hand-written one-hot machine: no transition term
is true, so it stays there until reset.

### `unique` is an assertion, not a directive

```systemverilog
unique case (state) ... default: ... endcase   // use BOTH
```

`unique` without a `default` diverges: simulation reports a violation and holds
the old value; synthesis was told the case is impossible and builds anything.
Never `full_case` / `parallel_case`. Never `casex` on a state (an X matches the
first branch and the FSM sails on).

### Control / datapath split

```systemverilog
assign last = (cnt <= CW'(1));   // from cnt, NOT cnt_d -- keeps the
S_XFER: if (ack) begin           // comparator off the next-state path
          cnt_d = cnt - 1'b1;
          if (last) next = S_DONE;
        end
```

A 256-beat transfer is 4 states and a counter, not 259 states.

### Properties worth writing every time

```systemverilog
a_legal  : assert property (state inside {S_IDLE, S_REQ, S_XFER, S_DONE});
a_pulse  : assert property (done |=> !done);
a_aligned: assert property (bus_req == (state == S_REQ));
c_run    : cover  property ((state == S_IDLE) ##1 (state == S_REQ) [*1:$]
                            ##1 (state == S_DONE));   // the one people skip
```

An assertion that never fires because its state is unreachable reports green.
`cover` every state you believe in.

### Fault injection

```systemverilog
$assertoff(0, u_dut);            // you are deliberately breaking its contract
force u_dut.state = 4'b0000;
@(negedge clk); release u_dut.state;
@(negedge clk); chk("recovered", !err);
$asserton(0, u_dut);
```

`force` holds the register against its own `always_ff`, so the injected value is
still the sampled value at the *next* edge too.
