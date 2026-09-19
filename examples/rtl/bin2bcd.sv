// -----------------------------------------------------------------------------
// bin2bcd.sv -- binary to packed BCD by the DOUBLE DABBLE algorithm.
//
// THE PROBLEM
//   Displaying a number in decimal needs division by 10, and a divider is large
//   and slow (see div_restoring.sv). For a display update that is absurd.
//
// THE ALGORITHM (shift-and-add-3)
//   Shift the binary value left into a BCD accumulator one bit at a time. Before
//   each shift, any BCD digit that is >= 5 gets 3 added to it.
//
//   Why 3: doubling a digit d >= 5 must produce a carry into the next digit,
//   i.e. the result should be 2d - 10 with a carry. A plain shift gives 2d. So
//   pre-add 3, and the shift turns it into 2d + 6 -- which is exactly
//   (2d - 10) + 16, i.e. the right low digit plus a carry out of the nibble.
//   One add-3 per digit per bit, and no division anywhere.
//
//   Unrolled, this is pure combinational logic: IN_W stages of (compare, maybe
//   add 3, shift). For a display it can equally be done one bit per cycle with a
//   single adder -- the structure is identical, folded in time.
//
// DIGITS defaults to the number of decimal digits 2^IN_W-1 needs:
//   floor(IN_W * log10(2)) + 1, computed with the integer ratio 30103/100000.
//
// See docs/23-structural-design-techniques.md.
// -----------------------------------------------------------------------------
`default_nettype none

module bin2bcd #(
  parameter int unsigned IN_W   = 8,
  parameter int unsigned DIGITS = (IN_W * 30103) / 100000 + 1
) (
  input  var logic [IN_W-1:0]     bin,
  output var logic [DIGITS*4-1:0] bcd
);

  logic [DIGITS*4-1:0] acc;
  integer              i, d;

  always_comb begin
    acc = '0;
    for (i = IN_W - 1; i >= 0; i = i - 1) begin
      // Pre-bias every digit that would otherwise fail to carry.
      for (d = 0; d < DIGITS; d = d + 1)
        if (acc[d*4 +: 4] >= 4'd5)
          acc[d*4 +: 4] = acc[d*4 +: 4] + 4'd3;
      // Shift the next binary bit in at the bottom.
      acc = {acc[DIGITS*4-2:0], bin[i]};
    end
    bcd = acc;
  end

endmodule

`default_nettype wire
