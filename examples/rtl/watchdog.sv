// -----------------------------------------------------------------------------
// watchdog.sv -- windowed watchdog timer.
//
// A watchdog answers one question: is the thing that is supposed to be running
// still running? Software (or a state machine) must "kick" it periodically. If
// the kicks stop, the watchdog expires and something drastic happens -- usually
// a reset.
//
// WHY A WINDOW. A plain watchdog only detects kicks that are too LATE, which
// catches a hang but not a runaway: code stuck in a tight loop that happens to
// contain the kick keeps the watchdog happy forever while doing nothing useful.
// A windowed watchdog also rejects kicks that are too EARLY, so the kick has to
// come from a path that takes about the right amount of time. That turns the
// watchdog from a hang detector into a crude control-flow-integrity check, and
// it is why safety standards ask for one.
//
// Set WINDOW_MIN = 0 to disable the early check and get an ordinary watchdog.
//
// `expired` is STICKY. A watchdog that clears itself is a watchdog whose
// failure can go unnoticed: the reset it requested must be observable
// afterwards so the system can tell a watchdog reset from a power-on reset.
// Clear it deliberately with `clear`.
//
// The counter is in raw clock cycles. For a real timeout, drive `en` from a
// clk_div_en tick rather than making TIMEOUT a 32-bit constant -- a prescaler
// costs one small counter, and a 32-bit compare on the critical path does not.
// -----------------------------------------------------------------------------
`default_nettype none

module watchdog #(
  parameter int unsigned TIMEOUT    = 1024,  // kick must arrive before this
  parameter int unsigned WINDOW_MIN = 0      // ...and not before this. 0 = off
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic en,            // count enable; typically a prescaler tick
  input  var logic kick,          // "I am still alive"
  input  var logic clear,         // clear a latched expiry
  output var logic expired,       // sticky: late kick, early kick, or timeout
  output var logic early_kick,    // one-cycle pulse: the kick came too soon
  output var logic late_kick,     // one-cycle pulse: the count ran out
  output var logic in_window      // a kick right now would be accepted
);

  if (TIMEOUT < 2) begin : g_chk_timeout
    $error("watchdog: TIMEOUT must be >= 2, got %0d", TIMEOUT);
  end
  if (WINDOW_MIN >= TIMEOUT) begin : g_chk_window
    $error("watchdog: WINDOW_MIN (%0d) must be < TIMEOUT (%0d)",
           WINDOW_MIN, TIMEOUT);
  end

  localparam int unsigned CW = $clog2(TIMEOUT);

  logic [CW-1:0] cnt;
  logic          at_limit;

  assign at_limit  = (cnt == CW'(TIMEOUT - 1));
  assign in_window = (cnt >= CW'(WINDOW_MIN));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt        <= '0;
      expired    <= 1'b0;
      early_kick <= 1'b0;
      late_kick  <= 1'b0;
    end else begin
      early_kick <= 1'b0;                 // default: one-cycle pulses
      late_kick  <= 1'b0;

      if (clear) begin
        expired <= 1'b0;
        cnt     <= '0;
      end else if (kick) begin
        // A kick is always consumed; whether it counts as service depends on
        // where in the window it landed. Checking this BEFORE the timeout test
        // means a kick on the last legal cycle is accepted, not raced.
        cnt <= '0;
        if (!in_window) begin
          early_kick <= 1'b1;
          expired    <= 1'b1;
        end
      end else if (en && !expired) begin
        if (at_limit) begin
          late_kick <= 1'b1;
          expired   <= 1'b1;              // counter holds; expiry is sticky
        end else begin
          cnt <= cnt + 1'b1;
        end
      end
    end
  end

`ifdef FORMAL
  // `cnt` and `at_limit` are internal, and a hierarchical reference from a
  // harness reads the wrong net under the Yosys frontend (docs/25), so the
  // properties that need them live here.
  //
  // The counter never passes its limit. Inductive: it only increments when
  // !at_limit, and every other path clears it.
  always @* f_cnt_bounded : assert (cnt <= CW'(TIMEOUT - 1));

  // A late kick is reported only when the count really did run out.
  logic f_past = 1'b0;
  always @(posedge clk) f_past <= 1'b1;

  always @(posedge clk)
    if (f_past && rst_n && $past(rst_n) && late_kick)
      f_late_is_real : assert ($past(at_limit) && $past(en) && !$past(kick));
`endif

`ifndef SYNTHESIS
  a_expired_sticky: assert property (@(posedge clk) disable iff (!rst_n)
    (expired && !clear) |=> expired)
    else $error("watchdog: expiry cleared itself");

  a_pulse_implies_expired: assert property (@(posedge clk) disable iff (!rst_n)
    (early_kick || late_kick) |-> expired);

  a_no_double_fault: assert property (@(posedge clk) disable iff (!rst_n)
    !(early_kick && late_kick));
`endif

endmodule

`default_nettype wire
