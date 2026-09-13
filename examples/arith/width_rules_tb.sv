// -----------------------------------------------------------------------------
// width_rules_tb.sv -- the two-pass expression-width algorithm, demonstrated.
//
// Pass 1 (bottom-up): every operand gets its SELF-DETERMINED width.
// Pass 2 (top-down):  the expression width is max(self, LHS), and that width is
//                     pushed back down into every CONTEXT-DETERMINED operand,
//                     which is extended BEFORE the operator evaluates.
//
// The whole game is knowing which positions are context-determined (so a wide
// destination rescues them) and which are self-determined (so it does not).
//
// Run it:
//   $ iverilog -g2012 -o wr width_rules_tb.sv && ./wr
//
// See docs/17-signed-unsigned-arithmetic.md section 3.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// NOTE ON LINTING: this file deliberately contains the width and signedness
// mismatches that a linter is supposed to flag -- they ARE the subject matter.
// The pragmas below silence those two checks for this file only. In real RTL,
// leave them ON and treat them as errors; see docs/20.
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module width_rules_tb;

  int errors = 0;

  task automatic chk(input string name,
                     input logic signed [63:0] got,
                     input logic signed [63:0] exp);
    if (got !== exp) begin
      errors++;
      $display("  MISMATCH  %-52s got=%0d expected=%0d", name, got, exp);
    end else begin
      $display("  ok        %-52s = %0d", name, got);
    end
  endtask

  // ---------------------------------------------------------------------------
  // $bits() reports the self-determined width of an expression. It is the
  // fastest way to answer "how wide is this actually being computed?"
  // ---------------------------------------------------------------------------
  task automatic self_determined_widths();
    logic [7:0]  a8;
    logic [15:0] b16;
    logic [3:0]  c4;
    $display("\n=== Pass 1: self-determined widths ($bits reports them) ===");
    chk("$bits(a8)",            64'($bits(a8)),            8);
    chk("$bits(a8 + a8)",       64'($bits(a8 + a8)),       8);   // max(8,8)
    chk("$bits(a8 + b16)",      64'($bits(a8 + b16)),      16);  // max(8,16)
    chk("$bits(a8 * a8)",       64'($bits(a8 * a8)),       8);   // NOT 16!
    chk("$bits(a8 << 4)",       64'($bits(a8 << 4)),       8);   // width of LHS
    chk("$bits({a8, c4})",      64'($bits({a8, c4})),      12);  // sum
    chk("$bits({3{c4}})",       64'($bits({3{c4}})),       12);  // N * width
    chk("$bits(a8 == b16)",     64'($bits(a8 == b16)),     1);   // comparison
    chk("$bits(|a8)",           64'($bits(|a8)),           1);   // reduction
    chk("$bits(a8 && b16)",     64'($bits(a8 && b16)),     1);   // logical
    chk("$bits(c4 ? a8 : b16)", 64'($bits(c4 ? a8 : b16)), 16);  // max of arms
    chk("$bits(1)",             64'($bits(1)),             32);  // unsized literal
    chk("$bits(8'd1)",          64'($bits(8'd1)),          8);
  endtask

  // ---------------------------------------------------------------------------
  // Pass 2: the destination width flows DOWN into context-determined operands.
  // ---------------------------------------------------------------------------
  task automatic context_rescues();
    logic [7:0]  a, b;
    logic [15:0] w;
    a = 8'd200;  b = 8'd100;
    $display("\n=== Pass 2: a wide destination widens context-determined operands ===");
    w = a * b;        chk("w = a * b            (both operands widen to 16)", 64'(w), 20000);
    w = a + b;        chk("w = a + b            (carry kept)",                64'(w), 300);
    w = (a * b) >> 1; chk("w = (a*b) >> 1       (context passes through >>)", 64'(w), 10000);
    w = a * b + 1;    chk("w = a * b + 1        (context passes through +)",  64'(w), 20001);
    w = (a > b) ? (a * b) : 16'd0;
                      chk("w = cond ? (a*b) : 0 (ternary arms are context-det.)", 64'(w), 20000);
  endtask

  // ---------------------------------------------------------------------------
  // ...and where it does NOT reach.
  // ---------------------------------------------------------------------------
  task automatic context_broken();
    logic [7:0]  a, b, tmp;
    logic [15:0] w;
    a = 8'd200;  b = 8'd100;
    $display("\n=== Where the top-down pass does NOT reach ===");

    // (a) A narrow named intermediate cuts the chain.
    tmp = a * b;  w = 16'(tmp);
    chk("tmp = a*b; w = tmp   (truncated at the 8-bit tmp)", 64'(w), 32);

    // (b) Concatenation operands are SELF-determined: a*b evaluates at 8 bits,
    //     and only then is the 8-bit concatenation zero-extended to 16.
    w = {a * b};
    chk("w = {a * b}          (concat operand is self-determined)", 64'(w), 32);

    // (c) A replication operand is self-determined too.
    w = {2{a + b}};
    chk("w = {2{a + b}}       (8-bit sum 44, replicated)", 64'(w), 16'h2C2C);

    // (d) A reduction operand is self-determined.
    chk("|(a + b)             (8-bit sum 44 -> nonzero)", 64'(|(a + b)), 1);

    // (e) A shift COUNT is self-determined (and unsigned).
    w = 16'd1 << (a[2:0]);
    chk("1 << a[2:0]          (count 0 -> 1)", 64'(w), 1);
  endtask

  // ---------------------------------------------------------------------------
  // A LHS concatenation is itself the context -- a useful trick for capturing
  // a carry-out without declaring a wider intermediate.
  // ---------------------------------------------------------------------------
  task automatic lhs_concat_context();
    logic [7:0] a, b, sum;
    logic       cout, borrow;
    a = 8'd200;  b = 8'd100;
    $display("\n=== A concatenation on the LHS provides the context ===");
    {cout, sum} = a + b;
    chk("{cout,sum} = a + b   -> sum",  64'({56'h0, sum}),  44);
    chk("{cout,sum} = a + b   -> cout", 64'({63'h0, cout}), 1);

    a = 8'd100;  b = 8'd200;
    {borrow, sum} = a - b;
    chk("{borrow,sum} = a - b -> borrow (a < b)", 64'({63'h0, borrow}), 1);
  endtask

  // ---------------------------------------------------------------------------
  // Signedness propagates with width: in an UNSIGNED expression a signed
  // operand is ZERO-extended.
  // ---------------------------------------------------------------------------
  task automatic signedness_propagation();
    logic signed [3:0] s;
    logic        [3:0] u;
    logic signed [7:0] r;
    s = -1;   // 4'b1111
    u =  1;   // 4'b0001
    $display("\n=== Signedness travels with the width, down into the operands ===");

    // Unsigned expression (u is unsigned): s is ZERO-extended to 8 bits -> 15.
    r = s + u;
    chk("s + u  (unsigned expr: s zero-extends to 15)", 64'(r), 16);

    // Signed expression: s SIGN-extends to -1.
    r = s + signed'({1'b0, u});
    chk("s + signed'({1'b0,u})  (signed expr: s sign-extends)", 64'(r), 0);

    // Every operand of a signed expression must be signed for the whole
    // expression to be signed. One unsigned operand is enough to flip it.
    chk("$bits(s + u)", 64'($bits(s + u)), 4);
  endtask

  initial begin
    self_determined_widths();
    context_rescues();
    context_broken();
    lhs_concat_context();
    signedness_propagation();

    $display("");
    if (errors == 0) $display("width_rules_tb: PASS -- all widths matched the LRM algorithm");
    else begin
      $display("width_rules_tb: %0d MISMATCHES", errors);
      $fatal(1, "simulator disagrees with the LRM");
    end
    $finish;
  end

endmodule

/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on WIDTHTRUNC */
