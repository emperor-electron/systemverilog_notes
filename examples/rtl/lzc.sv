// -----------------------------------------------------------------------------
// lzc.sv -- leading-zero count.
//                population count, and a Gray <-> binary pair.
//
// Each is written the way it reads best; all are pure combinational and unroll
// at elaboration.
// -----------------------------------------------------------------------------
`default_nettype none

// --- leading zero count ------------------------------------------------------
// Counts zeros from the MSB down. Returns N if the input is all zero.
// This is the critical block inside a floating-point adder's normalizer.
module lzc #(
  parameter int unsigned N  = 32,
  parameter int unsigned CW = $clog2(N) + 1
) (
  input  var logic [N-1:0]  in,
  output var logic [CW-1:0] count,
  output var logic          all_zero
);
  always_comb begin
    count    = CW'(N);
    all_zero = 1'b1;
    for (int i = 0; i < int'(N); i++)
      if (in[i]) begin
        count    = CW'(N - 1 - i);   // later iterations (higher i) overwrite,
        all_zero = 1'b0;             //   so the HIGHEST set bit wins
      end
  end
endmodule

`default_nettype wire
