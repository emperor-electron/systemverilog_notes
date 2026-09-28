// -----------------------------------------------------------------------------
// cfg_burst_fsm.sv -- an FSM whose state graph depends on its configuration, so
// that changing the configuration mid-run can land it on a path that does not
// exist.
//
// It emits a framed burst:
//
//      hdr_en=0:            DATA x len
//      hdr_en=1:    HDR  +  DATA x len  +  TRL
//
// with addresses base, base+stride, base+2*stride, ... and back-pressure on the
// output. Three configuration fields, each broken by a mid-run write in a
// different way, which is the point of using one example rather than three:
//
//   len     the terminal condition. Shrink it below the count of a burst already
//           running and `cnt == len-1` is never true again: the engine emits
//           beats until the counter wraps all the way round. A HANG, out of a
//           perfectly legal store to a perfectly legal register.
//   stride  used on every beat. Change it and the second half of the burst walks
//           a different address sequence from the first -- a scatter into memory
//           that was never described by any descriptor.
//   hdr_en  the SHAPE OF THE STATE GRAPH. Enter with it set, so a header goes
//           out, then clear it: the DATA state now exits straight to IDLE and the
//           packet has a header and no trailer. Nothing downstream can parse
//           that, and no state in this FSM was ever illegal -- the FSM walked a
//           legal path through a graph that changed under it.
//
// That last one is the one worth dwelling on. Guarding against config changes by
// making the terminal test `>=` instead of `==` fixes the hang and nothing else:
// the burst still ends after the wrong number of beats, and `hdr_en` is not a
// comparison at all. There is no arithmetic trick that makes a state machine
// safe against its own configuration moving. The configuration has to hold
// still.
//
// LIVE_CFG selects which it does:
//
//   0  the configuration is SNAPSHOT into `cfg_q` at the start of each burst and
//      the FSM reads only the snapshot. `safe` is exported so csr_shadow.sv can
//      be told when a commit is allowed; but note that even with a TRANSPARENT
//      shadow -- no protection at the bank at all -- this module is still correct,
//      because the snapshot is its own. Two independent defences, and docs/39
//      section 8 is about which one you actually need.
//   1  the FSM reads `cfg` live. This is the bug, kept as a parameter so that the
//      proofs and the testbench can both be pointed at it: a fault you can
//      switch on is a fault you can prove your checks would have caught.
//
// See docs/39-control-registers-and-safe-reconfiguration.md.
// -----------------------------------------------------------------------------
`default_nettype none

module cfg_burst_fsm #(
  parameter bit LIVE_CFG = 1'b0
) (
  input  var logic                             clk,
  input  var logic                             rst_n,

  input  var logic [cfg_pkg::BURST_CFGW-1:0]   cfg,
  input  var logic                             start,    // one-cycle command

  output var logic                             m_valid,
  output var logic [cfg_pkg::ADDRW-1:0]        m_addr,
  output var logic [cfg_pkg::KINDW-1:0]        m_kind,
  input  var logic                             m_ready,

  output var logic                             busy,
  output var logic                             done,     // one cycle, per burst
  output var logic                             safe      // ok to commit now
);

  localparam int unsigned LENW    = cfg_pkg::LENW;
  localparam int unsigned STRIDEW = cfg_pkg::STRIDEW;
  localparam int unsigned ADDRW   = cfg_pkg::ADDRW;

  typedef enum logic [1:0] { S_IDLE, S_HDR, S_DATA, S_TRL } state_e;

  state_e                          state_q, state_d;
  logic [LENW-1:0]                 cnt_q;
  logic [ADDRW-1:0]                addr_q;
  logic                            done_q;

  // ---- which configuration the FSM reads -----------------------------------
  logic [cfg_pkg::BURST_CFGW-1:0]  cfg_u;

  if (LIVE_CFG) begin : g_live
    // No storage. Every field below is a wire back to the register bank, and
    // therefore to whatever the processor did three cycles ago.
    assign cfg_u = cfg;

  end else begin : g_snap
    logic [cfg_pkg::BURST_CFGW-1:0] cfg_q;

    // The whole bundle, one enable, at one instant -- the same shape as the
    // commit in csr_shadow.sv, for the same reason. Loading fields separately or
    // on separate cycles would put the tearing back.
    always_ff @(posedge clk or negedge rst_n) begin
      if      (!rst_n)        cfg_q <= '0;
      else if (start && safe) cfg_q <= cfg;
    end

    assign cfg_u = cfg_q;
  end

  logic [LENW-1:0]    len_u;
  logic [STRIDEW-1:0] stride_u;
  logic [ADDRW-1:0]   base_u;
  logic               hdr_u;

  assign len_u    = cfg_pkg::burst_len   (cfg_u);
  assign stride_u = cfg_pkg::burst_stride(cfg_u);
  assign base_u   = cfg_pkg::burst_base  (cfg_u);
  assign hdr_u    = cfg_pkg::burst_hdr_en(cfg_u);

  // The start decision reads the INCOMING configuration, because at the edge
  // that takes the snapshot `cfg_q` still holds the previous burst's copy. With
  // LIVE_CFG the two are the same wire, so this costs nothing there.
  logic [LENW-1:0] len_new;
  logic            hdr_new;
  assign len_new = cfg_pkg::burst_len   (cfg);
  assign hdr_new = cfg_pkg::burst_hdr_en(cfg);

  // ---- outputs -------------------------------------------------------------
  logic last_data, xfer;

  assign busy      = (state_q != S_IDLE);
  assign safe      = (state_q == S_IDLE);
  assign m_valid   = busy;
  assign m_addr    = addr_q;
  assign m_kind    = (state_q == S_HDR) ? cfg_pkg::K_HDR
                   : (state_q == S_TRL) ? cfg_pkg::K_TRL
                                        : cfg_pkg::K_DATA;
  assign done      = done_q;
  assign xfer      = m_valid && m_ready;
  assign last_data = (state_q == S_DATA) && (cnt_q == (len_u - 1'b1));

  // ---- next state ----------------------------------------------------------
  //
  // A zero-length burst is refused rather than started: started, it would run
  // 4096 beats on the wrap of `cnt == len-1`. Refusing is one comparison and no
  // surprises.
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      S_IDLE: if (start && (len_new != '0)) state_d = hdr_new ? S_HDR : S_DATA;
      S_HDR:  if (xfer)                    state_d = S_DATA;
      S_DATA: if (xfer && last_data)       state_d = hdr_u ? S_TRL : S_IDLE;
      S_TRL:  if (xfer)                    state_d = S_IDLE;
      default:                             state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      cnt_q   <= '0;
      addr_q  <= '0;
      done_q  <= 1'b0;
    end else begin
      state_q <= state_d;
      done_q  <= (state_d == S_IDLE) && (state_q != S_IDLE);

      if (state_q == S_IDLE) begin
        if (start && (len_new != '0)) begin
          cnt_q  <= '0;
          addr_q <= cfg_pkg::burst_base(cfg);
        end
      end else if (xfer && (state_q == S_DATA)) begin
        // Incremental addressing: one add per beat rather than a multiplier. The
        // formal block below checks it against base + cnt*stride, which is a
        // different expression and therefore an actual check.
        cnt_q  <= cnt_q + 1'b1;
        addr_q <= addr_q + ADDRW'(stride_u);
      end
    end
  end

`ifdef FORMAL
  logic                           f_rst_q  = 1'b0;
  logic                           f_busy_q = 1'b0;
  logic [cfg_pkg::BURST_CFGW-1:0] f_cfgu_q;
  logic [LENW-1:0]                f_len_q;      // len as sampled at start
  logic                           f_hdr_q;      // hdr_en as sampled at start
  logic [LENW-1:0]                f_beats;      // DATA beats accepted this burst
  logic                           f_saw_hdr;    // a header went out this burst
  logic [ADDRW-1:0]               f_ref_addr;

  always_ff @(posedge clk) f_rst_q  <= rst_n;
  always_ff @(posedge clk) f_busy_q <= busy;
  always_ff @(posedge clk) f_cfgu_q <= cfg_u;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_len_q   <= '0;
      f_hdr_q   <= 1'b0;
      f_beats   <= '0;
      f_saw_hdr <= 1'b0;
    end else if ((state_q == S_IDLE) && start && (len_new != '0)) begin
      f_len_q   <= len_new;
      f_hdr_q   <= hdr_new;
      f_beats   <= '0;
      f_saw_hdr <= 1'b0;
    end else begin
      if (xfer && (state_q == S_DATA)) f_beats   <= f_beats + 1'b1;
      if (xfer && (state_q == S_HDR))  f_saw_hdr <= 1'b1;
    end
  end

  // base + cnt*stride, computed with a multiplier. The datapath adds `stride`
  // once per beat and never multiplies, so this is an independent statement of
  // the address law rather than a restatement of the implementation.
  always_comb
    f_ref_addr = base_u + ADDRW'(ADDRW'(cnt_q) * ADDRW'(stride_u));

  always @(posedge clk) begin
    if (rst_n && f_rst_q) begin
      // (1) ISOLATION. The configuration the FSM reads does not move while a
      // burst is running. Everything else here is downstream of this one line;
      // with LIVE_CFG this is the assertion that fails first.
      //
      // `busy && f_busy_q`, not `busy`: the snapshot loads on the very edge that
      // makes the engine busy, so the naive form fires on the first cycle of
      // every correct burst. Written the naive way this failed at step 3 and it
      // took reading the trace to see that the DESIGN was right and the PROPERTY
      // was wrong -- the usual ratio, and the reason a first failure is worth
      // understanding before it is worth fixing.
      if (busy && f_busy_q) assert (cfg_u == f_cfgu_q);

      // (2) the address law, in every state that emits a beat. Stated over all of
      // `busy` rather than just the data phase because the header and trailer
      // addresses are the ends of the same sequence -- and because a property that
      // holds in every reachable state is the kind induction can use.
      if (busy) assert (m_addr == f_ref_addr);

      // (3) no overrun: the counter stays inside the length it started with.
      // This is the HANG, stated as a safety property -- a burst whose length
      // shrank under it violates this on the very next beat rather than running
      // for 4096 cycles and being noticed as a timeout.
      if (state_q == S_DATA) assert (cnt_q < f_len_q);

      // (4) exactly as many DATA beats as the length that was latched.
      if (done) assert (f_beats == f_len_q);

      // (5) WELL-FORMEDNESS. A trailer is emitted if and only if a header was.
      // Purely control -- no arithmetic to make defensive -- and it is the
      // property that no amount of careful comparison in the datapath can
      // recover once the graph is allowed to change shape mid-run.
      if (state_q == S_TRL) assert (f_saw_hdr);
      if (done)             assert (f_saw_hdr == f_hdr_q);

      // (6) ORDERING. A header precedes every data beat of its burst, and a
      // trailer follows all of them. `inside` would have been the natural way to
      // write a one-hot-state check here; the Yosys frontend rejects it
      // (docs/25), and in any case all four encodings of a 2-bit state are legal
      // so that check would have been vacuous. This one is not.
      if (state_q == S_HDR) assert (f_beats == '0);
      if (state_q == S_TRL) assert (f_beats == f_len_q);

      // ---- (7)..(10) tying the bookkeeping to the snapshot -------------------
      //
      // The six above are what the module PROMISES. These four say that the
      // burst-scoped counters in this block were taken from the same snapshot the
      // FSM is reading, which is what makes the six mean what they appear to
      // mean: without them nothing rules out a state where `f_len_q` and the
      // length the FSM is using are different numbers, and that is not a state
      // this module can be in.
      //
      // They were written to close k-induction, because `prove` returned UNKNOWN
      // while `bmc` passed -- the usual signature of a specification that is true
      // but not self-supporting. THEY DID NOT CLOSE IT: measured, induction still
      // returns UNKNOWN after 677 seconds, and the obstruction is the multiplier
      // in (2). They stay because they are true and the bounded proof checks them.
      // See cfg_burst_fsm_fv.sv for what replaced the unbounded claim.

      // (7) the bookkeeping was taken from the same snapshot the FSM is using.
      if (busy) begin
        assert (f_len_q == len_u);
        assert (f_hdr_q == hdr_u);
      end

      // (8) the data-beat count and the address counter are the same number.
      if (busy) assert (f_beats == cnt_q);

      // (9) a header is only in flight when one was asked for, and it has not
      // been counted yet.
      if (state_q == S_HDR) assert (f_hdr_q && !f_saw_hdr);

      // (10) past the header phase, "a header went out" and "a header was asked
      // for" are the same bit. This is (5) made inductive.
      if ((state_q == S_DATA) || (state_q == S_TRL))
        assert (f_saw_hdr == f_hdr_q);
    end
  end
`endif

`ifndef SYNTHESIS
  // An offer is never withdrawn and its payload never moves, which is what the
  // downstream skid buffer in docs/38 is entitled to assume.
  a_hold: assert property (@(posedge clk) disable iff (!rst_n)
    (m_valid && !m_ready) |=> (m_valid && $stable(m_addr) && $stable(m_kind)))
    else $error("cfg_burst_fsm: withdrew or altered an unaccepted beat");

  a_done_idle: assert property (@(posedge clk) disable iff (!rst_n)
    done |-> (state_q == S_IDLE))
    else $error("cfg_burst_fsm: done asserted while still running");
`endif

endmodule

`default_nettype wire
