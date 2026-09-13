// -----------------------------------------------------------------------------
// skid_buffer_tb.sv -- valid/ready handshake test with a THROUGHPUT check.
//
// Data integrity is the easy part. The reason a skid buffer exists is that it
// registers both directions of the handshake WITHOUT losing throughput, so the
// test that actually matters is: with both sides unthrottled, does it move one
// beat per cycle? A design that merely registers valid/data and stalls on
// backpressure will pass a data-integrity test and fail this one.
//
// Note how much simpler the driver is than in fifo_tb.sv. A valid/ready
// handshake needs no shadow model and no stale-flag workaround: the source
// asserts valid, HOLDS the payload, and waits for a cycle in which ready was
// also high. That self-synchronising property is why handshakes are preferred
// over raw flags at module boundaries.
//
// Run it:
//   $ verilator --binary --timing -Wno-fatal --timescale 1ns/1ps \
//       -o skid_buffer_tb ../rtl/skid_buffer.sv skid_buffer_tb.sv \
//       && obj_dir/skid_buffer_tb
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface axis_if #(parameter int DW = 32) (input logic clk, input logic rst_n);
  logic          tvalid, tready;
  logic [DW-1:0] tdata;

  clocking src @(posedge clk);          // upstream driver's view
    default input #1step output #0;
    output tvalid, tdata;
    input  tready;
  endclocking

  clocking dst @(posedge clk);          // downstream receiver's view
    default input #1step output #0;
    input  tvalid, tdata;
    output tready;
  endclocking

  clocking mon @(posedge clk);          // passive: everything is an input
    default input #1step;
    input tvalid, tready, tdata;
  endclocking

  // The AXI-Stream stability rule, checked on every instance.
  a_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (tvalid && !tready) |=> (tvalid && $stable(tdata)))
    else $error("axis_if: payload changed or valid dropped before handshake");
endinterface


module skid_buffer_tb;

  localparam int DW   = 32;
  localparam int NTXN = 4000;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  axis_if #(.DW(DW)) in  (.clk(clk), .rst_n(rst_n));
  axis_if #(.DW(DW)) out (.clk(clk), .rst_n(rst_n));

  skid_buffer #(.DW(DW)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (in.tvalid),
    .in_data   (in.tdata),
    .in_ready  (in.tready),
    .out_valid (out.tvalid),
    .out_data  (out.tdata),
    .out_ready (out.tready)
  );

  // ---- scoreboard -----------------------------------------------------------
  logic [DW-1:0] model [$];
  int n_sent = 0, n_got = 0, n_err = 0;

  // ---- source driver --------------------------------------------------------
  // No shadow model, no stale-flag problem: hold the beat until ready is seen.
  int src_gap = 0;      // idle cycles inserted between beats

  task automatic source(input int count);
    logic [DW-1:0] d;
    for (int i = 0; i < count; i++) begin
      d = 32'(i) ^ 32'hA5A5_0000;
      in.src.tdata  <= d;
      in.src.tvalid <= 1'b1;
      model.push_back(d);
      n_sent++;
      // Wait for a cycle in which BOTH valid (driven) and ready (sampled) hold.
      do @(in.src); while (!in.src.tready);
      if (src_gap > 0) begin
        in.src.tvalid <= 1'b0;
        repeat (src_gap) @(in.src);
      end
    end
    in.src.tvalid <= 1'b0;
  endtask

  // ---- sink -----------------------------------------------------------------
  int snk_ready_pct = 100;

  task automatic sink();
    forever begin
      out.dst.tready <= ($urandom_range(99, 0) < snk_ready_pct);
      @(out.dst);
    end
  endtask

  // ---- passive monitor + throughput counters --------------------------------
  int beats = 0, cycles = 0;
  bit count_en = 0;

  task automatic monitor();
    logic [DW-1:0] exp;
    forever begin
      @(out.mon);
      if (count_en) cycles++;
      if (out.mon.tvalid && out.mon.tready) begin
        n_got++;
        if (count_en) beats++;
        if (model.size() == 0) begin
          n_err++;
          $display("  UNDERRUN: got %h with an empty model", out.mon.tdata);
        end else begin
          exp = model.pop_front();
          if (out.mon.tdata !== exp) begin
            n_err++;
            if (n_err <= 20)
              $display("  MISMATCH beat %0d: got %h expected %h",
                       n_got, out.mon.tdata, exp);
          end
        end
      end
    end
  endtask

  // ---- test -----------------------------------------------------------------
  initial begin
    in.tvalid  = 1'b0;
    in.tdata   = '0;
    out.tready = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(in.src);

    fork
      sink();
      monitor();
    join_none

    // --- 1. full throughput: no gaps, sink always ready ---------------------
    $display("  phase 1: back-to-back, sink always ready (throughput check)");
    src_gap = 0;  snk_ready_pct = 100;
    @(in.src);
    beats = 0; cycles = 0; count_en = 1;
    source(NTXN);
    count_en = 0;
    $display("           %0d beats in %0d cycles", beats, cycles);
    if (beats < (cycles * 99) / 100) begin
      n_err++;
      $display("  THROUGHPUT FAIL: %0d beats in %0d cycles is not ~1/cycle",
               beats, cycles);
    end

    // --- 2. random backpressure ---------------------------------------------
    $display("  phase 2: random backpressure");
    src_gap = 0;  snk_ready_pct = 50;
    source(NTXN/2);

    // --- 3. heavy backpressure (exercises the skid slot) --------------------
    $display("  phase 3: heavy backpressure, sink ready 10%%");
    snk_ready_pct = 10;
    source(200);

    // --- 4. sparse source ---------------------------------------------------
    $display("  phase 4: sparse source, sink always ready");
    src_gap = 3;  snk_ready_pct = 100;
    source(200);

    // drain
    src_gap = 0;  snk_ready_pct = 100;
    repeat (64) @(in.src);
    disable fork;

    $display("");
    $display("  sent=%0d received=%0d left in model=%0d",
             n_sent, n_got, model.size());
    if (model.size() != 0) begin
      n_err++;
      $display("  MISMATCH: %0d beats never came out", model.size());
    end

    if (n_err == 0) $display("skid_buffer_tb: PASS");
    else begin
      $display("skid_buffer_tb: FAIL (%0d errors)", n_err);
      $fatal(1, "skid buffer mismatch");
    end
    $finish;
  end

  initial begin
    #10ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
