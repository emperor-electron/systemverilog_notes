// -----------------------------------------------------------------------------
// priority_encoder_fv.sv -- exhaustive proof of priority_encoder.
//
// N = 16 means 65536 patterns, which rtl_smoke_tb enumerates by brute force.
// Formal proves it without enumerating, so N can be raised to 32 or 64 where
// simulation cannot follow.
// -----------------------------------------------------------------------------
`default_nettype none

module priority_encoder_fv #(
  parameter int unsigned N  = 16,
  parameter int unsigned IW = 4
) (
  input  var logic         clk,
  input  var logic [N-1:0] in
);

  logic [IW-1:0] idx;
  logic          valid;

  priority_encoder #(.N(N), .IW(IW)) dut (.in(in), .idx(idx), .valid(valid));

  // Independent reference: search upward for the first set bit.
  logic [IW-1:0] ref_idx;
  logic          ref_valid;
  integer        i;
  always @* begin
    ref_idx   = '0;
    ref_valid = 1'b0;
    for (i = 0; i < N; i = i + 1)
      if (in[i] && !ref_valid) begin
        ref_idx   = i[IW-1:0];
        ref_valid = 1'b1;
      end
  end

  always @(posedge clk) begin
    a_valid : assert (valid == ref_valid);
    // idx is only meaningful when valid. Asserting it unconditionally would be
    // a stronger claim than the module makes.
    a_idx   : assert (!valid || (idx == ref_idx));
    // Structural: the reported bit really is set, and nothing below it is.
    a_is_set: assert (!valid || in[idx]);
    c_none  : cover (!valid);
    c_lowest: cover (valid && idx == '0);
    c_top   : cover (valid && idx == IW'(N-1));
  end

endmodule

`default_nettype wire
