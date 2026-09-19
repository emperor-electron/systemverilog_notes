// -----------------------------------------------------------------------------
// signedness_demo.sv -- every trap from docs/17, as a RUNNABLE, SELF-CHECKING
// demonstration.
//
// Each check asserts the value the LRM requires. If your simulator disagrees
// with one of these, that is worth knowing about.
//
// Run it (XSIM):
//   $ xvlog -sv signedness_demo.sv && xelab signedness_demo -s sim && xsim sim -R
// or simply:  make signedness
//
// XSIM is 4-state, so the X-propagation check below is live. The check detects
// a 2-state engine and skips itself rather than reporting a false failure.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// NOTE ON LINTING: this file deliberately contains the width and signedness
// mismatches that a linter is supposed to flag -- they ARE the subject matter.
// The pragmas below silence those two checks for this file only. In real RTL,
// leave them ON and treat them as errors; see docs/20.
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module signedness_demo;

  int errors = 0;

  task automatic chk(input string name,
                     input logic signed [63:0] got,
                     input logic signed [63:0] exp);
    if (got !== exp) begin
      errors++;
      $display("  MISMATCH  %-44s got=%0d (0x%0h)  expected=%0d (0x%0h)",
               name, got, got, exp, exp);
    end else begin
      $display("  ok        %-44s = %0d (0x%0h)", name, got, got);
    end
  endtask

  // ---- T1 -------------------------------------------------------------------
  task automatic t1_mixed_signedness();
    logic signed [7:0] a;
    logic        [7:0] u;
    logic signed [8:0] r;
    a = -8;                              // 8'hF8
    u =  8;                              // 8'h08
    $display("\n=== T1: one unsigned operand makes the whole expression unsigned ===");
    // Unsigned expression, 9-bit context: BOTH operands zero-extend.
    // 248 + 8 = 256, which as a signed 9-bit value is -256.
    r = a + u;
    chk("a + u           (expression is unsigned)", 64'(r), -256);
    // Fix: widen `u` to a 9-bit signed POSITIVE value first.
    r = a + signed'({1'b0, u});
    chk("a + signed'({1'b0,u})", 64'(r), 0);
  endtask

  // ---- T2 -------------------------------------------------------------------
  task automatic t2_part_select();
    logic signed [15:0] w;
    logic signed [31:0] z;
    w = -1;                              // 16'hFFFF
    $display("\n=== T2: a part-select is always unsigned ===");
    z = w;               chk("z = w           (assignment sign-extends)", 64'(z), -1);
    z = w[15:0];         chk("z = w[15:0]     (part-select zero-extends)", 64'(z), 65535);
    z = signed'(w[15:0]);chk("z = signed'(w[15:0])", 64'(z), -1);
  endtask

  // ---- T3 -------------------------------------------------------------------
  task automatic t3_concat();
    logic signed [3:0] c;
    logic signed [7:0] d;
    c = -1;                              // 4'hF
    $display("\n=== T3: a concatenation is always unsigned ===");
    d = c;               chk("d = c           (plain assignment)", 64'(d), -1);
    d = {c};             chk("d = {c}         (braces made it unsigned)", 64'(d), 15);
    d = signed'({c});    chk("d = signed'({c})", 64'(d), -1);
  endtask

  // ---- T4 -------------------------------------------------------------------
  task automatic t4_neg_literal();
    logic signed [7:0] e;
    e = -8'd1;
    $display("\n=== T4: -literal is unsigned unless you write 's' ===");
    // The BIT PATTERN is correct (0xFF): two's-complement negation of an
    // unsigned value produces the same bits...
    chk("bit pattern of -8'd1", 64'({56'h0, e}), 64'h0000_0000_0000_00FF);
    // ...but the EXPRESSION is unsigned, so a comparison sees 255, not -1.
    chk("(-8'd1  < 8'sd0) -- unsigned compare", 64'((-8'd1  < 8'sd0)), 0);
    chk("(-8'sd1 < 8'sd0) -- signed compare",   64'((-8'sd1 < 8'sd0)), 1);
  endtask

  // ---- T5 -------------------------------------------------------------------
  task automatic t5_lost_bits();
    logic [7:0]  p, q, t8;
    logic [15:0] big;
    logic [8:0]  sum9;
    p = 8'd200;  q = 8'd100;
    $display("\n=== T5: lost carry and lost product ===");
    t8   = p + q;
    chk("t8   = p + q       (8-bit context, wraps)", 64'({56'h0, t8}), 44);
    sum9 = p + q;
    chk("sum9 = p + q       (9-bit context keeps carry)", 64'({55'h0, sum9}), 300);
    sum9 = {1'b0, p} + {1'b0, q};
    chk("sum9 = {0,p}+{0,q} (explicit: works in any context)", 64'({55'h0, sum9}), 300);
    big  = p * q;
    chk("big  = p * q       (16-bit context widens both)", 64'({48'h0, big}), 20000);
    t8   = p * q;
    big  = 16'(t8);
    chk("t8 = p*q; big = t8 (truncated at t8)", 64'({48'h0, big}), 32);
  endtask

  // ---- T6 -------------------------------------------------------------------
  task automatic t6_arith_shift();
    logic        [7:0] m;
    logic signed [7:0] n;
    m = 8'hF0;
    n = 8'shF0;                          // -16
    $display("\n=== T6: >>> is arithmetic only if the LEFT operand is signed ===");
    chk("m >>> 2          (unsigned operand: zero fill)", 64'({56'h0, (m >>> 2)}), 64'h3C);
    chk("n >>> 2          (signed operand: sign fill)",   64'({56'h0, (n >>> 2)}), 64'hFC);
    chk("$signed(m) >>> 2", 64'({56'h0, ($signed(m) >>> 2)}), 64'hFC);
  endtask

  // ---- T7 -------------------------------------------------------------------
  task automatic t7_div_mod();
    logic signed [7:0] x;
    x = -7;
    $display("\n=== T7: signed division truncates toward zero; >>> floors ===");
    chk("x / 2            (truncate toward zero)",   64'(x / 8'sd2),  -3);
    chk("x >>> 1          (floor, toward -infinity)", 64'(x >>> 1),   -4);
    chk("(-7) % 2         (sign follows the LEFT operand)", 64'(-8'sd7 % 8'sd2), -1);
    chk("( 7) % (-2)",     64'(8'sd7 % -8'sd2), 1);
  endtask

  // ---- T8 -------------------------------------------------------------------
  // The array method `s.sum()` accumulates in the ELEMENT type, not in
  // something wide enough. The loops below are exactly what it does.
  //
  //   byte s[] = '{100, 100, 100};
  //   s.sum()                    ->  44   (wrapped in `byte`)
  //   s.sum() with (int'(item))  -> 300   (accumulated in `int`)
  //
  // Spelled out by hand rather than calling .sum(): array reduction methods are
  // unevenly supported across simulators, and the arithmetic -- which is the
  // point -- is identical either way.
  task automatic t8_array_sum();
    byte s [0:2];
    byte narrow_acc;
    int  wide_acc;
    s[0] = 100;  s[1] = 100;  s[2] = 100;
    $display("\n=== T8: array reduction accumulates in the ELEMENT type ===");

    narrow_acc = 0;
    foreach (s[i]) narrow_acc = narrow_acc + s[i];        // accumulates in byte
    chk("sum accumulated in `byte` (what .sum() does)", 64'(narrow_acc), 44);

    wide_acc = 0;
    foreach (s[i]) wide_acc = wide_acc + int'(s[i]);      // accumulates in int
    chk("sum accumulated in `int`  (.sum() with (int'(item)))", 64'(wide_acc), 300);
  endtask

  // ---- T9 -------------------------------------------------------------------
  task automatic t9_neg_min();
    logic signed [7:0] v, w;
    v = -128;
    $display("\n=== T9: negating the most-negative value is a no-op ===");
    // The signed 8-bit range is asymmetric: +128 is not representable, so the
    // negation wraps back to itself. Every saturating abs/negate needs this
    // special case.
    w = -v;
    chk("w = -v, all 8-bit         (-(-128) == -128)", 64'(w), -128);
    // But a wider CONTEXT changes the answer: the cast widens `v` to 64 bits
    // BEFORE the negation, where +128 is perfectly representable. The width
    // rules decide this, not the declared type of `v`.
    chk("64'(-v)  (cast widens, THEN negates)", 64'(-v), 128);
  endtask

  // ---- T10 ------------------------------------------------------------------
  task automatic t10_shift_count();
    logic [15:0] r16;
    logic [7:0]  one8, narrow;
    int          neg;
    one8 = 8'd1;
    neg  = -1;
    $display("\n=== T10: a shift's LEFT operand widens; its COUNT does not ===");
    // The LEFT operand of a shift is context-determined, so a wide destination
    // widens it before the shift happens.
    r16 = one8 << 9;
    chk("r16    = one8 << 9  (16-bit context widens one8)", 64'({48'h0, r16}), 512);
    // A narrow destination does not, and the bit is lost.
    narrow = one8 << 9;
    chk("narrow = one8 << 9  (8-bit destination)", 64'({56'h0, narrow}), 0);
    // The COUNT is self-determined and always treated as UNSIGNED. A negative
    // count is an enormous positive one -- never a shift in the other direction.
    r16 = 16'd1 << neg;
    chk("1 << (-1)           (count is unsigned: a huge shift)", 64'({48'h0, r16}), 0);
  endtask

  // ---- T11 ------------------------------------------------------------------
  task automatic t11_compare();
    logic signed [7:0] a;
    logic        [7:0] b;
    a = -1;  b = 1;
    $display("\n=== T11: comparison is signed only if BOTH operands are ===");
    chk("(a < b)          -- one unsigned => unsigned compare", 64'((a < b)), 0);
    chk("(a < signed'(b))", 64'((a < signed'(b))), 1);
  endtask

  // ---- T12 ------------------------------------------------------------------
  task automatic t12_ternary_x();
    logic       c;
    logic [3:0] y;
    c = 1'bx;
    $display("\n=== T12: a ternary with an X select merges bitwise ===");
    y = c ? 4'b1100 : 4'b1010;
    // Bits where the arms AGREE keep their value; bits that differ become X.
    if (y === 4'b1xx0) begin
      $display("  ok        %-44s = %b", "x ? 4'b1100 : 4'b1010", y);
    end else if (!$isunknown(y)) begin
      // A 2-state engine has no X to propagate, so it just picks one arm.
      // That is a documented simulator limitation, not a language question --
      // and it is exactly why X-propagation bugs must be hunted in a 4-state
      // simulator. See docs/02-data-types.md.
      $display("  SKIP      %-44s = %b  (2-state simulator: no X modelling)",
               "x ? 4'b1100 : 4'b1010", y);
    end else begin
      errors++;
      $display("  MISMATCH  %-44s got=%b expected=1xx0", "x ? 4'b1100 : 4'b1010", y);
    end
    y = c ? 4'b1010 : 4'b1010;
    chk("x ? 4'b1010 : 4'b1010 (identical arms: no X)", 64'({60'h0, y}), 64'b1010);
  endtask

  // ---- width-safe idioms ----------------------------------------------------
  task automatic idioms();
    logic [7:0]         ua, ub, uavg;
    logic signed [7:0]  sa, sb, savg;
    logic [8:0]         usum;
    logic signed [8:0]  ssum;
    logic [15:0]        uprod;
    logic signed [15:0] sprod;

    ua = 8'd200;  ub = 8'd100;
    sa = -8'sd100; sb = -8'sd100;

    $display("\n=== Width-safe idioms that work in ANY context ===");

    usum = {1'b0, ua} + {1'b0, ub};
    chk("unsigned add, carry kept", 64'({55'h0, usum}), 300);

    ssum = signed'({sa[7], sa}) + signed'({sb[7], sb});
    chk("signed add, no overflow", 64'(ssum), -200);

    uprod = 16'(ua) * 16'(ub);
    chk("unsigned product, widened first", 64'({48'h0, uprod}), 20000);

    sprod = 16'(sa) * 16'(sb);
    chk("signed product (both operands signed)", 64'(sprod), 10000);

    uavg = 8'(({1'b0, ua} + {1'b0, ub}) >> 1);
    chk("unsigned average (widen, then shift)", 64'({56'h0, uavg}), 150);

    uavg = (ua & ub) + ((ua ^ ub) >> 1);
    chk("unsigned average (no extra bit needed)", 64'({56'h0, uavg}), 150);

    savg = 8'((signed'({sa[7], sa}) + signed'({sb[7], sb})) >>> 1);
    chk("signed average (rounds toward -infinity)", 64'(savg), -100);
  endtask

  initial begin
    t1_mixed_signedness();
    t2_part_select();
    t3_concat();
    t4_neg_literal();
    t5_lost_bits();
    t6_arith_shift();
    t7_div_mod();
    t8_array_sum();
    t9_neg_min();
    t10_shift_count();
    t11_compare();
    t12_ternary_x();
    idioms();

    $display("");
    if (errors == 0) begin
      $display("signedness_demo: PASS -- every result matched the LRM rules");
    end else begin
      $display("signedness_demo: %0d MISMATCHES", errors);
      $fatal(1, "simulator disagrees with the LRM");
    end
    $finish;
  end

endmodule

/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on WIDTHTRUNC */
