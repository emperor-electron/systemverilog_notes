// -----------------------------------------------------------------------------
// techniques_tb.sv -- self-checking tests for the structural-technique modules:
// bin2bcd, mul_const, div_const, ring_counter, sort_network, srl_delay,
// rom_table and useq.
//
// Several of these are ALSO proved exhaustively in formal/ (see docs/25). They
// are simulated as well because simulation and formal catch different things:
// formal proves the function over all inputs but only for the parameter values
// it is elaborated with, while a testbench sweeps parameterizations and exercises
// the sequential glue -- the microcoded sequencer's protocol, the SRL's enable
// behaviour, the ROM's registered output.
//
// Run with XSIM:
//   xvlog -sv <rtl files> techniques_tb.sv && xelab techniques_tb -s sim
//   xsim sim -R
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module techniques_tb;

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
  // bin2bcd -- exhaustive for 8 bits, spot-checked for 16
  // ===========================================================================
  logic [7:0]   b8;
  logic [11:0]  d8;      // 3 digits
  logic [15:0]  b16;
  logic [19:0]  d16;     // 5 digits

  bin2bcd #(.IN_W(8))  u_bcd8  (.bin(b8),  .bcd(d8));
  bin2bcd #(.IN_W(16)) u_bcd16 (.bin(b16), .bcd(d16));

  task automatic test_bin2bcd();
    int val;
    $display("[bin2bcd] exhaustive 8-bit, random 16-bit");
    for (int v = 0; v < 256; v++) begin
      b8 = 8'(v);
      #1;
      // Recompose and compare, and check every nibble is a legal digit.
      val = 100*int'(d8[11:8]) + 10*int'(d8[7:4]) + int'(d8[3:0]);
      chk($sformatf("bcd8 %0d -> %0d (%h)", v, val, d8), val == v);
      chk($sformatf("bcd8 digits legal for %0d", v),
          d8[3:0] <= 9 && d8[7:4] <= 9 && d8[11:8] <= 9);
    end
    for (int t = 0; t < 2000; t++) begin
      b16 = 16'($urandom());
      #1;
      val = 10000*int'(d16[19:16]) + 1000*int'(d16[15:12]) + 100*int'(d16[11:8])
          + 10*int'(d16[7:4]) + int'(d16[3:0]);
      chk($sformatf("bcd16 %0d -> %0d", b16, val), val == int'(b16));
    end
    // Boundaries worth naming.
    b16 = 16'd0;     #1; chk("bcd16 0",     d16 == 20'h00000);
    b16 = 16'd9999;  #1; chk("bcd16 9999",  d16 == 20'h09999);
    b16 = 16'd65535; #1; chk("bcd16 65535", d16 == 20'h65535);
  endtask

  // ===========================================================================
  // mul_const -- CSD and binary encodings must agree with each other AND with *
  // ===========================================================================
  logic [7:0]  m_in;
  logic [15:0] m_csd7, m_bin7, m_csd255, m_bin255, m_csd10;

  mul_const #(.IN_W(8), .CW(8), .C(8'd7),   .USE_CSD(1'b1)) u_m_csd7   (.din(m_in), .dout(m_csd7));
  mul_const #(.IN_W(8), .CW(8), .C(8'd7),   .USE_CSD(1'b0)) u_m_bin7   (.din(m_in), .dout(m_bin7));
  mul_const #(.IN_W(8), .CW(8), .C(8'd255), .USE_CSD(1'b1)) u_m_csd255 (.din(m_in), .dout(m_csd255));
  mul_const #(.IN_W(8), .CW(8), .C(8'd255), .USE_CSD(1'b0)) u_m_bin255 (.din(m_in), .dout(m_bin255));
  mul_const #(.IN_W(8), .CW(8), .C(8'd10),  .USE_CSD(1'b1)) u_m_csd10  (.din(m_in), .dout(m_csd10));

  task automatic test_mul_const();
    $display("[mul_const] exhaustive 8-bit, CSD vs binary vs '*'");
    for (int v = 0; v < 256; v++) begin
      m_in = 8'(v);
      #1;
      chk($sformatf("mul C=7   csd %0d", v),   m_csd7   == 16'(v*7));
      chk($sformatf("mul C=7   bin %0d", v),   m_bin7   == 16'(v*7));
      chk($sformatf("mul C=255 csd %0d", v),   m_csd255 == 16'(v*255));
      chk($sformatf("mul C=255 bin %0d", v),   m_bin255 == 16'(v*255));
      chk($sformatf("mul C=10  csd %0d", v),   m_csd10  == 16'(v*10));
      // The two encodings must be identical in function, differing only in
      // adder count -- that is the whole claim.
      chk($sformatf("csd == bin for C=7   at %0d", v), m_csd7   == m_bin7);
      chk($sformatf("csd == bin for C=255 at %0d", v), m_csd255 == m_bin255);
    end
  endtask

  // ===========================================================================
  // div_const -- exhaustive 8-bit for several divisors; the reciprocal
  // construction must be EXACT, not approximate
  // ===========================================================================
  logic [7:0] q_in;
  logic [7:0] q3, r3, q10, r10, q100, r100, q16, r16, q1, r1;

  div_const #(.W(8), .D(3))   u_d3   (.num(q_in), .quot(q3),   .rem(r3));
  div_const #(.W(8), .D(10))  u_d10  (.num(q_in), .quot(q10),  .rem(r10));
  div_const #(.W(8), .D(100)) u_d100 (.num(q_in), .quot(q100), .rem(r100));
  div_const #(.W(8), .D(16))  u_d16  (.num(q_in), .quot(q16),  .rem(r16));
  div_const #(.W(8), .D(1))   u_d1   (.num(q_in), .quot(q1),   .rem(r1));

  task automatic test_div_const();
    $display("[div_const] exhaustive 8-bit for D = 1, 3, 10, 16, 100");
    for (int v = 0; v < 256; v++) begin
      q_in = 8'(v);
      #1;
      chk($sformatf("div D=1   %0d", v),  q1   == 8'(v/1)   && r1   == 8'(v%1));
      chk($sformatf("div D=3   %0d", v),  q3   == 8'(v/3)   && r3   == 8'(v%3));
      chk($sformatf("div D=10  %0d", v),  q10  == 8'(v/10)  && r10  == 8'(v%10));
      chk($sformatf("div D=16  %0d", v),  q16  == 8'(v/16)  && r16  == 8'(v%16));
      chk($sformatf("div D=100 %0d", v),  q100 == 8'(v/100) && r100 == 8'(v%100));
    end
  endtask

  // ===========================================================================
  // ring_counter -- rotation, and recovery from an illegal state
  // ===========================================================================
  localparam int RN = 6;
  logic          rc_en;
  logic [RN-1:0] rc_q, rc_plain;

  ring_counter #(.N(RN), .SELF_CORRECT(1'b1)) u_rc  (.clk, .rst_n, .en(rc_en), .q(rc_q));
  ring_counter #(.N(RN), .SELF_CORRECT(1'b0)) u_rcp (.clk, .rst_n, .en(rc_en), .q(rc_plain));

  task automatic test_ring_counter();
    $display("[ring_counter] rotation, hold, and self-correction");
    // Sample the reset value BEFORE enabling: `rc_en = 1` followed by a clock
    // edge has already advanced the counter, so checking afterwards tests the
    // wrong cycle.
    rc_en = 1'b0;
    @(negedge clk);
    chk("ring starts at bit 0", rc_q == {{(RN-1){1'b0}}, 1'b1});
    rc_en = 1'b1;
    for (int i = 1; i < 3*RN; i++) begin
      @(negedge clk);
      chk($sformatf("ring one-hot at step %0d", i), $onehot(rc_q));
      chk($sformatf("ring position at step %0d", i),
          rc_q == (RN'(1) << (i % RN)));
    end
    rc_en = 1'b0;
    begin
      logic [RN-1:0] held;
      held = rc_q;
      repeat (4) begin
        @(negedge clk);
        chk("ring holds when disabled", rc_q == held);
      end
    end
    rc_en = 1'b1;

    // Self-correction: force both counters into an illegal all-zero state and
    // check that only the self-correcting one recovers. `force` is a simulation
    // construct -- exactly the kind of fault injection formal does natively by
    // starting from an arbitrary state (docs/25).
    force u_rc.q  = '0;
    force u_rcp.q = '0;
    @(negedge clk);
    release u_rc.q;
    release u_rcp.q;
    repeat (RN + 2) @(negedge clk);
    chk("self-correcting ring recovers to one-hot", $onehot(rc_q));
    chk("plain ring stays dead at zero",            rc_plain == '0);
  endtask

  // ===========================================================================
  // sort_network -- against a reference insertion sort
  // ===========================================================================
  localparam int SN = 9, SW = 8;
  logic [SN*SW-1:0] s_in, s_out;
  logic [SW-1:0]    s_med;

  sort_network #(.N(SN), .W(SW)) u_sort (.din(s_in), .dout(s_out), .median(s_med));

  task automatic test_sort_network();
    logic [SW-1:0] ref_arr [0:SN-1];
    logic [SW-1:0] t;
    $display("[sort_network] %0d elements, random + degenerate cases", SN);
    for (int trial = 0; trial < 500; trial++) begin
      // Include all-equal and already-sorted cases, which often break networks.
      for (int i = 0; i < SN; i++) begin
        case (trial % 4)
          0: ref_arr[i] = SW'($urandom());
          1: ref_arr[i] = SW'(8'hAA);                 // all equal
          2: ref_arr[i] = SW'(i * 8);                 // already ascending
          default: ref_arr[i] = SW'((SN - i) * 8);    // descending
        endcase
        s_in[i*SW +: SW] = ref_arr[i];
      end
      #1;
      // Reference: insertion sort.
      for (int i = 1; i < SN; i++)
        for (int j = i; j > 0; j--)
          if (ref_arr[j] < ref_arr[j-1]) begin
            t = ref_arr[j]; ref_arr[j] = ref_arr[j-1]; ref_arr[j-1] = t;
          end
      for (int i = 0; i < SN; i++)
        chk($sformatf("sort trial %0d element %0d", trial, i),
            s_out[i*SW +: SW] == ref_arr[i]);
      chk($sformatf("median trial %0d", trial), s_med == ref_arr[SN/2]);
    end
  endtask

  // ===========================================================================
  // srl_delay -- exact latency and enable behaviour (vs a reference model)
  // ===========================================================================
  localparam int SD_W = 8, SD_D = 16;
  logic              sd_en;
  logic [SD_W-1:0]   sd_in, sd_out;

  srl_delay #(.WIDTH(SD_W), .DEPTH(SD_D)) u_srl (
    .clk(clk), .en(sd_en), .din(sd_in), .dout(sd_out));

  task automatic test_srl_delay();
    logic [SD_W-1:0] ref_sr [0:SD_D-1];
    $display("[srl_delay] depth %0d, with a random enable pattern", SD_D);
    foreach (ref_sr[i]) ref_sr[i] = '0;
    sd_en = 1'b1;
    // Prime it so the reference and the DUT agree before checking.
    for (int i = 0; i < SD_D; i++) begin
      sd_in = SD_W'($urandom());
      for (int k = SD_D-1; k > 0; k--) ref_sr[k] = ref_sr[k-1];
      ref_sr[0] = sd_in;
      @(negedge clk);
    end
    for (int i = 0; i < 400; i++) begin
      sd_en = ($urandom_range(99,0) < 65);
      sd_in = SD_W'($urandom());
      if (sd_en) begin
        for (int k = SD_D-1; k > 0; k--) ref_sr[k] = ref_sr[k-1];
        ref_sr[0] = sd_in;
      end
      @(negedge clk);
      chk($sformatf("srl step %0d got %h exp %h", i, sd_out, ref_sr[SD_D-1]),
          sd_out == ref_sr[SD_D-1]);
    end
    sd_en = 1'b1;
  endtask

  // ===========================================================================
  // rom_table -- elaboration-computed reciprocal table
  // ===========================================================================
  localparam int RT_AW = 6, RT_FRAC = 12, RT_DW = RT_FRAC + 1;
  logic              rt_en;
  logic [RT_AW-1:0]  rt_addr;
  logic [RT_DW-1:0]  rt_data;

  rom_table #(.AW(RT_AW), .FRAC(RT_FRAC)) u_rom (
    .clk(clk), .en(rt_en), .addr(rt_addr), .data(rt_data));

  task automatic test_rom_table();
    int exp;
    $display("[rom_table] reciprocal table computed at elaboration");
    rt_en = 1'b1;
    for (int a = 0; a < (1 << RT_AW); a++) begin
      rt_addr = RT_AW'(a);
      @(negedge clk);
      if (a == 0) begin
        chk("rom[0] saturates", rt_data == {RT_DW{1'b1}});
      end else begin
        exp = ((1 << RT_FRAC) + (a / 2)) / a;    // round-to-nearest reciprocal
        chk($sformatf("rom[%0d] got %0d exp %0d", a, rt_data, exp),
            int'(rt_data) == exp);
      end
    end
    rt_en = 1'b0;
  endtask

  // ===========================================================================
  // useq -- the microcoded sequencer must walk the protocol in order
  // ===========================================================================
  logic       uq_start;
  logic [1:0] uq_cond;
  logic       uq_bus_req, uq_wr_en, uq_done;
  logic [3:0] uq_pc;

  useq #(.PCW(4)) u_useq (
    .clk(clk), .rst_n(rst_n), .start(uq_start), .cond(uq_cond),
    .bus_req(uq_bus_req), .wr_en(uq_wr_en), .done(uq_done), .pc(uq_pc));

  task automatic test_useq();
    int guard;
    $display("[useq] microcoded sequence: request -> grant -> write -> ack -> done");
    uq_start = 1'b0; uq_cond = 2'b00;
    @(negedge clk);
    chk("useq idle: pc 0, nothing driven",
        uq_pc == 4'd0 && !uq_bus_req && !uq_wr_en && !uq_done);

    // Start. One cycle later the sequencer is at step 1, requesting the bus.
    uq_start = 1'b1; @(negedge clk); uq_start = 1'b0;
    chk("useq step 1 requests the bus", uq_pc == 4'd1 && uq_bus_req);

    // Step 2 polls for grant. With cond[0] low it must SPIN there -- this is
    // the check that failed when the microcode branched on the condition being
    // true instead of false, and the whole protocol ran in six cycles.
    @(negedge clk);
    chk("useq reached the grant poll", uq_pc == 4'd2);
    repeat (4) begin
      @(negedge clk);
      chk("useq spins at the grant poll", uq_pc == 4'd2 && uq_bus_req);
    end

    // Grant it. Next cycle it advances to the write.
    uq_cond[0] = 1'b1;
    @(negedge clk);
    uq_cond[0] = 1'b0;
    chk("useq advances to the write", uq_pc == 4'd3 && uq_wr_en && uq_bus_req);

    // Step 4 polls for ack, and must spin there too.
    @(negedge clk);
    chk("useq reached the ack poll", uq_pc == 4'd4);
    repeat (3) begin
      @(negedge clk);
      chk("useq spins at the ack poll", uq_pc == 4'd4 && !uq_wr_en);
    end

    // Ack it. Next cycle it signals done.
    uq_cond[1] = 1'b1;
    @(negedge clk);
    uq_cond[1] = 1'b0;
    chk("useq reaches done", uq_pc == 4'd5 && uq_done && !uq_bus_req);

    // Then it halts, and stays halted regardless of the condition inputs.
    guard = 0;
    while (uq_pc != 4'd6 && guard < 8) begin @(negedge clk); guard++; end
    chk("useq halts at step 6", uq_pc == 4'd6);
    uq_cond = 2'b11;
    repeat (5) begin
      @(negedge clk);
      chk("useq stays halted", uq_pc == 4'd6 && !uq_bus_req && !uq_wr_en
                               && !uq_done);
    end
    uq_cond = 2'b00;
  endtask

  // ===========================================================================
  initial begin
    b8 = '0; b16 = '0; m_in = '0; q_in = '0;
    rc_en = 1'b0; s_in = '0; sd_en = 1'b0; sd_in = '0;
    rt_en = 1'b0; rt_addr = '0; uq_start = 1'b0; uq_cond = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_bin2bcd();
    test_mul_const();
    test_div_const();
    test_sort_network();
    test_rom_table();
    test_srl_delay();
    test_ring_counter();
    test_useq();

    $display("");
    if (errors == 0) $display("techniques_tb: PASS");
    else begin
      $display("techniques_tb: FAIL (%0d errors)", errors);
      $fatal(1, "technique test failures");
    end
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
