// -----------------------------------------------------------------------------
// adder_tree.sv -- balanced N-input adder tree, recursively generated, with
// optional pipeline registers at every level.
//
// WHY A TREE AND NOT A CHAIN
//   acc = a[0] + a[1] + a[2] + ... written as a loop gives a CHAIN: N-1 adders
//   in series, so the delay grows as O(N) and the widths grow one bit at a
//   time. A balanced tree has depth ceil(log2(N)). For 16 operands that is
//   15 adders deep versus 4 -- the same area, a quarter of the delay.
//
//   Synthesis will often rebalance a chain into a tree on its own, but only
//   when the operation is associative AND the tool is confident about the
//   widths. Write the tree and the question does not arise.
//
// WHY RECURSION
//   A recursive module with a generate-if terminating condition produces a
//   finite structure at elaboration -- the recursion happens in the elaborator,
//   not in hardware. It handles a non-power-of-two N naturally by splitting
//   unevenly, which a hand-written loop does not.
//
// WIDTH GROWTH
//   Summing N values of W bits needs W + ceil(log2(N)) bits to be
//   overflow-free. Each level adds exactly one bit, which is what the
//   recursive width expression below encodes. See docs/18.
//
// See docs/21-pipelining.md and docs/22-timing-closure-and-optimization.md.
// -----------------------------------------------------------------------------
`default_nettype none

module adder_tree #(
  parameter int unsigned N     = 8,      // number of operands
  parameter int unsigned W     = 16,     // width of each operand
  parameter bit          SIGNED_OP = 1'b1,
  parameter bit          PIPE  = 1'b0,   // 1 => a register at every tree level
  parameter int unsigned OW    = W + $clog2(N)   // output width
) (
  input  var logic             clk,
  input  var logic             rst_n,
  input  var logic             en,
  input  var logic [N*W-1:0]   din_flat,  // operand k is din_flat[k*W +: W]
  output var logic [OW-1:0]    dout
);

  if (N == 0) begin : g_chk
    $error("adder_tree: N must be >= 1");
  end

  if (N == 1) begin : g_leaf
    // Terminating case. The cast is what performs the sign or zero extension;
    // a bare assignment of the unsigned slice would always zero-extend.
    assign dout = SIGNED_OP ? OW'(signed'(din_flat[W-1:0]))
                            : OW'(din_flat[W-1:0]);

  end else begin : g_node
    localparam int unsigned NL = N / 2;          // left subtree operand count
    localparam int unsigned NR = N - NL;         // right subtree (>= NL)
    // Each subtree needs W + clog2(its own N) bits; use the larger for both so
    // the final add has matching operand widths.
    localparam int unsigned SW = W + ((NR <= 1) ? 0 : $clog2(NR));

    logic [SW-1:0] l, r;

    adder_tree #(.N(NL), .W(W), .SIGNED_OP(SIGNED_OP), .PIPE(PIPE), .OW(SW))
      u_l (.clk(clk), .rst_n(rst_n), .en(en),
           .din_flat(din_flat[0 +: NL*W]), .dout(l));

    adder_tree #(.N(NR), .W(W), .SIGNED_OP(SIGNED_OP), .PIPE(PIPE), .OW(SW))
      u_r (.clk(clk), .rst_n(rst_n), .en(en),
           .din_flat(din_flat[NL*W +: NR*W]), .dout(r));

    logic [OW-1:0] sum;
    assign sum = SIGNED_OP ? OW'(signed'(l) + signed'(r))
                           : OW'(l + r);

    if (PIPE) begin : g_reg
      // One register per LEVEL, not per adder: because both subtrees are
      // elaborated at the same depth, this inserts a balanced set of pipeline
      // registers with no extra latency-matching work. Total latency is
      // ceil(log2(N)) cycles.
      always_ff @(posedge clk or negedge rst_n) begin
        if      (!rst_n) dout <= '0;
        else if (en)     dout <= sum;
      end
    end else begin : g_comb
      assign dout = sum;
    end
  end

endmodule

`default_nettype wire
