// -----------------------------------------------------------------------------
// arb_round_robin.sv -- round-robin arbiter built from two priority arbiters.
//
// The round-robin arbiter uses the "masked priority" trick:
//   1. Build a mask that clears every requester at or below the last winner.
//   2. Run a plain fixed-priority arbiter on the masked requests.
//   3. If nothing survived the mask, run it again on the UNmasked requests
//      (that is the wrap-around).
// Two priority arbiters and a mux -- no rotation barrel shifter needed.
// -----------------------------------------------------------------------------
`default_nettype none

// --- round robin -------------------------------------------------------------
module arb_round_robin #(
  parameter int unsigned N = 8
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic [N-1:0] req,
  input  var logic         update,    // advance the priority pointer
  output var logic [N-1:0] grant,
  output var logic         valid
);

  logic [N-1:0] mask;        // 1 for requesters with priority over the pointer
  logic [N-1:0] masked_req;
  logic [N-1:0] grant_masked, grant_unmasked;

  assign masked_req = req & mask;

  arb_fixed #(.N(N)) u_hi (.req(masked_req), .grant(grant_masked));
  arb_fixed #(.N(N)) u_lo (.req(req),        .grant(grant_unmasked));

  // Prefer a winner above the pointer; wrap around if there is none.
  assign grant = (|masked_req) ? grant_masked : grant_unmasked;
  assign valid = |req;

  // The next mask keeps everything STRICTLY above this winner. For a one-hot
  // grant g, ~((g - 1) | g) is exactly "bits above the set bit".
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                  mask <= '1;
    else if (update && valid)    mask <= ~((grant - 1'b1) | grant);
  end

`ifndef SYNTHESIS
  a_onehot:   assert property (@(posedge clk) disable iff (!rst_n)
                               $onehot0(grant));
  a_only_req: assert property (@(posedge clk) disable iff (!rst_n)
                               (grant & ~req) == '0);
  a_grant_if_req: assert property (@(posedge clk) disable iff (!rst_n)
                                   (|req) |-> (|grant));
`endif

endmodule


// --- weighted round robin (deficit counter) ----------------------------------
// Each requester gets WEIGHT[i] consecutive grants before the pointer moves on.

`default_nettype wire
