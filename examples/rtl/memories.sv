// -----------------------------------------------------------------------------
// memories.sv -- the RAM inference templates that synthesis tools recognize.
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
  // A true dual-port RAM is genuinely written from two different clock
  // domains. That is what the primitive does, so the multiple-driver warning
  // is expected here and only here.
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
