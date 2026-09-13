# Procedural Blocks, Assignments, and Control Flow

## 1. The block types

| Block | Purpose | Time-consuming | Synthesizable |
|---|---|---|---|
| `always_comb` | combinational logic | no | **yes** |
| `always_latch` | intentional level-sensitive latch | no | yes |
| `always_ff @(posedge clk)` | flip-flops | no (one edge) | **yes** |
| `always @(...)` | legacy general-purpose | depends | depends |
| `initial` | run once at time 0 | yes | memory init only |
| `final` | run once at the end of simulation | no | no |

### `always_comb` vs `always @*`

```systemverilog
always_comb  y = a & b;
always @*    y = a & b;
```

| | `always @*` | `always_comb` |
|---|---|---|
| Executes once at time 0 | no | **yes** |
| Sensitive to variables read inside called **functions** | no | **yes** |
| Other processes may also write the LHS | yes | **no** — compile error |
| Tool checks for inferred latches | no | **yes** |
| `ref` arguments allowed | — | no |

The "executes at time 0" difference is real: with `always @*`, if none of the
inputs change at time 0, the output stays `X` forever even though the inputs are
valid. `always_comb` always evaluates once.

The "sensitive through functions" difference matters as soon as you factor logic
into a function — `always @*` will not re-run when a signal that the function
reads changes.

**Use `always_comb`.** There is no case where `always @*` is better.

### `always_ff`

```systemverilog
always_ff @(posedge clk) begin
  q <= d;
end
```

`always_ff` is a **promise** to the tool that the block describes flip-flops.
The tool will error if:

- the sensitivity list is not purely edges,
- a variable assigned in the block is also assigned elsewhere,
- the block contains anything that cannot map to a flop.

That error is the point. A plain `always @(posedge clk)` that accidentally
infers a latch or a combinational loop compiles silently.

### `initial` in RTL

```systemverilog
// Acceptable, portable across FPGA tools:
logic [31:0] mem [0:1023];
initial $readmemh("boot.hex", mem);

// Acceptable on FPGA (bitstream sets the value), IGNORED on ASIC:
logic [7:0] counter = 8'h00;
```

On an ASIC, a flop's power-on value is whatever the silicon settles to. Write a
reset. On an FPGA, initializers and `initial` memory loads are honoured because
the configuration bitstream carries them.

## 2. Blocking vs non-blocking

```systemverilog
x = y;      // blocking:     evaluate RHS and update LHS immediately,
            //               before the next statement runs
q <= d;     // non-blocking: evaluate RHS now, schedule the LHS update for the
            //               NBA region at the end of this time step
```

### Why the blocking/non-blocking rule exists

Consider a two-stage shift register:

```systemverilog
always_ff @(posedge clk) begin
  b <= a;
  c <= b;
end
```

Both RHS values are sampled in the **Active** region, before either LHS is
written in the **NBA** region. So `c` gets the *old* `b`, which is exactly what
two real flip-flops do: each captures its input's value as it was just before
the clock edge.

Now with blocking assignments:

```systemverilog
always_ff @(posedge clk) begin
  b = a;
  c = b;      // reads the NEW b
end
```

`c` gets the new `b`, collapsing two flops into one. Worse, if the two
statements were in *separate* `always` blocks, the result would depend on which
block the simulator happened to schedule first — a **race**. The LRM does not
define that order, so two simulators can legitimately give different answers,
and synthesis gives a third.

Non-blocking assignment removes the race by construction: every RHS in every
`always_ff` in the design is evaluated before any LHS is updated, so scheduling
order cannot matter.

Combinational logic has the mirror-image requirement. Inside `always_comb` you
often want intermediate results:

```systemverilog
always_comb begin
  sum   = a + b;
  carry = sum[8];        // must see the NEW sum -> blocking
  y     = carry ? '1 : sum[7:0];
end
```

Here blocking is correct because the statements describe a *dataflow order*
within one lump of combinational logic, not a set of parallel registers.

### The rules

1. **`always_ff` → `<=` only.**
2. **`always_comb` → `=` only.**
3. **Never mix `=` and `<=` for the same variable.**
4. **Never assign one variable from two `always` blocks.** (`always_comb` and
   `always_ff` both enforce this; plain `always` does not.)
5. **Never read a variable in one block that another block assigns with `=`**
   in the same time step.

Violating these does not always break — it breaks *intermittently*, under a
different simulator, a different seed, or after an unrelated edit.

### `<=` is also the less-than-or-equal operator

```systemverilog
if (a <= b)  q <= c;     // first <= is a comparison, second is an assignment
```

The parser distinguishes by position. It reads badly but is unambiguous.

## 3. The two-process (and one-process) FSM styles

### Two-process: registered state, combinational next-state

```systemverilog
typedef enum logic [1:0] { IDLE, REQ, WAIT, DONE } state_e;
state_e state, next;

always_ff @(posedge clk or negedge rst_n)
  if (!rst_n) state <= IDLE;
  else        state <= next;

always_comb begin
  next = state;               // DEFAULT: hold. Prevents latches.
  unique case (state)
    IDLE: if (start)   next = REQ;
    REQ:  if (grant)   next = WAIT;
    WAIT: if (done)    next = DONE;
    DONE:              next = IDLE;
    default:           next = IDLE;
  endcase
end

// Outputs: Moore (a function of state only) -> glitch-free, registered-clean
always_comb begin
  req = 1'b0;  ack = 1'b0;
  unique case (state)
    REQ:  req = 1'b1;
    DONE: ack = 1'b1;
    default: ;
  endcase
end
```

The `next = state;` default assignment before the `case` is the whole trick for
latch avoidance: every path through the block now assigns `next`.

### One-process: everything registered

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= IDLE;
    req   <= 1'b0;
    ack   <= 1'b0;
  end else begin
    req <= 1'b0;              // default each cycle
    ack <= 1'b0;
    unique case (state)
      IDLE: if (start) begin state <= REQ;  req <= 1'b1; end
      REQ:  if (grant)       state <= WAIT;
      WAIT: if (done)  begin state <= DONE; ack <= 1'b1; end
      DONE:                  state <= IDLE;
      default:               state <= IDLE;
    endcase
  end
end
```

| | Two-process | One-process |
|---|---|---|
| Output timing | same cycle as the state (Moore) or combinational from inputs (Mealy) | one cycle **later** |
| Output glitches | possible (combinational) | none (registered) |
| Timing closure | next-state logic + output logic in one path | shorter paths |
| Readability | state transitions and outputs are separated | transitions and their outputs are together |

For anything driving a chip boundary or a long wire, **register the outputs**
(one-process, or a two-process FSM with a separate output register). For a small
internal FSM, two-process reads better.

Both examples above show the `default:` branch. It is not optional: a state
register can enter an unreachable encoding through an SEU or an `X`, and without
a default the synthesized logic is unconstrained.

## 4. `case` variants

```systemverilog
case (expr)  ... endcase       // exact match, X/Z must match literally
casez (expr) ... endcase       // Z and ? in EITHER operand are wildcards
casex (expr) ... endcase       // X and Z in either operand are wildcards
case (expr) inside ... endcase // wildcard + set membership in the items
```

**`casex` is a bug generator.** If the case *expression* contains an `X` — say
because a signal was not reset — `casex` will match it against a real branch and
take it, hiding the problem. `casez` only wildcards `Z` and `?`, and `Z` rarely
appears by accident inside a chip.

```systemverilog
// Priority decoder, idiomatic
always_comb begin
  unique casez (req)
    4'b???1: grant = 4'b0001;
    4'b??10: grant = 4'b0010;
    4'b?100: grant = 4'b0100;
    4'b1000: grant = 4'b1000;
    default: grant = 4'b0000;
  endcase
end

// Range-based decode
always_comb begin
  case (addr) inside
    [16'h0000 : 16'h0FFF]: sel = SEL_ROM;
    [16'h1000 : 16'h1FFF]: sel = SEL_RAM;
    16'hFFFF:              sel = SEL_CTRL;
    default:               sel = SEL_NONE;
  endcase
end
```

## 5. `unique`, `unique0`, `priority`

| Qualifier | You promise | Simulator checks | Synthesis assumes |
|---|---|---|---|
| `unique` | exactly one item matches | errors if 0 or >1 match | parallel mux, no priority |
| `unique0` | at most one matches | errors if >1 match | parallel mux |
| `priority` | at least one matches | errors if none match | priority mux |
| (none) | nothing | nothing | priority mux, latch if incomplete |

These are **assertions with a synthesis side effect**. The danger: if your
promise is wrong, simulation reports a violation (which people often filter out)
while synthesis silently builds hardware that assumes the promise held. That is
a sim/synth mismatch by construction.

Guidance:

- Prefer a plain `case` with a `default` branch. It is unambiguous and costs
  nothing — the tool builds a priority mux and optimizes it away if the items
  are actually mutually exclusive.
- Use `unique case` when you can genuinely prove one-hot (a decoded select, an
  FSM state) and you want the runtime check.
- Avoid `priority` — write the `default` instead.
- **Never** use the old `(* full_case, parallel_case *)` attributes. They tell
  synthesis to assume something the simulator does not, with no runtime check at
  all. `unique`/`priority` replaced them precisely because they are checked.

`unique case (1'b1)` is the idiomatic one-hot mux:

```systemverilog
always_comb begin
  y = '0;
  unique case (1'b1)
    sel_a: y = a;
    sel_b: y = b;
    sel_c: y = c;
    default: y = '0;
  endcase
end
```

## 6. Loops

```systemverilog
for (int i = 0; i < N; i++)   ...    // N must be constant for synthesis
foreach (arr[i])              ...    // bounds from the declaration
repeat (N)                    ...    // N constant for synthesis
while (cond)                  ...    // must be statically bounded
do ... while (cond);
forever                       ...    // [V] -- needs a time control inside
break;  continue;  return;
```

Synthesizable loops are **unrolled at elaboration**. The loop bound must be a
constant, and the body becomes N copies of the hardware:

```systemverilog
// A 32-bit priority encoder, written as a loop. Unrolls to a mux tree.
always_comb begin
  idx   = '0;
  found = 1'b0;
  for (int i = 0; i < 32; i++)
    if (!found && req[i]) begin
      idx   = 5'(i);
      found = 1'b1;
    end
end
```

Note the `!found` guard: without it the *last* set bit wins, because later loop
iterations overwrite earlier ones. With it, the first wins. Either is fine —
just be deliberate, because the loop's sequential appearance hides a priority
structure.

### Named blocks and `disable`

```systemverilog
outer: for (int i = 0; i < N; i++) begin
  inner: for (int j = 0; j < M; j++) begin
    if (done) disable outer;       // break out of both  [V]
  end
end
```

`break` only exits the innermost loop. `disable <label>` exits a named block —
which in a testbench also works as a way to kill a task from outside.

## 7. Avoiding inferred latches

A latch is inferred when a variable assigned in `always_comb` is **not
assigned on every path**. The three fixes, in order of preference:

```systemverilog
// 1. Default assignment at the top (best -- scales to many outputs)
always_comb begin
  y = '0;
  z = 1'b1;
  if (a) y = b;
end

// 2. Complete if/else
always_comb begin
  if (a) y = b;
  else   y = '0;
end

// 3. Complete case with a default
always_comb begin
  case (s)
    2'b00:   y = a;
    2'b01:   y = b;
    default: y = '0;
  endcase
end
```

Option 1 also covers the case where you later add an output to the block and
forget to cover it in one branch.

`always_comb` makes the tool *warn*. Turn that warning into an error in your
lint setup — an unintended latch is never what you wanted, and it breaks static
timing analysis in ways that are painful to debug later.

An **intentional** latch uses `always_latch`, which documents the intent and
suppresses the warning:

```systemverilog
always_latch
  if (en) q <= d;      // note: <= is conventional in always_latch
```

## 8. Reset style

### Synchronous reset

```systemverilog
always_ff @(posedge clk) begin
  if (!rst_n) q <= '0;
  else        q <= d;
end
```

- Smaller flops (no async pin), cleaner static timing, filters reset glitches.
- Requires a running clock to reset. A gated or stopped clock leaves the design
  in an unknown state.
- The reset net is a normal timed path and must meet setup like any other
  signal — which means it needs the same buffering care as a high-fanout signal.

### Asynchronous reset, synchronous release

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) q <= '0;
  else        q <= d;
end
```

- Works with no clock. Essential for power-up.
- The **release** must be synchronized to the clock, or flops near the end of
  the reset tree can come out of reset one cycle after flops near the start,
  producing an inconsistent initial state. That is what a reset synchronizer is
  for — see [`examples/rtl/reset_sync.sv`](../examples/rtl/reset_sync.sv).

Rules for the async form:

1. The sensitivity list contains **only** the clock edge and the reset edge.
2. The reset condition is the **first** `if`, with nothing before it.
3. The reset assigns **constants** only.
4. Every flop in a clock domain uses the **same** reset polarity and style.

Violating (1)–(3) means the tool cannot map it to the flop's async pin and will
either error out or build a mess of combinational logic in the reset path.

```systemverilog
// WRONG: the tool cannot infer an async reset from this
always_ff @(posedge clk or negedge rst_n) begin
  if (en)          q <= d;     // something before the reset test
  else if (!rst_n) q <= '0;
end

// WRONG: reset asserts a non-constant
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) q <= init_value; // must be a constant
  else        q <= d;
end
```
