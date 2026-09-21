// -----------------------------------------------------------------------------
// gpio.sv -- general-purpose I/O with synchronized inputs and change detection.
//
// The part people get wrong is not the output driver, it is the input path. A
// pad is asynchronous to this clock by definition, so every input bit needs a
// synchronizer before anything reads it -- and reading it in two places without
// one gives two different answers for the same pin in the same cycle.
//
// This module therefore does NOT expose the raw pad. `in_sync` is the only way
// to read a pin, and the edge pulses beside it are derived from the same
// synchronized copy, so software and the interrupt logic can never disagree
// about what the pin did.
//
// OUTPUT ENABLE, NOT A TRISTATE. The pad's `z` belongs in the top level next to
// the actual pin:
//
//     assign pad[i] = pad_oe[i] ? pad_o[i] : 1'bz;
//
// Keeping tristate out of every internal module means the design is synthesizable
// for an FPGA (where the tristate lives in the IOB and nowhere else) and
// simulatable without resolving z on internal nets.
//
// Edge pulses are provided rather than latched flags: feed them to irq_ctrl,
// which already handles latching, masking and priority, instead of duplicating
// that here badly.
// -----------------------------------------------------------------------------
`default_nettype none

module gpio #(
  parameter int unsigned W = 8
) (
  input  var logic         clk,
  input  var logic         rst_n,

  // Register side
  input  var logic [W-1:0] dir,        // 1 = drive the pad
  input  var logic [W-1:0] out,        // value to drive
  output var logic [W-1:0] in_sync,    // synchronized pad value
  output var logic [W-1:0] rise,       // one-cycle pulse per pin
  output var logic [W-1:0] fall,

  // Pad side
  output var logic [W-1:0] pad_o,
  output var logic [W-1:0] pad_oe,
  input  var logic [W-1:0] pad_i
);

  assign pad_o  = out;
  assign pad_oe = dir;

  for (genvar i = 0; i < int'(W); i++) begin : g_bit
    logic s;

    cdc_bit #(.STAGES(2), .INIT(1'b0)) u_sync (
      .dclk(clk), .drst_n(rst_n), .d(pad_i[i]), .q(s));

    edge_detect #(.INIT(1'b0)) u_ed (
      .clk(clk), .rst_n(rst_n), .d(s),
      .rise(rise[i]), .fall(fall[i]), .any());

    assign in_sync[i] = s;
  end

endmodule

`default_nettype wire
