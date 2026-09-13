// -----------------------------------------------------------------------------
// div_signed.sv -- signed wrapper around the restoring divider.
//
// `a / b` in RTL infers a full combinational divider: enormous, and with a
// critical path that will not close. Division by a constant power of two is
// free (wiring); everything else should be an explicit multi-cycle unit like
// this one, or a reciprocal-and-multiply.
//
// Restoring division is the shift-subtract algorithm you did by hand:
//
//   rem = 0; quo = dividend
//   repeat W times:
//     {rem, quo} <<= 1              -- bring down the next dividend bit
//     if (rem >= divisor) then      -- does the divisor go in?
//        rem -= divisor;  quo[0] = 1
//
// One subtract-and-compare per cycle, W cycles total. The comparison and the
// subtraction share one adder: compute rem - divisor and look at the borrow.
//
// See docs/17 (division semantics) and docs/18 (fixed-point division).
// -----------------------------------------------------------------------------
`default_nettype none

// ----------------------------------------------------------------------------
// Signed wrapper.
//
// SystemVerilog signed division TRUNCATES TOWARD ZERO (-7/2 == -3), and the
// remainder takes the sign of the DIVIDEND (-7%2 == -1). That is the C
// convention, and it is NOT what an arithmetic right shift gives you
// (-7>>>1 == -4, which floors). So: divide magnitudes, then apply signs.
//
// The most-negative input is the usual asymmetry trap: abs(-2^(W-1)) does not
// fit in W signed bits. Computing the magnitude in UNSIGNED arithmetic makes
// it work, because 2^(W-1) is representable there.
// ----------------------------------------------------------------------------
module 
div_signed #(
  parameter int unsigned W = 32
) (
  input  var logic                clk,
  input  var logic                rst_n,
  input  var logic                valid_i,
  output var logic                ready_o,
  input  var logic signed [W-1:0] dividend,
  input  var logic signed [W-1:0] divisor,
  output var logic                valid_o,
  input  var logic                ready_i,
  output var logic signed [W-1:0] quotient,
  output var logic signed [W-1:0] remainder,
  output var logic                div_by_zero
);

  logic [W-1:0] abs_a, abs_b, uq, ur;
  logic         sa, sb, sq_q, sa_q;
  logic         u_valid, u_ready, u_dbz;

  // Magnitude in UNSIGNED arithmetic: -(-2^(W-1)) is 2^(W-1), which fits.
  assign sa    = dividend[W-1];
  assign sb    = divisor[W-1];
  assign abs_a = sa ? (~dividend + 1'b1) : dividend;
  assign abs_b = sb ? (~divisor  + 1'b1) : divisor;

  div_restoring #(.W(W)) u_div (
    .clk         (clk),
    .rst_n       (rst_n),
    .valid_i     (valid_i),
    .ready_o     (ready_o),
    .dividend    (abs_a),
    .divisor     (abs_b),
    .valid_o     (u_valid),
    .ready_i     (ready_i),
    .quotient    (uq),
    .remainder   (ur),
    .div_by_zero (u_dbz)
  );

  // Latch the signs of the operands that started this division.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sq_q <= 1'b0;
      sa_q <= 1'b0;
    end else if (valid_i && ready_o) begin
      sq_q <= sa ^ sb;      // quotient sign
      sa_q <= sa;           // remainder takes the DIVIDEND's sign
    end
  end

  assign valid_o     = u_valid;
  assign div_by_zero = u_dbz;
  assign quotient    = sq_q ? -signed'(uq) : signed'(uq);
  assign remainder   = sa_q ? -signed'(ur) : signed'(ur);

endmodule

`default_nettype wire
