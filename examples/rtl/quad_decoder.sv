// -----------------------------------------------------------------------------
// quad_decoder.sv -- quadrature encoder decoder with error detection.
//
// A rotary or linear encoder produces two square waves 90 degrees apart. The
// pair walks a Gray sequence, one bit at a time:
//
//   forward   00 -> 01 -> 11 -> 10 -> 00
//   reverse   00 -> 10 -> 11 -> 01 -> 00
//
// So the decode is a lookup on {previous, current}: exactly one bit changed
// means a step, and which one tells the direction. It is a four-state Gray
// counter read backwards, which is why the same "only one bit changes" property
// that makes Gray code safe for CDC (docs/28) makes quadrature robust here.
//
// TWO BITS CHANGING AT ONCE IS AN ERROR, not a double step. It means either the
// encoder moved faster than this clock can follow, or a bit was corrupted. Some
// decoders quietly count 2; that turns a sampling failure into a permanently
// wrong position, because the error accumulates and nothing ever reports it.
// This one flags `err` and does not move the count -- a position that stops
// tracking is recoverable by homing, one that drifts silently is not.
//
// THE INPUTS MUST BE SYNCHRONIZED AND DEBOUNCED. They come from a mechanical or
// optical device on wires, so they are asynchronous to this clock and may
// bounce. Put a cdc_bit and, for mechanical encoders, a debounce in front.
// Sampling rate must exceed twice the fastest edge rate or steps are simply
// missed -- which `err` will report, since a missed step looks like two bits
// changing.
// -----------------------------------------------------------------------------
`default_nettype none

module quad_decoder #(
  parameter int unsigned CW = 16      // position counter width
) (
  input  var logic           clk,
  input  var logic           rst_n,

  input  var logic           a,        // synchronized, debounced
  input  var logic           b,
  input  var logic           clr,      // zero the position

  output var logic [CW-1:0]  count,
  output var logic           step,     // one cycle per valid step
  output var logic           dir,      // 1 = forward, valid with `step`
  output var logic           err       // one cycle: illegal transition
);

  logic [1:0] q, prev;

  assign q = {a, b};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev  <= 2'b00;
      count <= '0;
      step  <= 1'b0;
      dir   <= 1'b0;
      err   <= 1'b0;
    end else begin
      prev <= q;
      step <= 1'b0;
      err  <= 1'b0;

      if (clr) begin
        count <= '0;
      end else begin
        // {prev, current}. The four forward and four reverse transitions are
        // listed rather than computed, because the table IS the specification
        // and a clever expression hides which direction is which.
        unique case ({prev, q})
          4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: begin
            count <= count + 1'b1;
            step  <= 1'b1;
            dir   <= 1'b1;
          end
          4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: begin
            count <= count - 1'b1;
            step  <= 1'b1;
            dir   <= 1'b0;
          end
          4'b00_00, 4'b01_01, 4'b10_10, 4'b11_11: begin
            // No movement. Much the most common case.
          end
          default: begin
            // Both bits changed: a missed step or a corrupted sample. Report
            // it and leave the count alone.
            err <= 1'b1;
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  a_step_xor_err: assert property (@(posedge clk) disable iff (!rst_n)
    !(step && err))
    else $error("quad_decoder: reported a step and an error together");

  a_err_means_two_bits: assert property (@(posedge clk) disable iff (!rst_n)
    err |-> ($past(prev) != $past(q)) && ($past(prev[0]) != $past(q[0]))
                                      && ($past(prev[1]) != $past(q[1])));
`endif

endmodule

`default_nettype wire
