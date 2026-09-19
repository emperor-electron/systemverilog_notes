// -----------------------------------------------------------------------------
// async_fifo_tb.sv -- dual-clock FIFO test with an arbitrary clock ratio.
//
// Two things make this different from a single-clock FIFO test:
//
// 1. NEITHER SIDE CAN SHADOW-MODEL THE OTHER. In fifo_tb.sv the driver knows
//    the exact occupancy because it controls both ports. Here the writer has no
//    idea how many reads have happened, so it MUST use `wfull` -- which is
//    deliberately conservative (a stale pointer can only make the FIFO look
//    fuller than it is, never emptier).
//
//    Because `wfull` must be consulted in the same cycle the write is issued,
//    wr_en is gated COMBINATIONALLY -- exactly as real upstream logic does it:
//        assign wr_en = wr_req && !wfull;
//    A clocking-block output alone cannot express that: it would be driving
//    with a one-cycle-stale flag. (See the long comment in fifo_tb.sv.)
//
// 2. THE SCOREBOARD IS FED PURELY BY OBSERVATION. Each side has a passive
//    monitor in its own clock domain; the write monitor pushes what it sees
//    accepted, the read monitor pops and compares. Neither monitor knows
//    anything about the drivers.
//
// Run it:  make async_fifo
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module async_fifo_tb;

  localparam int DW    = 32;
  localparam int DEPTH = 16;
  localparam int NTXN  = 3000;

  // ---- clocks: deliberately unrelated periods -------------------------------
  logic wclk = 1'b0, rclk = 1'b0;
  logic wrst_n = 1'b0, rrst_n = 1'b0;

  int wper = 7;     // ns -- changed between phases to sweep the ratio
  int rper = 11;

  initial forever #(wper * 1ns / 2) wclk = ~wclk;
  initial forever #(rper * 1ns / 2) rclk = ~rclk;

  // ---- DUT ------------------------------------------------------------------
  logic          wr_req, wr_en, wfull;
  logic [DW-1:0] wr_data;
  logic          rd_req, rd_en, rempty;
  logic [DW-1:0] rd_data;

  // Combinational gating with the LIVE flag -- the way real logic does it.
  assign wr_en = wr_req && !wfull;
  assign rd_en = rd_req && !rempty;

  async_fifo #(.DW(DW), .DEPTH(DEPTH), .STAGES(2)) dut (
    .wclk (wclk), .wrst_n (wrst_n),
    .wr_en(wr_en), .wr_data(wr_data), .wfull(wfull),
    .rclk (rclk), .rrst_n (rrst_n),
    .rd_en(rd_en), .rd_data(rd_data), .rempty(rempty)
  );

  // ---- scoreboard -----------------------------------------------------------
  logic [DW-1:0] model [$];
  int n_wr = 0, n_rd = 0, n_err = 0;
  bit saw_full = 0, saw_empty = 0;
  int max_occ = 0;

  // ---- write side -----------------------------------------------------------
  int wr_weight = 60;
  logic [DW-1:0] next_data = 32'h1;

  always @(posedge wclk) begin
    if (!wrst_n) begin
      wr_req  <= 1'b0;
      wr_data <= '0;
    end else begin
      wr_req  <= ($urandom_range(99, 0) < wr_weight);
      wr_data <= next_data;
      // A counting pattern makes an out-of-order or duplicated beat obvious in
      // a waveform, which random data does not.
      if (wr_en) next_data <= next_data + 1;
    end
  end

  // Passive write monitor, in the WRITE clock domain. Sampling on negedge keeps
  // it clear of the NBA updates it is observing (docs/15); a clocking block per
  // domain is the production approach and fifo_tb.sv shows it.
  always @(negedge wclk) begin
    if (wrst_n) begin
      if (wr_en) begin
        model.push_back(wr_data);
        n_wr++;
        if (model.size() > max_occ) max_occ = model.size();
      end
      if (wfull) saw_full = 1'b1;
    end
  end

  // ---- read side ------------------------------------------------------------
  int rd_weight = 60;

  always @(posedge rclk) begin
    if (!rrst_n) rd_req <= 1'b0;
    else         rd_req <= ($urandom_range(99, 0) < rd_weight);
  end

  // Passive read monitor, in the READ clock domain.
  always @(negedge rclk) begin
    logic [DW-1:0] exp;
    if (rrst_n) begin
      if (rd_en) begin
        n_rd++;
        if (model.size() == 0) begin
          n_err++;
          $display("  READ UNDERRUN: got %h with an empty model", rd_data);
        end else begin
          exp = model.pop_front();
          if (rd_data !== exp) begin
            n_err++;
            if (n_err <= 20)
              $display("  MISMATCH beat %0d: got %h expected %h",
                       n_rd, rd_data, exp);
          end
        end
      end
      if (rempty) saw_empty = 1'b1;
    end
  end

  // ---- protocol assertions --------------------------------------------------
  a_no_overflow:  assert property (@(posedge wclk) disable iff (!wrst_n)
                                   wfull |-> !wr_en)
    else $error("async_fifo_tb: write while full");
  a_no_underflow: assert property (@(posedge rclk) disable iff (!rrst_n)
                                   rempty |-> !rd_en)
    else $error("async_fifo_tb: read while empty");

  // ---- test -----------------------------------------------------------------
  task automatic phase(input string name, input int wp, input int rp,
                       input int wwt, input int rwt, input int beats);
    int target;
    $display("  phase: %-26s wclk=%0dns rclk=%0dns wr=%0d%% rd=%0d%%",
             name, wp, rp, wwt, rwt);
    wper = wp;  rper = rp;
    wr_weight = wwt;  rd_weight = rwt;
    target = n_rd + beats;
    while (n_rd < target) @(posedge rclk);
  endtask

  initial begin
    wr_req = 1'b0;  rd_req = 1'b0;  wr_data = '0;
    repeat (5) @(posedge wclk);  wrst_n = 1'b1;
    repeat (5) @(posedge rclk);  rrst_n = 1'b1;

    // Sweep the clock ratio and the pressure so that both `wfull` (fast writer)
    // and `rempty` (fast reader) are genuinely exercised.
    phase("fast write / slow read",   3, 17,  90, 40, NTXN/4);
    phase("slow write / fast read",  17,  3,  40, 90, NTXN/4);
    phase("near-equal, coprime",      7, 11,  70, 70, NTXN/4);
    phase("back-to-back both sides",  5,  5, 100,100, NTXN/4);

    // Drain.
    wr_weight = 0;  rd_weight = 100;
    repeat (200) @(posedge rclk);

    $display("");
    $display("  writes=%0d reads=%0d max_occupancy=%0d/%0d", n_wr, n_rd,
             max_occ, DEPTH);
    $display("  saw: wfull=%b rempty=%b", saw_full, saw_empty);
    $display("  left in model = %0d", model.size());

    if (model.size() != 0) begin
      n_err++;
      $display("  MISMATCH: %0d beats never came out", model.size());
    end
    if (!saw_full)  begin n_err++; $display("  COVERAGE HOLE: wfull never seen"); end
    if (!saw_empty) begin n_err++; $display("  COVERAGE HOLE: rempty never seen"); end
    if (max_occ < DEPTH) $display("  note: peak occupancy %0d < DEPTH %0d",
                                 max_occ, DEPTH);

    if (n_err == 0) $display("async_fifo_tb: PASS");
    else begin
      $display("async_fifo_tb: FAIL (%0d errors)", n_err);
      $fatal(1, "async fifo mismatch");
    end
    $finish;
  end

  initial begin
    #20ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
