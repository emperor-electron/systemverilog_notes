// -----------------------------------------------------------------------------
// spi_master.sv -- SPI master, all four modes, MSB or LSB first.
//
// SPI has no standard document, which is why "SPI mode" exists at all. The two
// parameters that matter:
//
//   CPOL  the level SCLK idles at.
//   CPHA  which of the two SCLK edges in a bit period is the SAMPLE edge.
//         0 = sample on the LEADING edge (the first one after CS asserts),
//         1 = sample on the TRAILING edge.
//
//   mode 0 = CPOL 0, CPHA 0      mode 2 = CPOL 1, CPHA 0
//   mode 1 = CPOL 0, CPHA 1      mode 3 = CPOL 1, CPHA 1
//
// The whole design follows from one rule: DATA CHANGES ON ONE EDGE AND IS
// SAMPLED ON THE OTHER. Whichever edge samples, the other shifts, and that is
// the only difference CPHA makes here -- `sample_edge` and `shift_edge` below
// simply swap.
//
// The consequence that trips people up is at the START of a transfer. With
// CPHA=0 the first bit must already be on MOSI *before* the first clock edge,
// because that edge samples it; so it is presented when CS asserts. With
// CPHA=1 the first bit is presented BY the first edge. That is why the load
// path differs between the two and the shift path does not.
//
// SCLK frequency is clk / (2 * CLK_DIV). CLK_DIV = 1 gives clk/2.
// -----------------------------------------------------------------------------
`default_nettype none

module spi_master #(
  parameter int unsigned DW         = 8,
  parameter int unsigned CLK_DIV    = 4,      // clk cycles per SCLK half period
  parameter bit          CPOL       = 1'b0,
  parameter bit          CPHA       = 1'b0,
  parameter bit          MSB_FIRST  = 1'b1
) (
  input  var logic          clk,
  input  var logic          rst_n,

  input  var logic          start,            // accepted when ready
  input  var logic [DW-1:0] tx_data,
  output var logic          ready,
  output var logic [DW-1:0] rx_data,
  output var logic          done,             // one cycle, rx_data valid

  output var logic          sclk,
  output var logic          mosi,
  input  var logic          miso,
  output var logic          cs_n
);

  if (CLK_DIV == 0) begin : g_chk
    $error("spi_master: CLK_DIV must be >= 1");
  end

  localparam int unsigned DIVW  = (CLK_DIV <= 1) ? 1 : $clog2(CLK_DIV);
  localparam int unsigned EDGEW = $clog2(2 * DW + 1);

  typedef enum logic [1:0] { S_IDLE, S_SETUP, S_XFER, S_HOLD } st_e;

  st_e             st;
  logic [DIVW-1:0] divcnt;
  logic [EDGEW-1:0] edge_idx;       // 0 .. 2*DW-1
  logic [DW-1:0]   tx_sh, rx_sh;
  logic            half_tick;
  logic            leading;
  logic            sample_edge, shift_edge;

  // Bit order is handled once, at the boundary, so the shifter below is always
  // MSB-first and there is only one shift direction in the design.
  function automatic logic [DW-1:0] maybe_rev(input logic [DW-1:0] x);
    for (int i = 0; i < int'(DW); i++)
      maybe_rev[i] = MSB_FIRST ? x[i] : x[DW-1-i];
  endfunction

  assign half_tick   = (divcnt == DIVW'(CLK_DIV - 1));
  assign leading     = ~edge_idx[0];          // even edges are leading edges
  assign sample_edge = half_tick && (CPHA ? ~leading :  leading);
  assign shift_edge  = half_tick && (CPHA ?  leading : ~leading);

  assign ready   = (st == S_IDLE);
  assign rx_data = maybe_rev(rx_sh);

  // Indexing a function call result directly (`maybe_rev(tx_data)[DW-1]`) is
  // legal SystemVerilog and is rejected by the Yosys frontend, so the reordered
  // word gets a name. It is a wire either way.
  logic [DW-1:0] tx_ord;
  assign tx_ord = maybe_rev(tx_data);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      divcnt   <= '0;
      edge_idx <= '0;
      tx_sh    <= '0;
      rx_sh    <= '0;
      sclk     <= CPOL;
      mosi     <= 1'b0;
      cs_n     <= 1'b1;
      done     <= 1'b0;
    end else begin
      done <= 1'b0;

      // The half-period divider runs in every state but IDLE, so the CS setup
      // and hold times are a half period each, for free.
      if (st == S_IDLE) divcnt <= '0;
      else              divcnt <= half_tick ? '0 : (divcnt + 1'b1);

      unique case (st)
        S_IDLE: begin
          sclk     <= CPOL;
          cs_n     <= 1'b1;
          edge_idx <= '0;
          if (start) begin
            cs_n <= 1'b0;
            st   <= S_SETUP;
            if (CPHA == 1'b0) begin
              // The first edge SAMPLES, so the first bit has to be out already.
              mosi  <= tx_ord[DW-1];
              tx_sh <= {tx_ord[DW-2:0], 1'b0};
            end else begin
              // The first edge SHIFTS, so it will present the first bit itself.
              tx_sh <= tx_ord;
            end
          end
        end

        // CS-to-first-edge setup: one half period with SCLK still idle.
        S_SETUP: if (half_tick) st <= S_XFER;

        S_XFER: begin
          if (sample_edge) rx_sh <= {rx_sh[DW-2:0], miso};
          if (shift_edge) begin
            mosi  <= tx_sh[DW-1];
            tx_sh <= {tx_sh[DW-2:0], 1'b0};
          end
          if (half_tick) begin
            sclk <= ~sclk;
            if (edge_idx == EDGEW'(2 * DW - 1)) st <= S_HOLD;
            else                                edge_idx <= edge_idx + 1'b1;
          end
        end

        // Last-edge-to-CS hold, then deassert and report.
        S_HOLD: begin
          sclk <= CPOL;
          if (half_tick) begin
            cs_n <= 1'b1;
            done <= 1'b1;
            st   <= S_IDLE;
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  a_sclk_idle: assert property (@(posedge clk) disable iff (!rst_n)
    cs_n |-> (sclk == CPOL))
    else $error("spi_master: SCLK not idle while CS is deasserted");

  a_done_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    done |=> !done);

  a_ready_idle: assert property (@(posedge clk) disable iff (!rst_n)
    ready |-> cs_n);
`endif

endmodule

`default_nettype wire
