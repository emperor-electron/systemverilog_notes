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

`ifndef SYNTHESIS
  // AXI-Stream rule: valid must not be withdrawn before ready is seen.
  a_out_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (out_valid && !out_ready) |=> (out_valid && $stable(out_data)))
    else $error("skid_buffer: output payload changed before handshake");

  a_no_drop: assert property (@(posedge clk) disable iff (!rst_n)
    (in_valid && !in_ready) |=> in_valid)
    else $error("skid_buffer: upstream dropped valid (protocol violation)");
`endif

endmodule

`default_nettype wire
