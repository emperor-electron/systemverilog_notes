// -----------------------------------------------------------------------------
// video_filter_tb.sv -- the whole neighbourhood-filter pipeline, end to end:
//
//   frame source -> vid_axis_line_buffer -> vid_axis_win3 -> vid_axis_median3
//                    (3 lines in parallel)   (3x(N+2) window)  vid_axis_sobel
//
// Both filters are driven from the SAME window, which is the point of splitting
// the window builder out: the expensive part (a line of memory per tap) is paid
// once no matter how many filters read it.
//
// WHAT IS BEING TESTED IS THE GEOMETRY, and geometry is a claim about a whole
// frame -- which line, which column, which edge -- so the reference here is a
// software model of the frame with clamp-to-edge addressing. Per-beat invariants
// (the halo is replicated, a beat is never overwritten, a flat patch has no
// gradient) are asserted inside the modules instead, where they can also be
// proved; see formal/median9_net_fv.sby and formal/vid_axis_sobel_fv.sby.
//
// FIVE PASSES, and the last three do not use the reference model at all:
//
//   0  random frame, no backpressure       against the model
//   1  random frame, random backpressure   against the model
//   2  flat frame                          median passes it; sobel outputs zero
//   3  salt and pepper on a flat field     every impulse removed
//   4  vertical step edge                  sobel lights exactly the two columns
//                                          either side of the step
//
// Pass 3 is the filter's actual job stated without arithmetic: a lone outlier
// among eight equal neighbours must vanish. Pass 4 pins the ORIENTATION of the
// gradient, which a check against a model written from the same misunderstanding
// cannot do.
//
// THE FLUSH LINE. Each pass sends one extra line after the frame. The line
// buffer emits the rows for beat k when beat k+1 arrives, and the window builder
// emits the window for beat k when beat k+1 arrives or the line ends -- so the
// final beat of a frame needs a successor to push it out. A real pipeline either
// sends a flush line or accepts that the last line arrives with the next frame.
// The extra line is a COMPLETE line ending in TLAST, because the window builder
// derives start-of-line from the previous TLAST: a truncated flush line would
// leave the next frame's first beat looking like a continuation.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module video_filter_tb;

  localparam int unsigned FN     = 2;                 // PIXELS_PER_CLOCK
  localparam int unsigned FP     = 3;                 // COMPONENTS_PER_PIXEL
  localparam int unsigned FB     = 8;                 // BITS_PER_COMPONENT
  localparam int unsigned FTAPS  = 3;
  localparam int unsigned FWORDS = 4;                 // beats per line
  localparam int unsigned FWIDTH = FN * FWORDS;       // 8 pixels per line
  localparam int unsigned FLINES = 6;
  localparam int unsigned FBEAT  = FN * FP * FB;
  localparam int unsigned FCOLS  = FN + 2;
  localparam int unsigned FWINB  = FTAPS * FCOLS * FP * FB;
  localparam int unsigned FSHIFT = 3;                 // no scaling: easy to model
  localparam int unsigned GRADC  = 0;                 // gradient component
  localparam int unsigned MAXV   = (1 << FB) - 1;
  // |Gx| at a full-scale vertical step is (1+2+1)*MAXV, with Gy zero there.
  // Computed from the kernel by hand rather than from sobel_model(), so pass 4
  // stays a claim about the filter instead of a comparison of two models.
  localparam int unsigned STEP_RAW = (4 * MAXV) >> FSHIFT;
  localparam int unsigned STEP_MAG = (STEP_RAW > MAXV) ? MAXV : STEP_RAW;

  // A SIGNED int, compared below WITHOUT a cast: `while (j < int'(NBEATS))` is
  // evaluated as FALSE by XSIM and the loop body never runs, which left this
  // collector silently dead -- every check in it skipped, the testbench printing
  // PASS. Measured, with a minimal reproducer, in docs/37 section 13. The
  // equivalent `for` loop is unaffected, and so is the uncast comparison.
  localparam int NBEATS = int'(FLINES) * int'(FWORDS);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  int   err  = 0;
  logic done = 1'b0;
  int   pass = 0;

  // The frame, as a software model. Clamp-to-edge addressing is in fpix().
  int fr [FLINES][FWIDTH][FP];

  // ---- the pipeline --------------------------------------------------------
  logic [FBEAT-1:0]  f_in   = '0;
  logic              f_iv   = 1'b0, f_ir, f_il = 1'b0;
  logic [0:0]        f_iu   = '0;

  logic [FTAPS*FBEAT-1:0] lb_rows;
  logic                   lb_ov, lb_or, lb_ol;
  logic [0:0]             lb_ou;
  logic [FTAPS-1:0]       lb_real;

  logic [FWINB-1:0]  win;
  logic              win_ov, win_or, win_ol;
  logic [0:0]        win_ou;

  logic [FBEAT-1:0]  med_out, sob_out;
  logic              med_ov, med_ol, sob_ov, sob_ol;
  logic [0:0]        med_ou, sob_ou;
  logic              med_ir, sob_ir;

  // A registered random ready, so it is stable across the negedge the collector
  // samples on -- a ready driven combinationally from the same edge would race
  // with it.
  logic bp_en = 1'b0;
  logic filt_ready = 1'b1;
  always_ff @(posedge clk) filt_ready <= !bp_en || ($urandom_range(0, 3) != 0);

  vid_axis_line_buffer #(.N(FN), .P(FP), .B(FB), .TAPS(FTAPS),
                         .MAX_WIDTH(FWIDTH), .UW(1),
                         .EDGE_REPLICATE(1'b1)) u_lb (
    .clk, .rst_n,
    .s_tdata(f_in), .s_tvalid(f_iv), .s_tready(f_ir), .s_tlast(f_il),
    .s_tuser(f_iu),
    .m_rows(lb_rows), .m_tvalid(lb_ov), .m_tready(lb_or), .m_tlast(lb_ol),
    .m_tuser(lb_ou), .m_row_real(lb_real));

  vid_axis_win3 #(.N(FN), .P(FP), .B(FB), .R(FTAPS), .UW(1)) u_win (
    .clk, .rst_n,
    .s_rows(lb_rows), .s_tvalid(lb_ov), .s_tready(lb_or), .s_tlast(lb_ol),
    .s_tuser(lb_ou),
    .m_win(win), .m_tvalid(win_ov), .m_tready(win_or), .m_tlast(win_ol),
    .m_tuser(win_ou));

  vid_axis_median3 #(.N(FN), .P(FP), .B(FB), .R(FTAPS), .UW(1)) u_med (
    .clk, .rst_n,
    .s_win(win), .s_tvalid(win_ov), .s_tready(med_ir), .s_tlast(win_ol),
    .s_tuser(win_ou),
    .m_tdata(med_out), .m_tvalid(med_ov), .m_tready(filt_ready),
    .m_tlast(med_ol), .m_tuser(med_ou));

  vid_axis_sobel #(.N(FN), .P(FP), .B(FB), .R(FTAPS), .GRAD_COMP(GRADC),
                   .SHIFT(FSHIFT), .UW(1)) u_sob (
    .clk, .rst_n,
    .s_win(win), .s_tvalid(win_ov), .s_tready(sob_ir), .s_tlast(win_ol),
    .s_tuser(win_ou),
    .m_tdata(sob_out), .m_tvalid(sob_ov), .m_tready(filt_ready),
    .m_tlast(sob_ol), .m_tuser(sob_ou));

  // One window feeding two consumers: the producer may only advance when both
  // have taken the beat. Forgetting the AND is the classic fan-out bug -- the
  // faster consumer then sees every beat and the slower one sees some of them.
  assign win_or = med_ir && sob_ir;

  // ---- checking ------------------------------------------------------------
  task automatic fck(input string what, input logic ok);
    if (!ok) begin
      err++;
      if (err <= 15) $display("  FAIL  [pass %0d] %s", pass, what);
    end
  endtask

  // Clamp-to-edge frame access. This one function is the whole edge policy:
  // the line buffer replicates the oldest stored line at the top of the frame
  // and the window builder replicates the end pixels of a line, which together
  // are exactly "clamp the coordinates".
  function automatic int fpix(input int y, x, p);
    int yy, xx;
    yy = (y < 0) ? 0 : ((y >= int'(FLINES)) ? int'(FLINES) - 1 : y);
    xx = (x < 0) ? 0 : ((x >= int'(FWIDTH)) ? int'(FWIDTH) - 1 : x);
    fpix = fr[yy][xx][p];
  endfunction

  // Window row r of the beat carrying line y is line y-r: row 0 is the newest
  // line, and the neighbourhood is centred on row 1, one line back.
  function automatic int med_model(input int y, x, p);
    int v [9];
    int i, j, t;
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 3; c++)
        v[(r * 3) + c] = fpix(y - r, x + c - 1, p);
    for (i = 1; i < 9; i++) begin           // insertion sort; 9 elements
      t = v[i];
      j = i - 1;
      while (j >= 0 && v[j] > t) begin
        v[j + 1] = v[j];
        j--;
      end
      v[j + 1] = t;
    end
    med_model = v[4];
  endfunction

  function automatic int sobel_model(input int y, x);
    int w [3][3];
    int gx, gy, s;
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 3; c++)
        w[r][c] = fpix(y - r, x + c - 1, GRADC);
    gx = (w[0][2] + (2 * w[1][2]) + w[2][2])
       - (w[0][0] + (2 * w[1][0]) + w[2][0]);
    gy = (w[0][0] + (2 * w[0][1]) + w[0][2])
       - (w[2][0] + (2 * w[2][1]) + w[2][2]);
    s  = ((gx < 0) ? -gx : gx) + ((gy < 0) ? -gy : gy);
    s  = s >> FSHIFT;
    sobel_model = (s > int'(MAXV)) ? int'(MAXV) : s;
  endfunction

  // ---- stimulus ------------------------------------------------------------
  function automatic logic [FBEAT-1:0] mk_beat(input int line, word);
    mk_beat = '0;
    for (int n = 0; n < int'(FN); n++)
      for (int p = 0; p < int'(FP); p++)
        mk_beat[((n * int'(FP)) + p) * FB +: FB] =
          FB'(fr[line][(word * int'(FN)) + n][p]);
  endfunction

  // Hold data and TVALID until a negedge at which TREADY was high; the transfer
  // itself happens on the posedge inside the following step. Stimulus lives on
  // the negedge throughout this repository -- driving it on the same edge the
  // DUT samples is the race that made three FSM styles look one cycle apart in
  // fsm_tb.
  task automatic send_beat(input logic [FBEAT-1:0] d, input logic lst, sof);
    f_in = d;
    f_il = lst;
    f_iu = sof;
    f_iv = 1'b1;
    while (!f_ir) @(negedge clk);
    @(negedge clk);
  endtask

  task automatic send_frame();
    for (int line = 0; line < int'(FLINES); line++)
      for (int word = 0; word < int'(FWORDS); word++)
        send_beat(mk_beat(line, word), word == int'(FWORDS) - 1,
                  (line == 0) && (word == 0));
    // The flush line: a complete duplicate of the last line, ending in TLAST.
    for (int word = 0; word < int'(FWORDS); word++)
      send_beat(mk_beat(int'(FLINES) - 1, word), word == int'(FWORDS) - 1, 1'b0);
    f_iv = 1'b0;
  endtask

  task automatic collect_frame();
    int j, y, x, w;
    int want_m, want_s, got_m, got_s, idle;
    j    = 0;
    idle = 0;
    while (j < NBEATS) begin
      @(negedge clk);
      idle++;
      if (idle > 400) begin
        fck($sformatf("pipeline stalled after %0d of %0d output beats",
                      j, NBEATS), 1'b0);
        return;
      end
      if (med_ov && filt_ready) begin
        idle = 0;
        fck("median and sobel outputs stay in lockstep", sob_ov === 1'b1);
        y = j / int'(FWORDS);
        w = j % int'(FWORDS);

        fck($sformatf("tlast on beat %0d of line %0d", w, y),
            med_ol === ((w == int'(FWORDS) - 1) ? 1'b1 : 1'b0));
        fck("sobel tlast matches median tlast", sob_ol === med_ol);

        for (int n = 0; n < int'(FN); n++) begin
          x      = (w * int'(FN)) + n;
          want_s = sobel_model(y, x);
          for (int p = 0; p < int'(FP); p++) begin
            want_m = med_model(y, x, p);
            got_m  = int'(med_out[((n * int'(FP)) + p) * FB +: FB]);
            got_s  = int'(sob_out[((n * int'(FP)) + p) * FB +: FB]);
            fck($sformatf("median y=%0d x=%0d c=%0d: got %0d want %0d",
                          y, x, p, got_m, want_m), got_m == want_m);
            fck($sformatf("sobel y=%0d x=%0d c=%0d: got %0d want %0d",
                          y, x, p, got_s, want_s), got_s == want_s);
          end

          // ---- model-free claims, per pass ------------------------------
          if (pass == 2) begin
            fck($sformatf("flat frame: median y=%0d x=%0d unchanged", y, x),
                int'(med_out[((n * int'(FP)) + 0) * FB +: FB]) == fpix(y, x, 0));
            fck($sformatf("flat frame: sobel y=%0d x=%0d is zero", y, x),
                int'(sob_out[((n * int'(FP)) + 0) * FB +: FB]) == 0);
          end
          if (pass == 3) begin
            // Salt and pepper on a constant field: every impulse is an isolated
            // outlier, so the median of its neighbourhood is the field value.
            fck($sformatf("impulse removed at y=%0d x=%0d", y, x),
                int'(med_out[((n * int'(FP)) + 0) * FB +: FB]) == 100);
          end
          if (pass == 4) begin
            // A step edge at x=3|4 makes the whole picture constant along y, so
            // the vertical gradient must be zero everywhere and the horizontal
            // one nonzero only at the two columns adjacent to the step.
            got_s = int'(sob_out[((n * int'(FP)) + 0) * FB +: FB]);
            if ((x == 3) || (x == 4))
              fck($sformatf("step edge lights column %0d (got %0d want %0d)",
                            x, got_s, STEP_MAG), got_s == int'(STEP_MAG));
            else
              fck($sformatf("step edge leaves column %0d dark (got %0d)",
                            x, got_s), got_s == 0);
          end
        end
        j++;
      end
    end
  endtask

  // ---- frame fill ----------------------------------------------------------
  task automatic fill_frame(input int which);
    for (int y = 0; y < int'(FLINES); y++)
      for (int x = 0; x < int'(FWIDTH); x++)
        for (int p = 0; p < int'(FP); p++) begin
          case (which)
            0, 1:    fr[y][x][p] = $urandom_range(0, int'(MAXV));
            2:       fr[y][x][p] = 100 + p;          // flat, distinct per comp
            3:       fr[y][x][p] = 100;              // flat; impulses added below
            default: fr[y][x][p] = (x < 4) ? 0 : int'(MAXV);   // vertical step
          endcase
        end

    if (which == 3) begin
      // Isolated impulses only: no two in the same 3x3 neighbourhood, or the
      // median is not obliged to remove either of them. Every third column on
      // every other line, alternating salt and pepper.
      //
      // NOT IN THE FIRST OR LAST COLUMN. Clamp-to-edge REPLICATES the end pixel,
      // so an impulse sitting on the edge appears twice in every row of the
      // window -- six of the nine taps at the top corner, where the vertical
      // clamp triples the row as well. It is then the majority and the median
      // keeps it, correctly. An edge impulse is not an isolated impulse, and
      // this test found that out the direct way.
      for (int y = 0; y < int'(FLINES); y += 2)
        for (int x = 1; x < int'(FWIDTH) - 1; x += 3)
          for (int p = 0; p < int'(FP); p++)
            fr[y][x][p] = ((x / 3) % 2) ? 0 : int'(MAXV);
    end
  endtask

  // ---- run -----------------------------------------------------------------
  initial begin
    $display("");
    $display("=== video_filter_tb ===");
    $display("[cfg] N=%0d P=%0d B=%0d TAPS=%0d  %0dx%0d frame, SHIFT=%0d",
             FN, FP, FB, FTAPS, FWIDTH, FLINES, FSHIFT);

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    for (int ps = 0; ps < 5; ps++) begin
      pass  = ps;
      bp_en = (ps == 1);
      fill_frame(ps);

      // RESET BETWEEN PASSES, because this pipeline cannot be drained. When a
      // stream stops, the line buffer is still holding the last beat (it emits
      // beat k's rows when beat k+1 arrives) and the window builder is holding
      // the one before it (it needs the next beat for the right halo). Extra
      // beats only move the problem along: whatever arrives last stays stuck.
      // Without the reset, those two stale beats come out as the FIRST outputs
      // of the next pass and shift every check by one beat -- which showed up
      // here as a TLAST in the wrong place, one pass after the one that caused
      // it.
      f_iv  = 1'b0;
      rst_n = 1'b0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);

      fork
        send_frame();
        collect_frame();
      join
      bp_en = 1'b0;
      $display("  pass %0d: %0d errors so far", ps, err);
    end

    $display("");
    if (err == 0) $display("video_filter_tb: PASS");
    else begin
      $display("video_filter_tb: FAIL (%0d errors)", err);
      $fatal(1, "video filter test failures");
    end
    done = 1'b1;
    $finish;
  end

  initial begin
    #10ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
