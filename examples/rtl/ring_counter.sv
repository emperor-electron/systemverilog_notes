// -----------------------------------------------------------------------------
// ring_counter.sv -- one-hot ring counter.
//
// WHY: a binary counter plus a decoder costs log2(N) flops, a carry chain, and a
// decoder on every consumer. A ring counter costs N flops and NOTHING else --
// each consumer reads its own bit. Below roughly 16 states that is the better
// trade, and on an FPGA (flops plentiful, LUT depth precious) it wins sooner.
//
// SELF_CORRECT is the interesting part. A plain rotate preserves whatever bit
// pattern it starts with, so a single upset -- an SEU, a glitch during power-up,
// a missed reset -- leaves the counter permanently wrong, possibly all-zero and
// silently dead. The self-correcting form injects
//
//     ~|q[N-2:0]      instead of      q[N-1]
//
// which is 1 exactly when the lower N-1 bits are empty. In normal one-hot
// operation that is identical to rotating. From ANY illegal state it recovers
// within N cycles: extra bits shift out of the top and zeros come in behind
// them, and once the low bits are empty a fresh 1 is injected.
//
// That costs an N-1 input NOR and buys a design with no unreachable dead state
// -- which also matters for DFT, because a state machine that can lock up is a
// state machine scan cannot always get out of. See docs/24.
// -----------------------------------------------------------------------------
`default_nettype none

module ring_counter #(
  parameter int unsigned N            = 8,
  parameter bit          SELF_CORRECT = 1'b1
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         en,
  output var logic [N-1:0] q
);

  logic inject;

  // Self-correcting: inject a 1 when the lower bits are empty.
  // Plain rotate: recirculate the top bit.
  assign inject = SELF_CORRECT ? (~|q[N-2:0]) : q[N-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n) q <= {{(N-1){1'b0}}, 1'b1};
    else if (en)     q <= {q[N-2:0], inject};
  end

`ifdef FORMAL
  logic fv_past = 1'b0;
  always @(posedge clk) fv_past <= 1'b1;

  always @(posedge clk) begin
    if (rst_n && fv_past && $past(rst_n)) begin
      // ONE-HOT IS PRESERVED, not one-hot-always. The difference matters and is
      // easy to get wrong:
      //
      //   `assert ($onehot(q))` fails under INDUCTION -- and correctly so. The
      //   induction step starts from an ARBITRARY state satisfying the
      //   assertions, and for a self-correcting counter non-one-hot states are
      //   real states it is designed to recover from. One-hot is a property of
      //   the REACHABLE state space, not of every state.
      //
      //   Split it instead: this preservation step is inductive, and reset
      //   establishes the base case. The two together give one-hot for every
      //   reachable state -- which the harness checks directly with BMC.
      f_onehot_pres : assert (!$onehot($past(q)) || $onehot(q));
      f_holds       : assert ($past(en) || (q == $past(q)));

      // Self-correction: whatever state it is in, the lower bits emptying
      // always injects exactly one bit. So the counter can never be stuck
      // all-zero for more than one enabled cycle.
      if (SELF_CORRECT)
        f_never_stuck : assert (!($past(q) == '0 && $past(en)) || (q != '0));
    end
  end

  always @(posedge clk) begin
    f_c_walk : cover (rst_n && q[N-1]);
  end
`endif

endmodule

`default_nettype wire
