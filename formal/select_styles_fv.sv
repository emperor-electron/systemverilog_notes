// -----------------------------------------------------------------------------
// select_styles_fv.sv -- four ways of writing a priority select, compared.
//
// Purely combinational, so there is no clock, no reset and no induction: BMC at
// depth 1 already quantifies over every input, which for W=4 is 4 request bits
// and 16 bits of data -- 2^20 cases, settled exhaustively.
//
// What it settles:
//
//   f_if_casez, f_if_loop   the if-chain, the casez and the unrolled loop are
//                           the SAME circuit. Three spellings, one function.
//
//   f_par_onehot0           the parallel AND-OR form agrees with the priority
//                           forms exactly when at most one request is set.
//                           This is the proof obligation you take on the moment
//                           you write `unique case (1'b1)`.
//
//   f_c_par_differs         ...and the disagreement is reachable, so the
//                           qualified assertion above is not vacuous. A cover
//                           rather than an assert: it is a fact about the
//                           design, not a requirement on it.
// -----------------------------------------------------------------------------
`default_nettype none

module select_styles_fv #(
  parameter int unsigned W = 4
) (
  input  var logic [3:0]     req,
  input  var logic [4*W-1:0] data
);

  logic [W-1:0] d_if, d_casez, d_loop, d_par;

  select_styles #(.W(W)) dut (
    .req(req), .data(data),
    .d_if(d_if), .d_casez(d_casez), .d_loop(d_loop), .d_par(d_par));

  always @* begin
    f_if_casez   : assert (d_if == d_casez);
    f_if_loop    : assert (d_if == d_loop);
    f_par_onehot0: assert (!$onehot0(req) || (d_par == d_if));
  end

  // Reachability, so none of the above can pass by being unreachable.
  always @* begin
    f_c_granted   : cover (|req && (d_if != '0));
    f_c_priority  : cover (req[0] && req[3] && (d_if == data[0 +: W]));
    f_c_par_differs: cover (!$onehot0(req) && (d_par != d_if));
  end

endmodule

`default_nettype wire
