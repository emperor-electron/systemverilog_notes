// -----------------------------------------------------------------------------
// fp_add.sv -- IEEE 754 adder/subtractor, parameterized over (E, M).
//
// Single-path implementation with full subnormal support and all five RISC-V
// rounding modes. Combinational; add pipeline registers at the marked points.
//
// Pipeline:
//   1. unpack        split s/e/m, insert the hidden bit, classify
//   2. swap          order so |a| >= |b|
//   3. align         right-shift the smaller significand, accumulate sticky
//   4. add/sub       effective op = sub XOR sa XOR sb
//   5. normalize     leading-zero count + left shift, or right shift by 1
//   6. round         L/R/S -> increment; may renormalize once more
//   7. pack          reassemble, then override with the special-case result
//
// WHY THE STICKY BIT IS OR'ED INTO THE LSB (step 3):
//   If |ea - eb| > 1 the result of an effective subtraction is at least half of
//   the larger operand, so at most ONE bit of left normalization is needed and
//   the sticky never reaches the round position. If |ea - eb| <= 1 nothing is
//   shifted out at all, so sticky is zero and massive cancellation is exact.
//   Those two facts together are what make a single-path adder correctly
//   rounded with only three extra bits.
//
// See docs/19-floating-point-hardware.md.
// -----------------------------------------------------------------------------
`default_nettype none

module fp_add #(
  parameter int E = 8,                 // exponent bits
  parameter int M = 23                 // mantissa (stored) bits
) (
  input  var logic [E+M:0]     a,
  input  var logic [E+M:0]     b,
  input  var logic             sub,    // 1 => a - b
  input  var fp_pkg::rnd_e     rm,
  output var logic [E+M:0]     y,
  output var fp_pkg::flags_t   flags
);
  import fp_pkg::*;

  localparam int W    = E + M + 1;
  localparam int MW   = M + 1;         // significand including the hidden bit
  localparam int GW   = MW + 3;        // + guard, round, sticky positions
  localparam int EMAX = (1 << E) - 1;  // the all-ones exponent field

  localparam logic [W-1:0] QNAN = {1'b0, {E{1'b1}}, 1'b1, {(M-1){1'b0}}};

  // ===========================================================================
  // 1. Unpack
  // ===========================================================================
  logic           sa, sb_raw, sb;
  logic [E-1:0]   ea_raw, eb_raw, ea_eff, eb_eff;
  logic [M-1:0]   ma_raw, mb_raw;
  logic [MW-1:0]  fa, fb;
  logic           a_zero, a_sub, a_norm, a_inf, a_nan, a_snan, a_qnan;
  logic           b_zero, b_sub, b_norm, b_inf, b_nan, b_snan, b_qnan;
  fclass_e        a_cls, b_cls;

  fp_classify #(.E(E), .M(M)) u_ca (
    .x(a), .sign(sa), .exp_raw(ea_raw), .man_raw(ma_raw),
    .exp_eff(ea_eff), .man_ext(fa),
    .is_zero(a_zero), .is_sub(a_sub), .is_norm(a_norm), .is_inf(a_inf),
    .is_nan(a_nan), .is_snan(a_snan), .is_qnan(a_qnan), .fclass(a_cls)
  );

  fp_classify #(.E(E), .M(M)) u_cb (
    .x(b), .sign(sb_raw), .exp_raw(eb_raw), .man_raw(mb_raw),
    .exp_eff(eb_eff), .man_ext(fb),
    .is_zero(b_zero), .is_sub(b_sub), .is_norm(b_norm), .is_inf(b_inf),
    .is_nan(b_nan), .is_snan(b_snan), .is_qnan(b_qnan), .fclass(b_cls)
  );

  // Subtraction is addition with b's sign flipped. Everything downstream sees
  // only an add.
  assign sb = sb_raw ^ sub;

  // ===========================================================================
  // 2. Swap so that |a| >= |b|
  //
  // The IEEE encoding is monotonic in magnitude, so comparing the raw
  // {exponent, mantissa} fields as one unsigned integer IS a magnitude compare.
  // That is the same property the integer-compare trick in docs/19 relies on.
  // ===========================================================================
  logic          swap;
  logic          s_l, s_s;
  logic [E-1:0]  e_l, e_s;
  logic [MW-1:0] f_l, f_s;

  assign swap = ({eb_raw, mb_raw} > {ea_raw, ma_raw});

  assign s_l = swap ? sb     : sa;
  assign s_s = swap ? sa     : sb;
  assign e_l = swap ? eb_eff : ea_eff;
  assign e_s = swap ? ea_eff : eb_eff;
  assign f_l = swap ? fb     : fa;
  assign f_s = swap ? fa     : fb;

  logic eff_sub;
  assign eff_sub = s_l ^ s_s;

  // ===========================================================================
  // 3. Align
  // ===========================================================================
  logic [E:0]      exp_diff;
  logic [E:0]      shamt;
  logic [GW-1:0]   f_l_ext, f_s_ext, f_s_shift, f_s_aligned;
  logic [GW-1:0]   shift_mask;
  logic            sticky_align;

  assign exp_diff = {1'b0, e_l} - {1'b0, e_s};

  // Clamp: shifting by more than GW puts every bit into the sticky anyway.
  assign shamt = (exp_diff > (E+1)'(GW)) ? (E+1)'(GW) : exp_diff;

  assign f_l_ext = {f_l, 3'b000};
  assign f_s_ext = {f_s, 3'b000};

  assign f_s_shift  = f_s_ext >> shamt;
  // Mask of the positions that were shifted out. Note `<<` by GW yields 0,
  // making the mask all-ones -- which is exactly right for a full shift-out.
  assign shift_mask   = ~({GW{1'b1}} << shamt);
  assign sticky_align = |(f_s_ext & shift_mask);

  // OR the sticky into the LSB. See the header comment for why this is
  // sufficient for correct rounding of BOTH add and subtract.
  assign f_s_aligned = f_s_shift | {{(GW-1){1'b0}}, sticky_align};

  // ===========================================================================
  // 4. Add / subtract  (|a| >= |b|, so the difference is never negative)
  // ===========================================================================
  logic [GW:0] sum_raw;
  assign sum_raw = eff_sub ? ({1'b0, f_l_ext} - {1'b0, f_s_aligned})
                           : ({1'b0, f_l_ext} + {1'b0, f_s_aligned});

  // ===========================================================================
  // 5. Normalize
  // ===========================================================================
  function automatic int lzc_f(input logic [GW-1:0] v);
    lzc_f = GW;
    for (int i = 0; i < GW; i++)
      if (v[i]) lzc_f = GW - 1 - i;      // the highest set bit wins
  endfunction

  logic [GW-1:0]      mant_pre;
  logic               sticky_carry;
  logic signed [E+2:0] exp_pre;
  logic               sum_is_zero;

  always_comb begin
    if (sum_raw[GW]) begin
      // Carry out (effective add only): shift right one, exponent up one.
      mant_pre     = sum_raw[GW:1];
      sticky_carry = sum_raw[0];
      exp_pre      = signed'({3'b000, e_l}) + 1;
    end else begin
      mant_pre     = sum_raw[GW-1:0];
      sticky_carry = 1'b0;
      exp_pre      = signed'({3'b000, e_l});
    end
  end

  assign sum_is_zero = (mant_pre == '0);

  logic signed [E+2:0] lz, max_shift, shift_amt, exp_norm;
  logic [GW-1:0]       mant_norm;

  always_comb begin
    lz        = (E+3)'(lzc_f(mant_pre));
    max_shift = exp_pre - 1;                  // cannot push the exponent below 1
    shift_amt = (lz > max_shift) ? max_shift : lz;
    if (shift_amt < 0) shift_amt = '0;
    mant_norm = mant_pre << shift_amt[E+1:0];
    exp_norm  = exp_pre - shift_amt;
  end

  // ===========================================================================
  // 6. Round
  // ===========================================================================
  logic sign_res, g_l, g_r, g_s, inc;

  assign sign_res = s_l;
  assign g_l = mant_norm[3];
  assign g_r = mant_norm[2];
  assign g_s = (|mant_norm[1:0]) | sticky_carry;
  assign inc = round_up(rm, sign_res, g_l, g_r, g_s);

  logic [MW:0]         mant_rnd;      // one extra bit for the rounding carry
  logic [MW-1:0]       mant_fin;
  logic signed [E+2:0] exp_fin;

  assign mant_rnd = {1'b0, mant_norm[GW-1:3]} + (MW+1)'(inc);

  always_comb begin
    if (mant_rnd[MW]) begin
      // 1.111...1 + 1ulp == 10.000...0 : renormalize once. The new mantissa is
      // all zeros, so no second rounding is possible.
      mant_fin = mant_rnd[MW:1];
      exp_fin  = exp_norm + 1;
    end else begin
      mant_fin = mant_rnd[MW-1:0];
      exp_fin  = exp_norm;
    end
  end

  // ===========================================================================
  // 7. Pack + special cases
  // ===========================================================================
  logic overflow, underflow, inexact, is_sub_result;

  assign inexact       = g_r | g_s;
  assign is_sub_result = ~mant_fin[MW-1];                 // no hidden bit
  assign overflow      = (exp_fin >= signed'((E+3)'(EMAX))) && !sum_is_zero;
  assign underflow     = is_sub_result && !sum_is_zero && inexact;

  logic [E-1:0] exp_field;
  logic [M-1:0] man_field;

  assign exp_field = is_sub_result ? '0 : exp_fin[E-1:0];
  assign man_field = mant_fin[M-1:0];

  // Sign of an exact zero result: +0 in every mode except round-down, where
  // IEEE 754 requires -0.  (x + (-x) == +0 in RNE.)
  logic zero_sign;
  assign zero_sign = (a_zero && b_zero) ? (sa & sb) : (rm == RDN);

  logic [W-1:0] normal_result, ovf_result;
  assign normal_result = {sign_res, exp_field, man_field};
  assign ovf_result    = overflow_to_inf(rm, sign_res)
                       ? {sign_res, {E{1'b1}}, {M{1'b0}}}          // infinity
                       : {sign_res, {(E-1){1'b1}}, 1'b0, {M{1'b1}}}; // max finite

  always_comb begin
    flags = '0;

    if (a_nan || b_nan) begin
      // Any NaN in -> canonical qNaN out. A signalling NaN also raises Invalid.
      y        = QNAN;
      flags.nv = a_snan || b_snan;
    end else if (a_inf && b_inf) begin
      if (sa != sb) begin
        y        = QNAN;                 // inf - inf is undefined
        flags.nv = 1'b1;
      end else begin
        y = {sa, {E{1'b1}}, {M{1'b0}}};
      end
    end else if (a_inf) begin
      y = {sa, {E{1'b1}}, {M{1'b0}}};
    end else if (b_inf) begin
      y = {sb, {E{1'b1}}, {M{1'b0}}};
    end else if (a_zero && b_zero) begin
      y = {zero_sign, {E{1'b0}}, {M{1'b0}}};
    end else if (a_zero) begin
      y = {sb, b[E+M-1:0]};              // b with its effective sign
    end else if (b_zero) begin
      y = a;
    end else if (sum_is_zero) begin
      y = {zero_sign, {E{1'b0}}, {M{1'b0}}};   // exact cancellation
    end else if (overflow) begin
      y        = ovf_result;
      flags.of = 1'b1;
      flags.nx = 1'b1;
    end else begin
      y        = normal_result;
      flags.nx = inexact;
      flags.uf = underflow;
    end
  end

endmodule

`default_nettype wire
