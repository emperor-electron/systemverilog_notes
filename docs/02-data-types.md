# Data Types

## The 4-state / 2-state split

| | 4-state (`0 1 X Z`) | 2-state (`0 1`) |
|---|---|---|
| Types | `logic`, `reg`, `integer`, `time`, all nets | `bit`, `byte`, `shortint`, `int`, `longint` |
| Initial value | `X` | `0` |
| Memory per bit | 2 bits | 1 bit |
| Simulation speed | slower | faster |

The `X` value is not "unknown" in a philosophical sense — it is a **modelling
device** that propagates uncertainty. Its whole value in RTL is that a signal
which was never reset stays `X`, and that `X` flows downstream until it shows up
in a `$display` or an assertion and tells you about the bug.

If you declare your RTL with `bit`, every uninitialized flop reads as `0`, your
reset bug simulates perfectly, and it fails in silicon. **Use `logic` for RTL.**
Use 2-state types in testbench scoreboards, loop indices, and reference models
where the extra speed is real and `X` would only be noise.

`Z` means "not driven". It matters only for nets with multiple drivers and for
tri-state I/O pads.

## Integral types

| Type | Width | Signedness | States | Typical use |
|---|---|---|---|---|
| `bit` | 1, vectorizable | unsigned | 2 | TB, models, counters |
| `logic` | 1, vectorizable | unsigned | 4 | **all RTL** |
| `reg` | 1, vectorizable | unsigned | 4 | legacy alias for `logic` |
| `byte` | 8 | **signed** | 2 | TB data, DPI |
| `shortint` | 16 | **signed** | 2 | TB |
| `int` | 32 | **signed** | 2 | loop counters, TB |
| `longint` | 64 | **signed** | 2 | TB, large counters |
| `integer` | 32 | **signed** | 4 | legacy |
| `time` | 64 | unsigned | 4 | `$time` results |

```systemverilog
logic        [31:0] data;      // unsigned 32-bit, 4-state
logic signed [31:0] sdata;     // signed
int unsigned        u;         // unsigned 32-bit, 2-state
bit          [63:0] wide;
```

### `logic` is not "always a flop"

`logic` is a **variable**, meaning "something that holds a value between
assignments". Whether it becomes a wire, a latch, or a flip-flop is determined
entirely by *how you assign it*:

```systemverilog
logic a, b, c;
assign a = x & y;                          // a is combinational wiring
always_comb b = x & y;                     // b is combinational wiring
always_ff @(posedge clk) c <= x & y;       // c is a flip-flop
```

The old `wire`/`reg` distinction described the *syntax you were allowed to use*,
not the hardware. `logic` removes that restriction: it can be driven by one
continuous assignment **or** by procedural code, and it can be a module output.

## Nets vs variables

| | Variable (`logic`, `int`, ...) | Net (`wire`, `tri`, ...) |
|---|---|---|
| Semantics | last write wins | **resolved** across all drivers |
| Drivers | exactly one source | any number |
| Needs a driver | no (holds its value) | yes (undriven → `Z`) |
| Can be assigned procedurally | yes | no |

Net types and their resolution:

| Type | Resolution |
|---|---|
| `wire` / `tri` | `0`+`1` → `X`; `Z` loses to everything |
| `wand` / `triand` | wired-AND |
| `wor` / `trior` | wired-OR |
| `tri0` / `tri1` | pulls to 0 / 1 when undriven |
| `trireg` | holds the last driven value (capacitive) |
| `supply0` / `supply1` | constant 0 / 1, strongest |
| `uwire` | **unresolved** — a compile error if driven twice. Useful as a lint. |

You need a net for exactly three things: a bidirectional pad, a bus with
multiple drivers, and interfacing with gate-level models. Everything else is a
variable.

```systemverilog
// Tri-state I/O pad -- the one place `inout` and `Z` are correct
module pad (inout wire io, input logic oe, input logic dout, output logic din);
  assign io  = oe ? dout : 1'bz;
  assign din = io;
endmodule
```

## Non-integral types

```systemverilog
real      r;        // binary64.  Simulation only.
shortreal f;        // binary32.  Simulation only.
realtime  t;        // alias for real
string    s;        // dynamic-length, built-in methods
chandle   h;        // opaque C pointer from DPI; only == and != against null
event     e;        // synchronization; ->e to trigger, @e to wait
void                // function return type, or a cast to discard a value
```

`real` is 2-state, never `X`, and defaults to `0.0`. See
[docs/19](19-floating-point-hardware.md) for the hardware story.

## User-defined types

```systemverilog
typedef logic [7:0]            byte_t;
typedef byte_t                 page_t [0:255];      // unpacked array type
typedef logic signed [17:0]    coef_t;
typedef struct packed { ... }  hdr_t;
typedef enum logic [2:0] {...} state_e;
typedef union packed { ... }   word_u;
typedef hdr_t                  hdr_q_t [$];         // queue type
typedef class Driver;                               // forward declaration
typedef virtual axis_if        vif_t;
```

Naming convention that most codebases converge on:

| Suffix | Meaning |
|---|---|
| `_t` | a type (`addr_t`, `byte_t`) |
| `_e` | an enum type (`state_e`, `opcode_e`) |
| `_s` | a struct type (some houses use `_t` for these too) |
| `_q` / `_d` | registered value / its next-state combinational input |
| `_n` | active-low (`rst_n`) |

Put every shared `typedef` in a **package**, never in an included header at
`$unit` scope. `$unit` is the anonymous compilation-unit scope and what lands in
it depends on how the files were grouped on the command line — that is a
reproducibility problem waiting to happen.

## Casting

### Static casts — checked at elaboration

```systemverilog
int'(x)              // to a named type
byte_t'(x)
8'(x)                // size cast: truncate, or zero/sign-extend per x's signedness
signed'(x)           // signedness cast, same bits
unsigned'(x)
hdr_t'(bits)         // reinterpret a bit pattern as a packed struct
                     //   (widths must match exactly)
```

```systemverilog
logic [7:0] a = 8'hFF;
16'(a)                    // 16'h00FF (a is unsigned -> zero-extend)
16'(signed'(a))           // 16'hFFFF
int'(3.7)                 // 4   (rounds, ties away from zero)
$rtoi(3.7)                // 3   (truncates)
```

Size casts on **real** values round; size casts on integral values
truncate/extend. That asymmetry is worth remembering.

### Dynamic casts — checked at run time **[V]**

```systemverilog
if (!$cast(derived_h, base_h))  $error("wrong type");
$cast(my_enum, some_int);       // fails if the int is not a valid enum value
void'($cast(x, y));             // discard the result (you asserted it is safe)
```

`$cast` is the only way to safely downcast a class handle, and the only way to
range-check an integer into an enum. Use the function form (which returns 0/1)
rather than the task form (which errors out) whenever failure is a legal
outcome.

## Default values and initialization

| Type | Default |
|---|---|
| 4-state integral | all `X` |
| 2-state integral | all `0` |
| `real` | `0.0` |
| `string` | `""` |
| `event`, `chandle`, class handle | `null` |
| net | `Z` (until driven) |
| `enum` | the value of its **first** member, if that is a legal encoding |

```systemverilog
logic [7:0] a;          // X
logic [7:0] b = '0;     // 0 at time 0 -- treated as an `initial` in simulation.
                        //   In synthesis, a variable initializer sets the
                        //   POWER-ON value of the flop (FPGA: from the bitstream;
                        //   ASIC: usually ignored -- use a reset).
```

Do not rely on declaration initializers for reset in an ASIC flow. They work on
FPGAs (where the configuration bitstream sets flop initial values) and are
silently ignored on ASIC (where a flop's power-on state is random). Write a
reset.
