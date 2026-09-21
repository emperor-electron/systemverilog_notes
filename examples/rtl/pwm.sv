// -----------------------------------------------------------------------------
// pwm.sv -- pulse-width modulator.
//
// Counts 0 .. PERIOD-1 and drives the output high while the count is below
// DUTY. Used for LED brightness, motor drive, class-D audio, and as a
// single-bit DAC in front of an RC filter.
//
// THE TWO ENDPOINTS ARE THE WHOLE DESIGN. Almost every hand-written PWM gets
// one of them wrong:
//
//   duty == 0       must give a CONSTANT LOW output. `cnt < duty` gives that
//                   for free; `cnt <= duty` does not -- it emits a one-cycle
//                   sliver at 0% and a motor driver will happily turn that into
//                   an audible tick.
//   duty >= period  must give a CONSTANT HIGH output, with no glitch at the
//                   wrap. `cnt < duty` gives that too, since cnt never reaches
//                   period.
//
// So the comparison is strictly-less-than, and both endpoints then need no
// special case at all. That is worth stating because the obvious "fix" for one
// endpoint usually breaks the other.
//
// `duty` is sampled once per period into a shadow register. Changing the duty
// cycle mid-period would otherwise produce a short or long pulse on the
// changeover -- harmless in an LED, not harmless in a half-bridge.
// -----------------------------------------------------------------------------
`default_nettype none

module pwm #(
  parameter int unsigned W = 8
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         en,           // count enable; typically a prescaler
  input  var logic [W-1:0] period,       // 0 is treated as 1 (always wrapping)
  input  var logic [W-1:0] duty,
  output var logic         pwm_out,
  output var logic         period_tick   // one cycle at the start of a period
);

  logic [W-1:0] cnt;
  logic [W-1:0] duty_q;      // shadow: updated only at a period boundary
  logic [W-1:0] last;
  logic         wrap;

  // The last count of a period is period-1, not period. Wrapping on `period`
  // makes the period period+1 cycles long, which puts one stray low cycle into
  // a 100%-duty output -- the exact glitch this module claims not to have.
  //
  // `>=` rather than `==` so that shrinking `period` while the counter is
  // already above the new limit wraps immediately instead of counting all the
  // way round.
  assign last = (period == '0) ? '0 : (period - 1'b1);
  assign wrap = (cnt >= last);
  assign period_tick = en && wrap;
  assign pwm_out     = (cnt < duty_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt    <= '0;
      duty_q <= '0;
    end else if (en) begin
      if (wrap) begin
        cnt    <= '0;
        duty_q <= duty;      // take the new duty only between periods
      end else begin
        cnt <= cnt + 1'b1;
      end
    end
  end

`ifdef FORMAL
  // Proved under the assumption that `period` is stable (see the harness):
  // it is a configuration input, and a period that changes every cycle has no
  // duty cycle to reason about.
  always @* begin
    f_cnt_bounded : assert (cnt <= last);
    // The claim the endpoint comment makes: a duty at or above the period is a
    // constant-high output, with no stray low cycle at the wrap.
    if (duty_q >= period && period != '0) f_full_duty : assert (pwm_out);
    if (duty_q == '0)                     f_zero_duty : assert (!pwm_out);
  end
`endif

`ifndef SYNTHESIS
  a_zero_duty_is_low: assert property (@(posedge clk) disable iff (!rst_n)
    (duty_q == '0) |-> !pwm_out)
    else $error("pwm: output high at 0%% duty");
`endif

endmodule

`default_nettype wire
