// -----------------------------------------------------------------------------
// div_restoring.sv -- multi-cycle restoring divider (unsigned).
//
// `a / b` in RTL infers a full combinational divider: enormous, and with a
// critical path that will not close. Division by a constant power of two is
// free (wiring); everything else should be an explicit multi-cycle unit like
// this one, or a reciprocal-and-multiply.
//
// Restoring division is the shift-subtract algorithm you did by hand:
//
//   rem = 0; quo = dividend
//   repeat W times:
//     {rem, quo} <<= 1              -- bring down the next dividend bit
//     if (rem >= divisor) then      -- does the divisor go in?
//        rem -= divisor;  quo[0] = 1
//
// One subtract-and-compare per cycle, W cycles total. The comparison and the
// subtraction share one adder: compute rem - divisor and look at the borrow.
//
// See docs/17 (division semantics) and docs/18 (fixed-point division).
// -----------------------------------------------------------------------------
`default_nettype none

module div_restoring #(
  parameter int unsigned W = 32
) (
  input  var logic         clk,
  input  var logic         rst_n,

  input  var logic         valid_i,      // start a division
  output var logic         ready_o,      // unit is idle
  input  var logic [W-1:0] dividend,
  input  var logic [W-1:0] divisor,

  output var logic         valid_o,      // result available (one cycle pulse)
  input  var logic         ready_i,
  output var logic [W-1:0] quotient,
  output var logic [W-1:0] remainder,
  output var logic         div_by_zero
);

  localparam int unsigned CW = $clog2(W) + 1;

  typedef enum logic [1:0] { D_IDLE, D_RUN, D_DONE } st_e;

  st_e             st;
  logic [W-1:0]    quo, rem, dvsr;
  logic [CW-1:0]   cnt;
  logic [W:0]      shifted;     // {rem, quo} shifted left by one, top W+1 bits
  logic [W:0]      diff;
  logic            fits;

  // One cycle of the algorithm, shared between the compare and the subtract.
  assign shifted = {rem, quo[W-1]};              // rem<<1 | next dividend bit
  assign diff    = shifted - {1'b0, dvsr};
  assign fits    = !diff[W];                     // no borrow => divisor fits

  assign ready_o = (st == D_IDLE);
  assign valid_o = (st == D_DONE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= D_IDLE;
      quo         <= '0;
      rem         <= '0;
      dvsr        <= '0;
      cnt         <= '0;
      quotient    <= '0;
      remainder   <= '0;
      div_by_zero <= 1'b0;
    end else begin
      unique case (st)
        D_IDLE: begin
          if (valid_i) begin
            quo         <= dividend;
            rem         <= '0;
            dvsr        <= divisor;
            cnt         <= '0;
            div_by_zero <= (divisor == '0);
            st          <= D_RUN;
          end
        end

        D_RUN: begin
          // Shift the quotient left, inserting the result bit at the bottom.
          quo <= {quo[W-2:0], fits};
          rem <= fits ? diff[W-1:0] : shifted[W-1:0];
          cnt <= cnt + 1'b1;
          if (cnt == CW'(W - 1)) begin
            st <= D_DONE;
            // Publish the result on the SAME edge that raises valid_o. Writing
            // these inside D_DONE instead would put valid_o one cycle ahead of
            // the data -- a classic off-by-one in a handshake.
            //
            // Division by zero needs no special case: with dvsr == 0 the
            // subtraction never borrows, so `fits` is 1 every cycle and the
            // quotient fills with ones while the remainder ends up holding the
            // dividend. That is exactly the RISC-V convention.
            quotient  <= {quo[W-2:0], fits};
            remainder <= fits ? diff[W-1:0] : shifted[W-1:0];
          end
        end

        D_DONE: begin
          if (ready_i) st <= D_IDLE;
        end

        default: st <= D_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  a_ready_excl: assert property (@(posedge clk) disable iff (!rst_n)
                                 !(ready_o && valid_o));
`endif

endmodule


// -----------------------------------------------------------------------------
// Signed wrapper.
//
// SystemVerilog signed division TRUNCATES TOWARD ZERO (-7/2 == -3), and the
// remainder takes the sign of the DIVIDEND (-7%2 == -1). That is the C
// convention, and it is NOT what an arithmetic right shift gives you
// (-7>>>1 == -4, which floors). So: divide magnitudes, then apply signs.
//
// The most-negative input is the usual asymmetry trap: abs(-2^(W-1)) does not
// fit in W signed bits. Computing the magnitude in UNSIGNED arithmetic makes
// it work, because 2^(W-1) is representable there.
// -----------------------------------------------------------------------------

`default_nettype wire
