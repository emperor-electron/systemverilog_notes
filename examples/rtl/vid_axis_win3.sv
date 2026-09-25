// -----------------------------------------------------------------------------
// vid_axis_win3.sv -- turns R vertically-adjacent lines into an R x (N+2)
// sliding window, so that a 3-wide horizontal filter can be written as pure
// combinational logic downstream.
//
// vid_axis_line_buffer.sv solves the VERTICAL half of a neighbourhood filter:
// it presents R lines at the same horizontal position. This module solves the
// HORIZONTAL half, and the horizontal half is the awkward one, because at N
// pixels per clock the neighbours of a pixel are not all in the same beat:
//
//     beat k-1                beat k                  beat k+1
//   [ ... | p_{N-1} ]   [ p_0 | p_1 | ... | p_{N-1} ]   [ p_0 | ... ]
//            ^-- left neighbour       centre pixels        ^-- right neighbour
//            of p_0 of beat k                             of p_{N-1} of beat k
//
// So a 3-wide window over a beat needs ONE PIXEL from each of the neighbouring
// beats. The output is therefore N+2 columns wide, and column c of the window is
// the neighbourhood-centre for output pixel c-1.
//
// THE COST IS ONE BEAT OF LOOKAHEAD. The window for beat k cannot be built until
// beat k+1 has arrived, so this module holds a beat back and emits it when the
// next one shows up -- or immediately, if the held beat is the last of its line,
// because then the right neighbour is off the end of the line and is replicated
// instead. The steady-state rate is still one output beat per input beat; the
// only bubble is the first beat of the whole stream.
//
// That also means s_tready does not depend on s_tvalid, and the emit condition
// does. Deliberately: docs/30's rule is that VALID may not depend on READY, not
// the other way round.
//
// EDGES. Horizontal edge handling is `replicate` (clamp-to-edge), matching the
// line buffer's vertical EDGE_REPLICATE: column 0 repeats column 1 at the start
// of a line, and column N+1 repeats column N at the end. The alternative --
// zeros outside the image -- puts a dark frame around every picture, which a
// gradient filter turns into a bright outline around the whole image.
//
// The halo is copied A WHOLE PIXEL AT A TIME (`+: P*B`), with no loop over
// components. That is a direct payoff of the pixel-major layout in vid_pkg.sv: a
// pixel is a contiguous field, so moving one is a single part-select. Under a
// component-major layout this would be P separate copies per halo column.
//
// A WIDER WINDOW. For a 5-wide filter the halo is 2 pixels per side, which needs
// two pixels from each neighbouring beat -- available only if N >= 2. In general
// a halo of H pixels per side requires H <= N, or the window spans more than
// three beats and one beat of lookahead is no longer enough.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_win3 #(
  parameter int unsigned N  = 2,    // PIXELS_PER_CLOCK
  parameter int unsigned P  = 3,    // COMPONENTS_PER_PIXEL
  parameter int unsigned B  = 8,    // BITS_PER_COMPONENT
  parameter int unsigned R  = 3,    // rows in and out (= the line buffer's TAPS)
  parameter int unsigned UW = 1
) (
  input  var logic                      clk,
  input  var logic                      rst_n,

  // Row r at pixel n, component p:  rowpix_lsb(r, n, p, N, P, B)
  input  var logic [R*N*P*B-1:0]        s_rows,
  input  var logic                      s_tvalid,
  output var logic                      s_tready,
  input  var logic                      s_tlast,     // end of line
  input  var logic [UW-1:0]             s_tuser,

  // Row r at column c, component p:  rowpix_lsb(r, c, p, N+2, P, B)
  // Column c is the centre of the neighbourhood for output pixel c-1.
  output var logic [R*(N+2)*P*B-1:0]    m_win,
  output var logic                      m_tvalid,
  input  var logic                      m_tready,
  output var logic                      m_tlast,
  output var logic [UW-1:0]             m_tuser
);

  localparam int unsigned COLS  = vid_pkg::win_cols(N, 1);   // N + 2
  localparam int unsigned PIXB  = P * B;                     // bits per pixel
  localparam int unsigned WINB  = R * COLS * P * B;

  if (N < 1) begin : g_chk_n
    $error("vid_axis_win3: N must be >= 1");
  end

  // ---- the held beat -------------------------------------------------------
  logic [R*N*P*B-1:0] c_rows;
  logic               c_valid, c_first, c_last;
  logic [UW-1:0]      c_user;
  // Only the LAST PIXEL of each row of the previous beat is needed, not the
  // whole beat: the left halo is one pixel wide. R*P*B bits instead of R*N*P*B.
  logic [R*P*B-1:0]   l_pix;
  // Whether the next beat to be loaded starts a line. A beat is first-of-line
  // if the previously loaded beat carried TLAST -- tracked here rather than
  // derived from TUSER, because TUSER[0] marks the start of a FRAME.
  logic               in_first;

  logic out_ready, emit, load;

  assign out_ready = !m_tvalid || m_tready;
  assign s_tready  = !c_valid || out_ready;
  assign load      = s_tvalid && s_tready;
  // A held beat can be emitted once its right neighbour is known: either the
  // next beat is being offered, or the held beat ends the line and the neighbour
  // is replicated.
  assign emit      = c_valid && out_ready && (c_last || s_tvalid);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_rows   <= '0;
      c_valid  <= 1'b0;
      c_first  <= 1'b0;
      c_last   <= 1'b0;
      c_user   <= '0;
      l_pix    <= '0;
      in_first <= 1'b1;
    end else if (load) begin
      // `load` can only happen when the held beat is being emitted this cycle
      // or there is none, so this never overwrites unemitted data -- asserted
      // below rather than left to inspection.
      c_rows   <= s_rows;
      c_valid  <= 1'b1;
      c_first  <= in_first;
      c_last   <= s_tlast;
      c_user   <= s_tuser;
      in_first <= s_tlast;
      for (int r = 0; r < int'(R); r++)
        l_pix[r*PIXB +: PIXB] <=
          c_rows[vid_pkg::rowpix_lsb(r, N - 1, 0, N, P, B) +: PIXB];
    end else if (emit) begin
      c_valid  <= 1'b0;             // emitted with nothing to replace it
    end
  end

  // ---- build the window ----------------------------------------------------
  logic [WINB-1:0] win;

  for (genvar r = 0; r < int'(R); r++) begin : g_row
    // Column 0: the left halo. One pixel from the previous beat, or a copy of
    // this beat's pixel 0 at the start of a line.
    assign win[vid_pkg::rowpix_lsb(r, 0, 0, COLS, P, B) +: PIXB] =
      c_first ? c_rows[vid_pkg::rowpix_lsb(r, 0, 0, N, P, B) +: PIXB]
              : l_pix[r*PIXB +: PIXB];

    // Columns 1..N: the held beat, unchanged. Pure renaming.
    for (genvar n = 0; n < int'(N); n++) begin : g_col
      assign win[vid_pkg::rowpix_lsb(r, n + 1, 0, COLS, P, B) +: PIXB] =
        c_rows[vid_pkg::rowpix_lsb(r, n, 0, N, P, B) +: PIXB];
    end

    // Column N+1: the right halo. The first pixel of the beat being offered, or
    // a copy of this beat's last pixel at the end of a line.
    assign win[vid_pkg::rowpix_lsb(r, N + 1, 0, COLS, P, B) +: PIXB] =
      c_last ? c_rows[vid_pkg::rowpix_lsb(r, N - 1, 0, N, P, B) +: PIXB]
             : s_rows[vid_pkg::rowpix_lsb(r, 0,     0, N, P, B) +: PIXB];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_tvalid <= 1'b0;
      m_win    <= '0;
      m_tlast  <= 1'b0;
      m_tuser  <= '0;
    end else if (emit) begin
      m_tvalid <= 1'b1;
      m_win    <= win;
      m_tlast  <= c_last;
      m_tuser  <= c_user;
    end else if (m_tvalid && m_tready) begin
      m_tvalid <= 1'b0;
    end
  end

`ifdef FORMAL
  // The safety property of the holding register: a beat is never loaded over a
  // beat that has not been emitted.
  always @* begin
    assert (!(load && c_valid) || emit);
  end

  // Flow accounting, with the counters INSIDE the module beside the state they
  // account for. A harness-side counter cannot see `c_valid`, so induction has
  // to guess the relationship between the two and the proof comes back UNKNOWN
  // -- the lesson axil_slave_fv and axis_upsizer_fv both taught. See docs/25.
  //
  // Free-running and allowed to wrap, so the property is a DIFFERENCE rather than
  // a comparison -- and an EXACT one. `(f_n_in - f_n_out) <= 2` is true but does
  // not close under induction: from an arbitrary state the solver is free to put
  // the counters two apart with nothing in flight, and then one more beat breaks
  // the bound. Saying exactly where every beat in flight is -- the held beat, the
  // output register, or nowhere -- is state-local, so induction can carry it, and
  // it implies the bound. Measured: with the bound alone, `prove` returns
  // UNKNOWN; with the equality it passes.
  logic [5:0] f_n_in, f_n_out;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_n_in  <= '0;
      f_n_out <= '0;
    end else begin
      if (load)                 f_n_in  <= f_n_in  + 1'b1;
      if (m_tvalid && m_tready) f_n_out <= f_n_out + 1'b1;
    end
  end

  always @* begin
    assert ((f_n_in - f_n_out) == (6'(c_valid) + 6'(m_tvalid)));
  end

  // Halo replication, per row. Unlabelled: Yosys does not uniquify immediate
  // assertion labels by generate scope. The same two properties are stated again
  // as concurrent assertions below for XSIM, which cannot read these -- two
  // statements of one property, which is the standing cost of the dual-dialect
  // convention (docs/31).
  for (genvar r = 0; r < int'(R); r++) begin : g_fv_row
    always @* begin
      assert (!(emit && c_first) ||
              (win[vid_pkg::rowpix_lsb(r, 0, 0, COLS, P, B) +: PIXB] ==
               win[vid_pkg::rowpix_lsb(r, 1, 0, COLS, P, B) +: PIXB]));
      assert (!(emit && c_last) ||
              (win[vid_pkg::rowpix_lsb(r, COLS - 1, 0, COLS, P, B) +: PIXB] ==
               win[vid_pkg::rowpix_lsb(r, COLS - 2, 0, COLS, P, B) +: PIXB]));
    end
  end
`endif

`ifndef SYNTHESIS
  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_win)
                                          && $stable(m_tlast)
                                          && $stable(m_tuser)));

  a_no_overwrite: assert property (@(posedge clk) disable iff (!rst_n)
    (load && c_valid) |-> emit)
    else $error("win3: loaded over a beat that was never emitted");

  // Edge replication, stated once per row. These are CONCURRENT assertions in a
  // generate loop, which is fine: XSIM uniquifies them by generate scope. It is
  // IMMEDIATE assertions inside a generate loop that collide under Yosys, which
  // is why the `ifdef FORMAL` block above keeps its asserts at module level.
  for (genvar r = 0; r < int'(R); r++) begin : g_a_row
    a_left_replicated: assert property (@(posedge clk) disable iff (!rst_n)
      (emit && c_first) |->
        (win[vid_pkg::rowpix_lsb(r, 0, 0, COLS, P, B) +: PIXB] ==
         win[vid_pkg::rowpix_lsb(r, 1, 0, COLS, P, B) +: PIXB]));

    a_right_replicated: assert property (@(posedge clk) disable iff (!rst_n)
      (emit && c_last) |->
        (win[vid_pkg::rowpix_lsb(r, COLS - 1, 0, COLS, P, B) +: PIXB] ==
         win[vid_pkg::rowpix_lsb(r, COLS - 2, 0, COLS, P, B) +: PIXB]));
  end
`endif

endmodule

`default_nettype wire
