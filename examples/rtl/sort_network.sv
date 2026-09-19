// -----------------------------------------------------------------------------
// sort_network.sv -- odd-even transposition sorting network.
//
// A sorting network is a FIXED mesh of compare-exchange cells: no loop, no
// control logic, no variable latency. That is what makes sorting synthesizable
// at all -- a software sort has data-dependent control flow, which hardware
// cannot have without a sequencer.
//
// Structure: N stages, each comparing alternating adjacent pairs.
//   stage even: (0,1) (2,3) (4,5) ...
//   stage odd:  (1,2) (3,4) (5,6) ...
// Depth N, and N*(N-1)/2 comparators. For a 9-tap median filter -- the usual
// reason to want this -- N=9 means depth 9, which pipelines trivially.
//
// BETTER NETWORKS EXIST. Batcher's odd-even mergesort and the bitonic sorter
// reach depth O(log^2 N) -- for N=16 that is 10 stages instead of 16, and the
// gap widens fast. They are worth the extra generate complexity above N ~ 8.
// Odd-even transposition is here because its correctness is obvious and its
// structure is a clean illustration.
//
// THE 0-1 PRINCIPLE (Knuth): a comparator network sorts every input sequence if
// and only if it sorts every sequence of 0s and 1s. So proving this network for
// W=1 proves it for ALL widths -- which is exactly what formal/sort_network_fv
// does, and why that proof is complete rather than a sample.
//
// See docs/23-structural-design-techniques.md.
// -----------------------------------------------------------------------------
`default_nettype none

module sort_network #(
  parameter int unsigned N = 8,
  parameter int unsigned W = 8
) (
  input  var logic [N*W-1:0] din,     // element i is din[i*W +: W]
  output var logic [N*W-1:0] dout,    // ascending
  output var logic [W-1:0]   median   // dout[N/2], the usual reason to sort
);

  // cur[stage][lane]; one extra stage for the input.
  logic [W-1:0] cur [0:N][0:N-1];
  integer       k;

  // Stage 0 is the input.
  always @* begin
    for (k = 0; k < N; k = k + 1)
      cur[0][k] = din[k*W +: W];
  end

  // One compare-exchange layer per stage. Lanes not paired in a given stage
  // pass straight through -- the generate-if below covers both cases so no lane
  // is ever left undriven (which would infer a latch).
  for (genvar p = 0; p < int'(N); p++) begin : g_stage
    for (genvar i = 0; i < int'(N); i++) begin : g_lane
      if (((i % 2) == (p % 2)) && (i + 1 < int'(N))) begin : g_lo
        // Low half of a pair: take the smaller.
        always @* cur[p+1][i] = (cur[p][i] <= cur[p][i+1]) ? cur[p][i]
                                                           : cur[p][i+1];
      end else if ((i > 0) && (((i-1) % 2) == (p % 2))) begin : g_hi
        // High half of a pair: take the larger.
        always @* cur[p+1][i] = (cur[p][i-1] <= cur[p][i]) ? cur[p][i]
                                                           : cur[p][i-1];
      end else begin : g_pass
        always @* cur[p+1][i] = cur[p][i];
      end
    end
  end

  always @* begin
    for (k = 0; k < N; k = k + 1)
      dout[k*W +: W] = cur[N][k];
  end

  assign median = cur[N][N/2];

`ifdef FORMAL
  integer fi;
  always @* begin
    // Sortedness. With W=1 this is a COMPLETE proof for every width, by the
    // 0-1 principle.
    for (fi = 0; fi < int'(N) - 1; fi = fi + 1)
      assert (cur[N][fi] <= cur[N][fi+1]);
  end

  // Multiset preservation: for 0/1 inputs, the number of ones must not change.
  // A network that sorted by overwriting values would pass sortedness alone.
  logic [$clog2(N+1)-1:0] fv_in_ones, fv_out_ones;
  always @* begin
    fv_in_ones  = '0;
    fv_out_ones = '0;
    for (fi = 0; fi < int'(N); fi = fi + 1) begin
      fv_in_ones  = fv_in_ones  + ($clog2(N+1))'(|cur[0][fi]);
      fv_out_ones = fv_out_ones + ($clog2(N+1))'(|cur[N][fi]);
    end
    f_multiset : assert (fv_in_ones == fv_out_ones);
  end
`endif

endmodule

`default_nettype wire
