// -----------------------------------------------------------------------------
// fp_pkg.sv -- IEEE 754 helpers, parameterized over (EXP_W, MAN_W).
//
// Every function here is synthesizable: they are pure bit manipulation on the
// packed encoding. Nothing uses `real`.
//
// See docs/19-floating-point-hardware.md for the theory.
// -----------------------------------------------------------------------------
`ifndef FP_PKG_SV
`define FP_PKG_SV

package fp_pkg;

  // ---- format descriptors ---------------------------------------------------
  // (EXP_W, MAN_W) fully describes an IEEE 754 binary format.
  localparam int FP16_E = 5,  FP16_M = 10;    // binary16
  localparam int BF16_E = 8,  BF16_M = 7;     // bfloat16
  localparam int FP32_E = 8,  FP32_M = 23;    // binary32
  localparam int FP64_E = 11, FP64_M = 52;    // binary64
  localparam int E4M3_E = 4,  E4M3_M = 3;     // FP8 E4M3
  localparam int E5M2_E = 5,  E5M2_M = 2;     // FP8 E5M2

  function automatic int bias(input int exp_w);
    return (1 << (exp_w - 1)) - 1;
  endfunction

  // ---- rounding modes (RISC-V frm encoding) ---------------------------------
  typedef enum logic [2:0] {
    RNE = 3'b000,   // round to nearest, ties to even      (IEEE default)
    RTZ = 3'b001,   // round toward zero (truncate)
    RDN = 3'b010,   // round down, toward -infinity
    RUP = 3'b011,   // round up, toward +infinity
    RMM = 3'b100    // round to nearest, ties to max magnitude (away from zero)
  } rnd_e;

  // ---- exception flags (RISC-V fflags bit order) ----------------------------
  typedef struct packed {
    logic nv;   // bit 4: invalid operation
    logic dz;   // bit 3: divide by zero
    logic of;   // bit 2: overflow
    logic uf;   // bit 1: underflow
    logic nx;   // bit 0: inexact
  } flags_t;

  // ---- value classes --------------------------------------------------------
  typedef enum logic [3:0] {
    FC_NEG_INF  = 4'd0,
    FC_NEG_NORM = 4'd1,
    FC_NEG_SUB  = 4'd2,
    FC_NEG_ZERO = 4'd3,
    FC_POS_ZERO = 4'd4,
    FC_POS_SUB  = 4'd5,
    FC_POS_NORM = 4'd6,
    FC_POS_INF  = 4'd7,
    FC_SNAN     = 4'd8,
    FC_QNAN     = 4'd9
  } fclass_e;

  // ---------------------------------------------------------------------------
  // The increment decision for all five rounding modes.
  //   L = the LSB of the result being kept
  //   R = the "half" bit (the first bit discarded)
  //   S = sticky: the OR of every bit below R
  // RNE:  R & (S | L)   -- above half always; exactly half only to even.
  // ---------------------------------------------------------------------------
  function automatic logic round_up(input rnd_e rm,
                                    input logic sign,
                                    input logic l, r, s);
    case (rm)
      RNE:     return  r & (s | l);
      RTZ:     return  1'b0;
      RDN:     return  sign & (r | s);       // more negative
      RUP:     return ~sign & (r | s);       // more positive
      RMM:     return  r;
      default: return  r & (s | l);
    endcase
  endfunction

  // On overflow, RTZ and "round away from the infinity" give MAX_FINITE
  // instead of infinity.
  function automatic logic overflow_to_inf(input rnd_e rm, input logic sign);
    case (rm)
      RTZ:     return 1'b0;
      RDN:     return  sign;                 // -inf only for negative results
      RUP:     return ~sign;                 // +inf only for positive results
      default: return 1'b1;                  // RNE, RMM
    endcase
  endfunction

endpackage

`endif
