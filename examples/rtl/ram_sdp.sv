// -----------------------------------------------------------------------------
// ram_sdp.sv -- simple dual-port RAM (one write port, one read port).
//
// Getting a block RAM instead of a pile of flip-flops is entirely about
// matching the tool's template. The rules that actually matter:
//   * the memory array must be an UNPACKED array,
//   * the read must be inside a clocked block (for a synchronous RAM),
//   * no reset on the memory contents (block RAMs have no reset),
//   * one read address register, not a registered output of an async read.
// -----------------------------------------------------------------------------
`default_nettype none

// --- simple dual port: one write port, one read port, same clock -------------
module ram_sdp #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 1024,
  parameter int unsigned AW    = $clog2(DEPTH)
) (
  input  var logic          clk,
  input  var logic          we,
  input  var logic [AW-1:0] waddr,
  input  var logic [DW-1:0] wdata,
  input  var logic          re,
  input  var logic [AW-1:0] raddr,
  output var logic [DW-1:0] rdata
);
  logic [DW-1:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    if (re) rdata      <= mem[raddr];
  end
  // Same-address read/write in the same cycle is UNDEFINED here (the tool
  // picks read-first or write-first per the RAM primitive). If you need a
  // guarantee, add an explicit bypass:
  //   assign rdata_out = (we && re && waddr == raddr) ? wdata_q : rdata;
endmodule

`default_nettype wire
