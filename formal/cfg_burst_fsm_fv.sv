// -----------------------------------------------------------------------------
// cfg_burst_fsm_fv.sv -- an FSM against a configuration that moves under it.
//
// Everything asserted is inside cfg_burst_fsm.sv: the isolation property, the
// address law, the no-overrun bound and the header/trailer pairing all need the
// burst-scoped counters, and those belong beside the state they account for.
//
// WHAT THIS HARNESS SUPPLIES, AND WHY EACH PIECE MATTERS
//
// `cfg` IS FREE AND CHANGES ON EVERY CYCLE IF THE SOLVER WANTS IT TO. That is the
// entire experiment. A harness that held the configuration still while a burst
// ran would prove nothing about snapshotting -- the LIVE_CFG=1 build would pass
// it too. The cover f_c_cfg_moved below exists to confirm the solver really is
// moving it, because "the hazard was never exercised" and "the design is immune
// to the hazard" produce identical PASS output.
//
// `start` is free, including during a burst. A spurious start must be ignored
// rather than restart the count, and leaving it free is cheaper than assuming it
// away and then discovering the assumption was the only thing holding.
//
// THE ONE ASSUMPTION: the length is bounded to 1..4. That is purely to keep the
// bounded proof short -- a 4095-beat burst needs 4095 steps to complete and
// nothing about the properties changes with the number.
//
// THERE IS NO `prove` TASK. There was, and it does not close: measured, induction
// returns UNKNOWN after 677 seconds even with the four extra invariants the DUT
// carries for its benefit. The obstruction is the multiplier in the address law --
// showing that `addr + stride == base + (cnt+1)*stride` from an ARBITRARY starting
// state needs distributivity over a 16x16 multiply, which is not a thing to hand a
// bit-vector solver and hope. `bmc` at depth 22 covers every burst up to length 4
// through to completion, back-pressure and all, which is every distinct behaviour
// this state machine has; docs/39 section 11 states the limit rather than papering
// over it.
// -----------------------------------------------------------------------------
`default_nettype none

module cfg_burst_fsm_fv #(
  parameter bit LIVE_CFG = 1'b0
) (
  input  var logic                           clk,
  input  var logic                           rst_n,
  input  var logic [cfg_pkg::BURST_CFGW-1:0] cfg,
  input  var logic                           start,
  input  var logic                           m_ready
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic                         m_valid, busy, done, safe;
  logic [cfg_pkg::ADDRW-1:0]    m_addr;
  logic [cfg_pkg::KINDW-1:0]    m_kind;

  cfg_burst_fsm #(.LIVE_CFG(LIVE_CFG)) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .cfg     (cfg),
    .start   (start),
    .m_valid (m_valid),
    .m_addr  (m_addr),
    .m_kind  (m_kind),
    .m_ready (m_ready),
    .busy    (busy),
    .done    (done),
    .safe    (safe)
  );

  // Bound the length. Everything else about `cfg` -- stride, base, hdr_en, and
  // when any of them change -- is left to the solver.
  always @* assume ((cfg_pkg::burst_len(cfg) >= 1) && (cfg_pkg::burst_len(cfg) <= 4));

  // ---- harness-side framing observation ------------------------------------
  //
  // Tracked out here rather than read out of the instance: the Yosys frontend
  // rejects a hierarchical reference into a submodule (docs/37 section 13), so a
  // cover on `dut.f_saw_hdr` is not available. Ports only.
  logic xfer;
  logic saw_hdr, saw_trl;
  int   beats;

  assign xfer = m_valid && m_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      saw_hdr <= 1'b0;
      saw_trl <= 1'b0;
      beats   <= 0;
    end else if (done) begin
      saw_hdr <= 1'b0;
      saw_trl <= 1'b0;
      beats   <= 0;
    end else if (xfer) begin
      if (m_kind == cfg_pkg::K_HDR)  saw_hdr <= 1'b1;
      if (m_kind == cfg_pkg::K_TRL)  saw_trl <= 1'b1;
      if (m_kind == cfg_pkg::K_DATA) beats   <= beats + 1;
    end
  end

  // Did the configuration actually move while a burst was in flight?
  logic [cfg_pkg::BURST_CFGW-1:0] cfg_q;
  logic                           cfg_moved;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_q     <= '0;
      cfg_moved <= 1'b0;
    end else begin
      cfg_q <= cfg;
      if (done)                          cfg_moved <= 1'b0;
      else if (busy && (cfg != cfg_q))   cfg_moved <= 1'b1;
    end
  end

  always @(posedge clk) begin
    // A framed burst completed: header, data, trailer, in that order.
    f_c_framed     : cover (rst_n && past_ok && done && saw_hdr && saw_trl);

    // An unframed burst completed: neither header nor trailer.
    f_c_unframed   : cover (rst_n && past_ok && done && !saw_hdr && !saw_trl);

    // THE ONE THAT MATTERS. A burst that completed correctly while the
    // configuration was being rewritten underneath it. Without this cover, every
    // assertion in the DUT could be passing because the solver happened to leave
    // `cfg` alone -- which is exactly how the LIVE_CFG build would also pass.
    f_c_cfg_moved  : cover (rst_n && past_ok && done && cfg_moved);

    // ...and the same thing at full length, so the moving configuration had time
    // to matter.
    f_c_long_moved : cover (rst_n && past_ok && done && cfg_moved && (beats == 4));

    // Back-pressure in the middle of the data phase.
    f_c_stalled    : cover (rst_n && past_ok && m_valid && !m_ready
                            && (m_kind == cfg_pkg::K_DATA));

    // A start arriving while a burst is already running, which must be ignored.
    f_c_restart    : cover (rst_n && past_ok && start && busy);
  end

endmodule

`default_nettype wire
