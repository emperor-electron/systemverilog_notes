// -----------------------------------------------------------------------------
// seven_seg_mux.sv -- time-multiplexed multi-digit seven-segment driver.
//
// A four-digit display has 4 x 7 = 28 segments and usually 7 + 4 = 11 pins. The
// trick is persistence of vision: light one digit at a time, cycle fast enough,
// and the eye integrates them into a steady display.
//
// THE REFRESH RATE IS THE WHOLE DESIGN. Each digit is lit 1/DIGITS of the time,
// so the FULL cycle must complete faster than the eye can resolve:
//
//   below ~50 Hz per digit   visible flicker
//   ~60-200 Hz per digit     good
//   far above that           brightness falls, because the drive is a smaller
//                            fraction of each digit's cycle at the same duty
//
// REFRESH_DIV is the clk cycles per DIGIT, so the full refresh rate is
// clk / (REFRESH_DIV * DIGITS). For 4 digits at 1 kHz per digit from 50 MHz:
// REFRESH_DIV = 50_000.
//
// BLANKING BETWEEN DIGITS is not optional on a real board. Turning the segments
// off a little before switching the digit select stops the previous digit's
// pattern from appearing faintly on the next one while the transistors turn
// off -- "ghosting". BLANK_CYCLES does that, and being able to set it to zero
// is useful only in simulation.
//
// Digit-select polarity follows the same reasoning as hex7seg.sv: common-anode
// displays need an active-low drive, which is the default here.
// -----------------------------------------------------------------------------
`default_nettype none

module seven_seg_mux #(
  parameter int unsigned DIGITS       = 4,
  parameter int unsigned REFRESH_DIV  = 16,     // clk cycles per digit
  parameter int unsigned BLANK_CYCLES = 2,      // dead time before switching
  parameter bit          ACTIVE_LOW   = 1'b1
) (
  input  var logic                clk,
  input  var logic                rst_n,

  input  var logic [DIGITS*4-1:0] value,        // one hex nibble per digit
  input  var logic [DIGITS-1:0]   blank,        // per-digit blanking

  output var logic [6:0]          seg,          // {g,f,e,d,c,b,a}
  output var logic [DIGITS-1:0]   digit_sel     // one active digit at a time
);

  if (DIGITS < 1) begin : g_chk_d
    $error("seven_seg_mux: DIGITS must be >= 1");
  end
  if (BLANK_CYCLES >= REFRESH_DIV) begin : g_chk_b
    $error("seven_seg_mux: BLANK_CYCLES (%0d) must be < REFRESH_DIV (%0d)",
           BLANK_CYCLES, REFRESH_DIV);
  end

  localparam int unsigned RW = (REFRESH_DIV <= 1) ? 1 : $clog2(REFRESH_DIV);
  localparam int unsigned DW = (DIGITS <= 1) ? 1 : $clog2(DIGITS);

  logic [RW-1:0] rcnt;
  logic [DW-1:0] cur;
  logic          tick, in_blank;
  logic [3:0]    nibble;
  logic          digit_blank;

  assign tick     = (rcnt == RW'(REFRESH_DIV - 1));
  assign in_blank = (rcnt >= RW'(REFRESH_DIV - BLANK_CYCLES));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rcnt <= '0;
      cur  <= '0;
    end else begin
      rcnt <= tick ? '0 : (rcnt + 1'b1);
      if (tick) cur <= (cur == DW'(DIGITS - 1)) ? '0 : (cur + 1'b1);
    end
  end

  assign nibble      = value[cur * 4 +: 4];
  assign digit_blank = blank[cur] || in_blank;

  hex7seg #(.ACTIVE_LOW(ACTIVE_LOW)) u_dec (
    .val(nibble), .blank(digit_blank), .seg(seg));

  // Exactly one digit driven at a time -- the invariant the whole scheme rests
  // on. Two at once means two digits showing the same value, dimly.
  always_comb begin
    logic [DIGITS-1:0] sel;
    sel = '0;
    sel[cur] = 1'b1;
    digit_sel = ACTIVE_LOW ? ~sel : sel;
  end

`ifndef SYNTHESIS
  a_onehot_digit: assert property (@(posedge clk) disable iff (!rst_n)
    $onehot(ACTIVE_LOW ? ~digit_sel : digit_sel))
    else $error("seven_seg_mux: %0d digits selected at once",
                $countones(ACTIVE_LOW ? ~digit_sel : digit_sel));
`endif

endmodule

`default_nettype wire
