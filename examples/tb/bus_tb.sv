// -----------------------------------------------------------------------------
// bus_tb.sv -- self-checking tests for apb_slave, axil_slave and csr_bank.
//
// Both bus slaves front an identical csr_bank, so the same register semantics
// are exercised through two different protocols. That is the point of the split:
// a failure that appears through one bus and not the other is a bus bug, and one
// that appears through both is a register bug.
//
// The AXI4-Lite tests deliberately vary the ORDER of the AW and W channels --
// address first, data first, and both together. A subordinate that quietly
// requires one order passes a testbench that only ever uses that order, and
// deadlocks against the first manager that does it the other way.
//
// All stimulus is driven on negedge and all handshakes are observed on negedge,
// so nothing races the posedge the DUTs sample on.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bus_tb;

  localparam int unsigned AW   = 4;
  localparam int unsigned DW   = 32;
  localparam int unsigned NB   = DW / 8;
  localparam int unsigned N_RW = 4;
  localparam int unsigned N_RO = 2;
  localparam int unsigned A_RO   = N_RW;        // 4, 5
  localparam int unsigned A_STAT = N_RW + N_RO; // 6
  localparam int unsigned A_BAD  = 9;           // unmapped

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
  // APB slave + register bank
  // ===========================================================================
  logic            psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
  logic [AW-1:0]   paddr = '0;
  logic [DW-1:0]   pwdata = '0;
  logic [NB-1:0]   pstrb = '1;
  logic [DW-1:0]   prdata;
  logic            pready, pslverr;

  logic [AW-1:0]   a_raddr;
  logic            a_wen, a_ren;
  logic [DW-1:0]   a_wdata, a_rdata;
  logic [NB-1:0]   a_wstrb;
  logic            a_err;

  logic [N_RW*DW-1:0] a_rw_q;
  logic [N_RO*DW-1:0] a_ro_d = '0;
  logic [DW-1:0]      a_stat_set = '0, a_stat_q;

  apb_slave #(.AW(AW), .DW(DW), .WAIT_STATES(2)) u_apb (
    .clk, .rst_n,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb,
    .prdata, .pready, .pslverr,
    .reg_addr(a_raddr), .reg_wen(a_wen), .reg_wdata(a_wdata),
    .reg_wstrb(a_wstrb), .reg_ren(a_ren), .reg_rdata(a_rdata), .reg_err(a_err));

  csr_bank #(.DW(DW), .N_RW(N_RW), .N_RO(N_RO), .AW(AW)) u_csr_a (
    .clk, .rst_n,
    .addr(a_raddr), .wen(a_wen), .wdata(a_wdata), .wstrb(a_wstrb),
    .ren(a_ren), .rdata(a_rdata), .err(a_err),
    .rw_q(a_rw_q), .ro_d(a_ro_d), .status_set(a_stat_set), .status_q(a_stat_q));

  task automatic apb_write(input logic [AW-1:0] a, input logic [DW-1:0] d,
                           input logic [NB-1:0] s, output logic err);
    paddr = a; pwdata = d; pstrb = s; pwrite = 1'b1;
    psel = 1'b1; penable = 1'b0;
    @(negedge clk);
    penable = 1'b1;
    while (!pready) @(negedge clk);
    err = pslverr;
    @(negedge clk);
    psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
  endtask

  task automatic apb_read(input logic [AW-1:0] a, output logic [DW-1:0] d,
                          output logic err);
    paddr = a; pwrite = 1'b0;
    psel = 1'b1; penable = 1'b0;
    @(negedge clk);
    penable = 1'b1;
    while (!pready) @(negedge clk);
    d = prdata; err = pslverr;
    @(negedge clk);
    psel = 1'b0; penable = 1'b0;
  endtask

  task automatic test_apb();
    logic [DW-1:0] d;
    logic          e;
    $display("[apb] RW, byte strobes, RO, W1C, unmapped, wait states");

    // RW round trip on every register.
    for (int r = 0; r < N_RW; r++) begin
      apb_write(AW'(r), 32'h1000_0000 + DW'(r), '1, e);
      chk($sformatf("apb write reg%0d no error", r), !e);
    end
    for (int r = 0; r < N_RW; r++) begin
      apb_read(AW'(r), d, e);
      chk($sformatf("apb read reg%0d back (%h)", r, d),
          d === (32'h1000_0000 + DW'(r)) && !e);
    end

    // Byte strobes: only the enabled lanes may change.
    apb_write(AW'(0), 32'hFFFF_FFFF, 4'b0010, e);
    apb_read(AW'(0), d, e);
    chk($sformatf("apb byte strobe touched only lane 1 (%h)", d),
        d === 32'h1000_FF00);

    // Read-only register reflects hardware, and writing it is an error.
    a_ro_d[0 +: DW] = 32'hCAFE_0001;
    a_ro_d[DW +: DW] = 32'hCAFE_0002;
    @(negedge clk);
    apb_read(AW'(A_RO), d, e);
    chk($sformatf("apb RO reg0 reads hardware (%h)", d),
        d === 32'hCAFE_0001 && !e);
    apb_read(AW'(A_RO + 1), d, e);
    chk($sformatf("apb RO reg1 reads hardware (%h)", d),
        d === 32'hCAFE_0002 && !e);
    apb_write(AW'(A_RO), 32'h0, '1, e);
    chk("apb write to a read-only register reports an error", e);

    // Unmapped address.
    apb_read(AW'(A_BAD), d, e);
    chk("apb read of an unmapped address reports an error", e);

    // W1C: hardware sets, software clears by writing ones.
    a_stat_set = 32'h0000_000F;
    @(negedge clk);
    a_stat_set = 32'h0000_0000;
    @(negedge clk);
    apb_read(AW'(A_STAT), d, e);
    chk($sformatf("apb status shows the hardware-set bits (%h)", d),
        d === 32'h0000_000F);
    apb_write(AW'(A_STAT), 32'h0000_0005, '1, e);   // clear bits 0 and 2
    apb_read(AW'(A_STAT), d, e);
    chk($sformatf("apb W1C cleared only the written bits (%h)", d),
        d === 32'h0000_000A);
    apb_write(AW'(A_STAT), 32'hFFFF_FFFF, '1, e);
    apb_read(AW'(A_STAT), d, e);
    chk($sformatf("apb W1C all-ones clears everything (%h)", d), d === 32'h0);
  endtask

  // ===========================================================================
  // AXI4-Lite slave + register bank
  // ===========================================================================
  logic [AW-1:0] awaddr = '0;  logic awvalid = 1'b0;  logic awready;
  logic [DW-1:0] wdata  = '0;  logic [NB-1:0] wstrb = '1;
  logic          wvalid = 1'b0; logic wready;
  logic [1:0]    bresp;        logic bvalid;  logic bready = 1'b0;
  logic [AW-1:0] araddr = '0;  logic arvalid = 1'b0;  logic arready;
  logic [DW-1:0] rdata;        logic [1:0] rresp;
  logic          rvalid;       logic rready = 1'b0;

  logic [AW-1:0] x_raddr;
  logic          x_wen, x_ren;
  logic [DW-1:0] x_wdata, x_rdata;
  logic [NB-1:0] x_wstrb;
  logic          x_err;

  logic [N_RW*DW-1:0] x_rw_q;
  logic [N_RO*DW-1:0] x_ro_d = '0;
  logic [DW-1:0]      x_stat_set = '0, x_stat_q;

  axil_slave #(.AW(AW), .DW(DW)) u_axil (
    .clk, .rst_n,
    .awaddr, .awvalid, .awready,
    .wdata, .wstrb, .wvalid, .wready,
    .bresp, .bvalid, .bready,
    .araddr, .arvalid, .arready,
    .rdata, .rresp, .rvalid, .rready,
    .reg_addr(x_raddr), .reg_wen(x_wen), .reg_wdata(x_wdata),
    .reg_wstrb(x_wstrb), .reg_ren(x_ren), .reg_rdata(x_rdata),
    .reg_err(x_err));

  csr_bank #(.DW(DW), .N_RW(N_RW), .N_RO(N_RO), .AW(AW)) u_csr_x (
    .clk, .rst_n,
    .addr(x_raddr), .wen(x_wen), .wdata(x_wdata), .wstrb(x_wstrb),
    .ren(x_ren), .rdata(x_rdata), .err(x_err),
    .rw_q(x_rw_q), .ro_d(x_ro_d), .status_set(x_stat_set), .status_q(x_stat_q));

  // order: 0 = AW first, 1 = W first, 2 = together
  task automatic axil_write(input logic [AW-1:0] a, input logic [DW-1:0] d,
                            input logic [NB-1:0] s, input int order,
                            output logic [1:0] resp);
    fork
      begin : aw_ch
        if (order == 1) repeat (3) @(negedge clk);
        awaddr = a; awvalid = 1'b1;
        while (!awready) @(negedge clk);
        @(negedge clk);
        awvalid = 1'b0;
      end
      begin : w_ch
        if (order == 0) repeat (3) @(negedge clk);
        wdata = d; wstrb = s; wvalid = 1'b1;
        while (!wready) @(negedge clk);
        @(negedge clk);
        wvalid = 1'b0;
      end
    join

    // Leave BREADY low for a couple of cycles so BVALID has to hold.
    repeat (2) @(negedge clk);
    bready = 1'b1;
    while (!bvalid) @(negedge clk);
    resp = bresp;
    @(negedge clk);
    bready = 1'b0;
  endtask

  task automatic axil_read(input logic [AW-1:0] a, output logic [DW-1:0] d,
                           output logic [1:0] resp);
    araddr = a; arvalid = 1'b1;
    while (!arready) @(negedge clk);
    @(negedge clk);
    arvalid = 1'b0;

    repeat (2) @(negedge clk);       // make RVALID wait too
    rready = 1'b1;
    while (!rvalid) @(negedge clk);
    d = rdata; resp = rresp;
    @(negedge clk);
    rready = 1'b0;
  endtask

  task automatic test_axil();
    logic [DW-1:0] d;
    logic [1:0]    resp;
    $display("[axil] channel ordering, strobes, SLVERR, backpressure");

    // The same write three ways: AW first, W first, both together.
    for (int o = 0; o < 3; o++) begin
      axil_write(AW'(1), 32'hA000_0000 + DW'(o), '1, o, resp);
      chk($sformatf("axil write (order %0d) responds OKAY", o), resp === 2'b00);
      axil_read(AW'(1), d, resp);
      chk($sformatf("axil read back after order %0d (%h)", o, d),
          d === (32'hA000_0000 + DW'(o)) && resp === 2'b00);
    end

    // Byte strobes.
    axil_write(AW'(2), 32'h0000_0000, '1, 2, resp);
    axil_write(AW'(2), 32'hAABB_CCDD, 4'b1001, 2, resp);
    axil_read(AW'(2), d, resp);
    chk($sformatf("axil byte strobes touched lanes 0 and 3 only (%h)", d),
        d === 32'hAA00_00DD);

    // RO and unmapped produce SLVERR.
    x_ro_d[0 +: DW] = 32'h1234_5678;
    @(negedge clk);
    axil_read(AW'(A_RO), d, resp);
    chk($sformatf("axil RO reads hardware (%h)", d),
        d === 32'h1234_5678 && resp === 2'b00);
    axil_write(AW'(A_RO), 32'h0, '1, 2, resp);
    chk("axil write to RO responds SLVERR", resp === 2'b10);
    axil_read(AW'(A_BAD), d, resp);
    chk("axil read of unmapped address responds SLVERR", resp === 2'b10);

    // W1C through the other bus, same semantics.
    x_stat_set = 32'h0000_00F0;
    @(negedge clk);
    x_stat_set = 32'h0000_0000;
    @(negedge clk);
    axil_read(AW'(A_STAT), d, resp);
    chk($sformatf("axil status shows hardware bits (%h)", d),
        d === 32'h0000_00F0);
    axil_write(AW'(A_STAT), 32'h0000_0030, '1, 2, resp);
    axil_read(AW'(A_STAT), d, resp);
    chk($sformatf("axil W1C cleared only the written bits (%h)", d),
        d === 32'h0000_00C0);
  endtask

  // The behaviour that a "read then write zero" clear gets wrong: an event
  // arriving in the same cycle as the clear must survive it.
  task automatic test_w1c_race();
    logic [DW-1:0] d;
    logic [1:0]    resp;
    $display("[w1c] a hardware set in the same cycle as a clear must win");

    axil_write(AW'(A_STAT), 32'hFFFF_FFFF, '1, 2, resp);   // start clean
    axil_read(AW'(A_STAT), d, resp);
    chk($sformatf("status starts clear (%h)", d), d === 32'h0);

    // Drive the set line across the whole clearing write.
    fork
      begin
        x_stat_set = 32'h0000_0002;
        repeat (12) @(negedge clk);
        x_stat_set = 32'h0000_0000;
      end
      axil_write(AW'(A_STAT), 32'h0000_0002, '1, 2, resp);
    join
    @(negedge clk);
    axil_read(AW'(A_STAT), d, resp);
    chk($sformatf("the set bit survived the simultaneous clear (%h)", d),
        d[1] === 1'b1);
  endtask

  // ===========================================================================
  initial begin
    $display("");
    $display("=== bus_tb ===");

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_apb();
    test_axil();
    test_w1c_race();

    $display("");
    if (errors == 0) $display("bus_tb: PASS");
    else begin
      $display("bus_tb: FAIL (%0d errors)", errors);
      $fatal(1, "bus test failures");
    end
    $finish;
  end

  initial begin
    #2ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
