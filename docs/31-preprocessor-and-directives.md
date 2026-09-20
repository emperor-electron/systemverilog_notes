# The Preprocessor and Compiler Directives

SystemVerilog's preprocessor is inherited from Verilog and is essentially C's,
with one important difference: **macros have global scope and no namespace.**
There are no modules, no packages and no visibility rules for them. A `` `define ``
in any file affects every file compiled after it, in compilation order, for the
rest of the run.

That makes the preprocessor powerful, and it makes disciplined use of it more
important than in a language with real scoping. This document covers what the
directives do, the conditional-compilation strategy this repository uses to
support two tools with incompatible language subsets, and the traps.

---

## Contents

- [1. What the preprocessor is](#1-what-the-preprocessor-is)
- [2. `` `define `` and macro hygiene](#2-define-and-macro-hygiene)
- [3. Conditional compilation](#3-conditional-compilation)
- [4. The dual-dialect pattern](#4-the-dual-dialect-pattern)
- [5. `` `include `` and guards](#5-include-and-guards)
- [6. `` `default_nettype ``](#6-default_nettype)
- [7. `` `timescale ``](#7-timescale)
- [8. The rest](#8-the-rest)
- [9. When not to use a macro](#9-when-not-to-use-a-macro)
- [10. Checklist](#10-checklist)

---

## 1. What the preprocessor is

A textual substitution pass that runs before the language is parsed at all. It
has no idea what a module, a type or an expression is. Everything that follows
comes from that one fact:

- Macros do not respect any scope, because scopes do not exist yet.
- Macro arguments are substituted as **text**, not as values, so precedence
  errors are the default failure mode.
- Definitions persist across files in compilation order, so the same source can
  compile differently depending on the order of the file list.
- Errors are reported *after* substitution, so the line the tool names may
  contain nothing resembling what you wrote.

The last two are what make undisciplined macro use expensive to debug.

---

## 2. `` `define `` and macro hygiene

```systemverilog
`define MAX_BURST 16
`define CLOG2(n) ((n) <= 1 ? 0 : $clog2(n))
`define STRINGIFY(x) `"x`"
```

### Parenthesise everything

Arguments are text. Without parentheses, ordinary precedence quietly breaks:

```systemverilog
`define HALF(x) x / 2
y = `HALF(a + b);        // expands to a + b / 2   -- wrong

`define HALF(x) ((x) / 2)
y = `HALF(a + b);        // expands to ((a + b) / 2)   -- right
```

Parenthesise **each argument** and **the whole body**. There is no case where
this is wrong and many where omitting it is.

### Multi-line macros

Continue with a backslash. Every line but the last needs one, and a trailing
space after the backslash silently ends the macro:

```systemverilog
`define ASSERT_STABLE(clk, rst, sig)                      \
  assert property (@(posedge clk) disable iff (!rst)       \
    !$isunknown(sig))                                      \
    else $error(`"sig is X`");
```

### The escaping operators

| Operator | Does |
|---|---|
| `` `" `` | a literal `"` inside a macro body, so the text can form a string |
| ``` `\`" ``` | an escaped quote that survives into the expansion |
| ``` `` ``` | token paste — joins two identifiers |

```systemverilog
`define DECLARE_REG(name, w) logic [w-1:0] name``_q, name``_d;
`DECLARE_REG(count, 8)      // logic [7:0] count_q, count_d;
```

Token pasting is the main legitimate use of macros in RTL, because it is the one
thing the language genuinely cannot do: generate identifiers. Everything else on
this list has a better non-macro alternative (§9).

### Naming

Macros are global, so their names must be unique across the entire compilation,
including every vendor IP and library you pull in. Prefix them:

```systemverilog
`define MYPRJ_ASSERT_STABLE(...)      // not `ASSERT_STABLE
```

A collision does not error. The second definition wins, usually with a warning
nobody reads, and the behaviour changes depending on file order.

### `` `undef `` at the end of a file

If a macro is only meant for one file, undefine it when you are done:

```systemverilog
`define LOCAL_HELPER(x) ...
// ...
`undef LOCAL_HELPER
```

This is the closest thing the preprocessor has to scoping.

---

## 3. Conditional compilation

```systemverilog
`ifdef  NAME      // if defined
`ifndef NAME      // if not defined
`elsif  OTHER
`else
`endif
```

Definitions come from the source or from the command line, which is how the same
source builds differently per tool:

```bash
xvlog -sv -d SIMULATION design.sv          # XSIM
yosys -p 'read_verilog -sv -DSYNTHESIS -DFORMAL design.sv'
```

`SYNTHESIS` is defined automatically by most synthesis tools and by SymbiYosys
in this repository's flow. It is the standard way to exclude simulation-only
code from hardware:

```systemverilog
`ifndef SYNTHESIS
  // assertions, $display, reference models
`endif
```

> **`` `ifdef `` cannot test a value.** It tests only whether a name is defined.
> `` `ifdef WIDTH > 8 `` is not an error — it tests whether `WIDTH` is defined
> and ignores the rest of the line. For value-dependent code use a generate
> `if` on a parameter, which is checked by the compiler and appears in the
> elaborated hierarchy.

---

## 4. The dual-dialect pattern

This repository supports two tools whose accepted language subsets do not
overlap, and conditional compilation is what makes one source file serve both.

**XSIM** accepts the whole assertion language. **Yosys** supports *no part of
SVA's temporal layer* — no clocking event on `assert property`, no `|->`, no
`|=>`, no sequences, no `default clocking`. So a formally verified module
carries its properties twice, in two dialects:

```systemverilog
`ifndef SYNTHESIS
  // Idiomatic SVA, for XSIM. Concurrent assertions with a clocking event and
  // the |=> implication operator. Yosys cannot parse any of this.
  a_done_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    done |=> !done);
`endif

`ifdef FORMAL
  // Immediate assertions inside a clocked block, with $past. This is the whole
  // of what the Yosys frontend accepts.
  always @(posedge clk)
    if (past_ok && rst_n) f_done_pulse : assert (!($past(done) && done));
`endif
```

The two guards are chosen so exactly one applies per tool:

| Tool | `SYNTHESIS` | `FORMAL` | Gets |
|---|---|---|---|
| XSIM | undefined | undefined | the SVA block |
| SymbiYosys | **defined** | **defined** | the immediate block |
| Synthesis | defined | undefined | neither |

sby defining `SYNTHESIS` is what makes this work: it suppresses the SVA that
Yosys cannot parse, using the same guard that keeps it out of hardware.

**The cost is real and worth stating.** Two statements of one property can drift
apart, and nothing checks that they agree. Keep them adjacent in the file, name
them consistently (`a_` for the SVA dialect, `f_` for the immediate one), and
treat a change to one as a change to both.

There is a third guard in use for properties that belong to the caller rather
than the module — see [docs/26 §6](26-fsm-coding-styles.md#6-illegal-states-and-what-to-do-about-them)
for why `fsm_safe.sv` deliberately does *not* assert that its own state is
legal.

---

## 5. `` `include `` and guards

```systemverilog
`include "defs.svh"
```

Textual inclusion, resolved against the tool's include path (`+incdir+` for most
tools, `-i` for `xvlog`). `.svh` is the conventional extension for a header.

Because inclusion is textual, including a file twice defines everything twice.
Guard every header:

```systemverilog
`ifndef FP_PKG_SV
`define FP_PKG_SV

package fp_pkg;
  ...
endpackage

`endif
```

That is the form in [`fp_pkg.sv`](../examples/arith/fp_pkg.sv) and
[`fixed_pkg.sv`](../examples/arith/fixed_pkg.sv) — and note what it is
protecting. **A package does not need `` `include ``**; it is imported with
`import fp_pkg::*;` and compiled once as its own compilation unit. The guard
exists only in case someone includes the file textually, which is a thing
people do.

> **Prefer packages to headers.** A package gives you real scoping, real types,
> real functions and real parameters, all of which the preprocessor cannot. Use
> `` `include `` for macro definitions, which packages cannot hold, and nothing
> else. See [docs/07](07-interfaces-and-packages.md).

---

## 6. `` `default_nettype ``

```systemverilog
`default_nettype none
module foo (...);
  ...
endmodule
`default_nettype wire
```

Every module in this repository is bracketed this way, and it is the single most
valuable directive in the language.

By default, an undeclared identifier in a port connection or continuous
assignment becomes an implicit 1-bit wire. That turns a typo into a silent
functional bug:

```systemverilog
logic [7:0] data_valid;
assign dat_valid = ...;     // typo -> implicit 1-bit wire, no error
```

With `` `default_nettype none `` it is an error instead. It also catches a
forgotten width on a port and an accidentally-unconnected instance port.

**Restore it to `wire` at the end of the file.** The directive is global and
order-dependent, so leaving it at `none` breaks the next file compiled —
including third-party IP that legitimately relies on implicit nets. The
open-bracket/close-bracket convention is what makes it safe in a shared
codebase.

---

## 7. `` `timescale ``

```systemverilog
`timescale 1ns/1ps        // unit / precision
```

The first number is the unit for bare delays (`#5` means 5 ns); the second is
the rounding precision. It affects simulation only.

Three things to know:

**It is global and order-dependent, like everything else here.** A file with no
`` `timescale `` inherits whatever the previously compiled file set, which makes
the meaning of `#1` depend on the file list. Modules in this repository do not
set one at all — only testbenches do — which is the safer convention: RTL should
have no delays to scale.

**The finest precision in the design wins.** Any module with `1ps` precision
forces the whole simulation onto a 1 ps time wheel, which slows everything down.
Do not specify finer precision than you need.

**Prefer the command-line override** for consistency across a mixed codebase:

```bash
xelab -timescale 1ns/1ps top
```

`` `timescale `` has no meaning for synthesis and none for formal.

---

## 8. The rest

| Directive | What it does | Use |
|---|---|---|
| `` `undef `` | removes a definition | end of a file that defined local macros |
| `` `resetall `` | resets all directives to defaults | start of a file, if you distrust the file order |
| `` `line `` | overrides the reported line number | generated code, so errors point at the generator's input |
| `` `pragma `` | standardised tool directive | rarely; vendors mostly use comment pragmas |
| `` `__FILE__ ``, `` `__LINE__ `` | current file and line | error messages inside macros |
| `` `begin_keywords `` / `` `end_keywords `` | select a language version's keyword set | compiling old Verilog that uses a newer keyword as an identifier |

`` `__FILE__ `` and `` `__LINE__ `` are genuinely useful in assertion macros,
because the expansion otherwise reports the macro's location rather than the
call site:

```systemverilog
`define CHECK(c) \
  if (!(c)) $error("%s:%0d: check failed", `__FILE__, `__LINE__);
```

### Comment pragmas

Most vendor directives are *comments*, not preprocessor directives, which is why
they survive tools that do not understand them:

```systemverilog
/* verilator lint_off MULTIDRIVEN */
(* ASYNC_REG = "TRUE" *)           // an attribute, not a pragma
// synopsys translate_off
```

Attributes in `(* ... *)` are part of the language and are parsed; comment
pragmas are not, and an unknown one is silently ignored. That is a feature — it
is why [`ram_tdp.sv`](../examples/rtl/ram_tdp.sv) can carry a Verilator waiver
that XSIM and Yosys both skip harmlessly — and a hazard, because a misspelled
pragma is also silently ignored.

`// synopsys translate_off` / `translate_on` is the pre-`` `ifdef `` way of
hiding code from synthesis. Prefer `` `ifndef SYNTHESIS ``, which every tool
honours and which a reader can grep for.

---

## 9. When not to use a macro

Most historical uses of the preprocessor have better modern replacements. The
replacements are type-checked, scoped and visible in the elaborated design; the
macro is none of those.

| Instead of | Use | Why |
|---|---|---|
| `` `define WIDTH 32 `` | `parameter int WIDTH = 32` | typed, scoped, overridable per instance |
| `` `define ADDR_T logic [31:0] `` | `typedef` in a package | a real type; works with `$bits`, ports, arrays |
| `` `define MAX(a,b) ... `` | `function automatic` | evaluated once, type-checked, no precedence traps |
| `` `include "consts.svh" `` | `package` + `import` | namespaced, compiled once |
| `` `ifdef `` on a value | generate `if` on a parameter | checked by the compiler, appears in the hierarchy |

**What macros are still right for:**

- Generating identifiers (token pasting) — the language genuinely cannot.
- Wrapping assertions, where `` `__FILE__ `` / `` `__LINE__ `` and the ability
  to take an expression *unevaluated* both matter.
- Conditional compilation across tools — §3 and §4.
- Anything that must appear textually in a declaration position.

A function cannot be used where a declaration is required, and cannot capture
the text of its argument for an error message. Those two gaps are the honest
remaining case for macros in RTL.

---

## 10. Checklist

**Macros**
- [ ] Every argument parenthesised, and the whole body parenthesised.
- [ ] Names prefixed with a project-unique string.
- [ ] File-local macros `` `undef ``-ed at the end of the file.
- [ ] No macro used where a parameter, `typedef` or function would do.

**Conditional compilation**
- [ ] Simulation-only code behind `` `ifndef SYNTHESIS ``, not
      `// synopsys translate_off`.
- [ ] `` `ifdef `` never used to test a value.
- [ ] Dual-dialect properties kept adjacent and named consistently.

**Files**
- [ ] Every header guarded.
- [ ] Packages imported, not included.
- [ ] `` `default_nettype none `` at the top of every RTL file and `wire` at the
      bottom.
- [ ] `` `timescale `` on testbenches only, or set globally on the command line.
- [ ] No reliance on compilation order for correctness.

---

## See also

- [docs/07: Interfaces and packages](07-interfaces-and-packages.md) — what to
  use instead of a header
- [docs/12: Assertions](12-assertions-sva.md) — the SVA the dual-dialect pattern
  is protecting
- [docs/20: Synthesis subset](20-synthesis-subset-and-gotchas.md) — what
  `` `ifndef SYNTHESIS `` needs to hide
- [docs/25: Formal with sby](25-formal-verification-with-sby.md) — the Yosys
  frontend subset that makes the second dialect necessary
- [docs/26: FSM coding styles](26-fsm-coding-styles.md) — a worked example of
  which properties belong in the module and which belong to the caller
