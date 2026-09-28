// -----------------------------------------------------------------------------
// cfg_pipe_scale_fv.sv -- does every beat come out computed under the
// configuration that was active when it went in?
//
// THE HARNESS INSTANTIATES csr_shadow, IT DOES NOT ASSUME IT
//
// The obvious way to prove the QUIESCE mode is to assume "the configuration only
// changes when `safe` is high" and get on with it. That would prove the wrong
// thing. The assumption is a paraphrase of what csr_shadow is supposed to do, and
// a paraphrase can be wrong in exactly the way the design is wrong -- and if the
// paraphrase is subtly UNSATISFIABLE the whole proof passes vacuously, which is
// the failure axis_reg_slice_fv.sv was written up for.
//
// So the harness wires the real shadow to the real datapath and drives the pair
// from a free `staged` and a free `arm`. What is proved is the composition, which
// is also the thing that ships. It means this file is simultaneously the proof
// that csr_shadow's `safe` handshake is strong enough to protect a pipeline and
// the proof that cfg_pipe_scale asks for the right kind of protection -- and if
// either end of that contract is wrong, it fails.
//
// THE REFERENCE
//
// A three-deep delay line carrying {x, cfg}, gated by `en` exactly as the DUT's
// data registers are, and then cfg_pkg::scale_ref in one expression at the far
// end. The DUT spreads that same arithmetic over three stages and picks up its
// configuration at three different times; the model does it all at once from the
// configuration that was live at entry. The two being equal for every beat IS the
// property, and there is no way to state it without an independent copy of "what
// was the configuration when this beat entered".
//
// TASKS
//   travel   CFG_MODE 2 -- the configuration rides with the beat. No constraint on
//            when it may change, because there does not need to be one.
//   quiesce  CFG_MODE 1 -- the same datapath, protected only by `safe`.
//   cover    reachability, and the vacuity alarm.
//
// THERE IS NO `prove` TASK, and the reason is measured rather than assumed. This
// harness contains two 12x17 signed multipliers and two 30-bit variable shifters --
// one set in the DUT, one in the independent reference -- and a multiply followed by
// a variable right shift is effectively a multiply by 2^-shift, which is among the
// hardest things to hand a bit-vector solver. Bounded proof at depth 7 finishes in
// under a second; at depth 8 boolector does not finish in 300; induction does not
// close in 240. docs/39 section 11 has the full sweep and the argument that depth 7
// is nonetheless sufficient for what is being proved here.
//
// CFG_MODE 0 is the negative control. It is not a task here because run_all.sh
// requires every task to pass; run by hand at depth 7 it FAILS in one second.
// -----------------------------------------------------------------------------
`default_nettype none

module cfg_pipe_scale_fv #(
  parameter int unsigned CFG_MODE = 2
) (
  input  var logic                             clk,
  input  var logic                             rst_n,
  input  var logic [cfg_pkg::SCALE_CFGW-1:0]   staged,
  input  var logic                             arm,
  input  var logic                             en,
  input  var logic                             x_valid,
  input  var logic signed [cfg_pkg::XW-1:0]    x
);

  localparam int unsigned XW     = cfg_pkg::XW;
  localparam int unsigned YW     = cfg_pkg::YW;
  localparam int unsigned CFGW   = cfg_pkg::SCALE_CFGW;
  localparam int unsigned STAGES = 3;

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  // ---- the real double buffer, driven by a free software model --------------
  logic [CFGW-1:0] cfg;
  logic            pending, applied, lock, safe;

  csr_shadow #(.NREG(2), .DW(cfg_pkg::CFG_DW), .MODE(2)) u_shadow (
    .clk     (clk),
    .rst_n   (rst_n),
    .staged  (staged),
    .arm     (arm),
    .pending (pending),
    .applied (applied),
    .lock    (lock),
    .safe    (safe),
    .active  (cfg)
  );

  // ---- the datapath --------------------------------------------------------
  logic                y_valid, busy;
  logic signed [YW-1:0] y;

  cfg_pipe_scale #(.CFG_MODE(CFG_MODE)) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .en      (en),
    .cfg     (cfg),
    .x_valid (x_valid),
    .x       (x),
    .y_valid (y_valid),
    .y       (y),
    .busy    (busy),
    .safe    (safe)
  );

  // ---- the reference -------------------------------------------------------
  //
  // Gated by `en` and nothing else, matching the DUT's data registers. The valid
  // bits are pipe_ctrl's problem and are not re-modelled here; this line carries
  // only the values, and they are only compared on a cycle the DUT says is valid.
  logic signed [XW-1:0] fx [STAGES];
  logic [CFGW-1:0]      fc [STAGES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < int'(STAGES); i++) begin
        fx[i] <= '0;
        fc[i] <= '0;
      end
    end else if (en) begin
      fx[0] <= x;     fc[0] <= cfg;
      fx[1] <= fx[0]; fc[1] <= fc[0];
      fx[2] <= fx[1]; fc[2] <= fc[1];
    end
  end

  logic signed [YW-1:0] y_ref;

  always_comb
    y_ref = cfg_pkg::scale_ref(cfg_pkg::scale_gain (fc[STAGES-1]),
                               cfg_pkg::scale_shift(fc[STAGES-1]),
                               cfg_pkg::scale_lo   (fc[STAGES-1]),
                               cfg_pkg::scale_hi   (fc[STAGES-1]),
                               fx[STAGES-1]);

  // THE PROPERTY. Three stages, three different moments at which a configuration
  // field could have been sampled, and one answer that has to match the
  // configuration as it was at entry.
  always @(posedge clk)
    if (rst_n && past_ok && $past(rst_n) && y_valid)
      assert (y == y_ref);

  // ---- reachability, and the vacuity alarm ---------------------------------
  //
  // f_c_change_inflight is the one with teeth. If the solver cannot reach "a
  // configuration commit landed while beats were in flight", then the property
  // above is being proved about a pipeline that is never reconfigured under load,
  // which is the only interesting case. For CFG_MODE 1 this cover is expected to
  // be UNREACHABLE -- quiescing is exactly the promise that it cannot happen --
  // and that asymmetry is the cheapest possible summary of what the two modes
  // cost. See docs/39 section 11; the `cover` task runs CFG_MODE 2.
  always @(posedge clk) begin
    f_c_out          : cover (rst_n && past_ok && y_valid);
    f_c_commit       : cover (rst_n && past_ok && applied);
    f_c_change_inflight : cover (rst_n && past_ok && applied && busy);
    f_c_stall_inflight  : cover (rst_n && past_ok && !en && busy);
    f_c_clamp_hi     : cover (rst_n && past_ok && y_valid && (y == cfg_pkg::scale_hi(fc[STAGES-1])));
    f_c_clamp_lo     : cover (rst_n && past_ok && y_valid && (y == cfg_pkg::scale_lo(fc[STAGES-1])));
  end

endmodule

`default_nettype wire
