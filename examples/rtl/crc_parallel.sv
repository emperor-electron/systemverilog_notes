// -----------------------------------------------------------------------------
// crc_parallel.sv -- parallel (multi-bit-per-cycle) CRC.
//
// An LFSR is a shift register whose input is the XOR of selected taps. With a
// primitive polynomial it cycles through all 2^N - 1 nonzero states, which
// makes it a cheap pseudo-random source, a cheap counter (when you do not care
// about the order), and the basis of CRC and scrambler logic.
// -----------------------------------------------------------------------------
`default_nettype none

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
