// -----------------------------------------------------------------------------
// cfg_pipe_scale.sv -- a three-stage datapath whose configuration is used at
// three different times, which is what makes reconfiguring a pipeline different
// from reconfiguring an FSM.
//
//      y = clamp( round( (x * gain) >> shift ), lo, hi )
//
//      stage 0   multiply         uses  gain
//      stage 1   round and shift   uses  shift
//      stage 2   clamp             uses  lo, hi
//
// A beat entering at cycle T is multiplied at T, shifted at T+1 and clamped at
// T+2. If the configuration is read live at each stage, a write landing at T+1
// gives that one beat the OLD gain and the NEW shift -- a result that corresponds
// to no configuration software ever wrote, and which no amount of range-checking
// at the output would flag as wrong. It is not a stale value and it is not a new
// value; it is a mixture, and mixtures are why "the register was written between
// two clock edges, so at worst one frame is a bit off" is not true.
//
// CFG_MODE -- three answers, and the interesting part is that two of them are the
// same gates:
//
//   0 LIVE     every stage reads `cfg`. `safe` is tied high, which is a lie. The
//              unprotected baseline.
//   1 QUIESCE  every stage reads `cfg` -- THE SAME DATAPATH AS MODE 0, bit for
//              bit. The only difference is `safe`, one output bit, which now says
//              "empty, and nothing entering". Software must wait for the pipeline
//              to drain before its write takes effect, so reconfiguring costs a
//              bubble of LATENCY cycles; in exchange the datapath costs nothing.
//   2 TRAVEL   the fields ride along with the beat that entered under them, each
//              delayed to the stage that consumes it. `safe` is tied high and
//              means it: the configuration can change on any cycle, at full rate,
//              and every beat is computed entirely under the configuration that
//              was active when it entered.
//
// That MODE 0 and MODE 1 synthesise to the same datapath is the most useful thing
// in this file. The fix for a pipeline that corrupts data when reconfigured can be
// zero gates of datapath and one bit of correctly-specified interface -- and,
// equally, a datapath that looks completely correct in isolation can be wrong
// because of a bit it does not have.
//
// WHY `safe` IS NOT `!busy`
//
// The obvious condition for MODE 1 is "the pipeline is empty". It is not enough,
// and the proof says so: at the edge where a commit lands, a beat presented on
// that same cycle enters stage 0 with the OLD gain, and meets the NEW shift one
// cycle later. Empty is not sufficient; empty AND not admitting anything is.
// Weakening this to `!busy` makes dot-for-dot the same corruption as MODE 0, just
// rarer -- docs/39 section 11 records it as a mutation and the `travel` proof
// catches it in 7 steps.
//
// The stall is a global clock enable (docs/38 section 6). Note that `en` has to
// gate the travelling configuration registers as well as the data: freezing a
// beat in stage 1 while its `shift` advances is the same corruption again, one
// level down.
//
// See docs/39-control-registers-and-safe-reconfiguration.md.
// -----------------------------------------------------------------------------
`default_nettype none

module cfg_pipe_scale #(
  parameter int unsigned CFG_MODE = 2
) (
  input  var logic                             clk,
  input  var logic                             rst_n,
  input  var logic                             en,       // 0 = global stall

  input  var logic [cfg_pkg::SCALE_CFGW-1:0]   cfg,

  input  var logic                             x_valid,
  input  var logic signed [cfg_pkg::XW-1:0]    x,

  output var logic                             y_valid,
  output var logic signed [cfg_pkg::YW-1:0]    y,

  output var logic                             busy,
  output var logic                             safe      // ok to commit now
);

  localparam int unsigned M_LIVE    = 0;
  localparam int unsigned M_QUIESCE = 1;
  localparam int unsigned M_TRAVEL  = 2;

  localparam int unsigned XW    = cfg_pkg::XW;
  localparam int unsigned GAINW = cfg_pkg::GAINW;
  localparam int unsigned SHW   = cfg_pkg::SHW;
  localparam int unsigned YW    = cfg_pkg::YW;
  localparam int unsigned PW    = cfg_pkg::PW;
  localparam int unsigned SW    = cfg_pkg::SW;

  localparam int unsigned STAGES = 3;

  // ---- valid propagation, from the control block of docs/38 ----------------
  logic [STAGES-1:0] valid_q;

  pipe_ctrl #(.STAGES(STAGES)) u_ctl (
    .clk     (clk),
    .rst_n   (rst_n),
    .en      (en),
    .flush   (1'b0),
    .valid_i (x_valid),
    .valid_o (y_valid),
    .valid_q (valid_q),
    .busy    (busy)
  );

  // ===========================================================================
  // Which configuration each stage reads. This is the entire subject of the
  // module; the arithmetic below is identical in all three modes.
  // ===========================================================================
  logic [GAINW-1:0]     gain_s0;
  logic [SHW-1:0]       shift_s1;
  logic signed [YW-1:0] lo_s2, hi_s2;

  // Stage 0 always reads the live configuration, in every mode, and that is
  // correct in every mode: the beat is entering now, so "now" IS its entry
  // configuration.
  assign gain_s0 = cfg_pkg::scale_gain(cfg);

  if (CFG_MODE == M_TRAVEL) begin : g_travel
    // Each field is delayed to the stage that consumes it and no further. The
    // naive version pipelines the whole 64-bit bundle to the end -- 128 flops --
    // and this one costs 52, because `shift` is needed one stage down and the two
    // clamp bounds two. Measured in docs/39 section 7.
    logic [SHW-1:0]       sh_d1;
    logic signed [YW-1:0] lo_d1, hi_d1, lo_d2, hi_d2;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        sh_d1 <= '0;
        lo_d1 <= '0;  hi_d1 <= '0;
        lo_d2 <= '0;  hi_d2 <= '0;
      end else if (en) begin
        // Gated by `en` alongside the data registers. Unconditional here and a
        // stalled beat meets a configuration that moved while it waited.
        sh_d1 <= cfg_pkg::scale_shift(cfg);
        lo_d1 <= cfg_pkg::scale_lo(cfg);
        hi_d1 <= cfg_pkg::scale_hi(cfg);
        lo_d2 <= lo_d1;
        hi_d2 <= hi_d1;
      end
    end

    assign shift_s1 = sh_d1;
    assign lo_s2    = lo_d2;
    assign hi_s2    = hi_d2;

    // The configuration may change on any cycle, and this is not a lie: every
    // consumer of a field sees the copy that entered with its beat.
    assign safe = 1'b1;

  end else begin : g_shared
    // MODES 0 AND 1 SHARE THIS BRANCH. Identical datapath, identical cost. The
    // difference between a correct design and a silently corrupting one is the
    // one assignment below.
    assign shift_s1 = cfg_pkg::scale_shift(cfg);
    assign lo_s2    = cfg_pkg::scale_lo(cfg);
    assign hi_s2    = cfg_pkg::scale_hi(cfg);

    if (CFG_MODE == M_QUIESCE) begin : g_quiesce
      // Empty, AND not admitting a beat on this cycle. See the header: `!busy`
      // alone leaves exactly one cycle of exposure, and one cycle is enough.
      assign safe = !busy && !(x_valid && en);
    end else begin : g_unsafe
      assign safe = 1'b1;
    end
  end

  // ===========================================================================
  // The datapath. Three cuts, no configuration decisions.
  // ===========================================================================
  logic signed [PW-1:0] p_q, p_d;
  logic signed [SW-1:0] r_q, r_d, p_ext, rnd, lo_e, hi_e;
  logic signed [YW-1:0] y_q, y_d;

  // Stage 0: the multiply. `gain` is unsigned, so without forcing both operands
  // signed the whole expression goes unsigned and a negative sample comes out as
  // a large positive product (docs/17).
  always_comb p_d = $signed(x) * $signed({1'b0, gain_s0});

  // Stage 1: round half up on a variable right shift.
  always_comb begin
    p_ext = {{(SW-PW){p_q[PW-1]}}, p_q};
    rnd   = (shift_s1 == '0) ? '0 : (SW'(1) << (shift_s1 - 1'b1));
    r_d   = (p_ext + rnd) >>> shift_s1;
  end

  // Stage 2: clamp. Both bounds sign-extended explicitly rather than by a size
  // cast, so the comparison cannot depend on how a tool reads the cast.
  always_comb begin
    lo_e = {{(SW-YW){lo_s2[YW-1]}}, lo_s2};
    hi_e = {{(SW-YW){hi_s2[YW-1]}}, hi_s2};
    if      (r_q > hi_e) y_d = hi_s2;
    else if (r_q < lo_e) y_d = lo_s2;
    else                 y_d = r_q[YW-1:0];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_q <= '0;
      r_q <= '0;
      y_q <= '0;
    end else if (en) begin
      p_q <= p_d;
      r_q <= r_d;
      y_q <= y_d;
    end
  end

  assign y = y_q;

`ifdef FORMAL
  // The reference model lives in the harness, not here: for MODE 2 this module
  // already holds a delayed copy of the configuration, and a property built from
  // it would be comparing the design against itself. What can be checked from
  // inside is the stall discipline and the meaning of `safe`.
  logic f_rst_q = 1'b0;
  always_ff @(posedge clk) f_rst_q <= rst_n;

  always @(posedge clk) begin
    if (rst_n && f_rst_q) begin
      if (CFG_MODE == M_QUIESCE) assert (safe == (!busy && !(x_valid && en)));
      else                       assert (safe);
    end
  end

  if (CFG_MODE == M_TRAVEL) begin : g_fv_hold
    logic                 f_en_q = 1'b0;
    logic [SHW-1:0]       f_sh_q;
    logic signed [YW-1:0] f_lo_q, f_hi_q;

    always_ff @(posedge clk) begin
      f_en_q <= en;
      f_sh_q <= shift_s1;
      f_lo_q <= lo_s2;
      f_hi_q <= hi_s2;
    end

    // A stalled beat's configuration is stalled with it. This is the one-level-
    // down version of the whole document's thesis, and it is cheap to state.
    //
    // `!f_en_q`, not `!en`: the question is whether the registers moved at the
    // LAST EDGE, and the enable that governed that edge is the one from the
    // previous cycle. Written with `!en` this failed at step 2 on the perfectly
    // correct sequence en=1 then en=0 -- the second property in this document to
    // be wrong about which cycle it was talking about, which is enough of a
    // pattern to be worth naming: a property over a registered signal is a
    // statement about the edge, not about now.
    always @(posedge clk)
      if (rst_n && f_rst_q && !f_en_q) begin
        assert (shift_s1 == f_sh_q);
        assert (lo_s2    == f_lo_q);
        assert (hi_s2    == f_hi_q);
      end
  end
`endif

`ifndef SYNTHESIS
  a_stall_holds: assert property (@(posedge clk) disable iff (!rst_n)
    (!en) |=> ($stable(y) && $stable(y_valid)))
    else $error("cfg_pipe_scale: output advanced while stalled");
`endif

endmodule

`default_nettype wire
