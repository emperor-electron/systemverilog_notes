// -----------------------------------------------------------------------------
// wb_slave.sv -- Wishbone B4 classic slave, onto the generic register port.
//
// Wishbone classic is a single-cycle handshake: the master raises CYC and STB
// together and holds them until the slave answers with ACK, ERR or RTY. There
// are no separate channels and no pipelining, which makes it the least
// ceremonious of the three bus slaves here (see apb_slave.sv, axil_slave.sv).
//
// THE TWO THINGS THAT GO WRONG:
//
//   CYC vs STB. CYC means "a bus cycle is in progress"; STB means "this
//      particular transfer is valid now". A slave must qualify on BOTH. Looking
//      at STB alone responds to transfers aimed at a different slave during the
//      same cycle, which on a shared bus corrupts someone else's read.
//
//   ACK MUST BE A SINGLE CYCLE and must not be combinational from STB. A
//      combinational ACK works between two modules and oscillates the moment a
//      master drives STB from ACK. This one registers ACK, so a transfer takes
//      two cycles and the path is broken by construction -- the same reasoning
//      as PREADY in apb_slave.sv.
//
// ADDRESSING: as with the other two slaves, the address is passed through
// unmodified; a byte-addressed system drops the low bits on the way in.
// -----------------------------------------------------------------------------
`default_nettype none

module wb_slave #(
  parameter int unsigned AW = 8,
  parameter int unsigned DW = 32
) (
  input  var logic            clk,
  input  var logic            rst_n,

  // Wishbone B4 classic
  input  var logic            wb_cyc_i,
  input  var logic            wb_stb_i,
  input  var logic            wb_we_i,
  input  var logic [AW-1:0]   wb_adr_i,
  input  var logic [DW-1:0]   wb_dat_i,
  input  var logic [DW/8-1:0] wb_sel_i,
  output var logic [DW-1:0]   wb_dat_o,
  output var logic            wb_ack_o,
  output var logic            wb_err_o,

  // Generic register port
  output var logic [AW-1:0]   reg_addr,
  output var logic            reg_wen,
  output var logic [DW-1:0]   reg_wdata,
  output var logic [DW/8-1:0] reg_wstrb,
  output var logic            reg_ren,
  input  var logic [DW-1:0]   reg_rdata,
  input  var logic            reg_err
);

  logic active, responded;

  // Both, always. STB alone answers transfers meant for another slave.
  assign active = wb_cyc_i && wb_stb_i;

  assign reg_addr  = wb_adr_i;
  assign reg_wdata = wb_dat_i;
  assign reg_wstrb = wb_sel_i;

  // Strobe for exactly the one cycle that is not already being answered, so a
  // side-effecting register is accessed once per transfer.
  assign reg_wen = active &&  wb_we_i && !responded;
  assign reg_ren = active && !wb_we_i && !responded;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_ack_o  <= 1'b0;
      wb_err_o  <= 1'b0;
      wb_dat_o  <= '0;
      responded <= 1'b0;
    end else begin
      wb_ack_o <= 1'b0;
      wb_err_o <= 1'b0;

      if (active && !responded) begin
        responded <= 1'b1;
        if (reg_err) wb_err_o <= 1'b1;
        else         wb_ack_o <= 1'b1;
        if (!wb_we_i) wb_dat_o <= reg_rdata;
      end

      // The master drops STB (or CYC) once it has seen the response.
      if (!active) responded <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  a_ack_one_cycle: assert property (@(posedge clk) disable iff (!rst_n)
    wb_ack_o |=> !wb_ack_o);

  a_ack_xor_err: assert property (@(posedge clk) disable iff (!rst_n)
    !(wb_ack_o && wb_err_o))
    else $error("wb_slave: ACK and ERR asserted together");

  a_no_response_when_idle: assert property (@(posedge clk) disable iff (!rst_n)
    !wb_cyc_i |-> (!wb_ack_o && !wb_err_o))
    else $error("wb_slave: responded outside a bus cycle");

  a_strobe_once: assert property (@(posedge clk) disable iff (!rst_n)
    (reg_wen || reg_ren) |=> !(reg_wen || reg_ren));
`endif

endmodule

`default_nettype wire
