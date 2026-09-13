// -----------------------------------------------------------------------------
// fp_classify.sv -- decode an IEEE 754 value into its class and its
// normalized fields.
//
//   e == 0,      m == 0  -> zero (signed)
//   e == 0,      m != 0  -> subnormal:  value = (-1)^s * 2^(1-bias) * 0.m
//   0 < e < max          -> normal:     value = (-1)^s * 2^(e-bias) * 1.m
//   e == max,    m == 0  -> infinity
//   e == max,    m != 0  -> NaN (quiet if m[M-1], else signalling)
//
// The `exp_eff` / `man_ext` outputs fold subnormals into the normal path: a
// subnormal's value equals exponent 1 with a LEADING ZERO in the significand,
// which is exactly what {is_norm, man} gives.
// -----------------------------------------------------------------------------
`default_nettype none

module fp_classify #(
  parameter int E = 8,
  parameter int M = 23
) (
  input  var logic [E+M:0]  x,
  output var logic          sign,
  output var logic [E-1:0]  exp_raw,
  output var logic [M-1:0]  man_raw,
  output var logic [E-1:0]  exp_eff,     // 1 for subnormals, exp_raw otherwise
  output var logic [M:0]    man_ext,     // {hidden_bit, man_raw}
  output var logic          is_zero,
  output var logic          is_sub,
  output var logic          is_norm,
  output var logic          is_inf,
  output var logic          is_nan,
  output var logic          is_snan,
  output var logic          is_qnan,
  output var fp_pkg::fclass_e fclass
);
  import fp_pkg::*;

  logic exp_all_1, exp_all_0, man_zero;

  assign sign    = x[E+M];
  assign exp_raw = x[E+M-1 -: E];
  assign man_raw = x[M-1:0];

  assign exp_all_1 =  &exp_raw;
  assign exp_all_0 = ~|exp_raw;
  assign man_zero  = ~|man_raw;

  assign is_zero = exp_all_0 &&  man_zero;
  assign is_sub  = exp_all_0 && !man_zero;
  assign is_norm = !exp_all_0 && !exp_all_1;
  assign is_inf  = exp_all_1 &&  man_zero;
  assign is_nan  = exp_all_1 && !man_zero;
  assign is_qnan = is_nan &&  man_raw[M-1];
  assign is_snan = is_nan && !man_raw[M-1];

  // Subnormals have an EFFECTIVE exponent of 1, not 0: their value is
  // 2^(1-bias) * 0.m, i.e. the same scale as the smallest normal but with no
  // hidden bit.
  assign exp_eff = exp_all_0 ? E'(1) : exp_raw;
  assign man_ext = {is_norm || is_inf || is_nan, man_raw};

  always_comb begin
    if      (is_snan)            fclass = FC_SNAN;
    else if (is_qnan)            fclass = FC_QNAN;
    else if (is_inf  &&  sign)   fclass = FC_NEG_INF;
    else if (is_inf)             fclass = FC_POS_INF;
    else if (is_norm &&  sign)   fclass = FC_NEG_NORM;
    else if (is_norm)            fclass = FC_POS_NORM;
    else if (is_sub  &&  sign)   fclass = FC_NEG_SUB;
    else if (is_sub)             fclass = FC_POS_SUB;
    else if (sign)               fclass = FC_NEG_ZERO;
    else                         fclass = FC_POS_ZERO;
  end
endmodule

`default_nettype wire
