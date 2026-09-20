// -----------------------------------------------------------------------------
// cdc_handshake_fv.sv -- the source-side obligation behind the CDC.
//
// WHAT THIS PROOF DOES AND DOES NOT COVER, precisely, because a CDC proof that
// oversells itself is worse than none.
//
// Yosys formal is single-clock. `prep` flattens a design to one transition
// relation stepped by one clock, so a genuine two-clock crossing -- where the
// whole question is what happens when edges land arbitrarily close together --
// is outside what this flow can express. Tying sclk and dclk together, as this
// harness does, removes exactly the phenomenon a CDC proof would be about.
//
// So this does NOT prove the crossing is safe. Metastability settling, MTBF and
// sample timing are electrical properties handled by ASYNC_REG, a
// set_max_delay -datapath_only constraint and a CDC linter -- not by logic
// proofs.
//
// What it DOES prove is the design rule the crossing depends on, which is a
// pure source-domain logic property: `data_q` never changes while `req_q` is
// asserted. That is what makes it legal for only req/ack to cross while the
// data bus does not. If it were false, no amount of correct synchroniser
// structure would save the design -- the destination would latch a value that
// was mid-change.
//
// The property itself lives inside cdc_handshake.sv because `data_q` and
// `req_q` are internal, and a hierarchical reference from here would silently
// read the wrong net (docs/25).
// -----------------------------------------------------------------------------
`default_nettype none

module cdc_handshake_fv #(
  parameter int unsigned DW = 4
) (
  input  var logic          clk,
  input  var logic          rst_n,
  input  var logic          s_valid,
  input  var logic [DW-1:0] s_data
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic          s_ready, d_valid;
  logic [DW-1:0] d_data;

  // Both domains on one clock: see the header. This makes the handshake
  // degenerate, which is fine -- the property being proved is source-side only.
  cdc_handshake #(.DW(DW)) dut (
    .sclk(clk), .srst_n(rst_n), .s_valid(s_valid), .s_data(s_data),
    .s_ready(s_ready),
    .dclk(clk), .drst_n(rst_n), .d_valid(d_valid), .d_data(d_data));

  // The handshake must not offer ready while a request is still outstanding,
  // or the source could overwrite data the destination has not taken.
  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(s_valid) && $past(s_ready))
      f_ready_drops : assert (!s_ready);

  always @(posedge clk) begin
    f_c_accept   : cover (rst_n && s_valid && s_ready);
    f_c_delivered: cover (rst_n && d_valid);
  end

endmodule

`default_nettype wire
