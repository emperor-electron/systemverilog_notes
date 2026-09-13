// -----------------------------------------------------------------------------
// regfile.sv -- register file: 2 async read ports, 1 write port.
//
// Getting a block RAM instead of a pile of flip-flops is entirely about
// matching the tool's template. The rules that actually matter:
//   * the memory array must be an UNPACKED array,
//   * the read must be inside a clocked block (for a synchronous RAM),
//   * no reset on the memory contents (block RAMs have no reset),
//   * one read address register, not a registered output of an async read.
// -----------------------------------------------------------------------------
`default_nettype none

// --- register file: 2 read ports, 1 write port, async read -------------------
// Async read means flops or distributed RAM, not a block RAM. That is the
// right choice for a small, latency-critical register file.
module regfile #(
  parameter int unsigned DW = 32,
  parameter int unsigned N  = 32,
  parameter int unsigned AW = $clog2(N),
  parameter bit          ZERO_REG = 1'b1      // R0 reads as zero (RISC-V)
) (
  input  var logic          clk,
  input  var logic          rst_n,
  input  var logic          we,
  input  var logic [AW-1:0] waddr,
  input  var logic [DW-1:0] wdata,
  input  var logic [AW-1:0] raddr0,
  output var logic [DW-1:0] rdata0,
  input  var logic [AW-1:0] raddr1,
  output var logic [DW-1:0] rdata1
);
  logic [DW-1:0] regs [0:N-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      foreach (regs[i]) regs[i] <= '0;
    end else if (we && !(ZERO_REG && (waddr == '0))) begin
      regs[waddr] <= wdata;
    end
  end

  // Write-through bypass: a read in the same cycle as a write to the same
  // address returns the NEW value. Without this a pipeline needs a forwarding
  // path one stage later.
  always_comb begin
    rdata0 = (ZERO_REG && raddr0 == '0)          ? '0     :
             (we && (waddr == raddr0))           ? wdata  : regs[raddr0];
    rdata1 = (ZERO_REG && raddr1 == '0)          ? '0     :
             (we && (waddr == raddr1))           ? wdata  : regs[raddr1];
  end
endmodule

`default_nettype wire
