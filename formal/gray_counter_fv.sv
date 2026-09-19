// -----------------------------------------------------------------------------
// gray_counter_fv.sv -- proof of the property an async FIFO depends on.
//
// A Gray-coded pointer is safe to cross a clock domain because exactly ONE bit
// changes per increment: a synchronizer therefore latches either the old value
// or the new one, both of which are legal pointer values. If two bits ever
// changed together, the synchronizer could catch a mixture -- a pointer value
// that was never real -- and the FIFO would corrupt or deadlock.
//
// That is a claim about EVERY increment from EVERY state, including the wrap.
// Simulation can sample it; `prove` mode settles it for all time.
//
// Port-only, so no properties are needed inside the DUT.
// -----------------------------------------------------------------------------
`default_nettype none

module gray_counter_fv #(
  parameter int unsigned W = 5
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic en
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic [W-1:0] bin, gray;

  gray_counter #(.W(W)) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .bin(bin), .gray(gray));

  always @(posedge clk) begin
    if (rst_n) begin
      // The invariant that ties the two outputs together. Stating it is what
      // lets the induction step close: without it the solver may begin with a
      // bin/gray pair that no real execution could produce.
      f_consistent : assert (gray == (bin ^ (bin >> 1)));

      if (past_ok && $past(rst_n)) begin
        // THE defining property: at most one bit changes per cycle.
        f_one_change : assert ($countones(gray ^ $past(gray)) <= 1);
        // And exactly one when enabled -- a counter that does not count is
        // also a bug, and the <= form above would not catch it.
        f_counts     : assert (!$past(en)
                               || ($countones(gray ^ $past(gray)) == 1));
        f_holds      : assert ($past(en) || (gray == $past(gray)));
      end
    end
  end

  always @(posedge clk) begin
    f_c_wrap : cover (rst_n && past_ok && $past(bin) == '1 && bin == '0);
    f_c_run  : cover (rst_n && bin == W'(3));
  end

endmodule

`default_nettype wire
