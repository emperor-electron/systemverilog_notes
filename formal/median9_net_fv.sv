// -----------------------------------------------------------------------------
// median9_net_fv.sv -- the 19-comparator median selection network, proved two
// independent ways.
//
// 1. EQUIVALENCE WITH A FULL SORT (`equiv`). The same nine values go through
//    sort_network with N=9, whose own proof establishes that it sorts, and the
//    middle element of that sorted result is the median by definition. So this
//    compares a cheap selection network against an expensive but obviously
//    correct one -- and at W=1 the 0-1 PRINCIPLE makes it a proof for EVERY
//    element width.
//
//    The 0-1 principle applies to selection as well as sorting, for the same
//    reason: a comparator network commutes with any monotone function applied
//    elementwise, and thresholding at each value in turn reduces the general
//    case to the 0/1 case. Formally, for the threshold t_v(x) = (x >= v),
//    t_v(net(x)) = net(t_v(x)) = median(t_v(x)) = t_v(median(x)) for every v,
//    which forces net(x) = median(x).
//
// 2. AN IMPLEMENTATION-FREE CHARACTERISATION (`wide`). Inside median9_net.sv:
//    the output is one of the nine inputs, at least five inputs are >= it, and
//    at least five are <= it. Nothing but the median satisfies all three, and
//    none of the three mentions an algorithm -- so unlike a reference model, this
//    cannot agree with the design by sharing its mistake. It is checked here at
//    W=4, where it does not depend on the 0-1 principle either.
//
// NO INDUCTION AND NO DEPTH. Both networks are purely combinational: there is no
// state for induction to reason about, so a single BMC step covers the entire
// input space. `depth 1` is not a bound here, it is the whole proof.
// -----------------------------------------------------------------------------
`default_nettype none

module median9_net_fv #(
`ifdef W4
  parameter int unsigned W = 4      // the characterisation at a real width
`else
  parameter int unsigned W = 1      // 0-1 principle: a proof for every width
`endif
) (
  input  var logic           clk,
  input  var logic [9*W-1:0] din
);

  logic [W-1:0] med;

  median9_net #(.W(W)) dut (.din(din), .med(med));

  // The reference: a full sort of the same nine values.
  logic [9*W-1:0] sorted;
  logic [W-1:0]   ref_med;

  sort_network #(.N(9), .W(W)) u_ref (
    .din(din), .dout(sorted), .median(ref_med));

  always @(posedge clk) begin
    f_equiv : assert (med == ref_med);
  end

  always @(posedge clk) begin
    // The network must actually select, not pass its centre element through.
    f_c_changed : cover (med != din[4*W +: W]);
    f_c_flat    : cover (din == '0);
    // A median equal to the largest input: only reachable when five of the nine
    // are at that value, which is worth knowing the solver can construct.
    f_c_at_max  : cover ((med == sorted[8*W +: W]) && (med != sorted[0 +: W]));
  end

endmodule

`default_nettype wire
