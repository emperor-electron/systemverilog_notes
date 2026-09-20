// -----------------------------------------------------------------------------
// ram_be.sv -- byte-enabled RAM.
//
// Getting a block RAM instead of a pile of flip-flops is entirely about
// matching the tool's template. The rules that actually matter:
//   * the memory array must be an UNPACKED array,
//   * the read must be inside a clocked block (for a synchronous RAM),
//   * no reset on the memory contents (block RAMs have no reset),
//   * one read address register, not a registered output of an async read.
// -----------------------------------------------------------------------------
`default_nettype none

// --- byte-enabled RAM --------------------------------------------------------
// The indexed part-select `mem[addr][i*8 +: 8]` is the idiomatic byte lane.
module ram_be #(
  parameter int unsigned BYTES = 4,
  parameter int unsigned DEPTH = 1024,
  parameter int unsigned DW    = BYTES * 8,
  parameter int unsigned AW    = $clog2(DEPTH)
) (
  input  var logic             clk,
  input  var logic             en,
  input  var logic [BYTES-1:0] be,
  input  var logic [AW-1:0]    addr,
  input  var logic [DW-1:0]    din,
  output var logic [DW-1:0]    dout
);
  logic [DW-1:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (en) begin
      foreach (be[i])
        if (be[i]) mem[addr][i*8 +: 8] <= din[i*8 +: 8];
      dout <= mem[addr];
    end
  end
endmodule

`default_nettype wire
