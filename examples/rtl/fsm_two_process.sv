// -----------------------------------------------------------------------------
// fsm_two_process.sv -- FSM, two-process style (registered state, comb outputs).
// one-hot-encoded variant.
//
// The controller: wait for `start`, request a bus, wait for `grant`, transfer
// `len` beats, then pulse `done`.
// -----------------------------------------------------------------------------
`default_nettype none

// =============================================================================
// Style 1: TWO PROCESS -- registered state, combinational next-state and
// outputs. Outputs change in the same cycle as the state (Moore) or react
// combinationally to inputs (Mealy). Easiest to read; outputs can glitch.
// =============================================================================
module fsm_two_process #(
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

  typedef enum logic [2:0] {
    S_IDLE  = 3'd0,
    S_REQ   = 3'd1,
    S_XFER  = 3'd2,
    S_DONE  = 3'd3
  } state_e;

  state_e          state, next;
  logic [CW-1:0]   cnt, cnt_d;
  logic            last;

  assign last = (cnt <= CW'(1));

  // ---- state register ------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      cnt   <= '0;
    end else begin
      state <= next;
      cnt   <= cnt_d;
    end
  end

  // ---- next state ----------------------------------------------------------
  always_comb begin
    next  = state;          // DEFAULT: hold. This one line prevents latches.
    cnt_d = cnt;

    unique case (state)
      S_IDLE: if (start) begin
                next  = S_REQ;
                cnt_d = len;
              end
      S_REQ:  if (grant)  next = S_XFER;
      S_XFER: if (beat_ack) begin
                cnt_d = cnt - 1'b1;
                if (last) next = S_DONE;
              end
      S_DONE:             next = S_IDLE;
      default:            next = S_IDLE;     // unreachable encodings recover
    endcase
  end

  // ---- outputs (Moore: a function of state only) ---------------------------
  always_comb begin
    bus_req    = 1'b0;
    beat_valid = 1'b0;
    done       = 1'b0;
    unique case (state)
      S_REQ:   bus_req    = 1'b1;
      S_XFER:  begin bus_req = 1'b1; beat_valid = 1'b1; end
      S_DONE:  done       = 1'b1;
      default: ;
    endcase
  end

`ifndef SYNTHESIS
  a_state_legal: assert property (@(posedge clk) disable iff (!rst_n)
    state inside {S_IDLE, S_REQ, S_XFER, S_DONE})
    else $error("illegal state %b", state);

  a_terminates: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_DONE) |=> (state == S_IDLE));

  c_full_run: cover property (@(posedge clk) disable iff (!rst_n)
    (state == S_IDLE) ##1 (state == S_REQ) [*1:$] ##1 (state == S_XFER)
    [*1:$] ##1 (state == S_DONE));
`endif

endmodule


// =============================================================================
// Style 2: ONE PROCESS -- everything registered. Outputs are glitch-free and
// arrive one cycle after the decision. Shorter timing paths.
// =============================================================================

`default_nettype wire
