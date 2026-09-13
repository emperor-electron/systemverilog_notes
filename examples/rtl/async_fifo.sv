// -----------------------------------------------------------------------------
// async_fifo.sv -- dual-clock FIFO with Gray-coded pointers.
//
// The CDC problem: the write pointer must be visible in the read domain (to
// compute `empty`) and vice versa. A BINARY pointer cannot cross -- several
// bits change at once on a wrap (e.g. 0111 -> 1000) and the synchronizer would
// latch a mixture, producing a pointer value that was never real.
//
// Gray code fixes this: exactly ONE bit changes per increment, so a
// synchronizer either catches the old value or the new one -- both of which
// are legal pointer values. A stale pointer only ever makes the FIFO look
// MORE full (to the writer) or MORE empty (to the reader), which is the safe
// direction to be wrong in.
//
// `wfull` and `rempty` are REGISTERED, not combinational. That is not a
// pipelining choice -- it breaks what would otherwise be a combinational loop:
//     wbin_next -> wgray_next -> wfull -> wbin_next
// (because the pointer only advances when not full). Registering the flag cuts
// the loop and puts the comparator's delay in its own cycle.
//
// Structure follows Clifford Cummings, SNUG 2002, "Simulation and Synthesis
// Techniques for Asynchronous FIFO Design".
//
// DEPTH must be a power of two and at least 4.
// -----------------------------------------------------------------------------
`default_nettype none

module async_fifo #(
  parameter int unsigned DW     = 32,
  parameter int unsigned DEPTH  = 16,
  parameter int unsigned STAGES = 2
) (
  // write domain
  input  var logic          wclk,
  input  var logic          wrst_n,
  input  var logic          wr_en,
  input  var logic [DW-1:0] wr_data,
  output var logic          wfull,

  // read domain
  input  var logic          rclk,
  input  var logic          rrst_n,
  input  var logic          rd_en,
  output var logic [DW-1:0] rd_data,
  output var logic          rempty
);

  localparam int unsigned AW = $clog2(DEPTH);

  if (DEPTH != (1 << AW)) begin : g_chk_pow2
    $error("async_fifo: DEPTH must be a power of two, got %0d", DEPTH);
  end
  if (DEPTH < 4) begin : g_chk_min
    $error("async_fifo: DEPTH must be >= 4, got %0d", DEPTH);
  end

  logic [DW-1:0] mem [0:DEPTH-1];

  logic [AW:0] wbin, wbin_next, wgray, wgray_next;
  logic [AW:0] rbin, rbin_next, rgray, rgray_next;
  logic [AW:0] wgray_sync, rgray_sync;
  logic        wfull_next, rempty_next;

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    return b ^ (b >> 1);
  endfunction

  // ---- write domain ---------------------------------------------------------
  assign wbin_next  = wbin + (AW+1)'(wr_en && !wfull);
  assign wgray_next = bin2gray(wbin_next);

  // Full when the next write pointer would catch the read pointer from behind
  // after one more wrap: the top TWO Gray bits inverted, the rest equal.
  assign wfull_next = (wgray_next == {~rgray_sync[AW:AW-1], rgray_sync[AW-2:0]});

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin  <= '0;
      wgray <= '0;
      wfull <= 1'b0;
    end else begin
      wbin  <= wbin_next;
      wgray <= wgray_next;
      wfull <= wfull_next;
    end
  end

  // Memory write port. No reset -- RAMs do not have one.
  always_ff @(posedge wclk) begin
    if (wr_en && !wfull) mem[wbin[AW-1:0]] <= wr_data;
  end

  // ---- read domain ----------------------------------------------------------
  assign rbin_next   = rbin + (AW+1)'(rd_en && !rempty);
  assign rgray_next  = bin2gray(rbin_next);
  assign rempty_next = (rgray_next == wgray_sync);

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin   <= '0;
      rgray  <= '0;
      rempty <= 1'b1;                 // empty out of reset
    end else begin
      rbin   <= rbin_next;
      rgray  <= rgray_next;
      rempty <= rempty_next;
    end
  end

  // First-word fall-through: rd_data is valid whenever !rempty.
  assign rd_data = mem[rbin[AW-1:0]];

  // ---- pointer synchronizers ------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic [AW:0] w2r [0:STAGES-1];
  (* ASYNC_REG = "TRUE" *) logic [AW:0] r2w [0:STAGES-1];

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      for (int i = 0; i < STAGES; i++) w2r[i] <= '0;
    end else begin
      w2r[0] <= wgray;
      for (int i = 1; i < STAGES; i++) w2r[i] <= w2r[i-1];
    end
  end
  assign wgray_sync = w2r[STAGES-1];

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      for (int i = 0; i < STAGES; i++) r2w[i] <= '0;
    end else begin
      r2w[0] <= rgray;
      for (int i = 1; i < STAGES; i++) r2w[i] <= r2w[i-1];
    end
  end
  assign rgray_sync = r2w[STAGES-1];

`ifndef SYNTHESIS
  a_no_overflow:  assert property (@(posedge wclk) disable iff (!wrst_n)
                                   wfull |-> !wr_en)
    else $error("async_fifo: write while full");
  a_no_underflow: assert property (@(posedge rclk) disable iff (!rrst_n)
                                   rempty |-> !rd_en)
    else $error("async_fifo: read while empty");
  // The defining property of a Gray pointer: at most one bit changes per step.
  a_wgray_onestep: assert property (@(posedge wclk) disable iff (!wrst_n)
                                    $countones(wgray ^ $past(wgray)) <= 1);
  a_rgray_onestep: assert property (@(posedge rclk) disable iff (!rrst_n)
                                    $countones(rgray ^ $past(rgray)) <= 1);
`endif

endmodule

`default_nettype wire
