// -----------------------------------------------------------------------------
// i2c_master.sv -- I2C master with a byte-level command interface.
//
// I2C is two OPEN-DRAIN wires with pull-up resistors. Nothing ever drives a one;
// a device either pulls the line low or lets go. That is what makes a shared bus
// possible without contention, and it dictates this module's pin interface:
//
//     scl_oe / sda_oe   1 = pull the line LOW,  0 = release it
//     scl_i  / sda_i    what the line actually reads, which is the AND of
//                       every device on it
//
// At the pad: assign scl_pad = scl_oe ? 1'b0 : 1'bz;
// Never assign a 1. A master that drives SCL high fights the slave during clock
// stretching and eventually damages one of them.
//
// Reading the line back is not redundant -- it is where two features come from:
//
//   CLOCK STRETCHING. A slave that needs time holds SCL low after the master
//   releases it. The master must wait for scl_i to actually read high before
//   timing the high period, or it clocks a bit the slave never saw. This is the
//   single most commonly omitted part of a hand-written I2C master, and it fails
//   only against slow slaves -- so it passes every bench test with a fast one.
//
//   ARBITRATION. If the master releases SDA (writes a 1) and reads back 0,
//   someone else is pulling it low. That master has lost arbitration and must
//   stop driving immediately.
//
// BIT TIMING. Every operation is the same four quarter-period phases, which is
// what keeps START, STOP and data bits from each needing their own timing code:
//
//   ph0  SCL low, set SDA
//   ph1  SCL released; wait for it to read high (this is where stretching waits)
//   ph2  SCL high, sample SDA        <- START drives SDA low here
//   ph3  SCL driven low                 STOP releases SDA here
//
// A START in ph2 is "SDA falls while SCL is high"; a STOP is "SDA rises while
// SCL is high". Those are the only two times SDA is allowed to move during a
// high SCL, and every other phase keeps it still.
//
// COMMAND INTERFACE. One command per transfer element, so the caller composes
// whole transactions and this module never needs to know the device protocol:
//
//   START  generate (or repeat) a start condition
//   WRITE  clock out wdata, then read the slave's ACK into ack_out
//   READ   clock in a byte to rdata, then send ACK or NACK per nack_in
//   STOP   generate a stop condition and release the bus
// -----------------------------------------------------------------------------
`default_nettype none

module i2c_master #(
  // Quarter of an SCL period, in clk cycles. For 100 kHz from 50 MHz:
  // 50e6 / (4 * 100e3) = 125.
  parameter int unsigned DIV4 = 125
) (
  input  var logic       clk,
  input  var logic       rst_n,

  input  var logic       cmd_valid,
  input  var logic [1:0] cmd,
  input  var logic [7:0] wdata,
  input  var logic       nack_in,      // READ: 1 = answer with NACK (last byte)
  output var logic       cmd_ready,
  output var logic [7:0] rdata,
  output var logic       ack_out,      // WRITE: 0 = slave acknowledged
  output var logic       done,         // one cycle per completed command
  output var logic       busy,
  output var logic       arb_lost,     // sticky until the next START

  output var logic       scl_oe,       // 1 = pull SCL low
  input  var logic       scl_i,
  output var logic       sda_oe,       // 1 = pull SDA low
  input  var logic       sda_i
);

  localparam logic [1:0] CMD_START = 2'd0;
  localparam logic [1:0] CMD_WRITE = 2'd1;
  localparam logic [1:0] CMD_READ  = 2'd2;
  localparam logic [1:0] CMD_STOP  = 2'd3;

  if (DIV4 == 0) begin : g_chk
    $error("i2c_master: DIV4 must be >= 1");
  end

  localparam int unsigned QW = (DIV4 <= 1) ? 1 : $clog2(DIV4);

  typedef enum logic [2:0] {
    S_IDLE, S_START, S_BYTE, S_STOP
  } st_e;

  st_e            st;
  logic [QW-1:0]  qcnt;
  logic [1:0]     ph;
  logic [3:0]     bitcnt;      // 0..8; 8 is the ACK slot
  logic [7:0]     sh;
  logic [1:0]     cmd_q;
  logic           nack_q;
  logic           q_tick;
  logic           ph_adv;
  logic           writing, reading;
  logic           in_ack_slot;

  assign q_tick      = (qcnt == QW'(DIV4 - 1));
  assign writing     = (cmd_q == CMD_WRITE);
  assign reading     = (cmd_q == CMD_READ);
  assign in_ack_slot = (bitcnt == 4'd8);
  assign cmd_ready   = (st == S_IDLE) && !busy;

  // Phase 1 is where clock stretching waits: SCL has been released, and the
  // high period does not start until the line actually reads high.
  assign ph_adv = q_tick && ((ph != 2'd1) || scl_i);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      qcnt     <= '0;
      ph       <= '0;
      bitcnt   <= '0;
      sh       <= '0;
      cmd_q    <= CMD_START;
      nack_q   <= 1'b0;
      rdata    <= '0;
      ack_out  <= 1'b1;
      done     <= 1'b0;
      busy     <= 1'b0;
      arb_lost <= 1'b0;
      scl_oe   <= 1'b0;          // released: the bus idles high
      sda_oe   <= 1'b0;
    end else begin
      done <= 1'b0;

      // The quarter-period counter only runs while a command is in progress,
      // and only advances when the phase is allowed to.
      if (st == S_IDLE) qcnt <= '0;
      else              qcnt <= ph_adv ? '0 : (qcnt + 1'b1);

      unique case (st)
        S_IDLE: begin
          busy <= 1'b0;
          if (cmd_valid) begin
            cmd_q  <= cmd;
            sh     <= wdata;
            nack_q <= nack_in;
            bitcnt <= '0;
            ph     <= '0;
            busy   <= 1'b1;
            unique case (cmd)
              CMD_START: begin
                st       <= S_START;
                arb_lost <= 1'b0;     // a fresh START clears a stale loss
                sda_oe   <= 1'b0;     // release SDA so it can fall in ph2
              end
              CMD_STOP:  begin
                st     <= S_STOP;
                sda_oe <= 1'b1;       // hold SDA low so it can rise in ph2
              end
              default:   begin
                st     <= S_BYTE;
                // First bit is set below, in ph0.
              end
            endcase
          end
        end

        // START / repeated START. From idle, SCL is already released and ph1 is
        // a formality; after an ACK bit, SCL is low and ph1 is the real release.
        S_START: begin
          unique case (ph)
            2'd0: scl_oe <= 1'b1;               // make sure SCL is low first
            2'd1: scl_oe <= 1'b0;               // release; ph_adv waits for high
            2'd2: sda_oe <= 1'b1;               // SDA falls while SCL is high
            2'd3: scl_oe <= 1'b1;               // and take SCL back down
            default: ;
          endcase
          if (ph_adv) begin
            if (ph == 2'd3) begin
              st   <= S_IDLE;
              done <= 1'b1;
            end
            ph <= ph + 1'b1;
          end
        end

        S_BYTE: begin
          unique case (ph)
            2'd0: begin
              scl_oe <= 1'b1;
              // Drive SDA for this bit slot. Writing a 1 means RELEASING the
              // line, never driving it high.
              if (in_ack_slot) sda_oe <= reading ? ~nack_q : 1'b0;
              else             sda_oe <= writing ? ~sh[7]  : 1'b0;
            end
            2'd1: scl_oe <= 1'b0;
            2'd2: ;                     // SCL high; the sample is taken below
            2'd3: scl_oe <= 1'b1;
            default: ;
          endcase

          if (ph_adv) begin
            // Sample ONCE per bit, at the end of the high period.
            //
            // A phase body runs on every clock of that phase, not once -- a
            // phase is DIV4 cycles long. Putting the shift in the `2'd2` case
            // above shifts the same bit in DIV4 times and the received byte is
            // nonsense. Writes survived that mistake because setting an output
            // repeatedly is idempotent and shifting a register is not, which is
            // why it showed up only on reads.
            if (ph == 2'd2) begin
              if (in_ack_slot) begin
                if (writing) ack_out <= sda_i;   // 0 = the slave acknowledged
              end else begin
                if (reading) rdata <= {rdata[6:0], sda_i};
                // Arbitration: we released SDA but someone is pulling it low.
                if (writing && sh[7] && !sda_i) arb_lost <= 1'b1;
              end
            end

            if (ph == 2'd3) begin
              if (in_ack_slot) begin
                st     <= S_IDLE;
                done   <= 1'b1;
                sda_oe <= 1'b0;                 // leave SDA released
              end else begin
                sh     <= {sh[6:0], 1'b0};
                bitcnt <= bitcnt + 1'b1;
              end
            end
            ph <= ph + 1'b1;
          end
        end

        S_STOP: begin
          unique case (ph)
            2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end
            2'd1: scl_oe <= 1'b0;
            2'd2: sda_oe <= 1'b0;               // SDA rises while SCL is high
            2'd3: ;                             // bus idle: both released
            default: ;
          endcase
          if (ph_adv) begin
            if (ph == 2'd3) begin
              st   <= S_IDLE;
              done <= 1'b1;
            end
            ph <= ph + 1'b1;
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // The rule that makes the bus shareable: this module never drives a one.
  // (Structural here, but worth asserting because a "fix" for a stuck bus is
  // often to start driving SCL high.)
  a_done_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    done |=> !done);

  a_ready_not_busy: assert property (@(posedge clk) disable iff (!rst_n)
    cmd_ready |-> !busy);

  // SDA may only move while SCL is high during a START or a STOP.
  a_sda_stable_when_scl_high: assert property (@(posedge clk) disable iff (!rst_n)
    (!scl_oe && scl_i && (st == S_BYTE) && (ph == 2'd2)) |=>
      (($stable(sda_oe)) || (st != S_BYTE)))
    else $error("i2c_master: SDA moved while SCL was high during a data bit");
`endif

endmodule

`default_nettype wire
