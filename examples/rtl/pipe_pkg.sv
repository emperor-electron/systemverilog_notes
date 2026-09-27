// -----------------------------------------------------------------------------
// pipe_pkg.sv -- elaboration-time helpers shared by a datapath and the control
// that drives it.
//
// There is exactly one function here, and it exists because the datapath's cut
// mask and the control block's stage count are the same number computed twice.
// Two copies of that arithmetic is two chances to disagree, and the failure mode
// -- a pipeline whose valid bits are a different depth from its data -- looks
// like data corruption rather than like a parameter mistake.
//
// Referenced fully scoped as `pipe_pkg::cuts_below(...)`: the Yosys frontend
// rejects `import pkg::*;` in a module body and CRASHES on one at compilation
// unit scope (docs/37 section 13).
// -----------------------------------------------------------------------------
package pipe_pkg;

  // How many of the low `k` bits of the cut mask `m` are set.
  //
  //   cuts_below(CUTS, 4)  = the pipeline's latency in cycles
  //   cuts_below(CUTS, k)  = which control stage owns cut k
  //
  // Both uses are elaboration-time, so this is notation and not a circuit.
  function automatic int unsigned cuts_below(input logic [3:0] m,
                                            input int unsigned k);
    cuts_below = 0;
    for (int i = 0; i < 4; i++)
      if ((i < int'(k)) && m[i]) cuts_below = cuts_below + 1;
  endfunction

endpackage
