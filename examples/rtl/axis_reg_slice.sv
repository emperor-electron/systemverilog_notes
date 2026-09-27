// -----------------------------------------------------------------------------
// axis_reg_slice.sv -- the five ways to put a register in a valid/ready path,
// in one module, so they can be compared instead of argued about.
//
// A handshake has two directions, and each can be registered or not:
//
//   FORWARD   valid + payload, source -> sink
//   BACKWARD  ready,           sink   -> source
//
// Cutting a path means putting a register in it. Cutting the FORWARD path is
// easy. Cutting the BACKWARD path costs STORAGE, because during the cycle the
// source has not yet seen `ready` fall it may still send a beat, and that beat
// needs somewhere to live. Everything below follows from those two sentences.
//
//   MODE  name        slots  fwd cut  bwd cut  rate   what it is
//   ----  ----------  -----  -------  -------  -----  --------------------------
//    0    PASS          0      no       no     100%   wires; the baseline
//    1    FWD           1      YES      no     100%   "pipeline register"
//    2    REV           1      no       YES    100%   "ready-registered slice"
//    3    FULL          2      YES      YES    100%   the skid buffer
//    4    HALF          1      YES      YES     50%   "half-rate" / light-weight
//
// The interesting line is the last two. FULL and HALF both cut both directions;
// FULL pays two slots and keeps full throughput, HALF pays one slot and gives up
// half the bandwidth. That is the whole trade, and it is why HALF exists at all:
// it is the cheapest structure that makes EVERY output of the block a register,
// which is what you want on a chip-crossing bus or anywhere the timing budget is
// gone and the bandwidth is not needed.
//
// WHY 100% FOR PASS, FWD, REV AND FULL. "Rate" here means the sustained rate
// with the source always offering and the sink always accepting. All four move
// one beat per cycle. They differ in what happens the cycle a stall ARRIVES:
// PASS and FWD tell the source immediately (combinational `ready`), REV and FULL
// tell it a cycle late and absorb the beat that was already in flight.
//
// MODE is an integer rather than a string because the Yosys frontend rejects
// string parameters (see the Makefile) -- the named localparams below are the
// documentation.
//
// See docs/38 for the measurements: which paths are combinational (probed in
// simulation by toggling a signal between clock edges), the sustained rate of
// each mode, and the flop count.
// -----------------------------------------------------------------------------
`default_nettype none

module axis_reg_slice #(
  parameter int unsigned DW   = 32,
  parameter int unsigned MODE = 3      // 0 PASS, 1 FWD, 2 REV, 3 FULL, 4 HALF
) (
  input  var logic          clk,
  input  var logic          rst_n,

  input  var logic          s_valid,
  input  var logic [DW-1:0] s_data,
  output var logic          s_ready,

  output var logic          m_valid,
  output var logic [DW-1:0] m_data,
  input  var logic          m_ready
);

  localparam int unsigned MODE_PASS = 0;
  localparam int unsigned MODE_FWD  = 1;
  localparam int unsigned MODE_REV  = 2;
  localparam int unsigned MODE_FULL = 3;
  localparam int unsigned MODE_HALF = 4;

  if (MODE > MODE_HALF) begin : g_chk_mode
    $error("axis_reg_slice: MODE must be 0..4, got %0d", MODE);
  end

  // ---- 0: PASS -- no register at all --------------------------------------
  if (MODE == MODE_PASS) begin : g_pass
    // Here so that MODE can be swept without changing the instantiation, and so
    // that a measurement of "what does a slice cost" has a zero to compare with.
    assign m_valid = s_valid;
    assign m_data  = s_data;
    assign s_ready = m_ready;

`ifdef FORMAL
    assign fv_occ = '0;                 // nothing is stored, ever
`endif

  // ---- 1: FWD -- forward registered ---------------------------------------
  end else if (MODE == MODE_FWD) begin : g_fwd
    // The output side is a register, so `m_valid` and `m_data` are clean. The
    // ready path stays combinational: the source learns about a stall in the
    // same cycle, which is why one slot is enough.
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        m_valid <= 1'b0;
        m_data  <= '0;
      end else if (s_valid && s_ready) begin
        m_valid <= 1'b1;
        m_data  <= s_data;
      end else if (m_valid && m_ready) begin
        m_valid <= 1'b0;
      end
    end

    // Combinational from m_ready -- this is the path this mode does NOT cut.
    assign s_ready = !m_valid || m_ready;

`ifdef FORMAL
    assign fv_occ = DW'(m_valid);
`endif

  // ---- 2: REV -- reverse (ready) registered -------------------------------
  end else if (MODE == MODE_REV) begin : g_rev
    // `s_ready` is a register, so nothing downstream reaches the source
    // combinationally. The forward path is a mux instead: a beat either flows
    // straight through, or comes from the slot that caught it when the sink
    // refused it.
    logic          slot_valid;
    logic [DW-1:0] slot_data;

    assign s_ready = !slot_valid;        // a register, not an expression of m_ready
    assign m_valid = slot_valid || s_valid;
    assign m_data  = slot_valid ? slot_data : s_data;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        slot_valid <= 1'b0;
        slot_data  <= '0;
      end else if (slot_valid) begin
        if (m_ready) slot_valid <= 1'b0;             // the slot drains
      end else if (s_valid && !m_ready) begin
        // Offered, accepted (s_ready was high), and the sink would not take it:
        // this is the beat that needs somewhere to live.
        slot_valid <= 1'b1;
        slot_data  <= s_data;
      end
    end

`ifdef FORMAL
    assign fv_occ = DW'(slot_valid);
    // The slot holds the beat that is about to go out, so its payload is the
    // next sequence number. Without this the induction step is free to invent a
    // slot holding the wrong beat -- the same invariant skid_buffer.sv needs.
    always @* if (slot_valid) assert (slot_data == fv_out_seq);
`endif

  // ---- 3: FULL -- both directions, full rate: the skid buffer -------------
  end else if (MODE == MODE_FULL) begin : g_full
    // Not reimplemented here. skid_buffer.sv already carries the proof that it
    // loses, duplicates and reorders nothing, and that its occupancy invariant
    // closes under induction.
    skid_buffer #(.DW(DW)) u_skid (
      .clk       (clk),
      .rst_n     (rst_n),
      .in_valid  (s_valid),
      .in_data   (s_data),
      .in_ready  (s_ready),
      .out_valid (m_valid),
      .out_data  (m_data),
      .out_ready (m_ready)
    );

  // ---- 4: HALF -- both directions, one slot, half rate -------------------
  end else begin : g_half
    // Every output is a register and there is one slot. The cost falls out of
    // those two facts: the slot cannot be reloaded in the same cycle it drains,
    // because deciding to reload needs `m_ready`, and using `m_ready` in the
    // load condition is exactly what would put it back in the `s_ready` path.
    // So the slot fills on one cycle and empties on the next: one beat per two
    // cycles, for ever.
    logic full_q;

    assign s_ready = !full_q;
    assign m_valid = full_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        full_q <= 1'b0;
        m_data <= '0;
      end else if (!full_q) begin
        if (s_valid) begin
          full_q <= 1'b1;
          m_data <= s_data;
        end
      end else if (m_ready) begin
        full_q <= 1'b0;
      end
    end

`ifdef FORMAL
    assign fv_occ = DW'(full_q);
`endif
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Sequence numbering, the same technique skid_buffer.sv uses: constrain the
  // producer so that every beat's PAYLOAD IS ITS SEQUENCE NUMBER, then assert
  // that the output counts up with no gaps. One assertion then covers three
  // failures -- a gap is a lost beat, a repeat is a duplicate, a step backwards
  // is a reordering. Sound because none of these modes looks at the payload.
  //
  // It lives inside the module because the occupancy invariant below needs the
  // internal slot state, and the Yosys formal flow cannot read a hierarchical
  // reference into an instance (docs/25, docs/37 section 13).
  // ---------------------------------------------------------------------------
  logic [DW-1:0] fv_in_seq, fv_out_seq, fv_occ;

  always @* assume (s_data == fv_in_seq);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fv_in_seq  <= '0;
      fv_out_seq <= '0;
    end else begin
      if (s_valid && s_ready) fv_in_seq  <= fv_in_seq  + 1'b1;
      if (m_valid && m_ready) fv_out_seq <= fv_out_seq + 1'b1;
    end
  end

  always @* begin
    if (rst_n) begin
      f_stream : assert (!m_valid || (m_data == fv_out_seq));
    end
  end

  // What is in flight must equal what went in minus what came out. This is the
  // invariant that makes INDUCTION close: without it the solver starts from a
  // state where the slot holds a beat nobody sent.
  //
  // MODE_FULL is excluded because its storage is inside skid_buffer, which this
  // module cannot see into -- and does not need to, because skid_buffer_fv
  // already proves the same property where the state is visible. The FULL task
  // in axis_reg_slice_fv.sby is therefore bounded, and says so.
  if (MODE != MODE_FULL) begin : g_fv_occ
    always @* if (rst_n) f_occupancy : assert ((fv_in_seq - fv_out_seq) == fv_occ);
  end
`endif

`ifndef SYNTHESIS
  // The AXI-Stream contract, on both sides. PASS is excluded from the output
  // side because it has no state of its own: it can only be as well behaved as
  // whatever is upstream of it, and asserting otherwise would blame this module
  // for someone else's protocol violation.
  if (MODE != MODE_PASS) begin : g_a_stable
    a_out_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_data)))
      else $error("axis_reg_slice(MODE=%0d): payload moved before handshake", MODE);
  end

  // The half-rate mode's defining property, asserted rather than described: two
  // consecutive input transfers are impossible.
  if (MODE == MODE_HALF) begin : g_a_half
    a_half_rate: assert property (@(posedge clk) disable iff (!rst_n)
      (s_valid && s_ready) |=> !(s_valid && s_ready))
      else $error("axis_reg_slice(HALF): accepted two beats back to back");
  end
`endif

endmodule

`default_nettype wire
