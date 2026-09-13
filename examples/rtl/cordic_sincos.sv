// -----------------------------------------------------------------------------
// cordic_sincos.sv -- CORDIC rotation-mode sine/cosine, fixed point, one iteration
// per pipeline stage.
//
// CORDIC computes trig functions with NO multiplier: each iteration is an add,
// a subtract, and two hard-wired shifts. That makes it the standard choice when
// you need sin/cos/atan/magnitude and multipliers are scarce -- or when you
// need a long, regular, easily-pipelined structure.
//
// The idea: rotate the vector (x, y) by a sequence of ever-smaller fixed angles
// atan(2^-i), choosing the direction of each rotation to drive the residual
// angle z toward zero. A rotation by atan(2^-i) is
//
//     x' = x - d * y * 2^-i
//     y' = y + d * x * 2^-i
//     z' = z - d * atan(2^-i)          d = +/-1
//
// and `* 2^-i` is a shift. Each rotation also scales the vector by
// sqrt(1 + 2^-2i), so the product of all of them is a constant -- the CORDIC
// gain -- which is pre-divided out of the starting x value.
//
// Formats:
//   angle  z : Q3.29 signed  (value = radians * 2^29, range +/-4)
//              Q3.29 rather than Q2.30 because the range must hold pi.
//   x / y    : Q2.30 signed  (value = 1.0 * 2^30, range +/-2)
//
// Convergence range is |z| <= sum(atan(2^-i)) ~= 1.7433 rad, which is slightly
// more than pi/2. The pre-rotation stage folds any angle in [-pi, pi] into
// that range by subtracting pi and negating the result.
//
// The tables below were generated as:
//   atan_tab(i) = round(atan(2^-i) * 2^29)
//   CORDIC_K    = round(prod(1/sqrt(1+2^-2i), i=0..N-1) * 2^30)
//
// See docs/18-fixed-point-arithmetic.md.
// -----------------------------------------------------------------------------
`default_nettype none

module cordic_sincos #(
  parameter int unsigned ITER = 24          // 1..30; ~ITER bits of accuracy
) (
  input  var logic                clk,
  input  var logic                rst_n,
  input  var logic                valid_i,
  input  var logic signed [31:0]  angle,    // Q3.29 radians, |angle| <= pi
  output var logic                valid_o,
  output var logic signed [31:0]  cos_o,    // Q2.30
  output var logic signed [31:0]  sin_o     // Q2.30
);

  localparam int ANGLE_F = 29;
  localparam int XY_F    = 30;

  // The rotation-angle table. A function rather than an unpacked-array
  // parameter: it is more widely supported, and the call folds to a constant at
  // elaboration because the argument is a genvar.
  function automatic logic signed [31:0] atan_tab(input int i);
    case (i)
       0: return 32'sd421657428;   // atan(2^-0) = 0.7853981634 rad
       1: return 32'sd248918915;   // atan(2^-1) = 0.4636476090 rad
       2: return 32'sd131521918;   // atan(2^-2) = 0.2449786631 rad
       3: return 32'sd66762579;    // atan(2^-3) = 0.1243549945 rad
       4: return 32'sd33510843;    // atan(2^-4) = 0.0624188100 rad
       5: return 32'sd16771758;    // atan(2^-5) = 0.0312398334 rad
       6: return 32'sd8387925;     // atan(2^-6) = 0.0156237286 rad
       7: return 32'sd4194219;     // atan(2^-7) = 0.0078123411 rad
       8: return 32'sd2097141;     // atan(2^-8) = 0.0039062301 rad
       9: return 32'sd1048575;     // atan(2^-9) = 0.0019531225 rad
      10: return 32'sd524288;      // atan(2^-10) = 0.0009765622 rad
      11: return 32'sd262144;      // atan(2^-11) = 0.0004882812 rad
      12: return 32'sd131072;      // atan(2^-12) = 0.0002441406 rad
      13: return 32'sd65536;       // atan(2^-13) = 0.0001220703 rad
      14: return 32'sd32768;       // atan(2^-14) = 0.0000610352 rad
      15: return 32'sd16384;       // atan(2^-15) = 0.0000305176 rad
      16: return 32'sd8192;        // atan(2^-16) = 0.0000152588 rad
      17: return 32'sd4096;        // atan(2^-17) = 0.0000076294 rad
      18: return 32'sd2048;        // atan(2^-18) = 0.0000038147 rad
      19: return 32'sd1024;        // atan(2^-19) = 0.0000019073 rad
      20: return 32'sd512;         // atan(2^-20) = 0.0000009537 rad
      21: return 32'sd256;         // atan(2^-21) = 0.0000004768 rad
      22: return 32'sd128;         // atan(2^-22) = 0.0000002384 rad
      23: return 32'sd64;          // atan(2^-23) = 0.0000001192 rad
      24: return 32'sd32;          // atan(2^-24) = 0.0000000596 rad
      25: return 32'sd16;          // atan(2^-25) = 0.0000000298 rad
      26: return 32'sd8;           // atan(2^-26) = 0.0000000149 rad
      27: return 32'sd4;           // atan(2^-27) = 0.0000000075 rad
      28: return 32'sd2;           // atan(2^-28) = 0.0000000037 rad
      29: return 32'sd1;           // atan(2^-29) = 0.0000000019 rad
      default: return 32'sd0;
    endcase
  endfunction


  localparam logic signed [31:0] CORDIC_K = 32'sd652032874;   // 0.6072529350 in Q2.30
  localparam logic signed [31:0] PI_Q     = 32'sd1686629713;  // pi     in Q3.29
  localparam logic signed [31:0] PI_2_Q   = 32'sd843314857; // pi/2   in Q3.29

  if (ITER < 1 || ITER > 30) begin : g_chk
    $error("cordic_sincos: ITER must be in 1..30, got %0d", ITER);
  end

  // ---- stage 0: quadrant pre-rotation --------------------------------------
  // Fold |z| > pi/2 into the convergence range by rotating pi and remembering
  // to negate the result. (Rotating by exactly pi negates both x and y.)
  logic signed [31:0] z0;
  logic               neg0, v0;

  always_comb begin
    if (angle > PI_2_Q) begin
      z0   = angle - PI_Q;
      neg0 = 1'b1;
    end else if (angle < -PI_2_Q) begin
      z0   = angle + PI_Q;
      neg0 = 1'b1;
    end else begin
      z0   = angle;
      neg0 = 1'b0;
    end
  end

  // ---- the iteration pipeline ----------------------------------------------
  logic signed [31:0] x_p [0:ITER];
  logic signed [31:0] y_p [0:ITER];
  logic signed [31:0] z_p [0:ITER];
  logic               n_p [0:ITER];
  logic               v_p [0:ITER];

  assign v0 = valid_i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x_p[0] <= '0;  y_p[0] <= '0;  z_p[0] <= '0;
      n_p[0] <= 1'b0;  v_p[0] <= 1'b0;
    end else begin
      x_p[0] <= CORDIC_K;          // pre-divided by the CORDIC gain
      y_p[0] <= '0;
      z_p[0] <= z0;
      n_p[0] <= neg0;
      v_p[0] <= v0;
    end
  end

  for (genvar i = 0; i < int'(ITER); i++) begin : g_iter
    logic signed [31:0] dx, dy;

    // The shifts are by a CONSTANT i, so they are free: pure wiring.
    // >>> is an arithmetic shift only because x_p/y_p are declared SIGNED.
    assign dx = x_p[i] >>> i;
    assign dy = y_p[i] >>> i;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        x_p[i+1] <= '0;  y_p[i+1] <= '0;  z_p[i+1] <= '0;
        n_p[i+1] <= 1'b0;  v_p[i+1] <= 1'b0;
      end else begin
        if (z_p[i] >= 0) begin           // rotate counter-clockwise
          x_p[i+1] <= x_p[i] - dy;
          y_p[i+1] <= y_p[i] + dx;
          z_p[i+1] <= z_p[i] - atan_tab(i);
        end else begin                   // rotate clockwise
          x_p[i+1] <= x_p[i] + dy;
          y_p[i+1] <= y_p[i] - dx;
          z_p[i+1] <= z_p[i] + atan_tab(i);
        end
        n_p[i+1] <= n_p[i];
        v_p[i+1] <= v_p[i];
      end
    end
  end

  // ---- output: undo the quadrant fold --------------------------------------
  assign valid_o = v_p[ITER];
  assign cos_o   = n_p[ITER] ? -x_p[ITER] : x_p[ITER];
  assign sin_o   = n_p[ITER] ? -y_p[ITER] : y_p[ITER];

endmodule

`default_nettype wire
