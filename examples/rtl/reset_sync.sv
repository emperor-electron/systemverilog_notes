// -----------------------------------------------------------------------------
// reset_sync.sv -- asynchronous assert, synchronous release reset synchronizer.
//
// The problem it solves: an async reset that is RELEASED asynchronously lets
// flops at different points in the reset tree leave reset on different clock
// cycles, because the release edge can violate recovery/removal time at some
// flops and not others. The design then starts from an inconsistent state.
//
// The fix: assert asynchronously (so reset works with no clock), but shift the
// release through two flops clocked by the destination clock so that every
// consumer sees the same release edge, safely away from the clock edge.
// -----------------------------------------------------------------------------
`default_nettype none

module reset_sync #(
  parameter int unsigned STAGES = 2
) (
  input  var logic clk,
  input  var logic arst_n,      // asynchronous, active low, from a pin or PLL
  output var logic rst_n        // synchronized to clk
);

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) sync_q <= '0;                       // async assert
    else         sync_q <= {sync_q[STAGES-2:0], 1'b1};  // sync release
  end

  assign rst_n = sync_q[STAGES-1];

endmodule

`default_nettype wire
