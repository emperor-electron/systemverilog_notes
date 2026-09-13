// -----------------------------------------------------------------------------
// encoders.sv -- priority encoder, one-hot decoder, leading-zero count,
//                population count, and a Gray <-> binary pair.
//
// Each is written the way it reads best; all are pure combinational and unroll
// at elaboration.
// -----------------------------------------------------------------------------
`default_nettype none

// --- priority encoder: index of the lowest set bit ---------------------------
module priority_encoder #(
  parameter int unsigned N  = 16,
  parameter int unsigned IW = (N <= 1) ? 1 : $clog2(N)
) (
  input  var logic [N-1:0]  in,
  output var logic [IW-1:0] idx,
  output var logic          valid
);
  always_comb begin
    idx   = '0;
    valid = 1'b0;
    // The loop APPEARS sequential but unrolls into a priority mux chain.
    // The !valid guard makes the LOWEST index win; without it the highest does.
    for (int i = 0; i < int'(N); i++)
      if (!valid && in[i]) begin
        idx   = IW'(i);
        valid = 1'b1;
      end
  end
endmodule


// --- one-hot decoder ---------------------------------------------------------
module onehot_decoder #(
  parameter int unsigned IW = 4,
  parameter int unsigned N  = 1 << IW
) (
  input  var logic [IW-1:0] idx,
  input  var logic          en,
  output var logic [N-1:0]  out
);
  always_comb begin
    out = '0;
    if (en) out[idx] = 1'b1;
  end
endmodule


// --- leading zero count ------------------------------------------------------
// Counts zeros from the MSB down. Returns N if the input is all zero.
// This is the critical block inside a floating-point adder's normalizer.
module lzc #(
  parameter int unsigned N  = 32,
  parameter int unsigned CW = $clog2(N) + 1
) (
  input  var logic [N-1:0]  in,
  output var logic [CW-1:0] count,
  output var logic          all_zero
);
  always_comb begin
    count    = CW'(N);
    all_zero = 1'b1;
    for (int i = 0; i < int'(N); i++)
      if (in[i]) begin
        count    = CW'(N - 1 - i);   // later iterations (higher i) overwrite,
        all_zero = 1'b0;             //   so the HIGHEST set bit wins
      end
  end
endmodule


// --- population count (adder tree) -------------------------------------------
module popcount #(
  parameter int unsigned N  = 32,
  parameter int unsigned CW = $clog2(N) + 1
) (
  input  var logic [N-1:0]  in,
  output var logic [CW-1:0] count
);
  // $countones is synthesizable and the tool builds a good adder tree.
  assign count = CW'($countones(in));
endmodule


// --- Gray <-> binary ---------------------------------------------------------
module gray_codec #(
  parameter int unsigned W = 8
) (
  input  var logic [W-1:0] bin_in,
  output var logic [W-1:0] gray_out,
  input  var logic [W-1:0] gray_in,
  output var logic [W-1:0] bin_out
);
  // bin -> gray: one XOR gate per bit, no carry chain.
  assign gray_out = bin_in ^ (bin_in >> 1);

  // gray -> bin: a prefix XOR. b[i] = XOR of g[W-1:i].
  always_comb begin
    bin_out[W-1] = gray_in[W-1];
    for (int i = W-2; i >= 0; i--)
      bin_out[i] = bin_out[i+1] ^ gray_in[i];
  end
endmodule


// --- Gray-code counter -------------------------------------------------------
// Keeps a binary counter internally and emits the Gray view, which is what you
// want for a CDC pointer: the binary form is easy to compare and increment,
// the Gray form is what crosses the boundary.
module gray_counter #(
  parameter int unsigned W = 8
) (
  input  var logic         clk,
  input  var logic         rst_n,
  input  var logic         en,
  output var logic [W-1:0] bin,
  output var logic [W-1:0] gray
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bin  <= '0;
      gray <= '0;
    end else if (en) begin
      bin  <= bin + 1'b1;
      gray <= (bin + 1'b1) ^ ((bin + 1'b1) >> 1);
    end
  end

`ifndef SYNTHESIS
  a_onestep: assert property (@(posedge clk) disable iff (!rst_n)
                              $countones(gray ^ $past(gray)) <= 1)
    else $error("gray_counter: more than one bit changed");
`endif
endmodule

`default_nettype wire
