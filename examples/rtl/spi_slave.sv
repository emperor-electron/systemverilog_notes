// -----------------------------------------------------------------------------
// spi_slave.sv -- SPI slave, oversampled in the system clock domain.
//
// The textbook slave clocks its shift register directly on SCLK:
//
//     always_ff @(posedge sclk) sh <= {sh[DW-2:0], mosi};   // DON'T
//
// It is shorter and it is a bad idea on an FPGA. SCLK comes from a pin, so that
// makes a pin into a clock: it needs a clock tree and a clock-capable input, it
// is a second clock domain that stops whenever the master stops, every signal
// crossing back to the system domain is now a CDC, and it does not exist during
// scan. Worse, SCLK arrives with whatever ringing the board gives it, and a
// clock input has no noise margin -- one glitch is one extra bit.
//
// This version treats SCLK, MOSI and CS_N as what they are: asynchronous inputs.
// They are synchronized, edge-detected, and everything runs on the system clock.
// The design has ONE clock domain, works under scan, and a glitch on SCLK has to
// survive two flops to be believed.
//
// The cost is a sampling-rate requirement: the system clock must be fast enough
// to see every SCLK edge as a separate event. Allow at least 4 clk cycles per
// SCLK half period -- so clk >= 8 x SCLK -- and more if the board is noisy.
//
// CPOL and CPHA mean exactly what they do in spi_master.sv, and both ends sample
// on the SAME edge; they shift on the other one.
// -----------------------------------------------------------------------------
`default_nettype none

module spi_slave #(
  parameter int unsigned DW        = 8,
  parameter bit          CPOL      = 1'b0,
  parameter bit          CPHA      = 1'b0,
  parameter bit          MSB_FIRST = 1'b1
) (
  input  var logic          clk,
  input  var logic          rst_n,

  // Asynchronous pins. Synchronized inside; do not synchronize them again.
  input  var logic          sclk,
  input  var logic          mosi,
  input  var logic          cs_n,
  output var logic          miso,
  output var logic          miso_oe,    // 1 = drive MISO (CS is asserted)

  input  var logic [DW-1:0] tx_data,    // sampled when CS asserts
  output var logic [DW-1:0] rx_data,
  output var logic          rx_valid    // one cycle: a full word arrived
);

  localparam int unsigned BCW = $clog2(DW + 1);

  logic sclk_s, mosi_s, cs_n_s;

  cdc_bit #(.STAGES(2), .INIT(CPOL)) u_sync_sclk (
    .dclk(clk), .drst_n(rst_n), .d(sclk),  .q(sclk_s));
  cdc_bit #(.STAGES(2), .INIT(1'b0)) u_sync_mosi (
    .dclk(clk), .drst_n(rst_n), .d(mosi),  .q(mosi_s));
  cdc_bit #(.STAGES(2), .INIT(1'b1)) u_sync_cs (
    .dclk(clk), .drst_n(rst_n), .d(cs_n),  .q(cs_n_s));

  logic sclk_rise, sclk_fall, cs_assert;

  edge_detect #(.INIT(CPOL)) u_ed_sclk (
    .clk, .rst_n, .d(sclk_s), .rise(sclk_rise), .fall(sclk_fall), .any());
  edge_detect #(.INIT(1'b1)) u_ed_cs (
    .clk, .rst_n, .d(cs_n_s), .rise(), .fall(cs_assert), .any());

  // "Leading" is the edge that moves SCLK away from its idle level.
  logic leading_tick, trailing_tick, sample_tick, shift_tick;

  assign leading_tick  = CPOL ? sclk_fall : sclk_rise;
  assign trailing_tick = CPOL ? sclk_rise : sclk_fall;
  assign sample_tick   = !cs_n_s && (CPHA ? trailing_tick : leading_tick);
  assign shift_tick    = !cs_n_s && (CPHA ? leading_tick  : trailing_tick);

  function automatic logic [DW-1:0] maybe_rev(input logic [DW-1:0] x);
    for (int i = 0; i < int'(DW); i++)
      maybe_rev[i] = MSB_FIRST ? x[i] : x[DW-1-i];
  endfunction

  logic [DW-1:0]  tx_sh, rx_sh;
  logic [BCW-1:0] bitcnt;
  logic [DW-1:0]  tx_ord;

  assign tx_ord  = maybe_rev(tx_data);
  assign rx_data = maybe_rev(rx_sh);
  assign miso_oe = !cs_n_s;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_sh    <= '0;
      rx_sh    <= '0;
      bitcnt   <= '0;
      miso     <= 1'b0;
      rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;

      if (cs_assert) begin
        // Start of a transfer. With CPHA=0 the master samples on the very first
        // edge, so the first bit has to be on MISO before it arrives.
        bitcnt <= '0;
        rx_sh  <= '0;
        if (CPHA == 1'b0) begin
          miso  <= tx_ord[DW-1];
          tx_sh <= {tx_ord[DW-2:0], 1'b0};
        end else begin
          tx_sh <= tx_ord;
        end
      end else if (cs_n_s) begin
        bitcnt <= '0;
      end else begin
        if (shift_tick) begin
          miso  <= tx_sh[DW-1];
          tx_sh <= {tx_sh[DW-2:0], 1'b0};
        end
        if (sample_tick) begin
          rx_sh <= {rx_sh[DW-2:0], mosi_s};
          if (bitcnt == BCW'(DW - 1)) begin
            bitcnt   <= '0;
            rx_valid <= 1'b1;
          end else begin
            bitcnt <= bitcnt + 1'b1;
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  a_oe_follows_cs: assert property (@(posedge clk) disable iff (!rst_n)
    miso_oe == !cs_n_s);

  a_rx_valid_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    rx_valid |=> !rx_valid);
`endif

endmodule

`default_nettype wire
