// -----------------------------------------------------------------------------
// arb_fixed.sv -- fixed-priority arbiter (lowest set bit wins).
//
// The round-robin arbiter uses the "masked priority" trick:
//   1. Build a mask that clears every requester at or below the last winner.
//   2. Run a plain fixed-priority arbiter on the masked requests.
//   3. If nothing survived the mask, run it again on the UNmasked requests
//      (that is the wrap-around).
// Two priority arbiters and a mux -- no rotation barrel shifter needed.
// -----------------------------------------------------------------------------
`default_nettype none

// --- isolate the lowest set bit: r & (~r + 1) --------------------------------
// This is the whole of a fixed-priority arbiter. The carry chain of the
// increment does the priority propagation, which is why it maps so well.
module arb_fixed #(
  parameter int unsigned N = 8
) (
  input  var logic [N-1:0] req,
  output var logic [N-1:0] grant      // one-hot, or all zero
);
  assign grant = req & (~req + 1'b1);
endmodule

`default_nettype wire
