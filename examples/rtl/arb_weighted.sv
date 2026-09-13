// -----------------------------------------------------------------------------
// arb_weighted.sv -- weighted round-robin arbiter with per-agent credits.
//
// The round-robin arbiter uses the "masked priority" trick:
//   1. Build a mask that clears every requester at or below the last winner.
//   2. Run a plain fixed-priority arbiter on the masked requests.
//   3. If nothing survived the mask, run it again on the UNmasked requests
//      (that is the wrap-around).
// Two priority arbiters and a mux -- no rotation barrel shifter needed.
// -----------------------------------------------------------------------------
`default_nettype none

// --- weighted round robin (deficit counter) ----------------------------------
// Each requester gets WEIGHT[i] consecutive grants before the pointer moveson.
module arb_weighted #(
  parameter int unsigned N  = 4,
  parameter int unsigned CW = 4               // credit counter width
) (
  input  var logic            clk,
  input  var logic            rst_n,
  input  var logic [N-1:0]    req,
  input  var logic            update,
  input  var logic [CW-1:0]   weight [0:N-1],
  output var logic [N-1:0]    grant,
  output var logic            valid
);
  logic [CW-1:0] credit [0:N-1];
  logic [N-1:0]  eligible;
  logic          rr_update;

  // A requester is eligible while it still has credit.
  always_comb
    foreach (eligible[i]) eligible[i] = req[i] && (credit[i] != '0);

  // If nobody has credit left, refill everyone (a new "round").
  logic refill;
  assign refill = (eligible == '0) && (|req);

  arb_round_robin #(.N(N)) u_rr (
    .clk    (clk),
    .rst_n  (rst_n),
    .req    (refill ? req : eligible),
    .update (rr_update),
    .grant  (grant),
    .valid  (valid)
  );

  // Move the round-robin pointer only when the winner runs out of credit.
  always_comb begin
    rr_update = 1'b0;
    foreach (grant[i])
      if (grant[i] && update && (credit[i] <= CW'(1))) rr_update = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      foreach (credit[i]) credit[i] <= '0;
    end else if (refill) begin
      foreach (credit[i]) credit[i] <= weight[i];
    end else if (update) begin
      foreach (grant[i])
        if (grant[i] && (credit[i] != '0)) credit[i] <= credit[i] - 1'b1;
    end
  end
endmodule

`default_nettype wire
