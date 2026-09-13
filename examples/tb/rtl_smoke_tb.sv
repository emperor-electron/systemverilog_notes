// -----------------------------------------------------------------------------
// rtl_smoke_tb.sv -- self-checking smoke tests for the combinational and
// small-sequential building blocks: arbiters, encoders, Gray codec, CRC, LFSR,
// counter, shift register, and a UART loopback.
//
// Each block is checked against an independently-written reference (a behavioural
// model in the testbench, or a known-answer vector), not against itself.
//
// Run it:
//   $ verilator --binary --timing -Wno-fatal --timescale 1ns/1ps \
//       -o rtl_smoke_tb -y ../rtl ../tb/rtl_smoke_tb.sv && obj_dir/rtl_smoke_tb
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module rtl_smoke_tb;

  int errors = 0;

  task automatic chk(input string what, input logic ok);
    if (!ok) begin
      errors++;
      $display("  FAIL  %s", what);
    end
  endtask

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ===========================================================================
  // Fixed-priority arbiter: grant must be one-hot, a subset of req, and the
  // LOWEST set bit.
  // ===========================================================================
  localparam int NA = 8;
  logic [NA-1:0] af_req, af_grant;
  arb_fixed #(.N(NA)) u_af (.req(af_req), .grant(af_grant));

  task automatic test_arb_fixed();
    logic [NA-1:0] exp;
    $display("[arb_fixed] exhaustive over %0d patterns", 1 << NA);
    for (int v = 0; v < (1 << NA); v++) begin
      af_req = NA'(v);
      #1;
      // Reference: isolate the lowest set bit by a plain search.
      exp = '0;
      for (int i = 0; i < NA; i++)
        if (af_req[i]) begin exp = NA'(1) << i; break; end
      chk($sformatf("arb_fixed req=%b grant=%b exp=%b", af_req, af_grant, exp),
          af_grant === exp);
    end
  endtask

  // ===========================================================================
  // Round-robin arbiter: one-hot, subset of req, grants when any req, and FAIR
  // (every continuously-requesting agent is served).
  // ===========================================================================
  logic [NA-1:0] rr_req, rr_grant;
  logic          rr_valid;
  arb_round_robin #(.N(NA)) u_rr (
    .clk(clk), .rst_n(rst_n), .req(rr_req), .update(1'b1),
    .grant(rr_grant), .valid(rr_valid));

  task automatic test_arb_rr();
    int hits [NA];
    int total;
    $display("[arb_round_robin] fairness with all %0d agents requesting", NA);
    foreach (hits[i]) hits[i] = 0;
    rr_req = '1;                        // everyone wants it, always
    total  = 0;
    repeat (NA * 50) begin
      @(negedge clk);
      chk("rr grant one-hot",      $onehot(rr_grant));
      chk("rr grant subset of req", (rr_grant & ~rr_req) == '0);
      chk("rr valid when req",      rr_valid === 1'b1);
      foreach (hits[i]) if (rr_grant[i]) hits[i]++;
      total++;
    end
    // Perfect round robin: each agent gets within one of total/N.
    foreach (hits[i])
      chk($sformatf("rr fairness agent %0d got %0d of %0d", i, hits[i], total),
          (hits[i] >= (total / NA) - 1) && (hits[i] <= (total / NA) + 1));
    rr_req = '0;
  endtask

  // ===========================================================================
  // Priority encoder / LZC / popcount / Gray codec
  // ===========================================================================
  localparam int NE = 16;
  logic [NE-1:0] pe_in;
  logic [3:0]    pe_idx;
  logic          pe_valid;
  priority_encoder #(.N(NE)) u_pe (.in(pe_in), .idx(pe_idx), .valid(pe_valid));

  logic [31:0] lz_in;
  logic [5:0]  lz_cnt;
  logic        lz_zero;
  lzc #(.N(32)) u_lzc (.in(lz_in), .count(lz_cnt), .all_zero(lz_zero));

  logic [31:0] pc_in;
  logic [5:0]  pc_cnt;
  popcount #(.N(32)) u_pc (.in(pc_in), .count(pc_cnt));

  logic [7:0] g_bin, g_gray, g_gin, g_bout;
  gray_codec #(.W(8)) u_gc (.bin_in(g_bin), .gray_out(g_gray),
                            .gray_in(g_gin), .bin_out(g_bout));

  task automatic test_encoders();
    int exp_idx;
    int exp_lz;
    $display("[priority_encoder] exhaustive over %0d patterns", 1 << NE);
    for (int v = 0; v < (1 << NE); v++) begin
      pe_in = NE'(v);
      #1;
      exp_idx = 0;
      for (int i = 0; i < NE; i++)
        if (pe_in[i]) begin exp_idx = i; break; end
      chk($sformatf("pe in=%h idx=%0d exp=%0d", pe_in, pe_idx, exp_idx),
          (v == 0) ? (pe_valid === 1'b0) : (pe_valid === 1'b1 &&
                                            pe_idx === 4'(exp_idx)));
    end

    $display("[lzc] powers of two, boundaries, and random");
    for (int i = 0; i < 32; i++) begin
      lz_in = 32'd1 << i;  #1;
      chk($sformatf("lzc 1<<%0d = %0d", i, lz_cnt), lz_cnt === 6'(31 - i));
    end
    lz_in = '0;  #1;
    chk("lzc all-zero flag", lz_zero === 1'b1 && lz_cnt === 6'd32);
    for (int t = 0; t < 500; t++) begin
      lz_in = $urandom();  #1;
      exp_lz = 32;
      for (int i = 31; i >= 0; i--)
        if (lz_in[i]) begin exp_lz = 31 - i; break; end
      chk($sformatf("lzc %h = %0d exp %0d", lz_in, lz_cnt, exp_lz),
          lz_cnt === 6'(exp_lz));
    end

    $display("[popcount] random");
    for (int t = 0; t < 500; t++) begin
      int c;
      pc_in = $urandom();  #1;
      c = 0;
      for (int i = 0; i < 32; i++) if (pc_in[i]) c++;
      chk($sformatf("popcount %h = %0d exp %0d", pc_in, pc_cnt, c),
          pc_cnt === 6'(c));
    end

    $display("[gray_codec] round trip, exhaustive, single-bit-change property");
    for (int v = 0; v < 256; v++) begin
      logic [7:0] prev_gray;
      g_bin = 8'(v);  #1;
      g_gin = g_gray; #1;
      chk($sformatf("gray round trip %0d", v), g_bout === 8'(v));
      if (v > 0) begin
        g_bin = 8'(v - 1); #1;
        prev_gray = g_gray;
        g_bin = 8'(v);     #1;
        chk($sformatf("gray single-bit change at %0d", v),
            $countones(g_gray ^ prev_gray) == 1);
      end
    end
  endtask

  // ===========================================================================
  // CRC-32: known-answer test. CRC-32("123456789") == 0xCBF43926.
  // ===========================================================================
  logic        crc_init, crc_en;
  logic [7:0]  crc_data;
  logic [31:0] crc_raw, crc_out;
  crc_parallel #(.DW(8), .CW(32)) u_crc (
    .clk(clk), .rst_n(rst_n), .init(crc_init), .en(crc_en),
    .data(crc_data), .crc(crc_raw), .crc_out(crc_out));

  task automatic test_crc();
    byte unsigned msg [9];
    $display("[crc_parallel] known-answer: CRC-32(\"123456789\")");
    for (int i = 0; i < 9; i++) msg[i] = byte'("1") + byte'(i);
    @(negedge clk);
    crc_init = 1'b1; crc_en = 1'b0;
    @(negedge clk);
    crc_init = 1'b0;
    for (int i = 0; i < 9; i++) begin
      crc_data = msg[i];
      crc_en   = 1'b1;
      @(negedge clk);
    end
    crc_en = 1'b0;
    @(negedge clk);
    chk($sformatf("CRC-32 = %h, expected CBF43926", crc_out),
        crc_out === 32'hCBF4_3926);
  endtask

  // ===========================================================================
  // Galois LFSR: must visit all 2^W - 1 nonzero states exactly once.
  // ===========================================================================
  localparam int LW = 8;
  logic [LW-1:0] lfsr_state;
  logic          lfsr_bit;
  // x^8 + x^6 + x^5 + x^4 + 1 -- a primitive polynomial, so maximal length.
  lfsr_galois #(.W(LW), .POLY(8'h8E), .SEED(8'h01)) u_lfsr (
    .clk(clk), .rst_n(rst_n), .en(1'b1),
    .state(lfsr_state), .bit_out(lfsr_bit));

  task automatic test_lfsr();
    bit seen [1:255];
    int n_new;
    $display("[lfsr_galois] maximal-length check over 2^%0d-1 states", LW);
    foreach (seen[i]) seen[i] = 0;
    n_new = 0;
    for (int i = 0; i < (1 << LW) - 1; i++) begin
      @(negedge clk);
      chk("lfsr never zero", lfsr_state !== '0);
      if (lfsr_state != 0 && !seen[lfsr_state]) begin
        seen[lfsr_state] = 1;
        n_new++;
      end
    end
    chk($sformatf("lfsr visited %0d of %0d nonzero states", n_new,
                  (1 << LW) - 1),
        n_new == (1 << LW) - 1);
  endtask

  // ===========================================================================
  // Counter: wrap, load, up/down.
  // ===========================================================================
  logic       c_en, c_dir, c_load, c_wrap, c_max, c_min;
  logic [3:0] c_loadval, c_q;
  counter #(.WIDTH(4), .MAX(4'hF), .UP_DOWN(1'b1)) u_cnt (
    .clk(clk), .rst_n(rst_n), .en(c_en), .dir(c_dir), .load(c_load),
    .load_val(c_loadval), .q(c_q), .at_max(c_max), .at_min(c_min),
    .wrap(c_wrap));

  task automatic test_counter();
    $display("[counter] up-wrap, down-wrap, load");
    @(negedge clk);
    c_load = 1'b1; c_loadval = 4'd0; c_en = 1'b0; c_dir = 1'b0;
    @(negedge clk);
    c_load = 1'b0; c_en = 1'b1;
    for (int i = 1; i <= 16; i++) begin
      @(negedge clk);
      chk($sformatf("count up %0d got %0d", i % 16, c_q), c_q === 4'(i % 16));
    end
    // wrap pulse should have fired exactly on the 15 -> 0 transition
    chk("counter wrap pulse after 15->0", c_wrap === 1'b1);

    c_dir = 1'b1;                       // count down
    for (int i = 1; i <= 16; i++) begin
      @(negedge clk);
      chk($sformatf("count down got %0d", c_q), c_q === 4'((16 - i) % 16));
    end

    c_load = 1'b1; c_loadval = 4'd7;
    @(negedge clk);
    c_load = 1'b0;
    chk($sformatf("counter load got %0d", c_q), c_q === 4'd7);
    c_en = 1'b0;
  endtask

  // ===========================================================================
  // Shift register: serial out must match the loaded parallel value, MSB first.
  // ===========================================================================
  logic       sr_load, sr_sh, sr_sin, sr_sout, sr_done;
  logic [7:0] sr_din, sr_dout;
  shift_register #(.WIDTH(8), .MSB_FIRST(1'b1)) u_sr (
    .clk(clk), .rst_n(rst_n), .load(sr_load), .din(sr_din),
    .shift_en(sr_sh), .sin(sr_sin), .sout(sr_sout), .dout(sr_dout),
    .done(sr_done));

  task automatic test_shift_register();
    logic [7:0] pattern, captured;
    $display("[shift_register] PISO, MSB first");
    pattern = 8'hB4;
    sr_sin = 1'b0;
    @(negedge clk);
    sr_load = 1'b1; sr_din = pattern; sr_sh = 1'b0;
    @(negedge clk);
    sr_load = 1'b0; sr_sh = 1'b1;
    captured = '0;
    for (int i = 0; i < 8; i++) begin
      captured = {captured[6:0], sr_sout};   // MSB arrives first
      @(negedge clk);
    end
    sr_sh = 1'b0;
    chk($sformatf("shift out %h expected %h", captured, pattern),
        captured === pattern);
    chk("shift register done flag", sr_done === 1'b1);
  endtask

  // ===========================================================================
  // UART loopback: tx -> rx, checking data and the absence of framing errors.
  // ===========================================================================
  localparam int UDIV = 8;              // small divisor to keep the test short
  logic       u_tvalid, u_tready, u_line;
  logic [7:0] u_tdata;
  logic       u_rvalid, u_ferr;
  logic [7:0] u_rdata;

  uart_tx #(.DIV(UDIV), .DW($clog2(UDIV))) u_tx (
    .clk(clk), .rst_n(rst_n), .valid(u_tvalid), .data(u_tdata),
    .ready(u_tready), .tx(u_line));

  uart_rx #(.DIV(UDIV), .DW($clog2(UDIV))) u_rx (
    .clk(clk), .rst_n(rst_n), .rx(u_line), .valid(u_rvalid),
    .data(u_rdata), .frame_err(u_ferr));

  task automatic test_uart();
    logic [7:0] sent [8];
    int got = 0;
    $display("[uart] loopback of 8 bytes at DIV=%0d", UDIV);
    sent[0]=8'h00; sent[1]=8'hFF; sent[2]=8'hA5; sent[3]=8'h5A;
    sent[4]=8'h01; sent[5]=8'h80; sent[6]=8'h7F; sent[7]=8'hC3;

    fork
      begin : sender
        for (int i = 0; i < 8; i++) begin
          @(negedge clk);
          while (!u_tready) @(negedge clk);
          u_tdata  = sent[i];
          u_tvalid = 1'b1;
          @(negedge clk);
          u_tvalid = 1'b0;
          // wait for the frame to finish before offering the next byte
          while (!u_tready) @(negedge clk);
        end
      end
      begin : receiver
        while (got < 8) begin
          @(negedge clk);
          if (u_rvalid) begin
            chk($sformatf("uart byte %0d got %h expected %h",
                          got, u_rdata, sent[got]),
                u_rdata === sent[got]);
            chk($sformatf("uart byte %0d framing", got), u_ferr === 1'b0);
            got++;
          end
        end
      end
    join
    chk($sformatf("uart received %0d of 8 bytes", got), got == 8);
  endtask

  // ===========================================================================
  initial begin
    af_req = '0; rr_req = '0; pe_in = '0; lz_in = '0; pc_in = '0;
    g_bin = '0; g_gin = '0;
    crc_init = 1'b0; crc_en = 1'b0; crc_data = '0;
    c_en = 1'b0; c_dir = 1'b0; c_load = 1'b0; c_loadval = '0;
    sr_load = 1'b0; sr_sh = 1'b0; sr_sin = 1'b0; sr_din = '0;
    u_tvalid = 1'b0; u_tdata = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_arb_fixed();
    test_encoders();
    test_arb_rr();
    test_crc();
    test_lfsr();
    test_counter();
    test_shift_register();
    test_uart();

    $display("");
    if (errors == 0) $display("rtl_smoke_tb: PASS");
    else begin
      $display("rtl_smoke_tb: FAIL (%0d errors)", errors);
      $fatal(1, "smoke test failures");
    end
    $finish;
  end

  initial begin
    #100ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
