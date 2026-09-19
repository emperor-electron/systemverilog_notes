// -----------------------------------------------------------------------------
// div_restoring_fv.sv -- the real functional proof of a divider:
//
//        quotient * divisor + remainder == dividend      and   remainder < divisor
//
// That single equation IS the specification of integer division. Simulation can
// check it on a few hundred random pairs; this proves it for every pair the
// solver can reach within the bound -- and because the datapath is uniform, a
// bound covering a couple of full divisions is strong evidence for all of them.
//
// Port-only: the harness drives the operands, so it can latch them itself and
// needs no access to the DUT's internals.
// -----------------------------------------------------------------------------
`default_nettype none

module div_restoring_fv #(
  parameter int unsigned W = 6         // small: the solver unrolls W cycles
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         valid_i,
  input  var logic         ready_i,
  input  var logic [W-1:0] dividend,
  input  var logic [W-1:0] divisor
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic         ready_o, valid_o, div_by_zero;
  logic [W-1:0] quotient, remainder;

  div_restoring #(.W(W)) dut (
    .clk(clk), .rst_n(rst_n),
    .valid_i(valid_i), .ready_o(ready_o),
    .dividend(dividend), .divisor(divisor),
    .valid_o(valid_o), .ready_i(ready_i),
    .quotient(quotient), .remainder(remainder), .div_by_zero(div_by_zero));

  // Latch the operands that started the division in flight.
  logic [W-1:0] a_q = '0, b_q = '0;
  always @(posedge clk)
    if (valid_i && ready_o) begin
      a_q <= dividend;
      b_q <= divisor;
    end

  // The check needs 2W bits: quotient * divisor can use the full width.
  logic [2*W-1:0] recomposed;
  always @* recomposed = (quotient * b_q) + remainder;

  always @(posedge clk) begin
    if (rst_n) begin
      // Handshake sanity: the unit is never simultaneously idle and done.
      f_excl : assert (!(ready_o && valid_o));

      if (valid_o && (b_q != '0)) begin
        // THE specification of division.
        f_exact : assert (recomposed == {{W{1'b0}}, a_q});
        f_rem   : assert (remainder < b_q);
      end

      if (valid_o && (b_q == '0)) begin
        // The documented divide-by-zero convention (RISC-V): quotient all ones,
        // remainder = dividend.
        f_dbz      : assert (div_by_zero);
        f_dbz_q    : assert (quotient  == '1);
        f_dbz_r    : assert (remainder == a_q);
      end
    end
  end

  always @(posedge clk) begin
    f_c_done  : cover (rst_n && valid_o && b_q != '0);
    f_c_dbz   : cover (rst_n && valid_o && b_q == '0);
    f_c_exact : cover (rst_n && valid_o && remainder == '0 && b_q != '0);
  end

endmodule

`default_nettype wire
