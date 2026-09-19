// -----------------------------------------------------------------------------
// sync_fifo_fv.sv -- formal harness for sync_fifo.
//
// The FIFO does not prevent an overflow; it only reports `full`. Writing while
// full is a contract violation by the ENVIRONMENT, so that is an assumption
// here, not an assertion. Getting this backwards is the most common way a
// formal run produces a meaningless counterexample: the solver simply drives
// the illegal input and reports the resulting corruption as a bug.
// -----------------------------------------------------------------------------
`default_nettype none

module sync_fifo_fv #(
  parameter int unsigned DW    = 4,
  parameter int unsigned DEPTH = 4
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic wr_en,
  input  var logic rd_en
);

  localparam int unsigned AW = $clog2(DEPTH);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic [DW-1:0] wr_data, rd_data;
  logic          full, empty, almost_full, almost_empty;
  logic [AW:0]   level;

  sync_fifo #(.DW(DW), .DEPTH(DEPTH), .FWFT(1'b1)) dut (
    .clk(clk), .rst_n(rst_n),
    .wr_en(wr_en), .wr_data(wr_data), .full(full), .almost_full(almost_full),
    .rd_en(rd_en), .rd_data(rd_data), .empty(empty),
    .almost_empty(almost_empty), .level(level));

  // The environment's half of the contract.
  always @* begin
    if (full)  assume (!wr_en);
    if (empty) assume (!rd_en);
  end

endmodule

`default_nettype wire
