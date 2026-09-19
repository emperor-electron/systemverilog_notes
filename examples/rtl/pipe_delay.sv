// -----------------------------------------------------------------------------
// pipe_delay.sv -- parameterized N-cycle delay line for latency matching.
//
// The most-used block in any pipelined design, and the source of most pipeline
// bugs when it is missing. When you add a pipeline stage to a datapath, EVERY
// signal that travels alongside it -- valid, tags, byte enables, the sideband
// you forgot about -- has to be delayed by the same amount. Doing that with a
// hand-written chain of registers per signal is how stages drift apart.
//
// LATENCY == 0 is a legal, useful configuration: it degenerates to a wire, so a
// caller can parameterize the depth down to nothing without special-casing.
//
// `en` is a pipeline-wide clock enable (a stall). Note that the whole line
// stalls together -- that is the point. A per-stage enable would let stages
// slip relative to each other, which is exactly the bug this block prevents.
//
// See docs/21-pipelining.md.
// -----------------------------------------------------------------------------
`default_nettype none

module pipe_delay #(
  parameter int unsigned WIDTH   = 32,
  parameter int unsigned LATENCY = 1,
  parameter bit          RESET   = 1'b1,      // 0 => no reset (smaller flops)
  parameter logic [WIDTH-1:0] RST_VAL = '0
) (
  input  var logic             clk,
  input  var logic             rst_n,
  input  var logic             en,
  input  var logic [WIDTH-1:0] din,
  output var logic [WIDTH-1:0] dout
);

  if (LATENCY == 0) begin : g_passthrough
    // Not a degenerate case to be tolerated -- a deliberate one. It lets a
    // parent sweep LATENCY from 0 upward without conditional instantiation.
    assign dout = din;

  end else begin : g_pipe
    logic [WIDTH-1:0] stage [0:LATENCY-1];

    for (genvar i = 0; i < int'(LATENCY); i++) begin : g_stage
      logic [WIDTH-1:0] prev;
      if (i == 0) begin : g_head
        assign prev = din;
      end else begin : g_body
        assign prev = stage[i-1];
      end

      if (RESET) begin : g_rst
        always_ff @(posedge clk or negedge rst_n) begin
          if      (!rst_n) stage[i] <= RST_VAL;
          else if (en)     stage[i] <= prev;
        end
      end else begin : g_norst
        // A datapath register usually does not need a reset: the valid flag
        // travelling beside it says whether its contents mean anything. Leaving
        // the reset off shrinks the flop and, more importantly, removes the
        // register from the reset tree -- which on a wide bus is a real saving
        // in both area and reset-net routing. Reset the CONTROL path, not the
        // data path.
        always_ff @(posedge clk) begin
          if (en) stage[i] <= prev;
        end
      end
    end

    assign dout = stage[LATENCY-1];
  end

endmodule

`default_nettype wire
