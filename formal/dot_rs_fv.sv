// -----------------------------------------------------------------------------
// dot_rs_fv.sv -- is the four-stage pipeline the same arithmetic as the
// combinational expression it was cut from?
//
// THE PROPERTY. dot_rs_dp.sv computes the same dot product either as one lump
// (CUTS=0000) or in four stages (CUTS=1111). So instantiate BOTH from the same
// source, delay the combinational one by four cycles with a shift register that
// shares the pipeline's enable, and assert they agree whenever the pipeline says
// its output is valid:
//
//     dot_rs_global (CUTS=1111)  ---------------------.
//                                                      >--- must be equal
//     dot_rs_dp (CUTS=0000) -> 4-deep delay, same en --'
//
// The delay line is not a reimplementation of the design. It reimplements the
// TIMING, which is trivial and testable by inspection; the ARITHMETIC comes from
// the same module the design uses, so the two cannot drift. That division is the
// point -- a reference model that recomputes the arithmetic can agree with the
// design by sharing its mistake.
//
// COEFFICIENTS ARE FREE BUT CONSTANT. `c` is not pinned to a value: the proof
// holds for every coefficient set the block can be programmed with. It is assumed
// STABLE, because the pipeline applies the coefficients that were present when a
// beat entered while the combinational reference applies today's -- changing them
// mid-flight makes the two legitimately disagree. That is a real property of the
// design (there is no shadow register on `c`), so it is assumed here and stated
// in dot_rs_dp.sv rather than papered over.
//
// WHY THERE IS A SECOND, ELASTIC TASK. The `bmc` equivalence above drives the
// GLOBAL-stall wrapper, where every stage enable is the same wire -- `adv =
// {4{en}}`. So it cannot see a datapath that registers a stage on the WRONG
// stage's enable: in that configuration the wrong enable is the right one.
// Measured, not assumed: mis-wiring cut 3 to adv[0] passes `bmc` cleanly.
//
// The `elastic` task closes that hole. It drives dot_rs_elastic, where the
// enables genuinely differ from each other, and pins each delivered beat to the
// input it came from by CONSTRUCTION rather than by timing:
//
//     assume x == f(in_count)        the producer sends a known function of its
//                                    own sequence number
//     reference = f(out_count)       the reference computes on the beat that is
//                                    supposed to be coming out now
//
// No delay line, no alignment assumptions, and it works however many bubbles
// collapsed on the way through. The same device proves the video colour matrix's
// indexing in vid_axis_csc_fv.sv.
//
// WHY THE EQUIVALENCE IS BMC-ONLY. Induction starts from an arbitrary state in
// which the DUT's four stage registers and the harness's four delay registers
// hold unrelated values, so the equality fails for reasons that say nothing about
// the design. Closing it would need an invariant relating stage k of the DUT to
// element k of the delay line -- and that needs the DUT's internals, which the
// Yosys flow cannot reach into. So `bmc` covers the equivalence and `prove`
// covers everything that is inductive (the clamp, and the global stall's promise
// that nothing moves while `en` is low), with the equivalence gated behind
// `ifdef EQUIV`. fsm_three_process_fv.sv splits itself the same way for the same
// reason.
// -----------------------------------------------------------------------------
`default_nettype none

module dot_rs_fv #(
  parameter int unsigned TAPS = 2,
  parameter int unsigned XW   = 4,
  parameter int unsigned CW   = 6,
  parameter int unsigned CF   = 3,
  parameter int unsigned YW   = 4
) (
  input  var logic                clk,
  input  var logic                rst_n,
  input  var logic                en,
  input  var logic                flush,
  input  var logic                valid_i,
  input  var logic [TAPS*XW-1:0]  x,
  input  var logic [TAPS*CW-1:0]  c,
  input  var logic                m_ready
);

  localparam int unsigned LAT = 4;         // CUTS = 4'b1111

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  // Free, but constant -- see the header.
  always @(posedge clk) if (past_ok) assume (c == $past(c));

  // ---- the design ----------------------------------------------------------
  logic          valid_o, busy;
  logic [YW-1:0] y;

  dot_rs_global #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW),
                  .CUTS(4'b1111)) dut (
    .clk (clk), .rst_n (rst_n), .en (en), .flush (flush),
    .valid_i (valid_i), .x (x), .c (c),
    .valid_o (valid_o), .y (y), .busy (busy)
  );

  // ---- the reference: the same module, uncut -------------------------------
  logic [YW-1:0] y_ref;

  dot_rs_dp #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW),
              .CUTS(4'b0000)) u_ref (
    .clk (clk), .rst_n (rst_n), .adv (4'b0000), .x (x), .c (c), .y (y_ref)
  );

  // ---- the reference's timing: a delay line with the pipeline's enable -----
  logic [YW-1:0] ref_q [LAT];
  integer        fk;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (fk = 0; fk < LAT; fk = fk + 1) ref_q[fk] <= '0;
    end else if (en) begin
      ref_q[0] <= y_ref;
      for (fk = 1; fk < LAT; fk = fk + 1) ref_q[fk] <= ref_q[fk-1];
    end
  end

`ifdef EQUIV
  always @(posedge clk) begin
    if (rst_n && valid_o) f_equiv : assert (y == ref_q[LAT-1]);
  end
`endif

`ifdef ELASTIC
  // ---- the elastic wrapper, with every stage enable independent ------------
  logic                el_sr, el_mv;
  logic [YW-1:0]       el_y;
  logic [TAPS*XW-1:0]  el_x, el_ref_x;
  logic [YW-1:0]       el_y_ref;
  logic [7:0]          in_cnt, out_cnt;

  dot_rs_elastic #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW),
                   .CUTS(4'b1111)) dut_el (
    .clk (clk), .rst_n (rst_n), .flush (1'b0),
    .s_valid (valid_i), .s_ready (el_sr), .x (el_x), .c (c),
    .m_valid (el_mv), .m_ready (m_ready), .y (el_y)
  );

  // Beat k carries a known payload, so the beat coming out can be identified
  // without any assumption about how long it took to get there.
  function automatic logic [TAPS*XW-1:0] fv_payload(input logic [7:0] k);
    fv_payload = '0;
    for (int i = 0; i < int'(TAPS); i++)
      fv_payload[i*XW +: XW] = XW'(k + 8'(i * 3));
  endfunction

  assign el_x     = fv_payload(in_cnt);
  assign el_ref_x = fv_payload(out_cnt);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_cnt  <= '0;
      out_cnt <= '0;
    end else begin
      if (valid_i && el_sr) in_cnt  <= in_cnt  + 1'b1;
      if (el_mv  && m_ready) out_cnt <= out_cnt + 1'b1;
    end
  end

  dot_rs_dp #(.TAPS(TAPS), .XW(XW), .CW(CW), .CF(CF), .YW(YW),
              .CUTS(4'b0000)) u_ref_el (
    .clk (clk), .rst_n (rst_n), .adv (4'b0000),
    .x (el_ref_x), .c (c), .y (el_y_ref)
  );

  // The producer's half of the handshake contract. The payload needs no
  // assumption -- it is a function of the accepted count, which only moves when
  // a beat is accepted.
  always @(posedge clk)
    if (past_ok && rst_n && $past(rst_n) && $past(valid_i) && !$past(el_sr))
      assume (valid_i);

  always @(posedge clk) begin
    if (rst_n) f_el_equiv : assert (!el_mv || (el_y == el_y_ref));
  end

  always @(posedge clk) begin
    f_c_el_out  : cover (rst_n && el_mv && m_ready);
    f_c_el_bp   : cover (rst_n && el_mv && !m_ready);
    f_c_el_full : cover (rst_n && !el_sr);
  end
`endif

  always @(posedge clk) begin
    f_c_out       : cover (rst_n && valid_o);
    f_c_stalled   : cover (rst_n && !en && busy);
    f_c_saturated : cover (rst_n && valid_o && (y == {YW{1'b1}}));
    f_c_zero      : cover (rst_n && valid_o && (y == '0));
    f_c_flush_busy: cover (rst_n && past_ok && $past(flush) && $past(busy) && !busy);
  end

endmodule

`default_nettype wire
