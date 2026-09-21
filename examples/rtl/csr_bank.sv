// -----------------------------------------------------------------------------
// csr_bank.sv -- a control/status register bank behind a generic register port.
//
// Deliberately NOT tied to a bus. apb_slave.sv and axil_slave.sv both translate
// their protocol into the same four-signal register port below, and this module
// implements the register semantics once. That split is worth copying: bus
// protocol bugs and register-behaviour bugs are different bugs, they are found
// by different tests, and keeping them in one module guarantees you re-debug
// both every time either changes.
//
//   addr/wen/wdata/wstrb   write side, single cycle
//   addr/ren -> rdata      read side, combinational on addr
//   err                    address decoded to nothing, or a write to a RO reg
//
// THREE REGISTER BEHAVIOURS, which is nearly all of them in practice:
//
//   RW    software reads and writes; hardware reads.  Configuration.
//   RO    hardware writes; software reads.            Status, counters, IDs.
//   W1C   hardware SETS a bit; software clears it by WRITING A ONE to it.
//         Interrupt and error flags.
//
// W1C is the one that has to be got exactly right. A "read it, then write zero"
// clear loses every event that arrived in between; writing a one to the bit you
// just read clears only what you saw. And when hardware sets a bit in the same
// cycle software clears it, THE SET MUST WIN -- otherwise the event that
// arrived during the clear disappears, which is a lost interrupt that reproduces
// once a week.
//
// Address map: 0 .. N_RW-1 are RW, then N_RO read-only, then the W1C status
// register last.
// -----------------------------------------------------------------------------
`default_nettype none

module csr_bank #(
  parameter int unsigned DW   = 32,
  parameter int unsigned N_RW = 4,
  parameter int unsigned N_RO = 2,
  parameter int unsigned NREG = N_RW + N_RO + 1,
  parameter int unsigned AW   = (NREG <= 1) ? 1 : $clog2(NREG)
) (
  input  var logic                clk,
  input  var logic                rst_n,

  // Generic register port.
  input  var logic [AW-1:0]       addr,
  input  var logic                wen,
  input  var logic [DW-1:0]       wdata,
  input  var logic [DW/8-1:0]     wstrb,
  input  var logic                ren,
  output var logic [DW-1:0]       rdata,
  output var logic                err,

  // Hardware side.
  output var logic [N_RW*DW-1:0]  rw_q,        // configuration to the design
  input  var logic [N_RO*DW-1:0]  ro_d,        // status from the design
  input  var logic [DW-1:0]       status_set,  // hardware sets these bits
  output var logic [DW-1:0]       status_q
);

  localparam int unsigned NB      = DW / 8;
  localparam int unsigned A_RO    = N_RW;
  localparam int unsigned A_STAT  = N_RW + N_RO;

  logic [DW-1:0] rw_r [N_RW];
  logic          hit_rw, hit_ro, hit_stat;

  assign hit_rw   = (addr <  AW'(A_RO));
  assign hit_ro   = (addr >= AW'(A_RO))   && (addr < AW'(A_STAT));
  assign hit_stat = (addr == AW'(A_STAT));

  // A write to a read-only register is an error, not a silent no-op: silently
  // dropping it is how a driver bug survives to the field.
  assign err = (!hit_rw && !hit_ro && !hit_stat) || (wen && hit_ro);

  // ---- read: combinational on addr -----------------------------------------
  always_comb begin
    rdata = '0;                                   // default: unmapped reads 0
    if (hit_rw)        rdata = rw_r[addr];
    else if (hit_ro)   rdata = ro_d[(addr - AW'(A_RO)) * DW +: DW];
    else if (hit_stat) rdata = status_q;
  end

  // ---- write ---------------------------------------------------------------
  for (genvar r = 0; r < int'(N_RW); r++) begin : g_rw
    assign rw_q[r*DW +: DW] = rw_r[r];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < int'(N_RW); r++) rw_r[r] <= '0;
      status_q <= '0;
    end else begin
      // Byte strobes, applied per lane. The indexed part-select is the form
      // that maps onto a byte-write-enable rather than a read-modify-write.
      if (wen && hit_rw) begin
        for (int b = 0; b < int'(NB); b++)
          if (wstrb[b]) rw_r[addr][b*8 +: 8] <= wdata[b*8 +: 8];
      end

      // W1C, with SET beating CLEAR in the same cycle. Written as one
      // expression so the precedence is not an accident of statement order.
      if (wen && hit_stat) status_q <= (status_q & ~wdata) | status_set;
      else                 status_q <=  status_q          | status_set;
    end
  end

`ifndef SYNTHESIS
  a_set_wins: assert property (@(posedge clk) disable iff (!rst_n)
    (|status_set) |=> ((status_q & $past(status_set)) == $past(status_set)))
    else $error("csr_bank: a hardware-set status bit was lost to a clear");

  a_ro_write_errs: assert property (@(posedge clk) disable iff (!rst_n)
    (wen && hit_ro) |-> err);
`endif

endmodule

`default_nettype wire
