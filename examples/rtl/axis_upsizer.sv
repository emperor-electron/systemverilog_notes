// -----------------------------------------------------------------------------
// axis_upsizer.sv -- AXI-Stream width converter, narrow to wide.
//
// RATIO input beats are packed into one output beat, lane 0 first.
//
// THE HARD CASE IS A SHORT LAST GROUP. A packet whose length is not a multiple
// of RATIO ends mid-group, and the module cannot wait for lanes that will never
// arrive. It must emit the partial word immediately, and it must say which
// lanes are real -- which is what `m_tkeep` is for. Dropping the partial group
// loses the tail of every packet whose length is not a multiple of the ratio;
// padding it without tkeep silently appends zeros to those packets. Both are
// bugs that only appear for particular lengths, which is why a test that sends
// round numbers of beats never finds them.
//
// The lanes of a partial word are zeroed rather than left stale, so a receiver
// that ignores tkeep sees zeros rather than data from the previous packet.
// That is still wrong, but it is not a data leak.
// -----------------------------------------------------------------------------
`default_nettype none

module axis_upsizer #(
  parameter int unsigned DW_IN = 8,
  parameter int unsigned RATIO = 4,
  parameter int unsigned DW_OUT = DW_IN * RATIO
) (
  input  var logic               clk,
  input  var logic               rst_n,

  input  var logic [DW_IN-1:0]   s_tdata,
  input  var logic               s_tvalid,
  output var logic               s_tready,
  input  var logic               s_tlast,

  output var logic [DW_OUT-1:0]  m_tdata,
  output var logic [RATIO-1:0]   m_tkeep,   // one bit per input-width lane
  output var logic               m_tvalid,
  input  var logic               m_tready,
  output var logic               m_tlast
);

  if (RATIO < 2) begin : g_chk
    $error("axis_upsizer: RATIO must be >= 2");
  end

  localparam int unsigned LW = $clog2(RATIO);

  logic [DW_OUT-1:0] acc;
  logic [RATIO-1:0]  keep;
  logic [LW-1:0]     lane;
  logic              accept, flush;

  // Accept while the output register is free or is being emptied this cycle.
  assign s_tready = !m_tvalid || m_tready;
  assign accept   = s_tvalid && s_tready;

  // Emit when the group is full, or early because the packet ended.
  assign flush = accept && ((lane == LW'(RATIO - 1)) || s_tlast);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc      <= '0;
      keep     <= '0;
      lane     <= '0;
      m_tdata  <= '0;
      m_tkeep  <= '0;
      m_tvalid <= 1'b0;
      m_tlast  <= 1'b0;
    end else begin
      if (m_tvalid && m_tready) m_tvalid <= 1'b0;

      if (accept) begin
        if (flush) begin
          // Publish this beat's lane together with whatever was accumulated.
          m_tdata  <= acc | (DW_OUT'(s_tdata) << (lane * DW_IN));
          m_tkeep  <= keep | (RATIO'(1) << lane);
          m_tvalid <= 1'b1;
          m_tlast  <= s_tlast;
          // Start the next group empty, so a short group leaves no residue.
          acc  <= '0;
          keep <= '0;
          lane <= '0;
        end else begin
          acc  <= acc  | (DW_OUT'(s_tdata) << (lane * DW_IN));
          keep <= keep | (RATIO'(1) << lane);
          lane <= lane + 1'b1;
        end
      end
    end
  end

`ifdef FORMAL
  // ---- lane accounting -----------------------------------------------------
  // Every input beat contributes exactly one lane to exactly one output beat.
  // The identity that makes it inductive is
  //
  //     accepted - emitted  ==  lanes in the accumulator + lanes in flight
  //
  // and it lives here, beside the state it accounts for, for the same reason
  // the AXI4-Lite counters do: in a harness those counters are registers
  // induction may start anywhere, unrelated to `keep` and `m_tkeep`, so the
  // step case fails on states that cannot occur.
  //
  // Violating it in either direction is a real bug with a familiar name --
  // losing lanes drops the tail of a packet, inventing them pads it.
  logic [7:0]  f_n_in, f_n_out;
  logic [LW:0] f_acc_lanes, f_out_lanes;

  always_comb begin
    f_acc_lanes = '0;
    for (int i = 0; i < int'(RATIO); i++)
      if (keep[i]) f_acc_lanes = f_acc_lanes + 1'b1;
  end

  always_comb begin
    f_out_lanes = '0;
    if (m_tvalid)
      for (int i = 0; i < int'(RATIO); i++)
        if (m_tkeep[i]) f_out_lanes = f_out_lanes + 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_n_in  <= '0;
      f_n_out <= '0;
    end else begin
      if (s_tvalid && s_tready) f_n_in  <= f_n_in  + 8'd1;
      if (m_tvalid && m_tready) f_n_out <= f_n_out + 8'(f_out_lanes);
    end
  end

  always @* begin
    // `lane` and `keep` are separate registers, so induction is free to start
    // them inconsistent with each other -- and then the accounting below is
    // false for a state the design can never actually be in. These two say how
    // they are related: keep is filled contiguously from lane 0, and `lane` is
    // exactly how many bits are set. With them, the accounting is inductive in
    // one step; without them the step case fails and the proof reports UNKNOWN.
    f_keep_contig : assert ((keep & (keep + 1'b1)) == '0);
    f_lane_is_cnt : assert ((LW+1)'(lane) == f_acc_lanes);

    f_lane_acct : assert ((f_n_in - f_n_out) ==
                          (8'(f_acc_lanes) + 8'(f_out_lanes)));
    // A published word always carries at least one real lane.
    f_keep_nz   : assert (!m_tvalid || (|m_tkeep));
    // The accumulator never holds a full group -- a full group is published.
    f_acc_bound : assert (f_acc_lanes < (LW+1)'(RATIO));
  end
`endif

`ifndef SYNTHESIS
  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata)
                                          && $stable(m_tkeep)));

  // A full group must keep every lane; only a tlast group may be short.
  a_short_only_on_last: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !(&m_tkeep)) |-> m_tlast)
    else $error("axis_upsizer: a short word was emitted without TLAST");

  a_keep_nonzero: assert property (@(posedge clk) disable iff (!rst_n)
    m_tvalid |-> (|m_tkeep));
`endif

endmodule

`default_nettype wire
