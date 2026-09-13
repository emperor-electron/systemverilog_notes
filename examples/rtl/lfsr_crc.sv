// -----------------------------------------------------------------------------
// lfsr_crc.sv -- Fibonacci/Galois LFSRs and a parallel (multi-bit) CRC.
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
module crc_parallel #(
  parameter int unsigned  DW   = 8,
  parameter int unsigned  CW   = 32,
  parameter logic [CW-1:0] POLY = 32'h04C1_1DB7,  // CRC-32 (IEEE 802.3)
  parameter logic [CW-1:0] INIT = 32'hFFFF_FFFF,
  parameter bit            REFIN  = 1'b1,   // reflect input bytes
  parameter bit            REFOUT = 1'b1,   // reflect the output
  parameter logic [CW-1:0] XOROUT = 32'hFFFF_FFFF
) (
  input  var logic           clk,
  input  var logic           rst_n,
  input  var logic           init,          // reload INIT
  input  var logic           en,
  input  var logic [DW-1:0]  data,
  output var logic [CW-1:0]  crc,           // raw register value
  output var logic [CW-1:0]  crc_out        // reflected + XORed final value
);

  function automatic logic [CW-1:0] crc_step(input logic [CW-1:0] c,
                                             input logic          b);
    // One bit: shift left, XOR the polynomial if the outgoing MSB differs.
    return (c[CW-1] ^ b) ? ((c << 1) ^ POLY) : (c << 1);
  endfunction

  function automatic logic [CW-1:0] crc_block(input logic [CW-1:0] c,
                                              input logic [DW-1:0] d);
    logic [CW-1:0] acc = c;
    for (int i = 0; i < int'(DW); i++)
      acc = crc_step(acc, REFIN ? d[i] : d[DW-1-i]);
    return acc;
  endfunction

  function automatic logic [CW-1:0] reflect(input logic [CW-1:0] v);
    logic [CW-1:0] r;
    for (int i = 0; i < int'(CW); i++) r[i] = v[CW-1-i];
    return r;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)      crc <= INIT;
    else if (init)   crc <= INIT;
    else if (en)     crc <= crc_block(crc, data);
  end

  assign crc_out = (REFOUT ? reflect(crc) : crc) ^ XOROUT;

endmodule

`default_nettype wire
