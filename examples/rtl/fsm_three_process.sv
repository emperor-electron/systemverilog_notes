// -----------------------------------------------------------------------------
// fsm_three_process.sv -- FSM, three-process style (registered outputs, and no
// latency penalty for them).
//
// Same controller as fsm_two_process.sv: wait for `start`, request a bus, wait
// for `grant`, transfer `len` beats, then pulse `done`. Identical ports, so the
// two can be compared directly -- and formal/fsm_three_process_fv.sby proves
// their outputs are CYCLE-FOR-CYCLE IDENTICAL, not off by one.
//
// THE POINT OF THIS FILE
// The usual objection to registering FSM outputs is "it adds a cycle". That is
// true only of the naive version, which decodes the CURRENT state and registers
// the result:
//
//     always_ff @(posedge clk) bus_req <= (state == S_REQ);   // ONE CYCLE LATE
//
// Decode the NEXT state instead and the register absorbs the cycle that the
// decode would otherwise have added:
//
//     always_ff @(posedge clk) bus_req <= (next == S_REQ);    // ALIGNED
//
// Because `state <= next` happens on the same edge, `bus_req` and `state` land
// in the same cycle. You get a glitch-free output straight off a flop, with a
// clean clock-to-out, and the state decode moved OFF the output path -- for the
// price of one flop per output bit and nothing else.
//
// This is the style to reach for by default on any output that leaves the
// module. See docs/26-fsm-coding-styles.md.
// -----------------------------------------------------------------------------
`default_nettype none

module fsm_three_process #(
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

  state_e        state, next;
  logic [CW-1:0] cnt, cnt_d;
  logic          last;

  assign last = (cnt <= CW'(1));

  // ---- process 1: state register -------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      cnt   <= '0;
    end else begin
      state <= next;
      cnt   <= cnt_d;
    end
  end

  // ---- process 2: next-state logic (combinational, no outputs here) --------
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

  // ---- process 3: output register, decoded from `next` ---------------------
  // Decoding `next` rather than `state` is what keeps the outputs aligned with
  // the state they describe. Every output is assigned on every path, so the
  // reset branch plus straight-line assignment leaves nothing to infer.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bus_req    <= 1'b0;
      beat_valid <= 1'b0;
      done       <= 1'b0;
    end else begin
      bus_req    <= (next == S_REQ) || (next == S_XFER);
      beat_valid <= (next == S_XFER);
      done       <= (next == S_DONE);
    end
  end

`ifdef FORMAL
  // The alignment claim, as an inductive invariant rather than a comment: each
  // output register agrees with the state it accompanies, in the same cycle.
  //
  // It is inductive in one step and needs no help. bus_req(t+1) is decoded from
  // next(t), and state(t+1) IS next(t), so the two land together by
  // construction. Decoding `state` instead would make this property false by
  // exactly one cycle -- which is the difference this module is about.
  always @* begin
    f_req_aligned   : assert (bus_req    == ((state == S_REQ) || (state == S_XFER)));
    f_valid_aligned : assert (beat_valid ==  (state == S_XFER));
    f_done_aligned  : assert (done       ==  (state == S_DONE));
  end
`endif

`ifndef SYNTHESIS
  // The temporal dialect: idiomatic SVA, for XSIM. Yosys cannot read any of
  // this, which is why the formal properties live in the harness instead.
  a_state_legal: assert property (@(posedge clk) disable iff (!rst_n)
    state inside {S_IDLE, S_REQ, S_XFER, S_DONE})
    else $error("illegal state %b", state);

  // The output register must agree with the state it accompanies -- this is the
  // alignment claim, checked every cycle rather than argued in a comment.
  a_req_aligned: assert property (@(posedge clk) disable iff (!rst_n)
    bus_req == ((state == S_REQ) || (state == S_XFER)));

  a_done_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    done |=> !done);

  c_full_run: cover property (@(posedge clk) disable iff (!rst_n)
    (state == S_IDLE) ##1 (state == S_REQ) [*1:$] ##1 (state == S_XFER)
    [*1:$] ##1 (state == S_DONE));
`endif

endmodule

`default_nettype wire
