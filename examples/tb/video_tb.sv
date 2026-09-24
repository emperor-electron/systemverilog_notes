// -----------------------------------------------------------------------------
// video_tb.sv -- vid_axis_gain, vid_axis_csc and vid_axis_line_buffer, swept
// across five (N, P, B) configurations at once.
//
// Genericity is a claim about ALL parameter values, so testing one is close to
// testing none. The five configurations below are chosen to break different
// things:
//
//   N=1 P=1 B=8    the fully degenerate case: one pixel, one component. Every
//                  loop runs once, every reduction has one term, and any code
//                  that assumed P>1 or N>1 falls over here.
//   N=2 P=3 B=8    ordinary RGB, two pixels per clock.
//   N=4 P=3 B=10   B not a multiple of 8, so no part-select lands on a byte
//                  boundary -- which catches anything that quietly assumed one.
//   N=2 P=4 B=12   P=4, so the coefficient matrix is 4x4 and P != 3.
//   N=1 P=3 B=16   wide components, one pixel per clock.
//
// THE STRONGEST CHECK HERE IS THE IDENTITY MATRIX. Feeding vid_axis_csc a P x P
// identity with zero offset must reproduce the input bit for bit, for every
// configuration. Any transposition of the coefficient index, any confusion
// between the pixel and component axes, and any off-by-one in the layout shows
// up immediately -- and unlike a check against a reference model, it cannot be
// satisfied by a reference that made the same mistake.
//
// Per-component gains are all DIFFERENT on purpose. A module that applied
// component 0's gain to every component would pass a test with uniform gains.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module video_tb;

  localparam int unsigned NCFG = 5;

  localparam int unsigned CFG_N [NCFG] = '{1, 2, 4, 2, 1};
  localparam int unsigned CFG_P [NCFG] = '{1, 3, 3, 4, 3};
  localparam int unsigned CFG_B [NCFG] = '{8, 8, 10, 12, 16};

  localparam int unsigned GW = 16, GF = 8;
  localparam int unsigned CW = 18, CF = 12;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  int   cfg_err  [NCFG];
  logic cfg_done [NCFG];

  // ===========================================================================
  for (genvar c = 0; c < int'(NCFG); c++) begin : g_cfg

    localparam int unsigned CN = CFG_N[c];
    localparam int unsigned CP = CFG_P[c];
    localparam int unsigned CB = CFG_B[c];
    localparam int unsigned TD = CN * CP * CB;
    localparam int unsigned OW = CB + 1;

    // These builders live INSIDE the generate scope on purpose. The width of a
    // `+:` part-select has to be a constant, and a function argument is not one
    // -- passing GW in gave "'GWi' is not a constant". Declared here, GW, OW and
    // CP are all elaboration-time constants of this instance, so the selects are
    // legal and each configuration gets its own correctly-sized vector.
    //
    // Per-component gains of 1.25, 1.50, 1.75, ... so that no two components
    // share a value: a module that applied component 0's gain to all of them
    // would pass a test with uniform gains.
    function automatic logic [CP*GW-1:0] mk_gain();
      mk_gain = '0;
      for (int p = 0; p < int'(CP); p++)
        mk_gain[p*GW +: GW] = GW'((1 << GF) + ((p + 1) * (1 << GF)) / 4);
    endfunction

    // Small distinct signed offsets: +1, -2, +3, -4, ...
    function automatic logic [CP*OW-1:0] mk_offset();
      mk_offset = '0;
      for (int p = 0; p < int'(CP); p++)
        mk_offset[p*OW +: OW] = OW'($signed(p[0] ? -(p + 2) : (p + 1)));
    endfunction

    localparam logic [CP*GW-1:0] CGAIN   = mk_gain();
    localparam logic [CP*OW-1:0] COFFSET = mk_offset();

    localparam longint unsigned MAXV = (1 << CB) - 1;

    // ---- gain -------------------------------------------------------------
    logic [TD-1:0] g_in = '0, g_out;
    logic          g_iv = 1'b0, g_ir, g_ov, g_or = 1'b1, g_il = 1'b0, g_ol;
    logic [0:0]    g_iu = '0, g_ou;

    vid_axis_gain #(.N(CN), .P(CP), .B(CB), .GW(GW), .GF(GF), .UW(1),
                    .GAIN(CGAIN), .OFFSET(COFFSET)) u_gain (
      .clk, .rst_n,
      .s_tdata(g_in), .s_tvalid(g_iv), .s_tready(g_ir), .s_tlast(g_il),
      .s_tuser(g_iu),
      .m_tdata(g_out), .m_tvalid(g_ov), .m_tready(g_or), .m_tlast(g_ol),
      .m_tuser(g_ou));

    // ---- csc --------------------------------------------------------------
    logic [CP*CP*CW-1:0] cs_coef = '0;
    logic [CP*CW-1:0]    cs_off  = '0;
    logic [TD-1:0]       c_in = '0, c_out;
    logic                c_iv = 1'b0, c_ir, c_ov, c_or = 1'b1;
    logic                c_il = 1'b0, c_ol;
    logic [0:0]          c_iu = '0, c_ou;

    vid_axis_csc #(.N(CN), .P(CP), .B(CB), .CW(CW), .CF(CF), .UW(1)) u_csc (
      .clk, .rst_n,
      .coef(cs_coef), .offset(cs_off),
      .s_tdata(c_in), .s_tvalid(c_iv), .s_tready(c_ir), .s_tlast(c_il),
      .s_tuser(c_iu),
      .m_tdata(c_out), .m_tvalid(c_ov), .m_tready(c_or), .m_tlast(c_ol),
      .m_tuser(c_ou));

    // ---- helpers ----------------------------------------------------------
    task automatic ck(input string what, input logic ok);
      if (!ok) begin
        cfg_err[c]++;
        if (cfg_err[c] <= 8)
          $display("  FAIL  [N=%0d P=%0d B=%0d] %s", CN, CP, CB, what);
      end
    endtask

    function automatic longint clamp(input longint v);
      clamp = (v < 0) ? 0 : ((v > longint'(MAXV)) ? longint'(MAXV) : v);
    endfunction

    // Push one beat through the gain block and check it.
    task automatic gain_beat(input logic [TD-1:0] d);
      longint prod, want;
      int     guard;
      g_in = d; g_iv = 1'b1;
      while (!g_ir) @(negedge clk);
      @(negedge clk);
      g_iv = 1'b0;
      guard = 0;
      while (!g_ov && guard < 20) begin @(negedge clk); guard++; end
      ck("gain produced a beat", g_ov);

      for (int n = 0; n < int'(CN); n++)
        for (int p = 0; p < int'(CP); p++) begin
          prod = longint'(CGAIN[p*GW +: GW]) * longint'(d[((n*CP)+p)*CB +: CB]);
          prod = prod + longint'($signed(COFFSET[p*OW +: OW])) * (1 << GF);
          want = clamp((prod + (1 << (GF-1))) >>> GF);
          ck($sformatf("gain pix%0d comp%0d: got %0d want %0d",
                       n, p, g_out[((n*CP)+p)*CB +: CB], want),
             longint'(g_out[((n*CP)+p)*CB +: CB]) == want);
        end
      @(negedge clk);
    endtask

    // Push one beat through the CSC and check it against the matrix.
    task automatic csc_beat(input logic [TD-1:0] d);
      longint acc, want;
      int     guard;
      c_in = d; c_iv = 1'b1;
      while (!c_ir) @(negedge clk);
      @(negedge clk);
      c_iv = 1'b0;
      guard = 0;
      while (!c_ov && guard < 20) begin @(negedge clk); guard++; end
      ck("csc produced a beat", c_ov);

      for (int n = 0; n < int'(CN); n++)
        for (int o = 0; o < int'(CP); o++) begin
          acc = longint'($signed(cs_off[o*CW +: CW]));
          for (int i = 0; i < int'(CP); i++)
            acc = acc + longint'($signed(cs_coef[((o*CP)+i)*CW +: CW]))
                      * longint'(d[((n*CP)+i)*CB +: CB]);
          want = clamp((acc + (1 << (CF-1))) >>> CF);
          ck($sformatf("csc pix%0d out%0d: got %0d want %0d",
                       n, o, c_out[((n*CP)+o)*CB +: CB], want),
             longint'(c_out[((n*CP)+o)*CB +: CB]) == want);
        end
      @(negedge clk);
    endtask

    task automatic set_identity();
      cs_coef = '0;
      cs_off  = '0;
      for (int o = 0; o < int'(CP); o++)
        cs_coef[((o*CP)+o)*CW +: CW] = CW'(1 << CF);
      @(negedge clk);
    endtask

    // A matrix with every entry distinct and nonzero, so a transposed index
    // cannot accidentally agree with the correct one.
    task automatic set_distinct();
      cs_coef = '0;
      cs_off  = '0;
      for (int o = 0; o < int'(CP); o++) begin
        for (int i = 0; i < int'(CP); i++)
          cs_coef[((o*CP)+i)*CW +: CW] =
            CW'(((1 << CF) / (2 * int'(CP))) * (1 + ((o * 3 + i) % 5)));
        cs_off[o*CW +: CW] = CW'($signed((o + 1) * (1 << CF) / 8));
      end
      @(negedge clk);
    endtask

    initial begin : run_cfg
      logic [TD-1:0] d;
      cfg_err[c]  = 0;
      cfg_done[c] = 1'b0;
      wait (rst_n);
      repeat (2 + c) @(negedge clk);

      // ---- identity must be a bit-exact pass-through --------------------
      set_identity();
      for (int t = 0; t < 12; t++) begin
        for (int k = 0; k < int'(TD); k++) d[k] = $urandom_range(0, 1);
        csc_beat(d);
        ck($sformatf("identity matrix is a pass-through (%h vs %h)", c_out, d),
           c_out === d);
      end

      // Corners as well as random: all-zero and all-max.
      d = '0;  csc_beat(d);  ck("identity passes all-zero", c_out === d);
      d = '1;  csc_beat(d);  ck("identity passes all-ones", c_out === d);

      // ---- a real matrix against the reference --------------------------
      set_distinct();
      for (int t = 0; t < 16; t++) begin
        for (int k = 0; k < int'(TD); k++) d[k] = $urandom_range(0, 1);
        csc_beat(d);
      end
      d = '1; csc_beat(d);            // saturation territory
      d = '0; csc_beat(d);

      // ---- gain ---------------------------------------------------------
      for (int t = 0; t < 16; t++) begin
        for (int k = 0; k < int'(TD); k++) d[k] = $urandom_range(0, 1);
        gain_beat(d);
      end

      // Every gain here is > 1, so an all-max input must SATURATE, and every
      // component must come out at full scale rather than wrapped to near zero.
      d = '1;
      gain_beat(d);
      for (int n = 0; n < int'(CN); n++)
        for (int p = 0; p < int'(CP); p++)
          ck($sformatf("gain saturates pix%0d comp%0d (got %0d want %0d)",
                       n, p, g_out[((n*CP)+p)*CB +: CB], MAXV),
             longint'(g_out[((n*CP)+p)*CB +: CB]) == longint'(MAXV));

      d = '0;
      gain_beat(d);

      cfg_done[c] = 1'b1;
    end
  end

  // ===========================================================================
  // Line buffer: row alignment, checked against a software model of the frame.
  // One configuration is enough here -- the geometry is what is being tested,
  // and the (N,P,B) sweep above already covers the indexing.
  // ===========================================================================
  localparam int unsigned LN = 2, LP = 3, LB = 8, LTAPS = 3;
  localparam int unsigned LWIDTH = 8;                       // pixels per line
  localparam int unsigned LWORDS = (LWIDTH + LN - 1) / LN;  // 4 beats per line
  localparam int unsigned LBEAT  = LN * LP * LB;

  int lb_err = 0;
  logic lb_done = 1'b0;

  logic [LBEAT-1:0]        lb_in = '0;
  logic                    lb_iv = 1'b0, lb_ir, lb_il = 1'b0;
  logic [0:0]              lb_iu = '0;
  logic [LTAPS*LBEAT-1:0]  lb_rows;
  logic                    lb_ov, lb_or = 1'b1, lb_ol;
  logic [0:0]              lb_ou;
  logic [LTAPS-1:0]        lb_real;

  vid_axis_line_buffer #(.N(LN), .P(LP), .B(LB), .TAPS(LTAPS),
                         .MAX_WIDTH(LWIDTH), .UW(1),
                         .EDGE_REPLICATE(1'b1)) u_lb (
    .clk, .rst_n,
    .s_tdata(lb_in), .s_tvalid(lb_iv), .s_tready(lb_ir), .s_tlast(lb_il),
    .s_tuser(lb_iu),
    .m_rows(lb_rows), .m_tvalid(lb_ov), .m_tready(lb_or), .m_tlast(lb_ol),
    .m_tuser(lb_ou), .m_row_real(lb_real));

  task automatic lck(input string what, input logic ok);
    if (!ok) begin
      lb_err++;
      if (lb_err <= 12) $display("  FAIL  [line_buffer] %s", what);
    end
  endtask

  // A distinctive word per (line, word) so a misaligned tap is unmistakable.
  function automatic logic [LBEAT-1:0] mk_word(input int line, word);
    mk_word = '0;
    for (int n = 0; n < int'(LN); n++)
      for (int p = 0; p < int'(LP); p++)
        mk_word[((n*LP)+p)*LB +: LB] =
          LB'((line * 64) + (word * 8) + (n * LP) + p);
  endfunction

  initial begin : run_lb
    logic [LBEAT-1:0] got, want;
    int               out_line, out_word, guard;
    wait (rst_n);
    repeat (12) @(negedge clk);

    out_line = 0;
    out_word = 0;

    for (int line = 0; line < 6; line++) begin
      for (int word = 0; word < int'(LWORDS); word++) begin
        lb_in = mk_word(line, word);
        lb_il = (word == int'(LWORDS) - 1);
        lb_iu = (line == 0 && word == 0) ? 1'b1 : 1'b0;   // SOF
        lb_iv = 1'b1;
        while (!lb_ir) @(negedge clk);
        @(negedge clk);
        lb_iv = 1'b0;

        // Collect an output beat if one appeared.
        if (lb_ov) begin
          for (int t = 0; t < int'(LTAPS); t++) begin
            got = lb_rows[t*LBEAT +: LBEAT];
            if (out_line - t >= 0) begin
              want = mk_word(out_line - t, out_word);
              lck($sformatf("line %0d word %0d tap %0d: got %h want %h",
                            out_line, out_word, t, got, want), got === want);
              lck($sformatf("tap %0d flagged real at line %0d", t, out_line),
                  lb_real[t] === 1'b1);
            end else begin
              // Above the top of the frame: edge replication repeats the
              // oldest real line, and the tap is flagged as not real.
              want = mk_word(0, out_word);
              lck($sformatf("edge replicate line %0d tap %0d: got %h want %h",
                            out_line, t, got, want), got === want);
              lck($sformatf("tap %0d flagged not-real at line %0d", t, out_line),
                  lb_real[t] === 1'b0);
            end
          end
          if (out_word == int'(LWORDS) - 1) begin
            lck($sformatf("tlast on the final word of line %0d", out_line),
                lb_ol === 1'b1);
            out_word = 0;
            out_line++;
          end else begin
            out_word++;
          end
        end
      end
    end

    lck($sformatf("saw output for %0d lines (want >= 4)", out_line),
        out_line >= 4);
    lb_done = 1'b1;
  end

  // ===========================================================================
  int total;

  initial begin
    $display("");
    $display("=== video_tb ===");
    $display("[configs] (N,P,B) = (1,1,8) (2,3,8) (4,3,10) (2,4,12) (1,3,16)");

    repeat (4) @(negedge clk);
    rst_n = 1'b1;

    for (int c = 0; c < int'(NCFG); c++) wait (cfg_done[c]);
    wait (lb_done);

    total = lb_err;
    for (int c = 0; c < int'(NCFG); c++) begin
      $display("  N=%0d P=%0d B=%0d : %0d errors",
               CFG_N[c], CFG_P[c], CFG_B[c], cfg_err[c]);
      total += cfg_err[c];
    end
    $display("  line_buffer     : %0d errors", lb_err);

    $display("");
    if (total == 0) $display("video_tb: PASS");
    else begin
      $display("video_tb: FAIL (%0d errors)", total);
      $fatal(1, "video pipeline test failures");
    end
    $finish;
  end

  initial begin
    #10ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
