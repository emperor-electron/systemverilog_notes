// -----------------------------------------------------------------------------
// timer.sv -- down-counting timer, one-shot or periodic.
//
// Counts DOWN from `reload` to zero rather than up to a compare value. Both work
// and down is better: the terminal condition is `count == 0`, which is a
// NOR of the count bits, while up-counting needs a full-width comparator against
// a register. On a 32-bit timer that is the difference between one gate delay
// and a carry chain, and the compare is on the critical path by construction.
//
// PERIODIC RELOAD IS OFF BY ONE IF YOU ARE NOT CAREFUL. A timer that reloads
// with `reload` and counts to zero spends reload+1 cycles per period, because
// the zero cycle is a cycle too. This one reloads with `reload` and treats the
// transition INTO zero as the expiry, so the period is exactly reload+1 ticks
// and that is stated rather than discovered. Software wanting N ticks writes
// N-1, which is the same convention every real timer peripheral uses.
//
// `tick_en` is the prescaler input: drive it from clk_div_en so the counter runs
// at whatever rate you need without making `reload` 32 bits of microseconds.
//
// `expired` is a one-cycle pulse, suitable for feeding irq_ctrl, which does the
// latching. A timer that latches its own flag duplicates the interrupt
// controller badly; see irq_ctrl.sv.
// -----------------------------------------------------------------------------
`default_nettype none

module timer #(
  parameter int unsigned W = 32
) (
  input  var logic         clk,
  input  var logic         rst_n,

  input  var logic         tick_en,     // prescaler tick; 1'b1 to run at clk
  input  var logic         start,       // load `reload` and run
  input  var logic         stop,        // halt, keeping the current count
  input  var logic         periodic,    // 1 = auto-reload, 0 = one-shot
  input  var logic [W-1:0] reload,

  output var logic [W-1:0] count,
  output var logic         running,
  output var logic         expired      // one cycle when the count reaches zero
);

  logic at_zero;

  assign at_zero = (count == '0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      count   <= '0;
      running <= 1'b0;
      expired <= 1'b0;
    end else begin
      expired <= 1'b0;                         // default: a one-cycle pulse

      // `start` beats `stop`, and both beat counting. Stating the priority
      // explicitly matters: a start and a stop in the same cycle has to do
      // something, and "whichever the case statement reached first" is not a
      // specification.
      if (start) begin
        count   <= reload;
        running <= 1'b1;
      end else if (stop) begin
        running <= 1'b0;
      end else if (running && tick_en) begin
        if (at_zero) begin
          expired <= 1'b1;
          if (periodic) begin
            count <= reload;                   // period is reload+1 ticks
          end else begin
            running <= 1'b0;                   // one-shot: stop at zero
          end
        end else begin
          count <= count - 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  a_expired_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    expired |=> !expired);

  a_expired_only_running: assert property (@(posedge clk) disable iff (!rst_n)
    expired |-> $past(running && tick_en))
    else $error("timer: expired while not running");

  a_oneshot_stops: assert property (@(posedge clk) disable iff (!rst_n)
    (expired && !$past(periodic) && !start) |-> !running)
    else $error("timer: one-shot kept running past expiry");
`endif

endmodule

`default_nettype wire
