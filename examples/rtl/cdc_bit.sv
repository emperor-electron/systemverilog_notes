// -----------------------------------------------------------------------------
// cdc_bit.sv
//
// One of the three single-signal clock-domain-crossing primitives:
//   cdc_bit       : 2-flop synchronizer for a LEVEL. The signal must be stable
//                   for at least 2 destination clock edges (no fast pulses).
//   cdc_pulse     : toggle-based pulse crossing. A single-cycle pulse in the
//                   source domain becomes a single-cycle pulse in the
//                   destination domain. Source pulses must be spaced further
//                   apart than the synchronizer latency.
//   cdc_handshake : full 4-phase handshake for a multi-bit BUS. The source
//                   holds the data stable while the request is outstanding,
//                   so only the 1-bit req/ack signals actually cross.
//
// NEVER put a 2-flop synchronizer on each bit of a bus: the bits resolve on
// different cycles and the receiver sees values that were never sent.
// -----------------------------------------------------------------------------
`default_nettype none

// --- level synchronizer ------------------------------------------------------
module cdc_bit #(
  parameter int unsigned STAGES = 2,
  parameter bit          INIT   = 1'b0
) (
  input  var logic dclk,
  input  var logic drst_n,
  input  var logic d,          // asynchronous input
  output var logic q           // synchronized to dclk
);
  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

  always_ff @(posedge dclk or negedge drst_n) begin
    if (!drst_n) sync_q <= {STAGES{INIT}};
    else         sync_q <= {sync_q[STAGES-2:0], d};
  end

  assign q = sync_q[STAGES-1];
endmodule

`default_nettype wire
