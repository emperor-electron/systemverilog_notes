// -----------------------------------------------------------------------------
// vid_axis_sobel.sv -- 3x3 Sobel gradient magnitude, N pixels per clock.
//
//   Gx = | -1  0  +1 |      Gy = | -1  -2  -1 |      out = |Gx| + |Gy|
//        | -2  0  +2 |           |  0   0   0 |
//        | -1  0  +1 |           | +1  +2  +1 |
//
// The complement of vid_axis_median3.sv: same window, same generate-loop shape,
// and every design decision different because this one is a convolution.
//
// THE LOOP NEST MIRRORS THE DATAFLOW, NOT THE DATA LAYOUT. vid_axis_csc.sv has
// N*P engines, because it produces P output components per pixel. This module has
// N engines, because a gradient is a single number per pixel: it reads ONE
// component (GRAD_COMP) and writes the result to all P outputs. Choosing the
// nest by copying the previous module would give N*P copies of identical logic
// and P times the area for nothing.
//
// WHY THE RESULT GOES TO ALL P COMPONENTS. It keeps the stream's shape -- still
// N pixels of P components of B bits -- so nothing downstream has to be
// reconfigured to display, encode or write out the result. A single-component
// output would be a different bus geometry and a second configuration of every
// block after it. The picture is grey, which is what an edge map is.
//
// L1 INSTEAD OF SQRT. The true magnitude is sqrt(Gx^2 + Gy^2). |Gx| + |Gy| needs
// no multiplier and no square root and is exact on the axes, but it
// OVERESTIMATES -- by up to sqrt(2), 41%, at 45 degrees where equal horizontal
// and vertical edges meet. max(|Gx|,|Gy|) errs the other way, 29% low on the same
// diagonal; max + min/2 is within about 12% for one shift and one add. Any of
// them is fine behind a threshold tuned with it in place, and all of them are
// wrong if the number is reported as a magnitude. See docs/18 on choosing an
// approximation and then stating its error.
//
// WIDTHS, computed and not guessed. Each gradient sums three terms weighted
// 1,2,1 with opposite signs, so |Gx| <= 4*(2^B - 1) < 2^(B+2), which needs B+3
// bits SIGNED; |Gx| + |Gy| <= 8*(2^B - 1) < 2^(B+3), which fits in B+3 bits
// UNSIGNED. One expression, two different meanings of the same width -- and the
// reason both are named below rather than written as B+3 in six places.
//
// SHIFT. With SHIFT=0 any edge of more than a quarter scale saturates, which
// makes a usable but blown-out edge map. SHIFT=2 or 3 keeps the whole range and
// is what a real pipeline uses. Thresholding is deliberately NOT here: it is one
// comparison, it belongs with whatever consumes the edge map, and building it in
// would force this module to carry a threshold register and its programming.
//
// ROW ORDER AND THE SIGN OF Gy. Window row 0 is the newest line, row 2 the
// oldest -- so row 2 is the TOP of the picture and the Gy computed below is
// negated relative to the kernel above. It does not matter, because the output is
// |Gy|. It would matter for a gradient DIRECTION output, which is the usual way
// this gets found out.
//
// THE OUTPUT IS CENTRED ON THE MIDDLE ROW, one line above the beat that produced
// it. A Sobel pipeline built on a 3-tap line buffer therefore shifts the picture
// down by one line unless the sideband is re-timed to match; docs/21.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_sobel #(
  parameter int unsigned N         = 2,   // PIXELS_PER_CLOCK
  parameter int unsigned P         = 3,   // COMPONENTS_PER_PIXEL
  parameter int unsigned B         = 8,   // BITS_PER_COMPONENT
  parameter int unsigned R         = 3,   // rows in the window; rows 0..2 used
  parameter int unsigned GRAD_COMP = 0,   // which component the gradient reads
  parameter int unsigned SHIFT     = 0,   // right shift applied to |Gx|+|Gy|
  parameter int unsigned UW        = 1
) (
  input  var logic                    clk,
  input  var logic                    rst_n,

  input  var logic [R*(N+2)*P*B-1:0]  s_win,     // from vid_axis_win3
  input  var logic                    s_tvalid,
  output var logic                    s_tready,
  input  var logic                    s_tlast,
  input  var logic [UW-1:0]           s_tuser,

  output var logic [N*P*B-1:0]        m_tdata,
  output var logic                    m_tvalid,
  input  var logic                    m_tready,
  output var logic                    m_tlast,
  output var logic [UW-1:0]           m_tuser
);

  localparam int unsigned COLS  = vid_pkg::win_cols(N, 1);   // N + 2
  localparam int unsigned GRADW = B + 3;                     // signed gradient
  localparam int unsigned MAGW  = B + 3;                     // unsigned |x|+|y|
  localparam logic [MAGW-1:0] MAG_MAX = MAGW'((1 << B) - 1);

  if (R < 3) begin : g_chk_r
    $error("vid_axis_sobel: R must be >= 3, got %0d", R);
  end
  if (GRAD_COMP >= P) begin : g_chk_comp
    $error("vid_axis_sobel: GRAD_COMP (%0d) must be < P (%0d)", GRAD_COMP, P);
  end

  logic [B-1:0] mag [N];

`ifdef FORMAL
  // Premises about the WINDOW for the orientation assertions below, written with
  // whole-row slices and no per-tap indexing at all -- so they cannot share a
  // mistake with the gather inside the generate loop.
  //
  // THAT INDEPENDENCE IS THE WHOLE POINT, and it was learned the hard way: the
  // first version of those assertions stated its premises on the internal taps
  // w[r][c], and a design with the row and column indices EXCHANGED passed them
  // without complaint. Of course it did -- "w row-constant implies gy == 0" is a
  // property of the arithmetic downstream of the gather, and says nothing about
  // how w was filled. A property whose premise reaches the input through the same
  // expression as the data path cannot test that expression.
  localparam int unsigned ROWB = COLS * P * B;       // bits in one window row

  logic f_rows_same, f_cols_same;

  always_comb begin
    // All three window rows bit-identical: the picture is constant vertically,
    // so a vertical gradient must be zero.
    f_rows_same = (s_win[0*ROWB +: ROWB] == s_win[1*ROWB +: ROWB])
               && (s_win[1*ROWB +: ROWB] == s_win[2*ROWB +: ROWB]);

    // Each row is one pixel repeated: constant horizontally, so a horizontal
    // gradient must be zero. Rows may still differ from each other.
    f_cols_same = 1'b1;
    for (int r = 0; r < 3; r++)
      if (s_win[r*ROWB +: ROWB] != {COLS{s_win[r*ROWB +: P*B]}})
        f_cols_same = 1'b0;
  end
`endif

  // ---- N gradient engines --------------------------------------------------
  for (genvar n = 0; n < int'(N); n++) begin : g_pix

    // The 3x3 patch of the gradient component, widened and signed once, here.
    // Naming the nine taps is not decoration: the kernel below then reads like
    // the kernel, and the one place that can get the indexing wrong is this
    // loop rather than eighteen terms of arithmetic.
    logic signed [GRADW-1:0] w [3][3];

    for (genvar r = 0; r < 3; r++) begin : g_prow
      for (genvar c = 0; c < 3; c++) begin : g_pcol
        // {1'b0, ...} first: a B-bit component is UNSIGNED, and $signed() of it
        // alone would read its top bit as a sign and make bright pixels
        // negative. docs/17 trap T6b.
        assign w[r][c] = GRADW'($signed({1'b0,
          s_win[vid_pkg::rowpix_lsb(r, n + c, GRAD_COMP, COLS, P, B) +: B]}));
      end
    end

    logic signed [GRADW-1:0] gx, gy;
    logic        [MAGW-1:0]  ax, ay, sum, scaled;

    always_comb begin
      // Right column minus left column, centre row weighted double.
      gx = (w[0][2] + (w[1][2] <<< 1) + w[2][2])
         - (w[0][0] + (w[1][0] <<< 1) + w[2][0]);
      // Row 0 minus row 2 -- the picture's bottom minus its top, so this is -Gy
      // of the kernel in the header. |Gy| is what is used, so it cancels.
      gy = (w[0][0] + (w[0][1] <<< 1) + w[0][2])
         - (w[2][0] + (w[2][1] <<< 1) + w[2][2]);

      // |x| by negating the signed value, then reinterpreting as unsigned. The
      // negation cannot overflow: GRADW was sized so that |gx| has a bit spare.
      ax = MAGW'($unsigned((gx < 0) ? -gx : gx));
      ay = MAGW'($unsigned((gy < 0) ? -gy : gy));

      sum    = ax + ay;                    // fits: see the width note above
      scaled = sum >> SHIFT;               // unsigned, so a logical shift is right
      mag[n] = (scaled > MAG_MAX) ? B'(MAG_MAX) : scaled[B-1:0];
    end

`ifdef FORMAL
    // Unlabelled inside a generate loop: Yosys does not uniquify immediate
    // assertion labels by scope and N copies would collide. vid_axis_gain.sv
    // hits the same limitation.
    always @* begin
      // A flat patch has no gradient. Stated on the internal taps, where a
      // window-indexing mistake is still visible.
      assert (!((w[0][0] == w[0][1]) && (w[0][1] == w[0][2]) &&
                (w[1][0] == w[1][1]) && (w[1][1] == w[1][2]) &&
                (w[2][0] == w[2][1]) && (w[2][1] == w[2][2]) &&
                (w[0][0] == w[1][0]) && (w[1][0] == w[2][0]))
              || (mag[n] == '0));
      // ORIENTATION. The only properties here that can catch a TRANSPOSED
      // window index -- and they are needed because the OUTPUT cannot. The two
      // Sobel kernels are each other's transpose, so |Gx| + |Gy| is unchanged by
      // transposing the patch: reading w[c][r] instead of w[r][c] produces
      // exactly the same magnitude for every possible input, and no test applied
      // to m_tdata can ever see it. The pre-saturation gradients can.
      //
      // The premises are f_rows_same / f_cols_same, computed at module level from
      // whole-row SLICES of s_win. That independence is the point; see the note
      // there.
      assert (!f_rows_same || (gy == '0));
      assert (!f_cols_same || (gx == '0));

      // The saturation is a clamp, not a wrap.
      assert (!(scaled > MAG_MAX) || (mag[n] == B'(MAG_MAX)));
      assert ((scaled > MAG_MAX) || (MAGW'(mag[n]) == scaled));
    end
`endif
  end

  // ---- repack: one magnitude to all P components ---------------------------
  logic [N*P*B-1:0] packed_out;

  for (genvar n = 0; n < int'(N); n++) begin : g_pack_n
    for (genvar p = 0; p < int'(P); p++) begin : g_pack_p
      assign packed_out[vid_pkg::comp_lsb(n, p, P, B) +: B] = mag[n];
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

`ifndef SYNTHESIS
  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata)
                                          && $stable(m_tlast)
                                          && $stable(m_tuser)));

  // Every component of an output pixel carries the same magnitude: the picture
  // is grey. Cheap, and it catches a repack loop that indexed the wrong pixel.
  for (genvar n = 0; n < int'(N); n++) begin : g_a_pix
    a_grey: assert property (@(posedge clk) disable iff (!rst_n)
      m_tvalid |-> (m_tdata[vid_pkg::comp_lsb(n, 0, P, B) +: B] ==
                    m_tdata[vid_pkg::comp_lsb(n, P - 1, P, B) +: B]));
  end
`endif

endmodule

`default_nettype wire
