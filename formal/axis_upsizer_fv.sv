// -----------------------------------------------------------------------------
// axis_upsizer_fv.sv -- no lane is lost and none is invented.
//
// Width conversion has exactly one safety property worth proving and it is a
// conservation law: every input beat becomes exactly one lane of exactly one
// output beat. Lose lanes and you drop the tail of a packet; invent them and
// you pad it with whatever was in the accumulator. Both failures depend on the
// packet length modulo the ratio, so they hide from any test that sends round
// numbers of beats -- which is what makes this a formal problem rather than a
// simulation one.
//
// The accounting identity itself is inside axis_upsizer.sv, next to the state
// it relates (`keep`, `m_tkeep`). This harness supplies the environment: the
// upstream manager's obligation to hold VALID and its payload steady, and the
// covers that show the interesting cases -- a full group, a SHORT group, and a
// short group of exactly one lane -- are all reachable.
// -----------------------------------------------------------------------------
`default_nettype none

module axis_upsizer_fv #(
  parameter int unsigned DW_IN = 8,
  parameter int unsigned RATIO = 4
) (
  input  var logic             clk,
  input  var logic             rst_n,
  input  var logic [DW_IN-1:0] s_tdata,
  input  var logic             s_tvalid,
  input  var logic             s_tlast,
  input  var logic             m_tready
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic                     s_tready, m_tvalid, m_tlast;
  logic [DW_IN*RATIO-1:0]   m_tdata;
  logic [RATIO-1:0]         m_tkeep;

  axis_upsizer #(.DW_IN(DW_IN), .RATIO(RATIO)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready),
    .s_tlast(s_tlast),
    .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
    .m_tready(m_tready), .m_tlast(m_tlast));

  // The upstream side of the handshake contract, assumed (docs/30).
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_tvalid) && !$past(s_tready))
      assume (s_tvalid && (s_tdata == $past(s_tdata))
                       && (s_tlast == $past(s_tlast)));

  // This module's own side of it, asserted.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(m_tvalid) && !$past(m_tready))
      f_m_stable : assert (m_tvalid && (m_tdata == $past(m_tdata))
                                    && (m_tkeep == $past(m_tkeep))
                                    && (m_tlast == $past(m_tlast)));

  // Only a final word may be short. A short word mid-packet is a dropped lane
  // that the accounting alone would not localise.
  always @* f_short_only_last : assert (!m_tvalid || (&m_tkeep) || m_tlast);

  always @(posedge clk) begin
    f_c_full_group  : cover (rst_n && m_tvalid && (&m_tkeep));
    f_c_short_group : cover (rst_n && m_tvalid && !(&m_tkeep) && m_tlast);
    f_c_single_lane : cover (rst_n && m_tvalid && (m_tkeep == 1) && m_tlast);
    f_c_backpressure: cover (rst_n && m_tvalid && !m_tready);
  end

endmodule

`default_nettype wire
