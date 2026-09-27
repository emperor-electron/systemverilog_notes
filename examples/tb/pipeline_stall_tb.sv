// -----------------------------------------------------------------------------
// pipeline_stall_tb.sv -- the stall structures of docs/38, measured rather than
// described.
//
// Four things are being established here, and only the last one is an ordinary
// functional test:
//
//   1. WHICH PATHS ARE COMBINATIONAL, per register-slice mode. Measured by
//      changing an input BETWEEN clock edges and looking at whether an output
//      moves in the same instant. That is a direct observation of combinational
//      dependence -- no assertion, no inspection of the source.
//   2. THE SUSTAINED RATE of each mode with both sides unthrottled, which is the
//      number that separates the half-rate slice from the rest and the one a
//      data-integrity test cannot see.
//   3. STALL INSENSITIVITY: the same input sequence through the elastic pipeline
//      under several different random backpressure patterns must produce the
//      SAME output sequence. A pipeline that loses a beat only when a stall
//      lands in a particular cycle passes every fixed-pattern test.
//   4. That the three control schemes over one datapath -- combinational, global
//      stall, elastic -- all compute the same arithmetic, against a longint
//      model.
//
// The skew buffer section is separate because reconvergence is a different
// problem from stalling: the two branches are decoupled, and the measurement is
// how far apart they are allowed to drift before one is made to wait.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module pipeline_stall_tb;

  localparam int unsigned NMODE = 5;    // PASS, FWD, REV, FULL, HALF
  localparam int unsigned DW    = 8;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  int   err = 0;
  string MODE_NAME [NMODE] = '{"PASS", "FWD ", "REV ", "FULL", "HALF"};

  int   rate_beats [NMODE];
  int   rate_cycles[NMODE];
  int   latency    [NMODE];
  logic comb_fwd   [NMODE];
  logic comb_bwd   [NMODE];
  logic mode_done  [NMODE];

  task automatic ck(input string what, input logic ok);
    if (!ok) begin
      err++;
      if (err <= 20) $display("  FAIL  %s", what);
    end
  endtask

  // ===========================================================================
  // 1-3. The five register-slice modes, one instance each.
  // ===========================================================================
  for (genvar M = 0; M < int'(NMODE); M++) begin : g_mode

    logic          s_valid = 1'b0, s_ready;
    logic [DW-1:0] s_data  = '0;
    logic          m_valid, m_ready = 1'b0;
    logic [DW-1:0] m_data;

    axis_reg_slice #(.DW(DW), .MODE(M)) u_slice (
      .clk, .rst_n,
      .s_valid(s_valid), .s_data(s_data), .s_ready(s_ready),
      .m_valid(m_valid), .m_data(m_data), .m_ready(m_ready));

    // ---- a stream of sequence numbers, checked at the output ---------------
    //
    // One process drives and checks, which is the simplest way to be sure the
    // stimulus and the sampling cannot race. `step` presents the stimulus for the
    // coming posedge, records what that posedge will do, and only advances the
    // payload AFTER the edge -- getting that order wrong makes every value skip
    // by one, which looks exactly like a DUT that drops beats.
    int   exp_out, seen;
    logic took;

    task automatic step(input logic want_valid, input logic want_ready);
      // TVALID may only be withdrawn once the beat has been accepted; `took`
      // carries that fact over from the previous cycle.
      if (!s_valid || took) s_valid = want_valid;
      m_ready = want_ready;
      #1;                          // let a combinational s_ready settle
      if (m_valid && m_ready) begin
        ck($sformatf("[%s] out of order: got %0d want %0d",
                     MODE_NAME[M], m_data, exp_out[DW-1:0]),
           m_data === exp_out[DW-1:0]);
        exp_out++;
        seen++;
      end
      took = s_valid && s_ready;   // what the coming posedge will accept
      @(negedge clk);              // the posedge happens inside this wait
      if (took) s_data = s_data + 1'b1;
    endtask

    initial begin : run_mode
      int   guard;
      logic was_mv, was_sr;
      logic [DW-1:0] was_md;
      mode_done[M] = 1'b0;
      exp_out      = 0;
      seen         = 0;
      took         = 1'b0;
      wait (rst_n);
      repeat (2) @(negedge clk);

      // ---- (1) is the FORWARD path combinational? -------------------------
      // Slice empty, sink ready. Offer a beat mid-cycle and see whether m_valid
      // follows in the same instant. This is a direct measurement of a
      // combinational dependence -- no assertion and no reading of the source.
      m_ready = 1'b1;
      s_valid = 1'b0;
      s_data  = 8'hA5;
      @(negedge clk);
      #1;
      // Record the outputs, change an input, look again. A LEVEL test is not
      // enough: `s_ready` may already be high for reasons of its own, and
      // reading a high level as evidence of a combinational path reported the
      // skid buffer as combinational when it is not.
      was_mv = m_valid;
      was_md = m_data;
      s_valid = 1'b1;
      #1;
      comb_fwd[M] = (m_valid !== was_mv) || (m_data !== was_md);
      s_valid = 1'b0;               // put it back before the next posedge
      #1;

      // ---- (2) is the BACKWARD path combinational? ------------------------
      // The dependence only exists while the slice holds a beat -- a slice with
      // nothing in it can always accept -- so fill it first with the sink
      // refusing.
      m_ready = 1'b0;
      @(negedge clk);
      s_valid = 1'b1;
      s_data  = 8'h5A;
      guard   = 0;
      while (!m_valid && guard < 8) begin @(negedge clk); guard++; end
      s_valid = 1'b0;
      @(negedge clk);
      #1;
      was_sr  = s_ready;
      m_ready = 1'b1;               // change the sink's ready mid-cycle
      #1;
      comb_bwd[M] = (s_ready !== was_sr);
      m_ready = 1'b0;
      #1;

      // Flush the probe beats out and resynchronise.
      m_ready = 1'b1;
      repeat (4) @(negedge clk);
      m_ready = 1'b0;
      s_valid = 1'b0;
      repeat (2) @(negedge clk);

      // ---- latency of an empty slice, in cycles ---------------------------
      // Counted from the cycle the beat is PRESENTED, which is why the check
      // comes before the first wait: counting from the cycle after presenting
      // reports every one-cycle slice as zero.
      s_data  = 8'h00;
      s_valid = 1'b1;
      m_ready = 1'b1;
      guard   = 0;
      #1;
      while (!(m_valid && (m_data === 8'h00)) && guard < 10) begin
        @(negedge clk);
        #1;
        guard++;
      end
      latency[M] = guard;
      s_valid = 1'b0;
      m_ready = 1'b1;
      repeat (4) @(negedge clk);

      // ---- (3) sustained rate, both sides unthrottled --------------------
      exp_out = 0;
      seen    = 0;
      s_data  = '0;
      took    = 1'b0;
      s_valid = 1'b0;
      rate_cycles[M] = 100;
      for (int i = 0; i < 100; i++) step(1'b1, 1'b1);
      rate_beats[M] = seen;
      // Drain.
      for (int i = 0; i < 8; i++) step(1'b0, 1'b1);

      // ---- (4) integrity under random backpressure ------------------------
      exp_out = 0;
      seen    = 0;
      s_data  = '0;
      took    = 1'b0;
      s_valid = 1'b0;
      for (int i = 0; i < 400; i++)
        step(($urandom_range(0, 3) != 0), ($urandom_range(0, 3) != 0));
      for (int i = 0; i < 12; i++) step(1'b0, 1'b1);
      ck($sformatf("[%s] moved beats under random backpressure (saw %0d)",
                   MODE_NAME[M], seen), seen > 40);

      mode_done[M] = 1'b1;
    end
  end

  // ===========================================================================
  // 4. One datapath, three control schemes.
  // ===========================================================================
  localparam int unsigned TAPS = 4, XW = 8, CW = 10, CF = 8, YW = 8;
  localparam int unsigned LAT  = 4;          // CUTS = 4'b1111

  logic [TAPS*CW-1:0] coef;
  logic [TAPS*XW-1:0] samp;

  // (a) combinational: CUTS = 0
  logic [YW-1:0] y_comb;
  dot_rs_dp #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW), .CUTS(4'b0000))
    u_comb (.clk, .rst_n, .adv(4'b0000), .x(samp), .c(coef), .y(y_comb));

  // (b) global stall
  logic g_en = 1'b1, g_flush = 1'b0, g_vi = 1'b0, g_vo, g_busy;
  logic [YW-1:0] y_glob;
  dot_rs_global #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW), .CUTS(4'b1111))
    u_glob (.clk, .rst_n, .en(g_en), .flush(g_flush), .valid_i(g_vi),
            .x(samp), .c(coef), .valid_o(g_vo), .y(y_glob), .busy(g_busy));

  // (c) elastic
  logic e_flush = 1'b0, e_sv = 1'b0, e_sr, e_mv, e_mr = 1'b1;
  logic [YW-1:0] y_elas;
  logic [TAPS*XW-1:0] e_samp = '0;
  dot_rs_elastic #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW), .CUTS(4'b1111))
    u_elas (.clk, .rst_n, .flush(e_flush), .s_valid(e_sv), .s_ready(e_sr),
            .x(e_samp), .c(coef), .m_valid(e_mv), .m_ready(e_mr), .y(y_elas));

  function automatic int unsigned dot_model(input logic [TAPS*XW-1:0] xs);
    longint acc;
    longint want;
    acc = 0;
    for (int i = 0; i < int'(TAPS); i++)
      acc += longint'($signed(coef[i*CW +: CW])) * longint'(xs[i*XW +: XW]);
    want = (acc + (1 << (CF - 1))) >>> CF;
    if (want < 0)                     want = 0;
    else if (want > ((1 << YW) - 1))  want = (1 << YW) - 1;
    dot_model = int'(want);
  endfunction

  function automatic logic [TAPS*XW-1:0] mk_samples(input int k);
    mk_samples = '0;
    for (int i = 0; i < int'(TAPS); i++)
      mk_samples[i*XW +: XW] = XW'((k * 37) + (i * 53) + 1);
  endfunction

  logic dp_done = 1'b0;

  initial begin : run_dp
    int    got, want, guard;
    logic [YW-1:0] held;
    coef = '0;
    for (int i = 0; i < int'(TAPS); i++)
      coef[i*CW +: CW] = CW'($signed((i[0] ? -1 : 1) * ((1 << CF) / (i + 2))));
    wait (rst_n);
    repeat (2) @(negedge clk);

    // ---- the combinational reference against the model -------------------
    for (int k = 0; k < 12; k++) begin
      samp = mk_samples(k);
      @(negedge clk);
      ck($sformatf("comb dp: got %0d want %0d", y_comb, dot_model(samp)),
         int'(y_comb) == dot_model(samp));
    end

    // ---- global stall: arithmetic, latency, and freezing -----------------
    g_en = 1'b1;
    for (int k = 0; k < 12; k++) begin
      samp = mk_samples(k);
      g_vi = 1'b1;
      @(negedge clk);
      g_vi = 1'b0;
      // Latency is exactly LAT cycles when never stalled.
      repeat (LAT - 1) @(negedge clk);
      ck($sformatf("global dp k=%0d: valid at latency %0d", k, LAT), g_vo === 1'b1);
      ck($sformatf("global dp k=%0d: got %0d want %0d", k, y_glob, dot_model(samp)),
         int'(y_glob) == dot_model(samp));
      @(negedge clk);
    end

    // A stall must freeze the output, for as long as it is held.
    samp = mk_samples(3);
    g_vi = 1'b1;
    @(negedge clk);
    g_vi = 1'b0;
    repeat (LAT - 1) @(negedge clk);
    held = y_glob;
    g_en = 1'b0;                       // stall
    samp = mk_samples(9);              // and change the inputs underneath it
    repeat (7) @(negedge clk);
    ck("global dp: output frozen while stalled", y_glob === held);
    ck("global dp: valid frozen while stalled", g_vo === 1'b1);
    g_en = 1'b1;
    @(negedge clk);

    // Flush must empty it.
    g_vi = 1'b1;
    @(negedge clk);
    g_vi    = 1'b0;
    g_flush = 1'b1;
    @(negedge clk);
    g_flush = 1'b0;
    ck("global dp: flush cleared busy", g_busy === 1'b0);
    ck("global dp: flush cleared valid", g_vo === 1'b0);
    repeat (2) @(negedge clk);

    dp_done = 1'b1;
  end

  // ===========================================================================
  // 3. Stall insensitivity of the elastic pipeline.
  //
  // The same 24-beat input sequence is pushed through three times, with
  // different random ready patterns. The OUTPUT SEQUENCE must be identical every
  // time: a pipeline whose result depends on when it was stalled is broken in a
  // way that only a differential test like this one exposes.
  // ===========================================================================
  // A SIGNED int, and compared below without a cast. `while (n < int'(NSEQ))` is
  // evaluated as false by XSIM and the loop never runs -- the bug documented in
  // docs/37 section 13, walked into a second time while writing this file. It
  // cost another debugging session, which is the argument for writing such things
  // down.
  localparam int NSEQ = 24;
  int elas_out [3][NSEQ];
  int elas_n   [3];
  logic elas_done = 1'b0;

  int   sent, got_n, trial_ix;
  logic e_took;

  // The same discipline as `step` above: present the stimulus for the coming
  // posedge, decide what that posedge will do, and only then let it happen.
  // Sampling `valid && ready` AFTER the edge counts the wrong cycle -- it
  // reported beats twice under heavy backpressure and made an otherwise correct
  // pipeline look stall-sensitive.
  task automatic estep(input logic want_valid, input logic want_ready);
    if (!e_sv || e_took) begin
      e_sv = want_valid;
      if (want_valid && (sent < NSEQ)) e_samp = mk_samples(sent);
      if (sent >= NSEQ) e_sv = 1'b0;
    end
    e_mr = want_ready;
    #1;
    if (e_mv && e_mr) begin
      if (got_n < NSEQ) elas_out[trial_ix][got_n] = int'(y_elas);
      got_n++;
    end
    e_took = e_sv && e_sr;
    @(negedge clk);
    if (e_took) sent++;
  endtask

  initial begin : run_elastic
    wait (dp_done);                     // `coef` is set up by run_dp
    repeat (2) @(negedge clk);

    for (int trial = 0; trial < 3; trial++) begin
      int guard;
      trial_ix = trial;
      sent  = 0;
      got_n = 0;
      guard = 0;
      e_sv  = 1'b0;
      e_mr  = 1'b1;
      e_took = 1'b0;

      while ((got_n < NSEQ) && (guard < 4000)) begin
        guard++;
        // Three patterns: clean, backpressure only, and backpressure WITH GAPS in
        // the input.
        //
        // The third one is not variety for its own sake. Offering the input
        // continuously keeps the pipeline full, and in a full pipeline every
        // per-stage enable is the same signal -- `can_take[i]` collapses to
        // `m_ready` for every i. So a datapath stage registered on the WRONG
        // stage's enable is invisible while the input never has a gap. Measured:
        // with trials 0 and 1 only, mis-wiring cut 3 to adv[0] passed this
        // testbench; with gaps it fails. Bubbles are the stimulus that makes
        // per-stage control observable.
        case (trial)
          0:       estep(1'b1, 1'b1);
          1:       estep(1'b1, ($urandom_range(0, 3) != 0));
          default: estep(($urandom_range(0, 3) != 0),
                         ($urandom_range(0, 1) != 0));
        endcase
      end
      elas_n[trial] = got_n;
      e_sv = 1'b0;
      e_mr = 1'b1;
      repeat (8) @(negedge clk);
      ck($sformatf("elastic trial %0d delivered %0d of %0d beats",
                   trial, got_n, NSEQ), got_n == NSEQ);
    end

    // Every trial must agree with the model, and therefore with each other.
    for (int k = 0; k < NSEQ; k++) begin
      int want;
      logic [TAPS*XW-1:0] xs;
      xs   = mk_samples(k);
      want = dot_model(xs);
      for (int t = 0; t < 3; t++)
        ck($sformatf("elastic trial %0d beat %0d: got %0d want %0d",
                     t, k, elas_out[t][k], want), elas_out[t][k] == want);
    end

    elas_done = 1'b1;
  end

  // ===========================================================================
  // 5. The skew buffer: two branches, one of which stalls.
  // ===========================================================================
  localparam int unsigned SK_DEPTH = 4;

  logic        a_valid = 1'b0, a_ready, b_valid = 1'b0, b_ready;
  logic [7:0]  a_data = '0, b_data = '0;
  logic        sk_mv, sk_mr = 1'b1;
  logic [7:0]  sk_a, sk_b;
  logic signed [$clog2(SK_DEPTH)+2:0] sk_skew;

  skew_buffer #(.DWA(8), .DWB(8), .DEPTH(SK_DEPTH)) u_skew (
    .clk, .rst_n,
    .a_valid(a_valid), .a_data(a_data), .a_ready(a_ready),
    .b_valid(b_valid), .b_data(b_data), .b_ready(b_ready),
    .m_valid(sk_mv), .m_a(sk_a), .m_b(sk_b), .m_ready(sk_mr),
    .skew(sk_skew));

  logic skew_done = 1'b0;

  initial begin : run_skew
    int an, bn, outn, max_skew, a_stalled;
    wait (rst_n);
    repeat (2) @(negedge clk);
    an = 0; bn = 0; outn = 0; max_skew = 0; a_stalled = 0;

    // Branch A offers a beat every cycle. Branch B is bursty -- it goes away for
    // a few cycles at a time, which is exactly the skew the buffer exists to
    // absorb.
    while (outn < 40 && an < 200) begin
      a_valid = (an < 60);
      a_data  = 8'(an);
      b_valid = (bn < 60) && ($urandom_range(0, 2) != 0);
      b_data  = 8'(bn + 100);
      @(negedge clk);
      if (sk_mv && sk_mr) begin
        // The pairing property: the n-th A with the n-th B, always.
        ck($sformatf("skew pair %0d: a=%0d b=%0d", outn, sk_a, sk_b),
           (sk_a === 8'(outn)) && (sk_b === 8'(outn + 100)));
        outn++;
      end
      if (a_valid && a_ready) an++;
      else if (a_valid)       a_stalled++;
      if (b_valid && b_ready) bn++;
      if (sk_skew > max_skew) max_skew = int'(sk_skew);
    end

    ck($sformatf("skew buffer paired %0d beats", outn), outn >= 40);
    // The fast branch must be allowed to run ahead: if it were never stalled the
    // depth is larger than needed, and if it stalls immediately the join is
    // coupling the branches.
    ck($sformatf("fast branch ran ahead (max skew %0d of DEPTH %0d)",
                 max_skew, SK_DEPTH), max_skew >= 2);
    $display("  [skew] max skew observed %0d of DEPTH %0d; branch A stalled %0d cycles",
             max_skew, SK_DEPTH, a_stalled);
    skew_done = 1'b1;
  end

  // ===========================================================================
  initial begin
    $display("");
    $display("=== pipeline_stall_tb ===");
    repeat (4) @(negedge clk);
    rst_n = 1'b1;

    for (int m = 0; m < int'(NMODE); m++) wait (mode_done[m]);
    wait (elas_done);
    wait (skew_done);

    $display("");
    $display("  axis_reg_slice, measured:");
    $display("    mode  beats/100cy  latency  fwd path      bwd path");
    for (int m = 0; m < int'(NMODE); m++)
      $display("    %s     %3d          %0d        %s  %s",
               MODE_NAME[m], rate_beats[m], latency[m],
               comb_fwd[m] ? "combinational" : "registered   ",
               comb_bwd[m] ? "combinational" : "registered   ");

    // The claims of the mode table in docs/38, as checks rather than comments.
    ck("PASS: forward path is combinational", comb_fwd[0] === 1'b1);
    ck("PASS: backward path is combinational", comb_bwd[0] === 1'b1);
    ck("FWD:  forward path is registered", comb_fwd[1] === 1'b0);
    ck("FWD:  backward path is combinational", comb_bwd[1] === 1'b1);
    ck("REV:  forward path is combinational", comb_fwd[2] === 1'b1);
    ck("REV:  backward path is registered", comb_bwd[2] === 1'b0);
    ck("FULL: forward path is registered", comb_fwd[3] === 1'b0);
    ck("FULL: backward path is registered", comb_bwd[3] === 1'b0);
    ck("HALF: forward path is registered", comb_fwd[4] === 1'b0);
    ck("HALF: backward path is registered", comb_bwd[4] === 1'b0);

    // Rates: full for everything except HALF, which is half.
    for (int m = 0; m < 4; m++)
      ck($sformatf("%s sustains ~1 beat/cycle (got %0d/100)",
                   MODE_NAME[m], rate_beats[m]), rate_beats[m] >= 95);
    ck($sformatf("HALF sustains ~1 beat per 2 cycles (got %0d/100)",
                 rate_beats[4]), (rate_beats[4] >= 45) && (rate_beats[4] <= 55));

    $display("");
    if (err == 0) $display("pipeline_stall_tb: PASS");
    else begin
      $display("pipeline_stall_tb: FAIL (%0d errors)", err);
      $fatal(1, "pipeline stall test failures");
    end
    $finish;
  end

  initial begin
    #20ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
