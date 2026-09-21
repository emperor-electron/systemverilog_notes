// -----------------------------------------------------------------------------
// debounce.sv -- mechanical switch debouncer.
//
// A physical contact bounces for somewhere between a few hundred microseconds
// and a few milliseconds. Sampled by a 50 MHz clock that is tens of thousands
// of transitions, and every one of them looks like a real button press to the
// logic behind it.
//
// The filter: the output only follows the input once the input has held its new
// value for STABLE_CYCLES consecutive clocks. Any glitch back to the old value
// restarts the count. That is an integrator, not a one-shot timer, which is
// what makes it immune to a burst that happens to straddle a timer expiry.
//
// SIZING: STABLE_CYCLES should be longer than the worst-case bounce and shorter
// than the fastest press a human can make -- roughly 1ms to 20ms. At 50 MHz,
// 5ms is 250_000. The default here is small so simulation is quick; set it from
// the real clock rate.
//
// THE INPUT MUST BE SYNCHRONIZED FIRST. A raw pin is asynchronous to this
// clock, and this module's flops are not synchronizers. Put a cdc_bit in front
// (docs/28). Debouncing does NOT subsume synchronization: a metastable sample
// can resolve either way, so it corrupts the stability count rather than being
// filtered by it.
// -----------------------------------------------------------------------------
`default_nettype none

module debounce #(
  parameter int unsigned STABLE_CYCLES = 16,
  parameter bit          INIT          = 1'b0
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic d,          // synchronized, still bouncing
  output var logic q,          // debounced level
  output var logic rise,       // one-cycle pulse on a clean 0->1
  output var logic fall        // one-cycle pulse on a clean 1->0
);

  if (STABLE_CYCLES == 0) begin : g_chk
    $error("debounce: STABLE_CYCLES must be >= 1");
  end

  localparam int unsigned CW = (STABLE_CYCLES <= 1) ? 1 : $clog2(STABLE_CYCLES);

  logic [CW-1:0] cnt;
  logic          q_r;
  logic          settled;

  assign settled = (cnt == CW'(STABLE_CYCLES - 1));
  assign q       = q_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt  <= '0;
      q_r  <= INIT;
      rise <= 1'b0;
      fall <= 1'b0;
    end else begin
      rise <= 1'b0;                      // default: one-cycle pulses
      fall <= 1'b0;

      if (d == q_r) begin
        cnt <= '0;                       // agrees with the output: nothing to do
      end else if (settled) begin
        q_r  <= d;                       // held long enough: accept the change
        cnt  <= '0;
        rise <=  d;
        fall <= ~d;
      end else begin
        cnt <= cnt + 1'b1;               // disagrees: count toward accepting it
      end
    end
  end

endmodule

`default_nettype wire
