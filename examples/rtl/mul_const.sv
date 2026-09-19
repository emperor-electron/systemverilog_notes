// -----------------------------------------------------------------------------
// mul_const.sv -- multiply by a COMPILE-TIME constant with no multiplier.
//
// A multiply by a constant is a sum of shifted copies, and shifts are free.
// Two encodings, selectable, with very different adder counts:
//
//   BINARY   one term per set bit of C.          popcount(C) terms.
//   CSD      canonical signed digit (non-adjacent form): terms may be
//            SUBTRACTED as well as added, which collapses every run of 1s into
//            a single subtract-and-carry.
//
//   C = 7    binary: (x<<2)+(x<<1)+x        3 terms
//            CSD:    (x<<3) - x             2 terms
//   C = 15   binary: 4 terms                CSD: (x<<4) - x, 2 terms
//   C = 255  binary: 8 terms                CSD: (x<<8) - x, 2 terms
//
// The CSD recoding runs in the ELABORATOR -- the masks are localparams, so the
// hardware is just the adder tree they describe. Nothing computes the encoding
// at run time.
//
// Worth knowing: synthesis usually does this transformation itself when it sees
// `x * 8'd7`. Writing it out matters when you want the CSD form guaranteed, when
// the constant comes from a parameter the tool will not treat as constant, or
// when you need to know the adder count for area budgeting.
//
// See docs/23-structural-design-techniques.md.
// -----------------------------------------------------------------------------
`default_nettype none

module mul_const #(
  parameter int unsigned  IN_W = 8,
  parameter int unsigned  CW   = 8,
  parameter logic [CW-1:0] C   = 8'd7,
  parameter bit           USE_CSD = 1'b1,
  parameter int unsigned  OUT_W = IN_W + CW
) (
  input  var logic [IN_W-1:0]  din,
  output var logic [OUT_W-1:0] dout
);

  // Masks are one bit wider than C: the CSD carry can push a term one position
  // above the top of C (C = 2^CW - 1 becomes 2^CW - 1 term).
  localparam int unsigned MW = CW + 1;

  // ---- elaboration-time recoding -------------------------------------------
  // Note the assign-to-the-function-name style rather than `return`: Yosys's
  // formal frontend rejects `return`, and this module is a formal target.
  function automatic logic [MW-1:0] csd_add(input logic [CW-1:0] c);
    logic [MW+1:0] v;
    int            i;
    csd_add = '0;
    v       = {2'b00, c};
    i       = 0;
    while (v != 0 && i < MW) begin
      if (v[0]) begin
        // ...11 -> subtract here and carry; ...01 -> add here.
        if (v[1]) v = v + 1;
        else      begin csd_add[i] = 1'b1; v = v - 1; end
      end
      v = v >> 1;
      i = i + 1;
    end
  endfunction

  function automatic logic [MW-1:0] csd_sub(input logic [CW-1:0] c);
    logic [MW+1:0] v;
    int            i;
    csd_sub = '0;
    v       = {2'b00, c};
    i       = 0;
    while (v != 0 && i < MW) begin
      if (v[0]) begin
        if (v[1]) begin csd_sub[i] = 1'b1; v = v + 1; end
        else      v = v - 1;
      end
      v = v >> 1;
      i = i + 1;
    end
  endfunction

  localparam logic [MW-1:0] ADD_MASK = USE_CSD ? csd_add(C) : {1'b0, C};
  localparam logic [MW-1:0] SUB_MASK = USE_CSD ? csd_sub(C) : '0;

  // ---- the datapath: one shifted term per set mask bit ----------------------
  logic [OUT_W-1:0] acc;
  integer           i;

  always_comb begin
    acc = '0;
    for (i = 0; i < MW; i = i + 1) begin
      // Intermediate results may go NEGATIVE when a subtract term is applied
      // before a larger add term. That is harmless: two's complement addition
      // is exact modulo 2^OUT_W, and the true product fits in OUT_W bits, so
      // the final value is correct regardless of the order.
      if (ADD_MASK[i]) acc = acc + (OUT_W'(din) << i);
      if (SUB_MASK[i]) acc = acc - (OUT_W'(din) << i);
    end
    dout = acc;
  end

`ifdef FORMAL
  // Exhaustive equivalence against the multiply it replaces. Depth 1 covers
  // every input value.
  always @* begin
    f_equiv : assert (dout == (OUT_W'(din) * OUT_W'(C)));
  end
`endif

endmodule

`default_nettype wire
