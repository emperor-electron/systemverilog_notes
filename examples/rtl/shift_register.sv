// -----------------------------------------------------------------------------
// shift_register.sv -- PISO / SIPO shift register with parallel load.
//
// Demonstrates:
//   * a shift written as a concatenation (the idiomatic form)
//   * a bit-counter sized with $clog2, guarded against DEPTH == 1
// -----------------------------------------------------------------------------
`default_nettype none

module shift_register #(
  parameter int unsigned WIDTH = 8,
  parameter bit          MSB_FIRST = 1'b1
) (
  input  var logic             clk,
  input  var logic             rst_n,
  input  var logic             load,
  input  var logic [WIDTH-1:0] din,      // parallel in
  input  var logic             shift_en,
  input  var logic             sin,      // serial in
  output var logic             sout,     // serial out
  output var logic [WIDTH-1:0] dout,     // parallel out
  output var logic             done      // WIDTH shifts completed since load
);

  localparam int unsigned CW = (WIDTH <= 1) ? 1 : $clog2(WIDTH);

  logic [WIDTH-1:0] sr;
  logic [CW:0]      cnt;

  assign sout = MSB_FIRST ? sr[WIDTH-1] : sr[0];
  assign dout = sr;
  assign done = (cnt == (CW+1)'(WIDTH));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sr  <= '0;
      cnt <= '0;
    end else if (load) begin
      sr  <= din;
      cnt <= '0;
    end else if (shift_en) begin
      // MSB-first shifts left and brings `sin` in at the bottom.
      sr  <= MSB_FIRST ? {sr[WIDTH-2:0], sin} : {sin, sr[WIDTH-1:1]};
      if (!done) cnt <= cnt + 1'b1;
    end
  end

endmodule

`default_nettype wire
