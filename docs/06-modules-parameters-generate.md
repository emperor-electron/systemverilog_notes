# Modules, Parameters, and Generate

## 1. Module declaration

```systemverilog
`default_nettype none

module fifo #(
  parameter int  DW    = 32,
  parameter int  DEPTH = 16,
  parameter type T     = logic [DW-1:0],     // type parameter
  localparam int AW    = $clog2(DEPTH)       // derived, NOT overridable
) (
  input  var  logic          clk,
  input  var  logic          rst_n,
  input  var  logic          wr_en,
  input  var  T              wr_data,
  output var  logic          full,
  input  var  logic          rd_en,
  output var  T              rd_data,
  output var  logic          empty,
  output var  logic [AW:0]   level
);
  ...
endmodule

`default_nettype wire
```

Notes on this header:

- **ANSI style** (types and directions in the port list) — the non-ANSI style
  (`module m(a,b); input a; output b;`) still works but is only worth knowing
  for reading old code.
- `parameter` in the header is overridable; `localparam` is derived. Putting the
  derived value in the header lets it appear in port widths.
- `var` on a port makes it explicitly a variable rather than a net. It is
  optional (an `input` defaults to a net, an `output` can be either) but it
  makes `` `default_nettype none `` behave predictably and documents intent.
- A `type` parameter lets one module serve both `logic [31:0]` and a packed
  struct.

### Port direction defaults

| Declaration | Default kind |
|---|---|
| `input x` | net (`wire`) |
| `inout x` | net |
| `output x` | net, unless assigned procedurally → then declare `output logic x` |

Always write the type: `output logic [7:0] q`.

## 2. Instantiation

```systemverilog
fifo #(.DW(64), .DEPTH(8))  u_fifo (
  .clk      (clk),
  .rst_n    (rst_n),
  .wr_en    (push),
  .wr_data  (din),
  .full     (fifo_full),
  .rd_en    (pop),
  .rd_data  (dout),
  .empty    (fifo_empty),
  .level    ()                 // explicitly unconnected
);
```

| Style | Form | Verdict |
|---|---|---|
| Positional | `fifo u(clk, rst_n, ...)` | never — one inserted port breaks everything silently |
| Named | `.clk(clk)` | **default choice** |
| Implicit named | `.clk` (shorthand for `.clk(clk)`) | good when names match by convention |
| Wildcard | `.*` | terse; hides what is connected. Acceptable for a deep, stable hierarchy with strict naming, dangerous otherwise |

`.*` connects every port whose name matches a signal in scope, and it is a
**compile error** if a port has no matching signal — so it is safer than it
looks. What it costs you is grep-ability: you can no longer find every driver of
a signal by searching for its name.

An unconnected `input` is a compile warning (it floats to `Z`/`X`); an
unconnected `output` is fine.

## 3. Parameters

```systemverilog
parameter  int    W      = 8;            // overridable
localparam int    BYTES  = W / 8;        // derived
parameter  type   data_t = logic [7:0];  // type parameter
parameter  real   FREQ   = 100.0e6;      // real parameter (elaboration only)
parameter  string NAME   = "core0";
parameter  logic [7:0] INIT [0:3] = '{1,2,3,4};   // array parameter
specparam  tRISE = 1.2;                  // timing only, inside `specify`
```

Override mechanisms:

```systemverilog
fifo #(.DW(64)) u (...);                 // by name -- do this
fifo #(64, 8)   u (...);                 // positional -- fragile
defparam u.DW = 64;                      // DEPRECATED, do not use
```

`defparam` was removed from the recommended subset because it can appear
anywhere in the design and modify any parameter, making elaboration
order-dependent and parameters un-analyzable.

### Parameter validation

Catch bad parameterizations at elaboration rather than in simulation:

```systemverilog
if (DEPTH < 2)
  $error("DEPTH must be >= 2, got %0d", DEPTH);
if (DEPTH != (1 << $clog2(DEPTH)))
  $fatal(1, "DEPTH must be a power of two, got %0d", DEPTH);
```

A bare `if` at module scope is an **elaboration-time generate-if**, so this runs
during elaboration and the error stops the build.

## 4. Generate

`generate` constructs are evaluated at **elaboration**, before any simulation
or synthesis. They create or remove hierarchy, instances, and declarations.

### generate-for

```systemverilog
genvar i;
for (i = 0; i < NUM_LANES; i++) begin : g_lane
  lane #(.ID(i)) u_lane (
    .clk  (clk),
    .din  (din [i]),
    .dout (dout[i])
  );
end
```

The label `g_lane` is **required** in practice: it becomes the array of
hierarchical scopes, so the instances are `top.g_lane[0].u_lane`,
`top.g_lane[1].u_lane`, ... Without a label the tool invents a name and your
constraints, assertions, and waveform scripts break on the next tool version.

You can declare signals inside a generate block; they become per-iteration:

```systemverilog
for (genvar i = 0; i < N; i++) begin : g_stage
  logic [W-1:0] partial;                       // one per iteration
  assign partial = (i == 0) ? din : g_stage[i-1].partial + 1;
end
assign dout = g_stage[N-1].partial;            // hierarchical reference
```

Cross-iteration hierarchical references like `g_stage[i-1].partial` are legal
and are the standard way to build a chain (systolic array, carry chain,
pipeline) without an explicit array of wires. Many people find the explicit
array clearer:

```systemverilog
logic [W-1:0] chain [0:N];
assign chain[0] = din;
for (genvar i = 0; i < N; i++) begin : g_stage
  stage u (.in(chain[i]), .out(chain[i+1]));
end
assign dout = chain[N];
```

### generate-if

```systemverilog
if (IMPL == "FAST") begin : g_fast
  fast_mult u_mult (.*);
end else if (IMPL == "SMALL") begin : g_small
  serial_mult u_mult (.*);
end else begin : g_dsp
  dsp_mult u_mult (.*);
end
```

Because the branches are *elaborated away*, the unselected hardware does not
exist — this is the right way to parameterize between implementations, unlike
a runtime mux which builds both.

Note the instance is named `u_mult` inside each branch, but the full path
differs (`g_fast.u_mult` vs `g_small.u_mult`). If you need a stable path, use
the same label in every branch:

```systemverilog
if (FAST) begin : g_mult  fast_mult u (.*); end
else      begin : g_mult  slow_mult u (.*); end
// path is always  g_mult.u
```

### generate-case

```systemverilog
case (DW)
  8:       byte_unit  u_impl (.*);
  16, 32:  word_unit  u_impl (.*);
  default: begin : g_err
    $error("unsupported DW=%0d", DW);
  end
endcase
```

### `genvar` vs `int`

A `genvar` exists only at elaboration. It is not a simulation object and cannot
be read at runtime. Modern SystemVerilog lets you declare it inline:

```systemverilog
for (genvar i = 0; i < N; i++) begin : g_x  ...  end
```

which scopes it to the loop and avoids a file-level `genvar` shared by many
loops.

## 5. Hierarchical references

```systemverilog
top.u_core.u_regfile.mem[5]        // absolute
u_sub.signal                       // relative, downward
$root.top.clk                      // explicit root
```

Hierarchical references are legal for **reading** from a testbench (and for
`force`/`release`), and illegal in synthesizable code. They are how you probe
internal state without adding ports:

```systemverilog
// Testbench: watch an internal FSM without modifying the DUT
always @(posedge clk)
  if (dut.u_ctrl.state == dut.u_ctrl.ERROR)
    $error("controller entered ERROR at %t", $time);
```

The cleaner alternative is `bind`, which attaches a checker module into the DUT
hierarchy without editing it and without absolute paths:

```systemverilog
bind fifo fifo_checker #(.DEPTH(DEPTH)) u_chk (
  .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .rd_en(rd_en),
  .full(full), .empty(empty), .level(level)
);
```

`bind` targets a **module type** (every instance of `fifo` gets a checker) or a
specific instance (`bind top.u_fifo ...`). It is the standard way to add
assertions to third-party or legacy RTL.

## 6. Elaboration-time computation

Constant functions run in the elaborator and let you express derived parameters
readably:

```systemverilog
function automatic int clog2_min1(input int n);
  return (n <= 1) ? 1 : $clog2(n);
endfunction

function automatic int unsigned crc_table_entry(input int unsigned idx);
  int unsigned c = idx;
  for (int b = 0; b < 8; b++)
    c = (c & 1) ? (32'hEDB8_8320 ^ (c >> 1)) : (c >> 1);
  return c;
endfunction

localparam int AW = clog2_min1(DEPTH);
localparam int unsigned CRC_TAB [0:255] = '{ ... };   // or built by a generate
```

Restrictions on a constant function: `automatic`, no time controls, no
hierarchical references, no `$display` side effects you depend on, and every
argument must itself be constant at the call site.

Real-valued parameters are allowed and useful for coefficient tables — the
`real` math happens at elaboration and only the quantized integers reach
synthesis. See [docs/18](18-fixed-point-arithmetic.md#7-a-complete-parameterized-package).
