# System Tasks, File I/O, and DPI

## 1. Display family **[V]**

```systemverilog
$display("...")     // print + newline, values as of NOW
$write("...")       // no newline
$displayb/o/h/d     // default radix for %v-less arguments
$strobe("...")      // print at the END of the time step (Postponed region)
$monitor("...")     // print whenever any argument changes; only ONE active
$monitoron  $monitoroff
```

`$display` in an `always_ff` prints the **old** value of a non-blocking target,
because it runs in Active and the update happens in NBA:

```systemverilog
always_ff @(posedge clk) begin
  q <= d;
  $display("q=%0d", q);      // prints the PREVIOUS q
  $strobe ("q=%0d", q);      // prints the NEW q
end
```

Use `$strobe` when you want settled values.

### Format specifiers

| Spec | Prints |
|---|---|
| `%b %o %d %h` | binary / octal / decimal / hex |
| `%0d` | decimal with no leading padding (**use this**) |
| `%5d %-5d` | width 5, right / left justified |
| `%c` | one character from the low 8 bits |
| `%s` | string |
| `%t` | time, formatted per `$timeformat` |
| `%e %f %g` | real in exponential / fixed / shortest form |
| `%v` | net strength |
| `%m` | the **hierarchical path** of the current scope |
| `%l` | library/cell info |
| `%p` | "pretty print" — works on structs, arrays, and class objects |
| `%%` | a literal % |

`%p` is the fastest way to dump a complex object:

```systemverilog
typedef struct packed { logic [3:0] op; logic [7:0] addr; } cmd_t;
cmd_t c = '{op:4'h3, addr:8'hA0};
$display("%p", c);        // '{op:'h3, addr:'ha0}
$display("%p", my_queue); // '{'{...}, '{...}}
```

`%m` is the fastest way to find out where a message came from:

```systemverilog
$display("[%m] entering state %s", state.name());
// [tb.dut.u_ctrl] entering state RUN
```

### Severity tasks

```systemverilog
$info   ("informational");
$warning("something odd: %0d", x);
$error  ("test failed: exp=%h got=%h", e, g);      // increments the error count
$fatal  (1, "unrecoverable: %s", msg);             // finishes with that exit code
```

These integrate with the simulator's message counting and filtering, unlike a
bare `$display`. Use them.

### Formatting into a string

```systemverilog
string s;
s = $sformatf("addr=%h data=%h", a, d);      // returns a string
$sformat(s, "addr=%h", a);                   // writes into s
$swrite(s, "addr=%h", a);                    // same
```

`$sformatf` is what you want inside a class's `to_str()`.

## 2. Simulation control and time **[V]**

```systemverilog
$finish;  $finish(1);      // end simulation (1 = print stats)
$stop;                     // break to the interactive prompt
$exit;                     // end a program block

$time                      // 64-bit, in the current timeunit
$stime                     // 32-bit
$realtime                  // real
$timeformat(-9, 3, " ns", 12);   // units, precision, suffix, min width
```

```systemverilog
$timeformat(-9, 3, " ns", 10);
$display("%t", $time);     //  "   12.500 ns"
```

## 3. Randomization **[V]**

```systemverilog
$random           // 32-bit SIGNED, legacy, do not use in new code
$random(seed)
$urandom          // 32-bit UNSIGNED, thread-local RNG -- use this
$urandom(seed)
$urandom_range(hi, lo)    // inclusive; lo defaults to 0
$dist_uniform(seed, lo, hi)
$dist_normal(seed, mean, sd)
$dist_exponential(seed, mean)
$dist_poisson  $dist_chi_square  $dist_t  $dist_erlang
```

`$urandom` has **random stability**: each process and object has its own
generator seeded from its parent, so adding a call in one component does not
shift another component's stream. `$random` uses one global generator and does
not. Use `$urandom`.

## 4. File I/O **[V]**

```systemverilog
int fd;
fd = $fopen("out.log", "w");         // "r" "w" "a" "r+" "w+" "a+"
if (fd == 0) $fatal(1, "cannot open");

$fdisplay(fd, "value = %0d", x);
$fwrite  (fd, "%h\n", y);
$fflush  (fd);
$fclose  (fd);

// Reading
int  fdr = $fopen("in.txt", "r");
int  code;
string line;
logic [31:0] a, d;
while (!$feof(fdr)) begin
  code = $fgets(line, fdr);                 // read a line
  code = $sscanf(line, "%h %h", a, d);      // parse it
  if (code == 2) apply(a, d);
end
$fclose(fdr);

// Direct scan
code = $fscanf(fd, "%h %h\n", a, d);
$ferror(fd, msg);  $rewind(fd);  $fseek(fd, off, op);  $ftell(fd);
$fgetc(fd);  $ungetc(c, fd);  $fread(buf, fd);
```

`$fopen` with a **multichannel descriptor** (no mode argument) returns a bitmask
so one `$fdisplay` can write to several files plus stdout:

```systemverilog
int mcd = $fopen("a.log") | $fopen("b.log") | 32'h1;   // bit 0 = stdout
$fdisplay(mcd, "goes to all three");
```

### Memory load/store

```systemverilog
logic [31:0] mem [0:1023];

$readmemh("image.hex", mem);              // whole array
$readmemh("image.hex", mem, 16);          // starting at index 16
$readmemh("image.hex", mem, 16, 271);     // a range
$readmemb("image.bin", mem);
$writememh("dump.hex", mem);
$writememb("dump.bin", mem);
```

File format: whitespace-separated values, `//` and `/* */` comments allowed, and
`@ADDR` to jump to an address:

```
// boot rom
@0000
DEADBEEF 00000000 12345678
@0100
CAFEBABE
```

`$readmemh` on an FPGA is synthesizable for ROM/RAM initialization — it is the
standard way to preload a boot image.

## 5. Query and math functions

### Elaboration-time queries **[S]**

```systemverilog
$bits(expr_or_type)       // bit width
$clog2(n)                 // ceil(log2(n)).  $clog2(1)==0 -- guard it!
$size(arr)                // elements in the (first) dimension
$size(arr, d)             // elements in dimension d
$left(arr, d) $right(arr, d) $low(arr, d) $high(arr, d) $increment(arr, d)
$dimensions(arr)  $unpacked_dimensions(arr)
$typename(expr)           // a string naming the type -- great for debug
```

```systemverilog
localparam int AW = $clog2(DEPTH);
logic [$bits(my_struct_t)-1:0] flat;
$display("%s", $typename(x));
```

### Bit-vector queries **[S]**

```systemverilog
$countones(v)     $countbits(v, 1)     $countbits(v, 0, x)
$onehot(v)        $onehot0(v)          $isunknown(v)
```

`$isunknown(v)` is the RTL-friendly `X` check — use it in assertions:

```systemverilog
assert property (@(posedge clk) valid |-> !$isunknown(data));
```

### Math **[V]**

```systemverilog
$ceil $floor $sqrt $pow $exp $ln $log10 $fabs
$sin $cos $tan $asin $acos $atan $atan2 $hypot
$sinh $cosh $tanh $asinh $acosh $atanh
$itor $rtoi $realtobits $bitstoreal $shortrealtobits $bitstoshortreal
```

These operate on `real` and are simulation-only — except in a
`localparam` initializer, where they run at elaboration and the result is a
constant. See [docs/18](18-fixed-point-arithmetic.md#7-a-complete-parameterized-package).

## 6. Command-line plusargs **[V]**

```systemverilog
if ($test$plusargs("verbose")) verbose = 1;

int n;
if ($value$plusargs("num_txn=%d", n))  num = n;
else                                    num = 100;

string f;
void'($value$plusargs("cfg=%s", f));
```

```bash
vsim tb +verbose +num_txn=5000 +cfg=stress.cfg
```

This is the standard way to parameterize a test run without recompiling.

## 7. DPI — calling C from SystemVerilog **[V]**

### Import

```systemverilog
import "DPI-C" function int      c_add(input int a, input int b);
import "DPI-C" function void     c_init(input string cfg);
import "DPI-C" context function int c_cb_user();   // may call back into SV
import "DPI-C" task              c_long_task();    // may consume SV time
import "DPI-C" function chandle  c_alloc(input int n);
import "DPI-C" pure function int c_square(input int x);  // no side effects,
                                                          // optimizable
```

```c
#include "svdpi.h"
int c_add(int a, int b) { return a + b; }
```

| Qualifier | Meaning |
|---|---|
| `pure` | no side effects, result depends only on arguments. The tool may cache/elide calls. |
| `context` | the function needs to know its calling SV scope (required if it calls an exported SV function or uses `svGetScope`) |
| neither | the default: has side effects, no callbacks |

### Type mapping

| SystemVerilog | C |
|---|---|
| `byte` | `char` |
| `shortint` | `short int` |
| `int` | `int` |
| `longint` | `long long` |
| `real` | `double` |
| `shortreal` | `float` |
| `string` | `const char*` |
| `chandle` | `void*` |
| `bit` | `svBit` (`unsigned char`) |
| `logic`/`reg` | `svLogic` |
| `bit [N-1:0]` | `svBitVecVal*` (packed, 32 bits per word) |
| `logic [N-1:0]` | `svLogicVal*` (aval/bval pairs) |
| open array `int []` | `svOpenArrayHandle` |

**Use 2-state types across DPI where you can.** A `logic [31:0]` becomes an
`svLogicVal` array with separate a/b words, which is fiddly; a `bit [31:0]`
becomes a plain `unsigned int`.

### Export — calling SystemVerilog from C

```systemverilog
export "DPI-C" function sv_notify;

function void sv_notify(input int code);
  $display("C says %0d", code);
endfunction
```

```c
extern void sv_notify(int code);      /* declared by the generated header */
void c_worker(void) { sv_notify(42); }
```

An exported function is called in the context of the SV scope that was active
when the importing (`context`) function was called. That is why callbacks
require `context`.

### Passing arrays

```systemverilog
import "DPI-C" function void c_process(input bit [31:0] din [],
                                       output bit [31:0] dout []);
```

```c
#include "svdpi.h"
void c_process(const svOpenArrayHandle din, svOpenArrayHandle dout) {
  int lo = svLow(din, 1), hi = svHigh(din, 1);
  for (int i = lo; i <= hi; i++) {
    uint32_t v;
    svGetBitArrElemVecVal((svBitVecVal*)&v, din, i);
    v = v * 2;
    svPutBitArrElemVecVal(dout, (svBitVecVal*)&v, i);
  }
}
```

For bulk data the faster route is a `chandle` to a C-owned buffer plus a few
accessor functions, avoiding per-element marshalling entirely.

### The canonical use: a golden reference model

```systemverilog
// Compare RTL against a C model of the same algorithm
import "DPI-C" function int unsigned c_crc32(input int unsigned crc,
                                             input byte unsigned data);

always @(posedge clk)
  if (valid)
    assert (dut_crc === c_crc32(prev_crc, data))
      else $error("CRC mismatch at %t", $time);
```

This is DPI's best justification: the reference implementation already exists in
C (a codec, a cipher, a floating-point library, an ISA simulator), and
reimplementing it in SystemVerilog would just create a second thing to debug.

### Build

```bash
# Questa
vlog -sv tb.sv dut.sv
gcc -shared -fPIC -o libdpi.so dpi.c -I$QUESTA_HOME/include
vsim -sv_lib libdpi tb

# VCS
vcs -sverilog tb.sv dut.sv dpi.c

# Verilator
verilator --cc --exe --build dut.sv tb.cpp dpi.c
```

## 8. VPI / DPI / PLI

| Interface | Direction | Use |
|---|---|---|
| **DPI-C** | both | function calls. **The default choice.** |
| VPI (PLI 2.0) | C → SV | introspect and modify the design: walk the hierarchy, register callbacks on value changes, add custom system tasks |
| PLI 1.0 (`tf_`/`acc_`) | C → SV | obsolete |

Use DPI unless you specifically need to *traverse the design* or hook value
changes — that is VPI territory (waveform dumpers, coverage collectors, custom
debug tools).
