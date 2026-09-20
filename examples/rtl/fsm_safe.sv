// -----------------------------------------------------------------------------
// fsm_safe.sv -- one-hot FSM with explicit illegal-state recovery.
//
// A 4-state one-hot FSM has 16 encodings, of which 4 are legal. The other 12
// are not merely unused -- they are reachable in silicon, by a single event
// upset, a marginal reset, a metastable capture on an input that feeds the
// next-state logic, or a setup violation on one bit of the state vector. What
// the design does in those 12 encodings is a decision you make on purpose or a
// decision the synthesiser makes for you.
//
// Built the obvious way, the OR-of-transitions form below makes all-zeros an
// ABSORBING state: no transition term is true, so next is all-zeros again, and
// the FSM is dead until the next reset. On a controller with no watchdog, that
// is a hang with no symptom other than silence.
//
// SAFE == 1 adds one term -- "if the state is not one-hot, go to IDLE" -- which
// costs a $onehot decode and makes every one of the 12 illegal encodings
// recover in a single cycle. formal/fsm_safe_fv.sby proves exactly that, over
// all 16 encodings, not just the ones a testbench happens to reach.
//
// SAFE == 0 is kept so the failure is demonstrable: examples/tb/fsm_tb.sv
// forces an illegal state into both variants and shows one hanging.
//
// NOTE ON VENDOR ATTRIBUTES: Vivado's `(* fsm_safe_state = "reset_state" *)`
// asks the tool to do this for you. It is worth setting, but it applies only
// when the tool actually infers an FSM -- which it may not for a hand-written
// one-hot vector -- and it is silently ignored by every other toolchain. RTL
// you can read and prove beats an attribute you have to trust.
//
// See docs/26-fsm-coding-styles.md.
// -----------------------------------------------------------------------------
`default_nettype none

module fsm_safe #(
  parameter bit SAFE = 1'b1
) (
  input  var logic       clk,
  input  var logic       rst_n,
  input  var logic       start,
  input  var logic       grant,
  input  var logic       last_beat,
  output var logic       bus_req,
  output var logic       done,
  output var logic       state_err   // current encoding is not one-hot
);

  localparam int unsigned NS = 4;

  // Index constants, not an enum: the state vector is a bit per state, so the
  // transitions below are written as plain boolean equations. An enum would
  // imply the vector only ever holds a named value, which is the assumption
  // this module exists to not make.
  localparam int unsigned I_IDLE = 0;
  localparam int unsigned I_REQ  = 1;
  localparam int unsigned I_XFER = 2;
  localparam int unsigned I_DONE = 3;

  logic [NS-1:0] state, next;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= (NS'(1) << I_IDLE);
    else        state <= next;
  end

  // Next-state as an OR of the transitions INTO each state. Each bit is a
  // two-term function of one or two state bits, so the whole next-state cone is
  // two levels deep no matter how many states there are -- which is why one-hot
  // closes timing on wide FSMs where a binary encoding needs a full decode.
  always_comb begin
    next = '0;

    next[I_IDLE] = (state[I_IDLE] & ~start)
                 |  state[I_DONE];
    next[I_REQ]  = (state[I_IDLE] &  start)
                 | (state[I_REQ]  & ~grant);
    next[I_XFER] = (state[I_REQ]  &  grant)
                 | (state[I_XFER] & ~last_beat);
    next[I_DONE] = (state[I_XFER] &  last_beat);

    // The recovery term. It must come LAST and overwrite, not OR in: ORing
    // IDLE into an illegal state would produce a state that is still illegal
    // (two bits set) rather than recovering from it.
    if (SAFE && !$onehot(state)) next = (NS'(1) << I_IDLE);
  end

  assign bus_req    = state[I_REQ] | state[I_XFER];
  assign done       = state[I_DONE];
  assign state_err  = !$onehot(state);

`ifdef FORMAL
  // The immediate dialect, for Yosys. `next` is internal, and a hierarchical
  // reference from a harness reads the wrong net under the Yosys frontend
  // (docs/25), so the property that needs `next` has to live here.
  //
  // No clock and no reset qualifier: this is a claim about the COMBINATIONAL
  // function, asserted over every one of the 16 encodings `state` can hold.
  // Induction supplies the arbitrary states for free -- that is the whole
  // reason this is a formal property and not a test.
  if (SAFE) begin : g_fv
    always @* f_next_always_legal : assert ($onehot(next));
  end
`endif

`ifndef SYNTHESIS
  // NOT asserted here: `$onehot(state)`.
  //
  // It is true of every reachable state, but this is the one module in the
  // repository whose job is to behave well in the states where it is FALSE.
  // Asserting it inside the module would fire on every fault injection and on
  // every formal step that starts from an arbitrary state -- punishing the
  // design for the tolerance it was built to have. The reachability claim
  // belongs to the caller, so it lives in formal/fsm_safe_fv.sv and in
  // examples/tb/fsm_tb.sv. ring_counter.sv is split for the same reason.
  //
  // What IS asserted here is the module's actual contract: however it got into
  // an illegal encoding, it leaves on the next edge.
  a_recovers: assert property (@(posedge clk) disable iff (!rst_n)
    (SAFE && !$onehot(state)) |=> $onehot(state))
    else $error("fsm_safe: still in illegal encoding %b", state);
`endif

endmodule

`default_nettype wire
