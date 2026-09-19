// -----------------------------------------------------------------------------
// div_const.sv -- unsigned divide by a COMPILE-TIME constant, no divider.
//
// A variable divider is a multi-cycle machine (div_restoring.sv). Dividing by a
// CONSTANT needs neither: multiply by a fixed-point reciprocal and shift.
//
//   q = floor(n / D)  ==  (n * M) >> S      for a suitable M and S
//
// Picking M and S so that this is EXACT for every n -- not approximate, not
// off-by-one near multiples of D -- is the whole trick. The standard result
// (Granlund & Montgomery; Hacker's Delight ch. 10) is:
//
//   L = ceil(log2(D)),   S = W + L,   M = floor(2^S / D) + 1
//
// then floor(n*M / 2^S) == floor(n/D) for all 0 <= n < 2^W. The `+1` is what
// makes M an over-estimate of the reciprocal by just enough that the truncation
// never rounds the wrong way.
//
// Cost: one W x (W+2) multiply -- one DSP block -- plus a shift, versus W cycles
// of a restoring divider. If D is a power of two it degenerates to a shift and
// the multiplier disappears entirely.
//
// The remainder comes free-ish: r = n - q*D, another constant multiply
// (mul_const territory).
//
// See docs/23-structural-design-techniques.md.
// -----------------------------------------------------------------------------
`default_nettype none

module div_const #(
  parameter int unsigned W = 16,
  parameter int unsigned D = 10
) (
  input  var logic [W-1:0] num,
  output var logic [W-1:0] quot,
  output var logic [W-1:0] rem
);

  // ---- elaboration-time constants ------------------------------------------
  function automatic int clog2_ceil(input int unsigned v);
    int unsigned t;
    clog2_ceil = 0;
    t          = v - 1;
    while (t > 0) begin
      clog2_ceil = clog2_ceil + 1;
      t          = t >> 1;
    end
  endfunction

  function automatic bit is_pow2(input int unsigned v);
    is_pow2 = (v != 0) && ((v & (v - 1)) == 0);
  endfunction

  localparam int unsigned L   = clog2_ceil(D);
  localparam int unsigned S   = W + L;
  // M < 2^(W+1): since D > 2^(L-1), M ~= 2^(W+L)/D < 2^(W+1). W+2 is ample.
  localparam int unsigned MWD = W + 2;
  // The product register must reach the TOP of the shift, not merely hold the
  // product: the result is taken from prod[S +: W], so it needs S + W bits.
  // Sizing it as W + MWD (= 2W+2) is enough for the product's VALUE but leaves
  // prod[S +: W] reading past the top whenever L > 2 -- which silently returns
  // zeros. Formal caught this immediately; random simulation would not have,
  // because it fails for every input rather than a rare one.
  localparam int unsigned PW  = S + W;

  // floor(2^S / D) + 1, computed in the elaborator at 64-bit width.
  localparam logic [MWD-1:0] M = MWD'(((64'd1 << S) / 64'(D)) + 64'd1);

  if (D == 0) begin : g_chk
    $error("div_const: D must be non-zero");
  end

  logic [W-1:0] q;

  if (is_pow2(D)) begin : g_shift
    // Power of two: pure wiring, no multiplier at all.
    assign q = num >> L;
  end else begin : g_recip
    logic [PW-1:0] prod;
    assign prod = num * M;
    assign q    = prod[S +: W];        // >> S, then keep W bits
  end

  assign quot = q;

  // r = n - q*D. D is constant, so q*D is itself a shift-add network.
  assign rem = num - W'(q * W'(D));

`ifdef FORMAL
  // Exhaustive for the parameterised W: prove the reciprocal trick is EXACT,
  // which is the only thing that makes it usable. This is the property that
  // fails if S or M is off by one, and it fails only for a handful of inputs
  // near multiples of D -- exactly the kind of bug random simulation misses.
  always @* begin
    f_quot : assert (quot == (num / W'(D)));
    f_rem  : assert (rem  == (num % W'(D)));
  end
`endif

endmodule

`default_nettype wire
