// -----------------------------------------------------------------------------
// serial_tb.sv -- self-checking tests for spi_master, spi_slave and i2c_master.
//
// SPI is tested master-against-slave rather than against a model: the two
// modules are wired together and exchange bytes in BOTH directions
// simultaneously, in all four modes and both bit orders. That is a stronger
// check than either against a testbench model, because a sign error in "which
// edge samples" would have to be made identically in both to cancel out -- and
// the master samples on the system clock while the slave oversamples, so it
// cannot be the same mistake twice.
//
// I2C is tested against a behavioural slave driving a wired-AND bus model,
// because that is the only way to exercise the two features that make I2C
// awkward: the slave ACKing by pulling SDA low, and the slave STRETCHING the
// clock by holding SCL low after the master releases it.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module serial_tb;

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
  // SPI: four modes x two bit orders, master wired to slave
  // ===========================================================================
  localparam int unsigned SPI_DIV = 8;      // 8 clk per SCLK half period

  logic [7:0] spi_mtx = 8'h00, spi_stx = 8'h00;
  logic [7:0] m_start_v = 8'h00;            // one start bit per configuration

  logic [7:0] m_ready, m_done, s_rxv;
  logic [7:0] m_rx [8];
  logic [7:0] s_rx [8];

  // cfg 0..3 = modes 0..3, MSB first.  cfg 4..7 = the same, LSB first.
  for (genvar c = 0; c < 8; c++) begin : g_cfg
    localparam bit CPOLp = bit'((c / 2) % 2);
    localparam bit CPHAp = bit'(c % 2);
    localparam bit MSBp  = bit'(c < 4);

    logic sclk, mosi, miso, cs_n, miso_oe;

    spi_master #(.DW(8), .CLK_DIV(SPI_DIV), .CPOL(CPOLp), .CPHA(CPHAp),
                 .MSB_FIRST(MSBp)) u_m (
      .clk, .rst_n,
      .start(m_start_v[c]), .tx_data(spi_mtx), .ready(m_ready[c]),
      .rx_data(m_rx[c]), .done(m_done[c]),
      .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n));

    spi_slave #(.DW(8), .CPOL(CPOLp), .CPHA(CPHAp), .MSB_FIRST(MSBp)) u_s (
      .clk, .rst_n,
      .sclk(sclk), .mosi(mosi), .cs_n(cs_n), .miso(miso), .miso_oe(miso_oe),
      .tx_data(spi_stx), .rx_data(s_rx[c]), .rx_valid(s_rxv[c]));
  end

  task automatic spi_xfer(input int c, input logic [7:0] mdat,
                                       input logic [7:0] sdat);
    int guard;
    spi_mtx = mdat;
    spi_stx = sdat;
    @(negedge clk);

    chk($sformatf("cfg%0d master ready before start", c), m_ready[c]);
    m_start_v[c] = 1'b1;
    @(negedge clk);
    m_start_v[c] = 1'b0;

    guard = 0;
    while (!m_done[c] && guard < 40 * SPI_DIV) begin
      @(negedge clk);
      guard++;
    end
    chk($sformatf("cfg%0d transfer completed", c), m_done[c]);

    // Both directions, same transfer.
    chk($sformatf("cfg%0d master received %h (sent by slave: %h)",
                  c, m_rx[c], sdat), m_rx[c] === sdat);
    chk($sformatf("cfg%0d slave received %h (sent by master: %h)",
                  c, s_rx[c], mdat), s_rx[c] === mdat);

    repeat (SPI_DIV) @(negedge clk);
  endtask

  task automatic test_spi();
    $display("[spi] 4 modes x 2 bit orders, master <-> slave, both directions");
    for (int c = 0; c < 8; c++) begin
      $display("  cfg%0d ...", c);
      spi_xfer(c, 8'hA5, 8'h3C);
      spi_xfer(c, 8'h00, 8'hFF);       // all-zero and all-one, the easy corners
      spi_xfer(c, 8'hFF, 8'h00);
      spi_xfer(c, 8'h01, 8'h80);       // single bit at each end
    end
  endtask

  // ===========================================================================
  // I2C: wired-AND bus, behavioural slave
  // ===========================================================================
  localparam int unsigned I2C_DIV4  = 4;      // short, so simulation is quick
  localparam logic [6:0]  SLV_ADDR  = 7'h42;

  logic       i2c_cmd_valid = 1'b0;
  logic [1:0] i2c_cmd      = 2'd0;
  logic [7:0] i2c_wdata    = 8'h00;
  logic       i2c_nack_in  = 1'b0;
  logic       i2c_cmd_ready, i2c_done, i2c_busy, i2c_ack, i2c_arb_lost;
  logic [7:0] i2c_rdata;
  logic       m_scl_oe, m_sda_oe;

  // The slave's two pull-downs, plus its clock-stretch pull-down.
  logic slv_sda_low = 1'b0;
  logic slv_scl_low = 1'b0;

  // The bus itself: a wired AND with a pull-up. Nobody drives a one.
  wire scl = (m_scl_oe || slv_scl_low) ? 1'b0 : 1'b1;
  wire sda = (m_sda_oe || slv_sda_low) ? 1'b0 : 1'b1;

  i2c_master #(.DIV4(I2C_DIV4)) u_i2c (
    .clk, .rst_n,
    .cmd_valid(i2c_cmd_valid), .cmd(i2c_cmd), .wdata(i2c_wdata),
    .nack_in(i2c_nack_in), .cmd_ready(i2c_cmd_ready), .rdata(i2c_rdata),
    .ack_out(i2c_ack), .done(i2c_done), .busy(i2c_busy),
    .arb_lost(i2c_arb_lost),
    .scl_oe(m_scl_oe), .scl_i(scl), .sda_oe(m_sda_oe), .sda_i(sda));

  localparam logic [1:0] C_START = 2'd0;
  localparam logic [1:0] C_WRITE = 2'd1;
  localparam logic [1:0] C_READ  = 2'd2;
  localparam logic [1:0] C_STOP  = 2'd3;

  task automatic i2c_do(input logic [1:0] c, input logic [7:0] d,
                        input logic nk);
    int guard;
    while (!i2c_cmd_ready) @(negedge clk);
    i2c_cmd       = c;
    i2c_wdata     = d;
    i2c_nack_in   = nk;
    i2c_cmd_valid = 1'b1;
    @(negedge clk);
    i2c_cmd_valid = 1'b0;

    guard = 0;
    while (!i2c_done && guard < 200 * I2C_DIV4) begin
      @(negedge clk);
      guard++;
    end
    chk($sformatf("i2c command %0d completed", c), i2c_done);
    @(negedge clk);
  endtask

  // ---- behavioural slave ---------------------------------------------------
  //
  // Driven by SCL edges as a state machine rather than as a sequence of
  // blocking tasks. The task-based version of this model was the source of the
  // first failure here: it watched for a STOP with `fork ... join_any`, and
  // since that branch completed on ANY rise of SDA rather than only one while
  // SCL was high, join_any killed the byte receiver every time the master
  // clocked out a 1 bit. An edge-driven model has no such races.
  //
  // Slot numbering: 0..7 are the data bits, 8 is the ACK slot. Sampling happens
  // on the SCL rise; whoever drives the next slot sets up on the SCL fall.
  typedef enum logic [1:0] { SL_IDLE, SL_ADDR, SL_WR, SL_RD } sst_e;

  sst_e       sst  = SL_IDLE;
  int         slot = 0;
  logic [7:0] sbyte, tx_cur;
  logic       s_rw, addr_match, master_ack;
  // Pairs each SCL fall with the rise before it. Without this, the falling edge
  // that ENDS a START condition counts as a bit-slot boundary, the address byte
  // loses its last bit, and the slave ACKs in the wrong slot -- which is
  // exactly how the first version of this model failed.
  logic       seen_rise = 1'b0;
  int         ridx;

  logic [7:0] slv_mem [4];
  int         slv_wr_n = 0;
  logic [7:0] slv_wr [8];
  logic       slv_saw_stop = 1'b0;
  logic       slv_stretch = 1'b0;
  int         slv_stretch_cycles = 6;

  // START: SDA falls while SCL is high.
  always @(negedge sda) if (scl === 1'b1) begin
    sst         = SL_ADDR;
    slot        = 0;
    sbyte       = 8'h00;
    ridx        = 0;
    seen_rise   = 1'b0;
    slv_sda_low = 1'b0;
  end

  // STOP: SDA rises while SCL is high.
  always @(posedge sda) if (scl === 1'b1) begin
    if (sst != SL_IDLE) slv_saw_stop = 1'b1;
    sst         = SL_IDLE;
    slv_sda_low = 1'b0;
  end

  // Sample on the rising edge of SCL.
  always @(posedge scl) begin
    if (sst != SL_IDLE) begin
      if (slot < 8) begin
        if (sst == SL_ADDR || sst == SL_WR) sbyte = {sbyte[6:0], sda};
      end else begin
        if (sst == SL_RD) master_ack = ~sda; // low from the master means ACK
      end
      seen_rise = 1'b1;
    end
  end

  // Set up the next slot on the falling edge of SCL.
  always @(negedge scl) begin
    if ((sst != SL_IDLE) && seen_rise) begin
      seen_rise = 1'b0;
      if (slot < 7) begin
        slot = slot + 1;
        slv_sda_low = (sst == SL_RD) ? ~tx_cur[7 - slot] : 1'b0;
      end else if (slot == 7) begin
        slot = 8;
        unique case (sst)
          SL_ADDR: begin
            s_rw        = sbyte[0];
            addr_match  = (sbyte[7:1] == SLV_ADDR);
            slv_sda_low = addr_match;        // pull low to ACK
          end
          SL_WR: begin
            slv_wr[slv_wr_n] = sbyte;
            slv_wr_n         = slv_wr_n + 1;
            slv_sda_low      = 1'b1;         // always ACK data
          end
          default: slv_sda_low = 1'b0;       // SL_RD: release for master's ACK
        endcase
      end else begin
        slot  = 0;
        sbyte = 8'h00;
        unique case (sst)
          SL_ADDR: begin
            if (!addr_match) begin
              sst         = SL_IDLE;
              slv_sda_low = 1'b0;
            end else if (s_rw) begin
              sst         = SL_RD;
              tx_cur      = slv_mem[ridx % 4];
              ridx        = ridx + 1;
              slv_sda_low = ~tx_cur[7];
            end else begin
              sst         = SL_WR;
              slv_sda_low = 1'b0;
            end
          end
          SL_WR: slv_sda_low = 1'b0;
          default: begin                     // SL_RD
            if (master_ack) begin
              tx_cur      = slv_mem[ridx % 4];
              ridx        = ridx + 1;
              slv_sda_low = ~tx_cur[7];
            end else begin
              sst         = SL_IDLE;         // NACK: the master is finished
              slv_sda_low = 1'b0;
            end
          end
        endcase
      end
    end
  end

  // Optional clock stretching: hold SCL low for a while after the master takes
  // it low, so it is still low when the master tries to release it.
  always @(negedge scl) begin
    if (slv_stretch) begin
      slv_scl_low = 1'b1;
      repeat (slv_stretch_cycles) @(posedge clk);
      slv_scl_low = 1'b0;
    end
  end

  task automatic test_i2c();
    $display("[i2c] address, write, read, ACK/NACK, and clock stretching");

    slv_mem[0] = 8'hDE; slv_mem[1] = 8'hAD;
    slv_mem[2] = 8'hBE; slv_mem[3] = 8'hEF;

    // ---- write two bytes -------------------------------------------------
    slv_wr_n = 0; slv_saw_stop = 1'b0;
    i2c_do(C_START, 8'h00, 1'b0);
    i2c_do(C_WRITE, {SLV_ADDR, 1'b0}, 1'b0);
    chk("slave ACKed its address", !i2c_ack);
    i2c_do(C_WRITE, 8'h11, 1'b0);
    chk("slave ACKed data byte 0", !i2c_ack);
    i2c_do(C_WRITE, 8'h22, 1'b0);
    chk("slave ACKed data byte 1", !i2c_ack);
    i2c_do(C_STOP, 8'h00, 1'b0);
    repeat (8 * I2C_DIV4) @(negedge clk);
    chk($sformatf("slave received 2 bytes (saw %0d)", slv_wr_n), slv_wr_n == 2);
    if (slv_wr_n >= 2) begin
      chk($sformatf("byte 0 is 11 (saw %h)", slv_wr[0]), slv_wr[0] === 8'h11);
      chk($sformatf("byte 1 is 22 (saw %h)", slv_wr[1]), slv_wr[1] === 8'h22);
    end

    // ---- an address nobody answers --------------------------------------
    i2c_do(C_START, 8'h00, 1'b0);
    i2c_do(C_WRITE, {7'h55, 1'b0}, 1'b0);
    chk("unaddressed slave does not ACK", i2c_ack);
    i2c_do(C_STOP, 8'h00, 1'b0);
    repeat (8 * I2C_DIV4) @(negedge clk);

    // ---- read two bytes, NACK the last ----------------------------------
    i2c_do(C_START, 8'h00, 1'b0);
    i2c_do(C_WRITE, {SLV_ADDR, 1'b1}, 1'b0);
    chk("slave ACKed a read address", !i2c_ack);
    i2c_do(C_READ, 8'h00, 1'b0);              // ACK: more to come
    chk($sformatf("read byte 0 is DE (saw %h)", i2c_rdata), i2c_rdata === 8'hDE);
    i2c_do(C_READ, 8'h00, 1'b1);              // NACK: last byte
    chk($sformatf("read byte 1 is AD (saw %h)", i2c_rdata), i2c_rdata === 8'hAD);
    i2c_do(C_STOP, 8'h00, 1'b0);
    repeat (8 * I2C_DIV4) @(negedge clk);

    // ---- the same write, with the slave stretching the clock -------------
    // If the master ignored scl_i, the data would be corrupted here and
    // identical without stretching -- which is why this is the same transfer.
    slv_stretch = 1'b1;
    slv_wr_n = 0; slv_saw_stop = 1'b0;
    i2c_do(C_START, 8'h00, 1'b0);
    i2c_do(C_WRITE, {SLV_ADDR, 1'b0}, 1'b0);
    chk("slave ACKed its address while stretching", !i2c_ack);
    i2c_do(C_WRITE, 8'h5A, 1'b0);
    chk("slave ACKed data while stretching", !i2c_ack);
    i2c_do(C_STOP, 8'h00, 1'b0);
    repeat (16 * I2C_DIV4) @(negedge clk);
    chk($sformatf("stretched write delivered 1 byte (saw %0d)", slv_wr_n),
        slv_wr_n == 1);
    if (slv_wr_n >= 1)
      chk($sformatf("stretched byte is 5A (saw %h)", slv_wr[0]),
          slv_wr[0] === 8'h5A);
    slv_stretch = 1'b0;

    chk("no arbitration loss on a single-master bus", !i2c_arb_lost);
  endtask

  // ===========================================================================
  initial begin
    $display("");
    $display("=== serial_tb ===");

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    test_spi();
    test_i2c();

    $display("");
    if (errors == 0) $display("serial_tb: PASS");
    else begin
      $display("serial_tb: FAIL (%0d errors)", errors);
      $fatal(1, "serial interface test failures");
    end
    $finish;
  end

  initial begin
    #500ms;
    $fatal(1, "GLOBAL TIMEOUT");
  end

endmodule
