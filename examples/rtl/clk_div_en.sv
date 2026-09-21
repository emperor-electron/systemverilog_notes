// -----------------------------------------------------------------------------
// clk_div_en.sv -- divide a clock into a periodic ENABLE, not a slower clock.
//
// This is the module that should exist wherever someone is tempted to write
//
//     always_ff @(posedge clk) slow_clk <= ~slow_clk;   // DON'T
//     always_ff @(posedge slow_clk) ...
//
// A clock produced by logic has skew relative to its parent, needs its own
// clock tree, must be declared with create_generated_clock, breaks scan unless
// bypassed in test mode, and turns one timing domain into two. A clock enable
// has none of those properties and produces the same behaviour:
//
//     always_ff @(posedge clk) if (tick) ...
//
// See docs/24 (why a clock may not come from logic) and docs/32 section 3.
//
// DIV == 1 is legal and degenerates to `tick = en`, so a caller can sweep the
// divisor down to "every cycle" without special-casing.
//
// `tick` is high for exactly one clk cycle every DIV enabled cycles. It is
// gated by `en`, so a stalled consumer does not silently lose ticks: the
// divider stops counting rather than free-running.
// -----------------------------------------------------------------------------
`default_nettype none

module clk_div_en #(
  parameter int unsigned DIV = 2
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic en,        // count enable; hold low to freeze the divider
  output var logic tick       // one cycle high every DIV enabled cycles
);

  if (DIV == 0) begin : g_chk
    $error("clk_div_en: DIV must be >= 1");
  end

  if (DIV == 1) begin : g_passthrough
    assign tick = en;

  end else begin : g_div
    localparam int unsigned CW = $clog2(DIV);

    logic [CW-1:0] cnt;

    // Compare against DIV-1 on the CURRENT count, so `tick` is a register
    // output plus one comparator rather than sitting after the adder.
    assign tick = en && (cnt == CW'(DIV - 1));

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n)   cnt <= '0;
      else if (en)  cnt <= tick ? '0 : (cnt + 1'b1);
    end
  end

endmodule

`default_nettype wire
