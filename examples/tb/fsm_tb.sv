// -----------------------------------------------------------------------------
// fsm_tb.sv -- self-checking tests for the FSM coding-style modules:
// fsm_two_process, fsm_one_process, fsm_three_process, fsm_onehot, fsm_safe.
//
// Two things are checked that the individual modules cannot check about
// themselves:
//
//  1. STYLE EQUIVALENCE. The two-process, one-process and three-process
//     versions implement the same controller. Driven from identical stimulus
//     they must produce identical waveforms -- not similar, identical, in the
//     same cycle. The point of docs/26 is that the choice between these styles
//     is about timing and maintainability, not about behaviour, and that only
//     means anything if the behaviour really is the same.
//
//  2. ILLEGAL-STATE RECOVERY, demonstrated rather than asserted. Two fsm_safe
//     instances differing only in SAFE have an illegal encoding forced into
//     their state registers. The safe one is back in IDLE on the next edge; the
//     unsafe one is still sitting in the illegal state many cycles later,
//     because all-zeros is absorbing. formal/fsm_safe_fv.sby proves this over
//     all 12 illegal encodings; here it is shown happening.
//
// Run with XSIM:
//   xvlog -sv <rtl files> fsm_tb.sv && xelab fsm_tb -s sim && xsim sim -R
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module fsm_tb;

  localparam int unsigned CW = 4;

  int errors = 0;

  task automatic chk(input string what, input logic ok);
    if (!ok) begin
      errors++;
      if (errors <= 30) $display("  FAIL  %s", what);
    end
  endtask

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ===========================================================================
  // 1. The three styles, same stimulus, same ports
  // ===========================================================================
  // Initialised at declaration, not in the task that uses them. These signals
  // feed DUTs that are instantiated for the whole simulation, so leaving them
  // undriven until their own test runs pushes X into those DUTs' state
  // registers during the EARLIER tests -- and an X state quietly fails the
  // one-hot assertions inside fsm_safe and fsm_onehot. Drive every DUT input
  // from time 0, even the ones this test does not care about yet.
  logic           start = 1'b0, grant = 1'b0, beat_ack = 1'b0;
  logic [CW-1:0]  len   = CW'(1);

  logic req2, val2, done2;    // two-process   (combinational outputs)
  logic req1, val1, done1;    // one-process   (registered at transition time)
  logic req3, val3, done3;    // three-process (registered, decoded from next)

  fsm_two_process   #(.CW(CW)) u_two (
    .clk, .rst_n, .start, .len, .grant, .beat_ack,
    .bus_req(req2), .beat_valid(val2), .done(done2));

  fsm_one_process   #(.CW(CW)) u_one (
    .clk, .rst_n, .start, .len, .grant, .beat_ack,
    .bus_req(req1), .beat_valid(val1), .done(done1));

  fsm_three_process #(.CW(CW)) u_three (
    .clk, .rst_n, .start, .len, .grant, .beat_ack,
    .bus_req(req3), .beat_valid(val3), .done(done3));

  // Continuous equivalence monitor.
  //
  // Stimulus is driven on the FALLING edge throughout this file and sampled
  // here 1ns AFTER the rising edge, so every comparison is between settled
  // values. Driving on the rising edge instead makes the whole file fail with
  // the three styles apparently a cycle apart -- which is a race in the
  // testbench, not a difference between the designs. It is the first thing to
  // suspect when two implementations of one FSM "disagree by one cycle".
  int compares = 0;
  always @(posedge clk) begin
    #1;
    if (rst_n) begin
    compares++;
    chk($sformatf("t=%0t two vs three: req %b/%b val %b/%b done %b/%b",
                  $time, req2, req3, val2, val3, done2, done3),
        (req2 === req3) && (val2 === val3) && (done2 === done3));
    chk($sformatf("t=%0t two vs one:   req %b/%b val %b/%b done %b/%b",
                  $time, req2, req1, val2, val1, done2, done1),
        (req2 === req1) && (val2 === val1) && (done2 === done1));
    end
  end

  // An independent model of what the controller is supposed to do, so that the
  // three-way comparison above cannot pass by all three being wrong together.
  int beats_seen, done_pulses;
  always @(posedge clk) if (rst_n) begin
    if (val3 && beat_ack) beats_seen++;
    if (done3)            done_pulses++;
  end

  task automatic run_transaction(input int nbeats,
                                 input int grant_delay,
                                 input int ack_gap);
    beats_seen  = 0;
    done_pulses = 0;
    len   = CW'(nbeats);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    @(negedge clk);

    // Hold off the grant to prove the FSM waits rather than free-running.
    repeat (grant_delay) @(negedge clk);
    chk($sformatf("req asserted while waiting for grant (n=%0d)", nbeats), req2);
    chk("no beat_valid before grant", !val2);
    grant = 1'b1;
    @(negedge clk);
    grant = 1'b0;
    @(negedge clk);

    // Acknowledge each beat, optionally stalling between them.
    for (int b = 0; b < nbeats; b++) begin
      repeat (ack_gap) begin
        beat_ack = 1'b0;
        @(negedge clk);
      end
      beat_ack = 1'b1;
      @(negedge clk);
    end
    beat_ack = 1'b0;

    // done is a single-cycle pulse; give it a cycle to appear and settle.
    @(negedge clk);
    @(negedge clk);
    chk($sformatf("exactly %0d beats acknowledged (saw %0d)",
                  nbeats, beats_seen), beats_seen == nbeats);
    chk($sformatf("exactly one done pulse (saw %0d)", done_pulses),
        done_pulses == 1);
    chk("returned to idle: no bus_req", !req2);
  endtask

  task automatic test_styles();
    $display("[styles] two-process vs one-process vs three-process");
    start = 1'b0; grant = 1'b0; beat_ack = 1'b0; len = CW'(1);
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    run_transaction(1, 0, 0);     // shortest possible
    run_transaction(3, 2, 0);     // delayed grant
    run_transaction(4, 1, 2);     // stalls between beats
    run_transaction(2, 5, 3);     // slow everything
    run_transaction(1, 0, 0);     // back-to-back after the slow one

    chk("equivalence monitor actually ran", compares > 50);
    $display("  %0d cycles compared across three styles", compares);
  endtask

  // ===========================================================================
  // 2. fsm_onehot -- the explicit one-hot style
  // ===========================================================================
  logic oh_start = 1'b0, oh_grant = 1'b0, oh_last = 1'b0;
  logic oh_req, oh_done;

  fsm_onehot u_oh (
    .clk, .rst_n, .start(oh_start), .grant(oh_grant),
    .last_beat(oh_last), .bus_req(oh_req), .done(oh_done));

  task automatic test_onehot();
    $display("[onehot] explicit one-hot encoding");
    oh_start = 1'b0; oh_grant = 1'b0; oh_last = 1'b0;
    @(negedge clk);
    chk("idle: no request", !oh_req && !oh_done);

    oh_start = 1'b1; @(negedge clk); oh_start = 1'b0;
    chk("request asserted after start", oh_req);

    oh_grant = 1'b1; @(negedge clk); oh_grant = 1'b0;
    chk("still requesting during transfer", oh_req);
    chk("not done during transfer", !oh_done);

    oh_last = 1'b1; @(negedge clk); oh_last = 1'b0;
    chk("done pulses after last beat", oh_done);

    @(negedge clk);
    chk("done is a single cycle", !oh_done);
    chk("back to idle", !oh_req);
  endtask

  // ===========================================================================
  // 3. fsm_safe -- illegal-state recovery, by fault injection
  // ===========================================================================
  logic sf_start = 1'b0, sf_grant = 1'b0, sf_last = 1'b0;
  logic s1_req, s1_done, s1_err;   // SAFE = 1
  logic s0_req, s0_done, s0_err;   // SAFE = 0

  fsm_safe #(.SAFE(1'b1)) u_safe1 (
    .clk, .rst_n, .start(sf_start), .grant(sf_grant), .last_beat(sf_last),
    .bus_req(s1_req), .done(s1_done), .state_err(s1_err));

  fsm_safe #(.SAFE(1'b0)) u_safe0 (
    .clk, .rst_n, .start(sf_start), .grant(sf_grant), .last_beat(sf_last),
    .bus_req(s0_req), .done(s0_done), .state_err(s0_err));

  // `force` cannot take an automatic variable as its source, so the injected
  // value is staged in a static signal first.
  logic [3:0] inj;

  // Inject one illegal encoding into both instances and watch what each does.
  task automatic inject(input logic [3:0] bad);
    // `force` holds the register against its own always_ff, so the injected
    // encoding is still the sampled value at the FOLLOWING clock edge too --
    // the design cannot update a register it is not allowed to drive. That
    // makes the in-module `a_recovers` property look violated by an artefact
    // of the injection rather than by the design, so design assertions are
    // suspended for the window. Recovery is checked below from `state_err`,
    // which is a port and needs no such help.
    $assertoff(0, u_safe1);
    $assertoff(0, u_safe0);

    inj = bad;
    force u_safe1.state = inj;
    force u_safe0.state = inj;
    @(negedge clk);
    chk($sformatf("injected %b is flagged illegal", bad), s1_err && s0_err);
    release u_safe1.state;
    release u_safe0.state;

    // One clock edge of normal operation is all the recovery is allowed.
    @(negedge clk);
    chk($sformatf("SAFE=1 recovered from %b in one cycle", bad), !s1_err);

    $asserton(0, u_safe1);
    $asserton(0, u_safe0);
    chk($sformatf("SAFE=1 drives nothing while illegal (%b)", bad),
        !s1_req && !s1_done);
  endtask

  task automatic test_safe();
    logic stuck;
    $display("[safe] illegal-state recovery under fault injection");
    sf_start = 1'b0; sf_grant = 1'b0; sf_last = 1'b0;
    @(negedge clk);

    // Every one of the 12 illegal encodings of a 4-state one-hot vector.
    for (int e = 0; e < 16; e++) begin
      if ($onehot(4'(e))) continue;
      inject(4'(e));
    end

    // And the headline difference: all-zeros is absorbing without SAFE.
    $assertoff(0, u_safe0);
    inj = 4'b0000;
    force u_safe0.state = inj;
    @(negedge clk);
    release u_safe0.state;
    sf_start = 1'b1;                       // poke it; it should not respond
    repeat (10) @(negedge clk);
    sf_start = 1'b0;
    stuck = s0_err;
    chk("SAFE=0 is still stuck in the illegal state 10 cycles later", stuck);
    $display("  SAFE=0 state_err after 10 cycles: %b (stuck as expected)", stuck);

    // Reset is the only way out for the unsafe variant.
    rst_n = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    chk("SAFE=0 recovers only via reset", !s0_err);
    $asserton(0, u_safe0);
  endtask

  // ===========================================================================
  initial begin
    $display("");
    $display("=== fsm_tb ===");

    test_styles();
    test_onehot();
    test_safe();

    $display("");
    if (errors == 0) $display("fsm_tb: PASS");
    else begin
      $display("fsm_tb: FAIL (%0d errors)", errors);
      $fatal(1, "FSM test failures");
    end
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
