// -----------------------------------------------------------------------------
// fsm_onehot.sv -- FSM, explicit one-hot encoding.
// one-hot-encoded variant.
//
// The controller: wait for `start`, request a bus, wait for `grant`, transfer
// `len` beats, then pulse `done`.
// -----------------------------------------------------------------------------
`default_nettype none

// =============================================================================
// Style 3: EXPLICIT ONE-HOT. Each state is one flop; the next-state logic for
// each is a small OR of the transitions INTO it. Fast on an FPGA (no decode),
// and `unique case (1'b1)` reads naturally.
// =============================================================================
module fsm_onehot (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic start,
  input  var logic grant,
  input  var logic last_beat,
  output var logic bus_req,
  output var logic done
);

  typedef enum logic [3:0] {
    S_IDLE = 4'b0001,
    S_REQ  = 4'b0010,
    S_XFER = 4'b0100,
    S_DONE = 4'b1000
  } state_e;

  state_e state, next;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= S_IDLE;
    else        state <= next;
  end

  always_comb begin
    next = state;
    // `unique case (1'b1)` over a one-hot vector is a parallel mux, not a
    // priority chain -- and the `unique` is checked at run time.
    unique case (1'b1)
      state[0]: if (start)     next = S_REQ;    // S_IDLE
      state[1]: if (grant)     next = S_XFER;   // S_REQ
      state[2]: if (last_beat) next = S_DONE;   // S_XFER
      state[3]:                next = S_IDLE;   // S_DONE
      default:                 next = S_IDLE;
    endcase
  end

  assign bus_req = state[1] | state[2];
  assign done    = state[3];

`ifndef SYNTHESIS
  a_onehot: assert property (@(posedge clk) disable iff (!rst_n)
                             $onehot(state))
    else $error("fsm_onehot: state %b is not one-hot", state);
`endif

endmodule

`default_nettype wire
