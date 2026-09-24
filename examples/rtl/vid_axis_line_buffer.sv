// -----------------------------------------------------------------------------
// vid_axis_line_buffer.sv -- TAPS vertically-adjacent lines presented in
// parallel, for a vertical filter, at N pixels per clock.
//
// This is where N, P and B stop being an indexing exercise and start deciding
// the geometry of the memory:
//
//     line memory WIDTH  =  N * P * B          bits   (one whole beat)
//     line memory DEPTH  =  ceil(MAX_WIDTH / N) words
//     number of memories =  TAPS - 1
//
// Doubling N halves the depth and doubles the width. That is not free: block
// RAMs come in fixed aspect ratios, so a 4-pixel 10-bit RGB beat is 120 bits
// wide and will be built from several BRAMs in parallel whether the depth needs
// them or not. Sweeping N in this module is the cheapest way to see the shape of
// that trade-off before committing to it.
//
// Note `words_per_line` ROUNDS UP (vid_pkg.sv). A line whose width is not a
// multiple of N still needs a final partial beat, and a depth computed by
// truncating division is one word short for every such mode -- which corrupts
// exactly one pixel group per line, at the right-hand edge, in some resolutions
// only.
//
// THE STRUCTURE. TAPS-1 memories in a chain. Memory 0 is written with the
// current line and read one line later; memory i is written with what memory
// i-1 read. So memory i holds the line from i+1 lines ago, and the read outputs
// plus the current beat give TAPS vertically-adjacent lines at the same
// horizontal position.
//
// THE ALIGNMENT TRICK, which is the whole reason this works: the write address
// TRAILS the read address by one beat. Reads for word w are issued on the beat
// carrying word w and arrive a cycle later; the write of word w happens on that
// later beat, using the data that has just arrived. Two consequences, both
// wanted:
//
//   * every tap is aligned to the same word, with no per-tap delay matching.
//     The naive "read and write the same address" version needs i cycles of
//     skew correction on tap i, which is where hand-written line buffers go
//     wrong.
//   * the read and write addresses are never equal, so the same-address
//     read/write case -- which ram_sdp.sv documents as UNDEFINED, because the
//     primitive may be read-first or write-first -- simply never arises.
//
// EDGE_REPLICATE handles the top of the frame, where the history does not exist
// yet. With it set, taps beyond what has been stored repeat the oldest real
// line, which is the standard "clamp to edge" boundary for a vertical filter.
// Without it they read zero, which puts a dark band across the top of every
// frame -- occasionally what you want, usually a bug report.
// -----------------------------------------------------------------------------
`default_nettype none

module vid_axis_line_buffer #(
  parameter int unsigned N              = 2,    // PIXELS_PER_CLOCK
  parameter int unsigned P              = 3,    // COMPONENTS_PER_PIXEL
  parameter int unsigned B              = 8,    // BITS_PER_COMPONENT
  parameter int unsigned TAPS           = 3,    // lines presented in parallel
  parameter int unsigned MAX_WIDTH      = 64,   // pixels per line, worst case
  parameter int unsigned UW             = 1,
  parameter bit          EDGE_REPLICATE = 1'b1
) (
  input  var logic                    clk,
  input  var logic                    rst_n,

  input  var logic [N*P*B-1:0]        s_tdata,
  input  var logic                    s_tvalid,
  output var logic                    s_tready,
  input  var logic                    s_tlast,   // end of line
  input  var logic [UW-1:0]           s_tuser,   // bit 0 = start of frame

  // Row r at bit r*N*P*B. Row 0 is the current line, row r is r lines above it.
  output var logic [TAPS*N*P*B-1:0]   m_rows,
  output var logic                    m_tvalid,
  input  var logic                    m_tready,
  output var logic                    m_tlast,
  output var logic [UW-1:0]           m_tuser,
  // Bit r set means row r is real history rather than a replicated edge.
  output var logic [TAPS-1:0]         m_row_real
);

  localparam int unsigned BEAT_BITS = N * P * B;
  localparam int unsigned WORDS     = vid_pkg::words_per_line(MAX_WIDTH, N);
  localparam int unsigned AW        = (WORDS <= 1) ? 1 : $clog2(WORDS);
  localparam int unsigned LCW       = (TAPS <= 1) ? 1 : $clog2(TAPS);

  if (TAPS < 1) begin : g_chk_taps
    $error("vid_axis_line_buffer: TAPS must be >= 1");
  end
  if (WORDS < 2) begin : g_chk_words
    // The alignment trick needs the write address to trail the read address by
    // one word, which is only distinct if there are at least two of them.
    $error("vid_axis_line_buffer: MAX_WIDTH/N must give >= 2 words, got %0d",
           WORDS);
  end

  logic beat, do_write;
  assign beat     = s_tvalid && s_tready;
  assign s_tready = !m_tvalid || m_tready;


  // ---- horizontal position and vertical history ----------------------------
  logic [AW-1:0]  wcnt;         // word index of the beat arriving now
  logic [AW-1:0]  wcnt_d1;      // ...of the previous beat: the write address
  logic [LCW-1:0] lines_done;   // completed lines, saturating at TAPS-1

  logic [BEAT_BITS-1:0] d1_data;
  logic                 d1_last, d1_occupied;
  logic [UW-1:0]        d1_user;
  // The history count has to travel WITH the data, like every other sideband.
  // Using the live `lines_done` to decide which taps are real reads it one beat
  // too late: the end-of-line beat increments it, and the very next beat then
  // builds the rows for the PREVIOUS word while believing an extra line is
  // available -- so the top tap reads a line that was never written and the
  // output is X. This is the latency-matching discipline of docs/21, and a
  // counter is as much a sideband signal as TLAST is.
  logic [LCW-1:0]       d1_lines;

  // The write trails the read by one beat, so there is nothing to write until a
  // beat has been captured. Writing on the very first beat after reset would put
  // waddr and raddr both at word 0 -- the same-address case ram_sdp.sv documents
  // as UNDEFINED -- with meaningless data. Gating on `d1_occupied` skips that
  // write; the address is written correctly on the next beat anyway.
  assign do_write = beat && d1_occupied;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wcnt        <= '0;
      wcnt_d1     <= '0;
      lines_done  <= '0;
      d1_data     <= '0;
      d1_last     <= 1'b0;
      d1_user     <= '0;
      d1_occupied <= 1'b0;
      d1_lines    <= '0;
    end else if (beat) begin
      wcnt_d1     <= wcnt;
      wcnt        <= s_tlast ? '0 : (wcnt + 1'b1);
      d1_lines    <= lines_done;      // the count in force for THIS beat's word
      d1_data     <= s_tdata;
      d1_last     <= s_tlast;
      d1_user     <= s_tuser;
      d1_occupied <= 1'b1;

      // Start of frame throws the history away: the first line of a new frame
      // has no lines above it, and reusing the previous frame's bottom rows is
      // a wrap-around artefact that only shows on the first few lines.
      if (s_tuser[0])                      lines_done <= '0;
      else if (s_tlast && (lines_done != LCW'(TAPS - 1)))
                                           lines_done <= lines_done + 1'b1;
    end
  end

  // ---- the memory chain ----------------------------------------------------
  logic [BEAT_BITS-1:0] lb_rd [TAPS];   // lb_rd[0] unused; keeps indices aligned

  assign lb_rd[0] = '0;

  for (genvar t = 1; t < int'(TAPS); t++) begin : g_lb
    // Memory t-1 is written with the row above it in the chain: the current
    // beat for t==1, and the previous memory's read output otherwise.
    logic [BEAT_BITS-1:0] wdata;
    assign wdata = (t == 1) ? d1_data : lb_rd[t-1];

    ram_sdp #(.DW(BEAT_BITS), .DEPTH(WORDS), .AW(AW)) u_line (
      .clk   (clk),
      .we    (do_write),
      .waddr (wcnt_d1),      // trails the read by one word -- see the header
      .wdata (wdata),
      .re    (beat),
      .raddr (wcnt),
      .rdata (lb_rd[t])
    );
  end

  // ---- assemble the rows ---------------------------------------------------
  logic [BEAT_BITS-1:0] row [TAPS];
  logic [TAPS-1:0]      row_real;
  logic [BEAT_BITS-1:0] oldest_real;

  // The oldest row that actually holds history, selected as its own mux.
  //
  // The obvious way to write the clamp below is `row[lines_done]`, and it infers
  // a latch: that reads the very array this block is assigning, with a variable
  // index, so the result depends on statement order. It happens to be safe here
  // (the index is always an element already written) but the tool cannot know
  // that, and neither can the next reader. Computing the source separately
  // removes the self-reference instead of arguing about it.
  always_comb begin
    oldest_real = d1_data;                       // d1_lines == 0
    for (int t = 1; t < int'(TAPS); t++)
      if (LCW'(t) == d1_lines) oldest_real = lb_rd[t];
  end

  always_comb begin
    row[0]      = d1_data;
    row_real[0] = 1'b1;
    for (int t = 1; t < int'(TAPS); t++) begin
      if (LCW'(t) <= d1_lines) begin
        row[t]      = lb_rd[t];
        row_real[t] = 1'b1;
      end else begin
        // Not stored yet: clamp to the oldest real row, or read zero.
        row[t]      = EDGE_REPLICATE ? oldest_real : '0;
        row_real[t] = 1'b0;
      end
    end
  end

  logic [TAPS*BEAT_BITS-1:0] rows_packed;

  for (genvar t = 0; t < int'(TAPS); t++) begin : g_pack
    assign rows_packed[t*BEAT_BITS +: BEAT_BITS] = row[t];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_tvalid   <= 1'b0;
      m_rows     <= '0;
      m_tlast    <= 1'b0;
      m_tuser    <= '0;
      m_row_real <= '0;
    end else if (beat && d1_occupied) begin
      m_tvalid   <= 1'b1;
      m_rows     <= rows_packed;
      m_tlast    <= d1_last;
      m_tuser    <= d1_user;
      m_row_real <= row_real;
    end else if (m_tvalid && m_tready) begin
      m_tvalid   <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  a_tvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_rows)
                                          && $stable(m_tlast)));

  // Row 0 is always real; it is the beat that just arrived.
  a_row0_real: assert property (@(posedge clk) disable iff (!rst_n)
    m_tvalid |-> m_row_real[0]);

  // Real rows are contiguous from 0: history fills from the nearest line
  // outwards, so a gap would mean the chain was written out of order.
  a_real_contiguous: assert property (@(posedge clk) disable iff (!rst_n)
    m_tvalid |-> ((m_row_real & (m_row_real + 1'b1)) == '0))
    else $error("line_buffer: row_real %b is not contiguous", m_row_real);

  // The write address must never equal the read address on a cycle that writes,
  // or the RAM's same-address behaviour -- which ram_sdp documents as undefined
  // -- decides the output. This is the alignment trick, asserted rather than
  // assumed.
  //
  // It also enforces the module's one requirement on the stream: A LINE MUST BE
  // AT LEAST TWO BEATS. With a single-beat line the word counter never leaves
  // zero, so the read and write addresses are permanently equal and the
  // structure cannot work. That is pathological for a line buffer -- a vertical
  // filter on an image N pixels wide -- but it is better to say so here than to
  // return quiet nonsense.
  a_addr_distinct: assert property (@(posedge clk) disable iff (!rst_n)
    do_write |-> (wcnt != wcnt_d1))
    else $error("line_buffer: read/write address collision at %0d -- is a line only one beat long?", wcnt);
`endif

endmodule

`default_nettype wire
