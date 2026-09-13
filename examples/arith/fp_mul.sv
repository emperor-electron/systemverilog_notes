// -----------------------------------------------------------------------------
// fp_mul.sv -- IEEE 754 multiplier, parameterized over (E, M).
//
// Much simpler than the adder: no alignment shift, no massive cancellation,
// and at most ONE bit of normalization (because the product of two values in
// [1,2) lies in [1,4)).
//
// Pipeline:
//   1. unpack, and pre-normalize subnormal inputs (LZC + left shift, with the
//      exponent adjusted down to compensate)
//   2. sign      sy = sa ^ sb
//   3. exponent  ey = ea + eb - bias  (+1 if the product is >= 2.0)
//   4. mantissa  prod = fa * fb, an MW x MW -> 2*MW unsigned multiply
//   5. normalize at most one right shift
//   6. denormalize if the exponent underflowed below 1
//   7. round, then pack
//
// EXPONENT ARITHMETIC IS THE TRAP HERE: `ea + eb - BIAS` computed on E-bit
// operands evaluates at E bits and wraps silently, producing a plausible but
// wrong exponent. It must be done SIGNED and WIDER. See docs/17.
// -----------------------------------------------------------------------------
`default_nettype none

module fp_mul #(
  parameter int E = 8,
  parameter int M = 23
) (
  input  var logic [E+M:0]   a,
  input  var logic [E+M:0]   b,
  input  var fp_pkg::rnd_e   rm,
  output var logic [E+M:0]   y,
  output var fp_pkg::flags_t flags
);
  import fp_pkg::*;

  localparam int W    = E + M + 1;
  localparam int MW   = M + 1;
  localparam int PW   = 2 * MW;
  localparam int GW   = MW + 3;
  localparam int BIAS = (1 << (E-1)) - 1;
  localparam int EMAX = (1 << E) - 1;

  localparam logic [W-1:0] QNAN = {1'b0, {E{1'b1}}, 1'b1, {(M-1){1'b0}}};

  // ===========================================================================
  // 1. Unpack
  // ===========================================================================
  logic          sa, sb;
  logic [E-1:0]  ea_raw, eb_raw, ea_eff, eb_eff;
  logic [M-1:0]  ma_raw, mb_raw;
  logic [MW-1:0] fa, fb;
  logic          a_zero, a_sub, a_norm, a_inf, a_nan, a_snan, a_qnan;
  logic          b_zero, b_sub, b_norm, b_inf, b_nan, b_snan, b_qnan;
  fclass_e       a_cls, b_cls;

  fp_classify #(.E(E), .M(M)) u_ca (
    .x(a), .sign(sa), .exp_raw(ea_raw), .man_raw(ma_raw),
    .exp_eff(ea_eff), .man_ext(fa),
    .is_zero(a_zero), .is_sub(a_sub), .is_norm(a_norm), .is_inf(a_inf),
    .is_nan(a_nan), .is_snan(a_snan), .is_qnan(a_qnan), .fclass(a_cls)
  );
  fp_classify #(.E(E), .M(M)) u_cb (
    .x(b), .sign(sb), .exp_raw(eb_raw), .man_raw(mb_raw),
    .exp_eff(eb_eff), .man_ext(fb),
    .is_zero(b_zero), .is_sub(b_sub), .is_norm(b_norm), .is_inf(b_inf),
    .is_nan(b_nan), .is_snan(b_snan), .is_qnan(b_qnan), .fclass(b_cls)
  );

  // Pre-normalize subnormal operands so the multiplier array only ever sees
  // significands with the MSB set. The exponent pays for the shift.
  function automatic int lzc_mw(input logic [MW-1:0] v);
    lzc_mw = MW;
    for (int i = 0; i < MW; i++)
      if (v[i]) lzc_mw = MW - 1 - i;
  endfunction

  logic signed [E+2:0] lza, lzb, ea_adj, eb_adj;
  logic [MW-1:0]       fa_n, fb_n;

  always_comb begin
    lza    = (E+3)'(lzc_mw(fa));
    lzb    = (E+3)'(lzc_mw(fb));
    fa_n   = fa << lza[E+1:0];
    fb_n   = fb << lzb[E+1:0];
    ea_adj = signed'({3'b000, ea_eff}) - lza;
    eb_adj = signed'({3'b000, eb_eff}) - lzb;
  end

  // ===========================================================================
  // 2-4. Sign, exponent, product
  // ===========================================================================
  logic          sy;
  logic [PW-1:0] prod;
  logic          norm_shift;

  assign sy         = sa ^ sb;
  assign prod       = fa_n * fb_n;         // both unsigned -> unsigned multiply
  assign norm_shift = prod[PW-1];          // the product reached 2.0

  logic signed [E+2:0] exp_sum;
  assign exp_sum = ea_adj + eb_adj - signed'((E+3)'(BIAS)) + (E+3)'(norm_shift);

  // ===========================================================================
  // 5. Select the significand plus round/sticky
  // ===========================================================================
  logic [MW-1:0] sig;
  logic          rbit, sticky_p;
  logic [GW-1:0] mant_g;

  always_comb begin
    if (norm_shift) begin
      sig      = prod[PW-1 -: MW];
      rbit     = prod[MW-1];
      sticky_p = |prod[MW-2:0];
    end else begin
      sig      = prod[PW-2 -: MW];
      rbit     = prod[MW-2];
      sticky_p = |prod[MW-3:0];
    end
    // Working format: {significand (MW bits), round, 0, sticky}
    mant_g = {sig, rbit, 1'b0, sticky_p};
  end

  // ===========================================================================
  // 6. Denormalize if the exponent fell below 1
  // ===========================================================================
  logic signed [E+2:0] dn_shift, exp_norm;
  logic [GW-1:0]       mant_dn, dn_mask;
  logic                sticky_dn, flush_zero;

  always_comb begin
    // Default assignments first, so every signal is driven on every path.
    // Without them the `flush_zero` branch below leaves `dn_mask` unassigned
    // and the tool infers a latch -- see docs/05.
    dn_shift   = '0;
    flush_zero = 1'b0;
    dn_mask    = '0;
    mant_dn    = mant_g;
    sticky_dn  = 1'b0;
    exp_norm   = exp_sum;

    if (exp_sum < 1) begin
      // The result is below the smallest normal: shift right into the
      // subnormal range and let rounding decide the final value.
      dn_shift   = 1 - exp_sum;
      flush_zero = (dn_shift >= signed'((E+3)'(GW)));
      exp_norm   = 1;
      if (flush_zero) begin
        mant_dn   = '0;
        sticky_dn = |mant_g;
      end else begin
        dn_mask   = ~({GW{1'b1}} << dn_shift[E+1:0]);
        mant_dn   = mant_g >> dn_shift[E+1:0];
        sticky_dn = |(mant_g & dn_mask);
      end
    end
  end

  // ===========================================================================
  // 7. Round and pack
  // ===========================================================================
  logic g_l, g_r, g_s, inc;

  assign g_l = mant_dn[3];
  assign g_r = mant_dn[2];
  assign g_s = (|mant_dn[1:0]) | sticky_dn;
  assign inc = round_up(rm, sy, g_l, g_r, g_s);

  logic [MW:0]         mant_rnd;
  logic [MW-1:0]       mant_fin;
  logic signed [E+2:0] exp_fin;

  assign mant_rnd = {1'b0, mant_dn[GW-1:3]} + (MW+1)'(inc);

  always_comb begin
    if (mant_rnd[MW]) begin
      mant_fin = mant_rnd[MW:1];
      exp_fin  = exp_norm + 1;
    end else begin
      mant_fin = mant_rnd[MW-1:0];
      exp_fin  = exp_norm;
    end
  end

  logic is_sub_result, res_zero, overflow, underflow, inexact;

  assign inexact       = g_r | g_s;
  assign is_sub_result = ~mant_fin[MW-1];
  assign res_zero      = (mant_fin == '0);
  assign overflow      = (exp_fin >= signed'((E+3)'(EMAX)));
  assign underflow     = is_sub_result && !res_zero && inexact;

  logic [W-1:0] normal_result, ovf_result, zero_result, inf_result;

  assign normal_result = {sy, is_sub_result ? {E{1'b0}} : exp_fin[E-1:0],
                          mant_fin[M-1:0]};
  assign inf_result    = {sy, {E{1'b1}}, {M{1'b0}}};
  assign zero_result   = {sy, {E{1'b0}}, {M{1'b0}}};
  assign ovf_result    = overflow_to_inf(rm, sy)
                       ? inf_result
                       : {sy, {(E-1){1'b1}}, 1'b0, {M{1'b1}}};

  always_comb begin
    flags = '0;

    if (a_nan || b_nan) begin
      y        = QNAN;
      flags.nv = a_snan || b_snan;
    end else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
      y        = QNAN;                  // 0 * inf is undefined
      flags.nv = 1'b1;
    end else if (a_inf || b_inf) begin
      y = inf_result;
    end else if (a_zero || b_zero) begin
      y = zero_result;                  // signed zero
    end else if (overflow) begin
      y        = ovf_result;
      flags.of = 1'b1;
      flags.nx = 1'b1;
    end else if (res_zero) begin
      y        = zero_result;           // underflowed all the way to zero
      flags.uf = 1'b1;
      flags.nx = 1'b1;
    end else begin
      y        = normal_result;
      flags.nx = inexact;
      flags.uf = underflow;
    end
  end

endmodule

`default_nettype wire
