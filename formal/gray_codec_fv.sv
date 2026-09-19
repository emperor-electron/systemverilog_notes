// -----------------------------------------------------------------------------
// gray_codec_fv.sv -- proof of the two properties that make Gray code useful.
//
//   1. ROUND TRIP: gray2bin(bin2gray(x)) == x for every x.
//   2. SINGLE-BIT CHANGE: bin2gray(x) and bin2gray(x+1) differ in exactly one
//      bit -- including across the wrap from all-ones to zero.
//
// Property 2 is the one an async FIFO's correctness depends on, and it is a
// property of ALL adjacent pairs -- exactly the kind of universally quantified
// claim formal proves and simulation can only sample.
// -----------------------------------------------------------------------------
`default_nettype none

module gray_codec_fv #(
  parameter int unsigned W = 8
) (
  input  var logic         clk,
  input  var logic [W-1:0] x
);

  logic [W-1:0] gray_x, bin_back;
  logic [W-1:0] gray_xp1;
  logic [W-1:0] unused_a, unused_b;

  // Instance 1: encode x, and decode it straight back.
  gray_codec #(.W(W)) u_rt (
    .bin_in   (x),
    .gray_out (gray_x),
    .gray_in  (gray_x),      // feed the encoder's output into the decoder
    .bin_out  (bin_back)
  );

  // Instance 2: encode x+1, so the two Gray codes can be compared.
  gray_codec #(.W(W)) u_next (
    .bin_in   (x + 1'b1),
    .gray_out (gray_xp1),
    .gray_in  (unused_a),
    .bin_out  (unused_b)
  );

  assign unused_a = '0;

  always @(posedge clk) begin
    a_round_trip : assert (bin_back == x);
    // Exactly one bit differs between consecutive codes -- wrap included,
    // because x+1 wraps and the property still has to hold.
    a_one_change : assert ($countones(gray_x ^ gray_xp1) == 1);
    c_wrap       : cover (x == '1);
    c_zero       : cover (x == '0);
  end

endmodule

`default_nettype wire
