// -----------------------------------------------------------------------------
// counter.sv -- parameterized up/down counter with load, enable, and wrap flags.
//
// Demonstrates:
//   * the always_comb / always_ff split
//   * default assignment to avoid latches
//   * carry-out done right (the extra bit comes from the concatenation width)
// -----------------------------------------------------------------------------
`default_nettype none

module counter #(
  parameter int unsigned WIDTH = 8,
  parameter logic [WIDTH-1:0] MAX = '1,          // wrap value for counting up
  parameter bit UP_DOWN = 1'b0                   // 1 => `dir` port is honoured
) (
  input  var logic             clk,
  input  var logic             rst_n,
  input  var logic             en,
  input  var logic             dir,              // 1 = down, 0 = up
  input  var logic             load,
  input  var logic [WIDTH-1:0] load_val,
  output var logic [WIDTH-1:0] q,
  output var logic             at_max,
  output var logic             at_min,
  output var logic             wrap              // pulses on the wrapping cycle
);

  logic [WIDTH-1:0] q_d;
  logic             down;
  logic             wrap_d;

  assign down   = UP_DOWN ? dir : 1'b0;
  assign at_max = (q == MAX);
  assign at_min = (q == '0);

  always_comb begin
    q_d    = q;                       // default: hold. No latch, no surprises.
    wrap_d = 1'b0;

    if (load) begin
      q_d = load_val;
    end else if (en) begin
      if (down) begin
        q_d    = at_min ? MAX : (q - 1'b1);
        wrap_d = at_min;
      end else begin
        q_d    = at_max ? '0 : (q + 1'b1);
        wrap_d = at_max;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q    <= '0;
      wrap <= 1'b0;
    end else begin
      q    <= q_d;
      wrap <= wrap_d;
    end
  end

endmodule

`default_nettype wire
