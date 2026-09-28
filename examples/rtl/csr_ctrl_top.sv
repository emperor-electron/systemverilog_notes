// -----------------------------------------------------------------------------
// csr_ctrl_top.sv -- the whole path from a processor store to a configured
// datapath, with the commit point in it.
//
//   AXI4-Lite  ->  axil_slave  ->  csr_bank  ->  csr_shadow  ->  cfg_burst_fsm
//                                                            \-> cfg_pipe_scale
//
// Everything here already existed except the shadow. That is the point: adding
// safe reconfiguration to a design that already has a register bank is one module
// and a `safe` signal, not a redesign.
//
// REGISTER MAP (byte offsets; the bus is 32-bit and the index is addr[5:2])
//
//   0x00  SCALE0  RW   [15:0] gain      [19:16] shift
//   0x04  SCALE1  RW   [11:0] lo        [27:16] hi
//   0x08  BURST0  RW   [11:0] len       [23:16] stride     [24] hdr_en
//   0x0C  BURST1  RW   [15:0] base
//   0x10  STATUS  RO   [0] cfg_pending  [1] cfg_lock  [2] burst_busy  [3] dp_busy
//   0x14  ACTIVE_BURST0  RO   what the hardware is USING, not what was written
//   0x18  ACTIVE_SCALE0  RO   likewise
//   0x1C  EVENT   W1C  [0] burst done   [1] configuration applied
//   0x20  CTRL    WO   [0] arm (commit) [1] start burst      -- write strobes
//
// FOUR THINGS IN THIS MAP EARN THEIR KEEP
//
// 1. CTRL IS NOT A REGISTER. It is an address that is decoded and discarded. A
//    real flop that software sets and hardware clears cannot be read back
//    usefully -- software sees "still set" and cannot distinguish "not started"
//    from "nearly finished" -- and the clear races the set. A command is an event,
//    so it is a write strobe. It lives outside csr_bank's map, and the bank's
//    "unmapped address" error is masked for it.
//
// 2. ACTIVE_* MIRRORS EXIST. Reading back 0x08 tells software what it wrote.
//    Reading back 0x14 tells it what the hardware is actually using. Those are
//    different values for as long as a commit is pending, and having both is the
//    difference between debugging a stuck engine in a minute and in a day. Cost:
//    wires.
//
// 3. EVENT.applied IS AN INTERRUPT SOURCE. The arm/commit handshake is
//    asynchronous with respect to software -- the commit happens whenever the
//    consumer next becomes safe, which may be thousands of cycles later. Polling
//    STATUS.cfg_pending works; a W1C event bit means software does not have to.
//    csr_bank makes the hardware set win over a simultaneous software clear,
//    which is what stops the completion of a long-delayed commit from vanishing.
//
// 4. WRITES ARE LOCKED OUT WHILE A COMMIT IS PENDING, and a write in that window
//    is both SUPPRESSED and reported as SLVERR. Reporting alone would not be
//    enough: the write would still land in the staged copy and could still be
//    published by the commit it raced, so software would get an error for a
//    corruption that happened anyway. Suppress first, then report.
//
// THE COMMIT WINDOW IS AN INTERSECTION
//
//   assign cfg_safe = burst_safe && dp_safe;
//
// One line, and it is the composition cost of this whole scheme: a bank shared
// between N consumers can only commit when ALL of them are safe. Here the scaler
// runs in TRAVEL mode so `dp_safe` is constantly high, and the window is just
// "the burst engine is idle". Build the scaler in QUIESCE mode instead and the
// window becomes "burst idle AND pipeline empty", which at a high input rate can
// be never -- a configuration update that is refused forever, by construction,
// with nothing anywhere reporting an error. That is the argument for paying the
// 52 flops.
//
// See docs/39-control-registers-and-safe-reconfiguration.md.
// -----------------------------------------------------------------------------
`default_nettype none

module csr_ctrl_top #(
  parameter int unsigned AWB = 6,    // AXI byte-address width: 16 registers
  parameter int unsigned DW  = 32
) (
  input  var logic                             clk,
  input  var logic                             rst_n,

  // ---- AXI4-Lite from the processing system --------------------------------
  input  var logic [AWB-1:0]                   awaddr,
  input  var logic                             awvalid,
  output var logic                             awready,
  input  var logic [DW-1:0]                    wdata,
  input  var logic [DW/8-1:0]                  wstrb,
  input  var logic                             wvalid,
  output var logic                             wready,
  output var logic [1:0]                       bresp,
  output var logic                             bvalid,
  input  var logic                             bready,
  input  var logic [AWB-1:0]                   araddr,
  input  var logic                             arvalid,
  output var logic                             arready,
  output var logic [DW-1:0]                    rdata,
  output var logic [1:0]                       rresp,
  output var logic                             rvalid,
  input  var logic                             rready,

  // ---- the configured datapath ---------------------------------------------
  input  var logic                             dp_en,
  input  var logic                             x_valid,
  input  var logic signed [cfg_pkg::XW-1:0]    x,
  output var logic                             y_valid,
  output var logic signed [cfg_pkg::YW-1:0]    y,

  // ---- the configured engine ------------------------------------------------
  output var logic                             m_valid,
  output var logic [cfg_pkg::ADDRW-1:0]        m_addr,
  output var logic [cfg_pkg::KINDW-1:0]        m_kind,
  input  var logic                             m_ready,

  output var logic                             irq
);

  localparam int unsigned N_RW  = 4;
  localparam int unsigned N_RO  = 3;
  localparam int unsigned BAW   = 4;                 // register-index width
  localparam logic [BAW-1:0] A_CTRL = 4'd8;          // outside csr_bank's map

  // ===========================================================================
  // Bus subordinate -> generic register port
  // ===========================================================================
  logic [AWB-1:0]   reg_addr;
  logic             reg_wen, reg_ren;
  logic [DW-1:0]    reg_wdata, reg_rdata;
  logic [DW/8-1:0]  reg_wstrb;
  logic             reg_err;

  axil_slave #(.AW(AWB), .DW(DW)) u_axil (
    .clk       (clk),      .rst_n    (rst_n),
    .awaddr    (awaddr),   .awvalid  (awvalid),  .awready (awready),
    .wdata     (wdata),    .wstrb    (wstrb),    .wvalid  (wvalid),
    .wready    (wready),
    .bresp     (bresp),    .bvalid   (bvalid),   .bready  (bready),
    .araddr    (araddr),   .arvalid  (arvalid),  .arready (arready),
    .rdata     (rdata),    .rresp    (rresp),    .rvalid  (rvalid),
    .rready    (rready),
    .reg_addr  (reg_addr), .reg_wen  (reg_wen),  .reg_wdata (reg_wdata),
    .reg_wstrb (reg_wstrb),.reg_ren  (reg_ren),  .reg_rdata (reg_rdata),
    .reg_err   (reg_err)
  );

  // axil_slave passes the address through untouched, on purpose -- whether it is
  // a byte address or an index is the integrator's decision and it refuses to
  // make it. This is where that decision is made.
  logic [BAW-1:0] idx;
  assign idx = reg_addr[BAW+1:2];

  // ===========================================================================
  // Command decode. No storage: a command is the write itself.
  // ===========================================================================
  logic ctrl_hit, cmd_arm, cmd_start;

  assign ctrl_hit  = (idx == A_CTRL);
  assign cmd_arm   = reg_wen && ctrl_hit && reg_wdata[0];
  assign cmd_start = reg_wen && ctrl_hit && reg_wdata[1];

  // ===========================================================================
  // The register bank
  // ===========================================================================
  logic [N_RW*DW-1:0] staged;
  logic [N_RO*DW-1:0] ro_d;
  logic [DW-1:0]      status_set, status_q;
  logic               bank_err, bank_wen;

  logic cfg_pending, cfg_applied, cfg_lock, cfg_safe;
  logic late_wr;

  // A configuration write while a commit is outstanding. Suppressed, not merely
  // flagged -- see note 4 in the header.
  assign late_wr  = reg_wen && cfg_lock && (idx < BAW'(N_RW));
  assign bank_wen = reg_wen && !late_wr;

  // The bank flags CTRL as an unmapped address, correctly, because it is. Masking
  // that here is the one place the two address maps have to be reconciled.
  assign reg_err  = (bank_err && !ctrl_hit) || late_wr;

  csr_bank #(
    .DW   (DW),
    .N_RW (N_RW),
    .N_RO (N_RO),
    .NREG (N_RW + N_RO + 1),
    .AW   (BAW)
  ) u_bank (
    .clk        (clk),
    .rst_n      (rst_n),
    .addr       (idx),
    .wen        (bank_wen),
    .wdata      (reg_wdata),
    .wstrb      (reg_wstrb),
    .ren        (reg_ren),
    .rdata      (reg_rdata),
    .err        (bank_err),
    .rw_q       (staged),
    .ro_d       (ro_d),
    .status_set (status_set),
    .status_q   (status_q)
  );

  // ===========================================================================
  // The commit point
  // ===========================================================================
  logic [N_RW*DW-1:0] active;

  csr_shadow #(.NREG(N_RW), .DW(DW), .MODE(2)) u_shadow (
    .clk     (clk),
    .rst_n   (rst_n),
    .staged  (staged),
    .arm     (cmd_arm),
    .pending (cfg_pending),
    .applied (cfg_applied),
    .lock    (cfg_lock),
    .safe    (cfg_safe),
    .active  (active)
  );

  // The bank's word order puts register 0 in the low bits, which is exactly
  // cfg_pkg's layout for a two-word bundle -- so these are slices and not a
  // shuffle. Getting that to line up by construction rather than by a rewiring
  // step is why the map and the accessors live in one package.
  logic [cfg_pkg::SCALE_CFGW-1:0] cfg_scale;
  logic [cfg_pkg::BURST_CFGW-1:0] cfg_burst;

  assign cfg_scale = active[0                     +: cfg_pkg::SCALE_CFGW];
  assign cfg_burst = active[cfg_pkg::SCALE_CFGW   +: cfg_pkg::BURST_CFGW];

  // ===========================================================================
  // Consumers
  // ===========================================================================
  logic burst_busy, burst_done, burst_safe;
  logic dp_busy, dp_safe;

  // The intersection. See the header.
  assign cfg_safe = burst_safe && dp_safe;

  // A start issued in the SAME bus write as an arm would snapshot the OLD active
  // configuration. The engine samples `cfg` on the edge that starts it, the commit
  // lands on that same edge, and a register reads its old value on the edge it
  // updates -- so the burst runs one configuration behind. Rather than push that
  // ordering onto software as a documented footgun, the start is HELD until a
  // cycle on which no commit is outstanding.
  //
  // `!cmd_arm && !cfg_pending` is the condition, and both terms are needed. The
  // first version of this used only `cfg_pending && cfg_safe` -- "a commit is
  // landing right now" -- and it did not work, because on the cycle of the
  // arm+start write `cfg_pending` is still the registered zero: the arm has not
  // been latched yet. The start went out immediately and the burst ran with the
  // previous configuration. csr_config_tb section 4f is that test.
  //
  // With no commit outstanding, `commit` inside csr_shadow is zero, so `active`
  // cannot move across this edge and the snapshot the engine takes is the settled
  // value. A start issued with nothing armed therefore costs nothing, which is the
  // common case.
  //
  // A held start waits for the commit, and the commit waits for `cfg_safe`. In
  // this top `dp_safe` is constantly high so that resolves; a top whose scaler ran
  // in QUIESCE mode under continuous load would hold the start as long as the
  // commit is refused, which is one more reason that intersection is worth
  // avoiding.
  logic start_ok, start_pend_q, fsm_start;

  assign start_ok  = !cmd_arm && !cfg_pending;
  assign fsm_start = (cmd_start || start_pend_q) && start_ok;

  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n)                        start_pend_q <= 1'b0;
    else if (cmd_start && !start_ok)        start_pend_q <= 1'b1;
    else if (start_pend_q && start_ok)      start_pend_q <= 1'b0;
  end

  cfg_burst_fsm #(.LIVE_CFG(1'b0)) u_burst (
    .clk     (clk),
    .rst_n   (rst_n),
    .cfg     (cfg_burst),
    .start   (fsm_start),
    .m_valid (m_valid),
    .m_addr  (m_addr),
    .m_kind  (m_kind),
    .m_ready (m_ready),
    .busy    (burst_busy),
    .done    (burst_done),
    .safe    (burst_safe)
  );

  cfg_pipe_scale #(.CFG_MODE(2)) u_scale (
    .clk     (clk),
    .rst_n   (rst_n),
    .en      (dp_en),
    .cfg     (cfg_scale),
    .x_valid (x_valid),
    .x       (x),
    .y_valid (y_valid),
    .y       (y),
    .busy    (dp_busy),
    .safe    (dp_safe)
  );

  // ===========================================================================
  // Status and events
  // ===========================================================================
  logic [DW-1:0] status_word;

  always_comb begin
    status_word    = '0;
    status_word[0] = cfg_pending;
    status_word[1] = cfg_lock;
    status_word[2] = burst_busy;
    status_word[3] = dp_busy;
  end

  assign ro_d[0*DW +: DW] = status_word;
  assign ro_d[1*DW +: DW] = cfg_burst[0 +: DW];   // ACTIVE_BURST0
  assign ro_d[2*DW +: DW] = cfg_scale[0 +: DW];   // ACTIVE_SCALE0

  always_comb begin
    status_set    = '0;
    status_set[0] = burst_done;
    status_set[1] = cfg_applied;
  end

  assign irq = |status_q;

`ifndef SYNTHESIS
  // A commit never lands while the engine it configures is running. This is the
  // end-to-end version of csr_shadow's own assertion: there, `safe` was a free
  // input and the property was about honouring it; here `safe` is wired to a real
  // consumer and the property is about the wiring being right.
  a_no_commit_while_busy: assert property (@(posedge clk) disable iff (!rst_n)
    cfg_applied |-> $past(!burst_busy))
    else $error("csr_ctrl_top: configuration committed while the engine was busy");

  // A suppressed write is always reported. A silently dropped configuration write
  // is the hardest class of bug to find from the software side, because every
  // subsequent read of the staged register says the write worked.
  a_late_wr_errs: assert property (@(posedge clk) disable iff (!rst_n)
    late_wr |-> reg_err)
    else $error("csr_ctrl_top: dropped a register write without reporting it");
`endif

endmodule

`default_nettype wire
