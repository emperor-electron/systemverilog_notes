# Functional Coverage **[V]**

Code coverage tells you which lines executed. Functional coverage tells you
which **scenarios** occurred. Only the second one answers "did we test it".

## 1. Covergroups

```systemverilog
covergroup cg_txn @(posedge clk);
  option.per_instance = 1;
  option.at_least     = 5;
  option.name         = "txn_coverage";

  cp_kind : coverpoint kind {
    bins read    = {OP_READ};
    bins write   = {OP_WRITE};
    bins atomic[] = {OP_CAS, OP_SWAP, OP_ADD};   // one bin each
    ignore_bins  rsvd = {OP_RESERVED};
    illegal_bins bad  = {OP_INVALID};
  }

  cp_len : coverpoint len {
    bins tiny   = {[1:4]};
    bins small  = {[5:64]};
    bins medium = {[65:512]};
    bins large  = {[513:$]};
    bins pow2[] = {1,2,4,8,16,32,64,128,256,512};
  }

  cp_resp : coverpoint resp iff (valid);

  x_kind_len : cross cp_kind, cp_len {
    ignore_bins atomic_large = binsof(cp_kind.atomic) &&
                               binsof(cp_len) intersect {[513:$]};
  }
endgroup

cg_txn cg;
initial begin
  cg = new();       // covergroups MUST be constructed
end
```

A covergroup is a class-like object: declare the type, then `new()` an instance.
Forgetting the `new()` is a silent no-coverage bug.

## 2. Sampling

Three ways:

```systemverilog
// (a) Clocked: sample on an event
covergroup cg @(posedge clk); ... endgroup

// (b) Explicit: call sample()
covergroup cg; ... endgroup
cg.sample();

// (c) With arguments -- the idiomatic form for class-based TB
covergroup cg with function sample(bit [3:0] kind, int len);
  cp_kind : coverpoint kind;
  cp_len  : coverpoint len;
endgroup
cg.sample(txn.kind, txn.len);
```

Form (c) is the best default: the covergroup does not need to reach into the
design or hold handles, it just receives values. It also makes the covergroup
reusable and unit-testable.

## 3. Bins

```systemverilog
coverpoint x {
  bins a       = {1, 2, 3};        // one bin, matches any of 1/2/3
  bins b[]     = {1, 2, 3};        // three bins: b[1], b[2], b[3]
  bins c[4]    = {[0:15]};         // four bins, 4 values each
  bins d       = {[10:20], 25};
  bins e       = default;          // everything not covered by another bin
  bins f[]     = default;          // one bin per uncovered value (can explode)

  wildcard bins g = {4'b1??0};     // ? matches 0 and 1

  // Transition bins
  bins t1 = (0 => 1);
  bins t2 = (0 => 1 => 2 => 3);
  bins t3 = (0, 1 => 2, 3);        // (0=>2),(0=>3),(1=>2),(1=>3)
  bins t4 = (1 [*3]);              // 1=>1=>1
  bins t5 = (1 [->3]);             // 1, non-consecutively, 3 times
  bins t6 = (1 => 2 [*1:3] => 3);

  ignore_bins  ig = {7};           // excluded from the coverage total
  illegal_bins il = {15};          // a runtime ERROR if it ever occurs
}
```

Default bin sizing: without an explicit `bins`, a coverpoint gets
`option.auto_bin_max` bins (default 64) spread over its value range. For a
32-bit signal that is meaningless — always write explicit bins for anything
wider than a few bits.

`ignore_bins` vs `illegal_bins`:

- `ignore_bins` = "this can happen, we do not care about it" → removed from the
  denominator.
- `illegal_bins` = "this must never happen" → an error if it does. This makes
  the covergroup double as a checker.

## 4. Crosses

```systemverilog
cross cp_a, cp_b;                         // every combination

x_ab : cross cp_a, cp_b {
  ignore_bins  imposs = binsof(cp_a) intersect {0} &&
                        binsof(cp_b) intersect {[10:$]};
  illegal_bins never  = binsof(cp_a.bad);
  bins         both_hi = binsof(cp_a.hi) && binsof(cp_b.hi);
}
```

Crosses **multiply**: a 10-bin coverpoint crossed with a 20-bin one is 200 bins,
and crossing three is 2000. Most of those are usually uninteresting or
impossible. Two disciplines keep crosses useful:

1. Cross only **small, deliberately-binned** coverpoints. Make a 4-bin
   `cp_len_class` specifically for crossing rather than crossing the 50-bin
   `cp_len`.
2. Write the `ignore_bins` for impossible combinations up front. An unreachable
   bin in the denominator means you can never close coverage, and the team
   learns to ignore the number.

## 5. Options

| Option | Default | Meaning |
|---|---|---|
| `option.per_instance` | 0 | track each instance separately (vs merged) |
| `option.at_least` | 1 | hits needed before a bin counts as covered |
| `option.auto_bin_max` | 64 | automatic bin count |
| `option.weight` | 1 | contribution to the parent's total |
| `option.goal` | 100 | target percentage |
| `option.name` | — | instance name in reports |
| `option.comment` | — | free text in reports |
| `type_option.merge_instances` | 1 | merge all instances for the type total |
| `option.cross_num_print_missing` | 0 | how many uncovered cross bins to list |

Set `option.per_instance = 1` on anything you instantiate more than once, or
the report merges four channels' coverage and tells you nothing about which one
is untested.

## 6. Querying coverage

```systemverilog
cg.get_coverage();            // type coverage, 0..100
cg.get_inst_coverage();       // this instance
cg.cp_kind.get_coverage();    // one coverpoint
$get_coverage();              // overall, whole simulation
cg.start();  cg.stop();       // gate sampling
cg.set_inst_name("chan0");
```

```systemverilog
// End-of-test gate
final begin
  if ($get_coverage() < 95.0)
    $warning("coverage %.1f%% below target", $get_coverage());
end
```

## 7. Coverage in a class-based testbench

```systemverilog
class Coverage;
  bit [3:0] kind;
  int       len;
  bit       err;

  covergroup cg;
    option.per_instance = 1;
    cp_kind : coverpoint kind { bins k[] = {[0:7]}; }
    cp_len  : coverpoint len  { bins tiny={[1:8]}; bins mid={[9:64]};
                                bins big={[65:$]}; }
    cp_err  : coverpoint err;
    x_ke    : cross cp_kind, cp_len;
  endgroup

  function new();
    cg = new();                 // construct in the class constructor
  endfunction

  function void sample(Txn t);
    kind = t.kind;
    len  = t.len;
    err  = t.err;
    cg.sample();
  endfunction
endclass
```

Note the pattern: the covergroup samples **class properties**, and a `sample()`
method copies the transaction's fields in first. The `with function sample(...)`
form avoids the copy:

```systemverilog
covergroup cg with function sample(bit [3:0] kind, int len, bit err);
  cp_kind : coverpoint kind;
  ...
endgroup
...
cg.sample(t.kind, t.len, t.err);
```

## 8. Writing a coverage model that means something

The failure mode of functional coverage is a model that reaches 100% while the
design is untested. That happens when the bins describe **inputs** rather than
**scenarios**.

Weak:

```systemverilog
cp_addr : coverpoint addr;          // 64 auto bins of a 32-bit address.
                                    // Hits 100% and proves nothing.
```

Strong:

```systemverilog
cp_addr_class : coverpoint addr_class {   // a DERIVED, meaningful classification
  bins region_boundary_low  = {ADDR_FIRST};
  bins region_boundary_high = {ADDR_LAST};
  bins unaligned            = {ADDR_UNALIGNED};
  bins crosses_page         = {ADDR_PAGE_CROSS};
  bins normal               = {ADDR_NORMAL};
}
```

Checklist for a coverage model:

1. **Boundaries.** Min, max, min+1, max−1, zero, and the exact points where the
   design changes behaviour (FIFO full/empty/almost-full, counter wrap).
2. **State.** Every FSM state, and every *legal transition* between states —
   the transitions find more bugs than the states.
3. **Concurrency.** The cross of "what the DUT is doing" with "what is arriving".
   Back-to-back, gap of one, gap of many.
4. **Backpressure.** Ready low for 0/1/many cycles, at every stage.
5. **Error paths.** Each error type, and each error occurring *during* each
   normal operation.
6. **Resets.** Reset during idle, during a transaction, during a burst.
7. **Configuration.** Cross the parameter/mode space with the operation space.

And for each coverage hole you decide not to close, write the `ignore_bins` with
a comment saying why. A coverage report that is honestly at 92% with documented
exclusions is worth more than one at 100% that nobody believes.

## 9. Coverage-driven closure loop

```
  1. Write the coverage model from the spec (before the tests).
  2. Run constrained-random with many seeds.
  3. Rank coverage: which seeds contributed unique bins?
  4. Find the holes.
  5. For each hole, decide:
       - reachable and interesting -> add a constraint / a directed test
       - unreachable              -> ignore_bins + a comment
       - a spec question          -> ask
  6. Repeat until the curve flattens, then stop adding seeds and start
     adding directed tests.
```

The coverage curve flattening is the signal to switch strategies. Running the
same random test with 10× more seeds after the curve flattens buys almost
nothing; the remaining holes need targeted stimulus.
