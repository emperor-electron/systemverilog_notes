// -----------------------------------------------------------------------------
// sync_fifo.sv -- synchronous FIFO, single clock.
//
// Uses an extra MSB on the pointers so that full and empty are distinguishable
// without wasting an entry and without a separate counter:
//
//   empty : rd_ptr == wr_ptr                  (all bits equal)
//   full  : rd_ptr == {~wr_ptr[AW], wr_ptr[AW-1:0]}
//           (MSBs differ, low bits equal => the writer has lapped the reader)
//
// DEPTH must be a power of two for the pointer wrap to line up.
// -----------------------------------------------------------------------------
`default_nettype none

module sync_fifo #(
  parameter int unsigned DW    = 32,
  parameter int unsigned DEPTH = 16,
  parameter bit          FWFT  = 1'b0   // 1 = first-word fall-through (show-ahead)
) (
  input  var logic          clk,
  input  var logic          rst_n,

  input  var logic          wr_en,
  input  var logic [DW-1:0] wr_data,
  output var logic          full,
  output var logic          almost_full,

  input  var logic          rd_en,
  output var logic [DW-1:0] rd_data,
  output var logic          empty,
  output var logic          almost_empty,

  output var logic [$clog2(DEPTH):0] level
);

  localparam int unsigned AW = $clog2(DEPTH);

  // Elaboration-time parameter checks.
  if (DEPTH < 2) begin : g_chk_min
    $error("sync_fifo: DEPTH must be >= 2, got %0d", DEPTH);
  end
  if (DEPTH != (1 << AW)) begin : g_chk_pow2
    $error("sync_fifo: DEPTH must be a power of two, got %0d", DEPTH);
  end

  logic [DW-1:0] mem [0:DEPTH-1];
  logic [AW:0]   wr_ptr, rd_ptr;      // one extra bit for full/empty
  logic          do_wr, do_rd;

  assign do_wr = wr_en && !full;
  assign do_rd = rd_en && !empty;

  assign empty = (wr_ptr == rd_ptr);
  assign full  = (wr_ptr[AW] != rd_ptr[AW]) &&
                 (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
  assign level = wr_ptr - rd_ptr;

  assign almost_full  = (level >= (AW+1)'(DEPTH - 1));
  assign almost_empty = (level <= (AW+1)'(1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (do_wr) wr_ptr <= wr_ptr + 1'b1;
      if (do_rd) rd_ptr <= rd_ptr + 1'b1;
    end
  end

  // Write port. No reset on the memory -- RAMs do not have one.
  always_ff @(posedge clk) begin
    if (do_wr) mem[wr_ptr[AW-1:0]] <= wr_data;
  end

  if (FWFT) begin : g_fwft
    // First-word fall-through: rd_data is valid whenever !empty, and rd_en
    // ACKNOWLEDGES the current word. Combinational read -> distributed RAM
    // on an FPGA, or a registered-output RAM plus a bypass on an ASIC.
    assign rd_data = mem[rd_ptr[AW-1:0]];
  end else begin : g_std
    // Standard mode: rd_data appears one cycle after rd_en.
    always_ff @(posedge clk) begin
      if (do_rd) rd_data <= mem[rd_ptr[AW-1:0]];
    end
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Formal properties. These live inside the module because they need `mem` and
  // `rd_ptr`, and Yosys's formal flow cannot read a hierarchical reference into
  // a submodule (see docs/25). The harness in formal/ only drives the inputs.
  //
  // Sequence numbering again: constrain wr_data to be its own sequence number,
  // then the output stream must count up with no gaps -- which proves no loss,
  // no duplication and no reordering in one assertion.
  // ---------------------------------------------------------------------------
  logic [DW-1:0] fv_in_seq  = '0;
  logic [DW-1:0] fv_out_seq = '0;

  always @* assume (wr_data == fv_in_seq);

  always @(posedge clk) begin
    if (!rst_n) begin
      fv_in_seq  <= '0;
      fv_out_seq <= '0;
    end else begin
      if (do_wr) fv_in_seq  <= fv_in_seq  + 1'b1;
      if (do_rd) fv_out_seq <= fv_out_seq + 1'b1;
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      // The flag/level decode, proved against the sequence counters rather
      // than restated from the pointers.
      f_level : assert (level == (AW+1)'(fv_in_seq - fv_out_seq));
      f_full  : assert (full  == (level == (AW+1)'(DEPTH)));
      f_empty : assert (empty == (level == '0));
      f_bound : assert (level <= (AW+1)'(DEPTH));

      // First-word fall-through presents the oldest beat whenever non-empty.
      if (FWFT) f_stream : assert (empty || (rd_data == fv_out_seq));

      // ---- the invariant that closes the induction ------------------------
      // Every occupied slot holds the beat its position implies. Without this,
      // the induction step is free to invent memory contents. Expressing it
      // needs a loop over DEPTH, which is why the formal instance is kept
      // small -- the proof cost grows with DEPTH, the confidence does not.
    end
  end

  // ---- the memory-contents invariant ---------------------------------------
  // Every occupied slot holds the beat its position implies. This is what lets
  // the induction step close: without it, the solver may begin from a state
  // with arbitrary memory contents and "prove" a corruption that no real
  // execution could reach.
  //
  // A GENERATE loop, not a `for` inside the always block: each iteration then
  // gets its own scope, so the assertions have distinct names and all DEPTH of
  // them actually exist. A plain `for` with a labelled assert is rejected for a
  // duplicate cell name, and unlabelled it does not produce DEPTH separate
  // properties.
  for (genvar k = 0; k < int'(DEPTH); k++) begin : g_fv_mem
    always @(posedge clk)
      if (rst_n && ((AW+1)'(k) < level))
        assert (mem[AW'(rd_ptr[AW-1:0] + AW'(k))] == (fv_out_seq + DW'(k)));
  end

  always @(posedge clk) begin
    f_c_full  : cover (rst_n && full);
    f_c_empty : cover (rst_n && empty && fv_in_seq != '0);
    f_c_b2b   : cover (rst_n && do_wr && do_rd);
  end
`endif

`ifndef SYNTHESIS
  a_no_overflow:  assert property (@(posedge clk) disable iff (!rst_n)
                                   full |-> !wr_en)
    else $error("sync_fifo: write while full");
  a_no_underflow: assert property (@(posedge clk) disable iff (!rst_n)
                                   empty |-> !rd_en)
    else $error("sync_fifo: read while empty");
  a_level_bound:  assert property (@(posedge clk) disable iff (!rst_n)
                                   level <= (AW+1)'(DEPTH));
  a_full_iff:     assert property (@(posedge clk) disable iff (!rst_n)
                                   full == (level == (AW+1)'(DEPTH)));
`endif

endmodule

`default_nettype wire
