// -----------------------------------------------------------------------------
// irq_ctrl.sv -- interrupt controller: latch, mask, prioritise.
//
// Three jobs, and each has a failure mode that only shows up in the field:
//
//   LATCH    A source that pulses for one cycle must not be missed because the
//            CPU happened to be in another handler. `pending` is sticky and is
//            cleared only by software writing a one to it.
//
//   MASK     Masking must hide the interrupt from the CPU WITHOUT discarding
//            it. `pending` is latched regardless of `mask`, so unmasking later
//            delivers the event that arrived while it was masked. A controller
//            that gates the source before the latch silently loses those, and
//            the symptom is a device that stops responding after a driver
//            briefly disables its interrupt.
//
//   PRIORITY Lowest index wins, which is a fixed priority and therefore
//            starves high indices under sustained load. That is the right
//            default for interrupts -- they are a specification, not a
//            fairness problem -- but it is a real property, so see docs/30 on
//            arbitration before wiring anything latency-sensitive to line 7.
//
// EDGE selects how `pending` is set:
//   1  a rising edge of irq_in latches a bit. For pulsed sources.
//   0  the level itself latches a bit while high. For level sources that
//      deassert only once the CPU services the device.
//
// The set-beats-clear rule from csr_bank.sv applies here too and for the same
// reason: an interrupt arriving in the same cycle software clears the flag must
// survive, or it is lost forever.
// -----------------------------------------------------------------------------
`default_nettype none

module irq_ctrl #(
  parameter int unsigned N    = 8,
  parameter bit          EDGE = 1'b1,
  parameter int unsigned IW   = (N <= 1) ? 1 : $clog2(N)
) (
  input  var logic          clk,
  input  var logic          rst_n,

  input  var logic [N-1:0]  irq_in,     // from the peripherals
  input  var logic [N-1:0]  mask,       // 1 = delivered to the CPU
  input  var logic [N-1:0]  clr,        // write-one-to-clear, one cycle

  output var logic [N-1:0]  pending,    // latched, regardless of mask
  output var logic [N-1:0]  active,     // pending AND enabled
  output var logic          irq,        // any active
  output var logic [IW-1:0] id,         // lowest active index
  output var logic          id_valid
);

  logic [N-1:0] irq_q, set;

  // Edge mode needs the previous sample; level mode does not, and the tool
  // removes the register when EDGE is 0 because nothing reads it.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq_q <= '0;
    else        irq_q <= irq_in;
  end

  assign set = EDGE ? (irq_in & ~irq_q) : irq_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pending <= '0;
    else        pending <= (pending & ~clr) | set;   // set wins over clear
  end

  assign active = pending & mask;
  assign irq    = |active;

  priority_encoder #(.N(N), .IW(IW)) u_pri (
    .in(active), .idx(id), .valid(id_valid));

`ifndef SYNTHESIS
  a_set_survives_clear: assert property (@(posedge clk) disable iff (!rst_n)
    (|set) |=> ((pending & $past(set)) == $past(set)))
    else $error("irq_ctrl: an interrupt was lost to a simultaneous clear");

  // Masking hides, it does not discard.
  a_mask_does_not_discard: assert property (@(posedge clk) disable iff (!rst_n)
    (|(set & ~mask)) |=> (|pending))
    else $error("irq_ctrl: a masked interrupt was dropped instead of latched");

  a_irq_matches_active: assert property (@(posedge clk) disable iff (!rst_n)
    irq == (|(pending & mask)));
`endif

endmodule

`default_nettype wire
