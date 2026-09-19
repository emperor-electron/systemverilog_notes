// -----------------------------------------------------------------------------
// ram_tdp.sv -- true dual-port RAM, two independent clocks.
//
// Getting a block RAM instead of a pile of flip-flops is entirely about
// matching the tool's template. The rules that actually matter:
//   * the memory array must be an UNPACKED array,
//   * the read must be inside a clocked block (for a synchronous RAM),
//   * no reset on the memory contents (block RAMs have no reset),
//   * one read address register, not a registered output of an async read.
// -----------------------------------------------------------------------------
`default_nettype none

// --- true dual port, two independent clocks ----------------------------------
module ram_tdp #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 1024,
  parameter int unsigned AW    = $clog2(DEPTH)
) (
  input  var logic          clk_a,
  input  var logic          en_a,
  input  var logic          we_a,
  input  var logic [AW-1:0] addr_a,
  input  var logic [DW-1:0] din_a,
  output var logic [DW-1:0] dout_a,

  input  var logic          clk_b,
  input  var logic          en_b,
  input  var logic          we_b,
  input  var logic [AW-1:0] addr_b,
  input  var logic [DW-1:0] din_b,
  output var logic [DW-1:0] dout_b
);
  // A true dual-port RAM is genuinely written from two different clock domains.
  // That is what the primitive does, so a multiple-driver warning is expected
  // here and only here. The pragma is Verilator's spelling, kept because it is
  // widely understood and harmless to other tools, which ignore unknown
  // comment pragmas.
  /* verilator lint_off MULTIDRIVEN */
  logic [DW-1:0] mem [0:DEPTH-1];
  /* verilator lint_on MULTIDRIVEN */

  always_ff @(posedge clk_a) begin
    if (en_a) begin
      if (we_a) mem[addr_a] <= din_a;
      dout_a <= mem[addr_a];
    end
  end

  always_ff @(posedge clk_b) begin
    if (en_b) begin
      if (we_b) mem[addr_b] <= din_b;
      dout_b <= mem[addr_b];
    end
  end
  // Writing the same address from both ports in the same cycle gives an
  // undefined result in the RAM primitive. Arbitrate above this level.
endmodule


// --- byte-enabled RAM --------------------------------------------------------
// The indexed part-select `mem[addr][i*8 +: 8]` is the idiomatic byte lane.

`default_nettype wire
