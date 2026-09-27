// -----------------------------------------------------------------------------
// skew_buffer.sv -- rejoins two branches of a pipeline that have drifted apart.
//
// The problem is not stalling; it is RECONVERGENCE. A pipeline forks, the two
// branches do different amounts of work, and the results have to be paired up
// again:
//
//            .------ branch A (3 stages, sometimes stalls) ------.
//   in ----- |                                                   | ---> out
//            '------ branch B (7 stages, never stalls) ----------'
//
// Three things can go wrong at the join, and only the first is obvious:
//
//   1. FIXED LATENCY DIFFERENCE. B is four cycles behind A, for ever. The fix is
//      a delay line (pipe_delay.sv) on A, sized to the difference -- and that is
//      the right fix only while the difference is CONSTANT.
//   2. VARIABLE DIFFERENCE. If either branch can stall independently, no delay
//      line can match them: the skew changes at run time. That is what this
//      module is for.
//   3. A JOIN WITH NO STORAGE COUPLES THE BRANCHES. The obvious join --
//      `m_valid = a_valid && b_valid` with a shared ready -- means every stall in
//      A becomes a stall in B and vice versa. Two branches that each stall 5% of
//      the time now stall 10%, and a stall anywhere is a stall everywhere. This
//      is how a "local" backpressure scheme quietly becomes a global one.
//
// So: a small FIFO on each side, and the join fires when both have a beat. The
// branches are then decoupled up to DEPTH beats of skew -- one may run that far
// ahead of the other before it is made to wait.
//
// SIZING. DEPTH is the skew the design tolerates without loss of throughput, and
// it is the same bandwidth-delay calculation as any other elastic buffer
// (docs/30): if branch A stalls for up to S cycles at a time while B keeps
// producing one beat per cycle, DEPTH must be at least S or B stalls too. Sizing
// it by "4 looks about right" is the usual reason a reconverging pipeline runs at
// 80% of the rate its arithmetic could sustain.
//
// WHAT THIS DOES NOT DO: reorder. Beat n of A is paired with beat n of B, always.
// If the branches can produce results out of order -- variable-latency stages,
// multiple outstanding requests -- pairing by arrival is wrong and you need tags
// (docs/21 section 10), not a skew buffer.
// -----------------------------------------------------------------------------
`default_nettype none

module skew_buffer #(
  parameter int unsigned DWA   = 16,    // branch A payload width
  parameter int unsigned DWB   = 16,    // branch B payload width
  parameter int unsigned DEPTH = 4      // beats of skew absorbed; power of two
) (
  input  var logic            clk,
  input  var logic            rst_n,

  input  var logic            a_valid,
  input  var logic [DWA-1:0]  a_data,
  output var logic            a_ready,

  input  var logic            b_valid,
  input  var logic [DWB-1:0]  b_data,
  output var logic            b_ready,

  output var logic            m_valid,
  output var logic [DWA-1:0]  m_a,
  output var logic [DWB-1:0]  m_b,
  input  var logic            m_ready,

  // How far branch A is ahead of B, in beats. Positive: A is ahead. Worth
  // bringing out to a register or a counter -- it is the number that tells you
  // whether DEPTH was chosen correctly, and it costs nothing to look at.
  output var logic signed [$clog2(DEPTH)+2:0] skew
);

  localparam int unsigned LW = $clog2(DEPTH) + 1;     // sync_fifo level width

  logic            a_full, b_full, a_empty, b_empty;
  logic [LW-1:0]   a_level, b_level;
  logic            xfer;

  // The join. Both sides must have a beat, and both are acknowledged together --
  // that is what keeps the pairing.
  assign m_valid = !a_empty && !b_empty;
  assign xfer    = m_valid && m_ready;
  assign a_ready = !a_full;
  assign b_ready = !b_full;

  sync_fifo #(.DW(DWA), .DEPTH(DEPTH), .FWFT(1'b1)) u_fifo_a (
    .clk (clk), .rst_n (rst_n),
    .wr_en (a_valid && a_ready), .wr_data (a_data),
    .full (a_full), .almost_full (),
    .rd_en (xfer), .rd_data (m_a),
    .empty (a_empty), .almost_empty (),
    .level (a_level)
  );

  sync_fifo #(.DW(DWB), .DEPTH(DEPTH), .FWFT(1'b1)) u_fifo_b (
    .clk (clk), .rst_n (rst_n),
    .wr_en (b_valid && b_ready), .wr_data (b_data),
    .full (b_full), .almost_full (),
    .rd_en (xfer), .rd_data (m_b),
    .empty (b_empty), .almost_empty (),
    .level (b_level)
  );

  assign skew = $signed({2'b0, a_level}) - $signed({2'b0, b_level});

`ifndef SYNTHESIS
  // The pairing property, stated where it can be seen: both sides advance
  // together or not at all. A join that reads one FIFO without the other is how
  // the branches get permanently offset by one -- and the symptom is not a
  // missing beat, it is every subsequent beat paired with the wrong partner.
  a_paired: assert property (@(posedge clk) disable iff (!rst_n)
    (u_fifo_a.do_rd == u_fifo_b.do_rd))
    else $error("skew_buffer: one side advanced without the other");

  // The skew cannot exceed what was paid for.
  a_skew_bounded: assert property (@(posedge clk) disable iff (!rst_n)
    (skew <= $signed(DEPTH)) && (skew >= -$signed(DEPTH)))
    else $error("skew_buffer: skew %0d exceeds DEPTH %0d", skew, DEPTH);

  // Output stability, as for any valid/ready producer.
  a_out_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_valid && !m_ready) |=> (m_valid && $stable(m_a) && $stable(m_b)))
    else $error("skew_buffer: output moved before the handshake completed");
`endif

endmodule

`default_nettype wire
