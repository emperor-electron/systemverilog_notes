// -----------------------------------------------------------------------------
// ring_counter_fv.sv -- the base case that the module's induction step needs.
//
// ring_counter.sv proves that one-hot is PRESERVED (inductive). This harness
// proves it actually HOLDS, from the real reset state, with BMC -- the base case.
// Preservation plus base case is one-hot for every reachable state, which is the
// property the design actually promises.
//
// Keeping the two apart is not pedantry: asserting `$onehot(q)` unconditionally
// inside the module makes `prove` fail, because induction starts from arbitrary
// states and a self-correcting counter is specifically built to tolerate those.
// -----------------------------------------------------------------------------
`default_nettype none

module ring_counter_fv #(
  parameter int unsigned N = 6
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic en
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic [N-1:0] q;
  ring_counter #(.N(N), .SELF_CORRECT(1'b1)) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .q(q));

  always @(posedge clk)
    if (rst_n) f_onehot_reachable : assert ($onehot(q));

  always @(posedge clk) begin
    f_c_walk : cover (rst_n && q[N-1]);
    f_c_wrap : cover (rst_n && q[0] && !init);
  end

endmodule

`default_nettype wire
