// -----------------------------------------------------------------------------
// fsm_safe_fv.sv -- illegal-state recovery, proved over all 16 encodings.
//
// This is the case formal verification is unreasonably good at and simulation
// is bad at. A 4-state one-hot FSM has 12 illegal encodings. None is reachable
// from reset, so no amount of constrained-random stimulus will ever visit one;
// a testbench can only get there by forcing the state register, which means
// hand-picking which of the 12 to try. Induction starts from an ARBITRARY
// state, so it covers all 12 without being told they exist.
//
// A TRAP THIS HARNESS WALKED INTO FIRST
// The obvious way to write the recovery property is to assert both of these in
// the same proof:
//
//     f_legal_reachable : assert (!state_err);                       // (1)
//     f_recovers_in_one : assert (!($past(state_err) && state_err)); // (2)
//
// and it proves nothing. Induction ASSUMES every asserted property in the
// preceding steps, so (1) at step t-1 hands (2) the assumption
// `!$past(state_err)` and (2) becomes vacuously true. The first version of this
// file did exactly that and passed cleanly with the recovery term REMOVED --
// the negative control is what caught it, not the proof.
//
// The fix is to prove the two claims in separate tasks, so that the task
// checking recovery has nothing constraining the previous state:
//
//   prove    (1) reachable states are legal -- the everyday invariant.
//   recover  (2) alone, with (1) compiled out, so the previous state really is
//            arbitrary and the property really does quantify over all 12
//            illegal encodings.
//
// With `recover` set up that way, rebuilding against .SAFE(1'b0) fails with a
// counterexample parked in the absorbing all-zeros state -- which is the
// evidence that the recovery term does something. See docs/26.
// -----------------------------------------------------------------------------
`default_nettype none

module fsm_safe_fv (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic start,
  input  var logic grant,
  input  var logic last_beat
);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic bus_req, done, state_err;

  fsm_safe #(.SAFE(1'b1)) dut (
    .clk(clk), .rst_n(rst_n), .start(start), .grant(grant),
    .last_beat(last_beat), .bus_req(bus_req), .done(done),
    .state_err(state_err));

`ifdef RECOVERY_ONLY
  // The `recover` task, run as BMC and NOT as induction, with no reset
  // assumption anywhere. That combination is the whole point: BMC proves every
  // step rather than assuming earlier ones, and a state register with no
  // initialiser is left free at step 0, so `state` there ranges over all 16
  // encodings -- the 12 illegal ones included.
  //
  // Reset is held INACTIVE so that recovery has to be the next-state logic's
  // own doing and cannot be credited to the reset that would have fixed it
  // anyway.
  always @* assume (rst_n);

  always @(posedge clk)
    if (past_ok) f_recovers_in_one : assert (!state_err);
`else
  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  // Reachable states are legal. Inductive on its own: one-hot in, one-hot out.
  // Note this holds even with SAFE=0 -- legal states never lead anywhere
  // illegal. It is a real property, but it is not the recovery property, and
  // conflating the two is the trap described in the header.
  always @(posedge clk)
    if (rst_n) f_legal_reachable : assert (!state_err);

  // The recovery must not drive the bus on its way home.
  always @(posedge clk)
    if (rst_n) f_no_spurious : assert (!state_err || !(bus_req || done));

  always @(posedge clk) begin
    f_c_req  : cover (rst_n && bus_req);
    f_c_done : cover (rst_n && done);
  end
`endif

endmodule

`default_nettype wire
