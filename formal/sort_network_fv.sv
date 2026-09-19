// -----------------------------------------------------------------------------
// sort_network_fv.sv -- a COMPLETE proof that the network sorts, via the
// 0-1 principle.
//
// Knuth's 0-1 principle: a comparator network sorts every input sequence if and
// only if it sorts every sequence of 0s and 1s. So a proof at W=1 is a proof for
// EVERY element width -- 8-bit, 32-bit, floating point keys, anything the
// comparator orders consistently.
//
// That is a much stronger statement than it looks, and it is the reason formal
// is the right tool here: simulating a 9-element 8-bit network exhaustively is
// 2^72 vectors. At W=1 the whole input space is 2^9 = 512 patterns, and the
// principle carries the result to all widths for free.
//
// The proofs themselves (sortedness, multiset preservation) live inside
// sort_network.sv's `ifdef FORMAL` block, because sortedness needs the internal
// stage array and Yosys cannot read a hierarchical reference into a submodule.
// See docs/25.
// -----------------------------------------------------------------------------
`default_nettype none

module sort_network_fv #(
  parameter int unsigned N = 9,     // odd, as in a median filter
  parameter int unsigned W = 1      // 1 => the 0-1 principle applies
) (
  input  var logic             clk,
  input  var logic [N*W-1:0]   din
);

  logic [N*W-1:0] dout;
  logic [W-1:0]   median;

  sort_network #(.N(N), .W(W)) dut (
    .din(din), .dout(dout), .median(median));

  // The median output must be the middle element of the sorted result.
  always @(posedge clk)
    f_median : assert (median == dout[(N/2)*W +: W]);

  always @(posedge clk) begin
    f_c_all0 : cover (din == '0);
    f_c_all1 : cover (din == '1);
    f_c_mix  : cover (dout != din);      // the network actually reorders
  end

endmodule

`default_nettype wire
