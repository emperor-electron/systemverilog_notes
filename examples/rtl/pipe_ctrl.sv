// -----------------------------------------------------------------------------
// pipe_ctrl.sv -- valid propagation with stall and flush for a fixed-latency
// pipeline.
//
// A pipeline needs three things beyond the datapath registers:
//
//   VALID    a bit travelling with each beat saying "this slot holds real data".
//            Without it, the first N results out of an N-deep pipeline are
//            garbage, and nothing downstream can tell.
//   STALL    a global enable that freezes every stage at once. Freezing stages
//            independently is how data gets duplicated or dropped.
//   FLUSH    kill in-flight work (branch mispredict, abort, error). Flushing
//            clears the VALID bits only -- the datapath registers keep their
//            stale contents, which is fine because nothing will look at them.
//
// That last point is the one worth internalizing: flush and reset are cheap
// because they only have to touch the control path.
//
// See docs/21-pipelining.md.
// -----------------------------------------------------------------------------
`default_nettype none

module pipe_ctrl #(
  parameter int unsigned STAGES = 4
) (
  input  var logic                clk,
  input  var logic                rst_n,
  input  var logic                en,          // 1 = advance, 0 = stall
  input  var logic                flush,       // kill everything in flight
  input  var logic                valid_i,
  output var logic                valid_o,
  output var logic [STAGES-1:0]   valid_q,     // per-stage, for the datapath
  output var logic                busy         // anything in flight?
);

  if (STAGES == 0) begin : g_comb
    assign valid_o = valid_i;
    assign valid_q = '0;
    assign busy    = 1'b0;

  end else begin : g_pipe
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        valid_q <= '0;
      end else if (flush) begin
        // Flush wins over `en`: an aborted pipeline must clear even while
        // stalled, or the stale beats reappear when the stall lifts.
        valid_q <= '0;
      end else if (en) begin
        valid_q <= {valid_q[STAGES-2:0], valid_i};
      end
    end

    assign valid_o = valid_q[STAGES-1];
    assign busy    = |valid_q;
  end

`ifndef SYNTHESIS
  // A stalled pipeline must not advance.
  a_stall_holds: assert property (@(posedge clk) disable iff (!rst_n || flush)
    (!en) |=> $stable(valid_q))
    else $error("pipe_ctrl: valid advanced while stalled");

  // A flush must empty the pipeline in one cycle.
  a_flush_clears: assert property (@(posedge clk) disable iff (!rst_n)
    flush |=> (valid_q == '0))
    else $error("pipe_ctrl: flush did not clear the pipeline");
`endif

endmodule

`default_nettype wire
