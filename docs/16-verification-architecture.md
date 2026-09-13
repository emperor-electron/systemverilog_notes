# Testbench Architecture **[V]**

How the pieces from docs 09–15 fit into a working testbench. This is the
layered architecture that UVM formalizes, written in plain SystemVerilog so the
structure is visible.

## 1. The layers

```
  ┌─────────────────────────────────────────────────────────┐
  │  Test          picks the scenario, sets constraints     │
  ├─────────────────────────────────────────────────────────┤
  │  Environment   instantiates and connects everything      │
  ├──────────────┬──────────────┬───────────────────────────┤
  │  Generator   │  Scoreboard  │  Coverage                  │
  │  (stimulus)  │  (checking)  │  (measurement)             │
  ├──────────────┼──────────────┴───────────────────────────┤
  │  Driver      │  Monitor                                  │
  ├──────────────┴───────────────────────────────────────────┤
  │  Virtual interface  →  physical interface  →  DUT        │
  └───────────────────────────────────────────────────────────┘
```

| Component | Responsibility | Rule |
|---|---|---|
| **Transaction** | one unit of work, plus constraints | no timing, no interface access |
| **Generator** | creates and randomizes transactions | never touches signals |
| **Driver** | converts a transaction into pin wiggles | never checks anything |
| **Monitor** | converts pin wiggles back into transactions | **passive** — never drives |
| **Scoreboard** | compares observed against expected | never touches signals |
| **Coverage** | samples what actually happened | passive |
| **Environment** | wiring | no test-specific logic |
| **Test** | scenario selection, factory overrides | no wiring |

The separation that matters most: **the monitor must be independent of the
driver.** If the scoreboard's "expected" comes from the same object the driver
sent, a driver bug is invisible. The monitor reconstructs transactions from the
wires, so a driver that sends the wrong thing produces a mismatch.

## 2. Transaction

```systemverilog
class Txn;
  typedef enum { READ, WRITE } kind_e;

  rand kind_e        kind;
  rand bit [31:0]    addr;
  rand bit [31:0]    data;
  rand int unsigned  delay;      // pre-transaction idle

  // Non-random: filled in by the monitor
  bit [31:0] rdata;
  bit        error;
  time       t_start, t_end;

  constraint c_align { addr[1:0] == 2'b00; }
  constraint c_delay { delay dist { 0 := 70, [1:3] := 25, [4:20] := 5 }; }

  function Txn clone();
    Txn t = new();
    t.kind = kind;  t.addr = addr;  t.data = data;  t.delay = delay;
    t.rdata = rdata;  t.error = error;
    return t;
  endfunction

  function string to_str();
    return $sformatf("%s addr=%08h data=%08h%s",
                     kind.name(), addr,
                     (kind == WRITE) ? data : rdata,
                     error ? " ERR" : "");
  endfunction

  function bit compare(Txn o);
    return (kind == o.kind) && (addr == o.addr) &&
           ((kind == WRITE) || (rdata === o.rdata));   // === catches X
  endfunction
endclass
```

Note `===` in `compare()`. With `==`, an `X` in `rdata` makes the comparison
return `X`, which `if` treats as false — so it "works", but you learn nothing
about *why*. With `===` the X is a first-class mismatch you can print.

## 3. Driver

```systemverilog
class Driver;
  virtual apb_if.mst  vif;
  mailbox #(Txn)      req_mbx;
  mailbox #(Txn)      done_mbx;    // optional: completion notification
  int                 n_sent;

  function new(virtual apb_if.mst v, mailbox #(Txn) m);
    if (v == null) $fatal(1, "Driver: null virtual interface");
    vif     = v;
    req_mbx = m;
  endfunction

  task run();
    reset();
    forever begin
      Txn t;
      req_mbx.get(t);
      repeat (t.delay) @(vif.cb);
      t.t_start = $time;
      drive(t);
      t.t_end   = $time;
      n_sent++;
      if (done_mbx != null) done_mbx.put(t);
    end
  endtask

  protected task reset();
    vif.cb.psel    <= 1'b0;
    vif.cb.penable <= 1'b0;
    @(posedge vif.presetn);
    @(vif.cb);
  endtask

  protected task drive(Txn t);
    // SETUP phase
    vif.cb.paddr   <= t.addr;
    vif.cb.pwrite  <= (t.kind == Txn::WRITE);
    vif.cb.pwdata  <= t.data;
    vif.cb.psel    <= 1'b1;
    vif.cb.penable <= 1'b0;
    @(vif.cb);
    // ACCESS phase
    vif.cb.penable <= 1'b1;
    do @(vif.cb); while (!vif.cb.pready);
    // IDLE
    vif.cb.psel    <= 1'b0;
    vif.cb.penable <= 1'b0;
  endtask
endclass
```

Everything goes through `vif.cb` (the clocking block), so the driver cannot race
the DUT. The driver **does not check `prdata`** — that is the monitor's job.

## 4. Monitor

```systemverilog
class Monitor;
  virtual apb_if.mon vif;
  mailbox #(Txn)     out_mbx;
  int                n_seen;

  function new(virtual apb_if.mon v, mailbox #(Txn) m);
    if (v == null) $fatal(1, "Monitor: null virtual interface");
    vif     = v;
    out_mbx = m;
  endfunction

  task run();
    forever begin
      Txn t = new();
      // Wait for the SETUP phase
      do @(vif.cb); while (!(vif.cb.psel && !vif.cb.penable));
      t.kind = vif.cb.pwrite ? Txn::WRITE : Txn::READ;
      t.addr = vif.cb.paddr;
      t.data = vif.cb.pwdata;
      t.t_start = $time;
      // Wait for the ACCESS phase to complete
      do @(vif.cb); while (!(vif.cb.penable && vif.cb.pready));
      t.rdata = vif.cb.prdata;
      t.error = vif.cb.pslverr;
      t.t_end = $time;
      n_seen++;
      out_mbx.put(t);
    end
  endtask
endclass
```

The monitor observes **only** the interface. It has no handle to the driver, no
knowledge of what was requested, and it would work identically against a
different driver or against real traffic.

## 5. Scoreboard with a reference model

```systemverilog
class Scoreboard;
  mailbox #(Txn) in_mbx;
  bit [31:0]     model [bit [31:0]];    // associative: a sparse memory model
  int            n_checked, n_errors;

  task run();
    forever begin
      Txn t;
      in_mbx.get(t);
      check(t);
    end
  endtask

  function void check(Txn t);
    n_checked++;
    case (t.kind)
      Txn::WRITE: begin
        model[t.addr] = t.data;
      end
      Txn::READ: begin
        bit [31:0] exp = model.exists(t.addr) ? model[t.addr] : 32'h0;
        if (t.rdata !== exp) begin
          n_errors++;
          $error("MISMATCH @%08h: exp=%08h got=%08h  (%s)",
                 t.addr, exp, t.rdata, t.to_str());
        end
      end
    endcase
  endfunction

  function void report();
    $display("Scoreboard: %0d checked, %0d errors", n_checked, n_errors);
    if (n_errors != 0) $fatal(1, "TEST FAILED");
  endfunction
endclass
```

An associative array indexed by address models a full 32-bit memory without
allocating 4 GB. It is the single most useful testbench data structure.

### Out-of-order scoreboards

When responses can return out of order, key the expected queue by transaction
ID:

```systemverilog
class OooScoreboard;
  Txn pending [bit [7:0]];          // by ID

  function void expect_txn(Txn t);
    if (pending.exists(t.id)) $error("duplicate outstanding ID %0h", t.id);
    pending[t.id] = t;
  endfunction

  function void observe(Txn r);
    Txn e;
    if (!pending.exists(r.id)) begin
      $error("response for unknown ID %0h", r.id);
      return;
    end
    e = pending[r.id];
    pending.delete(r.id);
    if (!e.compare(r)) $error("mismatch: exp %s got %s", e.to_str(), r.to_str());
  endfunction

  function void report();
    foreach (pending[id]) $error("never completed: ID %0h", id);
  endfunction
endclass
```

The `report()` catch for never-completed transactions is essential — a dropped
transaction is otherwise invisible, because nothing ever mismatches.

## 6. Environment

```systemverilog
class Env;
  virtual apb_if vif;

  Generator  gen;
  Driver     drv;
  Monitor    mon;
  Scoreboard scb;
  Coverage   cov;

  mailbox #(Txn) gen2drv = new(8);      // bounded: backpressure
  mailbox #(Txn) mon2scb = new();

  function new(virtual apb_if v);
    vif = v;
    gen = new(gen2drv);
    drv = new(v.mst, gen2drv);
    mon = new(v.mon, mon2scb);
    scb = new();
    cov = new();
    scb.in_mbx = mon2scb;
  endfunction

  task run(int n);
    fork
      gen.run(n);
      drv.run();
      mon.run();
      scb.run();
      cov_loop();
    join_none

    wait (scb.n_checked == n);
    #1us;                               // drain
    disable fork;
  endtask

  task cov_loop();
    forever begin
      Txn t;
      mon2scb.peek(t);                  // peek, do not consume
      cov.sample(t);
      @(posedge vif.pclk);
    end
  endtask

  function void report();
    scb.report();
    $display("Coverage: %.1f%%", cov.cg.get_coverage());
  endfunction
endclass
```

Note `mon2scb` is a bounded-by-nature mailbox feeding **two** consumers. A
cleaner structure gives each subscriber its own mailbox and has the monitor
broadcast — that is what UVM's analysis ports do:

```systemverilog
class Monitor;
  mailbox #(Txn) subscribers [$];

  function void connect(mailbox #(Txn) m);
    subscribers.push_back(m);
  endfunction

  task publish(Txn t);
    foreach (subscribers[i]) subscribers[i].put(t.clone());   // clone!
  endtask
endclass
```

The `clone()` matters: without it every subscriber holds the same handle, and
one subscriber modifying the transaction corrupts the others' view.

## 7. Test

```systemverilog
class BaseTest;
  Env env;

  virtual function void configure();   // override to change the scenario
  endfunction

  task run(virtual apb_if vif, int n = 100);
    env = new(vif);
    configure();
    env.run(n);
    env.report();
  endtask
endclass

class BurstTest extends BaseTest;
  virtual function void configure();
    env.gen.min_delay = 0;
    env.gen.max_delay = 0;            // back-to-back, no gaps
  endfunction
endclass

class ErrorTest extends BaseTest;
  virtual function void configure();
    env.gen.inject_errors = 1;
    env.scb.expect_errors = 1;
  endfunction
endclass
```

```systemverilog
module tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  apb_if bus (.pclk(clk), .presetn(rst_n));
  dut u_dut (.bus(bus.slv));

  initial begin
    BaseTest t;
    string   name;

    if (!$value$plusargs("TEST=%s", name)) name = "base";
    case (name)
      "burst": t = BurstTest::new();
      "error": t = ErrorTest::new();
      default: t = BaseTest::new();
    endcase

    rst_n = 0;  repeat (5) @(posedge clk);  rst_n = 1;
    t.run(bus, 1000);
    $finish;
  end

  // Global timeout -- every testbench needs one
  initial begin
    #10ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end
endmodule
```

## 8. Things that are always worth building

| Feature | Why |
|---|---|
| **Global timeout** | a hung test that runs until the farm kills it wastes hours and produces no log |
| **Seed printed at the top of the log** | reproducing a failure is otherwise impossible |
| **`to_str()` on every transaction** | the first thing you need when something mismatches |
| **A message with data, never just "FAIL"** | `exp=%h got=%h at %t` |
| **End-of-test drain + "nothing left pending" check** | dropped transactions are silent otherwise |
| **A `+verbose` plusarg** | so the default log is readable and the debug log exists |
| **An error count, with `$fatal` at the end if nonzero** | a test that prints errors and exits 0 will be reported as passing |

## 9. When to use UVM

UVM is this architecture plus: a factory with type overrides, a configuration
database, standardized phasing, analysis ports, a report server, register
abstraction (RAL), and sequences.

| Situation | Recommendation |
|---|---|
| One block, one engineer, a few weeks | plain SystemVerilog, as above |
| Reusable VIP shared across projects | UVM |
| Large team, many blocks, a chip-level integration | UVM |
| Formal-first flow | neither — SVA + a formal tool |
| Learning | plain SystemVerilog first. UVM's abstractions make sense once you have felt the problems they solve. |

The architecture above is worth building by hand once, precisely so that UVM's
`uvm_driver`, `uvm_monitor`, `uvm_scoreboard`, and `uvm_analysis_port` read as
solutions rather than ceremony.
