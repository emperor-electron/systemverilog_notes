# Interfaces, Modports, Clocking Blocks, and Packages

## 1. Why interfaces

A bus with 12 signals connected through 5 levels of hierarchy means 12 port
declarations × 5 levels × 2 (declaration + connection) = 120 lines that all have
to agree. Adding a signal touches every one of them. An interface reduces that
to one declaration and one port per level.

```systemverilog
interface apb_if #(parameter int AW = 32, parameter int DW = 32)
                  (input logic pclk, input logic presetn);
  logic [AW-1:0] paddr;
  logic          psel, penable, pwrite;
  logic [DW-1:0] pwdata, prdata;
  logic          pready, pslverr;

  modport mst (
    output paddr, psel, penable, pwrite, pwdata,
    input  prdata, pready, pslverr,
    input  pclk, presetn
  );
  modport slv (
    input  paddr, psel, penable, pwrite, pwdata,
    output prdata, pready, pslverr,
    input  pclk, presetn
  );
  modport mon (
    input paddr, psel, penable, pwrite, pwdata,
           prdata, pready, pslverr, pclk, presetn
  );
endinterface
```

```systemverilog
module apb_master (apb_if.mst bus);  ... endmodule
module apb_slave  (apb_if.slv bus);  ... endmodule

// top
apb_if #(.AW(32), .DW(32)) bus (.pclk(clk), .presetn(rst_n));
apb_master u_m (.bus(bus));
apb_slave  u_s (.bus(bus));
```

## 2. Modports

A `modport` is a **view**: it names which signals are visible and in which
direction from a particular instance's perspective.

```systemverilog
modport mst (output paddr, input prdata, ...);
```

Without a modport, a module port declared `apb_if bus` sees every signal as
`inout` — which compiles, but gives up the direction checking that is most of
the value.

Modports can also export tasks, which lets the interface own the protocol:

```systemverilog
interface apb_if (...);
  ...
  task automatic write(input logic [AW-1:0] a, input logic [DW-1:0] d);
    @(posedge pclk);
    paddr <= a; pwdata <= d; pwrite <= 1'b1; psel <= 1'b1; penable <= 1'b0;
    @(posedge pclk);
    penable <= 1'b1;
    do @(posedge pclk); while (!pready);
    psel <= 1'b0; penable <= 1'b0;
  endtask

  modport tb (import write, import read, input pclk, presetn);
endinterface
```

Now a testbench holding `apb_if.tb` calls `bus.write(addr, data)` and the
protocol lives in one place. (Tasks in an interface are not synthesizable; this
is a testbench pattern.)

## 3. Clocking blocks **[V]**

A clocking block fixes the **sampling and driving times** of a set of signals
relative to a clock, which eliminates testbench/DUT races without any `#1`
hackery.

```systemverilog
interface axis_if #(parameter int DW = 32) (input logic clk, input logic rst_n);
  logic [DW-1:0] tdata;
  logic          tvalid, tready, tlast;

  clocking cb_src @(posedge clk);
    default input #1step output #1ns;
    output tdata, tvalid, tlast;
    input  tready;
  endclocking

  clocking cb_mon @(posedge clk);
    default input #1step;
    input tdata, tvalid, tready, tlast;
  endclocking

  modport src (clocking cb_src);
  modport mon (clocking cb_mon);
endinterface
```

| Directive | Meaning |
|---|---|
| `input #1step` | sample in the **Preponed** region — the value *before* any change at this edge, i.e. what a real flop would capture |
| `output #1ns` | drive 1 ns after the clock edge |
| `output #0` | drive in the Re-NBA region (after the DUT's NBA updates) |
| `default input #Ns output #Ms` | applies to all signals in the block |

Usage from a testbench:

```systemverilog
task automatic send(input logic [31:0] d);
  vif.cb_src.tdata  <= d;          // <= drives at the output skew
  vif.cb_src.tvalid <= 1'b1;
  @(vif.cb_src);                   // wait one clocking event
  while (!vif.cb_src.tready) @(vif.cb_src);
  vif.cb_src.tvalid <= 1'b0;
endtask
```

`@(cb)` waits for the clocking block's event. Reading `cb.sig` gives the
**sampled** value; writing `cb.sig <= v` schedules a drive at the output skew.
Because sampling happens before the edge and driving happens after, testbench
and DUT can never race.

`##N` inside a clocking domain means N clocking events:

```systemverilog
default clocking cb_src;    // declare one default per scope
...
##3;                        // wait 3 clock edges
```

## 4. Virtual interfaces **[V]**

Classes are dynamic and cannot contain static hierarchy, so a class-based
testbench reaches the DUT through a **virtual interface** — a handle to an
interface instance.

```systemverilog
class axis_driver;
  virtual axis_if.src vif;                  // a handle, may be null

  function new(virtual axis_if.src v);
    vif = v;
  endfunction

  task run();
    forever begin
      transaction t;
      mbx.get(t);
      vif.cb_src.tdata  <= t.data;
      vif.cb_src.tvalid <= 1'b1;
      @(vif.cb_src);
      ...
    end
  endtask
endclass
```

```systemverilog
// Top: connect the physical interface to the class world
module tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  axis_if #(.DW(32)) bus (.clk, .rst_n);
  dut u_dut (.bus(bus.dst));

  initial begin
    axis_driver drv = new(bus.src);         // virtual interface binding
    drv.run();
  end
endmodule
```

A null virtual interface is the single most common testbench crash. It happens
when the connection is made after the class starts running, or never. Guard it:

```systemverilog
function new(virtual axis_if.src v);
  if (v == null) $fatal(1, "axis_driver: null virtual interface");
  vif = v;
endfunction
```

## 5. Assertions inside an interface

Protocol checks belong with the protocol, not scattered through the DUT:

```systemverilog
interface axis_if #(parameter int DW = 32) (input logic clk, input logic rst_n);
  logic [DW-1:0] tdata;
  logic          tvalid, tready, tlast;

  // AXI-Stream rule: once TVALID is asserted it must stay asserted, and the
  // payload must not change, until TREADY is seen.
  property p_stable_payload;
    @(posedge clk) disable iff (!rst_n)
      (tvalid && !tready) |=> (tvalid && $stable(tdata) && $stable(tlast));
  endproperty
  a_stable_payload: assert property (p_stable_payload)
    else $error("AXIS: payload changed before handshake");

  property p_no_x;
    @(posedge clk) disable iff (!rst_n)
      tvalid |-> !$isunknown({tdata, tlast});
  endproperty
  a_no_x: assert property (p_no_x);
endinterface
```

Every instance of the interface, anywhere in the design, now carries the
checks — no `bind` needed, no duplication.

## 6. Interfaces and synthesis

Interfaces **are** synthesizable, with restrictions that vary by tool. The
reliably portable subset:

- signals (`logic`, packed types) and `modport` declarations,
- `parameter`s,
- continuous assignments,
- `generate` blocks.

Not portable into synthesis: tasks/functions in the interface, clocking blocks,
`virtual` interfaces, dynamic types. Those are testbench features.

Many teams sidestep the tool-support question entirely by using interfaces only
in the testbench and using **packed structs** for RTL bundling:

```systemverilog
package axis_pkg;
  typedef struct packed {
    logic [31:0] tdata;
    logic        tlast;
    logic        tvalid;
  } axis_fwd_t;                     // source -> sink
  // tready travels the other way, so it stays a separate port
endpackage

module stage (
  input  axis_pkg::axis_fwd_t in_fwd,
  output logic                in_ready,
  output axis_pkg::axis_fwd_t out_fwd,
  input  logic                out_ready
);
```

This gets most of the maintainability benefit (add a field in one place) with
zero tool-support risk, at the cost of the direction checking a modport gives.

## 7. Packages

```systemverilog
package riscv_pkg;

  localparam int XLEN = 32;

  typedef logic [XLEN-1:0] xlen_t;

  typedef enum logic [6:0] {
    OP_LOAD   = 7'b0000011,
    OP_IMM    = 7'b0010011,
    OP_AUIPC  = 7'b0010111,
    OP_STORE  = 7'b0100011,
    OP_REG    = 7'b0110011,
    OP_LUI    = 7'b0110111,
    OP_BRANCH = 7'b1100011,
    OP_JALR   = 7'b1100111,
    OP_JAL    = 7'b1101111,
    OP_SYSTEM = 7'b1110011
  } opcode_e;

  typedef struct packed {
    logic       reg_write;
    logic       mem_read;
    logic       mem_write;
    logic [3:0] alu_op;
  } ctrl_t;

  function automatic xlen_t sext_imm_i(input logic [31:0] instr);
    return {{20{instr[31]}}, instr[31:20]};
  endfunction

endpackage
```

### Importing

```systemverilog
import riscv_pkg::*;                  // wildcard: names are visible on demand
import riscv_pkg::opcode_e;           // explicit: one name
riscv_pkg::XLEN                       // scope resolution, no import

// Import in the module HEADER so parameters and ports can use the types:
module decoder import riscv_pkg::*; #(
  parameter int W = XLEN
) (
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);
```

A wildcard import does not immediately bring names into scope — it makes them
*available*. A locally declared name always wins, and two wildcard imports that
both provide the same name is an error only if you actually reference it.

### `export`

```systemverilog
package top_pkg;
  import base_pkg::*;
  export base_pkg::*;      // re-export, so importers of top_pkg see base too
endpackage
```

### Package rules that matter

- A package cannot contain hierarchy (no module instances, no `always` blocks).
- It **can** contain `let`, `typedef`, `parameter`/`localparam`, functions,
  tasks, classes, covergroups, and `sequence`/`property` declarations.
- Package items are elaborated once and shared — a `static` variable in a
  package is a global.
- Compile order matters: a package must be compiled before anything that
  imports it.

### `$unit` — avoid it

Anything declared outside any `module`/`package`/`interface` lands in the
anonymous compilation-unit scope, `$unit`. Its contents depend on how files were
grouped on the compiler command line, so a design that works with
`vlog a.sv b.sv` may fail with `vlog a.sv` + `vlog b.sv`.

```systemverilog
// defs.svh -- included into many files. Each inclusion may land in a
// DIFFERENT $unit, giving you multiple incompatible copies of the type.
typedef logic [7:0] byte_t;      // BAD

// defs_pkg.sv -- one definition, one scope, deterministic
package defs_pkg;
  typedef logic [7:0] byte_t;    // GOOD
endpackage
```

Put types in packages. Reserve `` `include `` for macro definitions.
