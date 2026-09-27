// -----------------------------------------------------------------------------
// axis_reg_slice_fv.sv -- one harness, five modes, one task each.
//
// The properties themselves are inside axis_reg_slice.sv, because the occupancy
// invariant that makes induction close needs the internal slot state and the
// Yosys flow cannot read into an instance. What is here is the environment: a
// well-behaved producer and consumer, and the reachability covers.
//
// WHAT EACH TASK SETTLES
//
//   m_pass  a wire loses nothing -- the degenerate case, and worth running
//           because it is the case where the sequence-number assertion must hold
//           with zero storage, which catches a harness that is accidentally
//           asserting something trivial.
//   m_fwd   the forward-registered slice, by induction.
//   m_rev   the ready-registered slice, by induction -- including the invariant
//           that its slot holds the NEXT beat out and not some other one.
//   m_full  the skid buffer, BOUNDED (see below).
//   m_half  the half-rate slice, by induction, plus its defining structural
//           property: two consecutive input transfers are impossible.
//
// WHY m_full IS BOUNDED. The FULL mode instantiates skid_buffer, whose storage
// axis_reg_slice cannot see, so the occupancy invariant cannot be stated at this
// level and induction has nothing to stand on. That is not a gap: skid_buffer_fv
// proves the same property unboundedly where the state IS visible. Duplicating
// the proof here by exporting the internals would be changing the design to suit
// the tool.
// -----------------------------------------------------------------------------
`default_nettype none

module axis_reg_slice_fv #(
  parameter int unsigned DW = 4
) (
  input  var logic          clk,
  input  var logic          rst_n,
  input  var logic          s_valid,
  input  var logic          m_ready,
  // FREE, and it must stay free. axis_reg_slice.sv constrains it with
  //     always @* assume (s_data == fv_in_seq);
  // so driving it from the harness as well makes the two constraints fight: tie
  // it to zero and the assumption becomes unsatisfiable the moment the counter
  // increments, at which point every task passes VACUOUSLY. That is exactly what
  // the first version of this file did, and the tell was the cover task failing
  // with every point unreachable -- an assumption nothing can satisfy makes
  // nothing reachable. Covers earn their place as a vacuity alarm, not as
  // documentation.
  input  var logic [DW-1:0] s_data
);

`ifdef M_PASS
  localparam int unsigned MODE = 0;
`elsif M_FWD
  localparam int unsigned MODE = 1;
`elsif M_REV
  localparam int unsigned MODE = 2;
`elsif M_FULL
  localparam int unsigned MODE = 3;
`else
  localparam int unsigned MODE = 4;
`endif

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic [DW-1:0] m_data;
  logic          s_ready, m_valid;

  axis_reg_slice #(.DW(DW), .MODE(MODE)) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .s_valid (s_valid),
    .s_data  (s_data),
    .s_ready (s_ready),
    .m_valid (m_valid),
    .m_data  (m_data),
    .m_ready (m_ready)
  );

  // The producer's side of the contract, assumed (docs/30): valid is not
  // withdrawn before the beat is taken. The payload needs no assumption -- the
  // module constrains it to its own sequence counter.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_valid) && !$past(s_ready))
      assume (s_valid);

  always @(posedge clk) begin
    f_c_move        : cover (rst_n && m_valid && m_ready);
    f_c_backpressure: cover (rst_n && m_valid && !m_ready);
    f_c_upstream_wait: cover (rst_n && s_valid && !s_ready);
`ifndef M_HALF
    // Every mode except HALF can take a beat in two consecutive cycles. For HALF
    // that is not a cover but an impossibility, asserted inside the module.
    f_c_b2b         : cover (rst_n && past_ok && $past(s_valid && s_ready)
                                              && s_valid && s_ready);
`endif
  end

endmodule

`default_nettype wire
