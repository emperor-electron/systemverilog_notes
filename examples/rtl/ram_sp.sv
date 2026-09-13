// -----------------------------------------------------------------------------
// ram_sp.sv -- single-port RAM, read-first.
//
// Getting a block RAM instead of a pile of flip-flops is entirely about
// matching the tool's template. The rules that actually matter:
//   * the memory array must be an UNPACKED array,
//   * the read must be inside a clocked block (for a synchronous RAM),
//   * no reset on the memory contents (block RAMs have no reset),
//   * one read address register, not a registered output of an async read.
// -----------------------------------------------------------------------------
`default_nettype none

// --- single-port RAM, read-first ---------------------------------------------
module ram_sp #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 1024,
  parameter int unsigned AW    = $clog2(DEPTH),
  parameter string       INIT_FILE = ""
) (
  input  var logic          clk,
  input  var logic          en,
  input  var logic          we,
  input  var logic [AW-1:0] addr,
  input  var logic [DW-1:0] din,
  output var logic [DW-1:0] dout
);
  logic [DW-1:0] mem [0:DEPTH-1];

  if (INIT_FILE != "") begin : g_init
    initial $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk) begin
    if (en) begin
      if (we) mem[addr] <= din;
      dout <= mem[addr];          // READ-FIRST: dout is the OLD contents
    end
  end
endmodule


// --- single-port RAM, write-first (write-through) ----------------------------

`default_nettype wire
