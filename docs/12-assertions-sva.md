# Assertions (SVA)

## 1. Immediate vs concurrent

```systemverilog
// Immediate: a procedural statement, evaluated when reached
always_comb
  assert (onehot0(sel)) else $error("sel not one-hot: %b", sel);

// Concurrent: a temporal property, evaluated on a clock
assert property (@(posedge clk) disable iff (!rst_n)
                 req |=> ##[0:3] ack)
  else $error("no ack within 4 cycles");
```

| | Immediate | Concurrent |
|---|---|---|
| Where | inside a procedural block | module/interface/`program` scope, or procedural |
| When evaluated | when the statement executes | on the specified clock edge |
| Samples | current simulation values | **Preponed** values (pre-edge) |
| Can span time | no | yes |
| Formal-tool target | limited | **yes** |

### Deferred immediate assertions

```systemverilog
always_comb
  assert #0 (a != b) else $error("...");       // re-evaluated at the end of
                                               //   the time step
assert final (count == 0) else $error("...");  // evaluated once at end of sim
```

`assert #0` solves the glitch problem: a combinational block may evaluate
several times in one time step as its inputs settle, and a plain immediate
assertion fires on every intermediate state. The deferred form only reports if
the condition is still false when the time step ends.

## 2. Anatomy of a concurrent assertion

```systemverilog
property p_handshake;
  @(posedge clk)                  // clocking event
  disable iff (!rst_n)            // reset condition -- kills in-flight attempts
  req && !busy                    // antecedent
  |=>                             // implication operator
  ##[1:4] ack;                    // consequent
endproperty

a_handshake: assert property (p_handshake)
  else $error("req at %t got no ack", $time);
c_handshake: cover property (p_handshake);
```

Always **label** assertions (`a_handshake:`). The label appears in the failure
message, in coverage reports, and in `$assertoff` targeting.

### The three directives

| Directive | Simulation | Formal |
|---|---|---|
| `assert property` | fails if violated | proves or finds a counterexample |
| `assume property` | (usually ignored, or checked) | **constrains** the input space |
| `cover property` | counts matches | finds a trace that reaches it |
| `restrict property` | ignored | constrains, formal only |

`assume` on the inputs is how you tell a formal tool "the environment obeys the
protocol". Getting an `assume` wrong is worse than a missing assertion: it makes
the tool prove things about an environment that does not exist.

## 3. Implication

```systemverilog
a |-> b        // OVERLAPPED: if a matches, b must start in the SAME cycle
a |=> b        // NON-OVERLAPPED: b must start the NEXT cycle
               // (identical to  a |-> ##1 b)
```

An implication **vacuously passes** when the antecedent does not match. That is
why every meaningful `assert property` should be paired with a `cover property`
on the antecedent — otherwise a typo that makes the antecedent never true gives
you a perfectly passing assertion that checks nothing.

```systemverilog
a_rule:  assert property (@(posedge clk) req |=> ack);
c_rule:  cover  property (@(posedge clk) req);          // did we ever try?
```

## 4. Sequences

```systemverilog
sequence s_burst;
  start ##1 (data_valid [*4]) ##1 done;
endsequence
```

### Delay and repetition

| Syntax | Meaning |
|---|---|
| `##0` | same cycle |
| `##1` | next cycle |
| `##[2:5]` | 2 to 5 cycles later |
| `##[1:$]` | 1 or more cycles later (**liveness** — needs a fairness assumption in formal) |
| `a [*3]` | `a` true for 3 **consecutive** cycles |
| `a [*2:5]` | 2 to 5 consecutive |
| `a [*]` | `a [*0:$]` |
| `a [+]` | `a [*1:$]` |
| `a [->3]` | 3rd **non-consecutive** occurrence; the sequence ends **on** it |
| `a [=3]` | 3 non-consecutive occurrences; may be followed by non-`a` cycles |

```systemverilog
// "After a request, the third grant must be for the same ID"
req ##1 (gnt [->3]) |-> gnt_id == $past(req_id, 1);
```

### Composition

| Operator | Meaning |
|---|---|
| `s1 and s2` | both match, possibly ending at different times; ends at the later |
| `s1 or s2` | either matches |
| `s1 intersect s2` | both match **and end at the same cycle** |
| `s1 within s2` | s1 occurs entirely inside s2 |
| `e throughout s` | expression `e` holds on every cycle of `s` |
| `first_match(s)` | only the earliest match (prunes the others) |
| `s1.ended` | s1 ended in this cycle |
| `s.triggered` | for use in procedural code |

`first_match` matters for performance and for correctness when a sequence has a
variable-length range:

```systemverilog
// Without first_match this spawns a thread per possible length
assert property (req ##[1:10] ack |=> done);
assert property (first_match(req ##[1:10] ack) |=> done);   // usually intended
```

### `throughout` — the standard "stays stable during" idiom

```systemverilog
property p_burst_stable;
  @(posedge clk) disable iff (!rst_n)
    $rose(burst_start) |->
      ($stable(burst_addr) throughout (burst_active [*1:$] ##1 burst_end));
endproperty
```

## 5. Sampled value functions

All evaluated on the assertion's clock, using **Preponed** values:

```systemverilog
$past(x)                 // x one clock ago
$past(x, N)              // N clocks ago
$past(x, N, en)          // N enabled clocks ago (gated sampling)
$past(x, N, en, @(posedge clk2))
$rose(x)                 // x was 0 (or X/Z), now 1
$fell(x)                 // x was 1, now 0
$stable(x)               // x == $past(x)
$changed(x)              // !$stable(x)
$sampled(x)              // x's sampled value (explicit, in procedural code)
```

`$past` before the first N clock edges returns the initial value (`X` for
4-state), which causes spurious failures at time 0. Guard with the reset:

```systemverilog
// disable iff (!rst_n) handles it, or explicitly:
assert property (@(posedge clk) disable iff (!rst_n)
                 ($past(valid) && !$past(ready)) |-> $stable(data));
```

### Bit-vector helpers

```systemverilog
$onehot(v)       // exactly one bit set
$onehot0(v)      // at most one bit set
$isunknown(v)    // any bit is X or Z
$countones(v)
$countbits(v, 1) $countbits(v, 0, x, z)
```

## 6. Local variables in sequences

Local variables let you capture a value and check it later — the mechanism for
data-integrity checks:

```systemverilog
property p_data_returns;
  logic [31:0] expected;
  logic [3:0]  id;
  @(posedge clk) disable iff (!rst_n)
    (wr_valid, expected = wr_data, id = wr_id)
    |-> ##[1:100] (rd_valid && rd_id == id && rd_data == expected);
endproperty
```

`(expr, assignment)` performs the assignment when that point of the sequence
matches. Each match attempt gets its own copy of the local variables, so
overlapping transactions are tracked independently — that is what makes this
work for out-of-order protocols.

## 7. Clock and reset

```systemverilog
default clocking cb @(posedge clk); endclocking
default disable iff (!rst_n);

// now every property in this scope inherits both:
assert property (req |=> ack);
```

Declaring `default clocking` and `default disable iff` once per module removes
the boilerplate from every property and — more importantly — removes the chance
of one property accidentally using the wrong clock.

`disable iff` aborts any **in-flight** attempt the moment the condition becomes
true. Without it, an assertion started before reset will report a failure when
reset clears the signals it was tracking.

## 8. Assertions in procedural code

```systemverilog
always_ff @(posedge clk) begin
  if (state == BUSY)
    assert property (@(posedge clk) ##[1:10] done)
      else $error("stuck in BUSY");
end

// Blocking wait on a property
initial begin
  expect (@(posedge clk) ##[1:100] irq) else $error("no interrupt");
  $display("got irq");
end
```

`expect` is a **blocking** statement that waits for the property to complete —
useful in a directed test as a synchronization point with a built-in timeout.

## 9. Control

```systemverilog
$assertoff(0, tb.dut);          // disable assertions in a hierarchy
$asserton(0, tb.dut);
$assertkill(0, tb.dut);         // disable and kill in-flight attempts
$assertcontrol(action, type, dir, levels, scope);   // the general form
$assertpassoff / $assertpasson / $assertfailoff / ...
```

Common use: turn assertions off during a reset sequence or during a
deliberately-illegal error-injection window.

```systemverilog
initial begin
  $assertoff(0, tb.dut);
  apply_reset();
  $asserton(0, tb.dut);
end
```

## 10. A practical checker library

```systemverilog
// ---- Handshake protocols ----------------------------------------------
// VALID must not drop before READY
property p_valid_stable;
  @(posedge clk) disable iff (!rst_n)
    (valid && !ready) |=> valid;
endproperty

// Payload must be stable while waiting
property p_data_stable;
  @(posedge clk) disable iff (!rst_n)
    (valid && !ready) |=> $stable(data);
endproperty

// No X on the payload when it is claimed valid
property p_no_x;
  @(posedge clk) disable iff (!rst_n)
    valid |-> !$isunknown(data);
endproperty

// Bounded response
property p_ack_bounded;
  @(posedge clk) disable iff (!rst_n)
    $rose(req) |-> ##[1:MAX_LAT] ack;
endproperty

// ---- FIFO ------------------------------------------------------------
property p_no_overflow;  @(posedge clk) disable iff (!rst_n)  full  |-> !wr_en;
endproperty
property p_no_underflow; @(posedge clk) disable iff (!rst_n)  empty |-> !rd_en;
endproperty
property p_level_bounds; @(posedge clk) disable iff (!rst_n)  level <= DEPTH;
endproperty
property p_full_iff;     @(posedge clk) disable iff (!rst_n)
                           full == (level == DEPTH);
endproperty

// ---- FSM -------------------------------------------------------------
property p_state_legal;
  @(posedge clk) disable iff (!rst_n)
    state inside {IDLE, REQ, WAIT, DONE};
endproperty

property p_no_deadlock;
  @(posedge clk) disable iff (!rst_n)
    (state != IDLE) |-> ##[1:TIMEOUT] (state == IDLE);
endproperty

// ---- One-hot / mutual exclusion --------------------------------------
property p_onehot_grant;
  @(posedge clk) disable iff (!rst_n)  $onehot0(grant);
endproperty

property p_grant_implies_req;
  @(posedge clk) disable iff (!rst_n)  (grant & ~req) == '0;
endproperty

// ---- Counters --------------------------------------------------------
property p_count_inc;
  @(posedge clk) disable iff (!rst_n)
    (inc && !dec && !full) |=> (count == $past(count) + 1);
endproperty
```

## 11. Where to put assertions

| Location | Use |
|---|---|
| Inside the RTL module | invariants about that module's own state; ship them |
| Inside an `interface` | protocol rules — every instance gets them free |
| In a separate checker module + `bind` | checking third-party or legacy RTL you cannot edit |
| In the testbench | end-to-end / data-integrity checks |

The `bind` pattern:

```systemverilog
// fifo_checker.sv -- knows nothing about where it will be attached
module fifo_checker #(parameter int DEPTH = 16) (
  input logic clk, rst_n, wr_en, rd_en, full, empty,
  input logic [$clog2(DEPTH):0] level
);
  a_no_overflow:  assert property (@(posedge clk) disable iff (!rst_n)
                                   full |-> !wr_en);
  a_no_underflow: assert property (@(posedge clk) disable iff (!rst_n)
                                   empty |-> !rd_en);
endmodule

// tb.sv or a separate bind file
bind fifo fifo_checker #(.DEPTH(DEPTH)) u_chk (.*);
```

Binding to the **module type** `fifo` attaches a checker to every instance in
the design, including ones added later. Keep binds in a separate file that is
compiled only in simulation, so the RTL file list stays synthesis-clean.

## 12. Guidance

1. **Label every assertion.** The label is what appears in the log.
2. **Pair every `assert` with a `cover`** of its antecedent. Vacuous passes are
   the main way assertions lie to you.
3. **Use `default clocking` and `default disable iff`.** One place to get right.
4. **Write the message with data**: `$error("exp=%h got=%h", e, g)`, not
   `$error("mismatch")`.
5. **Do not assert what the RTL already enforces structurally.** An assertion
   that restates an `assign` is maintenance cost with no coverage value.
6. **Bounded over unbounded.** `##[1:100] ack` finds bugs; `##[1:$] ack` only
   fails at end-of-simulation and is unprovable in formal without fairness.
7. Keep assertions out of the synthesis file list, or guard them:
   `` `ifndef SYNTHESIS ... `endif ``.
