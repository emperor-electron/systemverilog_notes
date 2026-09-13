# Tasks and Functions

## 1. The distinction

| | `function` | `task` |
|---|---|---|
| May consume simulation time | **no** (no `#`, `@`, `wait`, `fork...join`) | **yes** |
| Returns a value | yes (or `void`) | no |
| Called from | an expression, or as a statement if `void` | a statement only |
| Callable from a `function` | yes | no |
| Callable from a `task` | yes | yes |
| Synthesizable | **yes** | rarely (only if it consumes no time) |

```systemverilog
function automatic logic [7:0] saturate(input logic signed [15:0] x);
  if      (x >  127) return  8'sd127;
  else if (x < -128) return -8'sd128;
  else               return 8'(x);
endfunction

task automatic wait_ack(input int timeout);
  fork
    begin @(posedge ack); end
    begin repeat (timeout) @(posedge clk); $error("ack timeout"); end
  join_any
  disable fork;
endtask
```

## 2. `automatic` vs `static` — write `automatic`

Lifetime determines where a subroutine's local variables live.

| | `static` (the default at module scope) | `automatic` |
|---|---|---|
| Storage | one copy, shared by all calls | a fresh copy per call, on the stack |
| Recursion | **broken** | works |
| Concurrent calls | **corrupt each other** | independent |
| Locals retain values between calls | yes | no |

```systemverilog
// BROKEN: two concurrent calls share `i` and `sum`
function int sum_array(int a[]);
  int i, sum;                       // static storage!
  sum = 0;
  for (i = 0; i < a.size(); i++) sum += a[i];
  return sum;
endfunction

// CORRECT
function automatic int sum_array(int a[]);
  int sum = 0;
  foreach (a[i]) sum += a[i];
  return sum;
endfunction
```

The failure mode is brutal: the function works perfectly until two processes
call it in the same time step, then returns garbage nondeterministically.

Rules:

- Subroutines declared inside a **module/interface/program** default to
  `static`.
- Subroutines declared inside a **class** default to `automatic`.
- A `static` subroutine may still declare `automatic` locals, and vice versa.
- `module m; timeunit ...; ` — you can set the module default with
  `module automatic m;`, but it is clearer to mark each subroutine.

**Write `automatic` on every task and function.** The only reason to use
`static` is to deliberately retain state between calls, which is better done
with an explicit module-scope variable.

## 3. Arguments

```systemverilog
function automatic void f(
  input  int  a,          // default direction is `input`
  input  int  b = 5,      // default value -> the argument is optional
  output int  c,
  inout  int  d,
  ref    int  e,          // by reference: requires `automatic`
  const ref int arr[]     // by reference, read-only -- avoids a copy
);
```

| Direction | Semantics |
|---|---|
| `input` | copied in at call time |
| `output` | copied out at return |
| `inout` | copied in and out |
| `ref` | the actual object is passed; changes are visible **immediately** |
| `const ref` | as `ref`, but the subroutine cannot write it |

`const ref` is how you pass a large array without copying it:

```systemverilog
function automatic int checksum(const ref byte data[]);   // no copy
  int s = 0;
  foreach (data[i]) s += data[i];
  return s;
endfunction
```

Without `const ref`, passing a 64 KB dynamic array `input` copies 64 KB on every
call.

`ref` arguments are illegal in `always_comb` (the block cannot know what the
subroutine reads) and in `static` subroutines.

### Argument binding styles

```systemverilog
f(1, 2, x, y);                    // positional
f(.a(1), .c(x), .b(2), .d(y));    // named -- order-independent
f(.a(1), .b(), .c(x), .d(y));     // .b() takes the default value
```

## 4. Return

```systemverilog
function automatic int f();
  return 42;              // preferred
endfunction

function automatic int g();
  g = 42;                 // legacy: assign to the function name
  return;                 // ...then a bare return
endfunction

function automatic void h();
  if (bad) return;        // early exit
  ...
endfunction

void'(f());               // call a value-returning function as a statement
```

Ignoring a return value without `void'()` is a warning in most tools and an
error under strict lint. Use it explicitly to document "I know this returns
something and I do not need it" — most often with `$cast`:

```systemverilog
void'($cast(derived, base));       // I already proved this is safe
```

## 5. Synthesizable functions

A function synthesizes into combinational logic if it:

- is `automatic` (or has no state that matters),
- contains no time controls,
- contains only statically bounded loops,
- makes no hierarchical references,
- has no `ref` arguments (tool-dependent),
- does not call a task.

```systemverilog
// Gray <-> binary, synthesizable, reusable
function automatic logic [W-1:0] bin2gray #(int W) (input logic [W-1:0] b);
  return b ^ (b >> 1);
endfunction

function automatic logic [W-1:0] gray2bin #(int W) (input logic [W-1:0] g);
  logic [W-1:0] b;
  b[W-1] = g[W-1];
  for (int i = W-2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
  return b;
endfunction

// One-hot priority arbiter
function automatic logic [W-1:0] first_one #(int W) (input logic [W-1:0] r);
  return r & (~r + 1'b1);      // isolate the lowest set bit
endfunction

// Leading-zero count, unrolled at elaboration
function automatic int lzc #(int W) (input logic [W-1:0] v);
  for (int i = W-1; i >= 0; i--)
    if (v[i]) return W-1-i;
  return W;
endfunction
```

Note that a function called from `always_comb` contributes its reads to the
block's sensitivity list automatically — one of the concrete reasons to prefer
`always_comb` over `always @*`.

### Functions with static local state

```systemverilog
// A function CAN hold state, but the state is shared by every call site.
// In RTL this synthesizes to... nothing sensible. Do not do it.
function int counter();
  static int n = 0;     // one instance for the whole design
  return n++;
endfunction
```

Useful in a testbench for unique IDs; never in RTL.

## 6. Parameterized subroutines

```systemverilog
// Parameterized function (a "let"-like construct)
function automatic logic [W-1:0] rotl #(parameter int W = 8)
    (input logic [W-1:0] v, input int n);
  return (v << n) | (v >> (W - n));
endfunction

logic [15:0] r = rotl #(16) (data, 3);
```

Support for parameterized functions varies. The portable alternatives:

```systemverilog
// (a) Put the function in a parameterized package -- not possible directly,
//     so use a parameterized CLASS as a namespace (testbench only):
class fx #(parameter int W = 8);
  static function logic [W-1:0] rotl(input logic [W-1:0] v, int n);
    return (v << n) | (v >> (W - n));
  endfunction
endclass
logic [15:0] r = fx#(16)::rotl(data, 3);

// (b) Size the function for the widest case and let the caller truncate:
function automatic logic [63:0] rotl64(input logic [63:0] v, int n, int w);
  logic [63:0] m = (64'd1 << w) - 1;
  return (((v << n) | (v >> (w - n))) & m);
endfunction

// (c) Simplest and most portable in RTL: a parameterized MODULE.
module rotl #(parameter int W = 8) (input logic [W-1:0] i, input int n,
                                    output logic [W-1:0] o);
  assign o = (i << n) | (i >> (W - n));
endmodule
```

## 7. `let`

`let` defines a parameterized, inlined expression — a type-safe macro:

```systemverilog
let is_pow2(x)   = (x != 0) && ((x & (x - 1)) == 0);
let max(a, b)    = (a > b) ? a : b;
let valid_hs     = tvalid && tready;

if (is_pow2(DEPTH)) ...
assert property (@(posedge clk) valid_hs |-> !$isunknown(tdata));
```

Unlike a `` `define ``, a `let` is scoped, parses as an expression, and its
arguments are evaluated in the caller's context at the point of use — which
means `valid_hs` above samples `tvalid`/`tready` wherever it is written,
including inside an assertion's sampled-value context. That makes `let`
genuinely better than a macro for assertion helpers.

## 8. Recursion

```systemverilog
function automatic int fact(input int n);
  return (n <= 1) ? 1 : n * fact(n - 1);
endfunction

// Elaboration-time use: fine, the recursion happens in the elaborator
localparam int F5 = fact(5);      // 120
```

Recursion requires `automatic` and is simulation/elaboration only — a recursive
function with a runtime-variable depth cannot synthesize. Recursive **module**
instantiation, however, is a genuinely useful synthesis technique:

```systemverilog
// Recursive adder tree
module adder_tree #(parameter int N = 8, parameter int W = 16) (
  input  logic [W-1:0]            din [0:N-1],
  output logic [W+$clog2(N)-1:0]  dout
);
  if (N == 1) begin : g_leaf
    assign dout = din[0];
  end else begin : g_node
    localparam int NL = N / 2, NR = N - NL;
    logic [W+$clog2(NL>1?NL:2)-1:0] l;
    logic [W+$clog2(NR>1?NR:2)-1:0] r;
    adder_tree #(.N(NL), .W(W)) u_l (.din(din[0    : NL-1]),  .dout(l));
    adder_tree #(.N(NR), .W(W)) u_r (.din(din[NL   : N-1]),   .dout(r));
    assign dout = l + r;
  end
endmodule
```

The generate-if terminates the recursion at elaboration, so the hardware is a
finite tree.
