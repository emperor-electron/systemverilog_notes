// -----------------------------------------------------------------------------
// periph_tb.sv -- self-checking tests for the timer and I/O peripherals:
// clk_div_en, edge_detect, pulse_extend, debounce, watchdog, pwm, hex7seg.
//
// Every DUT input is driven from time 0, not from the start of its own test.
// These DUTs are instantiated for the whole simulation, so an input left at X
// until its test begins pushes X into that DUT's registers during the EARLIER
// tests -- and its assertions then fail while the testbench still prints PASS.
// See docs/33.
//
// Stimulus is driven on negedge and sampled on negedge throughout, so nothing
// races the edge the DUTs sample on.
//
// Run with XSIM:
//   xvlog -sv <rtl files> periph_tb.sv && xelab periph_tb -s sim && xsim sim -R
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module periph_tb;

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
  // clk_div_en -- tick spacing, and that `en` freezes rather than loses ticks
  // ===========================================================================
  logic en1 = 1'b0, en3 = 1'b0, en4 = 1'b0;
  logic t1, t3, t4;

  clk_div_en #(.DIV(1)) u_div1 (.clk, .rst_n, .en(en1), .tick(t1));
  clk_div_en #(.DIV(3)) u_div3 (.clk, .rst_n, .en(en3), .tick(t3));
  clk_div_en #(.DIV(4)) u_div4 (.clk, .rst_n, .en(en4), .tick(t4));

  task automatic test_clk_div_en();
    int n, gap, last, i;
    $display("[clk_div_en] DIV = 1, 3, 4 and enable gating");

    // DIV=1 degenerates to the enable itself.
    en1 = 1'b1; @(negedge clk);
    chk("DIV=1 ticks every enabled cycle", t1);
    en1 = 1'b0; @(negedge clk);
    chk("DIV=1 does not tick while disabled", !t1);

    // DIV=3: count ticks over a known window.
    en3 = 1'b1;
    n = 0;
    for (i = 0; i < 30; i++) begin
      @(negedge clk);
      if (t3) n++;
    end
    chk($sformatf("DIV=3 gives 10 ticks in 30 cycles (saw %0d)", n), n == 10);

    // DIV=4: measure the actual spacing rather than just the count.
    en4 = 1'b1;
    last = -1; gap = 0; n = 0;
    for (i = 0; i < 40; i++) begin
      @(negedge clk);
      if (t4) begin
        if (last >= 0) begin
          gap = i - last;
          chk($sformatf("DIV=4 tick spacing is 4 (saw %0d)", gap), gap == 4);
        end
        last = i;
        n++;
      end
    end
    chk($sformatf("DIV=4 produced ticks (saw %0d)", n), n >= 9);

    // Freezing the enable must hold the count, not drop ticks.
    en4 = 1'b0;
    repeat (7) @(negedge clk);
    chk("DIV=4 silent while disabled", !t4);
    en4 = 1'b1;
    n = 0;
    for (i = 0; i < 8; i++) begin
      @(negedge clk);
      if (t4) n++;
    end
    chk($sformatf("DIV=4 resumes after a freeze (saw %0d ticks)", n), n == 2);

    en1 = 1'b0; en3 = 1'b0; en4 = 1'b0;
  endtask

  // ===========================================================================
  // edge_detect
  // ===========================================================================
  logic ed_in = 1'b0;
  logic ed_r, ed_f, ed_a;

  edge_detect #(.INIT(1'b0)) u_ed (
    .clk, .rst_n, .d(ed_in), .rise(ed_r), .fall(ed_f), .any(ed_a));

  task automatic test_edge_detect();
    $display("[edge_detect] rise / fall / any");
    ed_in = 1'b0; @(negedge clk);
    chk("idle low: no edges", !ed_r && !ed_f && !ed_a);

    ed_in = 1'b1;
    #1;                                   // combinational, before the next edge
    chk("rise asserted on 0->1", ed_r && ed_a && !ed_f);
    @(negedge clk);
    chk("rise is one cycle only", !ed_r && !ed_a);

    ed_in = 1'b0;
    #1;
    chk("fall asserted on 1->0", ed_f && ed_a && !ed_r);
    @(negedge clk);
    chk("fall is one cycle only", !ed_f && !ed_a);
  endtask

  // ===========================================================================
  // pulse_extend -- both retrigger modes
  // ===========================================================================
  logic pe_in = 1'b0;
  logic pe_rt, pe_nort;

  pulse_extend #(.CYCLES(4), .RETRIGGER(1'b1)) u_pe_rt (
    .clk, .rst_n, .pulse_in(pe_in), .pulse_out(pe_rt));
  pulse_extend #(.CYCLES(4), .RETRIGGER(1'b0)) u_pe_nort (
    .clk, .rst_n, .pulse_in(pe_in), .pulse_out(pe_nort));

  task automatic test_pulse_extend();
    int hi;
    $display("[pulse_extend] CYCLES=4, retrigger on and off");

    // A single pulse: both modes stretch it to exactly 4 cycles.
    pe_in = 1'b1; @(negedge clk); pe_in = 1'b0;
    hi = 0;
    repeat (8) begin
      if (pe_rt) hi++;
      @(negedge clk);
    end
    chk($sformatf("single pulse stretched to 4 (saw %0d)", hi), hi == 4);

    repeat (4) @(negedge clk);

    // A second pulse two cycles into the window. RETRIGGER=1 restarts the
    // count and so runs longer; RETRIGGER=0 ignores it and stays at 4.
    begin
      int hi_rt, hi_no;
      hi_rt = 0; hi_no = 0;
      pe_in = 1'b1; @(negedge clk); pe_in = 1'b0;
      for (int i = 0; i < 12; i++) begin
        if (pe_rt)   hi_rt++;
        if (pe_nort) hi_no++;
        if (i == 1) pe_in = 1'b1;            // second pulse, mid-window
        else        pe_in = 1'b0;
        @(negedge clk);
      end
      chk($sformatf("RETRIGGER=0 ignores the second pulse (saw %0d, want 4)",
                    hi_no), hi_no == 4);
      chk($sformatf("RETRIGGER=1 restarts on the second pulse (saw %0d, want 6)",
                    hi_rt), hi_rt == 6);
    end

    repeat (12) @(negedge clk);
  endtask

  // ===========================================================================
  // debounce -- a bouncing input must not reach the output
  // ===========================================================================
  localparam int unsigned DB_STABLE = 8;
  logic db_in = 1'b0;
  logic db_q, db_r, db_f;

  debounce #(.STABLE_CYCLES(DB_STABLE)) u_db (
    .clk, .rst_n, .d(db_in), .q(db_q), .rise(db_r), .fall(db_f));

  task automatic test_debounce();
    int pulses;
    $display("[debounce] STABLE_CYCLES=%0d, with a bouncing contact", DB_STABLE);

    chk("starts low", !db_q);

    // Bounce for a while: the output must not move at all.
    pulses = 0;
    for (int i = 0; i < 20; i++) begin
      db_in = i[0];                        // alternate every cycle
      @(negedge clk);
      if (db_q) pulses++;
      if (db_r || db_f) pulses += 100;     // any edge here is a failure
    end
    chk("output never moves while the input bounces", pulses == 0);

    // Settle the input back to the current output value first, so the
    // stability counter is known to be zero. Without this the bounce above
    // leaves it part-way and the measurement below is off by one -- which is
    // correct behaviour, not a bug: the counter tracks "cycles disagreeing
    // with the output", and the last bounce half-cycle is one of them.
    db_in = 1'b0;
    repeat (3) @(negedge clk);

    // Now hold the new value and count exactly how long acceptance takes.
    db_in = 1'b1;
    begin
      int waited;
      waited = 0;
      while (!db_q && waited < 4 * DB_STABLE) begin
        @(negedge clk);
        waited++;
      end
      chk($sformatf("accepted after exactly %0d stable cycles (want %0d)",
                    waited, DB_STABLE), waited == DB_STABLE);
    end

    // And the rise pulse is exactly one cycle. Step past the cycle the loop
    // above exited on -- `rise` is asserted in that same cycle, so counting
    // from here would count the legitimate pulse as a repeat.
    @(negedge clk);
    pulses = 0;
    for (int i = 0; i < 6; i++) begin
      if (db_r) pulses++;
      @(negedge clk);
    end
    chk($sformatf("rise pulse is not repeated (saw %0d more)", pulses),
        pulses == 0);

    // Release, with bounce on the way down.
    for (int i = 0; i < 10; i++) begin
      db_in = ~i[0];
      @(negedge clk);
    end
    chk("still high through release bounce", db_q);
    db_in = 1'b0;
    repeat (DB_STABLE) @(negedge clk);
    chk("output low after a stable release", !db_q);
  endtask

  // ===========================================================================
  // watchdog -- windowed
  // ===========================================================================
  localparam int unsigned WD_TIMEOUT = 16;
  localparam int unsigned WD_WINDOW  = 4;
  logic wd_en = 1'b0, wd_kick = 1'b0, wd_clear = 1'b0;
  logic wd_exp, wd_early, wd_late, wd_inwin;

  watchdog #(.TIMEOUT(WD_TIMEOUT), .WINDOW_MIN(WD_WINDOW)) u_wd (
    .clk, .rst_n, .en(wd_en), .kick(wd_kick), .clear(wd_clear),
    .expired(wd_exp), .early_kick(wd_early), .late_kick(wd_late),
    .in_window(wd_inwin));

  task automatic test_watchdog();
    $display("[watchdog] TIMEOUT=%0d WINDOW_MIN=%0d", WD_TIMEOUT, WD_WINDOW);
    wd_en = 1'b1;

    // Kicking inside the window keeps it happy indefinitely.
    for (int i = 0; i < 5; i++) begin
      repeat (WD_WINDOW + 2) @(negedge clk);
      chk("in window before kicking", wd_inwin);
      wd_kick = 1'b1; @(negedge clk); wd_kick = 1'b0;
      chk("no expiry while served in window", !wd_exp);
    end

    // Too early: a kick before WINDOW_MIN is itself a fault.
    @(negedge clk);
    chk("not yet in window right after a kick", !wd_inwin);
    wd_kick = 1'b1; @(negedge clk); wd_kick = 1'b0;
    chk("early kick flagged", wd_early);
    chk("early kick expires the watchdog", wd_exp);

    // Sticky until cleared.
    repeat (5) @(negedge clk);
    chk("expiry is sticky", wd_exp);
    wd_clear = 1'b1; @(negedge clk); wd_clear = 1'b0;
    chk("clear deasserts expiry", !wd_exp);

    // Too late: stop kicking entirely.
    repeat (WD_TIMEOUT + 3) @(negedge clk);
    chk("late kick flagged as expiry", wd_exp);

    wd_clear = 1'b1; @(negedge clk); wd_clear = 1'b0;
    wd_en = 1'b0;
    chk("cleared again", !wd_exp);
  endtask

  // ===========================================================================
  // pwm -- duty cycle measured, including both endpoints
  // ===========================================================================
  localparam int unsigned PWM_PERIOD = 8;
  logic [7:0] pwm_period = 8'(PWM_PERIOD);
  logic [7:0] pwm_duty   = 8'd0;
  logic       pwm_en     = 1'b0;
  logic       pwm_o, pwm_tick;

  pwm #(.W(8)) u_pwm (
    .clk, .rst_n, .en(pwm_en), .period(pwm_period), .duty(pwm_duty),
    .pwm_out(pwm_o), .period_tick(pwm_tick));

  task automatic test_pwm();
    int hi;
    $display("[pwm] period=%0d, duty swept 0..%0d", PWM_PERIOD, PWM_PERIOD);
    pwm_en = 1'b1;

    for (int dd = 0; dd <= PWM_PERIOD; dd++) begin
      pwm_duty = 8'(dd);

      // Let the shadow register take the new duty at a period boundary.
      while (!pwm_tick) @(negedge clk);
      @(negedge clk);
      while (!pwm_tick) @(negedge clk);
      @(negedge clk);

      // Now measure exactly one period.
      hi = 0;
      for (int i = 0; i < PWM_PERIOD; i++) begin
        if (pwm_o) hi++;
        @(negedge clk);
      end
      chk($sformatf("duty %0d gives %0d high cycles of %0d",
                    dd, hi, PWM_PERIOD), hi == dd);
    end

    // The two endpoints, stated explicitly because they are the usual bugs.
    // `duty` is shadowed, so it takes effect at the NEXT period boundary --
    // wait for the tick and then one more cycle for the load, or the check
    // still sees the previous duty.
    pwm_duty = 8'd0;
    while (!pwm_tick) @(negedge clk);
    @(negedge clk);
    while (!pwm_tick) @(negedge clk);
    @(negedge clk);
    repeat (2 * PWM_PERIOD) begin
      chk("0%% duty never goes high", !pwm_o);
      @(negedge clk);
    end

    pwm_duty = 8'(PWM_PERIOD);
    while (!pwm_tick) @(negedge clk);
    @(negedge clk);
    while (!pwm_tick) @(negedge clk);
    @(negedge clk);
    repeat (2 * PWM_PERIOD) begin
      chk("100%% duty never goes low", pwm_o);
      @(negedge clk);
    end

    pwm_en = 1'b0;
  endtask

  // ===========================================================================
  // hex7seg
  // ===========================================================================
  logic [3:0] h_val   = 4'h0;
  logic       h_blank = 1'b0;
  logic [6:0] h_al, h_ah;

  hex7seg #(.ACTIVE_LOW(1'b1)) u_h_al (.val(h_val), .blank(h_blank), .seg(h_al));
  hex7seg #(.ACTIVE_LOW(1'b0)) u_h_ah (.val(h_val), .blank(h_blank), .seg(h_ah));

  task automatic test_hex7seg();
    logic [6:0] expect_pat [16];
    $display("[hex7seg] all 16 patterns, both polarities, and blanking");

    expect_pat = '{7'b0111111, 7'b0000110, 7'b1011011, 7'b1001111,
                   7'b1100110, 7'b1101101, 7'b1111101, 7'b0000111,
                   7'b1111111, 7'b1101111, 7'b1110111, 7'b1111100,
                   7'b0111001, 7'b1011110, 7'b1111001, 7'b1110001};

    for (int v = 0; v < 16; v++) begin
      h_val = 4'(v);
      #1;
      chk($sformatf("active-high pattern for %h", v[3:0]),
          h_ah === expect_pat[v]);
      chk($sformatf("active-low is the inverse for %h", v[3:0]),
          h_al === ~expect_pat[v]);
    end

    // Two structural facts that catch a mistyped table.
    h_val = 4'h8; #1;
    chk("8 lights every segment", h_ah === 7'b1111111);
    h_val = 4'h1; #1;
    chk("1 lights exactly two segments", $countones(h_ah) == 2);

    h_blank = 1'b1; #1;
    chk("blank clears all segments (active high)", h_ah === 7'b0000000);
    chk("blank clears all segments (active low)", h_al === 7'b1111111);
    h_blank = 1'b0;
  endtask

  // ===========================================================================
  initial begin
    $display("");
    $display("=== periph_tb ===");

    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_clk_div_en();
    test_edge_detect();
    test_pulse_extend();
    test_debounce();
    test_watchdog();
    test_pwm();
    test_hex7seg();

    $display("");
    if (errors == 0) $display("periph_tb: PASS");
    else begin
      $display("periph_tb: FAIL (%0d errors)", errors);
      $fatal(1, "peripheral test failures");
    end
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
