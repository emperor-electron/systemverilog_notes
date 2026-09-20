// -----------------------------------------------------------------------------
// onehot_decoder.sv -- binary index to one-hot.
//                population count, and a Gray <-> binary pair.
//
// Each is written the way it reads best; all are pure combinational and unroll
// at elaboration.
// -----------------------------------------------------------------------------
`default_nettype none

// --- one-hot decoder ---------------------------------------------------------
module onehot_decoder #(
  parameter int unsigned IW = 4,
  parameter int unsigned N  = 1 << IW
) (
  input  var logic [IW-1:0] idx,
  input  var logic          en,
  output var logic [N-1:0]  out
);
  always_comb begin
    out = '0;
    if (en) out[idx] = 1'b1;
  end
endmodule

`default_nettype wire
