// -----------------------------------------------------------------------------
// cdc_handshake.sv -- 4-phase handshake for a multi-bit CDC bus.
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

// --- 4-phase handshake for a multi-bit bus -----------------------------------
module cdc_handshake #(
  parameter int unsigned DW = 32
) (
  input  var logic           sclk,
  input  var logic           srst_n,
  input  var logic           s_valid,
  input  var logic [DW-1:0]  s_data,
  output var logic           s_ready,

  input  var logic           dclk,
  input  var logic           drst_n,
  output var logic           d_valid,
  output var logic [DW-1:0]  d_data
);
  logic          req_q;
  logic [DW-1:0] data_q;      // held stable while req is outstanding
  logic          ack_sync;    // ack, synchronized into the source domain
  logic          req_sync;    // req, synchronized into the destination domain
  logic          req_sync_q;
  logic          ack_q;

  // ---- source side ----------------------------------------------------------
  assign s_ready = !req_q && !ack_sync;

  always_ff @(posedge sclk or negedge srst_n) begin
    if (!srst_n) begin
      req_q  <= 1'b0;
      data_q <= '0;
    end else if (s_valid && s_ready) begin
      req_q  <= 1'b1;
      data_q <= s_data;             // stable from here until ack returns
    end else if (req_q && ack_sync) begin
      req_q  <= 1'b0;               // drop req once ack is seen
    end
  end

  cdc_bit u_ack_sync (.dclk(sclk), .drst_n(srst_n), .d(ack_q),  .q(ack_sync));
  cdc_bit u_req_sync (.dclk(dclk), .drst_n(drst_n), .d(req_q),  .q(req_sync));

  // ---- destination side -----------------------------------------------------
  always_ff @(posedge dclk or negedge drst_n) begin
    if (!drst_n) begin
      req_sync_q <= 1'b0;
      ack_q      <= 1'b0;
      d_valid    <= 1'b0;
      d_data     <= '0;
    end else begin
      req_sync_q <= req_sync;
      d_valid    <= req_sync && !req_sync_q;     // rising edge of req
      if (req_sync && !req_sync_q) d_data <= data_q;   // safe: stable by now
      ack_q      <= req_sync;                    // 4-phase: follow req
    end
  end
endmodule

`default_nettype wire
