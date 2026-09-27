// -----------------------------------------------------------------------------
// dot_rs_global.sv -- the staged dot product with the simplest possible stall:
// ONE enable, broadcast to every stage.
//
//     en = 1   the whole pipeline advances
//     en = 0   the whole pipeline freezes, including the stages that had no
//              reason to
//
// This is the right answer more often than its reputation suggests. It is two
// modules and no storage: pipe_ctrl.sv tracks the valid bits and the flush,
// dot_rs_dp.sv is the datapath, and every cut in the datapath shares the same
// enable wire. Note what the instantiation says:
//
//     .adv({4{en}})
//
// A GLOBAL STALL IS THE DEGENERATE CASE OF ELASTIC CONTROL -- the case where all
// the per-stage enables happen to be the same signal. That is the whole
// difference between this file and dot_rs_elastic.sv, which drives the same
// datapath from pipe_ripple_ctrl.sv instead.
//
// WHAT IT COSTS
//
//   * `en` fans out to every register in the datapath. At 4 taps that is
//     nothing; on a 512-bit datapath it is a high-fanout net that needs
//     replication and shows up as a hold problem before it shows up as a setup
//     one (docs/22).
//   * Bubbles do not collapse. A gap in the input stays a gap all the way
//     through, because a frozen pipeline freezes the gaps too.
//   * There is no backpressure signal. `en` is an input, so the PRODUCER has to
//     know when the consumer cannot take data -- the knowledge has to get there
//     somehow, and if it arrives as a wire from three modules away, that wire is
//     the design's real timing problem.
//
// WHAT IT BUYS: exact, predictable latency (LATENCY cycles, always), no extra
// flops, no protocol, and a datapath that is trivially retimeable because
// nothing in it depends on data.
//
// THE RULE THAT MAKES IT CORRECT: freeze everything or nothing. Freezing stages
// independently -- "stage 3 is busy so I will hold stage 3" -- duplicates beats
// (stage 4 re-samples a held value) or drops them (stage 2 advances into a frozen
// stage 3). If you want per-stage enables, you want the elastic version, where
// the enables are computed by something that has been proved.
// -----------------------------------------------------------------------------
`default_nettype none

module dot_rs_global #(
  parameter int unsigned TAPS = 4,
  parameter int unsigned XW   = 8,
  parameter int unsigned CW   = 10,
  parameter int unsigned CF   = 8,
  parameter int unsigned YW   = 8,
  parameter logic [3:0]  CUTS = 4'b1111
) (
  input  var logic                clk,
  input  var logic                rst_n,

  input  var logic                en,        // 1 = advance, 0 = stall everything
  input  var logic                flush,     // kill everything in flight

  input  var logic                valid_i,
  input  var logic [TAPS*XW-1:0]  x,
  input  var logic [TAPS*CW-1:0]  c,

  output var logic                valid_o,
  output var logic [YW-1:0]       y,
  output var logic                busy       // anything still in flight?
);

  localparam int unsigned LATENCY = pipe_pkg::cuts_below(CUTS, 4);

  if (LATENCY == 0) begin : g_chk_lat
    $error("dot_rs_global: CUTS must enable at least one cut");
  end

  pipe_ctrl #(.STAGES(LATENCY)) u_ctrl (
    .clk     (clk),
    .rst_n   (rst_n),
    .en      (en),
    .flush   (flush),
    .valid_i (valid_i),
    .valid_o (valid_o),
    .valid_q (),            // the datapath does not need the per-stage bits
    .busy    (busy)
  );

  dot_rs_dp #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW), .CUTS(CUTS)) u_dp (
    .clk   (clk),
    .rst_n (rst_n),
    .adv   ({4{en}}),        // the global stall, in one expression
    .x     (x),
    .c     (c),
    .y     (y)
  );

`ifdef FORMAL
  // The defining property of a global stall, in the only assertion style the
  // Yosys frontend accepts: while `en` is low, nothing observable moves. It is
  // inductive -- it relates this cycle to the last one and needs no history --
  // so `prove` settles it for all time rather than for a bounded window.
  logic fv_past = 1'b0;
  always @(posedge clk) fv_past <= 1'b1;

  always @(posedge clk) begin
    if (rst_n && fv_past && $past(rst_n) && !$past(flush) && !$past(en)) begin
      f_stall_holds_y : assert (y == $past(y));
      f_stall_holds_v : assert (valid_o == $past(valid_o));
    end
  end
`endif

`ifndef SYNTHESIS
  // A stalled pipeline must not move. This is the property that a per-stage
  // enable added "just for this one case" breaks.
  a_stall_holds: assert property (@(posedge clk) disable iff (!rst_n || flush)
    (!en) |=> ($stable(y) && $stable(valid_o)))
    else $error("dot_rs_global: output moved while stalled");

  a_flush_clears: assert property (@(posedge clk) disable iff (!rst_n)
    flush |=> (!valid_o && !busy))
    else $error("dot_rs_global: flush left work in flight");
`endif

endmodule

`default_nettype wire
