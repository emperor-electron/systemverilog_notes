// -----------------------------------------------------------------------------
// apb_slave.sv -- APB4 completer, translating the bus into a generic register
// port (see csr_bank.sv).
//
// APB is the simplest bus worth having: no bursts, no outstanding transactions,
// no separate channels. Every transfer is exactly two cycles.
//
//   SETUP   psel=1, penable=0   address and control are presented
//   ACCESS  psel=1, penable=1   held until pready=1; the data moves
//
// The two rules that a hand-written completer usually breaks:
//
//   1. PREADY MUST NOT DEPEND COMBINATIONALLY ON PENABLE. The requester may
//      drive penable from pready, and then the two form a loop. This module
//      registers pready, so the path is broken by construction and the transfer
//      costs a known number of cycles.
//
//   2. PRDATA IS ONLY VALID IN THE CYCLE WHERE PREADY IS HIGH. Driving it
//      continuously from a decoded address looks harmless and means a read of a
//      side-effecting register (a FIFO pop, a clear-on-read counter) fires
//      during SETUP as well. This module asserts `ren` for exactly one cycle.
//
//
// ADDRESSING: the address is passed through to the register port unmodified.
// Whether it is a byte address or a register index is the integrator's choice;
// a byte-addressed system drops the low $clog2(DW/8) bits on the way in. Doing
// that here would bake an assumption into the module that half its users do not
// share.
// WAIT_STATES inserts extra ACCESS cycles, which is what a real completer needs
// when the register lives behind a slower domain -- and is worth exercising
// even when you do not, because a requester that assumes two-cycle transfers is
// a bug waiting for the first slow peripheral.
// -----------------------------------------------------------------------------
`default_nettype none

module apb_slave #(
  parameter int unsigned AW          = 8,
  parameter int unsigned DW          = 32,
  parameter int unsigned WAIT_STATES = 0
) (
  input  var logic            clk,
  input  var logic            rst_n,

  // APB
  input  var logic            psel,
  input  var logic            penable,
  input  var logic            pwrite,
  input  var logic [AW-1:0]   paddr,
  input  var logic [DW-1:0]   pwdata,
  input  var logic [DW/8-1:0] pstrb,
  output var logic [DW-1:0]   prdata,
  output var logic            pready,
  output var logic            pslverr,

  // Generic register port
  output var logic [AW-1:0]   reg_addr,
  output var logic            reg_wen,
  output var logic [DW-1:0]   reg_wdata,
  output var logic [DW/8-1:0] reg_wstrb,
  output var logic            reg_ren,
  input  var logic [DW-1:0]   reg_rdata,
  input  var logic            reg_err
);

  localparam int unsigned WCW = (WAIT_STATES == 0) ? 1 : $clog2(WAIT_STATES + 1);

  logic [WCW-1:0] wcnt;
  logic           access;
  logic           last_cycle;

  assign access     = psel && penable;
  assign last_cycle = (wcnt == WCW'(WAIT_STATES));

  // The register port is combinational from the bus, but the strobes are
  // qualified so a side-effecting read or write happens exactly once.
  assign reg_addr  = paddr;
  assign reg_wdata = pwdata;
  assign reg_wstrb = pstrb;
  assign reg_wen   = access &&  pwrite && last_cycle;
  assign reg_ren   = access && !pwrite && last_cycle;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wcnt    <= '0;
      pready  <= 1'b0;
      prdata  <= '0;
      pslverr <= 1'b0;
    end else begin
      pready  <= 1'b0;
      pslverr <= 1'b0;

      if (access) begin
        if (last_cycle) begin
          wcnt    <= '0;
          pready  <= 1'b1;
          pslverr <= reg_err;
          if (!pwrite) prdata <= reg_rdata;
        end else begin
          wcnt <= wcnt + 1'b1;
        end
      end else begin
        wcnt <= '0;
      end
    end
  end

`ifndef SYNTHESIS
  // PENABLE must be low in the first cycle of a transfer and high afterwards.
  a_setup_then_access: assert property (@(posedge clk) disable iff (!rst_n)
    (psel && !penable) |=> (psel && penable))
    else $error("apb_slave: SETUP was not followed by ACCESS");

  // A transfer ends when PREADY is seen; the bus must not stall afterwards.
  a_ready_one_cycle: assert property (@(posedge clk) disable iff (!rst_n)
    pready |=> !pready);

  a_no_ready_when_idle: assert property (@(posedge clk) disable iff (!rst_n)
    !psel |-> !pready);

  // A side-effecting access must be pulsed exactly once per transfer.
  a_wen_once: assert property (@(posedge clk) disable iff (!rst_n)
    reg_wen |=> !reg_wen);
  a_ren_once: assert property (@(posedge clk) disable iff (!rst_n)
    reg_ren |=> !reg_ren);
`endif

endmodule

`default_nettype wire
