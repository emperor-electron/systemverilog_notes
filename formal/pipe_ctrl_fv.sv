// -----------------------------------------------------------------------------
// pipe_ctrl_fv.sv -- functional proof of the pipeline control block.
//
// This is a FULL functional proof, not a set of spot checks: the harness builds
// an independent shift-register reference and proves the DUT equals it in every
// reachable state, for every sequence of en/flush/valid_i. `prove` mode makes
// that claim unbounded -- it holds for all time, not just the first N cycles.
//
// THE THREE PATTERNS EVERY SEQUENTIAL HARNESS NEEDS
//   1. A defined starting point. `init` forces reset in cycle 0, so the solver
//      cannot begin in a fabricated state. After that rst_n is free, so
//      reset-during-operation is explored too.
//   2. `past_ok`, because $past is meaningless in the first cycle and asserting
//      over it produces bogus counterexamples.
//   3. A reference model built from the SPEC, not copied from the DUT.
//
// See docs/25-formal-verification-with-sby.md.
// -----------------------------------------------------------------------------
`default_nettype none

module pipe_ctrl_fv #(
  parameter int unsigned STAGES = 4
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic en,
  input  var logic flush,
  input  var logic valid_i
);

  // ---- 1. defined starting point -------------------------------------------
  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  // ---- 2. $past guard ------------------------------------------------------
  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  // ---- DUT -----------------------------------------------------------------
  logic                valid_o, busy;
  logic [STAGES-1:0]   valid_q;

  pipe_ctrl #(.STAGES(STAGES)) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .flush(flush), .valid_i(valid_i),
    .valid_o(valid_o), .valid_q(valid_q), .busy(busy));

  // ---- 3. independent reference --------------------------------------------
  // Written from the specification in docs/21: a shift register that advances
  // only on `en`, cleared by reset or flush, with flush winning over en.
  logic [STAGES-1:0] ref_q = '0;
  always @(posedge clk) begin
    if      (!rst_n) ref_q <= '0;
    else if (flush)  ref_q <= '0;
    else if (en)     ref_q <= {ref_q[STAGES-2:0], valid_i};
  end

  always @(posedge clk) begin
    if (rst_n) begin
      // Full functional equivalence.
      a_equiv   : assert (valid_q == ref_q);
      // The output and status decodes.
      a_valid_o : assert (valid_o == valid_q[STAGES-1]);
      a_busy    : assert (busy    == (|valid_q));

      if (past_ok) begin
        // A stall must freeze the pipeline exactly.
        a_stall   : assert (!( $past(rst_n) && !$past(en) && !$past(flush))
                            || (valid_q == $past(valid_q)));
        // Flush must empty it in one cycle, EVEN WHILE STALLED. This is the
        // property that fails if `en` is tested before `flush`.
        a_flush   : assert (!($past(rst_n) && $past(flush)) || (valid_q == '0));
      end
    end
  end

  // Reachability: prove the interesting situations are not vacuous.
  always @(posedge clk) begin
    c_full      : cover (rst_n && valid_q == '1);
    c_drained   : cover (rst_n && past_ok && $past(busy) && !busy);
    c_flush_busy: cover (rst_n && past_ok && $past(flush) && $past(busy));
    c_stall_busy: cover (rst_n && !en && busy);
  end

endmodule

`default_nettype wire
