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

`ifdef FORMAL
  // The obligation the whole crossing rests on.
  //
  // Only req and ack actually cross domains; `data_q` does not, and is read by
  // the destination on a clock edge that has no defined relationship to the
  // source clock at all. That is only safe because `data_q` is GUARANTEED
  // STABLE for the entire time `req_q` is asserted -- so whenever the
  // destination samples it, it samples a settled value.
  //
  // This is a source-domain property: it depends on nothing but the source
  // always_ff, so it can be proved here even though the crossing itself cannot
  // be (see docs/28 -- Yosys formal is single-clock). What it does NOT prove is
  // that the destination samples at the right moment; that is a timing
  // constraint, not a logic property.
  logic f_past = 1'b0;
  always @(posedge sclk) f_past <= 1'b1;

  always @(posedge sclk)
    if (f_past && srst_n && $past(srst_n) && $past(req_q) && req_q)
      f_data_stable : assert (data_q == $past(data_q));

  // And req is only raised on an accepted transfer, never spontaneously.
  always @(posedge sclk)
    if (f_past && srst_n && $past(srst_n) && !$past(req_q) && req_q)
      f_req_needs_xfer : assert ($past(s_valid) && $past(s_ready));
`endif

endmodule

`default_nettype wire
