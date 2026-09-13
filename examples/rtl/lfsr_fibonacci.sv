// -----------------------------------------------------------------------------
// lfsr_fibonacci.sv -- Fibonacci-form LFSR.
//
// An LFSR is a shift register whose input is the XOR of selected taps. With a
// primitive polynomial it cycles through all 2^N - 1 nonzero states, which
// makes it a cheap pseudo-random source, a cheap counter (when you do not care
// about the order), and the basis of CRC and scrambler logic.
// -----------------------------------------------------------------------------
`default_nettype none

// --- Fibonacci LFSR ----------------------------------------------------------
module lfsr_fibonacci #(
  parameter int unsigned  W    = 8,
  parameter logic [W-1:0] TAPS = 8'b1011_1000,  // x^8+x^6+x^5+x^4+1
  parameter logic [W-1:0] SEED = 8'h1
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         en,
  output var logic [W-1:0] state
);
  logic fb;
  assign fb = ^(state & TAPS);     // reduction XOR of the tapped bits

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)  state <= SEED;
    else if (en) state <= {fb, state[W-1:1]};
  end
endmodule


// --- Parallel CRC ------------------------------------------------------------
// Processes DW bits per cycle. The trick: the bit-serial CRC step is linear
// over GF(2), so DW serial steps can be unrolled into one lump of XOR logic at
// elaboration time. The `for` loop below IS that unrolling -- the synthesized
// result is a two-level XOR network, not a shift register.

`default_nettype wire
