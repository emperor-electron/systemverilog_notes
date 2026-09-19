// -----------------------------------------------------------------------------
// srl_delay.sv -- delay line written so that it maps to an FPGA SRL.
//
// THE PAYOFF
//   Xilinx LUTs can be configured as a 16- or 32-stage shift register (SRL16 /
//   SRL32E) -- ONE LUT for 16 or 32 stages of a 1-bit delay, instead of 16 or 32
//   flip-flops. A 32-bit bus delayed by 32 cycles is 1024 flops written the
//   obvious way, or 32 LUTs as an SRL. That is a 16-32x area reduction on what
//   is otherwise pure overhead. Intel/Altera has the equivalent in ALM shift
//   mode.
//
// THE THREE CONDITIONS, ALL OF WHICH ARE EASY TO BREAK
//   1. NO RESET. An SRL has no reset input. One `if (!rst_n) sr <= '0;` and the
//      tool must fall back to flip-flops. This is the usual reason an SRL does
//      not appear.
//   2. NO INTERMEDIATE TAPS. Only the last stage may be read. Reading sr[3] of
//      a 16-deep line forces the whole thing into flops (or splits it).
//   3. A SINGLE COMMON ENABLE, or none. Per-stage enables cannot map.
//
//   Condition 1 is the same rule as "reset the control path, not the data path"
//   from docs/21 -- reached from a completely different direction. A datapath
//   delay line needs no reset because the valid bit beside it carries the
//   meaning, and here that also buys a 16x area reduction.
//
// WHEN NOT TO USE IT
//   An SRL is not resettable and not readable mid-line, so it cannot hold state
//   you need to inspect or clear. Use pipe_delay (docs/21) when you need either.
//   On ASIC there is no SRL, and this degenerates to an ordinary shift register.
//
// See docs/23-structural-design-techniques.md.
// -----------------------------------------------------------------------------
`default_nettype none

module srl_delay #(
  parameter int unsigned WIDTH = 8,
  parameter int unsigned DEPTH = 16       // 16 or 32 map to one LUT per bit
) (
  input  var logic             clk,
  input  var logic             en,        // one common enable, or tie to 1
  input  var logic [WIDTH-1:0] din,
  output var logic [WIDTH-1:0] dout
);

  if (DEPTH == 0) begin : g_bypass
    assign dout = din;
  end else begin : g_srl
    // One independent shift register per bit. Each is a packed vector shifted
    // as a whole -- the pattern the SRL inference rule looks for.
    for (genvar b = 0; b < int'(WIDTH); b++) begin : g_bit
      logic [DEPTH-1:0] sr;
      // Deliberately NO reset in this always_ff. See condition 1 above.
      always_ff @(posedge clk)
        if (en) sr <= {sr[DEPTH-2:0], din[b]};
      // Only the last stage is read. See condition 2.
      assign dout[b] = sr[DEPTH-1];
    end
  end

endmodule

`default_nettype wire
