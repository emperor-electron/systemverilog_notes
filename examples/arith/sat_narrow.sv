// -----------------------------------------------------------------------------
// sat_narrow.sv -- saturating width reduction.
//
// One of the three fixed-point "limit handling" blocks:
//   sat_add    : saturating signed add/subtract
//   sat_narrow : saturating width reduction
//   requantize : round then saturate -- the canonical end-of-datapath block
//
// These are what turn a mathematically correct fixed-point datapath into one
// that behaves acceptably at its limits. Wrapping on overflow turns a large
// positive into a large negative -- a discontinuity a control loop or an audio
// path cannot recover from.
//
// See docs/18-fixed-point-arithmetic.md.
// -----------------------------------------------------------------------------
`default_nettype none

// --- saturating narrow -------------------------------------------------------
module sat_narrow #(
  parameter int unsigned WI = 40,
  parameter int unsigned WO = 16
) (
  input  var logic signed [WI-1:0] din,
  output var logic signed [WO-1:0] dout,
  output var logic                 sat
);
  // The value fits iff every discarded bit equals the sign bit being kept.
  // Note the slice OVERLAPS the kept sign bit at index WO-1.
  logic [WI-WO:0] top;
  assign top = din[WI-1 : WO-1];
  assign sat = !((&top) || (~|top));

  assign dout = sat ? (din[WI-1] ? {1'b1, {(WO-1){1'b0}}}    // most negative
                                 : {1'b0, {(WO-1){1'b1}}})   // most positive
                    : din[WO-1:0];
endmodule

`default_nettype wire
