// -----------------------------------------------------------------------------
// cdc_pulse.sv -- toggle-based pulse synchronizer.
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

// --- pulse synchronizer (toggle method) --------------------------------------
module cdc_pulse (
  input  var logic sclk,
  input  var logic srst_n,
  input  var logic s_pulse,     // one sclk cycle wide
  input  var logic dclk,
  input  var logic drst_n,
  output var logic d_pulse      // one dclk cycle wide
);
  logic toggle_q;
  logic sync_q, sync_q2;

  // Source: flip a level on every input pulse. A level crosses safely.
  always_ff @(posedge sclk or negedge srst_n) begin
    if (!srst_n)      toggle_q <= 1'b0;
    else if (s_pulse) toggle_q <= ~toggle_q;
  end

  cdc_bit #(.STAGES(2)) u_sync (
    .dclk   (dclk),
    .drst_n (drst_n),
    .d      (toggle_q),
    .q      (sync_q)
  );

  // Destination: an edge on the synchronized level is a pulse.
  always_ff @(posedge dclk or negedge drst_n) begin
    if (!drst_n) sync_q2 <= 1'b0;
    else         sync_q2 <= sync_q;
  end

  assign d_pulse = sync_q ^ sync_q2;
endmodule

`default_nettype wire
