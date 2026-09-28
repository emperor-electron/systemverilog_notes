// -----------------------------------------------------------------------------
// csr_config_tb.sv -- the reconfiguration hazards of docs/39, measured.
//
// Four sections, and only the last is an ordinary functional test:
//
//   1. TEARING. A four-word configuration written one word per cycle, through
//      each of csr_shadow's three commit policies, counting the cycles in which
//      the ACTIVE configuration was a value software never wrote. The interesting
//      result is not that TRANSPARENT tears -- it is that SAFE_POINT tears too
//      whenever the consumer's safe window happens to be open during the writes,
//      and that only ARM_COMMIT is atomic regardless of what the consumer is
//      doing. That distinction is invisible in a block diagram.
//
//   2. AN FSM UNDER A MOVING CONFIGURATION. Two instances of cfg_burst_fsm, one
//      snapshotting and one reading live, driven by IDENTICAL stimulus, with the
//      configuration rewritten mid-burst. Measured per instance: data beats
//      emitted, address sequence, whether the frame was well formed, and whether
//      the burst terminated at all.
//
//   3. A PIPELINE UNDER A MOVING CONFIGURATION. Three instances of
//      cfg_pipe_scale, each behind a real csr_shadow, checked beat by beat against
//      a model of "the configuration that was active when this beat entered".
//      Plus the number that decides between the two correct modes: how many
//      commits land during an uninterrupted input stream.
//
//   4. THE WHOLE PATH, over AXI4-Lite into csr_ctrl_top: read-back mirrors,
//      status and event bits, the write lock, and one directed vector of literal
//      hex words that is the only thing in this repository pinning cfg_pkg's field
//      offsets to something outside cfg_pkg.
//
// XSIM NOTE, the hard way, twice before (docs/37 section 13): a `while` condition
// containing a cast evaluates FALSE under XSIM and the loop body silently never
// runs. Every bound below is a plain `int` compared bare.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module csr_config_tb;

  localparam int unsigned DW    = 32;
  localparam int unsigned NREG  = 4;
  localparam int unsigned CFGW  = NREG * DW;

  localparam int unsigned XW    = cfg_pkg::XW;
  localparam int unsigned YW    = cfg_pkg::YW;
  localparam int unsigned SCW   = cfg_pkg::SCALE_CFGW;
  localparam int unsigned BUW   = cfg_pkg::BURST_CFGW;
  localparam int unsigned ADDRW = cfg_pkg::ADDRW;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  int err = 0;

  task automatic ck(input string what, input logic ok);
    if (!ok) begin
      err++;
      if (err <= 25) $display("  FAIL  %s", what);
    end
  endtask

  // ===========================================================================
  // SECTION 1 -- tearing, per commit policy
  // ===========================================================================
  //
  // `sh_staged` is written one 32-bit word at a time, which is what a processor
  // actually does and the only reason a multi-word parameter can tear at all.
  // `sh_safe` is the consumer's critical-region signal and the whole experiment is
  // run twice: once with it closed during the writes and once with it open.
  logic [CFGW-1:0] sh_staged = '0;
  logic            sh_arm    = 1'b0;
  logic            sh_safe   = 1'b1;

  logic [CFGW-1:0] cfg_old, cfg_new;      // the two complete configurations
  logic            watch = 1'b0;          // count torn cycles while high

  int torn [3];                           // per MODE, per pass
  int torn_open [3];

  for (genvar M = 0; M < 3; M++) begin : g_sh
    logic [CFGW-1:0] active;
    logic            pending, applied, lock;

    csr_shadow #(.NREG(NREG), .DW(DW), .MODE(M)) u_sh (
      .clk (clk), .rst_n (rst_n),
      .staged (sh_staged), .arm (sh_arm),
      .pending (pending), .applied (applied), .lock (lock),
      .safe (sh_safe), .active (active));

    // A cycle is TORN when the active configuration is neither of the two
    // complete values. Stated this way rather than as "differs from expected" so
    // that a commit landing early or late is not counted as tearing -- the two
    // are different faults and conflating them would hide both.
    logic is_torn;
    assign is_torn = (active != cfg_old) && (active != cfg_new);

    // A plain `always`, not `always_ff`: these counters are also cleared from a
    // task below, and `always_ff` promises a single driver.
    int n_torn;
    always @(posedge clk)
      if (watch && is_torn) n_torn <= n_torn + 1;

    task automatic arm_pass(); n_torn = 0; endtask
    task automatic save(input int pass);
      if (pass == 0) torn[M]      = n_torn;
      else           torn_open[M] = n_torn;
    endtask
  end

  // ===========================================================================
  // SECTION 2 -- an FSM under a moving configuration
  // ===========================================================================
  logic [BUW-1:0] f_cfg   = '0;
  logic           f_start = 1'b0;
  logic           f_ready = 1'b1;

  int  f_beats   [2];       // data beats emitted
  int  f_hdr     [2];       // headers emitted
  int  f_trl     [2];       // trailers emitted
  int  f_done    [2];       // did the burst terminate?
  int  f_addr_ok [2];       // did every data address follow base + n*stride?
  int  f_first   [2];       // the first data address, for the report

  for (genvar L = 0; L < 2; L++) begin : g_fsm
    logic                  m_valid, busy, done, safe;
    logic [ADDRW-1:0]      m_addr;
    logic [1:0]            m_kind;

    cfg_burst_fsm #(.LIVE_CFG(L == 1)) u_fsm (
      .clk (clk), .rst_n (rst_n),
      .cfg (f_cfg), .start (f_start),
      .m_valid (m_valid), .m_addr (m_addr), .m_kind (m_kind), .m_ready (f_ready),
      .busy (busy), .done (done), .safe (safe));

    // The expected address sequence is rebuilt here from the configuration AS IT
    // WAS AT START, captured by this collector rather than read out of the DUT --
    // otherwise the live instance would be checked against its own mistake.
    logic [ADDRW-1:0] exp_base;
    int               exp_stride;
    int               nb, nh, nt, ok, first;

    always @(posedge clk) begin
      if (f_start && safe) begin
        exp_base   <= cfg_pkg::burst_base(f_cfg);
        exp_stride <= int'(cfg_pkg::burst_stride(f_cfg));
        nb <= 0; nh <= 0; nt <= 0; ok <= 1; first <= 0;
      end else if (m_valid && f_ready) begin
        if (m_kind == cfg_pkg::K_HDR) nh <= nh + 1;
        if (m_kind == cfg_pkg::K_TRL) nt <= nt + 1;
        if (m_kind == cfg_pkg::K_DATA) begin
          if (nb == 0) first <= m_addr;
          if (m_addr != ADDRW'(int'(exp_base) + nb * exp_stride)) ok <= 0;
          nb <= nb + 1;
        end
      end
    end

    task automatic save_fsm();
      f_beats[L]   = nb;
      f_hdr[L]     = nh;
      f_trl[L]     = nt;
      f_addr_ok[L] = ok;
      f_first[L]   = first;
      f_done[L]    = busy ? 0 : 1;
    endtask
  end

  // ===========================================================================
  // SECTION 3 -- a pipeline under a moving configuration
  // ===========================================================================
  logic [SCW-1:0]       p_staged = '0;
  logic                 p_arm    = 1'b0;
  logic                 p_en     = 1'b1;
  logic                 p_xvalid = 1'b0;
  logic signed [XW-1:0] p_x      = '0;
  logic                 p_check  = 1'b0;

  int p_out   [3];     // beats checked
  int p_mism  [3];     // beats whose value did not match the entry configuration
  int p_comm  [3];     // commits that landed
  int p_lat   [3];     // cycles from arm to applied

  for (genvar M = 0; M < 3; M++) begin : g_dp
    logic [SCW-1:0]       cfg;
    logic                 pending, applied, lock, safe;
    logic                 y_valid, busy;
    logic signed [YW-1:0] y;

    // The real double buffer, exactly as csr_ctrl_top wires it. Assuming its
    // behaviour instead would make this a test of the assumption.
    csr_shadow #(.NREG(2), .DW(DW), .MODE(2)) u_sh (
      .clk (clk), .rst_n (rst_n),
      .staged (p_staged), .arm (p_arm),
      .pending (pending), .applied (applied), .lock (lock),
      .safe (safe), .active (cfg));

    cfg_pipe_scale #(.CFG_MODE(M)) u_dp (
      .clk (clk), .rst_n (rst_n), .en (p_en),
      .cfg (cfg), .x_valid (p_xvalid), .x (p_x),
      .y_valid (y_valid), .y (y), .busy (busy), .safe (safe));

    // Three-deep model of {sample, configuration-at-entry}, gated by `en` exactly
    // as the datapath registers are. This is the only way to state the property:
    // "correct" is not a function of the configuration now, it is a function of
    // the configuration three beats ago.
    logic signed [XW-1:0] mx [3];
    logic [SCW-1:0]       mc [3];
    int                   nout, nmis, ncom, lat, lat_run;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        for (int i = 0; i < 3; i++) begin mx[i] <= '0; mc[i] <= '0; end
      end else if (p_en) begin
        mx[0] <= p_x;  mc[0] <= cfg;
        mx[1] <= mx[0]; mc[1] <= mc[0];
        mx[2] <= mx[1]; mc[2] <= mc[1];
      end
    end

    logic signed [YW-1:0] y_exp;
    always_comb y_exp = cfg_pkg::scale_ref(cfg_pkg::scale_gain (mc[2]),
                                           cfg_pkg::scale_shift(mc[2]),
                                           cfg_pkg::scale_lo   (mc[2]),
                                           cfg_pkg::scale_hi   (mc[2]),
                                           mx[2]);

    // Qualified by `p_en`, not just `y_valid`. Under a global stall the output
    // register holds, so `y_valid` stays high and an unqualified count scores the
    // same held beat once per stalled cycle -- section 3c counted 8 "beats" for 3.
    // With the enable, one count per beat actually delivered. That the held value
    // must not move is a separate property, and cfg_pipe_scale's own `a_stall_holds`
    // assertion covers it.
    always @(posedge clk) begin
      if (p_check && y_valid && p_en) begin
        nout <= nout + 1;
        if (y !== y_exp) nmis <= nmis + 1;
      end
      if (p_check && applied) ncom <= ncom + 1;
      // Time from the arm to the commit actually landing. In QUIESCE mode under
      // load this never completes, which is the point of measuring it.
      if (p_arm)                     lat_run <= 1;
      else if (lat_run && !applied)  lat     <= lat + 1;
      else if (applied)              lat_run <= 0;
    end

    task automatic clr_dp();
      nout = 0; nmis = 0; ncom = 0; lat = 0; lat_run = 0;
    endtask
    task automatic save_dp();
      p_out[M] = nout; p_mism[M] = nmis; p_comm[M] = ncom; p_lat[M] = lat;
    endtask
  end

  // ===========================================================================
  // SECTION 4 -- csr_ctrl_top over AXI4-Lite
  // ===========================================================================
  localparam int unsigned AWB = 6;
  localparam int unsigned NB  = DW / 8;

  localparam logic [AWB-1:0] R_SCALE0 = 6'h00;
  localparam logic [AWB-1:0] R_SCALE1 = 6'h04;
  localparam logic [AWB-1:0] R_BURST0 = 6'h08;
  localparam logic [AWB-1:0] R_BURST1 = 6'h0C;
  localparam logic [AWB-1:0] R_STATUS = 6'h10;
  localparam logic [AWB-1:0] R_ACT_B0 = 6'h14;
  localparam logic [AWB-1:0] R_ACT_S0 = 6'h18;
  localparam logic [AWB-1:0] R_EVENT  = 6'h1C;
  localparam logic [AWB-1:0] R_CTRL   = 6'h20;

  logic [AWB-1:0]  awaddr = '0, araddr = '0;
  logic            awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0;
  logic            arvalid = 1'b0, rready = 1'b0;
  logic [DW-1:0]   t_wdata = '0;
  logic [NB-1:0]   t_wstrb = '1;
  logic            awready, wready, bvalid, arready, rvalid;
  logic [1:0]      bresp, rresp;
  logic [DW-1:0]   t_rdata;

  logic                 t_en = 1'b1, t_xvalid = 1'b0;
  logic signed [XW-1:0] t_x = '0;
  logic                 t_yvalid;
  logic signed [YW-1:0] t_y;
  logic                 t_mvalid, t_irq;
  logic [ADDRW-1:0]     t_maddr;
  logic [1:0]           t_mkind;
  logic                 t_mready = 1'b1;

  csr_ctrl_top #(.AWB(AWB), .DW(DW)) u_top (
    .clk (clk), .rst_n (rst_n),
    .awaddr (awaddr), .awvalid (awvalid), .awready (awready),
    .wdata (t_wdata), .wstrb (t_wstrb), .wvalid (wvalid), .wready (wready),
    .bresp (bresp), .bvalid (bvalid), .bready (bready),
    .araddr (araddr), .arvalid (arvalid), .arready (arready),
    .rdata (t_rdata), .rresp (rresp), .rvalid (rvalid), .rready (rready),
    .dp_en (t_en), .x_valid (t_xvalid), .x (t_x),
    .y_valid (t_yvalid), .y (t_y),
    .m_valid (t_mvalid), .m_addr (t_maddr), .m_kind (t_mkind),
    .m_ready (t_mready), .irq (t_irq));

  // Collector for the burst the top emits.
  int t_nb, t_nh, t_nt;
  logic [ADDRW-1:0] t_a0, t_a1;
  always @(posedge clk)
    if (t_mvalid && t_mready) begin
      if (t_mkind == cfg_pkg::K_HDR)  t_nh <= t_nh + 1;
      if (t_mkind == cfg_pkg::K_TRL)  t_nt <= t_nt + 1;
      if (t_mkind == cfg_pkg::K_DATA) begin
        if (t_nb == 0) t_a0 <= t_maddr;
        if (t_nb == 1) t_a1 <= t_maddr;
        t_nb <= t_nb + 1;
      end
    end

  // A three-deep model of {sample, active scale configuration} through the top,
  // for section 4h. `u_top.cfg_scale` is read hierarchically -- this is a
  // testbench, so that is available (the Yosys frontend's refusal to follow a
  // hierarchical reference only constrains the formal harnesses).
  logic signed [XW-1:0] tmx [3];
  logic [SCW-1:0]       tmc [3];
  int                   t_nchk, t_nbad;
  logic                 t_track = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 3; i++) begin tmx[i] <= '0; tmc[i] <= '0; end
    end else if (t_en) begin
      tmx[0] <= t_x;   tmc[0] <= u_top.cfg_scale;
      tmx[1] <= tmx[0]; tmc[1] <= tmc[0];
      tmx[2] <= tmx[1]; tmc[2] <= tmc[1];
    end
  end

  logic signed [YW-1:0] t_yexp;
  always_comb t_yexp = cfg_pkg::scale_ref(cfg_pkg::scale_gain (tmc[2]),
                                          cfg_pkg::scale_shift(tmc[2]),
                                          cfg_pkg::scale_lo   (tmc[2]),
                                          cfg_pkg::scale_hi   (tmc[2]),
                                          tmx[2]);

  always @(posedge clk)
    if (t_track && t_yvalid) begin
      t_nchk <= t_nchk + 1;
      if (t_y !== t_yexp) t_nbad <= t_nbad + 1;
    end

  task automatic bus_write(input logic [AWB-1:0] a, input logic [DW-1:0] d,
                           output logic [1:0] resp);
    awaddr = a; awvalid = 1'b1; t_wdata = d; t_wstrb = '1; wvalid = 1'b1;
    while (!(awready && wready)) @(negedge clk);
    @(negedge clk);
    awvalid = 1'b0; wvalid = 1'b0;
    bready = 1'b1;
    while (!bvalid) @(negedge clk);
    resp = bresp;
    @(negedge clk);
    bready = 1'b0;
  endtask

  task automatic bus_read(input logic [AWB-1:0] a, output logic [DW-1:0] d,
                          output logic [1:0] resp);
    araddr = a; arvalid = 1'b1;
    while (!arready) @(negedge clk);
    @(negedge clk);
    arvalid = 1'b0;
    rready = 1'b1;
    while (!rvalid) @(negedge clk);
    d = t_rdata; resp = rresp;
    @(negedge clk);
    rready = 1'b0;
  endtask

  // ===========================================================================
  // Stimulus
  // ===========================================================================
  logic [1:0]  resp;
  logic [DW-1:0] rd;
  int          i, guard;

  // Two bus writes, callable from a forked process so a configuration change can
  // land in the middle of a running stream.
  task automatic bus_cfg_change();
    logic [1:0] r2;
    bus_write(R_SCALE0, 32'h0005_0180, r2);   // gain 0x180, shift 5 -> y = x*12
    bus_write(R_CTRL,   32'h0000_0001, r2);
  endtask

  task automatic reset_all();
    rst_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
  endtask

  initial begin
    // -----------------------------------------------------------------------
    // 1. Tearing
    // -----------------------------------------------------------------------
    $display("[1] a four-word configuration written one word per cycle");

    cfg_old = '0;
    cfg_new = {32'hDDDD_4444, 32'hCCCC_3333, 32'hBBBB_2222, 32'hAAAA_1111};

    for (int pass = 0; pass < 2; pass++) begin
      reset_all();
      sh_staged = cfg_old;
      sh_safe   = 1'b1;
      sh_arm    = 1'b1;  @(negedge clk);  sh_arm = 1'b0;
      repeat (3) @(negedge clk);

      // pass 0: the consumer's critical region is CLOSED while software writes.
      // pass 1: it is OPEN -- which is the normal case for a consumer that is
      // simply idle, and the case that separates the two protected modes.
      sh_safe = (pass == 1);

      g_sh[0].arm_pass(); g_sh[1].arm_pass(); g_sh[2].arm_pass();
      watch = 1'b1;

      // one 32-bit store per cycle, low word first
      for (int w = 0; w < 4; w++) begin
        sh_staged[w*DW +: DW] = cfg_new[w*DW +: DW];
        @(negedge clk);
      end

      sh_arm = 1'b1;  @(negedge clk);  sh_arm = 1'b0;
      sh_safe = 1'b1;
      repeat (4) @(negedge clk);
      watch = 1'b0;

      g_sh[0].save(pass); g_sh[1].save(pass); g_sh[2].save(pass);

      // Whatever the policy, once the dust settles the new configuration must be
      // live. A shadow that never commits would score zero torn cycles too.
      ck($sformatf("pass %0d: TRANSPARENT ends up with the new configuration", pass),
         g_sh[0].active === cfg_new);
      ck($sformatf("pass %0d: SAFE_POINT ends up with the new configuration", pass),
         g_sh[1].active === cfg_new);
      ck($sformatf("pass %0d: ARM_COMMIT ends up with the new configuration", pass),
         g_sh[2].active === cfg_new);
    end

    $display("      torn cycles, consumer BUSY during the writes:  TRANSPARENT=%0d SAFE_POINT=%0d ARM_COMMIT=%0d",
             torn[0], torn[1], torn[2]);
    $display("      torn cycles, consumer IDLE during the writes:  TRANSPARENT=%0d SAFE_POINT=%0d ARM_COMMIT=%0d",
             torn_open[0], torn_open[1], torn_open[2]);

    ck("TRANSPARENT tears when software writes word by word", torn[0] > 0);
    ck("SAFE_POINT is atomic while the consumer is busy",     torn[1] == 0);
    ck("ARM_COMMIT is atomic while the consumer is busy",     torn[2] == 0);
    // The finding. An automatic commit point is only as atomic as the consumer's
    // safe window; software's own grouping is not.
    ck("SAFE_POINT tears when the consumer is idle",          torn_open[1] > 0);
    ck("ARM_COMMIT is atomic regardless of the consumer",     torn_open[2] == 0);

    // -----------------------------------------------------------------------
    // 2. An FSM under a moving configuration
    // -----------------------------------------------------------------------
    $display("[2] burst engine, configuration rewritten mid-burst");

    // ---- 2a: len and stride shrink under a running burst -------------------
    reset_all();
    f_cfg   = cfg_pkg::burst_pack(12'd4, 8'd3, 16'h0100, 1'b1);
    f_ready = 1'b1;
    f_start = 1'b1;  @(negedge clk);  f_start = 1'b0;

    // let the header and two data beats go out
    repeat (3) @(negedge clk);
    f_cfg = cfg_pkg::burst_pack(12'd2, 8'd7, 16'h0100, 1'b1);

    guard = 0;
    while (guard < 60) begin
      @(negedge clk);
      guard = guard + 1;
    end
    g_fsm[0].save_fsm(); g_fsm[1].save_fsm();

    $display("      2a  SNAPSHOT: %0d data beats, addr_ok=%0d, hdr=%0d trl=%0d, terminated=%0d",
             f_beats[0], f_addr_ok[0], f_hdr[0], f_trl[0], f_done[0]);
    $display("      2a  LIVE    : %0d data beats, addr_ok=%0d, hdr=%0d trl=%0d, terminated=%0d",
             f_beats[1], f_addr_ok[1], f_hdr[1], f_trl[1], f_done[1]);

    ck("2a snapshot emits exactly the length latched at start", f_beats[0] == 4);
    ck("2a snapshot addresses follow base + n*stride",          f_addr_ok[0] == 1);
    ck("2a snapshot frame is well formed",  (f_hdr[0] == 1) && (f_trl[0] == 1));
    ck("2a snapshot burst terminated",                          f_done[0] == 1);
    // The hang: the terminal comparison can no longer be true.
    ck("2a live burst did not terminate within 60 cycles",      f_done[1] == 0);
    ck("2a live burst walked the wrong addresses",              f_addr_ok[1] == 0);

    // ---- 2b: only hdr_en changes -- no arithmetic involved at all ----------
    reset_all();
    f_cfg   = cfg_pkg::burst_pack(12'd4, 8'd3, 16'h0200, 1'b1);
    f_start = 1'b1;  @(negedge clk);  f_start = 1'b0;
    repeat (3) @(negedge clk);
    // Clear the framing bit only. Length and stride are untouched, so every
    // defensive comparison in the datapath is satisfied throughout.
    f_cfg = cfg_pkg::burst_pack(12'd4, 8'd3, 16'h0200, 1'b0);

    guard = 0;
    while (guard < 30) begin
      @(negedge clk);
      guard = guard + 1;
    end
    g_fsm[0].save_fsm(); g_fsm[1].save_fsm();

    $display("      2b  SNAPSHOT: hdr=%0d trl=%0d   LIVE: hdr=%0d trl=%0d",
             f_hdr[0], f_trl[0], f_hdr[1], f_trl[1]);

    ck("2b snapshot still emits a matched header and trailer",
       (f_hdr[0] == 1) && (f_trl[0] == 1));
    ck("2b snapshot burst terminated", f_done[0] == 1);
    // A header with no trailer. The counts are right, the addresses are right,
    // and the packet is unparseable.
    ck("2b live burst emitted a header with no trailer",
       (f_hdr[1] == 1) && (f_trl[1] == 0));
    ck("2b live burst terminated anyway, silently malformed", f_done[1] == 1);

    // -----------------------------------------------------------------------
    // 3. A pipeline under a moving configuration
    // -----------------------------------------------------------------------
    $display("[3] three-stage scaler, configuration committed mid-stream");

    // ---- 3a: a gapped stream, one configuration change --------------------
    reset_all();
    p_staged = cfg_pkg::scale_pack(16'd256, 4'd3, -12'sd1000, 12'sd1000);
    p_arm = 1'b1; @(negedge clk); p_arm = 1'b0;
    repeat (3) @(negedge clk);

    g_dp[0].clr_dp(); g_dp[1].clr_dp(); g_dp[2].clr_dp();
    p_check = 1'b1;

    for (i = 0; i < 40; i++) begin
      p_xvalid = ($urandom_range(0, 3) != 0);   // gaps, so QUIESCE can commit
      // Kept inside the clamp. A range that saturates most outputs makes both the
      // right and the wrong answer equal to the bound -- see the note in 4h.
      p_x      = XW'($urandom_range(0, 60)) - XW'(30);
      p_en     = ($urandom_range(0, 9) != 0);   // occasional global stall
      if (i == 12) begin
        // A different gain AND a different shift AND different bounds, so a beat
        // that picks up a mixture of old and new is guaranteed to be wrong rather
        // than accidentally right.
        p_staged = cfg_pkg::scale_pack(16'd97, 4'd1, -12'sd300, 12'sd300);
        p_arm    = 1'b1;
      end else begin
        p_arm    = 1'b0;
      end
      @(negedge clk);
    end
    p_xvalid = 1'b0; p_arm = 1'b0; p_en = 1'b1;
    repeat (6) @(negedge clk);
    p_check = 1'b0;
    g_dp[0].save_dp(); g_dp[1].save_dp(); g_dp[2].save_dp();

    $display("      3a  LIVE   : %0d beats, %0d wrong, %0d commits",
             p_out[0], p_mism[0], p_comm[0]);
    $display("      3a  QUIESCE: %0d beats, %0d wrong, %0d commits",
             p_out[1], p_mism[1], p_comm[1]);
    $display("      3a  TRAVEL : %0d beats, %0d wrong, %0d commits",
             p_out[2], p_mism[2], p_comm[2]);

    ck("3a live mode produced beats at all",     p_out[0] > 10);
    ck("3a live mode corrupted at least one beat",
       (p_mism[0] > 0) || (p_comm[0] == 0));
    ck("3a quiesce mode matched every beat",     p_mism[1] == 0);
    ck("3a travel mode matched every beat",      p_mism[2] == 0);
    ck("3a travel mode committed the update",    p_comm[2] > 0);

    // ---- 3b: an uninterrupted stream -- can the commit ever land? ---------
    //
    // The measurement behind csr_ctrl_top's warning about intersecting safe
    // windows. QUIESCE requires the pipeline to be empty AND idle; an input that
    // never pauses means it is never either.
    reset_all();
    p_staged = cfg_pkg::scale_pack(16'd256, 4'd3, -12'sd1000, 12'sd1000);
    p_arm = 1'b1; @(negedge clk); p_arm = 1'b0;
    repeat (3) @(negedge clk);

    g_dp[0].clr_dp(); g_dp[1].clr_dp(); g_dp[2].clr_dp();
    p_check = 1'b1;
    p_en = 1'b1; p_xvalid = 1'b1;

    p_staged = cfg_pkg::scale_pack(16'd97, 4'd1, -12'sd300, 12'sd300);
    p_arm = 1'b1; @(negedge clk); p_arm = 1'b0;

    for (i = 0; i < 100; i++) begin
      p_x = XW'($urandom_range(0, 2047)) - XW'(1024);
      @(negedge clk);
    end
    p_check = 1'b0;
    g_dp[0].save_dp(); g_dp[1].save_dp(); g_dp[2].save_dp();

    $display("      3b  commits during 100 cycles of unbroken input:  LIVE=%0d QUIESCE=%0d TRAVEL=%0d",
             p_comm[0], p_comm[1], p_comm[2]);

    ck("3b travel commits under full load",  p_comm[2] == 1);
    // Refused for as long as the load lasts, with nothing reporting an error.
    ck("3b quiesce never commits under full load", p_comm[1] == 0);
    ck("3b travel still matched every beat", p_mism[2] == 0);

    p_xvalid = 1'b0;
    repeat (4) @(negedge clk);

    // ---- 3c: a stall that coincides with the commit ------------------------
    //
    // A beat frozen in stage 1 must keep the `shift` it entered with. If the
    // travelling configuration registers are not gated by `en` along with the data,
    // a stalled beat meets a configuration that moved while it waited.
    //
    // This is DIRECTED, not random, and it has to be: the random stalls in 3a hit
    // about one cycle in ten and there is one commit in the pass, so the
    // coincidence almost never happens. The proof catches that mutation every time
    // and the random testbench did not catch it at all -- which is the clearest
    // example in this file of what each method is for.
    reset_all();
    p_staged = cfg_pkg::scale_pack(16'd256, 4'd3, -12'sd1000, 12'sd1000);  // y = x*32
    p_arm = 1'b1; @(negedge clk); p_arm = 1'b0;
    repeat (3) @(negedge clk);

    g_dp[0].clr_dp(); g_dp[1].clr_dp(); g_dp[2].clr_dp();
    p_check = 1'b1;
    p_en = 1'b1;

    // Fill the pipeline.
    p_xvalid = 1'b1;
    for (i = 0; i < 3; i++) begin
      p_x = XW'(10 + i);
      @(negedge clk);
    end

    // Freeze it with beats in every stage, and arm a genuinely different
    // configuration on the same cycle. `safe` is high in TRAVEL mode, so the commit
    // lands on the next edge regardless of the stall.
    p_xvalid = 1'b0;
    p_en     = 1'b0;
    p_staged = cfg_pkg::scale_pack(16'd384, 4'd5, -12'sd1000, 12'sd1000);  // y = x*12
    p_arm    = 1'b1; @(negedge clk); p_arm = 1'b0;
    repeat (4) @(negedge clk);        // held, with the new configuration live

    // Release, and drain the three frozen beats.
    p_en = 1'b1;
    repeat (6) @(negedge clk);
    p_check = 1'b0;
    g_dp[0].save_dp(); g_dp[1].save_dp(); g_dp[2].save_dp();

    $display("      3c  stall across a commit:  LIVE %0d/%0d wrong, QUIESCE %0d/%0d, TRAVEL %0d/%0d",
             p_mism[0], p_out[0], p_mism[1], p_out[1], p_mism[2], p_out[2]);
    ck("3c the frozen beats came out", p_out[2] == 3);
    ck("3c travel held each beat's configuration across the stall", p_mism[2] == 0);
    ck("3c live mode corrupted the frozen beats", p_mism[0] > 0);

    // -----------------------------------------------------------------------
    // 4. The whole path over AXI4-Lite
    // -----------------------------------------------------------------------
    $display("[4] csr_ctrl_top: staged vs active, events, and the write lock");
    reset_all();

    // ---- 4a: literal hex words. THE ONLY CHECK IN THIS REPOSITORY THAT PINS
    // cfg_pkg's field offsets to anything outside cfg_pkg. Everything else packs
    // and unpacks with the same accessors, so a wrong offset would cancel out.
    //
    //   SCALE0 = 0x0003_0100 -> gain = 0x0100 (Q8.8 = 1.0), shift = 3
    //   SCALE1 = 0x07FF_F801 -> lo = 0x801 = -2047, hi = 0x7FF = +2047
    //   BURST0 = 0x0103_0004 -> len = 4, stride = 3, hdr_en = 1
    //   BURST1 = 0x0000_0100 -> base = 0x0100
    bus_write(R_SCALE0, 32'h0003_0100, resp);
    ck("4a SCALE0 write is OKAY", resp === 2'b00);
    bus_write(R_SCALE1, 32'h07FF_F801, resp);
    bus_write(R_BURST0, 32'h0103_0004, resp);
    bus_write(R_BURST1, 32'h0000_0100, resp);

    bus_read(R_BURST0, rd, resp);
    ck($sformatf("4a staged BURST0 reads back what was written (%h)", rd),
       rd === 32'h0103_0004);
    // Not committed yet, so the hardware is still using nothing.
    bus_read(R_ACT_B0, rd, resp);
    ck($sformatf("4a ACTIVE_BURST0 still zero before the arm (%h)", rd), rd === '0);

    // ---- 4b: arm, and watch the mirror move --------------------------------
    bus_write(R_CTRL, 32'h0000_0001, resp);      // arm
    ck("4b CTRL write is OKAY, not an unmapped-address error", resp === 2'b00);
    repeat (2) @(negedge clk);
    bus_read(R_ACT_B0, rd, resp);
    ck($sformatf("4b ACTIVE_BURST0 now mirrors the committed value (%h)", rd),
       rd === 32'h0103_0004);
    bus_read(R_ACT_S0, rd, resp);
    ck($sformatf("4b ACTIVE_SCALE0 mirrors the committed value (%h)", rd),
       rd === 32'h0003_0100);
    bus_read(R_STATUS, rd, resp);
    ck($sformatf("4b STATUS reports no pending commit (%h)", rd), rd[0] === 1'b0);

    // The applied event, and the interrupt.
    bus_read(R_EVENT, rd, resp);
    ck($sformatf("4b EVENT.applied is set (%h)", rd), rd[1] === 1'b1);
    ck("4b irq is asserted while an event is outstanding", t_irq === 1'b1);
    bus_write(R_EVENT, 32'h0000_0002, resp);     // W1C
    bus_read(R_EVENT, rd, resp);
    ck($sformatf("4b EVENT.applied cleared by writing one (%h)", rd), rd[1] === 1'b0);

    // ---- 4c: the burst, with hand-computed addresses ----------------------
    t_nb = 0; t_nh = 0; t_nt = 0;
    bus_write(R_CTRL, 32'h0000_0002, resp);      // start
    guard = 0;
    while (guard < 40) begin
      @(negedge clk);
      guard = guard + 1;
    end
    $display("      4c  data beats=%0d hdr=%0d trl=%0d first=%h second=%h",
             t_nb, t_nh, t_nt, t_a0, t_a1);
    ck("4c four data beats, from len = 4 in the literal word", t_nb == 4);
    ck("4c framed, from hdr_en = bit 24 of the literal word",
       (t_nh == 1) && (t_nt == 1));
    ck($sformatf("4c first address is base = 0x100 (%h)", t_a0), t_a0 === 16'h0100);
    ck($sformatf("4c second address is base + stride = 0x103 (%h)", t_a1),
       t_a1 === 16'h0103);
    bus_read(R_EVENT, rd, resp);
    ck($sformatf("4c EVENT.done is set (%h)", rd), rd[0] === 1'b1);
    bus_write(R_EVENT, 32'h0000_0001, resp);

    // ---- 4d: the datapath, with a hand-computed result --------------------
    //
    // gain = 256 (1.0 in Q8.8), shift = 3, so y = round(x * 256 / 8) = round(x*32).
    // x = 50 -> p = 12800, +4 for the round, >> 3 = 1600, inside [-2047, 2047].
    t_xvalid = 1'b1; t_x = 12'sd50;
    @(negedge clk);
    t_xvalid = 1'b0;
    repeat (4) @(negedge clk);
    ck($sformatf("4d y = 1600 for x = 50 at gain 1.0 shift 3 (%0d)", t_y),
       t_y === 12'sd1600);

    // ---- 4e: the write lock ----------------------------------------------
    //
    // Reach the locked state the only way it can be reached: a commit armed while
    // the engine it configures is running. The engine is held busy by withdrawing
    // `m_ready` rather than by making the burst long -- the first version of this
    // test used a long burst and the engine finished during the four bus cycles of
    // the write being checked, so the lock had already dropped and the write
    // legitimately succeeded. A test whose setup expires while it runs reports a
    // design bug that is not there.
    bus_write(R_BURST0, 32'h0103_0008, resp);    // len = 8, framed
    bus_write(R_CTRL,   32'h0000_0001, resp);    // arm -- engine idle, so immediate
    repeat (2) @(negedge clk);

    t_mready = 1'b0;                             // freeze the engine
    bus_write(R_CTRL,   32'h0000_0002, resp);    // start -- busy, and staying busy
    repeat (2) @(negedge clk);
    ck("4e the engine is busy", u_top.burst_busy === 1'b1);

    // Staged update while busy but with nothing armed: allowed.
    bus_write(R_BURST0, 32'h0103_0005, resp);
    ck("4e a write while busy but unarmed is accepted", resp === 2'b00);
    bus_write(R_CTRL,   32'h0000_0001, resp);    // arm -- now pending and locked
    @(negedge clk);
    bus_read (R_STATUS, rd, resp);
    ck($sformatf("4e STATUS reports the commit as pending and locked (%h)", rd),
       (rd[0] === 1'b1) && (rd[1] === 1'b1));

    // A configuration write in the locked window: rejected, and reported.
    bus_write(R_BURST1, 32'hDEAD_BEEF, resp);
    ck("4e a write during a pending commit responds SLVERR", resp === 2'b10);
    bus_read(R_BURST1, rd, resp);
    ck($sformatf("4e ...and the staged value was NOT modified (%h)", rd),
       rd === 32'h0000_0100);

    t_mready = 1'b1;                             // let it drain
    guard = 0;
    while (guard < 80) begin
      @(negedge clk);
      guard = guard + 1;
    end
    bus_read(R_ACT_B0, rd, resp);
    ck($sformatf("4e the deferred commit landed once the engine finished (%h)", rd),
       rd === 32'h0103_0005);

    // ---- 4f: arm and start in a single write ------------------------------
    //
    // The commit lands on the same edge the engine samples its snapshot, so
    // without the one-cycle deferral in csr_ctrl_top the burst would run with the
    // PREVIOUS configuration. This checks it runs with the new one.
    bus_write(R_EVENT,  32'h0000_0003, resp);
    bus_write(R_BURST0, 32'h0002_0003, resp);    // len = 3, stride = 2, hdr_en = 0
    bus_write(R_BURST1, 32'h0000_0800, resp);    // base = 0x800
    t_nb = 0; t_nh = 0; t_nt = 0;
    bus_write(R_CTRL,   32'h0000_0003, resp);    // arm AND start, one store
    guard = 0;
    while (guard < 40) begin
      @(negedge clk);
      guard = guard + 1;
    end
    $display("      4f  beats=%0d hdr=%0d trl=%0d first=%h second=%h",
             t_nb, t_nh, t_nt, t_a0, t_a1);
    ck("4f arm+start in one write ran the NEW length", t_nb == 3);
    ck("4f ...unframed, as the new configuration asked",
       (t_nh == 0) && (t_nt == 0));
    ck($sformatf("4f ...from the NEW base (%h)", t_a0), t_a0 === 16'h0800);
    ck($sformatf("4f ...with the NEW stride (%h)", t_a1), t_a1 === 16'h0802);

    // ---- 4h: the scaler, reconfigured while samples are in flight ---------
    //
    // Section 4d put ONE sample through a static configuration, which cannot see
    // a scaler that reads its configuration live -- the mutation matrix in
    // docs/39 section 11 found that gap, not a review. This streams samples
    // continuously and commits a new scale configuration in the middle, checking
    // every output against the configuration that was active when that sample
    // entered the pipeline.
    // THE CONFIGURATION PAIR HAS TO ACTUALLY DIFFER, and the first version of this
    // test did not: gain 256 with shift 3 and gain 64 with shift 1 both compute
    // y = x*32, so committing one over the other changed nothing to detect. The x
    // range compounded it -- samples up to +/-512 at a gain of 32 clamp at +/-2047
    // for |x| > 63, so almost every output was pinned to the bound under either
    // configuration. Two independent reasons the check could see nothing, and the
    // mutation matrix in docs/39 section 11 is what found them: a scaler rebuilt to
    // read its configuration live passed this section unchanged.
    //
    //   A: gain 0x0100, shift 3 -> y = x * 32
    //   B: gain 0x0180, shift 5 -> y = x * 12
    //
    // with |x| <= 60 so neither saturates, and a beat that mixes them (gain from A,
    // shift from B) landing on x*8 -- distinguishable from both.
    bus_write(R_SCALE0, 32'h0003_0100, resp);     // gain 1.0,   shift 3
    bus_write(R_SCALE1, 32'h07FF_F801, resp);     // lo -2047, hi +2047
    bus_write(R_CTRL,   32'h0000_0001, resp);     // arm
    repeat (3) @(negedge clk);

    t_nchk = 0; t_nbad = 0;
    t_track = 1'b1;
    t_en = 1'b1; t_xvalid = 1'b1;

    for (i = 0; i < 40; i++) begin
      t_x = XW'($urandom_range(0, 120)) - XW'(60);
      // A different gain AND shift, committed mid-stream. Nothing
      // pauses: with the scaler carrying its configuration alongside the data
      // this is legal at full rate, and that is the claim being tested.
      //
      // Forked, so the bus transaction runs concurrently with the sample stream.
      // Hand-rolling the handshake inline here instead -- asserting AWVALID and
      // dropping it a fixed number of cycles later -- moved VALID before READY
      // and axil_slave's own protocol assertions failed, which is exactly what
      // they are for.
      if (i == 15) fork bus_cfg_change(); join_none
      @(negedge clk);
    end
    t_xvalid = 1'b0;
    repeat (6) @(negedge clk);
    t_track = 1'b0;

    $display("      4h  %0d beats checked through the top, %0d wrong", t_nchk, t_nbad);
    ck("4h the top produced a stream", t_nchk > 20);
    ck("4h every beat matched the configuration it entered under", t_nbad == 0);
    bus_read(R_ACT_S0, rd, resp);
    ck($sformatf("4h the mid-stream commit landed (%h)", rd), rd === 32'h0005_0180);

    // ---- 4g: an unmapped address is still an error -----------------------
    bus_read(6'h3C, rd, resp);
    ck("4g an unmapped read still responds SLVERR", resp === 2'b10);

    // -----------------------------------------------------------------------
    if (err == 0) $display("csr_config_tb: PASS");
    else          $display("csr_config_tb: FAIL -- %0d checks failed", err);
    $finish;
  end

  initial begin
    #500000;
    $display("csr_config_tb: FAIL -- timeout");
    $finish;
  end

endmodule
