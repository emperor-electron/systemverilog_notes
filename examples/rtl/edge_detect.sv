// -----------------------------------------------------------------------------
// edge_detect.sv -- rising / falling / any edge of a synchronous signal.
//
// Trivial, and worth having as a module anyway: written inline it is one of the
// most frequently mis-signed lines in RTL (`~d & d_q` versus `d & ~d_q`), and
// the registered copy tends to get reused for something else and then drift.
//
// THE INPUT MUST ALREADY BE IN THIS CLOCK DOMAIN. Feeding a raw asynchronous
// pin here produces edges that do not exist: the flop can go metastable and the
// XOR sees a transition that never happened. Put a cdc_bit in front of it --
// see docs/28.
//
// INIT sets the reset value of the delayed copy, which decides whether a signal
// that is already high at reset release produces a rising edge. INIT=0 (the
// default) means it does; INIT=1 means it does not. Neither is universally
// right, which is why it is a parameter rather than a decision made for you.
// -----------------------------------------------------------------------------
`default_nettype none

module edge_detect #(
  parameter bit INIT = 1'b0
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic d,
  output var logic rise,
  output var logic fall,
  output var logic any
);

  logic d_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) d_q <= INIT;
    else        d_q <= d;
  end

  assign rise = d & ~d_q;
  assign fall = ~d & d_q;
  assign any  = d ^ d_q;

endmodule

`default_nettype wire
