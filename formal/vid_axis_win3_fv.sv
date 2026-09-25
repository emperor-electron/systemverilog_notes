// -----------------------------------------------------------------------------
// vid_axis_win3_fv.sv -- the horizontal window builder.
//
// This is the only block in the family with interesting CONTROL: it holds a beat
// back, needs the next one to finish the window, and must not drop or duplicate
// anything while doing it. So the properties split the way they always do in this
// repository -- what the module guarantees goes inside it, what its caller must
// provide is assumed here:
//
//   inside vid_axis_win3.sv     a beat is never loaded over an unemitted one;
//                               at most two beats are in flight (counters beside
//                               the state they account for, docs/25);
//                               the halo columns are replicated at line ends
//   here                        the handshake contract, and reachability
//
// WHAT IS DELIBERATELY NOT PROVED HERE, and why. The property this harness would
// most like to state is that the emitted window's CENTRE columns are the beat
// that was loaded, bit for bit. Stating it needs the pre-registered window and
// the emit condition, both internal, and the Yosys frontend cannot read into an
// instance at all: `dut.win` gives "Don't know how to detect sign and width for
// AST_AUTOWIRE node", and wrapping the same reference in a function gives
// "Failed to detect width for identifier ...dut.win". Exporting the window
// combinationally just to be able to assert on it would change the design to
// suit the proof.
//
// So that property lives in simulation instead, where video_filter_tb.sv checks
// every output pixel of every beat against a frame model with clamped
// coordinates -- which is exactly the centre-column mapping, stated over a whole
// frame rather than one beat. The split is not an accident of tooling alone: the
// per-beat invariants are what formal is good at, and the geometry of a frame is
// what a model is good at.
//
// N=2 deliberately: with N=1 the window has a single centre column and an
// off-by-one in the halo would look the same as an off-by-one in the centre.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_win3_fv #(
  parameter int unsigned N = 2,
  parameter int unsigned P = 1,
  parameter int unsigned B = 2,
  parameter int unsigned R = 2
) (
  input  var logic               clk,
  input  var logic               rst_n,
  input  var logic [R*N*P*B-1:0] s_rows,
  input  var logic               s_tvalid,
  input  var logic               s_tlast,
  input  var logic               m_tready
);

  localparam int unsigned COLS = N + 2;
  localparam int unsigned PIXB = P * B;

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic                     s_tready, m_tvalid, m_tlast;
  logic [R*COLS*P*B-1:0]    m_win;
  logic [0:0]               m_tuser;

  vid_axis_win3 #(.N(N), .P(P), .B(B), .R(R), .UW(1)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_rows(s_rows), .s_tvalid(s_tvalid), .s_tready(s_tready),
    .s_tlast(s_tlast), .s_tuser(1'b0),
    .m_win(m_win), .m_tvalid(m_tvalid), .m_tready(m_tready),
    .m_tlast(m_tlast), .m_tuser(m_tuser));

  // The upstream side of the handshake contract, assumed (docs/30).
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_tvalid) && !$past(s_tready))
      assume (s_tvalid && (s_rows == $past(s_rows)) && (s_tlast == $past(s_tlast)));

  always @(posedge clk) begin
    f_c_emit        : cover (rst_n && m_tvalid);
    f_c_line_end    : cover (rst_n && m_tvalid && m_tlast);
    f_c_backpressure: cover (rst_n && m_tvalid && !m_tready);
    // A line ending while nothing further is offered: the flush path, where the
    // right halo is replicated instead of waiting for a beat that is not coming.
    f_c_flush       : cover (rst_n && m_tvalid && m_tlast && !s_tvalid);
  end

endmodule

`default_nettype wire
