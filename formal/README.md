# Formal proofs

SymbiYosys proofs for the modules in [`../examples/`](../examples/).
Run them all with `make formal` from the repository root, or:

```bash
./run_all.sh                          # every proof, with per-task status
sby -f skid_buffer_fv.sby prove       # one task
sby -f sync_fifo_fv.sby   bmc
```

A failing run leaves `<name>_<task>/` containing `logfile.txt`, a VCD
counterexample, and `engine_0/trace_tb.v` — a generated Verilog testbench that
replays the exact failing input sequence. That last file is usually the fastest
way in, because Yosys bit-blasts vectors in the VCD.

## Layout

| File | Role |
|---|---|
| `<module>_fv.sv` | the harness: drives inputs, constrains the environment, gives the solver a defined reset state |
| `<module>_fv.sby` | tasks (`bmc` / `prove` / `cover`), depth, engine, and the file list |
| `run_all.sh` | runs every task in every `.sby`, exits non-zero on any failure |

Some modules also carry an `` `ifdef FORMAL `` block in the RTL itself. That is
not a style choice: **a hierarchical reference from a harness into a submodule
silently reads the wrong net** in this flow — a tautology like
`dut.skid_valid == !in_ready` fails — so any property needing internal state has
to live inside the module.

## The three modes

| Mode | Question | A pass means |
|---|---|---|
| `bmc` | can an assertion fail within `depth` cycles of reset? | no counterexample that short exists. For **combinational** logic this is an exhaustive proof |
| `prove` | does it hold for all time? | a real unbounded proof, by k-induction |
| `cover` | is this state reachable? | it is, and here is a trace. Guards against vacuous `assert`s |

`cover` is not optional. An assertion whose antecedent can never be true passes
while proving nothing.

## Why the assertion style looks old-fashioned

Yosys's open-source SystemVerilog frontend does not support SVA's temporal layer
at all — no `assert property` with a clocking event, no `|->` or `|=>`, no
sequences. Everything here is an **immediate assertion inside a clocked block**,
with `$past` carrying the temporal part. The idiomatic SVA still exists in the
RTL for XSIM, behind `` `ifndef SYNTHESIS ``, which `sby` skips by passing
`-DSYNTHESIS`.

[docs/25](../docs/25-formal-verification-with-sby.md) has the full list of
rejected constructs, the harness pattern, and a worked example of closing an
induction proof that will not converge.
