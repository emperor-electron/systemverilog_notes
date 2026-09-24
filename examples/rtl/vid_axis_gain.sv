// -----------------------------------------------------------------------------
// vid_axis_gain.sv -- per-component gain and offset, N pixels per clock.
//
// The introduction to the whole pattern. Every module in this family is built
// the same way and it is worth stating the shape once:
//
//   1. UNPACK the flat TDATA into an unpacked array with a generate loop.
//   2. Do the work on the array, where the indices mean something.
//   3. REPACK into flat TDATA with a generate loop.
//
// Steps 1 and 3 are pure renaming -- they are `assign`s on part-selects and cost
// nothing in hardware. What they buy is that step 2 never contains the
// expression `((n*P)+p)*B` and therefore cannot get it wrong.
//
//   logic [B-1:0] pix [N][P];        // the array that makes step 2 readable
//
// WHY NOT AN UNPACKED ARRAY ON THE PORT. Because the port is AXI-Stream TDATA,
// which is a flat vector by specification -- and because the Yosys frontend
// rejects unpacked array ports outright, which would put every module here
// outside the formal flow. Flatten at the boundary, structure on the inside.
//
// GENERATE LOOPS FOR STRUCTURE, PROCEDURAL LOOPS FOR REDUCTION. A `for` with a
// `genvar` outside a procedural block replicates hardware; a `for` inside an
// `always_comb` describes one lump of combinational logic. This module only
// needs the first kind. vid_axis_csc.sv needs both and shows the difference.
//
// ARITHMETIC. Gain is unsigned fixed point with GF fraction bits, so
// GAIN = (1 << GF) is unity. Offset is SIGNED in component units. The result is
// rounded half-up and then clamped to [0, 2^B-1]; video components are unsigned
// and a wrap is a black pixel where a white one belongs, which is far more
// visible than the clipping it replaces.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_gain #(
  parameter int unsigned N  = 2,    // PIXELS_PER_CLOCK
  parameter int unsigned P  = 3,    // COMPONENTS_PER_PIXEL
  parameter int unsigned B  = 8,    // BITS_PER_COMPONENT
  parameter int unsigned GW = 16,   // gain width
  parameter int unsigned GF = 8,    // gain fraction bits
  parameter int unsigned UW = 1,    // TUSER width
  // One gain and one offset per COMPONENT, not per pixel: the same correction
  // applies to every pixel in the beat. Packed parameter vectors, because an
  // unpacked array parameter cannot be overridden portably.
  parameter logic [P*GW-1:0]    GAIN   = {P{GW'(1) << GF}},
  parameter logic [P*(B+1)-1:0] OFFSET = '0
) (
  input  var logic              clk,
  input  var logic              rst_n,

  input  var logic [N*P*B-1:0]  s_tdata,
  input  var logic              s_tvalid,
  output var logic              s_tready,
  input  var logic              s_tlast,
  input  var logic [UW-1:0]     s_tuser,

  output var logic [N*P*B-1:0]  m_tdata,
  output var logic              m_tvalid,
  input  var logic              m_tready,
  output var logic              m_tlast,
  output var logic [UW-1:0]     m_tuser
);

  if (GF >= GW) begin : g_chk_gf
    $error("vid_axis_gain: GF (%0d) must be < GW (%0d)", GF, GW);
  end

  // Product of a GW-bit gain and a B-bit component, plus headroom for the
  // signed offset and the rounding term. Named, not open-coded, so the
  // saturation constants below cannot disagree with it.
  localparam int unsigned ACCW = GW + B + 2;
  localparam logic signed [ACCW-1:0] SAT_MAX = ACCW'((1 << B) - 1);

  // ---- 1. unpack -----------------------------------------------------------
  logic [B-1:0] pin  [N][P];
  logic [B-1:0] pout [N][P];

  for (genvar n = 0; n < int'(N); n++) begin : g_unpack_n
    for (genvar p = 0; p < int'(P); p++) begin : g_unpack_p
      assign pin[n][p] = s_tdata[vid_pkg::comp_lsb(n, p, P, B) +: B];
    end
  end

  // ---- 2. the work ---------------------------------------------------------
  for (genvar n = 0; n < int'(N); n++) begin : g_pix
    for (genvar p = 0; p < int'(P); p++) begin : g_comp
      logic signed [ACCW-1:0] prod, rounded, shifted;

      always_comb begin
        // Every operand widened to ACCW and signed BEFORE any arithmetic. A
        // single unsigned operand would make the whole expression unsigned and
        // turn the >>> below into a logical shift -- trap T6b in docs/17, and
        // the reason each step here has a name instead of being one line.
        prod = $signed({1'b0, GAIN[p*GW +: GW]}) * $signed({1'b0, pin[n][p]});
        prod = prod + ACCW'($signed(OFFSET[p*(B+1) +: (B+1)])) * ACCW'(1 << GF);

        rounded = prod + ((GF == 0) ? ACCW'(0) : (ACCW'(1) <<< (GF - 1)));
        shifted = rounded >>> GF;

        if      (shifted < 0)       pout[n][p] = '0;
        else if (shifted > SAT_MAX) pout[n][p] = B'(SAT_MAX);
        else                        pout[n][p] = shifted[B-1:0];
      end

`ifdef FORMAL
      // Saturation is the property worth proving, and it has to be stated where
      // the un-clamped value is visible: `shifted` is local to this generate
      // scope, and a hierarchical reference from a harness reads the wrong net
      // under the Yosys frontend (docs/25).
      //
      // The asserts are UNLABELLED on purpose. Inside a generate loop, Yosys
      // does not uniquify immediate-assertion labels by scope, so N*P copies of
      // a labelled assert collide with "cannot add procedural assertion ...
      // a cell with the same name was already created". sync_fifo.sv hits the
      // same limitation and solves it the same way. The cost is that a
      // counterexample names the cell rather than the property.
      //
      // Note what is NOT asserted: `pout[n][p] <= (1<<B)-1`. That is a
      // tautology -- pout is B bits wide and cannot hold anything else. The
      // real claim is that the clamp picked the right value.
      always @* begin
        assert (!(shifted < 0)       || (pout[n][p] == '0));
        assert (!(shifted > SAT_MAX) || (pout[n][p] == B'(SAT_MAX)));
        assert ((shifted < 0) || (shifted > SAT_MAX) ||
                (ACCW'($signed({1'b0, pout[n][p]})) == shifted));
      end
`endif
    end
  end

  // ---- 3. repack, into the output register ---------------------------------
  logic [N*P*B-1:0] packed_out;

  for (genvar n = 0; n < int'(N); n++) begin : g_pack_n
    for (genvar p = 0; p < int'(P); p++) begin : g_pack_p
      assign packed_out[vid_pkg::comp_lsb(n, p, P, B) +: B] = pout[n][p];
    end
  end

  // One register stage, full throughput. `s_tready` depends on `m_tready`
  // combinationally, which is legal (docs/30: it is VALID that may not depend on
  // READY) but does chain: a long string of these needs a skid_buffer somewhere
  // to break the ready path.
  assign s_tready = !m_tvalid || m_tready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_tvalid <= 1'b0;
      m_tdata  <= '0;
      m_tlast  <= 1'b0;
      m_tuser  <= '0;
    end else if (s_tvalid && s_tready) begin
      m_tvalid <= 1'b1;
      m_tdata  <= packed_out;
      m_tlast  <= s_tlast;
      m_tuser  <= s_tuser;
    end else if (m_tvalid && m_tready) begin
      m_tvalid <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata)
                                          && $stable(m_tlast)
                                          && $stable(m_tuser)));

`endif

endmodule

`default_nettype wire
