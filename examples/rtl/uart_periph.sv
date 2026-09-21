// -----------------------------------------------------------------------------
// uart_periph.sv -- a complete UART peripheral, assembled from modules that
// were each verified on their own.
//
// uart_tx + uart_rx + two sync_fifos + a small register map, presented on the
// same generic register port that apb_slave.sv, axil_slave.sv and wb_slave.sv
// all drive. Drop any of the three in front of it and the peripheral is on that
// bus; none of them knows anything about UARTs.
//
// This exists as an INTEGRATION example. Every part of it is already proved or
// tested elsewhere, so what is left to get wrong is the wiring -- and the
// wiring is where the interesting bug is:
//
//   READING THE DATA REGISTER POPS THE RX FIFO. That is a side-effecting read,
//   and it is why the bus slaves go to the trouble of pulsing `ren` for exactly
//   one cycle. A slave that drives `ren` from a decoded address for the whole
//   transfer pops the FIFO once per cycle of the ACCESS phase, and the received
//   bytes disappear in a pattern that depends on the bus's wait states. The
//   assertion below states the contract that protects against it.
//
//   FIFO FULL MUST DROP, NOT WRAP. A receiver with nowhere to put a byte has to
//   discard it and say so. Overwriting the FIFO would corrupt bytes the software
//   has not read yet, which turns a recoverable overrun into silent corruption.
//
// REGISTER MAP
//   0  DATA    W: push a byte to TX     R: pop a byte from RX (side-effecting)
//   1  STATUS  R: {rx_overrun, frame_err, rx_empty, rx_full, tx_empty, tx_full}
//   2  CTRL    RW: bit 0 clears the sticky error bits when written as one
// -----------------------------------------------------------------------------
`default_nettype none

module uart_periph #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned BAUD   = 115_200,
  parameter int unsigned DEPTH  = 16,
  parameter int unsigned AW     = 2,
  parameter int unsigned DW     = 32
) (
  input  var logic            clk,
  input  var logic            rst_n,

  // Generic register port (see csr_bank.sv)
  input  var logic [AW-1:0]   addr,
  input  var logic            wen,
  input  var logic [DW-1:0]   wdata,
  input  var logic [DW/8-1:0] wstrb,
  input  var logic            ren,
  output var logic [DW-1:0]   rdata,
  output var logic            err,

  // Pins
  input  var logic            rx,
  output var logic            tx,

  // To irq_ctrl
  output var logic            irq_rx_ready,
  output var logic            irq_tx_empty
);

  localparam logic [AW-1:0] A_DATA   = AW'(0);
  localparam logic [AW-1:0] A_STATUS = AW'(1);
  localparam logic [AW-1:0] A_CTRL   = AW'(2);

  // ---- TX path -------------------------------------------------------------
  logic       txf_wr, txf_rd, txf_full, txf_empty;
  logic [7:0] txf_dout;
  logic       tx_ready;

  assign txf_wr = wen && (addr == A_DATA) && !txf_full;
  assign txf_rd = tx_ready && !txf_empty;

  sync_fifo #(.DW(8), .DEPTH(DEPTH), .FWFT(1'b1)) u_txf (
    .clk, .rst_n,
    .wr_en(txf_wr), .wr_data(wdata[7:0]), .full(txf_full), .almost_full(),
    .rd_en(txf_rd), .rd_data(txf_dout), .empty(txf_empty), .almost_empty(),
    .level());

  uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .clk, .rst_n,
    .valid(!txf_empty), .data(txf_dout), .ready(tx_ready), .tx(tx));

  // ---- RX path -------------------------------------------------------------
  logic       rx_valid, rx_frame_err;
  logic [7:0] rx_byte;
  logic       rxf_wr, rxf_rd, rxf_full, rxf_empty;
  logic [7:0] rxf_dout;

  uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
    .clk, .rst_n, .rx(rx),
    .valid(rx_valid), .data(rx_byte), .frame_err(rx_frame_err));

  // A byte with nowhere to go is DROPPED and recorded, never written over one
  // the software has not read.
  assign rxf_wr = rx_valid && !rxf_full;
  assign rxf_rd = ren && (addr == A_DATA) && !rxf_empty;

  sync_fifo #(.DW(8), .DEPTH(DEPTH), .FWFT(1'b1)) u_rxf (
    .clk, .rst_n,
    .wr_en(rxf_wr), .wr_data(rx_byte), .full(rxf_full), .almost_full(),
    .rd_en(rxf_rd), .rd_data(rxf_dout), .empty(rxf_empty), .almost_empty(),
    .level());

  // ---- sticky error bits ---------------------------------------------------
  logic rx_overrun_q, frame_err_q;
  logic err_clr;

  assign err_clr = wen && (addr == A_CTRL) && wdata[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_overrun_q <= 1'b0;
      frame_err_q  <= 1'b0;
    end else begin
      // Set beats clear, as everywhere else in this repository: an error
      // arriving in the same cycle software clears the flag must survive.
      rx_overrun_q <= (rx_overrun_q && !err_clr) || (rx_valid && rxf_full);
      frame_err_q  <= (frame_err_q  && !err_clr) || rx_frame_err;
    end
  end

  // ---- register read -------------------------------------------------------
  always_comb begin
    rdata = '0;
    err   = 1'b0;
    unique case (addr)
      A_DATA:   rdata = DW'(rxf_dout);
      A_STATUS: rdata = DW'({rx_overrun_q, frame_err_q,
                             rxf_empty, rxf_full, txf_empty, txf_full});
      A_CTRL:   rdata = '0;
      default:  err   = 1'b1;
    endcase
  end

  assign irq_rx_ready = !rxf_empty;
  assign irq_tx_empty =  txf_empty;

`ifndef SYNTHESIS
  // The contract with the bus slave: a read strobe is one cycle. If this fires,
  // the bus slave in front of this peripheral is holding `ren` and eating bytes.
  a_ren_is_a_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    ren |=> !ren)
    else $error("uart_periph: ren held >1 cycle; the RX FIFO is being popped repeatedly by one bus read");

  a_no_pop_when_empty: assert property (@(posedge clk) disable iff (!rst_n)
    rxf_rd |-> !rxf_empty);

  a_no_push_when_full: assert property (@(posedge clk) disable iff (!rst_n)
    rxf_wr |-> !rxf_full);

  a_overrun_recorded: assert property (@(posedge clk) disable iff (!rst_n)
    (rx_valid && rxf_full) |=> rx_overrun_q)
    else $error("uart_periph: a byte was dropped without recording an overrun");
`endif

endmodule

`default_nettype wire
