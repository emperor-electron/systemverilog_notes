# Coding Conventions and Design Reuse

Conventions are not style preferences. In a hardware description language where
a typo becomes a 1-bit wire, an incomplete `if` becomes a latch, and a signed
cast silently changes a shift, most conventions exist because breaking them
produces *working-looking* code that is wrong.

This document collects the conventions used throughout this repository, the
failure each one prevents, and the patterns that make a module reusable rather
than merely parameterised.

---

## Contents

- [1. File and module structure](#1-file-and-module-structure)
- [2. Naming](#2-naming)
- [3. Types and declarations](#3-types-and-declarations)
- [4. Procedural blocks](#4-procedural-blocks)
- [5. Reset conventions](#5-reset-conventions)
- [6. Parameterisation](#6-parameterisation)
- [7. Elaboration-time checking](#7-elaboration-time-checking)
- [8. Interfaces that stay reusable](#8-interfaces-that-stay-reusable)
- [9. Assertions as part of the module](#9-assertions-as-part-of-the-module)
- [10. Comments that earn their place](#10-comments-that-earn-their-place)
- [11. Lint policy](#11-lint-policy)
- [12. Review checklist](#12-review-checklist)

---

## 1. File and module structure

**One module per file, named after the module.** Tools that search libraries
(`-y`, `+libext`) require it, and it makes a design navigable by `ls`. XSIM has
no library-search switch, so this repository's `make` analyses every file
explicitly — the convention still pays for readability.

Every RTL file is bracketed:

```systemverilog
// -----------------------------------------------------------------------------
// module_name.sv -- one-line statement of what it is.
//
// Why it exists, the non-obvious decisions, and what will break if you change
// them. See docs/NN.
// -----------------------------------------------------------------------------
`default_nettype none

module module_name #(...) (...);
  ...
endmodule

`default_nettype wire
```

`` `default_nettype none `` turns an undeclared identifier into an error instead
of an implicit 1-bit wire, which is the difference between catching a typo at
compile time and debugging a silently truncated signal. Restoring `wire` at the
end of the file matters because the directive is global and order-dependent —
leaving it at `none` breaks the next file compiled, including third-party IP
that legitimately uses implicit nets. See
[docs/31 §6](31-preprocessor-and-directives.md#6-default_nettype).

**Declaration order inside a module:** parameters, ports, localparams, types,
signals, submodule instances, combinational logic, sequential logic, assertions.
Predictability is the whole benefit.

---

## 2. Naming

| Suffix | Means | Example |
|---|---|---|
| `_t` | a type | `addr_t` |
| `_e` | an enum type | `state_e` |
| `_n` | active low | `rst_n` |
| `_q` | a registered value | `count_q` |
| `_d` | the next-state input to a register | `count_d` |
| `_i` / `_o` | module input / output, where ambiguity is real | `data_i` |
| `u_` | an instance | `u_fifo` |
| `g_` | a generate block label | `g_stage` |
| `a_` / `c_` / `f_` | SVA assert / cover / formal-dialect property | `a_onehot` |

The `_q`/`_d` pair is the one that repays itself constantly: it makes it
impossible to misread which side of a register you are looking at, and it makes
a missing `_d` assignment visible.

The `a_`/`f_` split is specific to this repository's dual-dialect pattern —
`a_` for the SVA that XSIM runs, `f_` for the immediate assertions Yosys reads
([docs/31 §4](31-preprocessor-and-directives.md#4-the-dual-dialect-pattern)).

**Signal names describe what a signal *is*, not what it does downstream.**
`fifo_almost_full` is a name that survives being used somewhere new; `stall_alu`
is not.

---

## 3. Types and declarations

**`logic`, not `reg` or `wire`.** One type for everything; the tool works out
whether it needs a flop. The only reason to write `wire` is a genuine
multiple-driver net, which in synthesizable RTL means a tri-state bus.

**`var` on ports.** `input var logic` makes the port a variable rather than a
net, which forbids the accidental multiple-driver case and matches how the
signal is actually used.

**Size every enum's base type.**

```systemverilog
typedef enum logic [2:0] { S_IDLE, S_REQ, S_XFER } state_e;
//               ^^^^^^^^ without this it is a 32-bit int
```

**Name every derived width.** A `localparam` that is computed once is a
`localparam` that cannot be computed inconsistently in three places:

```systemverilog
parameter  int unsigned DEPTH = 16,
localparam int unsigned AW    = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
```

The `<= 1` guard is not decoration — `$clog2(1)` is 0, and a zero-width signal
is an error in some tools and a silent oddity in others.

**Be explicit about `signed`.** Signedness propagates through expressions by
rules most people do not have memorised, and one unsigned operand makes the
whole expression unsigned — which turns `>>>` into a logical shift. That exact
bug (`requantize`) turned every negative filter output into a large positive one
and is trap T6b in [docs/17](17-signed-unsigned-arithmetic.md).

> Neither `xvlog` nor `yosys` reports width mismatches. This is stated plainly
> in [docs/20](20-synthesis-subset-and-gotchas.md) rather than left implied, and
> it is the main reason to name widths rather than write literals.

---

## 4. Procedural blocks

**`always_ff` with `<=` only. `always_comb` with `=` only.** The rule exists
because of the scheduling regions ([docs/15](15-scheduling-and-race-conditions.md)),
and violating it produces races that appear under a different simulator or after
an unrelated edit.

**Default assignment first, in every combinational block:**

```systemverilog
always_comb begin
  next    = state;        // hold
  bus_req = 1'b0;         // every output, every time
  unique case (state)
    ...
  endcase
end
```

Every path now assigns every signal, so there is nothing to infer. `fp_mul` in
this repository shows what forgetting it costs: an inferred latch on `dn_mask`,
caught by lint.

**Every `case` gets a `default`. `unique` is paired with a `default`, never with
`full_case`.** `unique` is an assertion about the inputs, not an optimisation
switch; without a `default` the tools diverge, because the simulator reports a
violation and holds the old value while synthesis was told the case is
impossible and builds anything. See
[docs/27 §3](27-control-structures.md#3-priority-or-parallel-the-choice-that-matters).

**Never `casex`.** An X in the case expression matches the first branch and the
design sails on.

---

## 5. Reset conventions

**Active low, asynchronous assert, synchronous release.** One
[`reset_sync.sv`](../examples/rtl/reset_sync.sv) per clock domain.

**Reset the control path, not the data path.** A datapath pipeline register
needs no reset — the valid bit travelling beside it carries the meaning.
Resetting it costs area, costs reset-net routing on a wide bus, and blocks
retiming. `pipe_delay.sv` makes this a parameter (`RESET`) precisely because it
is a per-instance decision:

```systemverilog
end else begin : g_norst
  always_ff @(posedge clk) begin
    if (en) stage[i] <= prev;      // no reset: smaller flop, off the reset tree
  end
end
```

**Never reset a memory array.** Block RAMs have no reset port, and a reset on
the array makes the memory un-inferrable — you get flops instead
([docs/29](29-memories-and-inference.md)).

---

## 6. Parameterisation

A module is reusable when its parameters are the *right* parameters, not when it
has many.

**Parameterise the things a second instance would need to differ in.** Width,
depth, latency, reset value, and behavioural variants that are genuinely
variants. `pipe_delay` takes `WIDTH`, `LATENCY`, `RESET` and `RST_VAL` — four
parameters, each of which a real second caller needs.

**`LATENCY == 0` must work.** Degenerate configurations are where
parameterisation earns its keep, because they let a caller sweep a parameter
without special-casing:

```systemverilog
if (LATENCY == 0) begin : g_passthrough
  assign dout = din;              // a deliberate case, not a tolerated one
end else begin : g_pipe
  ...
end
```

The same applies to `N == 1` for an arbiter, `DEPTH == 1` for a FIFO, and
`BYTES == 1` for a byte-enabled RAM. Each is a real caller configuration and
each is where off-by-one bugs live.

**Derive, do not re-specify.** `AW` is computed from `DEPTH`, not passed
alongside it, so the two cannot disagree. Where a derived parameter must appear
in the parameter list (because a port width needs it), give it a default
expression rather than expecting the caller to supply it.

**Label every generate block.** The label becomes part of the hierarchical path,
which is what waveform navigation, constraints (`get_cells u_dut/g_pipe/*`) and
`bind` all rely on. Unlabelled blocks get tool-generated names that change when
you edit the file — and a constraint that silently stops matching is worse than
one that errors. See [docs/06](06-modules-parameters-generate.md).

---

## 7. Elaboration-time checking

A parameterised module should refuse configurations it cannot implement, at
elaboration, with a message naming the problem:

The idiom is a **labelled generate `if` containing an elaboration system
task**, as in [`sync_fifo.sv`](../examples/rtl/sync_fifo.sv):

```systemverilog
localparam int unsigned AW = $clog2(DEPTH);

// Elaboration-time parameter checks.
if (DEPTH < 2) begin : g_chk_min
  $error("sync_fifo: DEPTH must be >= 2, got %0d", DEPTH);
end
if (DEPTH != (1 << AW)) begin : g_chk_pow2
  $error("sync_fifo: DEPTH must be a power of two, got %0d", DEPTH);
end
```

`$error`, `$fatal`, `$warning` and `$info` are *elaboration* system tasks when
they appear directly in a generate context, so the message is produced by the
compiler with the offending value substituted — and a generate `if` whose
condition is false produces nothing at all, so a legal configuration costs
literally zero.

This replaces a confusing downstream failure with a direct statement of the
rule, and it is far better than a comment saying "DEPTH must be a power of two",
because a comment does not run. Note the second check is written against `AW`
rather than repeating the power-of-two arithmetic: the check and the derived
width cannot disagree.

Elaboration-time computation deserves the same treatment: prefer a constant
function evaluated by the compiler over a hand-computed table that can drift
from the code it was derived from
([docs/23 §1](23-structural-design-techniques.md#1-elaboration-time-computation)).

---

## 8. Interfaces that stay reusable

**Register the module's outputs.** A module whose outputs come straight off a
flop can be placed anywhere; one whose outputs are combinational imposes its
logic depth on whatever it connects to, and its reusability depends on the
caller's timing. For an FSM, decode from `next` so registering costs no latency
([docs/26 §3](26-fsm-coding-styles.md#3-registering-the-outputs-costs-nothing)).

**Use valid/ready, and obey the rules.** `valid` must not depend
combinationally on `ready`. It is the asymmetry that lets modules compose
without combinational loops, and it is what makes a skid buffer insertable
anywhere ([docs/30](30-flow-control-and-handshakes.md)).

**Avoid unpacked array ports.** They are legal, and the Yosys frontend rejects
them, along with `foreach`, `return` in a function, `string` parameters,
`$bits()` of a type and named assignment patterns. A module that avoids those
can be formally verified with an open-source flow; one that does not, cannot.
`select_styles.sv` takes a flat `[4*W-1:0]` vector and unpacks it internally for
exactly this reason.

**Do not put a clock or reset in an interface used across domains.** It reads
well and it hides the crossing from anyone looking at the port list.

---

## 9. Assertions as part of the module

Properties belong **in** the module, next to the logic they describe, guarded so
they disappear from hardware:

```systemverilog
`ifndef SYNTHESIS
  a_onehot: assert property (@(posedge clk) disable iff (!rst_n)
    $onehot0(grant))
    else $error("arb: grant %b is not one-hot", grant);
`endif
```

They document the contract in a form that is checked, and they fire at the
source of a bug rather than wherever it eventually surfaces.

**But only the properties the module actually promises.** The distinction
matters more than it sounds. `fsm_safe.sv` deliberately does *not* assert that
its own state is one-hot: it is true of every reachable state, but that module's
whole purpose is to behave well where it is false, so asserting it would fire on
every fault injection and every formal step starting from an arbitrary state.
The reachability claim belongs to the caller. `ring_counter.sv` is split the
same way — preservation in the module, base case in the harness.

The rule: **a module asserts what it guarantees; a harness asserts what it
expects.**

---

## 10. Comments that earn their place

Comment the *why*, and specifically the why that is not recoverable from the
code:

```systemverilog
// The recovery term must come LAST and overwrite, not OR in: ORing IDLE into
// an illegal state would produce a state that is still illegal (two bits set)
// rather than recovering from it.
if (SAFE && !$onehot(state)) next = (NS'(1) << I_IDLE);
```

Worth writing: a non-obvious decision and its alternative; a constraint a future
editor would otherwise break; a bug that was found here once; a tool limitation
being worked around; the reason a degenerate case exists.

Not worth writing: what the line does. `// increment the counter` above
`cnt <= cnt + 1` is noise that goes stale.

**Record the tool limitations where they bite.** `select_styles.sv` explains in
place why it uses a `found` flag instead of `break` — Yosys rejects `break`, and
the flag costs nothing because the loop is unrolled. Without that comment the
next editor "simplifies" it and silently removes the module from the formal flow.

---

## 11. Lint policy

**Lint is part of the build, not a separate activity.** `make` here runs
`xvlog` for analysis errors and `yosys` for inferred latches before anything
else, and the whole build fails on either.

**Every waiver is justified in place.** The one in this repository:

```systemverilog
// A true dual-port RAM is genuinely written from two different clock domains.
// That is what the primitive does, so a multiple-driver warning is expected
// here and only here.
/* verilator lint_off MULTIDRIVEN */
logic [DW-1:0] mem [0:DEPTH-1];
/* verilator lint_on MULTIDRIVEN */
```

Narrow scope, next to the code, with the reason. A file-level or project-level
waiver disables the check everywhere, including where it would have been right.

**Know what your linter does not check.** Neither tool in this flow reports
width mismatches. Saying so is more useful than assuming coverage that is not
there — and it is why the conventions in §3 about naming widths matter more here
than they would in a flow with a commercial linter.

---

## 12. Review checklist

**Structure**
- [ ] One module per file, named after the module.
- [ ] `` `default_nettype none `` at the top, `wire` at the bottom.
- [ ] Every generate block labelled.
- [ ] Declaration order predictable.

**Correctness**
- [ ] Default assignment first in every `always_comb`.
- [ ] Every `case` has a `default`; no `casex`; `unique` paired with `default`.
- [ ] `always_ff` uses `<=` only; `always_comb` uses `=` only.
- [ ] Every derived width is a named `localparam`, with degenerate cases guarded.
- [ ] `signed` explicit wherever arithmetic depends on it.
- [ ] Reset: active low, async assert, sync release; control path only; never a
      memory array.

**Reuse**
- [ ] Degenerate parameter values (0, 1) work and are tested.
- [ ] Derived parameters computed, not passed.
- [ ] Illegal configurations rejected with `$fatal` at elaboration.
- [ ] Outputs registered, or a documented reason not to.
- [ ] No unpacked array ports if the module should be formally verifiable.

**Verification**
- [ ] Module asserts what it guarantees, not what its caller expects.
- [ ] Assertions guarded by `` `ifndef SYNTHESIS ``.
- [ ] Lint clean, with every waiver narrow and justified in place.
- [ ] Comments explain the non-obvious decisions and the tool limitations.

---

## See also

- [docs/02: Data types](02-data-types.md) — `logic` versus `reg` and `wire`,
  2-state versus 4-state
- [docs/06: Modules, parameters, generate](06-modules-parameters-generate.md) —
  parameter styles, generate scoping, `bind`
- [docs/17: Signed and unsigned](17-signed-unsigned-arithmetic.md) — the trap
  catalogue behind the `signed` convention
- [docs/20: Synthesis subset](20-synthesis-subset-and-gotchas.md) — latch
  inference, and what the linters here do and do not catch
- [docs/31: Preprocessor and directives](31-preprocessor-and-directives.md) —
  `default_nettype`, header guards, the dual-dialect pattern
- [docs/33: Debugging and bring-up](33-debugging-and-bringup.md) — what these
  conventions are preventing, with the bugs that got through
