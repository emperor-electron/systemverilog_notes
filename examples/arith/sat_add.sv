// -----------------------------------------------------------------------------
// sat_add.sv -- saturating signed add/subtract.
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

// --- saturating signed add ---------------------------------------------------
module sat_add #(
  parameter int unsigned W = 16
) (
  input  var logic signed [W-1:0] a,
  input  var logic signed [W-1:0] b,
  input  var logic                sub,
  output var logic signed [W-1:0] y,
  output var logic                sat
);
  // Compute at W+1 bits by sign-extending both operands. The concatenations
  // are UNSIGNED, so the signed'() casts are load-bearing, not decoration.
  logic signed [W:0] s;

  assign s = sub ? (signed'({a[W-1], a}) - signed'({b[W-1], b}))
                 : (signed'({a[W-1], a}) + signed'({b[W-1], b}));

  // Overflow iff the two top bits of the wide result disagree.
  assign sat = (s[W] != s[W-1]);

  // On overflow emit the extreme of the correct sign:
  //   s[W]==0 (result was positive) -> 0111...1
  //   s[W]==1 (result was negative) -> 1000...0
  assign y = sat ? {s[W], {(W-1){~s[W]}}} : s[W-1:0];
endmodule

`default_nettype wire
