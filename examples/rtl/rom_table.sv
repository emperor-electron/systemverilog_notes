// -----------------------------------------------------------------------------
// rom_table.sv -- a ROM whose contents are COMPUTED AT ELABORATION.
//
// Anything derivable from parameters costs no hardware to derive: the elaborator
// runs the function, and synthesis sees only constants. Three ways to get a
// table into RTL, in increasing order of preference:
//
//   $readmemh("tbl.hex")   an external file. Can be lost, can drift from the
//                          code that generated it, and needs the generator
//                          script to be archived too.
//   a literal array        correct but unreadable, and unmaintainable when a
//                          parameter changes.
//   a constant FUNCTION    the derivation IS the source. Change the width and
//                          the table follows. This is the one to use.
//
// The table here is a fixed-point reciprocal, 1/x in Q(FRAC), which is what a
// fast divider or a normalizer needs -- see div_const.sv for the constant-divisor
// case and div_restoring.sv for the general one. Entry 0 is saturated because
// 1/0 has no representation.
//
// Note the assign-to-the-function-name style instead of `return`: Yosys's formal
// frontend rejects `return`, and elaboration-time functions are exactly the
// place that restriction bites. See docs/25.
//
// See docs/23-structural-design-techniques.md.
// -----------------------------------------------------------------------------
`default_nettype none

module rom_table #(
  parameter int unsigned AW   = 6,          // 2^AW entries
  parameter int unsigned FRAC = 12,         // fraction bits in the result
  parameter int unsigned DW   = FRAC + 1
) (
  input  var logic            clk,
  input  var logic            en,
  input  var logic [AW-1:0]   addr,
  output var logic [DW-1:0]   data
);

  // reciprocal(i) = round(2^FRAC / i), saturated at i == 0.
  function automatic logic [DW-1:0] recip(input int unsigned i);
    logic [63:0] num;
    if (i == 0) begin
      recip = '1;                                   // 1/0 -> saturate
    end else begin
      num   = (64'd1 << FRAC) + (64'(i) >> 1);      // +i/2 for round-to-nearest
      recip = DW'(num / 64'(i));
    end
  endfunction

  // The ROM. Each entry is a constant folded by the elaborator, so this is a
  // lookup table in LUTs or a block RAM -- never a divider.
  logic [DW-1:0] rom [0:(1<<AW)-1];
  for (genvar i = 0; i < (1 << AW); i++) begin : g_init
    // A localparam per entry makes the constant-ness explicit and keeps the
    // function call out of any runtime path.
    localparam logic [DW-1:0] E = recip(i);
    assign rom[i] = E;
  end

  always_ff @(posedge clk)
    if (en) data <= rom[addr];

endmodule

`default_nettype wire
