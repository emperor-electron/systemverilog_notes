// -----------------------------------------------------------------------------
// fixed_pkg.sv -- fixed-point helpers.
//
// Notation used throughout: sW.F  =  signed, W bits total, F fraction bits.
//   resolution = 2^-F
//   range      = [ -2^(W-1-F) , 2^(W-1-F) - 2^-F ]
//   value      = raw_integer * 2^-F
//
// Every function is automatic, pure, and synthesizable. The `real`-valued
// helper at the bottom runs at ELABORATION time only -- the hardware sees an
// integer constant.
//
// See docs/18-fixed-point-arithmetic.md.
// -----------------------------------------------------------------------------
`ifndef FIXED_PKG_SV
`define FIXED_PKG_SV

package fixed_pkg;

  // Widest intermediate this package works in. Bump it if you need more.
  localparam int FXW = 64;
  typedef logic signed [FXW-1:0] fx_t;

  // ---------------------------------------------------------------------------
  // Sign-extend a narrow signed value into the working width.
  // The cast is doing real work: a part-select or a concatenation would be
  // UNSIGNED and would zero-extend instead. See docs/17.
  // ---------------------------------------------------------------------------
  function automatic fx_t fx_ext(input logic signed [FXW-1:0] v);
    return v;
  endfunction

  // ---------------------------------------------------------------------------
  // Rounding. All take a value with F fraction bits to discard and return the
  // value with those bits removed (still left-aligned in fx_t).
  // ---------------------------------------------------------------------------

  // Truncate toward -infinity. Free, but carries a -0.5 LSB DC bias that
  // accumulates through a filter chain.
  function automatic fx_t fx_trunc(input fx_t v, input int f);
    return v >>> f;
  endfunction

  // Round half away from zero. One adder. Unbiased on average EXCEPT on ties.
  function automatic fx_t fx_round(input fx_t v, input int f);
    if (f <= 0) return v;
    return (v + (fx_t'(1) <<< (f - 1))) >>> f;
  endfunction

  // Round half to even (convergent). Unbiased including on ties -- the right
  // default for anything that accumulates. Requires f >= 2.
  function automatic fx_t fx_round_even(input fx_t v, input int f);
    logic r, s, l, inc;
    if (f <= 0) return v;
    if (f == 1) begin
      r = v[0];  s = 1'b0;  l = v[1];
    end else begin
      r = v[f-1];                       // the "half" bit
      s = |(v & ((fx_t'(1) <<< (f-1)) - 1));   // anything strictly below half
      l = v[f];                         // LSB of the kept result
    end
    inc = r & (s | l);
    return (v >>> f) + fx_t'(inc);
  endfunction

  // Truncate toward zero (magnitude truncation).
  function automatic fx_t fx_trunc_zero(input fx_t v, input int f);
    if (f <= 0) return v;
    return (v + (v[FXW-1] ? ((fx_t'(1) <<< f) - 1) : fx_t'(0))) >>> f;
  endfunction

  // ---------------------------------------------------------------------------
  // Saturation: narrow a value to `nw` bits, clamping instead of wrapping.
  //
  // A value fits in `nw` bits iff every discarded bit equals the sign bit being
  // kept -- i.e. the slice [FXW-1 : nw-1] (note the OVERLAP with the kept sign
  // bit) is all ones or all zeros.
  // ---------------------------------------------------------------------------
  function automatic logic fx_overflows(input fx_t v, input int nw);
    fx_t top_mask, top;
    if (nw >= FXW) return 1'b0;
    top_mask = ~((fx_t'(1) <<< (nw - 1)) - 1);   // bits [FXW-1 : nw-1]
    top      = v & top_mask;
    return !((top == top_mask) || (top == '0));  // not all 1s and not all 0s
  endfunction

  function automatic fx_t fx_sat(input fx_t v, input int nw);
    fx_t pos_max, neg_min;
    if (!fx_overflows(v, nw)) return v;
    pos_max = (fx_t'(1) <<< (nw - 1)) - 1;
    neg_min = -(fx_t'(1) <<< (nw - 1));
    return v[FXW-1] ? neg_min : pos_max;
  endfunction

  // ---------------------------------------------------------------------------
  // Rescale sW_i.F_i -> sW_o.F_o. Shifts the binary point, rounds if the
  // fraction shrinks, and saturates if the integer part cannot hold the value.
  // ---------------------------------------------------------------------------
  function automatic fx_t fx_rescale(input fx_t  v,
                                     input int   fi,
                                     input int   fo,
                                     input int   wo,
                                     input logic do_round,
                                     input logic do_sat);
    fx_t t;
    if (fo >= fi)       t = v <<< (fo - fi);
    else if (do_round)  t = fx_round_even(v, fi - fo);
    else                t = v >>> (fi - fo);
    return do_sat ? fx_sat(t, wo) : t;
  endfunction

  // ---------------------------------------------------------------------------
  // Number of guard bits needed to accumulate `n` values without overflow.
  // With ceil(log2(n)) guard bits the accumulator is PROVABLY overflow-free,
  // which means no saturation logic is needed in the inner loop -- saturate
  // once on the way out instead.
  // ---------------------------------------------------------------------------
  function automatic int fx_guard_bits(input int n);
    return (n <= 1) ? 0 : $clog2(n);
  endfunction

  // ---------------------------------------------------------------------------
  // ELABORATION-TIME ONLY: quantize a real literal into a fixed-point constant.
  //
  //   localparam logic signed [17:0] COS45 = 18'(fx_from_real(0.70710678, 17));
  //
  // The `real` arithmetic happens in the elaborator; synthesis sees only the
  // integer. This is the right way to get a readable coefficient table into
  // RTL -- write the decimals, let the tool quantize, keep the decimals in a
  // comment for the next reader.
  // ---------------------------------------------------------------------------
  function automatic fx_t fx_from_real(input real v, input int f);
    real scaled;
    scaled = v * (2.0 ** f);
    return fx_t'(longint'(scaled > 0.0 ? scaled + 0.5 : scaled - 0.5));
  endfunction

  // The inverse, for checking a table by eye in a testbench.
  function automatic real fx_to_real(input fx_t v, input int f);
    return real'(v) / (2.0 ** f);
  endfunction

endpackage

`endif
