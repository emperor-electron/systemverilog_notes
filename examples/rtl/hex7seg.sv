// -----------------------------------------------------------------------------
// hex7seg.sv -- 4-bit hex value to a seven-segment pattern.
//
// Segment order is {g,f,e,d,c,b,a} with bit 0 = a, the near-universal
// convention; `a` is the top bar and they run clockwise with `g` in the middle.
//
// ACTIVE_LOW inverts the whole output. Most physical seven-segment displays are
// common-anode, which means a segment lights when its drive is LOW -- so the
// default here is active low, because that is what is usually wired up, and
// getting it backwards is a display that reads in photographic negative.
//
// The table is a pure combinational decode written as a `case` with a full set
// of branches. No `default` is needed for completeness -- all 16 values of a
// 4-bit input are listed -- but one is present anyway so the block cannot
// infer a latch if the input width is ever changed.
// -----------------------------------------------------------------------------
`default_nettype none

module hex7seg #(
  parameter bit ACTIVE_LOW = 1'b1
) (
  input  var logic [3:0] val,
  input  var logic       blank,     // force all segments off
  output var logic [6:0] seg        // {g,f,e,d,c,b,a}
);

  logic [6:0] pat;

  always_comb begin
    unique case (val)               //          gfedcba
      4'h0: pat = 7'b0111111;
      4'h1: pat = 7'b0000110;
      4'h2: pat = 7'b1011011;
      4'h3: pat = 7'b1001111;
      4'h4: pat = 7'b1100110;
      4'h5: pat = 7'b1101101;
      4'h6: pat = 7'b1111101;
      4'h7: pat = 7'b0000111;
      4'h8: pat = 7'b1111111;
      4'h9: pat = 7'b1101111;
      4'hA: pat = 7'b1110111;
      4'hB: pat = 7'b1111100;
      4'hC: pat = 7'b0111001;
      4'hD: pat = 7'b1011110;
      4'hE: pat = 7'b1111001;
      4'hF: pat = 7'b1110001;
      default: pat = 7'b0000000;
    endcase
    if (blank) pat = 7'b0000000;
  end

  assign seg = ACTIVE_LOW ? ~pat : pat;

endmodule

`default_nettype wire
