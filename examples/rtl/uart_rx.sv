// -----------------------------------------------------------------------------
// uart_rx.sv -- 8N1 UART receiver with mid-bit sampling.
//
// The receiver is the interesting half: it recovers the bit clock from the
// start-bit edge and samples each bit at its MIDPOINT by waiting half a bit
// period after the edge and then a full period per bit. That tolerates a
// baud-rate mismatch of roughly +/-5% over a 10-bit frame.
// -----------------------------------------------------------------------------
`default_nettype none


module uart_rx #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned BAUD   = 115_200,
  parameter int unsigned DIV    = CLK_HZ / BAUD,
  parameter int unsigned DW     = $clog2(DIV)
) (
  input  var logic       clk,
  input  var logic       rst_n,
  input  var logic       rx,               // asynchronous input
  output var logic       valid,            // one-cycle pulse
  output var logic [7:0] data,
  output var logic       frame_err
);
  typedef enum logic [1:0] { R_IDLE, R_START, R_DATA, R_STOP } st_e;

  st_e           st;
  logic [DW-1:0] div;
  logic [2:0]    bit_idx;
  logic [7:0]    sh;
  logic          rx_sync;

  // rx arrives from outside the chip: synchronize it before use.
  cdc_bit #(.STAGES(2), .INIT(1'b1)) u_sync (
    .dclk   (clk),
    .drst_n (rst_n),
    .d      (rx),
    .q      (rx_sync)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= R_IDLE;
      div       <= '0;
      bit_idx   <= '0;
      sh        <= '0;
      data      <= '0;
      valid     <= 1'b0;
      frame_err <= 1'b0;
    end else begin
      valid <= 1'b0;                        // default: a one-cycle pulse

      unique case (st)
        R_IDLE: begin
          div <= '0;
          if (!rx_sync) st <= R_START;      // falling edge = start bit
        end
        R_START: begin
          // Wait HALF a bit time, then check the line is still low. That both
          // rejects glitches and centres all subsequent sampling.
          if (div == DW'(DIV/2 - 1)) begin
            div <= '0;
            if (!rx_sync) begin
              st      <= R_DATA;
              bit_idx <= '0;
            end else begin
              st <= R_IDLE;                 // glitch, not a real start bit
            end
          end else begin
            div <= div + 1'b1;
          end
        end
        R_DATA: begin
          if (div == DW'(DIV - 1)) begin
            div <= '0;
            sh  <= {rx_sync, sh[7:1]};      // LSB first
            if (bit_idx == 3'd7) st <= R_STOP;
            else                 bit_idx <= bit_idx + 1'b1;
          end else begin
            div <= div + 1'b1;
          end
        end
        R_STOP: begin
          if (div == DW'(DIV - 1)) begin
            div       <= '0;
            st        <= R_IDLE;
            data      <= sh;
            valid     <= 1'b1;
            frame_err <= !rx_sync;          // stop bit must be high
          end else begin
            div <= div + 1'b1;
          end
        end
        default: st <= R_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
