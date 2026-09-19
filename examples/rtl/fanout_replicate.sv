// -----------------------------------------------------------------------------
// fanout_replicate.sv -- register replication for a high-fanout control signal.
//
// THE PROBLEM
//   A single flop driving 2000 loads scattered across the die cannot meet
//   timing. The delay is not in the logic -- there is none -- it is in the
//   buffer tree and the wire. Synthesis can insert buffers, but a buffer tree
//   deep enough to drive 2000 loads costs several hundred picoseconds, and
//   every one of those loads is somewhere different.
//
//   This is the most common "there is no logic on this path and it still fails"
//   timing violation, and it shows up on exactly the signals you least suspect:
//   a global enable, a mode bit, a reset, an FSM state bit feeding every lane.
//
// THE FIX
//   Give each region its own copy of the flop, driven from the same input. Now
//   each copy drives 1/N of the loads and can be placed next to them. Cost: N-1
//   flops, which is nothing next to the datapath they control.
//
//   The catch is that synthesis will happily UNDO this -- a set of flops with
//   identical inputs is exactly what its resource-sharing pass merges. The
//   `dont_touch` / `preserve` attributes below are what stop it, and they are
//   tool-specific. Without them this module is an expensive no-op.
//
//   Most tools can also do this automatically, given a fanout limit
//   (`set_max_fanout`, or `-retime`/`register_replication` settings). Reach for
//   the automatic path first; use this when the tool needs to be told, or when
//   you want the copies tied to a known floorplan region.
//
// See docs/22-timing-closure-and-optimization.md.
// -----------------------------------------------------------------------------
`default_nettype none

module fanout_replicate #(
  parameter int unsigned WIDTH   = 1,     // signal width
  parameter int unsigned COPIES  = 4      // one per destination region
) (
  input  var logic                    clk,
  input  var logic                    rst_n,
  input  var logic                    en,
  input  var logic [WIDTH-1:0]        din,
  // Copy k drives region k. Consumers must use their OWN copy -- using
  // dout[0] everywhere reintroduces the fanout problem and wastes the flops.
  output var logic [COPIES-1:0][WIDTH-1:0] dout
);

  for (genvar c = 0; c < int'(COPIES); c++) begin : g_copy
    // Attributes are tool-specific and deliberately redundant here so the file
    // works across flows. Unknown attributes are ignored, not an error.
    (* dont_touch = "true" *)               // Synopsys, Vivado
    (* preserve *)                          // Intel Quartus
    (* syn_preserve = "1" *)                // Synplify
    (* keep = "true" *)                     // Vivado (also blocks merging)
    logic [WIDTH-1:0] rep_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if      (!rst_n) rep_q <= '0;
      else if (en)     rep_q <= din;
    end

    assign dout[c] = rep_q;
  end

endmodule

`default_nettype wire
