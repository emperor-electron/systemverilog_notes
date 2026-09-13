// -----------------------------------------------------------------------------
// mac_pipelined.sv -- signed multiply-accumulate, shaped to map onto a hard
// DSP block (Xilinx DSP48, Intel DSP, or an ASIC MAC macro).
//
// Hitting the hard block is entirely about MATCHING ITS SHAPE:
//   * a signed multiply whose operand widths fit the block (18x18, 18x27, ...)
//   * a REGISTER between the multiply and the accumulate (the block has one;
//     if your RTL does not, the tool must either add latency or give up and
//     build the accumulator out of fabric)
//   * an accumulator wide enough that it never needs external saturation
//   * no reset on the multiplier pipeline register, or a synchronous one
//
// Bit growth (see docs/18):
//   product        : AW + BW bits, exactly
//   N accumulations: + ceil(log2(N)) guard bits
// With GUARD = clog2(N) the accumulator is PROVABLY overflow-free for any
// input, so there is no saturation logic in the inner loop -- you saturate
// once on the way out. That is both smaller and faster.
//
// Every widening cast here is load-bearing. `ACCW'(prod)` sign-extends only
// because `prod` is declared signed; on an unsigned `prod` it would
// zero-extend and every negative product would become a huge positive one.
// See docs/17.
// -----------------------------------------------------------------------------
`default_nettype none

module mac_pipelined #(
  parameter int unsigned AW    = 18,                  // sample width
  parameter int unsigned BW    = 18,                  // coefficient width
  parameter int unsigned NACC  = 1024,                // max accumulations
  parameter int unsigned PW    = AW + BW,             // exact product width
  parameter int unsigned GUARD = $clog2(NACC),        // headroom
  parameter int unsigned ACCW  = PW + GUARD           // accumulator width
) (
  input  var logic                    clk,
  input  var logic                    rst_n,

  input  var logic                    valid_i,
  input  var logic signed [AW-1:0]    a,
  input  var logic signed [BW-1:0]    b,
  input  var logic                    acc_clear,      // start a new sum
                                                      //   with this sample

  output var logic                    valid_o,
  output var logic signed [ACCW-1:0]  acc
);

  // ---- stage 1: multiply (registered -- this is the DSP block's M register)
  logic signed [PW-1:0] prod_q;
  logic                 v1_q, clr1_q;

  always_ff @(posedge clk) begin
    // Both operands are signed, so this is a SIGNED multiply and the result is
    // signed. Mixing in one unsigned operand would silently make the whole
    // multiply unsigned -- different gates, wrong answer.
    prod_q <= a * b;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1_q   <= 1'b0;
      clr1_q <= 1'b0;
    end else begin
      v1_q   <= valid_i;
      clr1_q <= acc_clear;
    end
  end

  // ---- stage 2: accumulate (the DSP block's P register) --------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc     <= '0;
      valid_o <= 1'b0;
    end else begin
      valid_o <= v1_q;
      if (v1_q) begin
        // ACCW'(prod_q) sign-extends because prod_q is declared signed.
        acc <= clr1_q ? ACCW'(prod_q) : (acc + ACCW'(prod_q));
      end
    end
  end

`ifndef SYNTHESIS
  // With clog2(NACC) guard bits the accumulator cannot overflow within NACC
  // accumulations. This assertion is what makes that claim checkable: it
  // catches a GUARD that was reduced without re-deriving NACC.
  logic [31:0] n_acc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            n_acc <= '0;
    else if (v1_q && clr1_q) n_acc <= 32'd1;
    else if (v1_q)           n_acc <= n_acc + 1'b1;
  end

  a_acc_budget: assert property (@(posedge clk) disable iff (!rst_n)
    n_acc <= 32'(NACC))
    else $error("mac_pipelined: %0d accumulations exceeds NACC=%0d (overflow \
is no longer guaranteed impossible)", n_acc, NACC);
`endif

endmodule

`default_nettype wire
