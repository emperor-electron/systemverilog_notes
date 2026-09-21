// -----------------------------------------------------------------------------
// axil_slave_fv.sv -- the AXI4-Lite obligations, counted rather than inspected.
//
// The register bank is NOT instantiated. `reg_rdata` and `reg_err` are left as
// free inputs, so the proof holds for ANY bank behind this subordinate --
// including ones that return different data every cycle. Instantiating a
// particular bank would prove the pair, which is a weaker and less reusable
// statement.
//
// THE MANAGER'S OBLIGATIONS ARE ASSUMED, not asserted. A subordinate cannot be
// held responsible for a manager that withdraws VALID, and a proof that lets the
// solver do so fails immediately with a counterexample that is not a bug. The
// assumptions below are exactly the rules axil_slave.sv asserts in simulation --
// the same properties, on the other side of the assume/assert line, which is
// the usual way one module's obligation becomes its neighbour's guarantee.
//
// WHAT IS PROVED. The counting itself lives inside axil_slave.sv, because the
// identity that makes it inductive relates the counters to internal state
// (`aw_full`, `w_full`, `ar_full`). Counters declared here instead leave `prove`
// UNKNOWN: induction starts them at arbitrary values unrelated to the DUT, and
// the step case fails on states that cannot occur. Moving them next to the state
// they account for is what closes the proof -- the same lesson as the skid
// buffer's occupancy invariant in docs/25.
//
// What this harness contributes is the environment: the manager's obligations as
// assumptions, this subordinate's own VALID-stability as assertions, and the
// covers that show both channel orderings really are reachable.
// -----------------------------------------------------------------------------
`default_nettype none

module axil_slave_fv #(
  parameter int unsigned AW = 4,
  parameter int unsigned DW = 32
) (
  input  var logic            clk,
  input  var logic            rst_n,
  input  var logic [AW-1:0]   awaddr,
  input  var logic            awvalid,
  input  var logic [DW-1:0]   wdata,
  input  var logic [DW/8-1:0] wstrb,
  input  var logic            wvalid,
  input  var logic            bready,
  input  var logic [AW-1:0]   araddr,
  input  var logic            arvalid,
  input  var logic            rready,
  input  var logic [DW-1:0]   reg_rdata,
  input  var logic            reg_err
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic            awready, wready, arready;
  logic [1:0]      bresp, rresp;
  logic            bvalid, rvalid;
  logic [DW-1:0]   rdata;
  logic [AW-1:0]   reg_addr;
  logic            reg_wen, reg_ren;
  logic [DW-1:0]   reg_wdata;
  logic [DW/8-1:0] reg_wstrb;

  axil_slave #(.AW(AW), .DW(DW)) dut (
    .clk(clk), .rst_n(rst_n),
    .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
    .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .araddr(araddr), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
    .reg_addr(reg_addr), .reg_wen(reg_wen), .reg_wdata(reg_wdata),
    .reg_wstrb(reg_wstrb), .reg_ren(reg_ren),
    .reg_rdata(reg_rdata), .reg_err(reg_err));

  // ---- the manager's side of the contract, assumed ------------------------
  always @(posedge clk) begin
    if (past_ok && rst_n && $past(rst_n)) begin
      if ($past(awvalid) && !$past(awready))
        assume (awvalid && (awaddr == $past(awaddr)));
      if ($past(wvalid) && !$past(wready))
        assume (wvalid && (wdata == $past(wdata)) && (wstrb == $past(wstrb)));
      if ($past(arvalid) && !$past(arready))
        assume (arvalid && (araddr == $past(araddr)));
    end
  end

  // ---- this subordinate's own side of the contract, asserted --------------
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n)) begin
      if ($past(bvalid) && !$past(bready))
        f_bvalid_stable : assert (bvalid && (bresp == $past(bresp)));
      if ($past(rvalid) && !$past(rready))
        f_rvalid_stable : assert (rvalid && (rdata == $past(rdata))
                                         && (rresp == $past(rresp)));
    end

  always @(posedge clk) begin
    f_c_write     : cover (rst_n && bvalid && bready);
    f_c_read      : cover (rst_n && rvalid && rready);
    f_c_w_first   : cover (rst_n && wvalid && wready && !awvalid);
    f_c_aw_first  : cover (rst_n && awvalid && awready && !wvalid);
    f_c_backpress : cover (rst_n && bvalid && !bready);
  end

endmodule

`default_nettype wire
