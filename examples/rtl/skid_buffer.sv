// -----------------------------------------------------------------------------
// skid_buffer.sv -- registers a valid/ready (AXI-Stream style) handshake in
// BOTH directions with no loss of throughput.
//
// The problem: registering `valid` and `data` is easy, but `ready` flows
// backwards. Registering it too adds a cycle of latency to the backpressure
// signal, during which the upstream may still send a beat that the downstream
// has already refused. That beat must be held somewhere -- the "skid" buffer.
//
// Result: every output (including out_ready -> in_ready) is registered, the
// combinational path is broken in both directions, and full throughput
// (one beat per cycle) is maintained.
//
// Cost: 2 x DW flops + a little control. This is THE standard pipeline-stage
// element; a long bus should have one every few hundred microns.
// -----------------------------------------------------------------------------
`default_nettype none

module skid_buffer #(
  parameter int unsigned DW = 32
) (
  input  var logic          clk,
  input  var logic          rst_n,

  input  var logic          in_valid,
  input  var logic [DW-1:0] in_data,
  output var logic          in_ready,

  output var logic          out_valid,
  output var logic [DW-1:0] out_data,
  input  var logic          out_ready
);

  logic [DW-1:0] skid_data;
  logic          skid_valid;

  // Accept input whenever the skid slot is free.
  assign in_ready = !skid_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid  <= 1'b0;
      out_data   <= '0;
      skid_valid <= 1'b0;
      skid_data  <= '0;
    end else begin
      if (skid_valid) begin
        // Drain the skid slot into the output register when it frees up.
        if (!out_valid || out_ready) begin
          out_valid  <= 1'b1;
          out_data   <= skid_data;
          skid_valid <= 1'b0;
        end
      end else if (!out_valid || out_ready) begin
        // Output register is free: take directly from the input.
        out_valid <= in_valid;
        if (in_valid) out_data <= in_data;
      end else if (in_valid) begin
        // Output register is busy and the input has a beat: park it.
        skid_valid <= 1'b1;
        skid_data  <= in_data;
      end
    end
  end

// -----------------------------------------------------------------------------
// Properties. Note that there are TWO sets, in two different styles, because
// the two tools accept different subsets of the language:
//
//   `ifndef SYNTHESIS  idiomatic SVA -- concurrent assertions with a clocking
//                      event and the |=> implication operator. XSIM runs these.
//                      Yosys cannot parse them at all, which is why they sit
//                      behind a guard it also honours (sby defines SYNTHESIS).
//
//   `ifdef FORMAL      immediate assertions inside a clocked block, with $past
//                      for temporal relationships. This is the only style
//                      Yosys's open-source frontend accepts.
//
// The FORMAL block also lives HERE rather than in formal/skid_buffer_fv.sv for
// a specific reason: Yosys's formal flow cannot read a hierarchical reference
// into a submodule -- `dut.skid_valid == !in_ready` FAILS even though in_ready
// is defined as !skid_valid. Any property that needs internal state therefore
// has to be inside the module. See docs/25.
// -----------------------------------------------------------------------------
`ifndef SYNTHESIS
  // AXI-Stream rule: valid must not be withdrawn before ready is seen.
  a_out_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (out_valid && !out_ready) |=> (out_valid && $stable(out_data)))
    else $error("skid_buffer: output payload changed before handshake");

  a_no_drop: assert property (@(posedge clk) disable iff (!rst_n)
    (in_valid && !in_ready) |=> in_valid)
    else $error("skid_buffer: upstream dropped valid (protocol violation)");
`endif

`ifdef FORMAL
  // ---- sequence numbering ---------------------------------------------------
  // Constrain the producer so that each beat's PAYLOAD IS ITS SEQUENCE NUMBER,
  // then assert the output counts up with no gaps. One pair of counters proves
  // three things at once:
  //     a gap        => a beat was lost
  //     a repeat     => a beat was duplicated
  //     out of order => reordering
  // This is sound because the datapath is DATA-INDEPENDENT -- the control logic
  // never inspects the payload -- so proving it for one stream proves it for
  // all. It would NOT be sound for a block that branches on its data.
  logic [DW-1:0] fv_in_seq  = '0;
  logic [DW-1:0] fv_out_seq = '0;

  always @* assume (in_data == fv_in_seq);

  always @(posedge clk) begin
    if (!rst_n) begin
      fv_in_seq  <= '0;
      fv_out_seq <= '0;
    end else begin
      if (in_valid  && in_ready)  fv_in_seq  <= fv_in_seq  + 1'b1;
      if (out_valid && out_ready) fv_out_seq <= fv_out_seq + 1'b1;
    end
  end

  logic fv_past = 1'b0;
  always @(posedge clk) fv_past <= 1'b1;

  always @(posedge clk) begin
    if (rst_n) begin
      // The end-to-end property: no loss, no duplication, no reordering.
      f_stream  : assert (!out_valid || (out_data == fv_out_seq));

      // ---- invariants that make the INDUCTION step close ------------------
      // BMC starts from the real reset state, so f_stream alone suffices there.
      // Induction starts from an ARBITRARY state satisfying the assertions, so
      // anything left unpinned is something the solver may invent -- here, a
      // skid slot holding the wrong beat. The fix is a stronger description of
      // the reachable state space, not a weaker property.
      f_occupancy: assert ((fv_in_seq - fv_out_seq) ==
                           (DW'(out_valid) + DW'(skid_valid)));
      f_no_orphan: assert (!skid_valid || out_valid);
      f_skid_val : assert (!skid_valid || (skid_data == (fv_out_seq + 1'b1)));

      if (fv_past) begin
        // The DUT must itself obey the protocol downstream.
        f_out_hold : assert (!($past(rst_n) && $past(out_valid)
                               && !$past(out_ready))
                             || (out_valid && out_data == $past(out_data)));
      end
    end
  end

  always @(posedge clk) begin
    f_c_b2b   : cover (rst_n && in_valid && in_ready && out_valid && out_ready);
    f_c_skid  : cover (rst_n && !in_ready);
    f_c_drain : cover (rst_n && fv_past && $past(!in_ready) && in_ready);
  end
`endif

endmodule

`default_nettype wire
