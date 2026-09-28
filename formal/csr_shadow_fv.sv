// -----------------------------------------------------------------------------
// csr_shadow_fv.sv -- the staged/active double buffer.
//
// The substance is inside csr_shadow.sv, because atomicity and isolation are
// statements about the relationship between the register bundle and the commit,
// and both live in there (the standing rule -- docs/25).
//
// `staged` IS A FREE 128-BIT INPUT and that is deliberate. axis_reg_slice_fv.sv
// records what happened the one time a payload was tied off in a harness whose
// module constrained it: the assumption became unsatisfiable, every assertion
// passed, and a slice that lost beats passed with them. Here a free `staged` also
// happens to be the strongest possible model of software -- it covers every
// write order, every partial update and every interleaving, including ones no
// processor would actually produce.
//
// `safe` is free too. The consumer is not modelled at all: csr_shadow's contract
// is "I commit only when told it is safe", and that has to hold against an
// adversarial `safe`, not a plausible one.
// -----------------------------------------------------------------------------
`default_nettype none

module csr_shadow_fv #(
  parameter int unsigned NREG = 4,
  parameter int unsigned DW   = 32,
  parameter int unsigned MODE = 2
) (
  input  var logic               clk,
  input  var logic               rst_n,
  input  var logic [NREG*DW-1:0] staged,
  input  var logic               arm,
  input  var logic               safe
);

  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  always @* if (init) assume (!rst_n);

  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= 1'b1;

  logic [NREG*DW-1:0] active;
  logic               pending, applied, lock;

  csr_shadow #(.NREG(NREG), .DW(DW), .MODE(MODE)) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .staged  (staged),
    .arm     (arm),
    .pending (pending),
    .applied (applied),
    .lock    (lock),
    .safe    (safe),
    .active  (active)
  );

  // A software model, for the covers only -- nothing is assumed from it. It
  // writes one 32-bit word at a time, which is the thing that makes a multi-word
  // parameter tearable in the first place, and the cover below asks the solver to
  // find a commit that lands with the two halves DIFFERENT from each other yet
  // still publishes them together.
  logic [NREG*DW-1:0] sw_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sw_q <= '0;
    else        sw_q <= staged;
  end

  always @(posedge clk) begin
    // The commit happened at all.
    f_c_commit  : cover (rst_n && past_ok && applied);

    // A commit that had to WAIT: armed, blocked, and still blocked a cycle later.
    // Without this the arm-never-lost assertions could all be about the
    // degenerate case where `safe` is always high.
    f_c_waited  : cover (rst_n && past_ok && pending && !safe && $past(pending));

    // An arm arriving while one is already pending -- the absorbed case.
    f_c_rearm   : cover (rst_n && past_ok && arm && $past(pending) && !$past(safe));

    // An arm landing on the very cycle a commit is taken. This is the case the
    // arm-never-dropped assertion used to exclude, and the one where the priority
    // between `arm` and `commit` on pend_q decides whether an update survives.
    f_c_arm_on_commit : cover (rst_n && past_ok && arm && pending && safe);

    // The tearing scenario, published atomically: the two halves of the bundle
    // differ from each other AND from what was active a cycle ago, and they all
    // land on the same edge. This is the cover that says the atomicity assertion
    // is about a reachable situation and not a vacuous one.
    f_c_atomic  : cover (rst_n && past_ok && applied
                         && (active[0 +: DW] != active[DW +: DW])
                         && (active != $past(active, 2)));

    // Software still writing while a commit is outstanding: the hazard `lock`
    // exists to report. Reachable, so the lock is not dead logic.
    f_c_late_wr : cover (rst_n && past_ok && lock && (staged != sw_q));
  end

endmodule

`default_nettype wire
