// -----------------------------------------------------------------------------
// popcount.sv -- population count.
//                population count, and a Gray <-> binary pair.
//
// Each is written the way it reads best; all are pure combinational and unroll
// at elaboration.
// -----------------------------------------------------------------------------
`default_nettype none

// --- population count (adder tree) -------------------------------------------
module popcount #(
  parameter int unsigned N  = 32,
  parameter int unsigned CW = $clog2(N) + 1
) (
  input  var logic [N-1:0]  in,
  output var logic [CW-1:0] count
);
  // $countones is synthesizable and the tool builds a good adder tree.
  assign count = CW'($countones(in));
endmodule


// --- Gray <-> binary ---------------------------------------------------------

`default_nettype wire
