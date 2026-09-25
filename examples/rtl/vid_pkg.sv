// -----------------------------------------------------------------------------
// vid_pkg.sv -- the layout convention for parameterized video on AXI-Stream.
//
// A video stream carrying N pixels per clock, P components per pixel and B bits
// per component needs N*P*B bits of TDATA, and the ONLY thing that makes such a
// bus interoperable is agreement about which bits are which. That agreement is
// this file, so it is written down once instead of re-derived (differently) in
// every module.
//
// THE CONVENTION: component-minor, pixel-major.
//
//   bit index of component p of pixel n  =  ((n * P) + p) * B
//
//   N=2, P=3, B=8 (two RGB pixels per clock), TDATA[47:0]:
//
//     47        40 39        32 31        24 23        16 15         8 7          0
//   +------------+------------+------------+------------+------------+------------+
//   | pix1 comp2 | pix1 comp1 | pix1 comp0 | pix0 comp2 | pix0 comp1 | pix0 comp0 |
//   +------------+------------+------------+------------+------------+------------+
//    \________ pixel 1 _________________/  \________ pixel 0 _________________/
//
// WHY THIS ORDER AND NOT THE OTHER. The alternative -- all of component 0 for
// every pixel, then all of component 1 -- is component-major, and it is what you
// get if you think of the bus as P planes. Pixel-major wins for a streaming bus
// because a whole pixel is then a CONTIGUOUS FIELD: extracting pixel n is one
// part-select, and changing N does not move the components around within a
// pixel. Component-major makes N*P*B-bit words whose meaning shifts every time N
// changes, which is precisely the parameter most likely to change late.
//
// It is also the convention Xilinx's AXI4-Stream Video IP uses, which matters
// more than any argument above if you ever have to interoperate.
//
// SIDEBAND, also following the AXI4-Stream Video convention:
//   TLAST     end of line
//   TUSER[0]  start of frame, asserted on the first pixel of the first line
//
// A NOTE ON REFERENCING THIS PACKAGE. Every use below is written out in full as
// `vid_pkg::comp_lsb(...)`. That is not style: the Yosys frontend rejects
// `import pkg::*;` inside a module body, and a compilation-unit-scope import
// crashes it outright with an internal assertion failure. The scoped form is
// the only one all three tools here accept, so the modules avoid the formal
// flow's limitation rather than working around it later. See docs/25.
// -----------------------------------------------------------------------------
package vid_pkg;

  // Bit position of component `p` of pixel `n`, for a stream of P components
  // per pixel and B bits per component.
  function automatic int unsigned comp_lsb(input int unsigned n, p, P, B);
    comp_lsb = ((n * P) + p) * B;
  endfunction

  // Bit position of the first component of pixel `n`.
  function automatic int unsigned pix_lsb(input int unsigned n, P, B);
    pix_lsb = (n * P) * B;
  endfunction

  // Total TDATA width for a given configuration.
  function automatic int unsigned tdata_bits(input int unsigned N, P, B);
    tdata_bits = N * P * B;
  endfunction

  // Bit position of component `p` of pixel `n` in row `r` of a bundle of
  // stacked rows, each `cols` pixels wide.
  //
  // This is the whole reason there is only ONE indexing rule in this family. A
  // bundle of TAPS rows from a line buffer, and a window of ROWS x (N+2H)
  // pixels, are both just longer pixel arrays in the same layout, so flattening
  // (r, n) into a single pixel index r*cols + n makes comp_lsb serve all three.
  // Pass N for a row bundle and N+2H for a window.
  function automatic int unsigned rowpix_lsb(input int unsigned r, n, p,
                                             cols, P, B);
    rowpix_lsb = comp_lsb((r * cols) + n, p, P, B);
  endfunction

  // Columns in a window of N pixels per clock with a halo of `halo` pixels on
  // each side. A halo of `halo` needs `halo` pixels from the beat before and
  // after, so it requires halo <= N -- otherwise the window spans more than
  // three beats and one beat of lookahead is not enough.
  function automatic int unsigned win_cols(input int unsigned N, halo);
    win_cols = N + (2 * halo);
  endfunction

  // Words needed to carry a line of `width` pixels at N pixels per clock,
  // rounded up: a line whose width is not a multiple of N still needs a final
  // partial word, and a line buffer sized by truncating division is short by one
  // for every such mode.
  function automatic int unsigned words_per_line(input int unsigned width, N);
    words_per_line = (width + N - 1) / N;
  endfunction

endpackage
