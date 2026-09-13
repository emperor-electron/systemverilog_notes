# Randomization and Constraints **[V]**

## 1. Random variables

```systemverilog
class Txn;
  rand  bit [7:0]  len;        // random, may repeat
  randc bit [3:0]  id;         // cyclic: all 16 values before any repeats
  bit   [7:0]      limit;      // NOT random -- a state input to the solver
  rand  bit [7:0]  data [];    // the ARRAY SIZE is also solved for
  rand  Txn        child;      // recursed into if non-null and rand_mode is on
endclass
```

`randc` is only legal on integral types of 16 bits or fewer in most tools (the
solver keeps a permutation of the full value space). Use it for IDs, source
selection, opcode coverage — anywhere "hit everything before repeating" is the
goal.

## 2. Calling the solver

```systemverilog
Txn t = new();

if (!t.randomize())                 // ALWAYS check the return value
  $fatal(1, "randomize failed");

t.randomize() with { len inside {[64:128]}; };   // inline constraint
t.randomize(len);                   // randomize ONLY len; others are state
t.randomize(null);                  // solve constraints, randomize nothing
                                    //   (a pure constraint check)

std::randomize(a, b) with { a < b; };   // no class needed
```

`randomize()` returns 0 on failure and **leaves the object unchanged**. Silently
ignoring it produces a test that runs the same stimulus every time and passes
for the wrong reason. Wrap it:

```systemverilog
`define CHK_RAND(obj, cstr) \
  if (!obj.randomize() with cstr) \
    $fatal(1, "%s:%0d randomize failed", `__FILE__, `__LINE__)
```

## 3. Constraint blocks

```systemverilog
class Txn;
  rand bit [7:0] len, addr;
  rand bit [1:0] kind;
  bit [7:0]      max_len;

  constraint c_len {
    len inside {[1:max_len]};
    len % 4 == 0;
  }

  constraint c_kind {
    kind dist { 0 := 50, 1 := 30, [2:3] := 20 };
  }

  constraint c_align {
    (kind == 3) -> addr[1:0] == 2'b00;      // implication
    if (len > 64) addr < 128; else addr < 256;
  }

  constraint c_order { solve kind before len; }

  constraint c_arr { data.size() inside {[4:16]};
                     foreach (data[i]) data[i] < 200; }
endclass
```

Constraints are **declarative and simultaneous**, not sequential. All active
constraints across all blocks are handed to the solver at once; order in the
source is irrelevant.

### Operators available

```systemverilog
a inside {1, 2, [5:9], arr}
a dist {v := w, [lo:hi] := w, [lo:hi] :/ w}
cond -> expr                      // implication (cond false => no constraint)
if (cond) expr; else expr;
foreach (arr[i]) ...
unique {a, b, c}                  // all different
a.size() == n
solve x before y;                 // ordering hint (see below)
soft len == 64;                   // a default that a later constraint may override
disable soft len;
```

### `:=` vs `:/`

```systemverilog
kind dist { [1:4] := 10 };      // EACH of 1,2,3,4 has weight 10 -> total 40
kind dist { [1:4] :/ 10 };      // the RANGE has weight 10 -> each gets 2.5
```

Mixing them:

```systemverilog
x dist { 0 := 40, [1:10] :/ 40, 100 := 20 };
// P(0)=40%, P(each of 1..10)=4%, P(100)=20%
```

### `soft` constraints

```systemverilog
class Base;
  rand int len;
  constraint c { soft len == 64; }
endclass

t.randomize() with { len == 128; };   // the hard inline constraint wins
```

A `soft` constraint is dropped if it conflicts with a hard one, instead of
causing a failure. This is how a base class provides sensible defaults that
tests can override without `constraint_mode`.

## 4. `solve ... before` — distribution, not legality

```systemverilog
class A;
  rand bit x;
  rand bit [3:0] y;
  constraint c { x -> y == 0; }
endclass
```

Without ordering, the solver picks uniformly from the **solution space**: there
are 16 solutions with `x==0` (any `y`) and 1 with `x==1` (`y==0`), so
`P(x==1) = 1/17`.

```systemverilog
constraint c2 { solve x before y; }
```

Now the solver picks `x` first (uniformly: 50/50), then `y` given `x`. So
`P(x==1) = 1/2`.

`solve before` **never changes which solutions are legal** — only their
probabilities. It also costs solver time. Use it when a Boolean flag is being
starved, which is the common case.

## 5. Controlling randomization at run time

```systemverilog
t.c_len.constraint_mode(0);       // disable one constraint block
t.constraint_mode(0);             // disable ALL of this object's constraints
t.len.rand_mode(0);               // make `len` non-random (keeps its value)
t.rand_mode(0);                   // all variables non-random

if (t.c_len.constraint_mode()) ...    // query
```

## 6. `pre_randomize` / `post_randomize`

```systemverilog
class Txn;
  rand bit [7:0] len;
  bit [7:0]      max_len;
  bit [15:0]     crc;

  function void pre_randomize();
    max_len = get_current_limit();   // set solver INPUTS here
  endfunction

  function void post_randomize();
    crc = compute_crc(len);          // derive non-random fields here
  endfunction
endclass
```

`pre_randomize` runs before the solver and is where you update non-`rand` state
that constraints depend on. `post_randomize` runs after and is where you compute
derived values that would be expensive or impossible to constrain.

Both are called on the whole object tree, parent before child. If you override
them in a subclass, call `super.pre_randomize()`.

## 7. Common patterns

### Weighted scenario selection

```systemverilog
typedef enum { SHORT, LONG, JUMBO, ERR } scenario_e;

class Stim;
  rand scenario_e sc;
  rand int        len;

  constraint c_sc  { sc dist { SHORT := 50, LONG := 30, JUMBO := 15, ERR := 5 }; }
  constraint c_len {
    solve sc before len;
    (sc == SHORT) -> len inside {[1:64]};
    (sc == LONG)  -> len inside {[65:1500]};
    (sc == JUMBO) -> len inside {[1501:9000]};
    (sc == ERR)   -> len inside {0, [9001:65535]};
  }
endclass
```

### Random but reproducible addresses in a sparse map

```systemverilog
class AddrGen;
  rand bit [31:0] addr;
  bit [31:0] regions [$][2];      // {base, limit} pairs

  constraint c_in_region {
    foreach (regions[i])
      // "in at least one region" -- build the OR explicitly
      ;
  }
  // Simpler and faster: pick the region first, then the offset.
  rand int unsigned region_idx;
  rand bit [31:0]   offset;
  constraint c_pick {
    region_idx < regions.size();
    solve region_idx before offset;
    offset < (regions[region_idx][1] - regions[region_idx][0]);
  }
  function void post_randomize();
    addr = regions[region_idx][0] + offset;
  endfunction
endclass
```

The general lesson: **decompose a hard constraint into a choice followed by a
constrained offset.** Solvers handle that far better than a disjunction of
ranges, and the distribution is easier to reason about.

### Randomizing an array with a relationship

```systemverilog
class Sorted;
  rand int a[];
  constraint c_size { a.size() inside {[4:16]}; }
  constraint c_sort { foreach (a[i]) if (i > 0) a[i] > a[i-1]; }
  constraint c_rng  { foreach (a[i]) a[i] inside {[0:1000]}; }
endclass
```

### Randomizing a delay stream

```systemverilog
class Delays;
  rand int unsigned d[];
  constraint c {
    d.size() == 100;
    foreach (d[i]) d[i] dist { 0 := 70, [1:3] := 25, [4:20] := 5 };
  }
endclass
```

Back-to-back (`0`) must dominate, or you never test the full-throughput path.

## 8. Seeds and reproducibility

```systemverilog
$urandom(seed)          // seeds the thread's RNG and returns a value
$urandom_range(hi, lo)
obj.srandom(seed);      // seed an object's RNG
process::self().srandom(seed);
```

Every object and every process has its own RNG, seeded hierarchically from the
parent. That means adding a `$urandom` call in one component does **not**
perturb another component's stream — random stability. It also means that if you
want to reproduce a failure you need the *simulation* seed, which the tool prints
and accepts on the command line (`-sv_seed`).

Print the seed at the start of every run:

```systemverilog
initial $display("SEED=%0d", seed_from_plusarg);
```

## 9. Debugging a failed `randomize()`

When `randomize()` returns 0, the constraints are over-specified. Tactics:

1. Turn on the solver's failure report (`-solvefaildebug` in VCS,
   `-svseed`/`-messages` elsewhere). Modern solvers name the conflicting
   constraint set.
2. Disable constraint blocks one at a time with `constraint_mode(0)` until it
   solves — the last one you disabled is (part of) the conflict.
3. Check for a non-`rand` variable with an `X` or an out-of-range value: a
   constraint referencing `max_len` when `max_len` is `8'hxx` is unsatisfiable.
4. Check array sizes: `foreach (a[i]) a[i] < n` when `a.size()` is unconstrained
   and huge.
5. Watch for `randc` over a range narrower than the constraint allows.

The most common cause by far is (3) — a solver *input* that was never
initialized.
