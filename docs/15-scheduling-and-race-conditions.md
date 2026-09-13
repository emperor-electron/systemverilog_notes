# The Scheduling Model and Race Conditions

Everything about why `<=` exists, why clocking blocks exist, and why two
simulators can disagree, comes from this model. IEEE 1800 §4.

## 1. The time slot

Simulation advances through **time slots**. Within one time slot the simulator
iterates over ordered **regions** until no more events are pending:

```
 ┌──────────────────────────────────────────────────────────────┐
 │  Preponed    ── concurrent assertions SAMPLE here            │
 ├──────────────────────────────────────────────────────────────┤
 │  Active      ── blocking assignments (=)                     │
 │                 continuous assignments                       │
 │                 $display, $write                             │
 │                 RHS evaluation of non-blocking assignments   │
 │                 primitive evaluation                         │
 │  Inactive    ── #0 delayed events                            │
 │  NBA         ── non-blocking assignment LHS UPDATES          │
 ├──────────────────────────────────────────────────────────────┤
 │  Observed    ── property expressions evaluated               │
 ├──────────────────────────────────────────────────────────────┤
 │  Reactive    ── program blocks, clocking block OUTPUT drives │
 │  Re-Inactive ── #0 inside program blocks                     │
 │  Re-NBA      ── NBA updates from program blocks              │
 ├──────────────────────────────────────────────────────────────┤
 │  Postponed   ── $strobe, $monitor  (read-only, final values) │
 └──────────────────────────────────────────────────────────────┘
        ↑                                              │
        └──── loop back to Active whenever an ─────────┘
              event is scheduled there
```

The loop-back is important: an Active-region event scheduled while processing
NBA sends the simulator back to Active. That is how a chain of combinational
logic settles within one time slot.

## 2. Why `<=` makes flops work

```systemverilog
always_ff @(posedge clk) b <= a;
always_ff @(posedge clk) c <= b;
```

At the clock edge:

1. Both processes wake in **Active**.
2. Both evaluate their RHS: process 1 reads `a`, process 2 reads the **old** `b`.
3. Both schedule NBA updates.
4. In **NBA**, `b` and `c` are written.

Because every RHS is read before any LHS is written, the *order in which the
simulator woke the two processes cannot matter*. That is the definition of
race-free, and it matches what two physical flip-flops do.

With blocking assignments the same code is order-dependent:

```systemverilog
always_ff @(posedge clk) b = a;    // if this runs first...
always_ff @(posedge clk) c = b;    // ...c gets the NEW b -> one flop, not two
```

The LRM explicitly leaves the order of Active-region events **undefined**. Two
compliant simulators may legitimately produce different answers, and neither is
wrong.

## 3. The classic races

### Race 1: reading a DUT output at the clock edge

```systemverilog
// TESTBENCH
always @(posedge clk)
  $display("data = %h", dut_data);   // old or new? undefined.
```

`dut_data` is updated in NBA by the DUT; the `$display` runs in Active. It sees
the **old** value — usually. But if the DUT drove it with `=` in some other
block, ordering decides.

**Fix:** a clocking block, which samples in Preponed (guaranteed pre-edge) and
drives in Reactive (guaranteed post-edge).

```systemverilog
clocking cb @(posedge clk);
  default input #1step output #0;
  input  dut_data;
  output stim;
endclocking

@(cb);
$display("data = %h", cb.dut_data);   // unambiguous: the pre-edge value
cb.stim <= v;                          // driven in Re-NBA, after the DUT settles
```

### Race 2: driving a DUT input at the clock edge

```systemverilog
always @(posedge clk) din <= stimulus;   // TB drives
always_ff @(posedge clk) q <= din;       // DUT samples
```

Both are NBA, so `q` gets the **old** `din` — which is what you want. But write
the TB drive with `=` and the DUT may see the new value, a cycle early, for one
signal and not another.

**Fix:** clocking block output, or a deliberate small delay (`#1 din = v;`) —
the clocking block is better because it is uniform and self-documenting.

### Race 3: `->e` vs `@(e)`

```systemverilog
initial begin @(e); $display("caught"); end     // may never print
initial begin ->e;  end
```

If the trigger fires before the waiter reaches `@(e)`, the trigger is lost.

**Fix:** `wait (e.triggered);` — true for the entire time step in which the
event fired.

### Race 4: two `always` blocks writing one variable

```systemverilog
always_ff @(posedge clk)  q <= a;
always_ff @(posedge rst)  q <= '0;     // undefined which wins
```

**Fix:** one variable, one driver. `always_ff` makes this a compile error; plain
`always` does not.

### Race 5: `initial` ordering at time 0

```systemverilog
initial clk = 0;
initial forever #5 clk = ~clk;
initial @(posedge clk) ...;       // does the first edge happen at t=5 or t=0?
```

All three run at time 0 in an undefined order. If the second runs first, `clk`
starts as `X` and `~X` is `X`.

**Fix:** initialize in the declaration and use a single clock process:

```systemverilog
logic clk = 1'b0;
always #5 clk = ~clk;
```

### Race 6: `#0` as a fix

```systemverilog
initial begin #0; ... end     // "run after everyone else at time 0"
```

`#0` schedules into the **Inactive** region, which does put it after the current
Active events — but if two processes both use `#0`, their relative order is
again undefined, and the whole design now depends on a convention nobody wrote
down. `#0` is a symptom, not a fix. Use a clocking block, an event, or an
explicit initialization ordering.

## 4. `program` blocks **[V]**

```systemverilog
program automatic test (axis_if.dst bus);
  initial begin
    ...
  end
endprogram
```

A `program` block's code runs in the **Reactive** region, after all design
activity in the time slot has settled. That was the original solution to
TB/DUT races: the design is in Active/NBA, the testbench is in Reactive, so they
cannot interleave.

Program blocks also:

- end the simulation implicitly when all their `initial` blocks finish,
- disallow `always` blocks,
- default to `automatic` lifetime.

Modern class-based testbenches usually use clocking blocks instead and skip
`program` entirely — clocking blocks give the same guarantee at signal
granularity, and `program` interacts awkwardly with class-based code that wants
`always`-style monitors.

## 5. `#1step`

```systemverilog
clocking cb @(posedge clk);
  default input #1step;
endclocking
```

`1step` is "one **precision** unit before the clock edge" — i.e. sample in the
Preponed region of the time slot containing the edge. It is not a real delay
you can use elsewhere; it is only legal as a clocking-block input skew, and it
means exactly "what a flip-flop would have captured".

## 6. Determinism rules to follow

1. **`always_ff` → `<=`. `always_comb` → `=`.** Never mix.
2. **One driver per variable.**
3. **Testbench touches the DUT only through a clocking block.**
4. **`wait (e.triggered)`, not `@(e)`**, unless you control both sides.
5. **No `#0`.**
6. **Initialize in the declaration** (`logic clk = 0;`), not in a separate
   `initial`.
7. **`automatic` on every task and function.**
8. **Types in packages**, not in `$unit`.
9. **Run the regression on two simulators** if you can. Race conditions that a
   tool happens to schedule favourably show up immediately on the other one.

## 7. Delta cycles and `$display` ordering

There is no `$display` ordering guarantee between processes in the same region.
If you need ordered output:

- use `$strobe` (Postponed — after everything settles), or
- timestamp every message (`$display("%t [%m] ...", $time)`), or
- funnel messages through a single reporting object.

The third is what UVM's report server does, and it is why a real testbench's
log is readable while a hand-rolled one's is not.
