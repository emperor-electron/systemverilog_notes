// -----------------------------------------------------------------------------
// arb_fixed_fv.sv -- formal properties for arb_fixed.
//
// A COMBINATIONAL block is the ideal formal target: a bounded model check to
// depth 1 is an EXHAUSTIVE proof over all 2^N input patterns. The simulation
// version of this check in rtl_smoke_tb loops over 256 patterns for N=8; this
// proves it for N=32 (4 billion patterns) in milliseconds.
//
// Note the assertion style. Yosys's open-source frontend does not support SVA
// `assert property` with a clocking event, `|->`, `|=>`, or sequences -- only
// IMMEDIATE assertions, which in a clocked context go inside an always block.
// Temporal relationships are expressed with $past instead. See docs/25.
// -----------------------------------------------------------------------------
`default_nettype none

module arb_fixed_fv #(
  parameter int unsigned N = 8
) (
  input  var logic         clk,
  input  var logic [N-1:0] req
);

  logic [N-1:0] grant;

  arb_fixed #(.N(N)) dut (.req(req), .grant(grant));

  // An independent reference: the lowest set bit, found by explicit search.
  // Deliberately NOT written as req & (~req+1) -- a proof against a restatement
  // of the implementation proves nothing.
  logic [N-1:0] ref_grant;
  integer       i;
  always @* begin
    ref_grant = '0;
    for (i = 0; i < N; i = i + 1)
      if (req[i] && ref_grant == '0) ref_grant[i] = 1'b1;
  end

  always @(posedge clk) begin
    // The functional equivalence -- exhaustive over every input pattern.
    a_equiv    : assert (grant == ref_grant);
    // Structural invariants, which hold independently of the reference.
    a_onehot0  : assert ($onehot0(grant));
    a_subset   : assert ((grant & ~req) == '0);
    a_grant_any: assert ((req == '0) || (grant != '0));
    // Cover: prove the interesting cases are reachable at all.
    c_none     : cover (req == '0);
    c_all      : cover (req == '1);
    c_top_only : cover (grant[N-1]);
  end

endmodule

`default_nettype wire
