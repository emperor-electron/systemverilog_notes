// -----------------------------------------------------------------------------
// lzc_fv.sv -- exhaustive proof of the leading-zero counter.
//
// LZC is the critical block inside a floating-point normalizer, and an
// off-by-one here corrupts every subnormal result. A 32-bit exhaustive proof is
// 4.3 billion patterns -- out of reach for simulation, routine for formal.
// -----------------------------------------------------------------------------
`default_nettype none

module lzc_fv #(
  parameter int unsigned N  = 32,
  parameter int unsigned CW = 6
) (
  input  var logic         clk,
  input  var logic [N-1:0] in
);

  logic [CW-1:0] count;
  logic          all_zero;

  lzc #(.N(N), .CW(CW)) dut (.in(in), .count(count), .all_zero(all_zero));

  // Reference: scan down from the MSB.
  logic [CW-1:0] ref_count;
  logic          ref_zero;
  integer        i;
  logic          found;
  always @* begin
    ref_count = CW'(N);
    ref_zero  = 1'b1;
    found     = 1'b0;
    for (i = N-1; i >= 0; i = i - 1)
      if (in[i] && !found) begin
        ref_count = CW'(N - 1 - i);
        ref_zero  = 1'b0;
        found     = 1'b1;
      end
  end

  always @(posedge clk) begin
    a_count : assert (count == ref_count);
    a_zero  : assert (all_zero == ref_zero);
    // The defining property, independent of the reference: the bit at position
    // (N-1-count) is set, and every bit above it is clear.
    a_bit_set: assert (all_zero || in[N-1-count]);
    c_zero   : cover (all_zero);
    c_msb    : cover (count == '0);
    c_lsb    : cover (!all_zero && count == CW'(N-1));
  end

endmodule

`default_nettype wire
