// -----------------------------------------------------------------------------
// dot_rs_elastic.sv -- the SAME staged datapath as dot_rs_global.sv, with
// per-stage elastic control instead of one global enable.
//
//     dot_rs_global :  pipe_ctrl        + dot_rs_dp,  adv = {4{en}}
//     dot_rs_elastic:  pipe_ripple_ctrl + dot_rs_dp,  adv = per-stage
//
// The datapath file is not touched. That is the argument of docs/38: how a
// pipeline stalls is a property of its CONTROL, and swapping the control is a
// one-line change if the datapath was written with per-stage enables in the first
// place. Writing `if (en)` directly into a datapath is what makes the choice
// expensive to revisit later.
//
// WHAT CHANGES, BEHAVIOURALLY
//
//   * There is a valid/ready handshake on both ends, so the block composes with
//     anything else that speaks it -- no `en` wire from three modules away.
//   * BUBBLES COLLAPSE. A gap in the input is squeezed out as beats pack towards
//     the exit, so a stalled output does not preserve the input's gaps. Latency
//     is therefore NOT constant: a beat takes LATENCY cycles only if it never
//     waits. Anything downstream that assumed a fixed latency (a sideband delay
//     line, say) must be driven from this module's valid, not from a counter.
//   * The cost is in the READY path: pipe_ripple_ctrl's `s_ready` is an OR chain
//     through every stage. Four stages is free; at thirty-two stages that chain
//     is the critical path, and the fix is an axis_reg_slice every few stages --
//     measured in docs/38 section 4.
//
// NOT SHOWN HERE, deliberately: inserting those slices. It is one instance per
// break point and it would triple the length of this file without adding an idea.
// -----------------------------------------------------------------------------
`default_nettype none

module dot_rs_elastic #(
  parameter int unsigned TAPS = 4,
  parameter int unsigned XW   = 8,
  parameter int unsigned CW   = 10,
  parameter int unsigned CF   = 8,
  parameter int unsigned YW   = 8,
  parameter logic [3:0]  CUTS = 4'b1111
) (
  input  var logic                clk,
  input  var logic                rst_n,

  input  var logic                flush,

  input  var logic                s_valid,
  output var logic                s_ready,
  input  var logic [TAPS*XW-1:0]  x,
  input  var logic [TAPS*CW-1:0]  c,

  output var logic                m_valid,
  input  var logic                m_ready,
  output var logic [YW-1:0]       y
);

  localparam int unsigned LATENCY = pipe_pkg::cuts_below(CUTS, 4);

  if (LATENCY == 0) begin : g_chk_lat
    $error("dot_rs_elastic: CUTS must enable at least one cut");
  end

  logic [LATENCY-1:0] adv_ctrl, valid_q;
  logic [3:0]         adv_dp;

  pipe_ripple_ctrl #(.STAGES(LATENCY)) u_ctrl (
    .clk     (clk),
    .rst_n   (rst_n),
    .s_valid (s_valid),
    .s_ready (s_ready),
    .m_valid (m_valid),
    .m_ready (m_ready),
    .flush   (flush),
    .adv     (adv_ctrl),
    .valid_q (valid_q)
  );

  // Control stage i owns cut k when cuts_below(CUTS, k) == i, which is exactly
  // the low LATENCY bits. The unused high bits are never read by the datapath.
  assign adv_dp = 4'(adv_ctrl);

  dot_rs_dp #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW), .CUTS(CUTS)) u_dp (
    .clk   (clk),
    .rst_n (rst_n),
    .adv   (adv_dp),
    .x     (x),
    .c     (c),
    .y     (y)
  );

`ifndef SYNTHESIS
  // The output side of the handshake contract. Note that this is a property of
  // the CONTROL -- the datapath registers hold because their enables are low --
  // which is why it is asserted here and not in dot_rs_dp.sv.
  a_out_stable: assert property (@(posedge clk) disable iff (!rst_n || flush)
    (m_valid && !m_ready) |=> (m_valid && $stable(y)))
    else $error("dot_rs_elastic: output moved before the handshake completed");

  a_flush_clears: assert property (@(posedge clk) disable iff (!rst_n)
    flush |=> !m_valid)
    else $error("dot_rs_elastic: flush left a valid beat at the output");
`endif

endmodule

`default_nettype wire
