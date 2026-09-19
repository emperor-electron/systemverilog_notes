// -----------------------------------------------------------------------------
// fifo_tb.sv -- layered, self-checking testbench for sync_fifo.
//
// A compact demonstration of the architecture in docs/16, and of why the
// testbench touches the DUT only through a CLOCKING BLOCK (docs/07, docs/15):
//
//   Test        -> picks the scenario (backpressure profile, burst shape)
//   Generator   -> creates data,          never touches signals
//   Driver      -> drives wr_en/wr_data,  never checks anything
//   Monitor     -> observes reads,        PASSIVE, never drives
//   Scoreboard  -> compares against a queue model of a FIFO
//
// The monitor reconstructs what came out of the FIFO purely from the pins. It
// has no handle on the driver, so a driver that writes the wrong thing produces
// a mismatch rather than being invisible.
//
// Run it:  make fifo
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// =============================================================================
// Interface: signals + direction + TIMING, in one reusable object.
// =============================================================================
interface fifo_if #(parameter int DW = 32, parameter int LW = 5)
                   (input logic clk, input logic rst_n);
  logic          wr_en, rd_en;
  logic [DW-1:0] wr_data, rd_data;
  logic          full, empty, almost_full, almost_empty;
  logic [LW-1:0] level;

  // `input #1step` samples in the PREPONED region -- the values a flip-flop
  // would have captured at this edge. `output #0` drives in Re-NBA, after the
  // DUT's own non-blocking updates. Together these make a TB/DUT race
  // impossible (docs/15).
  // The DRIVER's view: it drives the request signals and samples the flags.
  clocking cb @(posedge clk);
    default input #1step output #0;
    output wr_en, wr_data, rd_en;
    input  rd_data, full, empty, almost_full, almost_empty, level;
  endclocking

  // The MONITOR's view: everything is an input. This is not just tidiness --
  // an `output` clockvar CANNOT be read (IEEE 1800 14.3), so a passive monitor
  // physically needs its own all-input clocking block. That restriction is
  // what enforces the "monitor never drives" rule at compile time.
  clocking cb_mon @(posedge clk);
    default input #1step;
    input wr_en, wr_data, rd_en, rd_data;
    input full, empty, almost_full, almost_empty, level;
  endclocking

  modport drv (clocking cb);
  modport mon (clocking cb_mon);

  // Protocol checks live with the protocol, so every instance gets them free.
  a_no_overflow:  assert property (@(posedge clk) disable iff (!rst_n)
                                   full |-> !wr_en)
    else $error("fifo_if: write attempted while full");
  a_no_underflow: assert property (@(posedge clk) disable iff (!rst_n)
                                   empty |-> !rd_en)
    else $error("fifo_if: read attempted while empty");
endinterface


// =============================================================================
// Testbench
// =============================================================================
module fifo_tb;

  localparam int DW    = 32;
  localparam int DEPTH = 16;
  localparam int LW    = $clog2(DEPTH) + 1;
  localparam int NTXN  = 4000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  fifo_if #(.DW(DW), .LW(LW)) bus (.clk(clk), .rst_n(rst_n));

  sync_fifo #(.DW(DW), .DEPTH(DEPTH), .FWFT(1'b0)) dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .wr_en        (bus.wr_en),
    .wr_data      (bus.wr_data),
    .full         (bus.full),
    .almost_full  (bus.almost_full),
    .rd_en        (bus.rd_en),
    .rd_data      (bus.rd_data),
    .empty        (bus.empty),
    .almost_empty (bus.almost_empty),
    .level        (bus.level)
  );

  // ---------------------------------------------------------------------------
  // Scoreboard: a queue IS the reference model of a FIFO.
  // ---------------------------------------------------------------------------
  logic [DW-1:0] model [$];
  int  n_written = 0, n_read = 0, n_errors = 0;
  int  max_level = 0;
  bit  saw_full = 0, saw_empty = 0, saw_b2b_write = 0, saw_b2b_read = 0;

  task automatic sb_pushed(input logic [DW-1:0] d);
    model.push_back(d);
    n_written++;
  endtask

  task automatic sb_popped(input logic [DW-1:0] d);
    logic [DW-1:0] exp;
    n_read++;
    if (model.size() == 0) begin
      n_errors++;
      $display("  SCOREBOARD: popped %h but the model is EMPTY", d);
      return;
    end
    exp = model.pop_front();
    // === so that an X fails loudly instead of comparing as "not equal".
    if (d !== exp) begin
      n_errors++;
      if (n_errors <= 20)
        $display("  SCOREBOARD: got %h expected %h (txn %0d)", d, exp, n_read);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Driver: writes and reads with a configurable backpressure profile.
  //
  // The weights matter. A 50/50 profile almost never fills or empties the FIFO,
  // so it never tests the flags that are the entire point. The profiles below
  // deliberately spend time at both extremes.
  //
  // WHY THE DRIVER DOES NOT USE THE SAMPLED `full`/`empty` FLAGS:
  //   A clocking block samples in Preponed and drives in Re-NBA, so a flag read
  //   at edge T describes the state produced by edge T-1, while the signals
  //   being driven are consumed at edge T+1. The flag is therefore one cycle
  //   stale, and a driver that trusts it WILL write while full as soon as the
  //   FIFO is near its limit. (Real upstream logic has no such problem: it gates
  //   its request combinationally with the live `full` signal.)
  //
  //   The fix here is a shadow occupancy counter. The driver is the only agent
  //   touching either port, so it knows the exact occupancy the DUT will be in
  //   when it consumes what is being driven now -- no prediction needed, and no
  //   dependence on the very flags under test.
  // ---------------------------------------------------------------------------
  int wr_weight = 50;    // percent chance of attempting a write each cycle
  int rd_weight = 50;
  int occ       = 0;     // shadow occupancy at the edge being driven for

  task automatic driver();
    logic [DW-1:0] d;
    bit            do_wr, do_rd;
    forever begin
      @(bus.cb);

      do_wr = (occ < DEPTH) && ($urandom_range(99, 0) < wr_weight);
      do_rd = (occ > 0)     && ($urandom_range(99, 0) < rd_weight);

      bus.cb.wr_en <= do_wr;
      bus.cb.rd_en <= do_rd;
      if (do_wr) begin
        d = $urandom();
        bus.cb.wr_data <= d;
        sb_pushed(d);
      end

      occ = occ + int'(do_wr) - int'(do_rd);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Monitor: PASSIVE. Reconstructs the read stream from the pins alone.
  //
  // sync_fifo in standard (non-FWFT) mode registers rd_data, so the data for a
  // read accepted at edge T is observable at edge T+1. The monitor tracks that
  // one-cycle offset itself rather than being told about it.
  // ---------------------------------------------------------------------------
  task automatic monitor();
    bit pop_pending = 1'b0;
    forever begin
      @(bus.cb_mon);
      if (pop_pending) sb_popped(bus.cb_mon.rd_data);
      pop_pending = (bus.cb_mon.rd_en && !bus.cb_mon.empty);

      // Opportunistic coverage of the states that matter.
      if (bus.cb_mon.full)  saw_full  = 1'b1;
      if (bus.cb_mon.empty) saw_empty = 1'b1;
      if (int'(bus.cb_mon.level) > max_level) max_level = int'(bus.cb_mon.level);
      if (bus.cb_mon.wr_en && !bus.cb_mon.full)  saw_b2b_write = 1'b1;
      if (bus.cb_mon.rd_en && !bus.cb_mon.empty) saw_b2b_read  = 1'b1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Checker: flag consistency against the level count, every cycle.
  // ---------------------------------------------------------------------------
  a_full_iff:  assert property (@(posedge clk) disable iff (!rst_n)
                 bus.full  == (bus.level == LW'(DEPTH)));
  a_empty_iff: assert property (@(posedge clk) disable iff (!rst_n)
                 bus.empty == (bus.level == LW'(0)));
  a_level_max: assert property (@(posedge clk) disable iff (!rst_n)
                 bus.level <= LW'(DEPTH));

  // ---------------------------------------------------------------------------
  // Test
  // ---------------------------------------------------------------------------
  task automatic phase(input string name, input int wr, input int rd,
                       input int cycles);
    $display("  phase: %-22s wr=%0d%% rd=%0d%%", name, wr, rd);
    wr_weight = wr;
    rd_weight = rd;
    repeat (cycles) @(bus.cb);
  endtask

  initial begin
    bus.wr_en   = 1'b0;
    bus.rd_en   = 1'b0;
    bus.wr_data = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(bus.cb);

    fork
      driver();
      monitor();
    join_none

    // Each profile targets a different part of the state space.
    phase("fill (writer wins)",  90, 10, NTXN/4);   // drives to FULL
    phase("drain (reader wins)", 10, 90, NTXN/4);   // drives to EMPTY
    phase("balanced",            50, 50, NTXN/4);
    phase("back-to-back",       100,100, NTXN/4);   // max throughput
    phase("bursty",              70, 30, NTXN/4);
    phase("final drain",          0,100, DEPTH*4);

    // Let the last read's data land, then stop the stimulus.
    repeat (4) @(bus.cb);
    disable fork;

    $display("");
    $display("  writes=%0d reads=%0d max_level=%0d/%0d", n_written, n_read,
             max_level, DEPTH);
    $display("  saw: full=%b empty=%b b2b_write=%b b2b_read=%b",
             saw_full, saw_empty, saw_b2b_write, saw_b2b_read);
    $display("  left in model = %0d (should equal the FIFO level %0d)",
             model.size(), bus.level);

    // A dropped transaction is invisible unless you check for leftovers.
    if (model.size() != int'(bus.level)) begin
      n_errors++;
      $display("  MISMATCH: model holds %0d but the FIFO reports %0d",
               model.size(), bus.level);
    end
    if (!saw_full)  begin n_errors++; $display("  COVERAGE HOLE: never full"); end
    if (!saw_empty) begin n_errors++; $display("  COVERAGE HOLE: never empty"); end

    if (n_errors == 0) $display("fifo_tb: PASS");
    else begin
      $display("fifo_tb: FAIL (%0d errors)", n_errors);
      $fatal(1, "fifo mismatch");
    end
    $finish;
  end

  // Every testbench needs one of these.
  initial begin
    #5ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
