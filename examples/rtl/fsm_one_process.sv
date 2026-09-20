// -----------------------------------------------------------------------------
// fsm_one_process.sv -- FSM, one-process style (everything registered).
// The controller: wait for `start`, request a bus, wait for `grant`, transfer
// `len` beats, then pulse `done`.
// -----------------------------------------------------------------------------
`default_nettype none

// =============================================================================
// Style 2: ONE PROCESS -- everything registered. Outputs are glitch-free and
// arrive one cycle after the decision. Shorter timing paths.
// =============================================================================
module fsm_one_process #(
  parameter int unsigned CW = 8
) (
  input  var logic           clk,
  input  var logic           rst_n,
  input  var logic           start,
  input  var logic [CW-1:0]  len,
  input  var logic           grant,
  input  var logic           beat_ack,
  output var logic           bus_req,
  output var logic           beat_valid,
  output var logic           done
);

  typedef enum logic [2:0] { S_IDLE, S_REQ, S_XFER, S_DONE } state_e;

  state_e        state;
  logic [CW-1:0] cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      cnt        <= '0;
      bus_req    <= 1'b0;
      beat_valid <= 1'b0;
      done       <= 1'b0;
    end else begin
      done <= 1'b0;                 // default each cycle: a one-cycle pulse

      unique case (state)
        S_IDLE: begin
          if (start) begin
            state   <= S_REQ;
            cnt     <= len;
            bus_req <= 1'b1;
          end
        end
        S_REQ: begin
          if (grant) begin
            state      <= S_XFER;
            beat_valid <= 1'b1;
          end
        end
        S_XFER: begin
          if (beat_ack) begin
            cnt <= cnt - 1'b1;
            if (cnt <= CW'(1)) begin
              state      <= S_DONE;
              beat_valid <= 1'b0;
              bus_req    <= 1'b0;
              done       <= 1'b1;
            end
          end
        end
        S_DONE: begin
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
