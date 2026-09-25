// -----------------------------------------------------------------------------
// vid_axis_median3.sv -- 3x3 median filter, N pixels per clock, applied
// independently to each of the P components.
//
// The standard salt-and-pepper denoiser, and the standard example of a filter
// that is NOT a convolution: there is no kernel and no arithmetic, only
// comparisons. Which makes it the cleanest possible illustration of the pattern
// in this family, because nothing in it can be confused with the multiplier
// array in vid_axis_csc.sv.
//
//   vid_axis_line_buffer  ->  vid_axis_win3  ->  THIS
//    (3 lines in parallel)     (3 x (N+2) window)   (N*P median networks)
//
// WHAT THE GENERATE NEST BUILDS. Two levels, N * P instances of median9_net:
//
//     g_pix[0].g_comp[0].u_med    g_pix[0].g_comp[1].u_med  ...
//     g_pix[1].g_comp[0].u_med    g_pix[1].g_comp[1].u_med  ...
//
// At N=4, P=3, B=10 that is 12 instances, 228 comparators, all in parallel and
// all in one clock cycle. The cost of a neighbourhood filter scales with N*P and
// the arithmetic does not get cheaper with parameters -- which is the honest
// reason to care what N is before choosing it.
//
// PER COMPONENT, NOT PER PIXEL. Each component is filtered independently, so an
// output pixel can be a mixture of components from different input pixels. That
// is the conventional (marginal) median and what every image-processing library
// does; the alternative -- a vector median that picks the input pixel minimising
// total distance to the others -- preserves colours exactly but costs P
// multiplies per pair and is a different module.
//
// THE ROW ORDER DOES NOT MATTER HERE. A median is invariant under permutation of
// its inputs, so it makes no difference which window row is the top line. That
// is NOT true of vid_axis_sobel.sv, where swapping two rows changes the sign of
// the vertical gradient -- the same window, read by two filters with different
// sensitivity to its layout.
//
// LATENCY AND TIMING. One register stage, and the network is six comparators
// deep. That is the obvious place this block runs out of timing at high pixel
// rates; the natural cut is after the three row sorts inside median9_net, which
// splits it into 3 + 3 levels. Left unpipelined here because the shape of the
// generate nest is the point, and a pipeline register inside it would double the
// module's length.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_median3 #(
  parameter int unsigned N  = 2,    // PIXELS_PER_CLOCK
  parameter int unsigned P  = 3,    // COMPONENTS_PER_PIXEL
  parameter int unsigned B  = 8,    // BITS_PER_COMPONENT
  parameter int unsigned R  = 3,    // rows in the window; rows 0..2 are used
  parameter int unsigned UW = 1
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

  localparam int unsigned COLS = vid_pkg::win_cols(N, 1);    // N + 2

  if (R < 3) begin : g_chk_r
    $error("vid_axis_median3: R must be >= 3, got %0d", R);
  end

  logic [B-1:0] pout [N][P];

  // ---- N*P median networks -------------------------------------------------
  for (genvar n = 0; n < int'(N); n++) begin : g_pix
    for (genvar p = 0; p < int'(P); p++) begin : g_comp

      // The 3x3 neighbourhood of output pixel n: window columns n, n+1, n+2,
      // centred on column n+1. Gathering it is pure renaming again -- the
      // indexing expression appears here and nowhere else in the module.
      logic [9*B-1:0] patch;

      for (genvar r = 0; r < 3; r++) begin : g_prow
        for (genvar c = 0; c < 3; c++) begin : g_pcol
          assign patch[((r * 3) + c)*B +: B] =
            s_win[vid_pkg::rowpix_lsb(r, n + c, p, COLS, P, B) +: B];
        end
      end

      median9_net #(.W(B)) u_med (.din(patch), .med(pout[n][p]));
    end
  end

  // ---- repack --------------------------------------------------------------
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

`ifndef SYNTHESIS
  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata)
                                          && $stable(m_tlast)
                                          && $stable(m_tuser)));

  // A flat neighbourhood must come out unchanged: the median of nine equal
  // values is that value. This catches a window index that reaches outside the
  // 3x3 patch -- which a check against a software model only catches if the
  // model was written with different indices.
  //
  // WHY THIS USES TWO SHADOW REGISTERS AND NOT $past. The natural form,
  //
  //   (accepted && flat(s_win)) |=> (m_tdata == {(N*P){$past(s_win[0 +: B])}})
  //
  // FAILS under XSIM on a design that is provably correct. $past of a PART-SELECT
  // of a wide vector returns a value that is neither the previous sample, the
  // current one, nor two back -- measured, with a minimal reproducer, in
  // docs/37 section 13. $past of a whole vector is fine; a slice of one is not.
  // Two ordinary registers say the same thing and cannot be mis-sampled.
  logic         flat_q;
  logic [B-1:0] flat_val_q;

  always_ff @(posedge clk) begin
    flat_q     <= s_tvalid && s_tready && (s_win == {(R*COLS*P){s_win[0 +: B]}});
    flat_val_q <= s_win[0 +: B];
  end

  a_flat_passes: assert property (@(posedge clk) disable iff (!rst_n)
    flat_q |-> (m_tdata == {(N*P){flat_val_q}}))
    else $error("median3: a flat window did not pass through unchanged: %h",
                m_tdata);

`endif

endmodule

`default_nettype wire
