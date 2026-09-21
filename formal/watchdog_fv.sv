// -----------------------------------------------------------------------------
// watchdog_fv.sv -- a watchdog that clears itself is not a watchdog.
//
// The safety-relevant property of a watchdog is not that it expires when it
// should; it is that once it HAS expired, that fact survives until software
// deliberately acknowledges it. A watchdog whose expiry decays lets a system
// reset itself and come back with no evidence of why, which is how a fault that
// happens once an hour in the field becomes unattributable.
//
// So the headline property here is stickiness, proved unbounded, plus the
// guarantee that the flag is never set for no reason.
// -----------------------------------------------------------------------------
`default_nettype none

module watchdog_fv #(
  parameter int unsigned TIMEOUT    = 8,
  parameter int unsigned WINDOW_MIN = 3
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic en,
  input  var logic kick,
  input  var logic clear
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic expired, early_kick, late_kick, in_window;

  watchdog #(.TIMEOUT(TIMEOUT), .WINDOW_MIN(WINDOW_MIN)) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .kick(kick), .clear(clear),
    .expired(expired), .early_kick(early_kick), .late_kick(late_kick),
    .in_window(in_window));

  // Stickiness: nothing but `clear` takes the flag down.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(expired) && !$past(clear))
      f_sticky : assert (expired);

  // No spurious expiry: the flag only RISES on a reported fault.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && expired && !$past(expired))
      f_no_spurious : assert (early_kick || late_kick);

  // An early kick really was outside the window.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && early_kick)
      f_early_is_real : assert ($past(kick) && !$past(in_window));

  // The two fault causes are distinguishable, which is what makes the flag
  // useful for diagnosis rather than just for resetting.
  always @* f_one_cause : assert (!(early_kick && late_kick));

  always @(posedge clk) begin
    f_c_late    : cover (rst_n && late_kick);
    f_c_early   : cover (rst_n && early_kick);
    f_c_cleared : cover (rst_n && !expired && $past(expired));
    f_c_served  : cover (rst_n && in_window && kick && !expired);
  end

endmodule

`default_nettype wire
