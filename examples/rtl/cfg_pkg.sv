// -----------------------------------------------------------------------------
// cfg_pkg.sv -- the register map of the two worked examples in docs/39, plus the
// golden model of the one that does arithmetic.
//
// WHY A PACKAGE AND NOT FOUR SEPARATE PORTS
//
// Every consumer here takes its configuration as ONE wide vector and unpacks it
// internally. That is not a style preference. A consumer with separate `gain`,
// `shift`, `lo` and `hi` ports has four independently-timed inputs, and nothing
// in its interface says they must change together; a consumer with one `cfg`
// port has one, and "the configuration updates atomically" becomes a statement
// about a single register with a single enable, which is a thing a proof can
// state in one line. The field offsets have to live somewhere shared, so they
// live here.
//
// WHAT IS AND IS NOT TESTED BY SHARING THIS
//
// The DUTs unpack with the accessors below and the checkers pack with them, so a
// mistake in a field offset CANCELS OUT and no proof here would see it. That is
// a real gap and the honest fix is small: csr_config_tb.sv has one directed
// vector that writes literal hex words and checks a known result, which is the
// only place the map is pinned to something outside this file. Everything else
// tests the staging and the capture, which is what docs/39 is actually about.
//
// `scale_ref` is the golden model for cfg_pipe_scale.sv. It is deliberately ONE
// expression chain -- the DUT computes the same value across three pipeline
// stages with the configuration arriving at three different times, so the model
// has to be independent of how that is staged or it proves nothing. No module in
// examples/rtl calls it; only the testbench and the formal harness do.
//
// Referenced fully scoped as `cfg_pkg::...`: the Yosys frontend rejects
// `import pkg::*;` in a module body (docs/37 section 13).
// -----------------------------------------------------------------------------
package cfg_pkg;

  // ===========================================================================
  // Widths
  // ===========================================================================
  localparam int unsigned CFG_DW = 32;   // one PS register

  // ---- the scaler: y = clamp(round((x * gain) >> shift), lo, hi) ------------
  localparam int unsigned XW    = 12;    // signed input sample
  localparam int unsigned GAINW = 16;    // unsigned Q8.8 gain
  localparam int unsigned SHW   = 4;     // right shift, 0..15
  localparam int unsigned YW    = 12;    // signed output, and the clamp bounds

  // PW is one bit wider than the product needs so the sign-extension is never a
  // truncation, and SW one wider again for the rounding constant. Both are
  // cheaper than the argument about whether the tight width is correct.
  localparam int unsigned PW = XW + GAINW + 1;   // 29
  localparam int unsigned SW = PW + 1;           // 30

  // ---- the burst engine: len beats at base, base+stride, base+2*stride ------
  localparam int unsigned LENW    = 12;
  localparam int unsigned STRIDEW = 8;
  localparam int unsigned ADDRW   = 16;

  // The three kinds of beat the burst engine emits. A header and a trailer are
  // emitted only when `hdr_en` is set, and they must come in PAIRS -- which is
  // the well-formedness property cfg_burst_fsm.sv is built to guarantee across a
  // configuration change, and the one it visibly loses without a snapshot.
  localparam int unsigned KINDW  = 2;
  localparam logic [KINDW-1:0] K_HDR  = 2'd0;
  localparam logic [KINDW-1:0] K_DATA = 2'd1;
  localparam logic [KINDW-1:0] K_TRL  = 2'd2;

  // ===========================================================================
  // Register map
  //
  // Two 32-bit words each, because a PS writes 32 bits at a time and the point
  // of docs/39 is what happens between the two writes.
  // ===========================================================================
  localparam int unsigned SCALE_CFGW = 2 * CFG_DW;   // 64
  localparam int unsigned BURST_CFGW = 2 * CFG_DW;   // 64

  //   SCALE0 (word 0): [15:0] gain      [19:16] shift
  //   SCALE1 (word 1): [11:0] lo        [27:16] hi
  localparam int unsigned GAIN_LSB  = 0;
  localparam int unsigned SHIFT_LSB = 16;
  localparam int unsigned LO_LSB    = CFG_DW + 0;
  localparam int unsigned HI_LSB    = CFG_DW + 16;

  //   BURST0 (word 0): [11:0] len       [23:16] stride     [24] hdr_en
  //   BURST1 (word 1): [15:0] base
  localparam int unsigned LEN_LSB    = 0;
  localparam int unsigned STRIDE_LSB = 16;
  localparam int unsigned HDREN_LSB  = 24;
  localparam int unsigned BASE_LSB   = CFG_DW + 0;

  // ===========================================================================
  // Accessors -- pure slices, so these are wiring and not logic.
  // ===========================================================================
  function automatic logic [GAINW-1:0] scale_gain(input logic [SCALE_CFGW-1:0] c);
    scale_gain = c[GAIN_LSB +: GAINW];
  endfunction

  function automatic logic [SHW-1:0] scale_shift(input logic [SCALE_CFGW-1:0] c);
    scale_shift = c[SHIFT_LSB +: SHW];
  endfunction

  function automatic logic signed [YW-1:0] scale_lo(input logic [SCALE_CFGW-1:0] c);
    scale_lo = c[LO_LSB +: YW];
  endfunction

  function automatic logic signed [YW-1:0] scale_hi(input logic [SCALE_CFGW-1:0] c);
    scale_hi = c[HI_LSB +: YW];
  endfunction

  function automatic logic [LENW-1:0] burst_len(input logic [BURST_CFGW-1:0] c);
    burst_len = c[LEN_LSB +: LENW];
  endfunction

  function automatic logic [STRIDEW-1:0] burst_stride(input logic [BURST_CFGW-1:0] c);
    burst_stride = c[STRIDE_LSB +: STRIDEW];
  endfunction

  function automatic logic [ADDRW-1:0] burst_base(input logic [BURST_CFGW-1:0] c);
    burst_base = c[BASE_LSB +: ADDRW];
  endfunction

  function automatic logic burst_hdr_en(input logic [BURST_CFGW-1:0] c);
    burst_hdr_en = c[HDREN_LSB];
  endfunction

  // Packers, for testbenches and harnesses that want to build a configuration
  // from fields rather than from a hex constant.
  function automatic logic [SCALE_CFGW-1:0] scale_pack(
      input logic [GAINW-1:0]     gain,
      input logic [SHW-1:0]       shift,
      input logic signed [YW-1:0] lo,
      input logic signed [YW-1:0] hi);
    scale_pack = '0;
    scale_pack[GAIN_LSB  +: GAINW] = gain;
    scale_pack[SHIFT_LSB +: SHW]   = shift;
    scale_pack[LO_LSB    +: YW]    = lo;
    scale_pack[HI_LSB    +: YW]    = hi;
  endfunction

  function automatic logic [BURST_CFGW-1:0] burst_pack(
      input logic [LENW-1:0]    len,
      input logic [STRIDEW-1:0] stride,
      input logic [ADDRW-1:0]   base,
      input logic               hdr_en);
    burst_pack = '0;
    burst_pack[LEN_LSB    +: LENW]    = len;
    burst_pack[STRIDE_LSB +: STRIDEW] = stride;
    burst_pack[BASE_LSB   +: ADDRW]   = base;
    burst_pack[HDREN_LSB]             = hdr_en;
  endfunction

  // ===========================================================================
  // Golden model of the scaler.
  //
  // Round-half-up on a variable right shift, then a symmetric clamp. Written as
  // straight-line arithmetic on purpose: cfg_pipe_scale.sv spreads exactly this
  // over three stages, and a model that shared its staging could not detect a
  // beat picking up the wrong stage's configuration.
  //
  // SIGNEDNESS: `x * gain` with `gain` unsigned makes the WHOLE multiply
  // unsigned (docs/17) -- a negative sample would come out as a huge positive
  // product. Both operands are therefore forced signed, `gain` by zero-extending
  // it into a signed value one bit wider.
  // ===========================================================================
  function automatic logic signed [YW-1:0] scale_ref(
      input logic [GAINW-1:0]     gain,
      input logic [SHW-1:0]       shift,
      input logic signed [YW-1:0] lo,
      input logic signed [YW-1:0] hi,
      input logic signed [XW-1:0] x);
    logic signed [PW-1:0] p;
    logic signed [SW-1:0] p_ext, rnd, r, lo_e, hi_e;

    p     = $signed(x) * $signed({1'b0, gain});
    p_ext = {{(SW-PW){p[PW-1]}}, p};
    rnd   = (shift == '0) ? '0 : (SW'(1) << (shift - 1'b1));
    r     = (p_ext + rnd) >>> shift;

    lo_e  = {{(SW-YW){lo[YW-1]}}, lo};
    hi_e  = {{(SW-YW){hi[YW-1]}}, hi};

    if      (r > hi_e) scale_ref = hi;
    else if (r < lo_e) scale_ref = lo;
    else               scale_ref = r[YW-1:0];
  endfunction

endpackage
