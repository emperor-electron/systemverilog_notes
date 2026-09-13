// -----------------------------------------------------------------------------
// arith_tb.sv -- self-checking tests for the arithmetic and DSP blocks:
// the restoring divider (unsigned and signed), saturating add/narrow,
// requantize, the CORDIC sine/cosine unit, the systolic FIR, and the
// pipelined MAC.
//
// Each block is checked against an independently-written reference: the
// simulator's own integer division for the divider, unbounded arithmetic for
// saturation, $sin/$cos for CORDIC, and a direct-form convolution for the FIR.
//
// Note that every task samples on `negedge clk`. These blocks have plain
// (non-handshake) interfaces without a clocking block, so sampling on the
// active edge would race the DUT's non-blocking updates -- see docs/15, and
// fifo_tb.sv for the clocking-block alternative.
//
// Run it:
//   $ iverilog -g2012 -gsupported-assertions -o arith_tb \
//       -y ../rtl -y ../arith ../tb/arith_tb.sv && ./arith_tb
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module arith_tb;

  int errors = 0;

  task automatic chk(input string what, input logic ok);
    if (!ok) begin
      errors++;
      if (errors <= 30) $display("  FAIL  %s", what);
    end
  endtask

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ===========================================================================
  // Restoring divider, unsigned
  // ===========================================================================
  localparam int DVW = 16;
  logic            u_vi, u_ro, u_vo, u_dbz;
  logic [DVW-1:0]  u_a, u_b, u_q, u_r;

  div_restoring #(.W(DVW)) u_div (
    .clk(clk), .rst_n(rst_n), .valid_i(u_vi), .ready_o(u_ro),
    .dividend(u_a), .divisor(u_b), .valid_o(u_vo), .ready_i(1'b1),
    .quotient(u_q), .remainder(u_r), .div_by_zero(u_dbz));

  task automatic do_udiv(input logic [DVW-1:0] av, bv);
    @(negedge clk);
    while (!u_ro) @(negedge clk);
    u_a = av;  u_b = bv;  u_vi = 1'b1;
    @(negedge clk);  u_vi = 1'b0;
    while (!u_vo) @(negedge clk);
    if (bv != 0) begin
      chk($sformatf("udiv %0d/%0d q=%0d exp=%0d", av, bv, u_q, av / bv),
          u_q === (av / bv));
      chk($sformatf("udiv %0d%%%0d r=%0d exp=%0d", av, bv, u_r, av % bv),
          u_r === (av % bv));
    end else begin
      // RISC-V convention: quotient all ones, remainder = dividend.
      chk("udiv by zero flag",      u_dbz === 1'b1);
      chk("udiv by zero quotient",  u_q   === '1);
      chk("udiv by zero remainder", u_r   === av);
    end
    @(negedge clk);
  endtask

  // ===========================================================================
  // Restoring divider, signed. SystemVerilog truncates toward zero and the
  // remainder takes the DIVIDEND's sign -- see docs/17.
  // ===========================================================================
  logic                   s_vi, s_ro, s_vo, s_dbz;
  logic signed [DVW-1:0]  s_a, s_b, s_q, s_r;

  div_signed #(.W(DVW)) u_sdiv (
    .clk(clk), .rst_n(rst_n), .valid_i(s_vi), .ready_o(s_ro),
    .dividend(s_a), .divisor(s_b), .valid_o(s_vo), .ready_i(1'b1),
    .quotient(s_q), .remainder(s_r), .div_by_zero(s_dbz));

  task automatic do_sdiv(input logic signed [DVW-1:0] av, bv);
    @(negedge clk);
    while (!s_ro) @(negedge clk);
    s_a = av;  s_b = bv;  s_vi = 1'b1;
    @(negedge clk);  s_vi = 1'b0;
    while (!s_vo) @(negedge clk);
    if (bv != 0) begin
      chk($sformatf("sdiv %0d/%0d q=%0d exp=%0d", av, bv, s_q, av / bv),
          s_q === (av / bv));
      chk($sformatf("sdiv %0d%%%0d r=%0d exp=%0d", av, bv, s_r, av % bv),
          s_r === (av % bv));
    end
    @(negedge clk);
  endtask

  task automatic test_divider();
    $display("[div_restoring / div_signed]");
    do_udiv(16'd100,   16'd7);
    do_udiv(16'd0,     16'd5);
    do_udiv(16'd65535, 16'd1);
    do_udiv(16'd65535, 16'd65535);
    do_udiv(16'd5,     16'd10);
    do_udiv(16'd42,    16'd0);       // divide by zero
    repeat (200) do_udiv($urandom(), $urandom());

    do_sdiv(-16'sd7,     16'sd2);    // -3 rem -1  (truncate toward zero)
    do_sdiv( 16'sd7,    -16'sd2);    // -3 rem  1
    do_sdiv(-16'sd7,    -16'sd2);    //  3 rem -1
    do_sdiv(-16'sd32768, 16'sd1);    // the most-negative dividend
    do_sdiv(-16'sd32768,-16'sd1);    // overflows; must match the language
    do_sdiv( 16'sd0,    -16'sd3);
    repeat (200) do_sdiv($urandom(), $urandom());
  endtask

  // ===========================================================================
  // Saturating add / narrow / requantize
  // ===========================================================================
  logic signed [15:0] sa_a, sa_b, sa_y;
  logic               sa_sub, sa_sat;
  sat_add #(.W(16)) u_sa (.a(sa_a), .b(sa_b), .sub(sa_sub), .y(sa_y), .sat(sa_sat));

  logic signed [39:0] sn_in;
  logic signed [15:0] sn_out;
  logic               sn_sat;
  sat_narrow #(.WI(40), .WO(16)) u_sn (.din(sn_in), .dout(sn_out), .sat(sn_sat));

  logic signed [39:0] rq_in;
  logic signed [15:0] rq_out;
  logic               rq_sat;
  requantize #(.WI(40), .WO(16), .FDROP(12), .ROUND(1'b1)) u_rq (
    .din(rq_in), .dout(rq_out), .sat(rq_sat));

  task automatic test_saturation();
    longint exact, lo, hi;
    $display("[sat_add / sat_narrow / requantize]");
    lo = -32768;  hi = 32767;

    // sat_add: compare against exact arithmetic in a 64-bit reference.
    for (int t = 0; t < 4000; t++) begin
      sa_a   = 16'($urandom());
      sa_b   = 16'($urandom());
      sa_sub = ($urandom_range(1,0) != 0);
      #1;
      exact = sa_sub ? (longint'(sa_a) - longint'(sa_b))
                     : (longint'(sa_a) + longint'(sa_b));
      if (exact > hi)
        chk($sformatf("sat_add clamp high %0d", exact), sa_y === 16'sh7FFF && sa_sat);
      else if (exact < lo)
        chk($sformatf("sat_add clamp low %0d", exact),  sa_y === 16'sh8000 && sa_sat);
      else
        chk($sformatf("sat_add exact %0d got %0d", exact, sa_y),
            sa_y === 16'(exact) && !sa_sat);
    end
    // boundaries
    sa_a = 16'sh7FFF; sa_b = 16'sd1;  sa_sub = 1'b0; #1;
    chk("sat_add +max +1", sa_y === 16'sh7FFF && sa_sat);
    sa_a = 16'sh8000; sa_b = 16'sd1;  sa_sub = 1'b1; #1;
    chk("sat_add -min -1", sa_y === 16'sh8000 && sa_sat);

    // sat_narrow
    for (int t = 0; t < 4000; t++) begin
      sn_in = 40'($urandom()) | (40'($urandom()) << 20);
      #1;
      exact = longint'(sn_in);
      if (exact > hi)      chk("sat_narrow high", sn_out === 16'sh7FFF && sn_sat);
      else if (exact < lo) chk("sat_narrow low",  sn_out === 16'sh8000 && sn_sat);
      else                 chk($sformatf("sat_narrow pass %0d", exact),
                               sn_out === 16'(exact) && !sn_sat);
    end

    // requantize: drop 12 fraction bits with round-half-to-even, then saturate.
    for (int t = 0; t < 4000; t++) begin
      longint shifted, rem, half, expect_v;
      rq_in = 40'($urandom()) | (40'($urandom()) << 20);
      #1;
      exact   = longint'(rq_in);
      // reference: floor division by 4096, then round half to even
      shifted = exact >>> 12;
      rem     = exact - (shifted <<< 12);       // always 0..4095
      half    = 1 << 11;
      if (rem > half)                      expect_v = shifted + 1;
      else if (rem < half)                 expect_v = shifted;
      else                                 expect_v = shifted + (shifted & 1);
      if (expect_v > hi)      chk("requantize high", rq_out === 16'sh7FFF && rq_sat);
      else if (expect_v < lo) chk("requantize low",  rq_out === 16'sh8000 && rq_sat);
      else                    chk($sformatf("requantize %0d -> %0d got %0d",
                                            exact, expect_v, rq_out),
                                  rq_out === 16'(expect_v) && !rq_sat);
    end
  endtask

  // ===========================================================================
  // CORDIC sine/cosine, against $sin/$cos
  // ===========================================================================
  localparam int CITER = 24;
  logic               cd_vi, cd_vo;
  logic signed [31:0] cd_ang, cd_cos, cd_sin;
  cordic_sincos #(.ITER(CITER)) u_cd (
    .clk(clk), .rst_n(rst_n), .valid_i(cd_vi), .angle(cd_ang),
    .valid_o(cd_vo), .cos_o(cd_cos), .sin_o(cd_sin));

  task automatic test_cordic();
    real worst_c, worst_s, ec, es, e;
    int  n;
    $display("[cordic_sincos] %0d iterations, full [-pi, pi] sweep", CITER);
    worst_c = 0.0;  worst_s = 0.0;  n = 0;
    for (int k = -100; k <= 100; k++) begin
      real rad;
      rad    = 3.14159265358979 * real'(k) / 100.0;
      cd_ang = 32'(longint'(rad * (2.0 ** 29)));
      cd_vi  = 1'b1;
      @(negedge clk);  cd_vi = 1'b0;
      repeat (CITER + 2) @(negedge clk);
      ec = $cos(rad) - (real'(cd_cos) / (2.0 ** 30));
      es = $sin(rad) - (real'(cd_sin) / (2.0 ** 30));
      if (ec < 0.0) ec = -ec;
      if (es < 0.0) es = -es;
      if (ec > worst_c) worst_c = ec;
      if (es > worst_s) worst_s = es;
      n++;
    end
    $display("           worst |cos err| = %.3e, worst |sin err| = %.3e",
             worst_c, worst_s);
    // 24 iterations should give roughly 2^-23 ~= 1.2e-7.
    chk($sformatf("cordic cos accuracy %.3e", worst_c), worst_c < 1.0e-6);
    chk($sformatf("cordic sin accuracy %.3e", worst_s), worst_s < 1.0e-6);
  endtask

  // ===========================================================================
  // Systolic FIR against a direct-form convolution
  // ===========================================================================
  localparam int NTAP = 8, FDW = 16, FCW = 18, FCF = 17;
  localparam int FPW = FDW + FCW, FGUARD = 3, FACCW = FPW + FGUARD;
  localparam int NS = 200;

  logic                    f_vi, f_vo, f_sat;
  logic signed [FDW-1:0]   f_x, f_y;
  logic signed [FACCW-1:0] f_yf;
  logic [NTAP*FCW-1:0]     f_cf;
  logic signed [FCW-1:0]   f_h [0:NTAP-1];
  logic signed [FDW-1:0]   f_X [0:NS-1];
  logic signed [FACCW-1:0] f_Y [0:NS-1];
  int f_nout = 0;

  fir_systolic #(.NTAP(NTAP), .DW(FDW), .CW(FCW), .CF(FCF)) u_fir (
    .clk(clk), .rst_n(rst_n), .valid_i(f_vi), .x(f_x), .coef_flat(f_cf),
    .valid_o(f_vo), .y(f_y), .y_full(f_yf), .sat(f_sat));

  always @(negedge clk)
    if (rst_n && f_vo && f_nout < NS) begin
      f_Y[f_nout] = f_yf;
      f_nout++;
    end

  task automatic test_fir();
    $display("[fir_systolic] %0d taps, %0d samples, asymmetric coefficients",
             NTAP, NS);
    // Asymmetric on purpose: a symmetric set hides a reversed coefficient order.
    for (int k = 0; k < NTAP; k++) begin
      f_h[k] = signed'(FCW'(((k + 1) * 9173) * ((k % 3 == 1) ? -1 : 1)));
      f_cf[k*FCW +: FCW] = f_h[k];
    end
    for (int i = 0; i < NS; i++) f_X[i] = FDW'($urandom());

    f_nout = 0;
    @(negedge clk);
    for (int i = 0; i < NS; i++) begin
      f_x  = f_X[i];
      f_vi = 1'b1;
      @(negedge clk);
    end
    f_vi = 1'b0;
    repeat (NTAP + 4) @(negedge clk);

    chk($sformatf("fir captured %0d of %0d outputs", f_nout, NS), f_nout == NS);
    for (int n = 0; n < NS; n++) begin
      logic signed [FACCW-1:0] acc;
      acc = '0;
      for (int j = 0; j < NTAP; j++)
        if (n - j >= 0) acc = acc + FACCW'(signed'(f_X[n-j]) * f_h[j]);
      chk($sformatf("fir y[%0d] got %0d exp %0d", n, f_Y[n], acc),
          f_Y[n] === acc);
    end
  endtask

  // ===========================================================================
  // Pipelined MAC
  // ===========================================================================
  localparam int MAW = 18, MBW = 18, MNACC = 1024;
  localparam int MPW = MAW + MBW, MGUARD = 10, MACCW = MPW + MGUARD;

  logic                    m_vi, m_vo, m_clr;
  logic signed [MAW-1:0]   m_a;
  logic signed [MBW-1:0]   m_b;
  logic signed [MACCW-1:0] m_acc;

  mac_pipelined #(.AW(MAW), .BW(MBW), .NACC(MNACC)) u_mac (
    .clk(clk), .rst_n(rst_n), .valid_i(m_vi), .a(m_a), .b(m_b),
    .acc_clear(m_clr), .valid_o(m_vo), .acc(m_acc));

  task automatic test_mac();
    logic signed [MACCW-1:0] ref_acc;
    $display("[mac_pipelined] 300 signed MACs including the extreme operands");
    ref_acc = '0;
    @(negedge clk);
    for (int i = 0; i < 300; i++) begin
      logic signed [MAW-1:0] av;
      logic signed [MBW-1:0] bv;
      bit                    clr;
      // Mix in the most-negative operands: (-2^17)*(-2^17) is the one product
      // that needs the full AW+BW bits.
      case (i % 7)
        0:       begin av = -(1 <<< (MAW-1)); bv = -(1 <<< (MBW-1)); end
        1:       begin av =  (1 <<< (MAW-1)) - 1; bv = -(1 <<< (MBW-1)); end
        default: begin av = MAW'($urandom());     bv = MBW'($urandom()); end
      endcase
      clr  = (i == 0);
      m_a = av;  m_b = bv;  m_clr = clr;  m_vi = 1'b1;
      ref_acc = clr ? MACCW'(av * bv) : (ref_acc + MACCW'(av * bv));
      @(negedge clk);
    end
    m_vi = 1'b0;
    repeat (3) @(negedge clk);
    chk($sformatf("mac acc got %0d exp %0d", m_acc, ref_acc), m_acc === ref_acc);
  endtask

  // ===========================================================================
  initial begin
    u_vi = 1'b0; u_a = '0; u_b = '0;
    s_vi = 1'b0; s_a = '0; s_b = '0;
    sa_a = '0; sa_b = '0; sa_sub = 1'b0;
    sn_in = '0; rq_in = '0;
    cd_vi = 1'b0; cd_ang = '0;
    f_vi = 1'b0; f_x = '0; f_cf = '0;
    m_vi = 1'b0; m_a = '0; m_b = '0; m_clr = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_divider();
    test_saturation();
    test_cordic();
    test_fir();
    test_mac();

    $display("");
    if (errors == 0) $display("arith_tb: PASS");
    else begin
      $display("arith_tb: FAIL (%0d errors)", errors);
      $fatal(1, "arithmetic test failures");
    end
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
