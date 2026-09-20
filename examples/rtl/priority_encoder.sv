// -----------------------------------------------------------------------------
// priority_encoder.sv -- index of the lowest set bit.
//                population count, and a Gray <-> binary pair.
//
// Each is written the way it reads best; all are pure combinational and unroll
// at elaboration.
// -----------------------------------------------------------------------------
`default_nettype none

// --- priority encoder: index of the lowest set bit ---------------------------
module priority_encoder #(
  parameter int unsigned N  = 16,
  parameter int unsigned IW = (N <= 1) ? 1 : $clog2(N)
) (
  input  var logic [N-1:0]  in,
  output var logic [IW-1:0] idx,
  output var logic          valid
);
  always_comb begin
    idx   = '0;
    valid = 1'b0;
    // The loop APPEARS sequential but unrolls into a priority mux chain.
    // The !valid guard makes the LOWEST index win; without it the highest does.
    for (int i = 0; i < int'(N); i++)
      if (!valid && in[i]) begin
        idx   = IW'(i);
        valid = 1'b1;
      end
  end
endmodule

`default_nettype wire
