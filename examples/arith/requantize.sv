// -----------------------------------------------------------------------------
// requantize.sv -- round then saturate -- the end-of-datapath block.
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

// --- requantizer: round F fraction bits away, then saturate -----------------
// The canonical "end of the datapath" block: a wide, full-precision
// accumulator value comes in, a narrow output word goes out.
module requantize #(
  parameter int unsigned WI    = 40,   // input width
  parameter int unsigned WO    = 16,   // output width
  parameter int unsigned FDROP = 12,   // fraction bits to discard
  parameter bit          ROUND = 1'b1  // 1 = round half to even, 0 = truncate
) (
  input  var logic signed [WI-1:0] din,
  output var logic signed [WO-1:0] dout,
  output var logic                 sat
);
  logic signed [WI-1:0] shifted, inc_ext, rounded;
  logic                 r, s, l, inc;

  // Round half to even: increment iff  R & (S | L).
  //   L = LSB of the kept result, R = the half bit, S = OR of everything below
  assign l = din[FDROP];
  assign r = din[FDROP-1];
  assign s = (FDROP >= 2) ? |din[FDROP-2:0] : 1'b0;
  assign inc = ROUND ? (r & (s | l)) : 1'b0;

  // These two lines look like they could be one. They cannot:
  //
  //     assign rounded = (din >>> FDROP) + WI'(inc);     // WRONG
  //
  // `WI'(inc)` is an UNSIGNED size cast, which makes the whole addition
  // unsigned -- and signedness propagates DOWN into context-determined
  // operands, so `din` is then treated as unsigned too and `>>>` fills with
  // ZEROS. Every negative input comes out as a large positive number. See
  // docs/17 trap T6b.
  //
  // Splitting it keeps each operation in a signed context: the shift is
  // arithmetic because its only context is a signed target, and the add is
  // signed because both operands are.
  assign shifted = din >>> FDROP;
  assign inc_ext = inc ? 1 : 0;
  assign rounded = shifted + inc_ext;

  sat_narrow #(.WI(WI), .WO(WO)) u_sat (
    .din  (rounded),
    .dout (dout),
    .sat  (sat)
  );

`ifndef SYNTHESIS
  if (FDROP < 1) begin : g_chk
    $error("requantize: FDROP must be >= 1");
  end
`endif
endmodule

`default_nettype wire
