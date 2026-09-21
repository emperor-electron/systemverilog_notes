// -----------------------------------------------------------------------------
// axis_downsizer.sv -- AXI-Stream width converter, wide to narrow.
//
// One RATIO-lane input beat becomes RATIO output beats, lane 0 first. Lane
// order is the AXI-Stream convention: the least significant lane is the first
// byte on the wire, so it leaves first.
//
// The handshake rule that makes this composable is the one from docs/30:
// `s_tready` must not depend combinationally on `m_tready`, or two of these
// back to back form a combinational path the length of the chain. Here
// `s_tready` is a function of the hold register's occupancy only.
//
// TLAST travels with the LAST lane of the group, not with every lane. Asserting
// it on each output beat turns one packet into RATIO packets, which downstream
// will happily process and which is very hard to see in a waveform.
//
// TKEEP IS NOT OPTIONAL HERE. The first version of this module did not have it,
// and it could not round-trip a packet whose length was not a multiple of RATIO:
// the upsizer correctly emitted a short final word, and this module happily
// unpacked all RATIO lanes of it, padding the packet with zeros and putting
// TLAST one to three beats too late. A stream converter without TKEEP is only
// correct for packet lengths that happen to divide evenly, which is exactly the
// case a testbench sending round numbers of beats always hits.
//
// `s_tkeep` is expected to be CONTIGUOUS from lane 0, which is what a position
// stream means and what axis_upsizer produces. That restriction is asserted
// rather than assumed.
// -----------------------------------------------------------------------------
`default_nettype none

module axis_downsizer #(
  parameter int unsigned DW_OUT = 8,
  parameter int unsigned RATIO  = 4,
  parameter int unsigned DW_IN  = DW_OUT * RATIO
) (
  input  var logic              clk,
  input  var logic              rst_n,

  input  var logic [DW_IN-1:0]  s_tdata,
  input  var logic [RATIO-1:0]  s_tkeep,      // tie to '1 if every lane counts
  input  var logic              s_tvalid,
  output var logic              s_tready,
  input  var logic              s_tlast,

  output var logic [DW_OUT-1:0] m_tdata,
  output var logic              m_tvalid,
  input  var logic              m_tready,
  output var logic              m_tlast
);

  if (RATIO < 2) begin : g_chk
    $error("axis_downsizer: RATIO must be >= 2");
  end

  localparam int unsigned LW = $clog2(RATIO);

  logic [DW_IN-1:0] hold;
  logic [RATIO-1:0] hold_keep;
  logic             hold_valid, hold_last;
  logic [LW-1:0]    lane;
  logic [LW:0]      keep_cnt;
  logic             last_lane;

  // How many lanes of the held word are real. Contiguous from lane 0, so the
  // count is also one past the index of the final lane.
  always_comb begin
    keep_cnt = '0;
    for (int i = 0; i < int'(RATIO); i++)
      if (hold_keep[i]) keep_cnt = keep_cnt + 1'b1;
  end

  assign last_lane = ({1'b0, lane} == (keep_cnt - 1'b1));

  // Depends on the hold register alone -- never on m_tready.
  assign s_tready = !hold_valid;

  assign m_tvalid = hold_valid;
  assign m_tdata  = hold[lane * DW_OUT +: DW_OUT];
  assign m_tlast  = hold_last && last_lane;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hold       <= '0;
      hold_keep  <= '0;
      hold_valid <= 1'b0;
      hold_last  <= 1'b0;
      lane       <= '0;
    end else begin
      if (hold_valid && m_tready) begin
        if (last_lane) begin
          lane       <= '0;
          hold_valid <= 1'b0;          // group finished; take the next word
        end else begin
          lane <= lane + 1'b1;
        end
      end

      // Accepting a new word is written second so that a beat can be taken in
      // the same cycle the last lane leaves -- full throughput, no bubble.
      if (s_tvalid && s_tready) begin
        hold       <= s_tdata;
        hold_keep  <= s_tkeep;
        hold_last  <= s_tlast;
        hold_valid <= 1'b1;
        lane       <= '0;
      end
    end
  end

`ifndef SYNTHESIS
  // The contiguity restriction, stated as a check rather than a comment:
  // adding 1 to a contiguous-from-zero mask clears every kept bit at once.
  a_keep_contiguous: assert property (@(posedge clk) disable iff (!rst_n)
    (s_tvalid && s_tready) |-> ((s_tkeep & (s_tkeep + 1'b1)) == '0))
    else $error("axis_downsizer: TKEEP %b is not contiguous from lane 0",
                s_tkeep);

  a_keep_nonzero: assert property (@(posedge clk) disable iff (!rst_n)
    (s_tvalid && s_tready) |-> (|s_tkeep));

  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata)));

  a_tlast_once: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && m_tready && m_tlast) |=> !(m_tvalid && m_tlast) || !m_tvalid);
`endif

endmodule

`default_nettype wire
