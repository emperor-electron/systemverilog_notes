// -----------------------------------------------------------------------------
// median9_net.sv -- median of nine values in a fixed comparator network.
//
// The core of a 3x3 median filter, kept as its own combinational module so that
// it can be proved once, independently of the streaming wrapper that replicates
// it N*P times (vid_axis_median3.sv).
//
// WHY NOT JUST SORT. sort_network.sv with N=9 gives the median as a by-product:
// 9 stages and 36 comparators. But the median does not need the other eight
// values, and a selection network is much cheaper:
//
//                       comparators   depth
//     full sort of 9         36         9
//     this network           19         6        <-- 47% of the comparators
//
// THE ALGORITHM (Smith's, and exact -- not an approximation):
//
//   1. sort each of the three rows                     3 x 3 = 9 comparators
//   2. lo  = max of the three row minima                        2
//      mid = median of the three row medians                    3
//      hi  = min of the three row maxima                        2
//   3. median = median of (lo, mid, hi)                         3
//
// Step 2 is the part that is not obvious: the overall median can lie neither
// below `lo` nor above `hi`, so clamping `mid` into that range -- which is what
// the final median-of-three does -- is enough. That argument is short and easy
// to get subtly wrong, which is why this file carries a proof rather than an
// argument:
// formal/median9_net_fv.sby proves it against sort_network's median for W=1,
// and by the 0-1 PRINCIPLE that is a proof for every width. (A comparator
// network commutes with any monotone function applied elementwise; thresholding
// at each value in turn reduces the general case to the 0/1 case.)
//
// The same file also proves the characterisation that needs no reference at all:
// the output is one of the nine inputs, at least five inputs are >= it, and at
// least five are <= it. Nothing but the median can satisfy all three.
//
// COMPARE-EXCHANGE IS A MUX, NOT A BRANCH. srt3 below is written with `if` and a
// temporary, which reads like a software swap and is nothing of the kind: the
// function is unrolled at elaboration into three compare-exchange cells, each a
// comparator driving two 2:1 muxes. There is no sequencing and no state. See
// docs/37 section 4 for the unrolled form.
// -----------------------------------------------------------------------------
`default_nettype none

module median9_net #(
  parameter int unsigned W = 8
) (
  input  var logic [9*W-1:0] din,    // element k at din[k*W +: W]; rows of three
  output var logic [W-1:0]   med
);

  function automatic logic [W-1:0] mn(input logic [W-1:0] a, b);
    mn = (a < b) ? a : b;
  endfunction

  function automatic logic [W-1:0] mx(input logic [W-1:0] a, b);
    mx = (a < b) ? b : a;
  endfunction

  // Median of three: max(min(a,b), min(max(a,b), c)). `lo` and `hi` are the two
  // outputs of ONE comparator, so this is three comparators, not four.
  function automatic logic [W-1:0] md3(input logic [W-1:0] a, b, c);
    logic [W-1:0] lo, hi;
    lo  = mn(a, b);
    hi  = mx(a, b);
    md3 = mx(lo, mn(hi, c));
  endfunction

  // Ascending sort of three, returned packed as { max, med, min } so that
  // element k is at [k*W +: W]. A function that needs several outputs returns a
  // packed vector; the caller must NAME the result before indexing it, because
  // the Yosys frontend rejects a part-select of a function call.
  function automatic logic [3*W-1:0] srt3(input logic [W-1:0] a, b, c);
    logic [W-1:0] x0, x1, x2, t;
    x0 = a;
    x1 = b;
    x2 = c;
    if (x1 < x0) begin t = x0; x0 = x1; x1 = t; end   // compare-exchange (0,1)
    if (x2 < x1) begin t = x1; x1 = x2; x2 = t; end   //                  (1,2)
    if (x1 < x0) begin t = x0; x0 = x1; x1 = t; end   //                  (0,1)
    srt3 = {x2, x1, x0};
  endfunction

  // Three sorted rows. This is a PROCEDURAL loop that nevertheless replicates
  // hardware -- three independent sorters -- because each iteration writes a
  // DIFFERENT lvalue. The rule that procedural loops do not replicate is really
  // about declarations, instances and accumulation; see docs/37 section 4.5.
  logic [3*W-1:0] srow [3];
  logic [W-1:0]   lo, mid, hi;

  always_comb begin
    for (int r = 0; r < 3; r++)
      srow[r] = srt3(din[(3*r + 0)*W +: W],
                     din[(3*r + 1)*W +: W],
                     din[(3*r + 2)*W +: W]);

    lo  = mx(mx(srow[0][0*W +: W], srow[1][0*W +: W]), srow[2][0*W +: W]);
    mid = md3(  srow[0][1*W +: W], srow[1][1*W +: W],  srow[2][1*W +: W]);
    hi  = mn(mn(srow[0][2*W +: W], srow[1][2*W +: W]), srow[2][2*W +: W]);

    med = md3(lo, mid, hi);
  end

`ifdef FORMAL
  // An implementation-free specification of "median", which is what makes this
  // proof independent of the algorithm above rather than a restatement of it.
  //
  // It is also a COMPLETE characterisation: if v is one of the nine values, at
  // least five are >= v and at least five are <= v, then v is the median. (If v
  // sat below the median in sorted order, then five values being <= v would
  // force the fifth-smallest to equal v anyway.)
  logic [3:0] fv_ge, fv_le;
  logic       fv_member;
  integer     fk;

  always_comb begin
    fv_ge     = '0;
    fv_le     = '0;
    fv_member = 1'b0;
    for (fk = 0; fk < 9; fk = fk + 1) begin
      if (din[fk*W +: W] >= med) fv_ge = fv_ge + 1'b1;
      if (din[fk*W +: W] <= med) fv_le = fv_le + 1'b1;
      if (din[fk*W +: W] == med) fv_member = 1'b1;
    end
  end

  always @* begin
    f_member : assert (fv_member);
    f_rank_ge: assert (fv_ge >= 4'd5);
    f_rank_le: assert (fv_le >= 4'd5);
  end
`endif

endmodule

`default_nettype wire
