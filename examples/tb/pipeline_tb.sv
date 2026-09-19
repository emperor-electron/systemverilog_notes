// -----------------------------------------------------------------------------
// pipeline_tb.sv -- self-checking tests for the pipelining and timing-closure
// building blocks: pipe_delay, pipe_ctrl, adder_tree (several shapes),
// csa_accumulator, acc_interleaved, and operand_isolation.
//
// The interesting checks are the ones that catch the classic pipeline bugs:
//   * pipe_delay must delay by EXACTLY LATENCY, and must FREEZE on a stall --
//     a stage that keeps moving while its neighbours are frozen is the bug
//     latency matching exists to prevent.
//   * pipe_ctrl must clear on flush even while stalled.
//   * adder_tree must be exact for a non-power-of-two N, where the recursive
//     split is uneven and the subtree widths differ.
//   * csa_accumulator and acc_interleaved must match a plain accumulator
//     exactly -- these are algebraic rearrangements, so "close" is a bug.
//
// Every task samples on `negedge clk`: these blocks have plain interfaces with
// no clocking block, so sampling on the active edge would race the DUT's
// non-blocking updates (docs/15).
//
// Run it:
//   $ iverilog -g2012 -gsupported-assertions -Y.sv -y ../rtl -y ../arith \
//       -o pipeline_tb pipeline_tb.sv && ./pipeline_tb
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module pipeline_tb;

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
  // pipe_delay: exact latency, stall behaviour, and the LATENCY == 0 case
  // ===========================================================================
  localparam int PDW = 16;
  logic             pd_en;
  logic [PDW-1:0]   pd_in;
  logic [PDW-1:0]   pd_out0, pd_out1, pd_out3, pd_out7;

  pipe_delay #(.WIDTH(PDW), .LATENCY(0)) u_pd0
    (.clk, .rst_n, .en(pd_en), .din(pd_in), .dout(pd_out0));
  pipe_delay #(.WIDTH(PDW), .LATENCY(1)) u_pd1
    (.clk, .rst_n, .en(pd_en), .din(pd_in), .dout(pd_out1));
  pipe_delay #(.WIDTH(PDW), .LATENCY(3)) u_pd3
    (.clk, .rst_n, .en(pd_en), .din(pd_in), .dout(pd_out3));
  // RESET(0): no reset on the datapath registers -- the valid flag beside them
  // carries the meaning. Contents are X until data flows through.
  pipe_delay #(.WIDTH(PDW), .LATENCY(7), .RESET(1'b0)) u_pd7
    (.clk, .rst_n, .en(pd_en), .din(pd_in), .dout(pd_out7));

  task automatic test_pipe_delay();
    logic [PDW-1:0] hist [0:31];
    $display("[pipe_delay] exact latency for 0/1/3/7, then a stall");
    pd_en = 1'b1;
    for (int i = 0; i < 32; i++) hist[i] = PDW'($urandom());

    for (int i = 0; i < 32; i++) begin
      pd_in = hist[i];
      // LATENCY == 0 is a wire: visible in the same cycle it is driven.
      #1;
      chk($sformatf("pd0 i=%0d", i), pd_out0 === hist[i]);
      @(negedge clk);
      if (i >= 0) chk($sformatf("pd1 i=%0d", i), pd_out1 === hist[i]);
      if (i >= 2) chk($sformatf("pd3 i=%0d", i), pd_out3 === hist[i-2]);
      if (i >= 6) chk($sformatf("pd7 i=%0d", i), pd_out7 === hist[i-6]);
    end

    // Stall: every stage must freeze TOGETHER, and resume without losing or
    // duplicating a beat. A frozen-value spot check is too weak for that --
    // after the stall lifts, a 3-deep pipe legitimately advances by one stage,
    // so "still holds the old value" is simply not the property.
    //
    // The real property is "behaves exactly like a shift register that only
    // shifts when en", so model that and compare every cycle under a random
    // stall pattern. This catches loss, duplication, and stages drifting apart.
    begin
      logic [PDW-1:0] ref3 [0:2];
      logic [PDW-1:0] ref7 [0:6];
      foreach (ref3[i]) ref3[i] = 'x;
      foreach (ref7[i]) ref7[i] = 'x;

      // Prime both reference models so they track the DUT's current contents.
      for (int i = 0; i < 16; i++) begin
        pd_en = 1'b1;
        pd_in = PDW'($urandom());
        for (int k = 2; k > 0; k--) ref3[k] = ref3[k-1];
        ref3[0] = pd_in;
        for (int k = 6; k > 0; k--) ref7[k] = ref7[k-1];
        ref7[0] = pd_in;
        @(negedge clk);
      end
      chk("pd3 reference primed", pd_out3 === ref3[2]);
      chk("pd7 reference primed", pd_out7 === ref7[6]);

      for (int i = 0; i < 500; i++) begin
        pd_en = ($urandom_range(99, 0) < 60);   // 40% stall
        pd_in = PDW'($urandom());               // input churns regardless
        if (pd_en) begin
          for (int k = 2; k > 0; k--) ref3[k] = ref3[k-1];
          ref3[0] = pd_in;
          for (int k = 6; k > 0; k--) ref7[k] = ref7[k-1];
          ref7[0] = pd_in;
        end
        @(negedge clk);
        chk($sformatf("pd3 under random stall i=%0d got %h exp %h",
                      i, pd_out3, ref3[2]), pd_out3 === ref3[2]);
        chk($sformatf("pd7 under random stall i=%0d got %h exp %h",
                      i, pd_out7, ref7[6]), pd_out7 === ref7[6]);
      end
      pd_en = 1'b1;
    end
  endtask

  // ===========================================================================
  // pipe_ctrl: valid propagation, stall, flush-while-stalled
  // ===========================================================================
  localparam int PCS = 4;
  logic            pc_en, pc_flush, pc_vi, pc_vo, pc_busy;
  logic [PCS-1:0]  pc_vq;

  pipe_ctrl #(.STAGES(PCS)) u_pc
    (.clk, .rst_n, .en(pc_en), .flush(pc_flush), .valid_i(pc_vi),
     .valid_o(pc_vo), .valid_q(pc_vq), .busy(pc_busy));

  task automatic test_pipe_ctrl();
    $display("[pipe_ctrl] valid propagation, stall, flush while stalled");
    pc_en = 1'b1;  pc_flush = 1'b0;  pc_vi = 1'b0;
    @(negedge clk);
    chk("pc idle: not busy", !pc_busy);

    // A single beat must appear at the output exactly STAGES cycles later.
    pc_vi = 1'b1;  @(negedge clk);  pc_vi = 1'b0;
    for (int i = 1; i < PCS; i++) begin
      chk($sformatf("pc beat in flight at stage %0d", i), pc_busy);
      chk($sformatf("pc output still low at %0d", i), !pc_vo);
      @(negedge clk);
    end
    chk("pc beat emerges after STAGES cycles", pc_vo);
    @(negedge clk);
    chk("pc drained", !pc_busy && !pc_vo);

    // Stall must hold the valid vector exactly.
    pc_vi = 1'b1;  @(negedge clk);
    pc_vi = 1'b0;  pc_en = 1'b0;
    begin
      logic [PCS-1:0] frozen;
      frozen = pc_vq;
      repeat (5) begin
        @(negedge clk);
        chk("pc valid frozen while stalled", pc_vq === frozen);
      end
    end

    // Flush must win over the stall. This is the case that breaks if `en` is
    // tested before `flush`: the pipeline stays full and the stale beats
    // reappear when the stall lifts.
    pc_flush = 1'b1;
    @(negedge clk);
    chk("pc flush clears even while stalled", pc_vq === '0 && !pc_busy);
    pc_flush = 1'b0;  pc_en = 1'b1;
    @(negedge clk);
    chk("pc still empty after the stall lifts", !pc_busy);
  endtask

  // ===========================================================================
  // adder_tree: several N (including non-powers of two), signed and unsigned,
  // combinational and pipelined.
  // ===========================================================================
  localparam int ATW = 8;
  logic at_en;
  logic [16*ATW-1:0] at_flat;

  logic [ATW+0-1:0]  at_o1;   // N=1  -> OW = 8 + clog2(1)=0
  logic [ATW+1-1:0]  at_o2;   // N=2  -> +1
  logic [ATW+2-1:0]  at_o3;   // N=3  -> +2
  logic [ATW+3-1:0]  at_o5;   // N=5  -> +3
  logic [ATW+3-1:0]  at_o8;   // N=8  -> +3
  logic [ATW+4-1:0]  at_o16;  // N=16 -> +4
  logic [ATW+4-1:0]  at_u16;  // unsigned
  logic [ATW+4-1:0]  at_p16;  // pipelined

  adder_tree #(.N(1),  .W(ATW), .SIGNED_OP(1'b1)) u_at1
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat[1*ATW-1:0]),  .dout(at_o1));
  adder_tree #(.N(2),  .W(ATW), .SIGNED_OP(1'b1)) u_at2
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat[2*ATW-1:0]),  .dout(at_o2));
  adder_tree #(.N(3),  .W(ATW), .SIGNED_OP(1'b1)) u_at3
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat[3*ATW-1:0]),  .dout(at_o3));
  adder_tree #(.N(5),  .W(ATW), .SIGNED_OP(1'b1)) u_at5
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat[5*ATW-1:0]),  .dout(at_o5));
  adder_tree #(.N(8),  .W(ATW), .SIGNED_OP(1'b1)) u_at8
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat[8*ATW-1:0]),  .dout(at_o8));
  adder_tree #(.N(16), .W(ATW), .SIGNED_OP(1'b1)) u_at16
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat),             .dout(at_o16));
  adder_tree #(.N(16), .W(ATW), .SIGNED_OP(1'b0)) u_au16
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat),             .dout(at_u16));
  adder_tree #(.N(16), .W(ATW), .SIGNED_OP(1'b1), .PIPE(1'b1)) u_ap16
    (.clk, .rst_n, .en(at_en), .din_flat(at_flat),             .dout(at_p16));

  task automatic test_adder_tree();
    longint ss, su;
    int     lat;
    $display("[adder_tree] N = 1,2,3,5,8,16; signed and unsigned; pipelined");
    at_en = 1'b1;
    lat   = 4;                       // ceil(log2(16)) levels of registers

    for (int t = 0; t < 400; t++) begin
      for (int k = 0; k < 16; k++) at_flat[k*ATW +: ATW] = ATW'($urandom());
      #1;
      // Reference sums, computed in 64-bit so the reference itself cannot
      // overflow -- the point of the test is the DUT's width handling.
      for (int n = 1; n <= 16; n++) begin
        ss = 0;  su = 0;
        for (int k = 0; k < n; k++) begin
          ss += longint'(signed'(at_flat[k*ATW +: ATW]));
          su += longint'({56'b0, at_flat[k*ATW +: ATW]});
        end
        case (n)
          1:  chk($sformatf("at N=1  got %0d exp %0d", signed'(at_o1),  ss),
                  longint'(signed'(at_o1))  == ss);
          2:  chk($sformatf("at N=2  got %0d exp %0d", signed'(at_o2),  ss),
                  longint'(signed'(at_o2))  == ss);
          3:  chk($sformatf("at N=3  got %0d exp %0d", signed'(at_o3),  ss),
                  longint'(signed'(at_o3))  == ss);
          5:  chk($sformatf("at N=5  got %0d exp %0d", signed'(at_o5),  ss),
                  longint'(signed'(at_o5))  == ss);
          8:  chk($sformatf("at N=8  got %0d exp %0d", signed'(at_o8),  ss),
                  longint'(signed'(at_o8))  == ss);
          16: begin
                chk($sformatf("at N=16 signed got %0d exp %0d",
                              signed'(at_o16), ss),
                    longint'(signed'(at_o16)) == ss);
                chk($sformatf("at N=16 unsigned got %0d exp %0d", at_u16, su),
                    longint'({52'b0, at_u16}) == su);
              end
          default: ;
        endcase
      end
      // The pipelined instance lags by one cycle per level.
      @(negedge clk);
    end

    // Check the pipelined tree explicitly, with a known static input held long
    // enough for the answer to emerge.
    for (int k = 0; k < 16; k++) at_flat[k*ATW +: ATW] = ATW'(signed'(-8'sd3));
    repeat (lat + 2) @(negedge clk);
    chk($sformatf("at pipelined 16 x (-3) got %0d exp -48", signed'(at_p16)),
        longint'(signed'(at_p16)) == -48);
  endtask

  // ===========================================================================
  // csa_accumulator vs a plain accumulator: must be EXACT, not close.
  // ===========================================================================
  localparam int CW = 32;
  logic                 csa_clear, csa_valid;
  logic signed [CW-1:0] csa_din, csa_total;
  logic signed [CW-1:0] csa_s, csa_c;

  csa_accumulator #(.W(CW)) u_csa
    (.clk, .rst_n, .clear(csa_clear), .valid(csa_valid), .din(csa_din),
     .total(csa_total), .save_s(csa_s), .save_c(csa_c));

  task automatic test_csa();
    logic signed [CW-1:0] ref_acc;
    $display("[csa_accumulator] 2000 accumulations vs a plain adder");
    csa_clear = 1'b0;  csa_valid = 1'b0;  csa_din = '0;
    @(negedge clk);

    // First beat: clear loads the accumulator with din.
    csa_din   = 32'sd12345;
    csa_clear = 1'b1;
    ref_acc   = 32'sd12345;
    @(negedge clk);
    csa_clear = 1'b0;
    chk($sformatf("csa after clear got %0d exp %0d", csa_total, ref_acc),
        csa_total === ref_acc);

    for (int t = 0; t < 2000; t++) begin
      logic signed [CW-1:0] v;
      // Small values so the 32-bit accumulator cannot overflow across 2000
      // beats; overflow is a sizing question, not what this test is about.
      v = 32'(signed'(20'($urandom())) - 20'sd524288);
      csa_din   = v;
      csa_valid = 1'b1;
      ref_acc   = ref_acc + v;
      @(negedge clk);
      chk($sformatf("csa t=%0d got %0d exp %0d", t, csa_total, ref_acc),
          csa_total === ref_acc);
      // The redundant form must always resolve to the same number.
      chk("csa s+c == total", signed'(csa_s + csa_c) === csa_total);
    end
    csa_valid = 1'b0;
  endtask

  // ===========================================================================
  // acc_interleaved: three shapes, each vs a plain accumulator.
  // ===========================================================================
  localparam int IDW = 18, IACCW = 40;
  logic                    ai_clear, ai_valid;
  logic signed [IDW-1:0]   ai_din;
  logic signed [IACCW-1:0] ai_t11, ai_t41, ai_t44, ai_t82;
  logic                    ai_b11, ai_b41, ai_b44, ai_b82;

  // LANES=1, PIPE=1 is the degenerate case: a plain accumulator.
  acc_interleaved #(.DW(IDW), .ACCW(IACCW), .LANES(1), .PIPE(1)) u_ai11
    (.clk, .rst_n, .clear(ai_clear), .valid(ai_valid), .din(ai_din),
     .total(ai_t11), .busy(ai_b11));
  acc_interleaved #(.DW(IDW), .ACCW(IACCW), .LANES(4), .PIPE(1)) u_ai41
    (.clk, .rst_n, .clear(ai_clear), .valid(ai_valid), .din(ai_din),
     .total(ai_t41), .busy(ai_b41));
  acc_interleaved #(.DW(IDW), .ACCW(IACCW), .LANES(4), .PIPE(4)) u_ai44
    (.clk, .rst_n, .clear(ai_clear), .valid(ai_valid), .din(ai_din),
     .total(ai_t44), .busy(ai_b44));
  acc_interleaved #(.DW(IDW), .ACCW(IACCW), .LANES(8), .PIPE(2)) u_ai82
    (.clk, .rst_n, .clear(ai_clear), .valid(ai_valid), .din(ai_din),
     .total(ai_t82), .busy(ai_b82));

  task automatic test_interleaved();
    logic signed [IACCW-1:0] ref_acc;
    $display("[acc_interleaved] LANES/PIPE = 1/1, 4/1, 4/4, 8/2 vs a plain sum");
    ai_clear = 1'b1;  ai_valid = 1'b0;  ai_din = '0;
    @(negedge clk);
    ai_clear = 1'b0;
    ref_acc  = '0;

    // Drive back-to-back: the whole point is that a deep adder keeps up.
    for (int t = 0; t < 1000; t++) begin
      ai_din   = IDW'($urandom());
      ai_valid = 1'b1;
      ref_acc  = ref_acc + IACCW'(signed'(ai_din));
      @(negedge clk);
    end
    ai_valid = 1'b0;

    // Let every in-flight add land. A pipelined accumulator's total is only
    // meaningful once it has drained -- which is exactly what `busy` is for.
    repeat (16) @(negedge clk);

    chk($sformatf("ai 1/1 got %0d exp %0d", ai_t11, ref_acc), ai_t11 === ref_acc);
    chk($sformatf("ai 4/1 got %0d exp %0d", ai_t41, ref_acc), ai_t41 === ref_acc);
    chk($sformatf("ai 4/4 got %0d exp %0d", ai_t44, ref_acc), ai_t44 === ref_acc);
    chk($sformatf("ai 8/2 got %0d exp %0d", ai_t82, ref_acc), ai_t82 === ref_acc);
    chk("ai drained: not busy", !ai_b11 && !ai_b41 && !ai_b44 && !ai_b82);

    // Clear must zero every lane, not just the selected one.
    ai_clear = 1'b1;  @(negedge clk);  ai_clear = 1'b0;  @(negedge clk);
    chk("ai clear zeroes all lanes",
        ai_t11 === '0 && ai_t41 === '0 && ai_t44 === '0 && ai_t82 === '0);
  endtask

  // ===========================================================================
  // operand_isolation: both modes must give the correct product when enabled.
  // ===========================================================================
  localparam int OAW = 18, OBW = 18;
  logic                       oi_used;
  logic signed [OAW-1:0]      oi_a;
  logic signed [OBW-1:0]      oi_b;
  logic signed [OAW+OBW-1:0]  oi_p_hold, oi_p_zero;

  operand_isolation #(.AW(OAW), .BW(OBW), .ZERO_NOT_HOLD(1'b0)) u_oi_h
    (.clk, .rst_n, .result_used(oi_used), .a(oi_a), .b(oi_b), .product(oi_p_hold));
  operand_isolation #(.AW(OAW), .BW(OBW), .ZERO_NOT_HOLD(1'b1)) u_oi_z
    (.clk, .rst_n, .result_used(oi_used), .a(oi_a), .b(oi_b), .product(oi_p_zero));

  task automatic test_operand_isolation();
    logic signed [OAW+OBW-1:0] exp;
    logic signed [OAW-1:0]     last_a;
    logic signed [OBW-1:0]     last_b;
    $display("[operand_isolation] hold and zero modes, incl. the extreme operands");
    oi_used = 1'b1;
    for (int t = 0; t < 500; t++) begin
      case (t % 5)
        0: begin oi_a = -(1 <<< (OAW-1));     oi_b = -(1 <<< (OBW-1));     end
        1: begin oi_a =  (1 <<< (OAW-1)) - 1; oi_b = -(1 <<< (OBW-1));     end
        2: begin oi_a = '0;                   oi_b = OBW'($urandom());     end
        default: begin oi_a = OAW'($urandom()); oi_b = OBW'($urandom());   end
      endcase
      exp    = oi_a * oi_b;
      last_a = oi_a;  last_b = oi_b;
      #1;
      // Zero mode is combinational: correct in the same cycle.
      chk($sformatf("oi zero t=%0d got %0d exp %0d", t, oi_p_zero, exp),
          oi_p_zero === exp);
      @(negedge clk);
      // Hold mode registers its operands: correct one cycle later.
      chk($sformatf("oi hold t=%0d got %0d exp %0d", t, oi_p_hold, exp),
          oi_p_hold === exp);
    end

    // Disabled: zero mode must read 0; hold mode must keep the last product.
    oi_used = 1'b0;
    oi_a = 18'sd777;  oi_b = 18'sd888;    // churn the inputs
    #1;
    chk("oi zero mode outputs 0 when idle", oi_p_zero === '0);
    @(negedge clk);
    chk("oi hold mode retains the last product",
        oi_p_hold === (last_a * last_b));
  endtask

  // ===========================================================================
  initial begin
    pd_en = 1'b1;  pd_in = '0;
    pc_en = 1'b1;  pc_flush = 1'b0;  pc_vi = 1'b0;
    at_en = 1'b1;  at_flat = '0;
    csa_clear = 1'b0;  csa_valid = 1'b0;  csa_din = '0;
    ai_clear = 1'b0;  ai_valid = 1'b0;  ai_din = '0;
    oi_used = 1'b0;  oi_a = '0;  oi_b = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_pipe_delay();
    test_pipe_ctrl();
    test_adder_tree();
    test_csa();
    test_interleaved();
    test_operand_isolation();

    $display("");
    if (errors == 0) $display("pipeline_tb: PASS");
    else begin
      $display("pipeline_tb: FAIL (%0d errors)", errors);
      $fatal(1, "pipeline test failures");
    end
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
