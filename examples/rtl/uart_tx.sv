// -----------------------------------------------------------------------------
// uart_tx.sv -- 8N1 UART transmitter.
//
// The receiver is the interesting half: it recovers the bit clock from the
// start-bit edge and samples each bit at its MIDPOINT by waiting half a bit
// period after the edge and then a full period per bit. That tolerates a
// baud-rate mismatch of roughly +/-5% over a 10-bit frame.
// -----------------------------------------------------------------------------
`default_nettype none


module uart_tx #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned BAUD   = 115_200,
  parameter int unsigned DIV    = CLK_HZ / BAUD,
  parameter int unsigned DW     = $clog2(DIV)
) (
  input  var logic       clk,
  input  var logic       rst_n,
  input  var logic       valid,
  input  var logic [7:0] data,
  output var logic       ready,
  output var logic       tx
);
  typedef enum logic [1:0] { T_IDLE, T_START, T_DATA, T_STOP } st_e;

  st_e            st;
  logic [DW-1:0]  div;
  logic [2:0]     bit_idx;
  logic [7:0]     sh;
  logic           tick;

  assign tick  = (div == DW'(DIV - 1));
  assign ready = (st == T_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st      <= T_IDLE;
      div     <= '0;
      bit_idx <= '0;
      sh      <= '0;
      tx      <= 1'b1;                    // line idles high
    end else begin
      div <= tick ? '0 : (div + 1'b1);

      unique case (st)
        T_IDLE: begin
          tx  <= 1'b1;
          div <= '0;
          if (valid) begin
            sh <= data;
            st <= T_START;
          end
        end
        T_START: begin
          tx <= 1'b0;                      // start bit
          if (tick) begin
            st      <= T_DATA;
            bit_idx <= '0;
          end
        end
        T_DATA: begin
          tx <= sh[0];                     // LSB first
          if (tick) begin
            sh <= {1'b0, sh[7:1]};
            if (bit_idx == 3'd7) st <= T_STOP;
            else                 bit_idx <= bit_idx + 1'b1;
          end
        end
        T_STOP: begin
          tx <= 1'b1;                      // stop bit
          if (tick) st <= T_IDLE;
        end
        default: st <= T_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
