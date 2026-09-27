// -----------------------------------------------------------------------------
// pipe_ripple_ctrl_fv.sv -- the elastic control that has no storage of its own.
//
// Everything substantive is inside pipe_ripple_ctrl.sv, because it needs the
// per-stage valid bits:
//
//   * beats in flight == accepted minus delivered, EXACTLY (not a bound -- see
//     the note in vid_axis_win3.sv for why a bound does not survive induction);
//   * beats pack towards the exit, so the occupied stages are contiguous. This is
//     the invariant that makes the ready chain sound, and without it induction
//     invents a pipeline with a hole in the middle.
//
// The harness supplies a well-behaved producer and consumer and the covers. The
// covers are not decoration: an assumption nothing can satisfy makes every
// assertion pass, and the only cheap alarm for that is a cover that should be
// reachable and is not. axis_reg_slice_fv.sv carries the story of the time that
// mattered.
// -----------------------------------------------------------------------------
`default_nettype none

module pipe_ripple_ctrl_fv #(
  parameter int unsigned STAGES = 4
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic s_valid,
  input  var logic m_ready,
  input  var logic flush
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic                s_ready, m_valid;
  logic [STAGES-1:0]   adv, valid_q;

  pipe_ripple_ctrl #(.STAGES(STAGES)) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .s_valid (s_valid),
    .s_ready (s_ready),
    .m_valid (m_valid),
    .m_ready (m_ready),
    .flush   (flush),
    .adv     (adv),
    .valid_q (valid_q)
  );

  // The producer does not withdraw an offer. Without this the accounting
  // property is still true but the design is being asked to cope with a
  // protocol violation, which is a different question.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && !$past(flush)
        && $past(s_valid) && !$past(s_ready))
      assume (s_valid);

  always @(posedge clk) begin
    f_c_fill        : cover (rst_n && (&valid_q));
    f_c_drain       : cover (rst_n && (valid_q == '0) && past_ok && $past(|valid_q));
    f_c_backpressure: cover (rst_n && m_valid && !m_ready);
    // A bubble in the middle being squeezed out: stage 0 occupied, the exit
    // empty, and the pipeline advancing anyway. This is the behaviour a global
    // stall does not have, so it is worth knowing the solver can reach it.
    f_c_collapse    : cover (rst_n && valid_q[0] && !valid_q[STAGES-1] && adv[0]);
  end

endmodule

`default_nettype wire
