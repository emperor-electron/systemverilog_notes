// -----------------------------------------------------------------------------
// integration_tb.sv -- timer, wb_slave, and a whole UART peripheral on a bus.
//
// The UART test is the point of this file. uart_periph is assembled entirely
// from modules verified elsewhere, so what is being tested here is the WIRING --
// and specifically the one thing composition can break that none of the parts
// can catch alone: reading the DATA register pops the RX FIFO, so the bus slave
// in front of it must pulse `ren` for exactly one cycle. A slave that holds it
// for the whole transfer eats received bytes in a pattern that depends on its
// wait states.
//
// So the UART is driven through a real wb_slave rather than by poking its
// register port directly. TX is looped back to RX, which means every byte
// written has to survive the transmitter, the wire, the receiver, both FIFOs
// and the bus, in both directions.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module integration_tb;

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
  // timer
  // ===========================================================================
  localparam int unsigned TW = 16;
  logic          t_tick = 1'b1, t_start = 1'b0, t_stop = 1'b0, t_periodic = 1'b0;
  logic [TW-1:0] t_reload = '0, t_count;
  logic          t_running, t_expired;

  timer #(.W(TW)) u_timer (
    .clk, .rst_n, .tick_en(t_tick), .start(t_start), .stop(t_stop),
    .periodic(t_periodic), .reload(t_reload),
    .count(t_count), .running(t_running), .expired(t_expired));

  task automatic test_timer();
    int elapsed, expiries;
    $display("[timer] one-shot, periodic, and start/stop priority");

    // One-shot: reload N means N+1 ticks, and then it stops.
    t_periodic = 1'b0;
    t_reload   = TW'(5);
    t_start    = 1'b1; @(negedge clk); t_start = 1'b0;
    chk("running after start", t_running);

    elapsed = 0;
    while (!t_expired && elapsed < 100) begin
      @(negedge clk);
      elapsed++;
    end
    chk($sformatf("one-shot expired after %0d ticks (want 6)", elapsed),
        elapsed == 6);
    @(negedge clk);
    chk("one-shot stopped at expiry", !t_running);

    // Periodic: keeps firing, at the same interval.
    t_periodic = 1'b1;
    t_reload   = TW'(3);
    t_start    = 1'b1; @(negedge clk); t_start = 1'b0;
    expiries = 0;
    elapsed  = 0;
    repeat (4 * 8) begin
      @(negedge clk);
      elapsed++;
      if (t_expired) expiries++;
    end
    chk($sformatf("periodic fired %0d times in %0d ticks (want 8)",
                  expiries, elapsed), expiries == 8);
    chk("periodic still running", t_running);

    // stop halts it; start beats stop in the same cycle.
    t_stop = 1'b1; @(negedge clk); t_stop = 1'b0;
    chk("stop halts the timer", !t_running);
    t_start = 1'b1; t_stop = 1'b1; @(negedge clk);
    t_start = 1'b0; t_stop = 1'b0;
    chk("start beats stop in the same cycle", t_running);
    t_stop = 1'b1; @(negedge clk); t_stop = 1'b0;
  endtask

  // ===========================================================================
  // Wishbone slave + register bank
  // ===========================================================================
  localparam int unsigned BAW = 4;
  localparam int unsigned BDW = 32;
  localparam int unsigned NB  = BDW / 8;

  logic            c_cyc = 1'b0, c_stb = 1'b0, c_we = 1'b0;
  logic [BAW-1:0]  c_adr = '0;
  logic [BDW-1:0]  c_dat_i = '0;
  logic [NB-1:0]   c_sel = '1;
  logic [BDW-1:0]  c_dat_o;
  logic            c_ack, c_err;

  logic [BAW-1:0]  cr_addr;  logic cr_wen, cr_ren;
  logic [BDW-1:0]  cr_wdata, cr_rdata;
  logic [NB-1:0]   cr_wstrb; logic cr_err;
  logic [4*BDW-1:0] cr_rw_q;
  logic [2*BDW-1:0] cr_ro_d = '0;
  logic [BDW-1:0]   cr_set = '0, cr_stat;

  wb_slave #(.AW(BAW), .DW(BDW)) u_wb_csr (
    .clk, .rst_n,
    .wb_cyc_i(c_cyc), .wb_stb_i(c_stb), .wb_we_i(c_we), .wb_adr_i(c_adr),
    .wb_dat_i(c_dat_i), .wb_sel_i(c_sel), .wb_dat_o(c_dat_o),
    .wb_ack_o(c_ack), .wb_err_o(c_err),
    .reg_addr(cr_addr), .reg_wen(cr_wen), .reg_wdata(cr_wdata),
    .reg_wstrb(cr_wstrb), .reg_ren(cr_ren), .reg_rdata(cr_rdata),
    .reg_err(cr_err));

  csr_bank #(.DW(BDW), .N_RW(4), .N_RO(2), .AW(BAW)) u_csr (
    .clk, .rst_n,
    .addr(cr_addr), .wen(cr_wen), .wdata(cr_wdata), .wstrb(cr_wstrb),
    .ren(cr_ren), .rdata(cr_rdata), .err(cr_err),
    .rw_q(cr_rw_q), .ro_d(cr_ro_d), .status_set(cr_set), .status_q(cr_stat));

  task automatic wb_xfer(input logic we, input logic [BAW-1:0] a,
                         input logic [BDW-1:0] d,
                         output logic [BDW-1:0] q, output logic e);
    int guard;
    c_we = we; c_adr = a; c_dat_i = d;
    c_cyc = 1'b1; c_stb = 1'b1;
    guard = 0;
    while (!c_ack && !c_err && guard < 40) begin
      @(negedge clk);
      guard++;
    end
    q = c_dat_o;
    e = c_err;
    @(negedge clk);
    c_cyc = 1'b0; c_stb = 1'b0; c_we = 1'b0;
    @(negedge clk);
  endtask

  task automatic test_wb();
    logic [BDW-1:0] d;
    logic           e;
    $display("[wb_slave] single-cycle handshake, ERR, and CYC qualification");

    wb_xfer(1'b1, BAW'(0), 32'hC0FF_EE00, d, e);
    chk("wb write acked without error", !e);
    wb_xfer(1'b0, BAW'(0), 32'h0, d, e);
    chk($sformatf("wb read back (%h)", d), d === 32'hC0FF_EE00 && !e);

    // An unmapped address must produce ERR, not a silent ACK.
    wb_xfer(1'b0, BAW'(9), 32'h0, d, e);
    chk("wb read of an unmapped address returns ERR", e);

    // STB without CYC must be ignored entirely -- it belongs to no bus cycle.
    c_stb = 1'b1; c_cyc = 1'b0; c_we = 1'b0; c_adr = BAW'(0);
    repeat (4) @(negedge clk);
    chk("no response to STB without CYC", !c_ack && !c_err);
    c_stb = 1'b0;
    @(negedge clk);
  endtask

  // ===========================================================================
  // uart_periph behind a Wishbone slave, TX looped back to RX
  // ===========================================================================
  localparam int unsigned U_CLK  = 1000;
  localparam int unsigned U_BAUD = 100;        // DIV = 10 clk per bit
  localparam int unsigned U_AW   = 2;

  localparam logic [U_AW-1:0] U_DATA   = U_AW'(0);
  localparam logic [U_AW-1:0] U_STATUS = U_AW'(1);
  localparam logic [U_AW-1:0] U_CTRL   = U_AW'(2);

  logic           u_cyc = 1'b0, u_stb = 1'b0, u_we = 1'b0;
  logic [U_AW-1:0] u_adr = '0;
  logic [BDW-1:0] u_dat_i = '0, u_dat_o;
  logic           u_ack, u_err;

  logic [U_AW-1:0] ur_addr; logic ur_wen, ur_ren;
  logic [BDW-1:0]  ur_wdata, ur_rdata;
  logic [NB-1:0]   ur_wstrb; logic ur_err;
  logic            uart_line, irq_rx, irq_tx;

  wb_slave #(.AW(U_AW), .DW(BDW)) u_wb_uart (
    .clk, .rst_n,
    .wb_cyc_i(u_cyc), .wb_stb_i(u_stb), .wb_we_i(u_we), .wb_adr_i(u_adr),
    .wb_dat_i(u_dat_i), .wb_sel_i(4'hF), .wb_dat_o(u_dat_o),
    .wb_ack_o(u_ack), .wb_err_o(u_err),
    .reg_addr(ur_addr), .reg_wen(ur_wen), .reg_wdata(ur_wdata),
    .reg_wstrb(ur_wstrb), .reg_ren(ur_ren), .reg_rdata(ur_rdata),
    .reg_err(ur_err));

  uart_periph #(.CLK_HZ(U_CLK), .BAUD(U_BAUD), .DEPTH(8),
                .AW(U_AW), .DW(BDW)) u_uart (
    .clk, .rst_n,
    .addr(ur_addr), .wen(ur_wen), .wdata(ur_wdata), .wstrb(ur_wstrb),
    .ren(ur_ren), .rdata(ur_rdata), .err(ur_err),
    .rx(uart_line), .tx(uart_line),          // loopback
    .irq_rx_ready(irq_rx), .irq_tx_empty(irq_tx));

  task automatic uart_xfer(input logic we, input logic [U_AW-1:0] a,
                           input logic [BDW-1:0] d,
                           output logic [BDW-1:0] q);
    int guard;
    u_we = we; u_adr = a; u_dat_i = d;
    u_cyc = 1'b1; u_stb = 1'b1;
    guard = 0;
    while (!u_ack && !u_err && guard < 40) begin
      @(negedge clk);
      guard++;
    end
    q = u_dat_o;
    @(negedge clk);
    u_cyc = 1'b0; u_stb = 1'b0; u_we = 1'b0;
    @(negedge clk);
  endtask

  task automatic test_uart();
    logic [BDW-1:0] d;
    int             guard;
    logic [7:0]     sent [4];
    $display("[uart_periph] loopback through a bus, FIFOs, and overrun");

    sent = '{8'h55, 8'hA3, 8'h00, 8'hFF};

    uart_xfer(1'b0, U_STATUS, 32'h0, d);
    chk("tx fifo starts empty", d[1] === 1'b1);   // tx_empty
    chk("rx fifo starts empty", d[3] === 1'b1);   // rx_empty

    // Push four bytes; they go out, come back, and queue in the RX FIFO.
    for (int i = 0; i < 4; i++)
      uart_xfer(1'b1, U_DATA, BDW'(sent[i]), d);

    // A byte is 10 bit times of 10 clk each; four bytes plus slack.
    guard = 0;
    while (guard < 4 * 10 * 10 * 3) begin
      @(negedge clk);
      guard++;
    end

    chk("rx interrupt asserted after loopback", irq_rx);

    // Read them back, in order. Each read pops exactly one byte.
    for (int i = 0; i < 4; i++) begin
      uart_xfer(1'b0, U_STATUS, 32'h0, d);
      chk($sformatf("rx fifo not empty before read %0d", i), d[3] === 1'b0);
      uart_xfer(1'b0, U_DATA, 32'h0, d);
      chk($sformatf("byte %0d came back as %h (sent %h)", i, d[7:0], sent[i]),
          d[7:0] === sent[i]);
    end

    uart_xfer(1'b0, U_STATUS, 32'h0, d);
    chk("rx fifo empty again after four reads", d[3] === 1'b1);
    chk("no overrun during a well-paced exchange", d[5] === 1'b0);
    chk("no framing error on loopback", d[4] === 1'b0);

    // An address outside the map is an error.
    u_we = 1'b0; u_adr = U_AW'(3); u_cyc = 1'b1; u_stb = 1'b1;
    guard = 0;
    while (!u_ack && !u_err && guard < 40) begin
      @(negedge clk);
      guard++;
    end
    chk("unmapped UART register returns ERR", u_err);
    @(negedge clk);
    u_cyc = 1'b0; u_stb = 1'b0;
    @(negedge clk);
  endtask

  // ===========================================================================
  initial begin
    $display("");
    $display("=== integration_tb ===");

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_timer();
    test_wb();
    test_uart();

    $display("");
    if (errors == 0) $display("integration_tb: PASS");
    else begin
      $display("integration_tb: FAIL (%0d errors)", errors);
      $fatal(1, "integration test failures");
    end
    $finish;
  end

  initial begin
    #20ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
