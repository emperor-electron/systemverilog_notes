# Arrays, Structs, Enums, Unions

## 1. Packed vs unpacked — the central distinction

```systemverilog
logic [7:0] packed_dims name [3:0] unpacked_dims;
//    ^^^^^^^^^^^^^^^^^^      ^^^^^^^^^^^^^^^^^^
//    before the name          after the name
```

| | **Packed** | **Unpacked** |
|---|---|---|
| Bit layout | guaranteed contiguous | tool-defined, may be padded |
| Is an integral value | yes — can do arithmetic on the whole thing | no |
| Bit/part select across the whole object | yes | no |
| Can contain `real`, `string`, dynamic arrays | no | yes |
| Copy assignment | bit-for-bit | element-wise, types must match |
| Typical hardware | a bus, a bundled struct on a port | a memory, a register file |
| Declared | before the name | after the name |

```systemverilog
logic [31:0]      bus;              // 32-bit packed vector
logic [3:0][7:0]  lanes;            // 32 bits; lanes[2] is an 8-bit slice
logic [7:0]       mem   [0:1023];   // 1024 separate bytes -- a RAM
logic [3:0][7:0]  fifo  [0:15];     // 16 entries, each 4 lanes of 8 bits
logic             flags [0:7];      // 8 separate 1-bit variables (rarely useful)
```

`lanes` above is one 32-bit integral value that you can add, shift, or compare;
`mem` is not. That is the whole distinction, and it is why memories are unpacked
(the tool can then map them to a RAM macro) and buses are packed.

### Dimension ordering

```systemverilog
logic [A][B] x [C][D];
//     ^  ^     ^  ^
//     3  4     1  2      <- index order: x[c][d][a][b]
```

The **leftmost** dimension in each group varies slowest. Read it as: `x` is a
`C`-element array, of `D`-element arrays, of `A`-element packed arrays, of
`B`-bit packed vectors.

```systemverilog
logic [3:0][7:0] m [0:1][0:2];
m[1][2][3][7]         // a single bit
m[1][2][3]            // 8 bits
m[1][2]               // 32 bits (packed part)
m[1]                  // 3 x 32 bits -- an unpacked slice, assignable as a whole
```

### Ranges: `[N-1:0]` vs `[0:N-1]`

- **Packed** dimensions are conventionally `[MSB:LSB]` = `[N-1:0]`, so that
  bit `i` has weight `2^i`.
- **Unpacked** dimensions are conventionally `[0:N-1]` (or the `[N]` shorthand,
  which means `[0:N-1]`), so that index 0 is the first element.

Mixing these up produces code that works but reads backwards. Pick the
convention and hold it.

## 2. Selects

```systemverilog
v[3]                 // bit select
v[7:4]               // part select -- bounds must be CONSTANT
v[i +: 4]            // indexed part select: 4 bits starting at i, upward
v[i -: 4]            // 4 bits ending at i, downward
```

`+:`/`-:` are the only way to do a **variable** part select, and they are what
you want for byte lanes, shift registers, and register-file reads:

```systemverilog
// Extract byte `n` from a word
assign byte_out = word[n*8 +: 8];

// Write-enable per byte lane
always_ff @(posedge clk)
  for (int i = 0; i < 4; i++)
    if (be[i]) mem[addr][i*8 +: 8] <= wdata[i*8 +: 8];
```

Both bounds of a `+:`/`-:` select produce a **constant width**, which is what
makes it synthesizable — the hardware is a barrel shifter (or a mux tree), and
the width is fixed.

### Concatenation and replication

```systemverilog
{a, b, c}            // concatenation. ALWAYS UNSIGNED. Self-determined width.
{4{a}}               // replication
{2{a, b}}            // == {a, b, a, b}
{a, {3{1'b0}}}       // mixed
{>>{a, b}}           // stream left-to-right (pack)
{<<{v}}              // stream right-to-left -- reverses BIT order
{<<8{v}}             // reverse in 8-bit chunks -- byte swap!
```

Streaming operators are the idiomatic endian swap:

```systemverilog
logic [31:0] be, le;
assign le = {<<8{be}};          // byte-reverse a 32-bit word
// equivalent to: {be[7:0], be[15:8], be[23:16], be[31:24]}
```

And the idiomatic pack/unpack between a struct and a byte stream:

```systemverilog
hdr_t h;
byte  stream[];
stream = {>>{h}};        // pack the struct into bytes
h      = {>>{stream}};   // unpack
```

## 3. Structs

### Packed structs — the RTL workhorse

```systemverilog
typedef struct packed {
  logic [3:0] opcode;      // MSBs
  logic [1:0] mode;
  logic       enable;      // LSB
} ctrl_t;                  // 7 bits total
```

A packed struct **is** a 7-bit vector. You can:

```systemverilog
ctrl_t c;
c = 7'h41;                        // assign a raw pattern
c = '{opcode:4'h4, mode:2'b00, enable:1'b1};   // assign by field
c.opcode = 4'h5;                  // field access
$display("%b", c);                // treat as a vector
logic [6:0] raw = c;              // implicit, widths match
c = ctrl_t'(some_7bit_value);     // explicit reinterpret cast
```

This is why packed structs are the right way to carry a bundled control bus
through a port: named field access inside, a plain vector at the boundary.

```systemverilog
// A whole pipeline stage as one registered struct
typedef struct packed {
  logic        valid;
  logic [31:0] pc;
  logic [31:0] instr;
  ctrl_t       ctrl;
} stage_t;

stage_t s_q, s_d;
always_ff @(posedge clk)
  if (!rst_n) s_q <= '0;          // '0 fills the entire struct
  else        s_q <= s_d;
```

`s_q <= '0` zeroing an arbitrarily nested struct is one of the best
maintainability features in the language — add a field and the reset still
covers it.

### Unpacked structs **[V]**

```systemverilog
typedef struct {
  string   name;
  int      data[];      // dynamic array member -- only legal unpacked
  real     weight;
} record_t;
```

Use these in testbenches. They cannot be used as a single integral value and
cannot cross a port as a vector.

### Assignment patterns

```systemverilog
ctrl_t c;
c = '{opcode: 4'h1, mode: 2'b10, enable: 1'b0};   // by name
c = '{4'h1, 2'b10, 1'b0};                         // positional
c = '{default: '0};                               // everything zero
c = '{default: '0, enable: 1'b1};                 // zero except one field
c = '{logic: '0};                                 // by type
```

`'{default: '0, ...}` is the idiom for "set one field, zero the rest" and it is
what you want in a decoder's default assignment.

## 4. Unions

```systemverilog
// Packed union: all members must be the SAME WIDTH. Bit-aliased.
typedef union packed {
  logic [31:0]      word;
  logic [3:0][7:0]  bytes;
  struct packed { logic [15:0] hi, lo; } halves;
} word_u;

word_u w;
w.word = 32'hDEAD_BEEF;
w.bytes[0];            // 8'hEF
w.halves.hi;           // 16'hDEAD
```

Packed unions are legal in synthesis and are the clean way to express "this
32-bit register is also a set of fields". Every member is a view of the same
bits, so writing one writes all.

```systemverilog
// Unpacked union: no width requirement, no type checking.  [V]
typedef union { int i; real r; } any_u;

// Tagged union: the tag is stored and checked at run time.  [V]
typedef union tagged {
  void Invalid;
  int  Valid;
} maybe_int;

maybe_int m = tagged Valid (42);
case (m) matches
  tagged Valid .n : $display("got %0d", n);
  tagged Invalid  : $display("nothing");
endcase
```

## 5. Enums

```systemverilog
typedef enum logic [2:0] {
  IDLE = 3'b001,
  RUN  = 3'b010,
  DONE = 3'b100
} state_e;
```

The base type after `enum` controls **encoding and width**. Without it the base
is `int` (32-bit signed), which is almost never what you want in RTL.

| Encoding | Declaration | When |
|---|---|---|
| Binary | `enum logic [1:0] {A,B,C,D}` | few states, area-critical |
| One-hot | `enum logic [3:0] {A=1,B=2,C=4,D=8}` | FPGA, fast next-state logic |
| Gray | explicit values | CDC pointers, low-power |
| Let the tool choose | `enum logic [$clog2(N)-1:0] {...}` | usually fine |

Most synthesis tools re-encode FSM states automatically unless told otherwise,
so explicit one-hot values are more about *documenting intent* and about
enabling `unique case` than about forcing the encoding.

### Value assignment rules

```systemverilog
typedef enum { A, B, C } e1;              // 0, 1, 2
typedef enum { A=3, B, C } e2;            // 3, 4, 5    (continues from the last)
typedef enum { A=1, B=1 } e3;             // ILLEGAL: duplicate values
typedef enum logic[1:0] { A=2'b00, B=2'b01, C=2'b10, D=2'b11 } e4;
typedef enum { R[3] } e5;                 // R0, R1, R2
typedef enum { R[1:3] } e6;               // R1, R2, R3
typedef enum { R[2] = 5 } e7;             // R0=5, R1=6
```

### Strong typing

An enum variable accepts: another value of the *same* enum type, or an explicit
cast. It does **not** accept a bare integer:

```systemverilog
state_e s;
s = RUN;              // OK
s = 3'b010;           // ERROR
s = state_e'(3'b010); // OK -- unchecked cast
$cast(s, x);          // OK -- checked at run time, returns 0 if invalid
```

This is precisely why enums are the right FSM state type: the compiler stops
you from assigning a value that is not a state, and `$cast` lets you check a
value that came from outside.

Assigning through a cast does **not** validate. `state_e'(3'b111)` produces a
state variable holding `3'b111`, which `.name()` will report as `""`. Use that
in your default branch:

```systemverilog
default: begin
  $error("illegal state %b (%s)", state, state.name());
  next = IDLE;
end
```

### Methods

```systemverilog
s.first()     // first enum value
s.last()
s.next()      // next value, wraps
s.next(2)
s.prev()
s.num()       // number of members
s.name()      // string name; "" if the value is not a member
```

Iterate over all values:

```systemverilog
state_e s;
s = s.first();
repeat (s.num()) begin
  $display("%s = %b", s.name(), s);
  s = s.next();
end
```

## 6. Dynamic arrays, queues, associative arrays **[V]**

These are **not synthesizable**. They are the testbench's data structures.

### Dynamic array

```systemverilog
int da[];
da = new[16];                 // allocate, elements are 0
da = new[32](da);             // resize, copying the old contents
da.size();
da.delete();                  // free
```

### Queue

```systemverilog
int q[$];                     // unbounded
int b[$:7];                   // bounded: max 8 elements

q.push_back(x);   q.push_front(x);
x = q.pop_front(); x = q.pop_back();
q.insert(idx, x); q.delete(idx); q.delete();
q.size();  q[0];  q[$];  q[1:3];   // $ is the last index
q = {};                       // clear
q = {q, x};                   // append (slower than push_back)
q = {q[0:2], q[4:$]};         // remove element 3
```

Queues are the right type for a scoreboard's expected-value FIFO, for a
transaction history, and for a driver's pending list.

### Associative array

```systemverilog
int    aa [string];           // string-indexed
bit[7:0] mem [bit[31:0]];     // sparse memory model -- the killer use case
int    w  [*];                // wildcard index type

aa["key"] = 5;
if (aa.exists("key")) ...
aa.delete("key");  aa.delete();
aa.num();  aa.size();
aa.first(k);  aa.last(k);  aa.next(k);  aa.prev(k);   // return 0 when exhausted

string k;
if (aa.first(k))
  do $display("%s = %0d", k, aa[k]);
  while (aa.next(k));
```

A sparse associative memory model lets you model a 64-bit address space without
allocating it — essential for a processor testbench.

## 7. Array methods **[V]**

```systemverilog
// Reductions
a.sum()  a.product()  a.and()  a.or()  a.xor()
a.min()  a.max()                          // returns a QUEUE of one element
a.unique()  a.unique_index()

// Locators -- all return a queue
a.find(x)          with (x > 3)
a.find_first(x)    with (x.valid)
a.find_last(x)
a.find_index(x)    with (x == target)
a.find_first_index / find_last_index

// Ordering (in place)
a.sort();          a.sort(x) with (x.key);
a.rsort();  a.reverse();  a.shuffle();
```

The `with` clause uses `item` as the implicit iterator name (or you can bind
your own, as in `a.find(x) with (x > 3)`).

**The `sum()` width trap:**

```systemverilog
byte v[] = '{100, 100, 100};
v.sum()                          // 44  -- accumulates in `byte`
v.sum() with (int'(item))        // 300 -- accumulates in `int`
```

The accumulator type is the **element type**, not something wide enough. Always
cast inside the `with` for anything that could overflow. Same applies to
`product()`.

Counting with `sum()` is a common idiom — note the cast:

```systemverilog
int n_valid = pkts.sum() with (item.valid ? 1 : 0);
```

## 8. `foreach`

```systemverilog
foreach (mem[i])        ...           // one dimension
foreach (m[i, j])       ...           // two dimensions, one foreach
foreach (m[i])          foreach (m[i][j]) ...   // nested, equivalent
foreach (x[,j])         ...           // skip a dimension
```

`foreach` gets the bounds from the array declaration, so it is correct by
construction and works on `[0:N-1]` and `[N-1:0]` alike. In synthesizable code
it must be over a **static** array; the tool unrolls it.

```systemverilog
// Synthesizable: per-byte write enable
always_ff @(posedge clk)
  foreach (be[i])
    if (be[i]) mem[addr][i*8 +: 8] <= wdata[i*8 +: 8];
```
