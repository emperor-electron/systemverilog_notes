// -----------------------------------------------------------------------------
// sysmod_tb.sv -- self-checking tests for irq_ctrl, quad_decoder,
// axis_downsizer, axis_upsizer, seven_seg_mux and gpio.
//
// The stream converters are tested round trip as well as individually: a
// sequence through the upsizer and then the downsizer must come back byte for
// byte, with TLAST in the same place. A width converter can be wrong in a way
// that an "did I get the right number of beats" check misses entirely -- lane
// order, and where TLAST lands -- and a round trip catches both.
//
// Packet lengths that are NOT a multiple of the ratio are the interesting case
// for the upsizer, so they are the ones tested most.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module sysmod_tb;

  int errors = 0;

  task automatic chk(input string what, input logic ok);
    if (!ok) begin
      errors++;
      if (errors <= 40) $display("  FAIL  %s", what);
    end
  endtask

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ===========================================================================
  // irq_ctrl
  // ===========================================================================
  localparam int unsigned NIRQ = 8;
  logic [NIRQ-1:0] irq_in = '0, irq_mask = '0, irq_clr = '0;
  logic [NIRQ-1:0] irq_pend, irq_act;
  logic            irq_any, irq_idv;
  logic [2:0]      irq_id;

  irq_ctrl #(.N(NIRQ), .EDGE(1'b1)) u_irq (
    .clk, .rst_n, .irq_in(irq_in), .mask(irq_mask), .clr(irq_clr),
    .pending(irq_pend), .active(irq_act), .irq(irq_any),
    .id(irq_id), .id_valid(irq_idv));

  task automatic irq_pulse(input logic [NIRQ-1:0] bits);
    irq_in = bits;
    @(negedge clk);
    irq_in = '0;
    @(negedge clk);
  endtask

  task automatic test_irq();
    $display("[irq_ctrl] latch, mask-without-discard, priority, W1C");
    irq_mask = 8'hFF;
    @(negedge clk);

    // A one-cycle pulse must be latched.
    irq_pulse(8'b0000_0100);
    chk($sformatf("pulse latched into pending (%b)", irq_pend),
        irq_pend === 8'b0000_0100);
    chk("irq asserted", irq_any);
    chk($sformatf("id is 2 (saw %0d)", irq_id), irq_id === 3'd2 && irq_idv);

    // Lowest index wins.
    irq_pulse(8'b0000_0010);
    chk($sformatf("both pending (%b)", irq_pend), irq_pend === 8'b0000_0110);
    chk($sformatf("lowest index wins: id 1 (saw %0d)", irq_id), irq_id === 3'd1);

    // W1C clears only what is written.
    irq_clr = 8'b0000_0010;
    @(negedge clk);
    irq_clr = '0;
    @(negedge clk);
    chk($sformatf("W1C cleared only bit 1 (%b)", irq_pend),
        irq_pend === 8'b0000_0100);
    irq_clr = 8'hFF;
    @(negedge clk);
    irq_clr = '0;
    @(negedge clk);
    chk("all cleared", irq_pend === 8'h00 && !irq_any);

    // Masking hides from the CPU but must NOT discard.
    irq_mask = 8'h00;
    @(negedge clk);
    irq_pulse(8'b0010_0000);
    chk("masked interrupt still latched", irq_pend === 8'b0010_0000);
    chk("masked interrupt not delivered", !irq_any);
    irq_mask = 8'hFF;
    @(negedge clk);
    chk("unmasking delivers the stored interrupt", irq_any);
    chk($sformatf("id is 5 (saw %0d)", irq_id), irq_id === 3'd5);

    // A new interrupt in the same cycle as its clear must survive.
    irq_clr = 8'hFF;
    irq_in  = 8'b1000_0000;
    @(negedge clk);
    irq_clr = '0;
    irq_in  = '0;
    @(negedge clk);
    chk($sformatf("set beat the simultaneous clear (%b)", irq_pend),
        irq_pend[7] === 1'b1);

    irq_clr = 8'hFF; @(negedge clk); irq_clr = '0; @(negedge clk);
  endtask

  // ===========================================================================
  // quad_decoder
  // ===========================================================================
  logic        qa = 1'b0, qb = 1'b0, qclr = 1'b0;
  logic [15:0] qcount;
  logic        qstep, qdir, qerr;

  quad_decoder #(.CW(16)) u_quad (
    .clk, .rst_n, .a(qa), .b(qb), .clr(qclr),
    .count(qcount), .step(qstep), .dir(qdir), .err(qerr));

  // `qerr` is a one-cycle pulse, so it has to be caught rather than sampled:
  // a check that happens to look a cycle later sees nothing.
  logic err_seen = 1'b0;
  always @(posedge clk) if (qerr) err_seen <= 1'b1;

  // Gray sequence: forward is 00 -> 01 -> 11 -> 10 -> 00
  task automatic quad_move(input int steps, input logic fwd);
    logic [1:0] seq [4];
    int idx;
    seq = '{2'b00, 2'b01, 2'b11, 2'b10};
    idx = 0;
    for (int i = 0; i < 4; i++) if (seq[i] == {qa, qb}) idx = i;
    for (int s = 0; s < steps; s++) begin
      idx = fwd ? ((idx + 1) % 4) : ((idx + 3) % 4);
      {qa, qb} = seq[idx];
      @(negedge clk);
    end
  endtask

  task automatic test_quad();
    logic [15:0] cnt_before;
    $display("[quad_decoder] forward, reverse, and illegal transitions");
    qclr = 1'b1; @(negedge clk); qclr = 1'b0; @(negedge clk);
    {qa, qb} = 2'b00; @(negedge clk); @(negedge clk);

    quad_move(12, 1'b1);
    @(negedge clk);
    chk($sformatf("12 forward steps counted (saw %0d)", qcount), qcount == 16'd12);

    quad_move(5, 1'b0);
    @(negedge clk);
    chk($sformatf("5 reverse steps counted (saw %0d)", qcount), qcount == 16'd7);

    // Both bits changing at once is an error and must not move the count.
    cnt_before = qcount;
    err_seen = 1'b0;
    {qa, qb} = ~{qa, qb};
    @(negedge clk);
    @(negedge clk);
    chk("illegal transition flagged", err_seen);
    chk($sformatf("count unchanged on error (%0d vs %0d)", qcount, cnt_before),
        qcount == cnt_before);

    qclr = 1'b1; @(negedge clk); qclr = 1'b0; @(negedge clk);
    chk("clear zeroes the position", qcount == 16'd0);
  endtask


  // ===========================================================================
  // AXI-Stream width conversion
  // ===========================================================================
  localparam int unsigned RATIO = 4;

  // narrow -> wide -> narrow round trip
  logic [7:0]  up_tdata = '0;  logic up_tvalid = 1'b0, up_tlast = 1'b0;
  logic        up_tready;
  logic [31:0] mid_tdata;      logic [RATIO-1:0] mid_tkeep;
  logic        mid_tvalid, mid_tready, mid_tlast;
  logic [7:0]  dn_tdata;       logic dn_tvalid, dn_tlast;
  logic        dn_tready = 1'b1;

  axis_upsizer #(.DW_IN(8), .RATIO(RATIO)) u_up (
    .clk, .rst_n,
    .s_tdata(up_tdata), .s_tvalid(up_tvalid), .s_tready(up_tready),
    .s_tlast(up_tlast),
    .m_tdata(mid_tdata), .m_tkeep(mid_tkeep), .m_tvalid(mid_tvalid),
    .m_tready(mid_tready), .m_tlast(mid_tlast));

  axis_downsizer #(.DW_OUT(8), .RATIO(RATIO)) u_dn (
    .clk, .rst_n,
    .s_tdata(mid_tdata), .s_tkeep(mid_tkeep), .s_tvalid(mid_tvalid),
    .s_tready(mid_tready), .s_tlast(mid_tlast),
    .m_tdata(dn_tdata), .m_tvalid(dn_tvalid), .m_tready(dn_tready),
    .m_tlast(dn_tlast));

  logic [7:0] rx_q [$];
  int         rx_last_at = -1;

  always @(posedge clk) begin
    if (rst_n && dn_tvalid && dn_tready) begin
      rx_q.push_back(dn_tdata);
      if (dn_tlast) rx_last_at = rx_q.size() - 1;
    end
  end

  task automatic send_packet(input int n);
    for (int i = 0; i < n; i++) begin
      up_tdata  = 8'(i + 1);
      up_tlast  = (i == n - 1);
      up_tvalid = 1'b1;
      while (!up_tready) @(negedge clk);
      @(negedge clk);
    end
    up_tvalid = 1'b0;
    up_tlast  = 1'b0;
  endtask

  task automatic test_axis(input int n, input logic backpressure);
    int guard;
    $display("  packet of %0d beats%s", n,
             backpressure ? " with backpressure" : "");
    rx_q.delete();
    rx_last_at = -1;

    if (backpressure) begin
      fork
        send_packet(n);
        begin
          repeat (n * 3) begin
            dn_tready = 1'b0;
            repeat (2) @(negedge clk);
            dn_tready = 1'b1;
            @(negedge clk);
          end
        end
      join
    end else begin
      send_packet(n);
    end

    dn_tready = 1'b1;
    guard = 0;
    while (rx_q.size() < n && guard < 400) begin
      @(negedge clk);
      guard++;
    end

    chk($sformatf("round trip returned %0d beats (want %0d)", rx_q.size(), n),
        rx_q.size() == n);
    if (rx_q.size() == n) begin
      for (int i = 0; i < n; i++)
        chk($sformatf("beat %0d is %0d (saw %0d)", i, i + 1, rx_q[i]),
            rx_q[i] === 8'(i + 1));
      chk($sformatf("TLAST on the final beat (index %0d, want %0d)",
                    rx_last_at, n - 1), rx_last_at == n - 1);
    end
    repeat (4) @(negedge clk);
  endtask

  task automatic test_axis_all();
    $display("[axis] upsizer -> downsizer round trip, RATIO=%0d", RATIO);
    test_axis(4,  1'b0);      // exactly one group
    test_axis(8,  1'b0);      // two full groups
    test_axis(1,  1'b0);      // shortest possible: a 1-lane last group
    test_axis(5,  1'b0);      // one full group plus a remainder of 1
    test_axis(7,  1'b0);      // remainder of 3
    test_axis(6,  1'b1);      // remainder of 2, under backpressure
  endtask

  // ===========================================================================
  // seven_seg_mux
  // ===========================================================================
  localparam int unsigned SDIG = 4;
  logic [SDIG*4-1:0] ss_value = 16'h1234;
  logic [SDIG-1:0]   ss_blank = '0;
  logic [6:0]        ss_seg;
  logic [SDIG-1:0]   ss_sel;

  seven_seg_mux #(.DIGITS(SDIG), .REFRESH_DIV(8), .BLANK_CYCLES(2),
                  .ACTIVE_LOW(1'b1)) u_ss (
    .clk, .rst_n, .value(ss_value), .blank(ss_blank),
    .seg(ss_seg), .digit_sel(ss_sel));

  task automatic test_seven_seg();
    logic [SDIG-1:0] seen;
    logic [SDIG-1:0] act;
    $display("[seven_seg_mux] one-hot digit select, cycling, blanking");
    seen = '0;
    for (int i = 0; i < 8 * SDIG * 2; i++) begin
      @(negedge clk);
      act = ~ss_sel;                       // ACTIVE_LOW
      chk($sformatf("exactly one digit selected (%b)", ss_sel),
          $countones(act) == 1);
      seen |= act;
    end
    chk($sformatf("every digit was driven (%b)", seen), seen === '1);

    // Blanking a digit must turn its segments off while it is selected.
    ss_blank = 4'b0010;
    repeat (8 * SDIG) begin
      @(negedge clk);
      if ((~ss_sel) == 4'b0010)
        chk("blanked digit shows no segments", ss_seg === 7'b111_1111);
    end
    ss_blank = '0;
  endtask

  // ===========================================================================
  // gpio
  // ===========================================================================
  localparam int unsigned GW = 8;
  logic [GW-1:0] g_dir = '0, g_out = '0, g_pad_i = '0;
  logic [GW-1:0] g_in, g_rise, g_fall, g_pad_o, g_pad_oe;

  gpio #(.W(GW)) u_gpio (
    .clk, .rst_n, .dir(g_dir), .out(g_out),
    .in_sync(g_in), .rise(g_rise), .fall(g_fall),
    .pad_o(g_pad_o), .pad_oe(g_pad_oe), .pad_i(g_pad_i));

  // Edge outputs are one-cycle pulses, so they are latched here rather
  // than sampled -- the same reason as err_seen above.
  logic [GW-1:0] rise_seen = '0, fall_seen = '0;
  always @(posedge clk) if (rst_n) begin
    rise_seen <= rise_seen | g_rise;
    fall_seen <= fall_seen | g_fall;
  end

  task automatic test_gpio();
    int guard;
    $display("[gpio] drive, synchronize, edge pulses");
    g_dir = 8'h0F; g_out = 8'hA5;
    @(negedge clk);
    chk($sformatf("pad_oe follows dir (%h)", g_pad_oe), g_pad_oe === 8'h0F);
    chk($sformatf("pad_o follows out (%h)", g_pad_o),   g_pad_o  === 8'hA5);

    // An input change appears after the synchronizer, not immediately.
    g_pad_i = 8'h80;
    @(negedge clk);
    chk("input not visible before the synchronizer settles", g_in[7] === 1'b0);
    guard = 0;
    while (!g_in[7] && guard < 8) begin
      @(negedge clk);
      guard++;
    end
    chk($sformatf("input visible after %0d cycles", guard), g_in[7] === 1'b1);

    // `rise` is combinational from the synchronized value, so it is high in the
    // SAME cycle g_in goes high -- rise_seen only latches it at the next edge.
    @(negedge clk);

    // The rise pulse for that pin must have fired exactly once.
    chk("rise pulse accompanied the change", rise_seen[7]);
    g_pad_i = 8'h00;
    repeat (6) @(negedge clk);
    chk("fall pulse on the way back down", fall_seen[7]);
  endtask


  // ===========================================================================
  initial begin
    $display("");
    $display("=== sysmod_tb ===");

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_irq();
    test_quad();
    test_axis_all();
    test_seven_seg();
    test_gpio();

    $display("");
    if (errors == 0) $display("sysmod_tb: PASS");
    else begin
      $display("sysmod_tb: FAIL (%0d errors)", errors);
      $fatal(1, "system module test failures");
    end
    $finish;
  end

  initial begin
    #5ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
