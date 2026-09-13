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
