// -----------------------------------------------------------------------------
// pipe_ripple_ctrl.sv -- per-stage elastic control for an N-stage pipeline, with
// no storage added anywhere.
//
// The third answer to "how do I stall a pipeline", and the one that is usually
// reached for second:
//
//   1. GLOBAL STALL      one enable, broadcast to every stage (pipe_ctrl.sv).
//                        Logic depth 1, fanout N. Cheap, and it stalls stages
//                        that had no reason to stall.
//   2. RIPPLE (here)     each stage advances if the stage ahead of it can take
//                        its beat. Fanout 1 per net, logic depth N in the READY
//                        path. No extra storage: the pipeline registers ARE the
//                        elastic slots, and bubbles collapse.
//   3. SLICES            break the ready path with a register slice every few
//                        stages (axis_reg_slice.sv). Depth and fanout both
//                        bounded, at one slot per slice.
//
// THE CHAIN. Stage i can accept a new beat if it is empty, or if it can push
// what it holds into stage i+1:
//
//     can_take[N-1] = !valid[N-1] || m_ready
//     can_take[i]   = !valid[i]   || can_take[i+1]
//     s_ready       =  can_take[0]
//
// which is an N-input OR chain rooted at `m_ready`. That is the cost of this
// scheme and the reason it does not scale: at N=4 it is nothing, at N=40 it is
// the critical path, and the fix is to break it rather than to abandon the
// scheme (see docs/38).
//
// BUBBLES COLLAPSE, which is the property a global stall does not have. If stage
// 2 is empty and stage 1 holds a beat, stage 1 advances even while the output is
// stalled -- the pipeline packs itself towards the exit. A global stall freezes
// everything, so a bubble stays a bubble for the life of the beat.
//
// WHAT THIS MODULE DOES NOT DO. It controls `valid` and produces the per-stage
// advance enables; the datapath registers them with `if (adv[i])`. That split is
// deliberate: control is subtle and worth proving once, datapaths are wide and
// boring. dot_rs_elastic.sv is one datapath that uses it.
// -----------------------------------------------------------------------------
`default_nettype none

module pipe_ripple_ctrl #(
  parameter int unsigned STAGES = 4
) (
  input  var logic                clk,
  input  var logic                rst_n,

  input  var logic                s_valid,
  output var logic                s_ready,

  output var logic                m_valid,
  input  var logic                m_ready,

  input  var logic                flush,        // kill everything in flight

  // For the datapath: stage i must register its input when adv[i] is high, and
  // valid_q[i] says whether stage i currently holds a real beat.
  output var logic [STAGES-1:0]   adv,
  output var logic [STAGES-1:0]   valid_q
);

  if (STAGES < 1) begin : g_chk_stages
    $error("pipe_ripple_ctrl: STAGES must be >= 1, got %0d", STAGES);
  end

  logic [STAGES-1:0] can_take;

  // The backward chain. Written as a procedural loop because it is a REDUCTION
  // running from the output end to the input end: each element depends on the
  // one after it, so there is nothing to replicate (docs/37 section 4).
  always_comb begin
    can_take[STAGES-1] = !valid_q[STAGES-1] || m_ready;
    for (int i = int'(STAGES) - 2; i >= 0; i--)
      can_take[i] = !valid_q[i] || can_take[i+1];
  end

  assign adv = can_take;

  // FLUSH GATES BOTH ENDS, and this is a contract decision rather than an
  // implementation detail. A flush discards everything in flight, so during a
  // flush cycle this block must not ACCEPT a beat it is about to throw away, and
  // must not OFFER one that is about to cease to exist:
  //
  //   * without the gate on s_ready, a beat can be accepted by the handshake and
  //     discarded in the same cycle -- the producer counts it as delivered and
  //     the consumer never sees it. That is not a flush, it is a lost beat.
  //   * without the gate on m_valid, the consumer can take a beat in the same
  //     cycle the pipeline is aborted, which is worse: half an abort.
  //
  // Note what the gate on m_valid costs: valid goes low without ready having been
  // seen, which VIOLATES the valid/ready contract. That is unavoidable -- an
  // abort is a protocol violation by definition -- so `flush` must be visible to
  // both ends of the stream. A design that cannot arrange that needs to DRAIN
  // (stop offering and wait for `busy` to fall) instead of flushing. See docs/38.
  assign s_ready = can_take[0] && !flush;
  assign m_valid = valid_q[STAGES-1] && !flush;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= '0;
    end else if (flush) begin
      // Flush before advance, for the reason pipe_ctrl.sv gives: an aborted
      // pipeline must clear even while stalled, or the stale beats reappear when
      // the stall lifts.
      valid_q <= '0;
    end else begin
      for (int i = 0; i < int'(STAGES); i++)
        if (can_take[i])
          valid_q[i] <= (i == 0) ? s_valid : valid_q[i-1];
    end
  end

`ifdef FORMAL
  // Beat accounting, inside the module beside the state it accounts for -- the
  // standing rule (docs/25). Free-running counters, so the property is an exact
  // difference and not a bound: everything accepted is either still in a stage
  // or has left.
  logic [7:0] f_n_in, f_n_out;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_n_in  <= '0;
      f_n_out <= '0;
    end else if (flush) begin
      // A flush discards what is in flight, so the accounting has to be re-based
      // with it: leaving the counters alone made the difference between them
      // permanently wrong by however many beats were thrown away, and the
      // occupancy assertion below caught exactly that.
      f_n_in  <= '0;
      f_n_out <= '0;
    end else begin
      if (s_valid && s_ready) f_n_in  <= f_n_in  + 1'b1;
      if (m_valid && m_ready) f_n_out <= f_n_out + 1'b1;
    end
  end

  logic [7:0] f_occupancy;
  integer     fi;

  always_comb begin
    f_occupancy = '0;
    for (fi = 0; fi < int'(STAGES); fi = fi + 1)
      f_occupancy = f_occupancy + 8'(valid_q[fi]);
  end

  always @* begin
    assert ((f_n_in - f_n_out) == f_occupancy);
    // A stage can only be occupied if every stage ahead of it is occupied: beats
    // pack towards the exit. This is what makes the chain above sound -- and it
    // is the invariant induction needs, since without it the solver invents a
    // pipeline with a hole in it.
    for (fi = 1; fi < int'(STAGES); fi = fi + 1)
      assert (!valid_q[fi-1] || valid_q[fi] || can_take[fi]);
  end
`endif

`ifndef SYNTHESIS
  a_flush_clears: assert property (@(posedge clk) disable iff (!rst_n)
    flush |=> (valid_q == '0))
    else $error("pipe_ripple_ctrl: flush did not clear the pipeline");

  // A full pipeline with a stalled output must not accept anything.
  a_no_overrun: assert property (@(posedge clk) disable iff (!rst_n || flush)
    ((&valid_q) && !m_ready) |-> !s_ready)
    else $error("pipe_ripple_ctrl: accepted a beat into a full stalled pipeline");
`endif

endmodule

`default_nettype wire
