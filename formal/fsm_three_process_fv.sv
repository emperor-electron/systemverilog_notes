// -----------------------------------------------------------------------------
// fsm_three_process_fv.sv -- registering FSM outputs costs nothing.
//
// fsm_two_process decodes its outputs combinationally from `state`.
// fsm_three_process registers them, decoded from `next`. The claim this harness
// checks is that those two are CYCLE-FOR-CYCLE IDENTICAL -- that the second
// form buys a flop-driven output and a shorter path off the state decode
// without costing a cycle of latency.
//
// It is an equivalence check in the ordinary sense: same inputs into both, are
// the outputs ever different.
//
// WHY THE EQUIVALENCE IS `bmc` AND NOT `prove`
// Induction starts from an arbitrary state, in which the two DUTs' internal
// `state` and `cnt` registers hold unrelated values -- so their outputs differ
// and the step case fails immediately. Closing it needs the invariant
// `a.state == b.state && a.cnt == b.cnt`, and stating that needs hierarchical
// references into both DUTs, which the Yosys frontend silently mis-resolves
// (docs/25). So the equivalence is bounded, and the unbounded part of the claim
// -- that each output register always agrees with its own state -- is proved by
// the `prove` task from the invariants inside fsm_three_process.sv itself.
//
// Bounded to depth 30, which covers reset, a full LEN=3 transfer, and several
// back-to-back runs with arbitrary stalls on `grant` and `beat_ack`.
// -----------------------------------------------------------------------------
`default_nettype none

module fsm_three_process_fv #(
  parameter int unsigned CW = 4
) (
  input  var logic          clk,
  input  var logic          rst_n,
  input  var logic          start,
  input  var logic [CW-1:0] len,
  input  var logic          grant,
  input  var logic          beat_ack
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic [1:0] two_out, three_out;
  logic       two_done, three_done;

  fsm_two_process #(.CW(CW)) dut_two (
    .clk(clk), .rst_n(rst_n), .start(start), .len(len),
    .grant(grant), .beat_ack(beat_ack),
    .bus_req(two_out[0]), .beat_valid(two_out[1]), .done(two_done));

  fsm_three_process #(.CW(CW)) dut_three (
    .clk(clk), .rst_n(rst_n), .start(start), .len(len),
    .grant(grant), .beat_ack(beat_ack),
    .bus_req(three_out[0]), .beat_valid(three_out[1]), .done(three_done));

  // The equivalence itself. No `$past`, no delay term: the outputs are claimed
  // equal in the very same cycle.
  //
  // EQUIV is defined by the `bmc` and `cover` tasks only. The `prove` task
  // leaves it undefined so that induction is left with just the invariants
  // inside fsm_three_process.sv, which DO close -- rather than reporting a
  // failure that only means "this equivalence is not inductive".
`ifdef EQUIV
  always @(posedge clk) begin
    if (rst_n) begin
      f_req_eq   : assert (two_out[0]  == three_out[0]);
      f_valid_eq : assert (two_out[1]  == three_out[1]);
      f_done_eq  : assert (two_done    == three_done);
    end
  end
`endif

  // Reachability: without these the equivalence above could pass vacuously on
  // traces where the FSM never leaves IDLE and every output is a constant zero.
  always @(posedge clk) begin
    f_c_req  : cover (rst_n && three_out[0]);
    f_c_xfer : cover (rst_n && three_out[1]);
    f_c_done : cover (rst_n && three_done);
  end

endmodule

`default_nettype wire
