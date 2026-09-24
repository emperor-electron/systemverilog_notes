// -----------------------------------------------------------------------------
// vid_axis_csc_fv.sv -- the colour-space converter, two ways.
//
// TASK `bmc` / `prove`: the coefficients are left FREE. So the clamp properties
// inside vid_axis_csc.sv -- round, then saturate to [0, 2^B-1], never wrap --
// are proved for EVERY matrix and offset the block can be programmed with, not
// just the ones a testbench thought to try. That is the statement worth having:
// a colour matrix is data, and "it saturates correctly for BT.709" is a much
// weaker claim than "it saturates correctly".
//
// TASK `ident`: the coefficients are ASSUMED to be the identity with zero
// offset, and the output is asserted equal to the input. This catches confusion
// between the PIXEL and COMPONENT axes of the data layout, and any off-by-one in
// comp_lsb -- and unlike a check against a reference model, a reference cannot
// make the same mistake and agree.
//
// What it does NOT catch, and this was measured rather than assumed: swapping
// the two axes of the COEFFICIENT index. The identity matrix is symmetric, so
// coef[o][i] and coef[i][o] address the same values and a transposed matrix
// index passes cleanly. Writing this harness the obvious way produced a proof
// that looked like it covered the indexing and did not.
//
// TASK `basis`: the fix. The matrix is assumed to be zero everywhere except ONE
// entry, at a position the solver is free to choose, and then output component
// o0 must equal input component i0 while every other output component is zero.
// That is the definition of a linear map checked on basis vectors: it is
// asymmetric, it ranges over all P*P positions, and it needs no arithmetic in
// the harness -- so there is no expression here that could repeat a mistake made
// in the design.
//
// Sized small on purpose: N=1, P=2, B=4. The proof cost grows with N*P*B and the
// confidence does not -- an index that is wrong is wrong at P=2.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_csc_fv #(
  parameter int unsigned N  = 1,
  parameter int unsigned P  = 2,
  parameter int unsigned B  = 4,
  parameter int unsigned CW = 8,
  parameter int unsigned CF = 4
) (
  input  var logic              clk,
  input  var logic              rst_n,
  input  var logic [P*P*CW-1:0] coef,
  input  var logic [P*CW-1:0]   offset,
  input  var logic [N*P*B-1:0]  s_tdata,
  input  var logic              s_tvalid,
  input  var logic              s_tlast,
  input  var logic [0:0]        s_tuser,
  input  var logic              m_tready,
  // `basis` task only: which single coefficient is nonzero. Left free so the
  // solver tries every position.
  input  var logic [IDXW-1:0]   o0,
  input  var logic [IDXW-1:0]   i0
);

  localparam int unsigned IDXW = (P <= 1) ? 1 : $clog2(P) + 1;

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic                s_tready, m_tvalid, m_tlast;
  logic [N*P*B-1:0]    m_tdata;
  logic [0:0]          m_tuser;

  vid_axis_csc #(.N(N), .P(P), .B(B), .CW(CW), .CF(CF), .UW(1)) dut (
    .clk(clk), .rst_n(rst_n),
    .coef(coef), .offset(offset),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready),
    .s_tlast(s_tlast), .s_tuser(s_tuser),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
    .m_tlast(m_tlast), .m_tuser(m_tuser));

  // The upstream side of the handshake contract, assumed (docs/30).
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_tvalid) && !$past(s_tready))
      assume (s_tvalid && (s_tdata == $past(s_tdata))
                       && (s_tlast == $past(s_tlast))
                       && (s_tuser == $past(s_tuser)));

  // Coefficients are configuration: a matrix that changes every cycle has no
  // conversion to reason about, and the module's own header says updates belong
  // between frames.
  always @(posedge clk)
    if (!init) begin
      assume ($stable(coef));
      assume ($stable(offset));
    end

`ifdef IDENTITY
  // Identity matrix, zero offset. Written as a loop over both axes so the
  // ASSUMPTION uses the same indexing rule as the design -- if that rule is
  // what is broken, this constrains the wrong coefficients and the proof fails,
  // which is the outcome we want.
  always @* begin
    assume (offset == '0);
    for (int o = 0; o < int'(P); o++)
      for (int i = 0; i < int'(P); i++)
        assume (coef[((o*P)+i)*CW +: CW] ==
                CW'((o == i) ? (1 << CF) : 0));
  end

  // Identity in, identity out -- exactly, for every pixel value.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_tvalid && s_tready))
      f_identity : assert (m_tdata == $past(s_tdata));
`endif

`ifdef BASIS
  // One nonzero entry, at a free position. `assume` rather than drive, so the
  // solver enumerates all P*P placements.
  always @* begin
    assume (o0 < IDXW'(P));
    assume (i0 < IDXW'(P));
    assume (offset == '0);
    for (int o = 0; o < int'(P); o++)
      for (int i = 0; i < int'(P); i++)
        assume (coef[((o*P)+i)*CW +: CW] ==
                CW'(((IDXW'(o) == o0) && (IDXW'(i) == i0)) ? (1 << CF) : 0));
  end

  always @(posedge clk) if (!init) begin
    assume ($stable(o0));
    assume ($stable(i0));
  end

  // Output component o0 is input component i0; every other output is zero.
  // Unlabelled inside the generate loop -- Yosys does not uniquify immediate
  // assertion labels by scope (see vid_axis_gain.sv).
  for (genvar n = 0; n < int'(N); n++) begin : g_basis_pix
    for (genvar o = 0; o < int'(P); o++) begin : g_basis_out
      always @(posedge clk)
        if (past_ok && rst_n && $past(rst_n) && $past(s_tvalid && s_tready)) begin
          if (IDXW'(o) == o0)
            assert (m_tdata[((n*P)+o)*B +: B] ==
                    $past(s_tdata[((n*P)+i0)*B +: B]));
          else
            assert (m_tdata[((n*P)+o)*B +: B] == '0);
        end
    end
  end
`endif

  // Sideband must accompany its own beat, whatever the matrix is.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_tvalid && s_tready)) begin
      f_last_aligned : assert (m_tlast == $past(s_tlast));
      f_user_aligned : assert (m_tuser == $past(s_tuser));
    end

  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(m_tvalid) && !$past(m_tready))
      f_hold : assert (m_tvalid && (m_tdata == $past(m_tdata)));

  always @(posedge clk) begin
    f_c_beat       : cover (rst_n && m_tvalid && m_tready);
    f_c_backpress  : cover (rst_n && m_tvalid && !m_tready);
    f_c_saturated  : cover (rst_n && m_tvalid && (m_tdata[B-1:0] == '1));
    f_c_zeroed     : cover (rst_n && m_tvalid && (m_tdata[B-1:0] == '0));
  end

endmodule

`default_nettype wire
