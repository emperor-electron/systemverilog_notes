// -----------------------------------------------------------------------------
// pulse_extend.sv -- stretch a one-cycle pulse to N cycles.
//
// Wanted whenever a fast domain has to be seen by something slow: an LED that
// would otherwise blink for 20ns, a level a slower state machine samples, an
// output pin with a minimum-width specification.
//
// NOT a clock-domain crossing. Stretching a pulse so the other domain "probably
// catches it" is the classic almost-working CDC: it reduces the failure rate
// without removing the failure. Use cdc_pulse, which is built for it (docs/28).
//
// RETRIGGER decides what a new pulse during an active output means:
//   1 -- restart the count, so the output stays high N cycles past the LAST
//        input pulse. Right for activity indicators.
//   0 -- ignore it, so the output is exactly N cycles per accepted pulse and
//        pulses arriving during the window are lost. Right when the output
//        must be countable.
// -----------------------------------------------------------------------------
`default_nettype none

module pulse_extend #(
  parameter int unsigned CYCLES    = 4,
  parameter bit          RETRIGGER = 1'b1
) (
  input  var logic clk,
  input  var logic rst_n,
  input  var logic pulse_in,
  output var logic pulse_out
);

  if (CYCLES == 0) begin : g_chk
    $error("pulse_extend: CYCLES must be >= 1");
  end

  if (CYCLES == 1) begin : g_passthrough
    assign pulse_out = pulse_in;

  end else begin : g_stretch
    // $clog2(CYCLES+1), not $clog2(CYCLES): the counter has to HOLD the value
    // CYCLES, and for a power of two $clog2(CYCLES) is one bit short of that.
    // Sizing it from CYCLES alone silently truncates the load and the output
    // comes out one cycle narrow.
    localparam int unsigned CW = $clog2(CYCLES + 1);

    logic [CW-1:0] cnt;

    assign pulse_out = (cnt != '0);

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        cnt <= '0;
      end else if (pulse_in && (RETRIGGER || (cnt == '0))) begin
        // Load CYCLES, not CYCLES-1. The load itself takes a cycle, so the
        // output is high on the CYCLES clocks where cnt runs CYCLES..1.
        cnt <= CW'(CYCLES);
      end else if (cnt != '0) begin
        cnt <= cnt - 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
