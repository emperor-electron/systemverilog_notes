// -----------------------------------------------------------------------------
// select_styles.sv -- one function, four control structures, and the one
// difference that matters.
//
// The function: given a 4-bit request vector and four data words, produce the
// data belonging to the LOWEST-numbered set request, or zero if none is set.
// It is the inner loop of every arbiter, every interrupt controller and every
// bus decoder, so it is worth knowing what each way of writing it builds.
//
//   d_if     if / else-if chain        priority, N levels deep
//   d_casez  casez with don't-cares    priority, N levels deep
//   d_loop   for loop over the bits    priority, N levels deep
//   d_par    AND-OR of all lanes       PARALLEL, constant depth
//
// The first three are the same circuit written three ways -- a chain of muxes
// whose depth grows with N. formal/select_styles_fv.sby proves all three equal
// for every input, which is the point: the choice between them is taste, not
// function.
//
// The fourth is a different circuit. It is what synthesis builds when you write
// `unique case (1'b1)`, and it is genuinely faster -- constant depth instead of
// N. It is also NOT equivalent to the other three unless at most one request
// bit is set, and the proof says so: `d_par` matches only under $onehot0(req),
// and there is a cover showing a case where they differ.
//
// That inequivalence is the whole content of the word `unique`. Writing it is
// a promise about the inputs, and this module is where the promise is made
// visible instead of assumed.
//
// See docs/27-control-structures.md.
// -----------------------------------------------------------------------------
`default_nettype none

module select_styles #(
  parameter int unsigned W = 8
) (
  input  var logic [3:0]     req,
  input  var logic [4*W-1:0] data,     // {d3, d2, d1, d0}, lane i at [i*W +: W]
  output var logic [W-1:0]   d_if,
  output var logic [W-1:0]   d_casez,
  output var logic [W-1:0]   d_loop,
  output var logic [W-1:0]   d_par
);

  // A local unpacked array is fine; an unpacked array PORT is not, because the
  // Yosys frontend rejects it (docs/25). Hence the flat `data` port and this
  // unpack, which costs nothing -- it is pure renaming at elaboration.
  logic [W-1:0] d [4];
  always_comb begin
    for (int i = 0; i < 4; i++) d[i] = data[i*W +: W];
  end

  // ---- 1. if / else-if chain -----------------------------------------------
  // Reads as a list of rules in priority order, which is usually what the
  // specification says. Builds a chain: lane 3 passes through four muxes.
  always_comb begin
    if      (req[0]) d_if = d[0];
    else if (req[1]) d_if = d[1];
    else if (req[2]) d_if = d[2];
    else if (req[3]) d_if = d[3];
    else             d_if = '0;        // the `else` is what prevents a latch
  end

  // ---- 2. casez with don't-cares -------------------------------------------
  // The same priority, expressed as patterns. More compact for wide vectors and
  // it puts the priority in the pattern where you can see it, but the patterns
  // must be written so they cannot overlap ambiguously.
  //
  // `casez` and not `casex`: casez treats only Z and ? as wildcards, while
  // casex also treats X in the CASE EXPRESSION as a wildcard -- so an unknown
  // request would match the first pattern and be granted. See docs/24.
  always_comb begin
    casez (req)
      4'b???1: d_casez = d[0];
      4'b??10: d_casez = d[1];
      4'b?100: d_casez = d[2];
      4'b1000: d_casez = d[3];
      default: d_casez = '0;
    endcase
  end

  // ---- 3. for loop over the bits -------------------------------------------
  // The only one of the four that parameterises without being rewritten: change
  // the bound and it still works. A loop in an always_comb is UNROLLED at
  // elaboration -- it is not a loop in hardware, it is a way of writing four
  // copies of something without typing four copies.
  //
  // Written with a `found` flag rather than `break`. `break` says the same
  // thing more directly and XSIM and Vivado both accept it, but the Yosys
  // frontend rejects it outright ("Can't resolve task name `break'"), which
  // would put this whole module outside the formal flow. The flag form costs
  // nothing: because the loop is unrolled, `found` is just a wire.
  always_comb begin
    logic found;
    found  = 1'b0;
    d_loop = '0;
    for (int i = 0; i < 4; i++) begin
      if (req[i] && !found) begin
        d_loop = d[i];
        found  = 1'b1;
      end
    end
  end

  // ---- 4. parallel AND-OR --------------------------------------------------
  // What `unique case (1'b1)` compiles to: every lane is masked by its own
  // request and the results are OR-ed. Depth is one AND plus a log-depth OR
  // tree, independent of N -- for a 32-entry decoder that is the difference
  // between 32 mux levels and about 6.
  //
  // It computes something DIFFERENT when two request bits are set: the OR of
  // two data words, which is not either of them. That is not a bug in this
  // code, it is the cost of the speed, and it is why `unique` is a promise
  // rather than an optimisation switch.
  always_comb begin
    d_par = '0;
    for (int i = 0; i < 4; i++) d_par |= {W{req[i]}} & d[i];
  end

// No assertions here: every signal these properties talk about is a port, so
// they belong to the caller. They live in formal/select_styles_fv.sv, which
// proves the three priority forms equal for EVERY input and the parallel form
// equal exactly under $onehot0(req). A concurrent SVA property would also need
// a clocking event this module does not have, and an immediate assertion in an
// always_comb would fire on the deltas where the four blocks have not yet
// settled -- neither is the right tool for a combinational equivalence.

endmodule

`default_nettype wire
