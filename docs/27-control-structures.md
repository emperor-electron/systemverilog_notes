# Control Structures

Every control structure in SystemVerilog means one of three quite different
things depending on where you write it:

| Where | What a control structure *is* | Exists at |
|---|---|---|
| Inside `always_comb` / `always_ff` | a description of **combinational logic** | run time, as gates |
| Directly in a module body | a **generate** construct | elaboration only |
| Inside `initial` / `task` / `class` | an **ordinary imperative statement** | simulation only |

The same `for` loop builds four copies of an adder in the first context,
instantiates four modules in the second, and runs four times in the third.
Reading RTL means knowing which context you are in before you read the keyword.

This document is about what each structure becomes, where it belongs, and what
it costs. [docs/05](05-procedural-blocks-and-flow.md) covers the *syntax* and
the latch rules; this one covers the trade-offs.

Companion code, all verified:
[`select_styles.sv`](../examples/rtl/select_styles.sv) — the same function
written four ways, with the difference between them proved rather than
described — simulated in [`rtl_smoke_tb.sv`](../examples/tb/rtl_smoke_tb.sv),
proved in [`formal/select_styles_fv.sby`](../formal/select_styles_fv.sby)

---

## Contents

- [1. `if` / `else if`: a priority chain](#1-if--else-if-a-priority-chain)
- [2. The `case` family](#2-the-case-family)
- [3. Priority or parallel: the choice that matters](#3-priority-or-parallel-the-choice-that-matters)
- [4. The conditional operator](#4-the-conditional-operator)
- [5. Loops are spatial, not temporal](#5-loops-are-spatial-not-temporal)
- [6. `break`, `continue`, `return`, `disable`](#6-break-continue-return-disable)
- [7. Generate constructs](#7-generate-constructs)
- [8. Control structures for verification only](#8-control-structures-for-verification-only)
- [9. Quick reference](#9-quick-reference)
- [10. Checklist](#10-checklist)

---

## 1. `if` / `else if`: a priority chain

An `if`/`else if` chain is a **priority structure**. Each `else if` is
downstream of every condition above it, so the last branch's data passes through
as many mux levels as there are branches.

```systemverilog
always_comb begin
  if      (req[0]) grant = d[0];     // 1 mux level
  else if (req[1]) grant = d[1];     // 2
  else if (req[2]) grant = d[2];     // 3
  else if (req[3]) grant = d[3];     // 4
  else             grant = '0;
end
```

**Where it appears:** anywhere the specification is a list of rules in
precedence order — interrupt priority, arbitration, error handling, "if the
cache hit, else if the fill buffer matched, else go to memory".

**Why it is coded this way:** it is the only structure that reads in the same
order the specification is written. When priority is the *point*, spelling it
out as a chain documents itself.

**Advantages**
- Priority is explicit and impossible to misread.
- Conditions may overlap freely, and may be unrelated expressions rather than
  values of one variable.
- The `else` makes completeness obvious.

**Disadvantages**
- Depth grows linearly with the number of branches. A 32-way chain is 32 mux
  levels and will not close timing at any useful frequency.
- An `if` with no `else` in combinational logic **infers a latch** — the
  variable must hold its value, so the tool builds something that can.

### The latch rule, and the two ways out

```systemverilog
// BAD: no else, so `y` must hold -> latch
always_comb begin
  if (en) y = a;
end

// Good: default first, then override
always_comb begin
  y = '0;
  if (en) y = a;
end

// Also good: complete the if
always_comb begin
  if (en) y = a;
  else    y = '0;
end
```

The default-first form is the one to use habitually, because it scales: with six
outputs and nine branches, "assign every output at the top" is a rule you can
check by looking at one place, and "every branch assigns every output" is not.

Neither `xvlog` nor `yosys` reports width mismatches, but yosys *does* catch
inferred latches, which is why `make lint` runs it over every module
([docs/20](20-synthesis-subset-and-gotchas.md)).

### Nesting and late-arriving signals

Depth comes from nesting as much as from length. If one condition arrives late,
move it to the *end* of the chain — the last mux is the shortest path from that
input to the output:

```systemverilog
// `late` arrives at 90% of the period
// BAD: late feeds the top of a 3-deep cone
if (late) y = a; else if (p) y = b; else y = c;

// Better: everything else resolves first; `late` selects at the last mux
logic t;
always_comb t = p ? b : c;
always_comb y = late ? a : t;
```

This is the general restructure in
[docs/22](22-timing-closure-and-optimization.md): compute both answers
speculatively and let the late signal choose between them.

---

## 2. The `case` family

```systemverilog
case (expr)    ... endcase   // exact match; X and Z must match literally
casez (expr)   ... endcase   // Z and ? are wildcards, in EITHER operand
casex (expr)   ... endcase   // X and Z are wildcards, in either operand
case (expr) inside ... endcase  // set membership and ranges
```

A plain `case` on a value compiles to a **balanced mux** — depth grows with
log₂ of the number of branches rather than linearly. That is the main reason to
prefer it over a chain when the branches are values of a single expression.

```systemverilog
always_comb begin
  y = '0;                            // default first
  case (op)
    OP_ADD: y = a + b;
    OP_SUB: y = a - b;
    OP_AND: y = a & b;
    default: ;
  endcase
end
```

**Where it appears:** instruction decode, FSM next-state logic, register-file
address decode, any mux with a named selector.

### `casez`

Wildcards let one branch cover a family of patterns, which is how a priority
encoder is written compactly:

```systemverilog
casez (req)
  4'b???1: grant = d[0];
  4'b??10: grant = d[1];
  4'b?100: grant = d[2];
  4'b1000: grant = d[3];
  default: grant = '0;
endcase
```

Note that this is *still a priority structure* — the branches overlap, and the
first match wins. `casez` does not make it parallel; it makes it shorter to
write. Writing the patterns so the priority is visible in the bit patterns is
the benefit.

**The `?` in a `casez` pattern is a don't-care in the pattern, not a
don't-care in the design.** If the case expression itself contains Z, that Z
matches anything — which is rarely what you want but is at least confined to Z.

### `casex` — do not use

`casex` treats **X in the case expression** as a wildcard. An unknown value
therefore matches the *first* branch and the design proceeds as though nothing
were wrong:

```systemverilog
casex (state)          // state is 4'bxxxx after a missed reset
  4'b0001: ...         // <-- matches. The FSM "works".
```

This is X-optimism in its purest form: the bug is hidden in simulation and is
real in silicon. See [docs/24](24-dft-clocking-and-x-discipline.md). Use
`casez`, or `case ... inside`, and never `casex`.

### `case ... inside`

```systemverilog
case (addr) inside
  [16'h0000:16'h0FFF]: sel = ROM;
  [16'h1000:16'h1FFF]: sel = RAM;
  16'hFF00, 16'hFF04:  sel = CSR;
  default:             sel = NONE;
endcase
```

`inside` gives ranges and set membership, is wildcard-free, and reads far better
than the comparison chain it replaces. It is synthesizable and should be the
default for address decoding.

### `case` on an expression other than a variable

```systemverilog
case (1'b1)                    // "whichever of these is true"
  req[0]: grant = d[0];
  req[1]: grant = d[1];
endcase
```

This inverts the usual reading: the selector is a constant and the *branches*
are the conditions. It is the idiomatic way to write one-hot logic, and it reads
better than the equivalent chain. Without `unique` it is still a priority
structure; with `unique` it is a promise (next section).

---

## 3. Priority or parallel: the choice that matters

Everything above produces a priority chain. The alternative is an AND-OR
structure whose depth does not grow with the number of inputs:

```systemverilog
always_comb begin
  d_par = '0;
  for (int i = 0; i < N; i++) d_par |= {W{req[i]}} & d[i];
end
```

One AND per lane, then an OR tree — depth `1 + log₂N` instead of `N`. For a
32-entry decoder that is roughly 6 levels instead of 32.

**It computes something different.** With two request bits set, the AND-OR form
produces the bitwise OR of two data words, which is neither of them. That is not
a defect; it is the price of the speed, and it is exactly what `unique case`
asks synthesis to build:

```systemverilog
unique case (1'b1)          // "I promise at most one of these is true"
  req[0]: y = d[0];
  req[1]: y = d[1];
endcase
```

`unique`, `unique0` and `priority` are **assertions about the inputs, not
optimisation switches.** The simulator checks the promise at run time; synthesis
simply believes it. When the promise is false the two disagree, and the
disagreement appears only in the case you claimed was impossible.

[`select_styles.sv`](../examples/rtl/select_styles.sv) writes the same selector
four ways and
[`formal/select_styles_fv.sby`](../formal/select_styles_fv.sby) proves what the
difference is:

```systemverilog
f_if_casez   : assert (d_if == d_casez);                        // always
f_if_loop    : assert (d_if == d_loop);                         // always
f_par_onehot0: assert (!$onehot0(req) || (d_par == d_if));      // only then
```

The three priority spellings are provably the same circuit — the choice between
them is taste. The parallel form is provably a different one, equal exactly
under `$onehot0(req)`, and a `cover` demonstrates a case where they differ so
the qualified assertion cannot pass vacuously. Removing the `!$onehot0(req) ||`
qualifier makes the proof fail, which is the check that the qualifier is
carrying weight.

> **Rule.** Write `unique` only where the one-hot property is guaranteed by
> construction or proved. Always pair it with a `default` so that the tools
> agree on behaviour even if the promise is broken. Never use the old
> `full_case` / `parallel_case` pragmas: they make the divergence permanent and
> are checked by nothing.

| | if / else-if | case | casez | `unique case (1'b1)` / AND-OR |
|---|---|---|---|---|
| Structure | priority chain | balanced mux | priority chain | parallel |
| Depth in N | N | log₂N | N | 1 + log₂N |
| Overlapping conditions | fine | not allowed | first wins | **must not happen** |
| Conditions may be unrelated | yes | no (one expr) | no | yes |
| Needs a proof obligation | no | no | no | **yes** |

---

## 4. The conditional operator

```systemverilog
assign y = sel ? a : b;                     // one 2:1 mux
assign y = s1 ? a : (s0 ? b : c);           // a chain, same as if/else if
```

`?:` is a 2:1 mux and nothing more. Chaining it produces exactly the structure
an `if`/`else if` chain does; for more than two or three levels use a `case`
instead, because nested `?:` stops being readable long before it stops being
legal.

**One real semantic difference from `if`, and it runs the opposite way from
most people's intuition.** With an X selector:

- `?:` evaluates **both** arms and merges them bitwise — equal bits pass
  through, differing bits become X. The X **propagates**.
- `if` treats an X condition as **false** and takes the `else` branch,
  deterministically and silently. The X **disappears**.

Measured under XSIM, with `y2` driven by `if (sel) y2 = a; else y2 = b;`:

| `a` | `b` | `sel ? a : b` | `if (sel)` |
|---|---|---|---|
| `55` | `55` | `55` | `55` |
| `55` | `aa` | `xx` | `aa` ← the X vanished |
| `5F` | `55` | `5X` | `55` ← and again |

So the conditional operator is **X-pessimistic** and `if`/`else` is
**X-optimistic**: the `if` form quietly commits to the `else` branch on an
unknown condition, which is precisely how a missed reset produces a simulation
that works and silicon that does not.

This applies to every `if` in this document, including the priority chains in
§1: an X in `req[0]` does not halt anything, it just falls through to the next
branch. See [docs/24 §8](24-dft-clocking-and-x-discipline.md#8-x-optimism-and-x-pessimism).

(A variable holding its *previous* value is a different case again — that is an
`if` with no `else` at all, which is the latch of §1.)

---

## 5. Loops are spatial, not temporal

This is the single largest conceptual gap between software control flow and RTL
control flow. A loop inside an `always` block is **unrolled at elaboration**. It
does not iterate over time; it is a way of writing N copies of something without
typing them N times.

```systemverilog
always_comb begin
  parity = 1'b0;
  for (int i = 0; i < 32; i++) parity ^= data[i];
end
```

That is not a 32-cycle loop. It is a 32-input XOR tree, produced in one cycle,
and the synthesiser will balance it.

**The bound must be static.** The tool has to know how many copies to make, so
loop bounds must be constants or parameters. A loop bound that depends on a
signal is not synthesizable — you need a counter and a state machine, which is
the temporal version of the same idea (see
[docs/26 §8](26-fsm-coding-styles.md#8-splitting-control-from-datapath)).

### What unrolling costs

Each iteration is real hardware. The cost that surprises people is a
**loop-carried dependency**: when iteration *i* reads what iteration *i−1* wrote,
unrolling produces a *chain*, not parallel copies.

```systemverilog
// A ripple chain 32 levels deep -- the loop looks cheap and is not
always_comb begin
  carry = 1'b0;
  for (int i = 0; i < 32; i++) begin
    sum[i] = a[i] ^ b[i] ^ carry;
    carry  = (a[i] & b[i]) | (carry & (a[i] ^ b[i]));
  end
end
```

Write `a + b` and let synthesis pick a fast adder. Reach for an explicit loop
only when the structure is what you want — and then check the depth. The
restructuring techniques in [docs/22](22-timing-closure-and-optimization.md) and
the tree forms in [docs/23](23-structural-design-techniques.md) exist for
exactly this case.

### The loop forms

| Form | Synthesizable | Where it belongs |
|---|---|---|
| `for (int i = 0; i < N; i++)` | yes, N static | RTL and testbenches |
| `foreach (arr[i])` | yes, for fixed-size arrays | RTL and testbenches |
| `repeat (N)` | yes if N is static | mostly testbenches: `repeat (4) @(posedge clk);` |
| `while (c)` | only if statically bounded | testbenches |
| `do ... while (c)` | rarely | testbenches |
| `forever` | no | testbenches: `forever @(posedge clk) ...` |

`forever` inside an `initial` is the standard way to write a clock generator or
a monitor. `repeat (N) @(posedge clk);` is the standard way to wait N cycles and
is clearer than a counted `for`.

`foreach` is convenient and **the Yosys frontend rejects it**, along with
`return` in a function, `string` parameters, unpacked array ports, `$bits()` of
a type and named assignment patterns. If a module needs to be formally verified
here, it must avoid those; see [docs/25](25-formal-verification-with-sby.md).

---

## 6. `break`, `continue`, `return`, `disable`

```systemverilog
always_comb begin
  d = '0;
  for (int i = 0; i < 4; i++)
    if (req[i]) begin d = lane[i]; break; end    // first match wins
end
```

`break` in an unrolled loop is not a jump — it becomes the "have I already
matched" logic that makes the loop a priority chain. It is the clearest way to
write "first one that matches".

**It is also the spelling with the worst tool support.** XSIM and Vivado
synthesis both accept it; the Yosys frontend rejects it outright with
``Can't resolve task name `break'``. [`select_styles.sv`](../examples/rtl/select_styles.sv)
therefore uses the explicit flag instead, which costs nothing because the loop is
unrolled and the flag is just a wire:

```systemverilog
logic found;
found = 1'b0; d_loop = '0;
for (int i = 0; i < 4; i++)
  if (req[i] && !found) begin d_loop = lane[i]; found = 1'b1; end
```

The proof confirms the two are the same circuit. Prefer `break` for clarity in
code that will not be formally verified with an open-source flow, and know the
flag form for code that will.

`continue` is the same story with the opposite sense, and is rarer in RTL.

`return` exits a function or task early. It reads well and Yosys rejects it too,
so functions in formally verified modules here assign to the function name
instead:

```systemverilog
function automatic logic [W-1:0] bin2gray(input logic [W-1:0] b);
  bin2gray = b ^ (b >> 1);        // not: return b ^ (b >> 1);
endfunction
```

`disable` terminates a named block. In RTL it is legacy and should not appear;
in testbenches it is how you abandon a stuck sequence:

```systemverilog
begin : wait_for_ack
  repeat (TIMEOUT) begin
    @(posedge clk);
    if (ack) disable wait_for_ack;
  end
  $error("no ack within %0d cycles", TIMEOUT);
end
```

`disable fork` and `wait fork` are the structured alternatives for processes —
next section.

---

## 7. Generate constructs

Written directly in a module body — outside any procedural block — `if`, `for`
and `case` are **generate** constructs. They are evaluated at elaboration and
choose *what hardware exists*, rather than describing what it does.

```systemverilog
module pipe_delay #(parameter int unsigned LATENCY = 1) (...);
  if (LATENCY == 0) begin : g_passthrough
    assign dout = din;                          // no flops at all
  end else begin : g_pipe
    for (genvar i = 0; i < int'(LATENCY); i++) begin : g_stage
      logic [WIDTH-1:0] prev;                   // one per iteration
      ...
    end
  end
endmodule
```

Three things follow from "elaboration-time", and each is a common source of
confusion:

1. **The loop body is a scope, re-instantiated per iteration.** Everything
   declared inside it — including `prev` above — is copied. With a label, the
   copies form an array of scopes: `g_pipe.g_stage[0].prev`,
   `g_pipe.g_stage[1].prev`, and so on. They are *different variables*, which is
   why each can have its own continuous assignment. If they were one variable
   that would be an error, not merely confusing: a `logic` may have at most one
   continuous driver.

2. **A generate `if` keeps one branch and discards the other entirely.** The
   untaken branch produces no hardware and is not elaborated, so it may
   reference parameters that would be illegal in the taken configuration.

3. **The `generate` / `endgenerate` keywords are optional** and have been since
   IEEE 1800-2009. Any `if` or `for` in a module body is already a generate
   construct.

`genvar` is a compile-time integer: it is substituted, not stored, and does not
exist in the elaborated design.

**Always label generate blocks.** The label becomes part of the hierarchical
path, which is what you need for waveform navigation, for constraints (`get_cells
u_dut/g_pipe/g_stage[3]/*`) and for `bind`. Unlabelled blocks get tool-generated
names that change when you edit the file.

See [docs/06](06-modules-parameters-generate.md) for the full rules.

---

## 8. Control structures for verification only

None of the following is synthesizable. All of it is essential in testbenches.

### `fork` / `join`

```systemverilog
fork
  drive_stimulus();
  monitor_outputs();
join                 // wait for ALL branches

fork
  wait_for_done();
  timeout(1000);
join_any             // wait for the FIRST to finish
disable fork;        // ...then kill the others

fork
  background_checker();
join_none            // do not wait at all; parent continues immediately
```

`join_any` plus `disable fork` is the timeout idiom, and the `disable fork` is
not optional — without it the losing branch keeps running and will interfere
with the next transaction.

`wait fork;` waits for all child processes of the current process, which is how
you drain outstanding activity before ending a test.

> **`join_none` and loop variables.** A process spawned with `join_none` does
> not start until the parent blocks, so a `for` loop that forks per iteration
> must copy the loop variable into an `automatic` local, or every process will
> see the final value. This is the classic testbench bug:
> ```systemverilog
> for (int i = 0; i < N; i++) begin
>   automatic int k = i;          // without this, every process sees i == N
>   fork send(k); join_none
> end
> ```

### Event control and `iff`

```systemverilog
@(posedge clk);                       // one edge
@(posedge clk iff ready);             // the first edge where ready is high
wait (count == 10);                   // level-sensitive: proceeds immediately
                                      // if already true
wait_order (a, b, c);                 // events must occur in this order
```

`@(posedge clk iff cond)` is much better than `do @(posedge clk); while (!cond);`
— it samples the condition in the same region as the edge, so it has no race.

### Fine-grained process control

```systemverilog
process p;
initial begin
  fork p = process::self(); ... join_none
  p.await();      // block until it finishes
  p.kill();       // terminate it
  p.status();     // RUNNING / WAITING / SUSPENDED / KILLED / FINISHED
end
```

Useful in reusable verification components where `disable fork` is too blunt —
it kills every child, including ones another layer started.

---

## 9. Quick reference

| Structure | RTL | Elaboration | Testbench | Builds |
|---|---|---|---|---|
| `if` / `else if` | ✔ | ✔ (module body) | ✔ | priority mux chain |
| `case` | ✔ | ✔ | ✔ | balanced mux |
| `casez` | ✔ | — | ✔ | priority mux chain |
| `casex` | **avoid** | — | avoid | priority chain, X-optimistic |
| `case inside` | ✔ | — | ✔ | comparators + mux |
| `unique` / `priority` | ✔ (as a promise) | — | ✔ | parallel / priority mux |
| `?:` | ✔ | ✔ (constants) | ✔ | 2:1 mux |
| `for` | ✔ static bounds | ✔ `genvar` | ✔ | N copies, unrolled |
| `foreach` | ✔ (not in Yosys) | — | ✔ | N copies, unrolled |
| `repeat` | ✔ static | — | ✔ | N copies / N cycles |
| `while`, `do-while` | bounded only | — | ✔ | unrolled if bounded |
| `forever` | ✘ | — | ✔ | — |
| `break` / `continue` | ✔ (not in Yosys) | — | ✔ | first-match logic |
| `return` | ✔ (not in Yosys) | — | ✔ | — |
| `disable` | legacy | — | ✔ | — |
| `fork` / `join*` | ✘ | — | ✔ | — |
| `wait`, `@ iff` | ✘ | — | ✔ | — |

---

## 10. Checklist

**Combinational blocks**
- [ ] Every output assigned a default at the top, or every branch assigns every
      output.
- [ ] Every `if` in combinational logic has an `else`, or a default above it.
- [ ] Every `case` has a `default`.
- [ ] No `casex` anywhere.
- [ ] `unique` / `priority` paired with a `default`, and the promise is
      guaranteed by construction or proved.
- [ ] No `full_case` or `parallel_case`.

**Structure and timing**
- [ ] Chains longer than a few branches reconsidered as a `case` or an
      AND-OR structure.
- [ ] Late-arriving signals select at the *last* mux, not the first.
- [ ] Every loop checked for a loop-carried dependency before assuming it is
      parallel.
- [ ] Loop bounds are static; anything data-dependent is a counter and an FSM.

**Generate**
- [ ] Every generate block labelled.
- [ ] Declarations inside a generate `for` understood to be per-iteration.

**Testbenches**
- [ ] `join_any` always followed by `disable fork`.
- [ ] Loop variables captured into `automatic` locals before `join_none`.
- [ ] `@(posedge clk iff cond)` instead of a polling loop.

---

## See also

- [docs/05: Procedural blocks and flow](05-procedural-blocks-and-flow.md) — the
  syntax of each construct, blocking vs non-blocking, latch avoidance
- [docs/06: Modules, parameters, generate](06-modules-parameters-generate.md) —
  generate scoping and hierarchical names in full
- [docs/11: Processes and synchronization](11-processes-and-synchronization.md)
  — `fork`/`join`, mailboxes, semaphores, events
- [docs/20: Synthesis subset](20-synthesis-subset-and-gotchas.md) — what is
  synthesizable and what silently is not
- [docs/22: Timing closure](22-timing-closure-and-optimization.md) — restructuring
  a chain into a tree, late-arriving signals
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) —
  X-optimism, and why `casex` is on the banned list
- [docs/26: FSM coding styles](26-fsm-coding-styles.md) — where most of these
  structures actually get used
