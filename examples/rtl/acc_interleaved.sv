// -----------------------------------------------------------------------------
// acc_interleaved.sv -- break an accumulator's feedback loop by interleaving.
//
// THE PROBLEM
//   `acc <= acc + din` is a LOOP. Pipelining works by cutting a path with
//   registers, but you cannot cut a loop: whatever you insert, the result is
//   still needed one cycle later. Adding a pipeline register just makes the
//   accumulator wrong.
//
// THE TRICK
//   Keep LANES separate partial sums and rotate between them. Lane k is only
//   touched every LANES cycles, so the round trip lane -> adder -> lane now has
//   LANES cycles to complete, and PIPE-1 registers can be dropped into it. At
//   the end, add the partial sums together once.
//
//   This is the same idea as C-slowing a design, and it is why a tensor-core
//   MAC array or an FFT butterfly can accumulate at full rate with a deeply
//   pipelined adder. It costs LANES-1 extra accumulator registers and one
//   final reduction; it buys an arbitrarily deep adder.
//
// CONSTRAINT
//   LANES >= PIPE. A read of lane k at cycle t is written back at t+PIPE, and
//   the next read of lane k is at t+LANES.
//
// Addition is associative and commutative, so splitting the sum across lanes
// and recombining is exact -- for INTEGER and fixed-point operands. It is NOT
// exact for floating point, where a different summation order gives a
// different (usually better) rounding. See docs/19.
//
// See docs/21-pipelining.md.
// -----------------------------------------------------------------------------
`default_nettype none

module acc_interleaved #(
  parameter int unsigned DW    = 18,      // operand width
  parameter int unsigned ACCW  = 48,      // accumulator width
  parameter int unsigned LANES = 4,       // partial sums
  parameter int unsigned PIPE  = 2        // adder latency, 1..LANES
) (
  input  var logic                   clk,
  input  var logic                   rst_n,
  input  var logic                   clear,     // zero every lane
  input  var logic                   valid,
  input  var logic signed [DW-1:0]   din,
  output var logic signed [ACCW-1:0] total,     // sum of all lanes
  output var logic                   busy       // adds still in flight
);

  localparam int unsigned SELW  = (LANES <= 1) ? 1 : $clog2(LANES);
  localparam int unsigned EXTRA = PIPE - 1;      // registers before writeback

  if (PIPE < 1 || PIPE > LANES) begin : g_chk
    $error("acc_interleaved: need 1 <= PIPE (%0d) <= LANES (%0d)", PIPE, LANES);
  end

  logic signed [ACCW-1:0] lane [0:LANES-1];
  logic [SELW-1:0]        sel;

  // ---- issue: read the selected lane and start the add ----------------------
  logic signed [ACCW-1:0] sum_issue;
  assign sum_issue = lane[sel] + ACCW'(din);     // din is signed -> sign-extends

  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n) sel <= '0;
    else if (clear)  sel <= '0;
    else if (valid)  sel <= (sel == SELW'(LANES-1)) ? '0 : (sel + 1'b1);
  end

  // ---- the adder pipeline ---------------------------------------------------
  // EXTRA delay registers, then the lane register itself is the final stage.
  // A retiming-capable synthesis tool will redistribute the actual adder logic
  // across these registers; the RTL only has to provide somewhere to put it.
  logic signed [ACCW-1:0] wb_data;
  logic [SELW-1:0]        wb_sel;
  logic                   wb_valid;

  if (EXTRA == 0) begin : g_direct
    assign wb_data  = sum_issue;
    assign wb_sel   = sel;
    assign wb_valid = valid;
  end else begin : g_pipe
    logic signed [ACCW-1:0] p_data [0:EXTRA-1];
    logic [SELW-1:0]        p_sel  [0:EXTRA-1];
    logic [EXTRA-1:0]       p_val;

    for (genvar i = 0; i < int'(EXTRA); i++) begin : g_stage
      logic signed [ACCW-1:0] prev_data;
      logic [SELW-1:0]        prev_sel;

      // A generate-if, not a ternary: `p_data[i-1]` with i == 0 would be an
      // out-of-range index, and a ternary elaborates BOTH arms.
      if (i == 0) begin : g_head
        assign prev_data = sum_issue;
        assign prev_sel  = sel;
      end else begin : g_body
        assign prev_data = p_data[i-1];
        assign prev_sel  = p_sel[i-1];
      end

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          p_data[i] <= '0;
          p_sel[i]  <= '0;
        end else begin
          p_data[i] <= prev_data;
          p_sel[i]  <= prev_sel;
        end
      end
    end

    always_ff @(posedge clk or negedge rst_n) begin
      if      (!rst_n) p_val <= '0;
      else if (clear)  p_val <= '0;
      // EXTRA'({p_val, valid}) is a left shift that also works when EXTRA == 1:
      // the size cast keeps the LOW bits, dropping p_val's MSB. Writing it as
      // {p_val[EXTRA-2:0], valid} would form the illegal range [-1:0].
      else             p_val <= EXTRA'({p_val, valid});
    end

    assign wb_data  = p_data[EXTRA-1];
    assign wb_sel   = p_sel [EXTRA-1];
    assign wb_valid = p_val [EXTRA-1];
  end

  // ---- writeback ------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < int'(LANES); i++) lane[i] <= '0;
    end else if (clear) begin
      for (int i = 0; i < int'(LANES); i++) lane[i] <= '0;
    end else if (wb_valid) begin
      lane[wb_sel] <= wb_data;
    end
  end

  assign busy = (EXTRA != 0) && wb_valid;

  // ---- final reduction ------------------------------------------------------
  // Read rarely, so an unpipelined tree is fine here. If the running total is
  // needed every cycle, pipeline this with adder_tree #(.PIPE(1)).
  always_comb begin
    total = '0;
    for (int i = 0; i < int'(LANES); i++) total = total + lane[i];
  end

endmodule

`default_nettype wire
