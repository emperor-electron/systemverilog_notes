// -----------------------------------------------------------------------------
// operand_isolation.sv -- stop a wide datapath from switching when its result
// is not used.
//
// THE PROBLEM
//   A multiplier sitting behind a mux computes on every cycle whether or not
//   anyone wants the answer. Its inputs toggle, the whole array toggles, and it
//   burns dynamic power for nothing. On a big datapath this is easily the
//   largest single power item in a block.
//
// THE FIX
//   Hold the operands steady when the result is unused. A stable input means no
//   switching downstream, so the array is quiet. This is "operand isolation"
//   (or "datapath gating"), and unlike clock gating it needs no special cell
//   and no clock-tree work -- it is one AND gate per input bit, or one
//   enable on a register you probably already have.
//
// TWO WAYS, AND THE DIFFERENCE MATTERS
//   ZERO_NOT_HOLD = 1  force the operands to 0 when idle. Combinational, no
//                      state, but it causes a transition ON ENTRY to idle and
//                      another on exit. Good when idle periods are long.
//   ZERO_NOT_HOLD = 0  latch the last operands in a register with a clock
//                      enable. No transitions at all while idle, at the cost of
//                      a register. Better when the unit is used intermittently.
//
// WHEN NOT TO BOTHER
//   The gate is on the datapath, so it adds one gate of delay to a path that is
//   often already critical. If the block is small, or the enable is rarely
//   false, this is a net loss. Measure first.
//
// See docs/22-timing-closure-and-optimization.md.
// -----------------------------------------------------------------------------
`default_nettype none

module operand_isolation #(
  parameter int unsigned AW = 18,
  parameter int unsigned BW = 18,
  parameter bit ZERO_NOT_HOLD = 1'b0       // 0 = hold (registered), 1 = zero
) (
  input  var logic                       clk,
  input  var logic                       rst_n,
  input  var logic                       result_used,   // the enable
  input  var logic signed [AW-1:0]       a,
  input  var logic signed [BW-1:0]       b,
  output var logic signed [AW+BW-1:0]    product
);

  logic signed [AW-1:0] a_iso;
  logic signed [BW-1:0] b_iso;

  if (ZERO_NOT_HOLD) begin : g_zero
    // Purely combinational. Note `signed'()` on the masked value: the AND
    // produces an unsigned result, and feeding that to the multiply below
    // would make it an UNSIGNED multiply -- different hardware, wrong answer
    // for negative operands. See docs/17.
    assign a_iso = signed'(a & {AW{result_used}});
    assign b_iso = signed'(b & {BW{result_used}});

  end else begin : g_hold
    // Registered with a clock enable. While `result_used` is low the inputs to
    // the multiplier do not change at all, so nothing downstream switches.
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        a_iso <= '0;
        b_iso <= '0;
      end else if (result_used) begin
        a_iso <= a;
        b_iso <= b;
      end
    end
  end

  // Both operands signed -> a signed multiply. The product width AW+BW is
  // exact: it always fits, including (-2^(AW-1)) * (-2^(BW-1)).
  assign product = a_iso * b_iso;

endmodule

`default_nettype wire
