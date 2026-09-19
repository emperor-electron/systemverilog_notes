// -----------------------------------------------------------------------------
// useq.sv -- a MICROCODED sequencer: control stored as a table, not as a case
// statement.
//
// WHY
//   A case-statement FSM is the right answer up to roughly 15 states. Past that
//   it stops being readable, every added state touches the next-state logic and
//   the output logic, and the output decode grows into a critical path.
//
//   A microcoded sequencer stores each step as a ROM WORD whose fields ARE the
//   control outputs plus the next-address information. Then:
//     * adding a step is a table edit, not a logic edit;
//     * the control outputs are a ROM read -- one register deep, no decode;
//     * the sequence is data, so it can be reviewed against the protocol
//       document line by line;
//     * the same engine runs any sequence, so it is reusable.
//
//   This is how DMA engines, memory controller initialisation sequences, and
//   long link-training protocols are actually built.
//
// THE COST
//   Indirection. A bug is now either in the engine or in the table, and a
//   waveform shows you a program counter rather than a named state. Worth it
//   past the crossover, a liability below it.
//
// This engine: sequential execution, a conditional branch, and a halt. The
// microcode is built by a constant function, so it is elaboration-time data --
// see rom_table.sv for the same idea applied to a numeric table.
//
// See docs/23-structural-design-techniques.md.
// -----------------------------------------------------------------------------
`default_nettype none

module useq #(
  parameter int unsigned PCW = 4                  // 2^PCW microinstructions
) (
  input  var logic            clk,
  input  var logic            rst_n,
  input  var logic            start,
  input  var logic [1:0]      cond,               // external condition inputs
  output var logic            bus_req,
  output var logic            wr_en,
  output var logic            done,
  output var logic [PCW-1:0]  pc                  // exposed for debug
);

  // ---- microinstruction format ---------------------------------------------
  // A packed struct, so the fields are named here and a plain vector in the ROM.
  typedef struct packed {
    logic            bus_req;    // control outputs...
    logic            wr_en;
    logic            done;
    logic            branch;     // if the selected condition holds, go to targ
    logic [2:0]      csel;       // which condition, see the mux below
    logic [PCW-1:0]  targ;
  } uword_t;

  // Written out rather than $bits(uword_t): Yosys's frontend does not accept
  // $bits() applied to a TYPE (it is fine on an expression). Keep the sum in
  // step with the struct above.
  //                 bus_req + wr_en + done + branch + csel + targ
  localparam int unsigned UW = 1 + 1 + 1 + 1 + 3 + PCW;

  // ---- the microprogram, as elaboration-time data ---------------------------
  // Reads as a listing: each line is one step of the protocol.
  function automatic logic [UW-1:0] ucode(input int unsigned a);
    uword_t w;
    // Positional, not named (`'{bus_req:..., ...}`): Yosys's frontend does not
    // accept named assignment patterns. Field order matches the struct.
    //     bus_req wr_en  done   branch csel   targ
    w = '{1'b0,   1'b0,  1'b0,  1'b0,  3'd5,  PCW'(0)};
    case (a)
      // A WAIT is "branch back to myself while the condition is NOT yet true",
      // which is why the condition mux below provides inverted selects. The
      // first version of this table branched on the condition being TRUE, so
      // every wait state fell straight through -- the sequencer ran the whole
      // protocol in six cycles regardless of the handshakes.
      //     bus_req wr_en  done   branch csel   targ
      0: begin end                                              // idle / entry
      1: w = '{1'b1,   1'b0,  1'b0,  1'b0,  3'd5,  PCW'(0)};    // request bus
      2: w = '{1'b1,   1'b0,  1'b0,  1'b1,  3'd2,  PCW'(2)};    // wait !grant
      3: w = '{1'b1,   1'b1,  1'b0,  1'b0,  3'd5,  PCW'(0)};    // write
      4: w = '{1'b1,   1'b0,  1'b0,  1'b1,  3'd3,  PCW'(4)};    // wait !ack
      5: w = '{1'b0,   1'b0,  1'b1,  1'b0,  3'd5,  PCW'(0)};    // signal done
      6: w = '{1'b0,   1'b0,  1'b0,  1'b1,  3'd4,  PCW'(6)};    // halt (spin)
      default:
         w = '{1'b0,   1'b0,  1'b0,  1'b1,  3'd4,  PCW'(6)};    // trap -> halt
    endcase
    ucode = w;
  endfunction

  logic [UW-1:0] urom [0:(1<<PCW)-1];
  for (genvar a = 0; a < (1 << PCW); a++) begin : g_ucode
    localparam logic [UW-1:0] E = ucode(a);
    assign urom[a] = E;
  end

  // ---- the engine -----------------------------------------------------------
  uword_t w;
  logic   take_branch;
  logic   cond_sel;

  assign w = uword_t'(urom[pc]);

  always_comb begin
    case (w.csel)
      3'd0:    cond_sel =  cond[0];
      3'd1:    cond_sel =  cond[1];
      3'd2:    cond_sel = ~cond[0];      // "while not granted"
      3'd3:    cond_sel = ~cond[1];      // "while not acked"
      3'd4:    cond_sel = 1'b1;          // unconditional
      default: cond_sel = 1'b0;          // never
    endcase
  end

  assign take_branch = w.branch && cond_sel;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= '0;
    end else if (pc == '0) begin
      // Entry: hold at 0 until started.
      if (start) pc <= PCW'(1);
    end else begin
      pc <= take_branch ? w.targ : (pc + 1'b1);
    end
  end

  // Control outputs come straight from the ROM word -- no decode logic.
  assign bus_req = (pc != '0) && w.bus_req;
  assign wr_en   = (pc != '0) && w.wr_en;
  assign done    = (pc != '0) && w.done;

// Properties in the SVA style, for XSIM. This module is NOT in formal/: Yosys's
// constant-function evaluator cannot fold the `case` inside ucode(), so its
// frontend cannot read this file at all. See docs/25 for the full list of
// constructs that limits.
`ifndef SYNTHESIS
  // While idle, no control output is driven.
  a_idle_quiet: assert property (@(posedge clk) disable iff (!rst_n)
    (pc == '0) |-> (!bus_req && !wr_en && !done))
    else $error("useq: control output asserted while idle");

  // Every address decodes to a legal word because `default` traps to halt, so
  // the sequencer can never wander outside the microprogram.
  a_pc_bounded: assert property (@(posedge clk) disable iff (!rst_n)
    pc <= PCW'((1 << PCW) - 1));

  c_done: cover property (@(posedge clk) disable iff (!rst_n) done);
  c_halt: cover property (@(posedge clk) disable iff (!rst_n) pc == PCW'(6));
`endif

endmodule

`default_nettype wire
