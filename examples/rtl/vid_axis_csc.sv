// -----------------------------------------------------------------------------
// vid_axis_csc.sv -- colour-space conversion: a P x P matrix applied to N pixels
// per clock, with runtime-programmable coefficients.
//
//     out[o]  =  clamp( ( SUM over i of  coef[o][i] * in[i] )  +  offset[o] )
//
// RGB to YCbCr, YCbCr to RGB, RGB to greyscale, a channel swap and a full 3x3
// colour correction are all the same arithmetic with different numbers -- which
// is why the coefficients are INPUTS here, not parameters. A real pipeline
// switches between BT.601 and BT.709 at run time, and a design that bakes the
// matrix into parameters needs two copies of the multiplier array to do it.
//
// THIS IS THE MODULE THAT SHOWS BOTH KINDS OF LOOP, and the distinction is the
// single most useful thing to take from this family:
//
//   GENERATE loops (genvar, outside a procedural block) REPLICATE HARDWARE.
//   Here there are two nested levels of them: one per pixel (N) and one per
//   output component (P). That is N*P independent dot-product engines, and they
//   exist simultaneously.
//
//   PROCEDURAL loops (inside always_comb) DESCRIBE ONE LUMP OF LOGIC. The sum
//   over the P input components is a procedural loop, because it is a reduction
//   producing a single value -- an adder tree, not P copies of anything.
//
// Getting these the wrong way round is the classic error. A genvar loop cannot
// accumulate, because each iteration is a separate scope with its own
// declarations; a procedural loop over pixels would try to assign the same
// variable N times and describe only the last one.
//
// COEFFICIENT LAYOUT is row-major and deliberately the same shape as the pixel
// layout in vid_pkg.sv, so there is one indexing rule in the design and not two:
//
//     coef[o][i]  at  ((o * P) + i) * CW
//
// WIDTHS. The accumulator has to hold P products of a CW-bit signed coefficient
// and a B-bit unsigned component, plus the offset. That is CW + B + ceil(log2 P)
// bits plus a sign bit, and ACCW below is computed rather than guessed -- an
// accumulator one bit short is a wrap that looks exactly like a colour shift.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_csc #(
  parameter int unsigned N  = 2,    // PIXELS_PER_CLOCK
  parameter int unsigned P  = 3,    // COMPONENTS_PER_PIXEL
  parameter int unsigned B  = 8,    // BITS_PER_COMPONENT
  parameter int unsigned CW = 18,   // coefficient width, signed
  parameter int unsigned CF = 12,   // coefficient fraction bits
  parameter int unsigned UW = 1     // TUSER width
) (
  input  var logic                clk,
  input  var logic                rst_n,

  // Programming. Held stable while data flows; this module does not double
  // buffer, so change them between frames (see the note at the bottom).
  input  var logic [P*P*CW-1:0]   coef,      // signed, CF fraction bits
  input  var logic [P*CW-1:0]     offset,    // signed, CF fraction bits

  input  var logic [N*P*B-1:0]    s_tdata,
  input  var logic                s_tvalid,
  output var logic                s_tready,
  input  var logic                s_tlast,
  input  var logic [UW-1:0]       s_tuser,

  output var logic [N*P*B-1:0]    m_tdata,
  output var logic                m_tvalid,
  input  var logic                m_tready,
  output var logic                m_tlast,
  output var logic [UW-1:0]       m_tuser
);

  if (CF >= CW) begin : g_chk_cf
    $error("vid_axis_csc: CF (%0d) must be < CW (%0d)", CF, CW);
  end
  if (P < 1) begin : g_chk_p
    $error("vid_axis_csc: P must be >= 1");
  end

  // Growth from summing P products, computed rather than assumed.
  localparam int unsigned PSUM = (P <= 1) ? 1 : $clog2(P);
  localparam int unsigned ACCW = CW + B + PSUM + 2;
  localparam logic signed [ACCW-1:0] SAT_MAX = ACCW'((1 << B) - 1);

  // ---- 1. unpack -----------------------------------------------------------
  logic [B-1:0] pin  [N][P];
  logic [B-1:0] pout [N][P];

  for (genvar n = 0; n < int'(N); n++) begin : g_unpack_n
    for (genvar p = 0; p < int'(P); p++) begin : g_unpack_p
      assign pin[n][p] = s_tdata[vid_pkg::comp_lsb(n, p, P, B) +: B];
    end
  end

  // ---- 2. N*P dot products -------------------------------------------------
  for (genvar n = 0; n < int'(N); n++) begin : g_pix
    for (genvar o = 0; o < int'(P); o++) begin : g_out_comp

      logic signed [ACCW-1:0] acc, rounded, shifted;

      always_comb begin
        // The reduction. A procedural loop, so this is ONE adder tree per
        // (pixel, output component) -- not P pieces of hardware.
        acc = ACCW'($signed(offset[o*CW +: CW]));
        for (int i = 0; i < int'(P); i++) begin
          acc = acc + (ACCW'($signed(coef[vid_pkg::comp_lsb(o, i, P, CW) +: CW]))
                       * ACCW'($signed({1'b0, pin[n][i]})));
        end

        // Round half away from zero, then clamp. Both operands are already
        // ACCW-wide and signed, so >>> is arithmetic -- see docs/17 trap T6b for
        // what one unsigned operand would do to this expression.
        rounded = acc + ((CF == 0) ? ACCW'(0) : (ACCW'(1) <<< (CF - 1)));
        shifted = rounded >>> CF;

        if      (shifted < 0)       pout[n][o] = '0;
        else if (shifted > SAT_MAX) pout[n][o] = B'(SAT_MAX);
        else                        pout[n][o] = shifted[B-1:0];
      end

`ifdef FORMAL
      // Unlabelled: inside a generate loop Yosys does not uniquify immediate
      // assertion labels, and N*P labelled copies collide. See vid_axis_gain.sv.
      always @* begin
        assert (!(shifted < 0)       || (pout[n][o] == '0));
        assert (!(shifted > SAT_MAX) || (pout[n][o] == B'(SAT_MAX)));
        assert ((shifted < 0) || (shifted > SAT_MAX) ||
                (ACCW'($signed({1'b0, pout[n][o]})) == shifted));
      end
`endif
    end
  end

  // ---- 3. repack -----------------------------------------------------------
  logic [N*P*B-1:0] packed_out;

  for (genvar n = 0; n < int'(N); n++) begin : g_pack_n
    for (genvar p = 0; p < int'(P); p++) begin : g_pack_p
      assign packed_out[vid_pkg::comp_lsb(n, p, P, B) +: B] = pout[n][p];
    end
  end

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

  // COEFFICIENT UPDATES ARE NOT DOUBLE BUFFERED. Changing `coef` mid-frame
  // converts the rest of that frame with the new matrix, which is visible as a
  // horizontal seam. A production block latches the programmed values on
  // TUSER[0] (start of frame); that is deliberately left out here because it is
  // a register-bank concern -- csr_bank.sv plus a shadow register on SOF -- and
  // adding it would obscure the arithmetic this module exists to show.

`ifndef SYNTHESIS
  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata)
                                          && $stable(m_tlast)
                                          && $stable(m_tuser)));
`endif

endmodule

`default_nettype wire
