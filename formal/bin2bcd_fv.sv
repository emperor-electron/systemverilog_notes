// -----------------------------------------------------------------------------
// bin2bcd_fv.sv -- exhaustive proof of the double-dabble converter.
//
// Two things have to hold, and checking only the first is a common mistake:
//   1. every output nibble is a legal BCD digit (0..9);
//   2. the digits, read as a decimal number, equal the binary input.
//
// A converter that produced 0x0A instead of 0x10 for ten would satisfy (2) if
// (2) were written carelessly, and a converter that clamped every digit to 9
// would satisfy (1). Both are needed.
//
// IN_W = 8 is 256 patterns, which simulation can enumerate. The proof does not
// care: raise IN_W to 16 or 32 and it still terminates.
// -----------------------------------------------------------------------------
`default_nettype none

module bin2bcd_fv #(
  parameter int unsigned IN_W   = 8,
  parameter int unsigned DIGITS = (IN_W * 30103) / 100000 + 1
) (
  input  var logic             clk,
  input  var logic [IN_W-1:0]  bin
);

  logic [DIGITS*4-1:0] bcd;
  bin2bcd #(.IN_W(IN_W), .DIGITS(DIGITS)) dut (.bin(bin), .bcd(bcd));

  // Recompose the decimal value from the digits, weighted by powers of ten.
  logic [31:0] recomposed;
  logic [31:0] weight;
  integer      d;

  always @* begin
    recomposed = 32'd0;
    weight     = 32'd1;
    for (d = 0; d < DIGITS; d = d + 1) begin
      recomposed = recomposed + (32'(bcd[d*4 +: 4]) * weight);
      weight     = weight * 32'd10;
    end
  end

  always @(posedge clk) begin
    f_value : assert (recomposed == 32'(bin));
  end

  // Every nibble must be a valid BCD digit.
  for (genvar k = 0; k < int'(DIGITS); k++) begin : g_digit
    always @(posedge clk)
      assert (bcd[k*4 +: 4] <= 4'd9);
  end

  always @(posedge clk) begin
    f_c_zero : cover (bin == '0);
    f_c_max  : cover (bin == '1);
    f_c_carry: cover (bin == IN_W'(10));     // the first digit carry
  end

endmodule

`default_nettype wire
