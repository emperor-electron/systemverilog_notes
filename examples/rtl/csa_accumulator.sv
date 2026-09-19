// -----------------------------------------------------------------------------
// csa_accumulator.sv -- carry-save accumulator: accumulate at one full-adder
// delay per cycle, independent of the accumulator width.
//
// THE PROBLEM
//   `acc <= acc + din` puts a full carry-propagate adder in a feedback loop.
//   Its delay grows with width -- O(W) for a ripple adder, O(log W) for a
//   fast one -- and because it is a LOOP you cannot pipeline it: the result is
//   needed on the very next cycle.
//
// THE TRICK
//   Do not propagate the carry. Keep the running total in REDUNDANT form as two
//   vectors whose sum is the true value:  value = S + C.  Adding a new operand
//   is then a 3:2 compression of (S, C, din), which is just one full adder per
//   bit with NO carry chain at all:
//
//       S' = S ^ C ^ din                        (sum bits)
//       C' = maj(S, C, din) << 1                (carry bits, weight 2)
//
//   Two gate levels, the same for a 16-bit or a 128-bit accumulator. The single
//   carry-propagate add happens ONCE, when you finally need the number.
//
// THE COST
//   Two registers instead of one, and the true value is not directly visible.
//   That is why this shows up in multiplier arrays, FIR accumulators and
//   CRC/hash trees -- anywhere you add a great many things and read the result
//   rarely.
//
// The same 3:2 compressor is the cell a Wallace or Dadda tree is built from:
// reduce N partial products to 2 with a tree of these, then one final adder.
//
// See docs/22-timing-closure-and-optimization.md.
// -----------------------------------------------------------------------------
`default_nettype none

module csa_accumulator #(
  parameter int unsigned W = 48            // must cover the worst-case total
) (
  input  var logic                clk,
  input  var logic                rst_n,
  input  var logic                clear,   // restart the sum with `din`
  input  var logic                valid,
  input  var logic signed [W-1:0] din,
  output var logic signed [W-1:0] total,   // resolved value (one CPA)
  output var logic signed [W-1:0] save_s,  // redundant form, for chaining
  output var logic signed [W-1:0] save_c
);

  logic [W-1:0] s_q, c_q;
  logic [W-1:0] s_n, c_n, maj;

  // 3:2 compressor. `maj` shifted left by one is the carry vector; the bit
  // shifted out of the top is the overflow that W was sized to avoid.
  //
  // `maj` needs its own name: a part-select may only be applied to a variable
  // or net, never directly to a parenthesised expression.
  always_comb begin
    maj = (s_q & c_q) | (c_q & din) | (s_q & din);
    s_n = s_q ^ c_q ^ din;
    c_n = {maj[W-2:0], 1'b0};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_q <= '0;
      c_q <= '0;
    end else if (clear) begin
      s_q <= din;
      c_q <= '0;
    end else if (valid) begin
      s_q <= s_n;
      c_q <= c_n;
    end
  end

  // The one and only carry-propagate add. In a real design this lives outside
  // the accumulation loop -- on a separate cycle, or pipelined -- so its delay
  // never limits the accumulation rate.
  assign total  = signed'(s_q + c_q);
  assign save_s = signed'(s_q);
  assign save_c = signed'(c_q);

endmodule

`default_nettype wire
