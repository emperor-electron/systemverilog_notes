// -----------------------------------------------------------------------------
// skid_buffer_fv.sv -- formal harness for skid_buffer.
//
// Thin by necessity: the properties live inside the module (Yosys cannot read a
// hierarchical reference into a submodule -- see docs/25), so all this harness
// does is the two jobs that genuinely belong to the environment:
//
//   1. Give the solver a defined starting point. Without the reset assumption
//      it begins in a fabricated state and reports a counterexample that
//      cannot happen.
//   2. Constrain the UPSTREAM to obey the protocol. A source that withdraws
//      valid before the handshake completes violates AXI-Stream, and the buffer
//      is not required to cope. Omit this and the solver reports that "bug"
//      instead of looking for a real one.
// -----------------------------------------------------------------------------
`default_nettype none

module skid_buffer_fv #(
  parameter int unsigned DW = 4
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic in_valid,
  input  var logic out_ready
);

  // 1. Reset is asserted in cycle 0. After that rst_n is free, so
  //    reset-during-operation is explored too.
  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic [DW-1:0] in_data, out_data;
  logic          in_ready, out_valid;

  skid_buffer #(.DW(DW)) dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
    .out_valid(out_valid), .out_data(out_data), .out_ready(out_ready));

  // 2. Upstream protocol assumption.
  always @(posedge clk)
    if (rst_n && past_ok && $past(rst_n))
      if ($past(in_valid) && !$past(in_ready)) assume (in_valid);

endmodule

`default_nettype wire
