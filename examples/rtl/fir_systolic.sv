// -----------------------------------------------------------------------------
// fir_systolic.sv -- transposed-form systolic FIR filter.
//
// Direct-form FIR
//     y[n] = sum(h[k] * x[n-k])
// has an adder TREE whose depth grows as log(NTAP) and a fanout of x to every
// tap. The transposed (systolic) form reverses the delay line so that every
// tap is  multiply -> add -> register, giving a critical path of exactly one
// multiply plus one add REGARDLESS of tap count. It is the reason real FIRs
// are built this way.
//
//    x ->+----------+----------+----------+
//        |          |          |          |
//       [*h3]      [*h2]      [*h1]      [*h0]
//        |          |          |          |
//   0 ->(+)->[R]-->(+)->[R]-->(+)->[R]-->(+)->[R]--> y
//
// LATENCY IS ONE CYCLE, not NTAP -- which surprises people. In the transposed
// form the partial sums held in the chain belong to FUTURE outputs, not to an
// incomplete current one: chain[NTAP-1] already equals the full
// sum_j h[j]*x[n-j] for the sample just consumed, because the samples that have
// not arrived yet contribute zero. Unrolling the recurrence shows it directly:
//
//   chain[k](t)        = chain[k-1](t-1) + x(t) * h[NTAP-1-k]
//   => chain[NTAP-1](t) = sum_j x(t-j) * h[j]
//
// Throughput is one sample per cycle.
//
// Every register carries a clock enable driven by valid_i, so the delay line
// only advances on valid samples and the filter is correct with gaps in the
// input stream. Without that enable the chain would shift on idle cycles and
// inject zeros into the middle of the convolution.
//
// NUMERICAL DESIGN (docs/18):
//   * products are kept at FULL precision (DW + CW bits) -- no rounding inside
//     the chain, because truncating at every tap would inject NTAP times the
//     quantization noise AND a -0.5 LSB DC bias per tap.
//   * the accumulator carries clog2(NTAP) guard bits, making overflow
//     impossible for any input.
//   * rounding and saturation happen ONCE, at the output, in `requantize`.
// -----------------------------------------------------------------------------
`default_nettype none

module fir_systolic #(
  parameter int unsigned NTAP  = 8,
  parameter int unsigned DW    = 16,                  // sample width
  parameter int unsigned CW    = 18,                  // coefficient width
  parameter int unsigned CF    = 17,                  // coefficient frac bits
  parameter int unsigned PW    = DW + CW,             // full product width
  parameter int unsigned GUARD = $clog2(NTAP),
  parameter int unsigned ACCW  = PW + GUARD,
  parameter bit          ROUND = 1'b1
) (
  input  var logic                   clk,
  input  var logic                   rst_n,
  input  var logic                   valid_i,
  input  var logic signed [DW-1:0]   x,
  // Coefficients as one flat packed vector: coef_flat[k*CW +: CW] is h[k].
  // A packed port is more portable than an unpacked array port and the
  // indexed part-select is the idiomatic way to slice it (docs/03).
  input  var logic [NTAP*CW-1:0]     coef_flat,
  output var logic                   valid_o,
  output var logic signed [DW-1:0]   y,               // rounded + saturated
  output var logic signed [ACCW-1:0] y_full,          // full precision
  output var logic                   sat
);

  if (NTAP < 1) begin : g_chk_ntap
    $error("fir_systolic: NTAP must be >= 1");
  end
  if (CF >= PW) begin : g_chk_cf
    $error("fir_systolic: CF (%0d) must be < PW (%0d)", CF, PW);
  end

  // chain[k] is the REGISTERED partial sum leaving tap k.
  //
  // Note the array is driven only from always_ff blocks. Mixing a continuous
  // `assign chain[0] = ...` with procedural writes to other elements is legal
  // per the LRM but several tools reject it, treating the array as one object.
  // The per-iteration `prev_*` wires below avoid the question entirely.
  logic signed [ACCW-1:0] chain [0:NTAP-1];

  for (genvar k = 0; k < int'(NTAP); k++) begin : g_tap
    logic signed [CW-1:0]   h;
    logic signed [PW-1:0]   prod;
    logic signed [ACCW-1:0] prev_sum;

    if (k == 0) begin : g_head
      assign prev_sum = '0;
    end else begin : g_body
      assign prev_sum = chain[k-1];
    end

    // COEFFICIENT ORDER: the transposed form walks the coefficients BACKWARDS
    // relative to the delay line, so tap k must use h[NTAP-1-k] to implement
    // the conventional y[n] = sum_j h[j] * x[n-j]. Indexing it as h[k] instead
    // silently computes the convolution with a time-reversed filter -- which
    // is invisible for a symmetric coefficient set, and very much not for an
    // asymmetric one.
    //
    // The slice is UNSIGNED (docs/17), so the signed'() cast is what makes the
    // multiply below a SIGNED multiply. Without it, every negative coefficient
    // would be read as a large positive number.
    assign h    = signed'(coef_flat[(NTAP-1-k)*CW +: CW]);
    assign prod = x * h;                         // signed * signed -> signed

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n)          chain[k] <= '0;
      // ACCW'(prod) sign-extends: `prod` is declared signed.
      else if (valid_i)    chain[k] <= prev_sum + ACCW'(prod);
    end
  end

  // One cycle of latency: chain[NTAP-1] is already the complete convolution
  // for the sample consumed on the previous enabled edge.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) valid_o <= 1'b0;
    else        valid_o <= valid_i;
  end

  assign y_full = chain[NTAP-1];

  // Round and saturate ONCE, here. The product has CF fraction bits more than
  // the input, so that is what gets dropped to return to the input's format.
  requantize #(
    .WI    (ACCW),
    .WO    (DW),
    .FDROP (CF),
    .ROUND (ROUND)
  ) u_rq (
    .din  (y_full),
    .dout (y),
    .sat  (sat)
  );

endmodule

`default_nettype wire
