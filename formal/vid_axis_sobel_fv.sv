// -----------------------------------------------------------------------------
// vid_axis_sobel_fv.sv -- the 3x3 Sobel magnitude block, and a demonstration of
// a property that is true, provable, and worth exactly nothing as a check.
//
// WHAT IS PROVED WHERE. The substantive properties live inside vid_axis_sobel.sv,
// where the pre-saturation gradients are visible:
//
//   * a flat patch has zero magnitude
//   * the saturation is a clamp, and the unsaturated case is exact
//   * a row-constant patch has gy == 0, and a column-constant patch gx == 0
//
// The last pair is the interesting one, because it is the ONLY thing here that
// can catch a transposed window index. See below.
//
// THE MIRROR AND TRANSPOSE TASKS instantiate the block twice, feeding the second
// copy a transformed window, and assert that the outputs agree:
//
//   mirror     window columns reversed        |Gx| flips sign, |Gy| unchanged
//   transpose  window transposed (N=1)        Gx and Gy swap, because the two
//                                             kernels are each other's transpose
//
// Both hold, and both are worth stating: they are the symmetries an edge
// magnitude is supposed to have, and a kernel that was asymmetric by mistake --
// weights 1,2,1 on one side and 1,1,1 on the other -- breaks them.
//
// BUT THE TRANSPOSE TASK CANNOT CATCH A TRANSPOSED INDEX, and that is the lesson.
// If the design reads w[c][r] instead of w[r][c], it computes |Gy| + |Gx| instead
// of |Gx| + |Gy| -- the same number. The task still passes. This is the same trap
// as the identity matrix in vid_axis_csc_fv.sv, one level deeper: there the
// blindness was a property of the test vector, here it is a property of the
// FUNCTION BEING COMPUTED, so no test applied at the output can help. Only the
// asymmetric assertions on the internal gradients can, which is why they are
// inside the module and not in this harness.
//
// EQUIVALENCE TASKS MUST BE BMC, NOT PROVE. Induction starts from an arbitrary
// state, in which the two instances' output registers hold unrelated values, and
// the equality fails immediately for reasons that have nothing to do with the
// design. This is the same reason fsm_three_process_fv keeps its cross-module
// equivalence behind `ifdef EQUIV`.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_sobel_fv #(
  parameter int unsigned N = 1,     // one output pixel: the window IS the patch
  parameter int unsigned P = 1,
  parameter int unsigned B = 4,
  parameter int unsigned R = 3
) (
  input  var logic                    clk,
  input  var logic                    rst_n,
  input  var logic [R*(N+2)*P*B-1:0]  s_win,
  input  var logic                    s_tvalid,
  input  var logic                    s_tlast,
  input  var logic                    m_tready
);

  localparam int unsigned COLS = N + 2;

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic              s_tready, m_tvalid, m_tlast;
  logic [N*P*B-1:0]  m_tdata;
  logic [0:0]        m_tuser;

  vid_axis_sobel #(.N(N), .P(P), .B(B), .R(R), .GRAD_COMP(0), .SHIFT(0),
                   .UW(1)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_win(s_win), .s_tvalid(s_tvalid), .s_tready(s_tready),
    .s_tlast(s_tlast), .s_tuser(1'b0),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
    .m_tlast(m_tlast), .m_tuser(m_tuser));

  // The upstream side of the handshake contract, assumed (docs/30).
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_tvalid) && !$past(s_tready))
      assume (s_tvalid && (s_win == $past(s_win)));

  // This module's side of it, asserted.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(m_tvalid) && !$past(m_tready))
      f_m_stable : assert (m_tvalid && (m_tdata == $past(m_tdata)));

`ifdef SYMMETRY
  // A second copy, fed a transformed window.
  logic [R*COLS*P*B-1:0] win_t;

  for (genvar r = 0; r < int'(R); r++) begin : g_tr
    for (genvar c = 0; c < int'(COLS); c++) begin : g_tc
`ifdef TRANSPOSE
      // Rows and columns exchanged. Only meaningful while R == COLS, which is
      // why this harness runs at N=1.
      assign win_t[vid_pkg::rowpix_lsb(r, c, 0, COLS, P, B) +: B] =
             s_win[vid_pkg::rowpix_lsb(c, r, 0, COLS, P, B) +: B];
`else
      // Columns reversed: a left-right mirror of the picture.
      assign win_t[vid_pkg::rowpix_lsb(r, c, 0, COLS, P, B) +: B] =
             s_win[vid_pkg::rowpix_lsb(r, COLS - 1 - c, 0, COLS, P, B) +: B];
`endif
    end
  end

  logic              t_tready, t_tvalid, t_tlast;
  logic [N*P*B-1:0]  t_tdata;
  logic [0:0]        t_tuser;

  vid_axis_sobel #(.N(N), .P(P), .B(B), .R(R), .GRAD_COMP(0), .SHIFT(0),
                   .UW(1)) dut_t (
    .clk(clk), .rst_n(rst_n),
    .s_win(win_t), .s_tvalid(s_tvalid), .s_tready(t_tready),
    .s_tlast(s_tlast), .s_tuser(1'b0),
    .m_tdata(t_tdata), .m_tvalid(t_tvalid), .m_tready(m_tready),
    .m_tlast(t_tlast), .m_tuser(t_tuser));

  always @(posedge clk) begin
    if (rst_n) begin
      // Identical handshake signals, so the two copies must also stay in step.
      f_lockstep : assert (m_tvalid == t_tvalid);
      if (m_tvalid) f_symmetry : assert (m_tdata == t_tdata);
    end
  end
`endif

  always @(posedge clk) begin
    f_c_output     : cover (rst_n && m_tvalid);
    f_c_saturated  : cover (rst_n && m_tvalid && (m_tdata == {B{1'b1}}));
    f_c_zero_edge  : cover (rst_n && m_tvalid && (m_tdata == '0) && s_tvalid);
    f_c_mid        : cover (rst_n && m_tvalid && (m_tdata != '0)
                                             && (m_tdata != {B{1'b1}}));
  end

endmodule

`default_nettype wire
