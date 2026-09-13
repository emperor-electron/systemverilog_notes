// -----------------------------------------------------------------------------
// ram_sp_wf.sv -- single-port RAM, write-first.
//
// Getting a block RAM instead of a pile of flip-flops is entirely about
// matching the tool's template. The rules that actually matter:
//   * the memory array must be an UNPACKED array,
//   * the read must be inside a clocked block (for a synchronous RAM),
//   * no reset on the memory contents (block RAMs have no reset),
//   * one read address register, not a registered output of an async read.
// -----------------------------------------------------------------------------
`default_nettype none

// --- single-port RAM, write-first (write-through) ----------------------------

module ram_sp_wf #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 1024,
  parameter int unsigned AW    = $clog2(DEPTH)
) (
  input  var logic          clk,
  input  var logic          en,
  input  var logic          we,
  input  var logic [AW-1:0] addr,
  input  var logic [DW-1:0] din,
  output var logic [DW-1:0] dout
);
  logic [DW-1:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (en) begin
      if (we) begin
        mem[addr] <= din;
        dout      <= din;         // WRITE-FIRST: dout is the NEW data
      end else begin
        dout <= mem[addr];
      end
    end
  end
endmodule


// --- simple dual port: one write port, one read port, same clock -------------

`default_nettype wire
