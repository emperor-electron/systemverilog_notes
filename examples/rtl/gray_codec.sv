// -----------------------------------------------------------------------------
// gray_codec.sv -- binary <-> Gray conversion.
//                population count, and a Gray <-> binary pair.
//
// Each is written the way it reads best; all are pure combinational and unroll
// at elaboration.
// -----------------------------------------------------------------------------
`default_nettype none

// --- Gray <-> binary ---------------------------------------------------------
module gray_codec #(
  parameter int unsigned W = 8
) (
  input  var logic [W-1:0] bin_in,
  output var logic [W-1:0] gray_out,
  input  var logic [W-1:0] gray_in,
  output var logic [W-1:0] bin_out
);
  // bin -> gray: one XOR gate per bit, no carry chain.
  assign gray_out = bin_in ^ (bin_in >> 1);

  // gray -> bin: a prefix XOR. b[i] = XOR of g[W-1:i].
  always_comb begin
    bin_out[W-1] = gray_in[W-1];
    for (int i = W-2; i >= 0; i--)
      bin_out[i] = bin_out[i+1] ^ gray_in[i];
  end
endmodule


// --- Gray-code counter -------------------------------------------------------
// Keeps a binary counter internally and emits the Gray view, which is what you
// want for a CDC pointer: the binary form is easy to compare and increment,
// the Gray form is what crosses the boundary.

`default_nettype wire
