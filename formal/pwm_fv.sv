// -----------------------------------------------------------------------------
// pwm_fv.sv -- the two endpoints, proved rather than sampled.
//
// A PWM is easy to test at 50% and easy to get wrong at 0% and 100%. Those two
// cases are also the ones where being wrong is worst: a one-cycle sliver at
// nominally-0% duty is an audible tick in a motor drive and a visible flicker
// in an LED dimmer, and it is invisible in a testbench that sweeps duty in
// steps of ten.
//
// `period` is assumed STABLE. It is a configuration input, and a period that
// changes every cycle has no duty cycle to reason about -- the counter would be
// chasing a moving limit. This is an assume-guarantee split: the module
// guarantees a clean output for a fixed period, and the caller guarantees not
// to move the period underneath it. State the assumption, and it is checkable
// at the caller; leave it out, and the proof is about a design nobody builds.
//
// The endpoint properties themselves live inside pwm.sv, because they talk
// about the shadow register `duty_q` and the counter, both internal.
// -----------------------------------------------------------------------------
`default_nettype none

module pwm_fv #(
  parameter int unsigned W = 4
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         en,
  input  var logic [W-1:0] period,
  input  var logic [W-1:0] duty
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  // See the header: period is configuration, not a per-cycle input.
  always @(posedge clk) if (!init) assume ($stable(period));
  always @* assume (period != '0);

  logic pwm_out, period_tick;

  pwm #(.W(W)) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .period(period), .duty(duty),
    .pwm_out(pwm_out), .period_tick(period_tick));

  // Reachability, so the endpoint assertions cannot pass by never applying.
  always @(posedge clk) begin
    f_c_high   : cover (rst_n &&  pwm_out);
    f_c_low    : cover (rst_n && !pwm_out);
    f_c_wrap   : cover (rst_n && period_tick);
    f_c_full   : cover (rst_n && (duty >= period) && pwm_out);
  end

endmodule

`default_nettype wire
