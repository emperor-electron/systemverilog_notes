// -----------------------------------------------------------------------------
// fp_tb.sv -- self-checking testbench for fp_add and fp_mul, using the host
// FPU (via `shortreal`) as the golden reference.
//
// This is the strategy described in docs/19 section 16:
//
//   1. Directed corner cases -- every pair of interesting special values.
//   2. Uniform random, to catch gross errors.
//   3. Random with CLOSE exponents. Uniform random 32-bit patterns almost never
//      produce two operands within a few exponents of each other, so they
//      almost never exercise the close path or massive cancellation -- exactly
//      where the bugs live. This has to be constrained explicitly.
//   4. Exact-cancellation cases (a - a, a - (a^1), ...).
//   5. Subnormal-heavy cases.
//
// LIMITS OF THIS REFERENCE:
//   * `shortreal` arithmetic uses the host FPU, which is always
//     round-to-nearest-even. It can therefore only validate the RNE path. The
//     other four rounding modes need a DPI-C reference with fesetround(), or
//     Berkeley TestFloat.
//   * NaN payloads are permitted to differ between implementations, so NaN
//     results are compared by class rather than by bit pattern.
//
// Run it:  make fp
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module fp_tb;
  import fp_pkg::*;

  localparam int NRAND = 20000;

  logic [31:0] a, b;
  logic        sub;
  rnd_e        rm;

  logic [31:0] add_y, mul_y;
  flags_t      add_f, mul_f;

  int n_add = 0, n_mul = 0, e_add = 0, e_mul = 0;

  fp_add #(.E(8), .M(23)) u_add (
    .a(a), .b(b), .sub(sub), .rm(rm), .y(add_y), .flags(add_f));

  fp_mul #(.E(8), .M(23)) u_mul (
    .a(a), .b(b), .rm(rm), .y(mul_y), .flags(mul_f));

  // ---- helpers --------------------------------------------------------------
  function automatic bit is_nan(input logic [31:0] v);
    return (&v[30:23]) && (|v[22:0]);
  endfunction

  function automatic logic [31:0] make(input bit s, input logic [7:0] e,
                                       input logic [22:0] m);
    return {s, e, m};
  endfunction

  // ---- checkers -------------------------------------------------------------
  task automatic chk_add(input logic [31:0] av, bv, input logic sv);
    shortreal ra, rb, rr;
    logic [31:0] ref_y;
    a = av; b = bv; sub = sv;
    #1;
    ra    = $bitstoshortreal(av);
    rb    = $bitstoshortreal(bv);
    rr    = sv ? (ra - rb) : (ra + rb);
    ref_y = $shortrealtobits(rr);
    n_add++;
    // Both NaN is a pass: the payload is implementation-defined.
    if (is_nan(ref_y) && is_nan(add_y)) return;
    if (add_y !== ref_y) begin
      e_add++;
      if (e_add <= 20)
        $display("  ADD FAIL a=%h b=%h sub=%b  dut=%h ref=%h   (%g %s %g)",
                 av, bv, sv, add_y, ref_y, ra, sv ? "-" : "+", rb);
    end
  endtask

  task automatic chk_mul(input logic [31:0] av, bv);
    shortreal ra, rb, rr;
    logic [31:0] ref_y;
    a = av; b = bv; sub = 1'b0;
    #1;
    ra    = $bitstoshortreal(av);
    rb    = $bitstoshortreal(bv);
    rr    = ra * rb;
    ref_y = $shortrealtobits(rr);
    n_mul++;
    if (is_nan(ref_y) && is_nan(mul_y)) return;
    if (mul_y !== ref_y) begin
      e_mul++;
      if (e_mul <= 20)
        $display("  MUL FAIL a=%h b=%h  dut=%h ref=%h   (%g * %g)",
                 av, bv, mul_y, ref_y, ra, rb);
    end
  endtask

  task automatic chk_both(input logic [31:0] av, bv);
    chk_add(av, bv, 1'b0);
    chk_add(av, bv, 1'b1);
    chk_mul(av, bv);
  endtask

  // ---- stimulus phases ------------------------------------------------------
  // 1. Directed: every pair of interesting special values.
  task automatic phase_directed();
    logic [31:0] sp [0:15];
    sp[0]  = 32'h0000_0000;   // +0
    sp[1]  = 32'h8000_0000;   // -0
    sp[2]  = 32'h0000_0001;   // +smallest subnormal
    sp[3]  = 32'h8000_0001;   // -smallest subnormal
    sp[4]  = 32'h007F_FFFF;   // +largest subnormal
    sp[5]  = 32'h0080_0000;   // +smallest normal
    sp[6]  = 32'h3F80_0000;   // +1.0
    sp[7]  = 32'hBF80_0000;   // -1.0
    sp[8]  = 32'h7F7F_FFFF;   // +largest finite
    sp[9]  = 32'hFF7F_FFFF;   // -largest finite
    sp[10] = 32'h7F80_0000;   // +inf
    sp[11] = 32'hFF80_0000;   // -inf
    sp[12] = 32'h7FC0_0000;   // qNaN
    sp[13] = 32'h7F80_0001;   // sNaN
    sp[14] = 32'h4000_0000;   // +2.0
    sp[15] = 32'h3DCC_CCCD;   // +0.1 (inexact)

    $display("[1] directed special-value pairs");
    for (int i = 0; i < 16; i++)
      for (int j = 0; j < 16; j++)
        chk_both(sp[i], sp[j]);
  endtask

  // 2. Uniform random over the whole 32-bit space.
  task automatic phase_uniform();
    $display("[2] uniform random");
    for (int i = 0; i < NRAND; i++)
      chk_both($urandom(), $urandom());
  endtask

  // 3. CLOSE exponents -- the close path and cancellation.
  task automatic phase_close_exponents();
    logic [31:0] x, z;
    logic [7:0]  ex, ez;
    int          d;
    $display("[3] random with close exponents (close path, cancellation)");
    for (int i = 0; i < NRAND; i++) begin
      ex = 8'($urandom_range(200, 60));
      d  = $urandom_range(2, 0);
      ez = ($urandom_range(1,0) != 0) ? (ex + 8'(d)) : (ex - 8'(d));
      x  = make($urandom_range(1,0) != 0, ex, 23'($urandom()));
      z  = make($urandom_range(1,0) != 0, ez, 23'($urandom()));
      chk_both(x, z);
    end
  endtask

  // 4. Exact and near-exact cancellation.
  task automatic phase_cancellation();
    logic [31:0] x;
    $display("[4] exact and near-exact cancellation");
    for (int i = 0; i < NRAND; i++) begin
      x = make($urandom_range(1,0) != 0, 8'($urandom_range(220, 40)),
               23'($urandom()));
      chk_add(x, x,              1'b1);   // a - a          -> +0
      chk_add(x, x ^ 32'h1,      1'b1);   // 1 ulp apart
      chk_add(x, x ^ 32'h3,      1'b1);
      chk_add(x, x ^ 32'h8000_0000, 1'b0);// a + (-a)       -> +0
    end
  endtask

  // 5. Subnormal-heavy.
  task automatic phase_subnormal();
    logic [31:0] x, z;
    $display("[5] subnormal-heavy");
    for (int i = 0; i < NRAND; i++) begin
      x = make($urandom_range(1,0) != 0, 8'd0,              23'($urandom()));
      z = make($urandom_range(1,0) != 0, 8'($urandom_range(2,0)), 23'($urandom()));
      chk_both(x, z);
      chk_both(x, make(1'b0, 8'd126, 23'($urandom())));   // subnormal +- ~0.5
    end
  endtask

  // 6. Overflow / underflow boundaries.
  task automatic phase_boundaries();
    logic [31:0] big, tiny;
    $display("[6] overflow and underflow boundaries");
    for (int i = 0; i < NRAND/4; i++) begin
      big  = make($urandom_range(1,0) != 0, 8'($urandom_range(254, 250)),
                  23'($urandom()));
      tiny = make($urandom_range(1,0) != 0, 8'($urandom_range(5, 1)),
                  23'($urandom()));
      chk_both(big,  big);      // multiply overflows, add may
      chk_both(tiny, tiny);     // multiply underflows into subnormal/zero
      chk_both(big,  tiny);
    end
  endtask

  initial begin
    rm = RNE;   // the only mode the host-FPU reference can validate

    phase_directed();
    phase_uniform();
    phase_close_exponents();
    phase_cancellation();
    phase_subnormal();
    phase_boundaries();

    $display("");
    $display("fp_add: %0d vectors, %0d mismatches", n_add, e_add);
    $display("fp_mul: %0d vectors, %0d mismatches", n_mul, e_mul);
    if (e_add == 0 && e_mul == 0) begin
      $display("fp_tb: PASS (round-to-nearest-even path only)");
    end else begin
      $display("fp_tb: FAIL");
      $fatal(1, "floating-point mismatch");
    end
    $finish;
  end

endmodule
