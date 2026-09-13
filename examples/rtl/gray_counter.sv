// -----------------------------------------------------------------------------
// gray_counter.sv -- Gray-code counter for CDC pointers.
//                population count, and a Gray <-> binary pair.
//
// Each is written the way it reads best; all are pure combinational and unroll
// at elaboration.
// -----------------------------------------------------------------------------
`default_nettype none

// --- Gray-code counter -------------------------------------------------------
// Keeps a binary counter internally and emits the Gray view, which is what you
// want for a CDC pointer: the binary form is easy to compare and increment,
// the Gray form is what crosses the boundary.
module gray_counter #(
  parameter int unsigned W = 8
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         en,
  output var logic [W-1:0] bin,
  output var logic [W-1:0] gray
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bin  <= '0;
      gray <= '0;
    end else if (en) begin
      bin  <= bin + 1'b1;
      gray <= (bin + 1'b1) ^ ((bin + 1'b1) >> 1);
    end
  end

`ifndef SYNTHESIS
  a_onestep: assert property (@(posedge clk) disable iff (!rst_n)
                              $countones(gray ^ $past(gray)) <= 1)
    else $error("gray_counter: more than one bit changed");
`endif
endmodule

`default_nettype wire
