// -----------------------------------------------------------------------------
// lfsr_galois.sv -- Galois-form LFSR (one XOR on the critical path).
//
// An LFSR is a shift register whose input is the XOR of selected taps. With a
// primitive polynomial it cycles through all 2^N - 1 nonzero states, which
// makes it a cheap pseudo-random source, a cheap counter (when you do not care
// about the order), and the basis of CRC and scrambler logic.
// -----------------------------------------------------------------------------
`default_nettype none

// --- Galois LFSR -------------------------------------------------------------
// Galois form puts the XORs INSIDE the shift chain, so the critical path is one
// XOR regardless of how many taps there are. Prefer it over the Fibonacci form
// (which XORs all taps into the input) for wide, fast LFSRs.
module lfsr_galois #(
  parameter int unsigned   W    = 16,
  parameter logic [W-1:0]  POLY = 16'hD008,   // x^16+x^15+x^13+x^4+1, maximal
  parameter logic [W-1:0]  SEED = 16'h1
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         en,
  output var logic [W-1:0] state,
  output var logic         bit_out
);
  assign bit_out = state[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     state <= SEED;             // must be nonzero: 0 is a fixed point
    else if (en)    state <= state[0] ? ((state >> 1) ^ POLY) : (state >> 1);
  end

`ifndef SYNTHESIS
  a_never_zero: assert property (@(posedge clk) disable iff (!rst_n)
                                 state != '0)
    else $error("lfsr_galois: locked up at zero");
`endif
endmodule

`default_nettype wire
