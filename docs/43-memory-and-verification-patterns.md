# Memory and Verification Patterns

Ten entries: five about getting data into and out of storage, five about being able to
tell whether any of it works. The template and the six currencies are in
[docs/40](40-rtl-design-patterns.md).

The verification group is the one where a pattern's *absence* is hardest to notice,
because a design with no assertions and no counters looks exactly like a design with
them until something goes wrong in the field. Four of its five entries cost almost
nothing and have to be decided before the design is finished rather than after.

---

## Contents

**Memory and buffering** —
[1 Ring Buffer](#1-ring-buffer) ·
[2 Line Buffer / Sliding Window](#2-line-buffer--sliding-window) ·
[3 Memory Banking / Port Multiplication](#3-memory-banking--port-multiplication) ·
[4 Read-Latency Compensation](#4-read-latency-compensation) ·
[5 Content-Addressable Lookup](#5-content-addressable-lookup)

**Verification and observability** —
[6 Interface Assertions](#6-interface-assertions-sva-contract) ·
[7 Bind-In Checker](#7-bind-in-checker) ·
[8 Debug Hooks](#8-debug-hooks) ·
[9 Performance Counters](#9-performance-counters) ·
[10 Loopback / BIST Mode](#10-loopback--bist-mode)

---

# Memory and buffering

## 1. Ring Buffer

**Intent.** Turn a RAM plus two pointers into a queue.

**Motivation.** A queue in hardware is a memory, a write pointer, a read pointer and a
way to tell full from empty. The entire difficulty is that last part: when the two
pointers are equal the buffer is either completely empty or completely full, and the
pointers alone cannot say which.

**Applicability.** Use it for every FIFO, and for any history buffer where you need the
last N samples. **Do not use it** where the access pattern is not FIFO — a ring buffer
with random access is just a RAM with confusing pointer names — and do not use it at
depth 2, where a [skid buffer](41-structural-and-behavioral-patterns.md#2-skid-buffer-full-register-slice)
is smaller and has fixed latency.

**Structure.** Three ways to resolve full-versus-empty, and they are not equivalent:

```systemverilog
// (a) An extra pointer bit. Pointers are AW+1 bits; equal low bits with differing
//     top bits means full. Exact, costs one bit per pointer. Best for a CDC, where
//     a separate counter would itself have to cross.
// (b) An occupancy counter. sync_fifo.sv does this: `level` is maintained directly,
//     which also gives the threshold flags for free.
// (c) A "last operation was a write" flag. Cheapest, and wrong for a CDC because
//     the flag is in neither domain.
assign almost_full  = (level >= (AW+1)'(DEPTH - 1));
assign almost_empty = (level <= (AW+1)'(1));
```

**Consequences.** *Buys:* a queue of any depth for one memory and two counters, and on
an FPGA the memory is often free (a block RAM you were not otherwise using). *Costs:*
the read latency of the memory, which for a BRAM is one or two cycles and changes the
flag timing; and pointer comparators whose depth grows with the address width.

**Implementation.**
1. **Choose the full/empty scheme for the domain you are in.** The extra-pointer-bit
   scheme survives a CDC; an occupancy counter does not, because it belongs to neither
   side.
2. **`full` must be usable combinationally by the writer.** A registered `full` overruns
   by one, and in an async FIFO that is the signature bug.
3. **A non-power-of-two depth breaks pointer wrapping and Gray coding.** Either round up
   or write the wrap explicitly and test it.
4. **Test the wrap, the full-to-empty transition and the simultaneous read/write.**
   Those three are where the pointer arithmetic is wrong, and none of them happens in a
   short random test. [`fifo_tb.sv`](../examples/tb/fifo_tb.sv) uses a queue scoreboard
   so the order is checked, not just the count.

**Known uses.** [`sync_fifo.sv`](../examples/rtl/sync_fifo.sv)
([`sync_fifo_fv.sby`](../formal/sync_fifo_fv.sby)),
[`async_fifo.sv`](../examples/rtl/async_fifo.sv) (extra-bit scheme with Gray pointers),
[`vid_axis_line_buffer.sv`](../examples/rtl/vid_axis_line_buffer.sv) (a ring of whole
lines), the two FIFOs inside [`uart_periph.sv`](../examples/rtl/uart_periph.sv).

**Related.** [#4 FIFO Decoupler](41-structural-and-behavioral-patterns.md#4-fifo-decoupler)
(what it is for), [#4 Async FIFO](42-clocking-elaboration-and-timing-patterns.md#4-async-fifo-gray-pointers),
[#22 Ping-Pong Buffer](41-structural-and-behavioral-patterns.md#22-ping-pong-double-buffer),
[#4 Read-Latency Compensation](#4-read-latency-compensation).

---

## 2. Line Buffer / Sliding Window

**Intent.** Present a 2-D neighbourhood from a 1-D raster stream.

**Motivation.** A 3×3 filter needs nine pixels that in the stream are separated by two
line lengths. Storing whole frames is unnecessary and slow; storing *R−1* lines is
enough, and then the window is those lines read in parallel plus a short horizontal
shift register. The interesting difficulty is not the storage, it is the edges.

**Applicability.** Use it for any neighbourhood operation on a raster stream:
convolution, median, morphology, motion estimation. **Do not use it** when the
neighbourhood is large enough that R lines exceed the available memory — then you need
tiling, which is a different design — and do not use it for an operation that needs
random access to the frame.

**Structure.** Two halves. The vertical half is a ring of lines; the horizontal half is
where the **halo** lives:

```systemverilog
// vid_axis_win3.sv -- at N pixels per clock, a 3-wide horizontal window needs one
// pixel from each NEIGHBOURING beat, so the module needs ONE BEAT OF LOOKAHEAD.
// It stores only one pixel per row of the previous beat, not the whole beat.
assign out_ready = !m_tvalid || m_tready;
assign s_ready   = !c_valid || out_ready;
assign load      = s_tvalid && s_tready;
assign emit      = c_valid && out_ready && (c_last || s_tvalid);
```

**Consequences.** *Buys:* a 2-D window from a 1-D stream for (R−1) lines of storage
instead of a frame. *Costs:* (R−1) line buffers — usually block RAM, and the count is
fixed by the kernel height; a latency of (R−1)/2 lines plus one beat; and an edge policy
that must be chosen and implemented.

**Implementation.**
1. **The halo needs one beat of lookahead, and the halo width must not exceed N.** At N
   pixels per clock a 3-wide window straddles beat boundaries, so the module cannot emit
   a beat until it has seen the next one. A halo of H requires H ≤ N, and that is a
   parameter constraint to check at elaboration.
2. **Choose the edge policy explicitly: clamp, mirror, or shrink.** And then remember
   that **clamp-to-edge replicates**, so an "isolated" impulse at a corner appears in six
   of the nine taps — which makes an impulse-response test at the edge meaningless.
   [docs/37](37-parameterized-video-pipelines.md) records getting that wrong.
3. **One indexing rule, in a package, for the bus and the window alike.** Two copies of
   "where is component p of pixel n" is two chances to disagree, and the failure looks
   like a colour swap rather than a parameter mistake.
4. **A neighbourhood pipeline cannot be drained by waiting.** Stale beats from a previous
   frame appear as the next frame's first outputs, with `tlast` in the wrong place one
   frame later. Reset between frames, or flush explicitly.
5. **Prove the halo replication rather than eyeballing it.** It is a structural property
   and it is cheap to state.

**Known uses.** [`vid_axis_line_buffer.sv`](../examples/rtl/vid_axis_line_buffer.sv)
(TAPS lines in parallel), [`vid_axis_win3.sv`](../examples/rtl/vid_axis_win3.sv)
(R × (N+2) window, proved in [`vid_axis_win3_fv.sby`](../formal/vid_axis_win3_fv.sby)),
consumed by [`vid_axis_median3.sv`](../examples/rtl/vid_axis_median3.sv) and
[`vid_axis_sobel.sv`](../examples/rtl/vid_axis_sobel.sv).

**Related.** [#1 Ring Buffer](#1-ring-buffer),
[#22 Ping-Pong Buffer](41-structural-and-behavioral-patterns.md#22-ping-pong-double-buffer),
[#10 Parameterized Generator](42-clocking-elaboration-and-timing-patterns.md#10-parameterized-generator),
[docs/37](37-parameterized-video-pipelines.md).

---

## 3. Memory Banking / Port Multiplication

**Intent.** Get more ports than the primitive has.

**Motivation.** A block RAM has two ports. A design that needs four simultaneous reads
has to build them, and there are three ways: replicate the memory (4× the storage, any
number of read ports, one write port), bank it by address (no extra storage, but only if
the accesses never collide), or keep a live-value table (complex, exact). Which one you
can use is decided by the access pattern, not by preference.

**Applicability.** Use replication when reads dominate and the memory is small — a
register file, a coefficient table. Use banking when the addresses are *provably*
distinct, which usually means they are derived from different index bits. **Do not** bank
on hope: two accesses to the same bank in one cycle need an arbiter and a stall, and if
you have not designed for that, the design silently drops one.

**Structure.** Four approaches, with their real costs. The first is the one people
forget, and it is what a register file actually is:

```systemverilog
// (a) A FLOP ARRAY WITH COMBINATIONAL READ MUXES -- as many read ports as you like,
//     each one a mux over all N entries. No RAM primitive involved at all, which is
//     why it scales with N x DW in fabric and only suits small arrays.
//     regfile.sv does this: ONE array, two asynchronous reads.
logic [DW-1:0] regs [0:N-1];
assign rdata0 = regs[raddr0];         // a mux over N, not a memory port
assign rdata1 = regs[raddr1];

// (b) REPLICATION -- N copies of a real memory. Every copy gets every write, so
//     writes are unchanged and reads are free. N x the storage.
// (c) BANKING -- split by low address bits. Free, if accesses never collide.
//     Needs an arbiter and a stall path if they can.
// (d) LIVE-VALUE TABLE -- a small table recording which bank holds the current
//     value of each address. Exact for multi-write, and the most complex.
```

**Consequences.** Read muxes: *buy* any number of ports and zero read latency, *cost*
N × DW of fabric and a mux whose depth grows with N — fine at 32 entries, hopeless at
4096. Replication: *buys* read ports, *costs* N× storage and a write that must reach
every copy. Banking: *buys* ports for free, *costs* a collision case you must handle.
LVT: *buys* exactness, *costs* a second memory and real complexity.

**Implementation.**
1. **Pick by size first.** Read muxes for tens of entries, a memory primitive for
   thousands. Getting this backwards is the commonest mistake: a 4096-entry flop array
   will not fit, and a 32-entry BRAM wastes a block RAM and adds a cycle of latency.
2. **Write to every replica, every time.** A missed write makes one port return stale
   data — intermittently, depending on which port reads it.
3. **A banking scheme needs its non-collision argument written down.** "The accesses are
   to different banks" is a claim about the *algorithm*, and when the algorithm changes
   the memory silently breaks. Assert it.
4. **Asynchronous reads keep a memory out of block RAM, and that is sometimes the
   point.** [`regfile.sv`](../examples/rtl/regfile.sv) breaks the inference rules
   deliberately because a two-async-read register file cannot be a BRAM, and its header
   says so. Breaking a rule with a stated reason is a pattern; breaking it silently is
   [A6](40-rtl-design-patterns.md#a6-asynchronous-reset-on-datapath-registers)'s cousin.
5. **Check what you got.** `stat`, or the utilisation report. Four replicas of a memory
   that did not infer is 4× a bad outcome.

**Known uses.** [`regfile.sv`](../examples/rtl/regfile.sv) (form (a): one array, two
asynchronous read muxes — deliberately *not* a BRAM, and its header says that is the
point), [`ram_tdp.sv`](../examples/rtl/ram_tdp.sv) (the two ports the primitive does
have, with independent clocks). **Replication, banking and the live-value table are
sketches** — none of the three is built here. [docs/29](29-memories-and-inference.md) covers port configurations and collisions.

**Related.** [#13 Inference Template](42-clocking-elaboration-and-timing-patterns.md#13-inference-template),
[#19 Arbiter](41-structural-and-behavioral-patterns.md#19-arbiter),
[#20 Resource Sharing](41-structural-and-behavioral-patterns.md#20-resource-sharing-time-multiplexing).

---

## 4. Read-Latency Compensation

**Intent.** Delay the control to match the memory's own output latency.

**Motivation.** A block RAM's data arrives one cycle after the address, and two if you
use its output register. Every signal that travels *with* that data — a valid bit, a tag,
a destination, a byte enable — must be delayed by exactly the same amount. Get it wrong
by one and the data is correct but attached to the wrong metadata, which downstream is
indistinguishable from corruption.

**Applicability.** Use it wherever a memory read is in a pipeline. **Do not** solve it by
*removing* the memory's output register to make the latency 1 — that register is often
what makes the BRAM meet timing, and giving it up to simplify the bookkeeping is a bad
trade.

**Structure.** A delay line for the sideband, parameterised by the same number:

```systemverilog
// pipe_delay.sv -- N-cycle delay for latency matching. The parameter should come
// from ONE definition shared with the memory's configuration, not be written twice.
pipe_delay #(.WIDTH($bits(tag_t)), .DEPTH(RAM_LATENCY)) u_tag_dly (
  .clk, .rst_n, .en(advance), .din(tag_in), .dout(tag_out));
```

**Consequences.** *Buys:* metadata that arrives with its data. *Costs:* WIDTH ×
LATENCY flops (or one SRL per 16–32 if there are no taps and no reset —
[#22](42-clocking-elaboration-and-timing-patterns.md#22-srl-delay-line)); and a latency
number that now appears in two places and must not diverge.

**Implementation.**
1. **The latency must be one definition, shared.** A `localparam RAM_LATENCY` used by
   both the memory instantiation and the delay line. Two literals is
   [#11 Configuration Package](42-clocking-elaboration-and-timing-patterns.md#11-configuration-package)'s
   cautionary case.
2. **The delay must be gated by the same enable as the memory read.** A stalled pipeline
   whose sideband keeps advancing re-attaches every tag to the wrong beat — the same class
   of bug as a travelling configuration that is not gated by `en`, measured in
   [docs/39 §7](39-control-registers-and-safe-reconfiguration.md#7-reconfiguring-a-pipeline-quiesce-or-travel).
3. **Use an SRL if there are no taps and no reset needed;** flops otherwise. The choice
   is [#22](42-clocking-elaboration-and-timing-patterns.md#22-srl-delay-line) versus
   `pipe_delay`.
4. **Test it by making the sideband a sequence number.** If tag N ever arrives with data
   M, one assertion catches it — and a fixed tag catches nothing.

**Known uses.** [`pipe_delay.sv`](../examples/rtl/pipe_delay.sv) (exact latency tested at
0, 1, 3 and 7 plus a stall, in [`pipeline_tb.sv`](../examples/tb/pipeline_tb.sv));
[`ram_sp.sv`](../examples/rtl/ram_sp.sv) and the RAM family document their latency in
their headers; [`vid_axis_line_buffer.sv`](../examples/rtl/vid_axis_line_buffer.sv) does
it internally for its tap alignment.

**Related.** [#22 SRL Delay Line](42-clocking-elaboration-and-timing-patterns.md#22-srl-delay-line),
[#17 Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline),
[#13 Inference Template](42-clocking-elaboration-and-timing-patterns.md#13-inference-template),
[docs/29](29-memories-and-inference.md).

---

## 5. Content-Addressable Lookup

**Intent.** Search by value instead of by address.

**Motivation.** A cache tag check, a MAC address table, a flow classifier: the question
is "which entry holds this key", and a RAM cannot answer it. A true CAM compares all
entries in parallel — one cycle, and expensive. A hash table trades that certainty for
area.

**Applicability.** Use a **small fully-parallel CAM** (tens of entries) when you need a
single-cycle answer and a definite one: cache tags, a TLB, a reorder buffer's tag
lookup. Use a **hash table** for large key spaces where an occasional collision is
acceptable and can be resolved over several cycles. **Do not** build a large parallel
CAM in FPGA fabric: the comparator array grows with entries × key width and it will
dominate the design.

**Structure.** *Sketch only.* The parallel form, and the reason it does not scale:

```systemverilog
// Sketch. ENTRIES comparators of KEYW bits each, plus a priority encoder.
// Area is ENTRIES * KEYW, which is why this is a tens-of-entries pattern.
logic [ENTRIES-1:0] hit;
for (genvar e = 0; e < ENTRIES; e++)
  assign hit[e] = valid_q[e] && (key_q[e] == lookup_key);

assign found = |hit;
priority_encoder #(.N(ENTRIES)) u_pe (.in(hit), .idx(match_idx));

// a_unique: assert property (@(posedge clk) $onehot0(hit));   // no duplicate keys
```

**Consequences.** Parallel CAM: *buys* a one-cycle definite answer; *costs* area
proportional to entries × key width, and a wide OR whose depth grows too. Hash table:
*buys* scale; *costs* a collision path, which means the lookup latency is now variable
and the design needs a stall.

**Implementation.**
1. **Assert that keys are unique.** `$onehot0(hit)` — a duplicate key makes the priority
   encoder pick one arbitrarily, and the bug is that it depends on insertion order.
2. **Invalidation is as important as insertion.** A stale valid bit returns a hit for a
   key that has been removed, which is worse than a miss.
3. **The full and empty cases are the bugs.** A lookup in an empty CAM, and an insert
   into a full one, are the two paths nobody tests.
4. **On an FPGA, consider the built-in alternative first.** Some architectures can use a
   LUTRAM-based CAM far more cheaply than a comparator array; check before building.

**Known uses.** *Sketch only.* [`priority_encoder.sv`](../examples/rtl/priority_encoder.sv)
is the match-resolution half and is proved exhaustively;
[`crc_parallel.sv`](../examples/rtl/crc_parallel.sv) is the hashing primitive a hash
table would use. [docs/29](29-memories-and-inference.md) covers the memory side.

**Related.** [#24 Tagged Transactions](41-structural-and-behavioral-patterns.md#24-tagged-transactions--reorder-buffer),
[#3 Memory Banking](#3-memory-banking--port-multiplication),
[#19 Arbiter](41-structural-and-behavioral-patterns.md#19-arbiter) (the priority encoder
inside it is the same circuit).

---

# Verification and observability

## 6. Interface Assertions (SVA Contract)

*Analogue: Meyer's **Design by Contract**, not GoF.*

**Intent.** Write the protocol's rules at the port, where they are checked by every test
that ever drives it.

**Motivation.** A protocol rule written in a document is checked by review. The same rule
written as an assertion at the port is checked by every simulation, every regression and
every future integration — including the ones nobody thought about. And when it fails, it
fails *at the interface*, which is where the bug is, rather than three modules
downstream where the symptom is.

**Applicability.** Put them on every interface with a protocol: handshakes, buses,
memories, anything with a contract. **Do not** write assertions that restate the
implementation — `assert (q == q)` is a tautology with a cost. And do not use them where
a *proof* is available and cheap; an assertion samples, a proof searches.

**Structure.** The rules that recur, and where they live:

```systemverilog
// At a stream port -- the producer's obligation, checked at the consumer.
a_hold: assert property (@(posedge clk) disable iff (!rst_n)
  (m_valid && !m_ready) |=> (m_valid && $stable(m_data)))
  else $error("withdrew or altered an unaccepted beat");

// A same-cycle race, stated so it cannot be resolved the wrong way.
a_set_wins: assert property (@(posedge clk) disable iff (!rst_n)
  (|status_set) |=> ((status_q & $past(status_set)) == $past(status_set)))
  else $error("a hardware-set status bit was lost to a clear");
```

**Consequences.** *Buys:* the rule is checked everywhere, for ever, and the failure is
localised. *Costs:* simulation time; and — the real cost — an assertion that is *wrong*
is worse than none, because it fails on correct designs and gets commented out.

**Implementation.**
1. **Properties belong where the state is.** An assertion about beats in flight needs the
   per-stage valid bits, so it belongs inside the module, not in the harness. Put in the
   harness only what the harness knows: the stimulus's obligations.
2. **A failing assertion must fail the build.** A concurrent assertion calls `$error` and
   the simulator carries on, so a testbench whose own checks pass will print PASS with
   failures scrolling above it. The build here greps for both:
   `*** printed PASS but SVA assertions FAILED ***`.
3. **A property about a registered signal is a statement about an *edge*, not about
   now.** `!en |=> $stable(x)` is wrong if `en` fell after the edge that mattered; the
   condition you want is the enable that *governed* that edge. This cost two separate
   debugging sessions in [docs/39](39-control-registers-and-safe-reconfiguration.md#8-reconfiguring-an-fsm-snapshot-at-the-start),
   and it is the commonest mistake in this list.
4. **State occupancy as an equality, not a bound.** `in − out == occupancy` is provable
   by induction; `occupancy <= 2` is equally true and returns UNKNOWN.
5. **Know what the tools cannot read.** The Yosys frontend rejects all of SVA's temporal
   layer, so a module needs a `ifdef FORMAL` block of plain immediate assertions
   alongside its `ifndef SYNTHESIS` SVA. [docs/25](25-formal-verification-with-sby.md)
   has the full list.

**Known uses.** Nearly every module here; the clearest are
[`axil_slave.sv`](../examples/rtl/axil_slave.sv) (the three AXI rules as assertions),
[`csr_bank.sv`](../examples/rtl/csr_bank.sv) (set-beats-clear),
[`cfg_burst_fsm.sv`](../examples/rtl/cfg_burst_fsm.sv) (ten properties, six promises and
four invariants), [`pipe_ripple_ctrl.sv`](../examples/rtl/pipe_ripple_ctrl.sv)
(occupancy as an exact equality).

**Related.** [#7 Bind-In Checker](#7-bind-in-checker),
[#14 Elaboration-Time Assertion](42-clocking-elaboration-and-timing-patterns.md#14-elaboration-time-assertion)
(the build-time counterpart), [docs/12](12-assertions-sva.md),
[docs/25](25-formal-verification-with-sby.md).

---

## 7. Bind-In Checker

**Intent.** Attach assertions and monitors to RTL you must not edit.

**Motivation.** Third-party IP, legacy code, generated code, or simply a file under
change control: you want the protocol checked and you cannot add lines to the module.
`bind` attaches a checker module to every instance of a target, from a separate file,
without touching it.

**Applicability.** Use it for RTL you cannot or should not edit, and for keeping a large
body of checkers out of the design files — which is also a reasonable choice for your own
code, when the checkers would otherwise dominate the module. **Do not** use it as the
default for your own RTL: an assertion next to the logic it describes is read by everyone
who reads the logic, and one in another file is not.

**Structure.** A checker module with the target's ports, and one line to attach it:

```systemverilog
// fifo_checker.sv -- an ordinary module that happens to contain only properties.
module fifo_checker #(parameter int DEPTH = 8) (
  input logic clk, rst_n, wr, rd, full, empty);
  a_no_overflow : assert property (@(posedge clk) disable iff (!rst_n)
                                   !(wr && full));
  a_no_underflow: assert property (@(posedge clk) disable iff (!rst_n)
                                   !(rd && empty));
endmodule

// tb.sv or a separate bind file -- attaches to EVERY instance of `fifo`,
// including ones added later.
bind fifo fifo_checker #(.DEPTH(DEPTH)) u_chk (.*);
```

**Consequences.** *Buys:* checking without editing; one checker covering every instance,
including future ones; and a clean separation between design and verification files.
*Costs:* the checker's ports must track the target's, so a port rename breaks it in a way
the compiler reports only at elaboration; and the properties are now somewhere a reader
of the design will not see them.

**Implementation.**
1. **Keep binds in their own file.** A `bind` buried in a testbench is invisible, and
   `bind` in a design file defeats the purpose.
2. **`.*` is the right connection style here,** precisely because it breaks loudly when
   the target's ports change — which is the notification you want.
3. **Bind to the module, not the instance, unless you mean one instance.** `bind fifo`
   covers every `fifo` in the design including ones added after you wrote the checker,
   which is most of the value.
4. **A bound checker cannot see internal state unless you pass it.** Hierarchical
   references into the target work in simulation and not in the formal frontend here, so
   a checker that needs internals is a checker that belongs inside the module.

**Known uses.** *Sketch only in the RTL sense — no `bind` is used in this repository's
build,* because every module here is one we wrote and its assertions live inside it.
[docs/12 §9](12-assertions-sva.md) has the worked pattern and the guidance on when to
choose it, and [docs/06](06-modules-parameters-generate.md) covers the mechanism.

**Related.** [#6 Interface Assertions](#6-interface-assertions-sva-contract),
[#8 Interface Bundle](41-structural-and-behavioral-patterns.md#8-interface-bundle) (the
other place protocol rules can live), [docs/12](12-assertions-sva.md).

---

## 8. Debug Hooks

**Intent.** Decide, before the design is finished, what you will want to see afterwards.

**Motivation.** A bitstream or a tape-out fixes what is observable. The signals you wish
you could see are always the ones you did not bring out, and adding them means another
build — which for an FPGA is hours and for silicon is not possible. The pattern is
cheap and has to be applied early, which is exactly why it gets skipped.

**Applicability.** Use it on every design that will run on real hardware. **Do not**
mark everything: an ILA capturing five hundred signals costs block RAM you needed, and a
trigger condition nobody can express is not a debug aid.

**Structure.** *Sketch only — needs a vendor debug core.* Three tiers, cheapest first:

```systemverilog
// (1) Free: a status register. Expose the state, the pointers, the last error.
//     Software can read it with no special tooling and no rebuild.
assign ro_d[0*DW +: DW] = { 16'b0, pc_q, state_q, err_q };

// (2) Cheap: a signal marked for capture, with an explicit trigger.
(* MARK_DEBUG = "TRUE" *) logic [3:0] state_q;
(* MARK_DEBUG = "TRUE" *) logic       trigger;      // one signal that MEANS something

// (3) Expensive: a capture buffer with a trigger, i.e. an embedded logic analyser.
```

**Consequences.** *Buys:* the ability to diagnose a hardware-only failure without a
rebuild. *Costs:* block RAM for the capture buffer; routing for the marked nets;
`MARK_DEBUG` inhibits optimisation on those nets, which can cost timing; and a status
register costs a read mux entry.

**Implementation.**
1. **Tier 1 first, and it is nearly free.** A status register showing the FSM's state and
   the last error code diagnoses most field failures, needs no special tools, and can be
   read over the bus that is already there. Do this before reaching for a logic analyser.
2. **A trigger that means something is worth more than a hundred captured signals.**
   "The error bit set" is a trigger; "any activity" is not.
3. **A microcoded sequencer's program counter is the single most valuable signal in
   it.** Exposing it is what makes
   [#15](41-structural-and-behavioral-patterns.md#15-microcoded-sequencer) debuggable at
   all — otherwise the pattern's indirection is pure cost when something hangs.
4. **`MARK_DEBUG` changes the netlist.** Timing with debug and without are different
   builds; do not ship one and debug the other.

**Known uses.** *Sketch only — `MARK_DEBUG` appears nowhere in this repository,* since
nothing here targets a real device. Tier 1 **is** built:
[`csr_ctrl_top.sv`](../examples/rtl/csr_ctrl_top.sv)'s `STATUS` register exposes
`cfg_pending`, `cfg_lock`, `burst_busy` and `dp_busy`, and its `ACTIVE_*` mirrors let
software see what the hardware is *using* rather than only what was written — which is
the same instinct at the register level. [docs/33](33-debugging-and-bringup.md) is the
bring-up treatment.

**Related.** [#9 Performance Counters](#9-performance-counters),
[#7 CSR Bank](41-structural-and-behavioral-patterns.md#7-csr-bank-register-map),
[#25 Sticky Status](41-structural-and-behavioral-patterns.md#25-sticky-status--interrupt-aggregator),
[docs/33](33-debugging-and-bringup.md).

---

## 9. Performance Counters

**Intent.** Let software measure where the cycles went.

**Motivation.** "It is slower than expected" is not a debuggable statement. "Stalled
41,000 cycles out of 100,000, of which 39,000 waiting on the output" is. The counters are
a handful of flops and an increment, and without them the only way to find a bottleneck
is to guess and rebuild.

**Applicability.** Use them on any block whose throughput matters and whose stalls have
more than one possible cause. **Do not** count things whose ratio you already know, and
do not add a counter per signal — a counter you cannot interpret is area spent on
nothing.

**Structure.** The set that answers the question, and saturating rather than wrapping:

```systemverilog
// Sketch of the bus-visible version. Note SATURATION, not wrapping: a wrapped
// counter read at an unknown time is unusable, and saturation is one comparison.
logic [31:0] cnt_beats_q, cnt_stall_in_q, cnt_stall_out_q;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n || clear) begin ... end
  else begin
    if (s_valid && s_ready)   cnt_beats_q     <= sat_inc(cnt_beats_q);
    if (s_valid && !s_ready)  cnt_stall_in_q  <= sat_inc(cnt_stall_in_q);
    if (m_valid && !m_ready)  cnt_stall_out_q <= sat_inc(cnt_stall_out_q);
  end
end
```

**Consequences.** *Buys:* a bottleneck you can locate without a rebuild, and a number to
compare across versions. *Costs:* a 32-bit counter and an incrementer per event; a CSR
entry each; and a `clear` that has to be defined (read-to-clear, or an explicit strobe).

**Implementation.**
1. **Count the *causes* separately, not just "stalled".** "Stalled" is one number and
   tells you nothing; "stalled waiting for input" versus "stalled waiting for output"
   tells you which side to fix.
2. **Saturate, do not wrap.** A wrapped counter read at an unknown time is worse than
   no counter, because it produces a number that looks meaningful.
3. **Reading a 64-bit counter over a 32-bit bus is a tearing problem.** Latch the whole
   counter on the low-word read and return the latched high word afterwards — the same
   commit-point instinct as
   [docs/39](39-control-registers-and-safe-reconfiguration.md), for the same reason.
4. **A free-running cycle counter is the denominator, and you need it.** Beats without
   cycles is not a rate.
5. **Counters are also the verification tool.** Exactly the same counters, inside a
   formal block, are how occupancy invariants get stated as equalities — which is a
   second reason to have them.

**Known uses.** *Sketch only on the bus-visible side.* The counters themselves are
built: [`pipe_ripple_ctrl.sv`](../examples/rtl/pipe_ripple_ctrl.sv) keeps `f_n_in` and
`f_n_out` inside its `ifdef FORMAL` block, and they are what makes
`(f_n_in - f_n_out) == f_occupancy` provable. Exposing that pair through a
[CSR Bank](41-structural-and-behavioral-patterns.md#7-csr-bank-register-map) is the
missing step, and it is a small one.

**Related.** [#8 Debug Hooks](#8-debug-hooks),
[#7 CSR Bank](41-structural-and-behavioral-patterns.md#7-csr-bank-register-map),
[#6 Interface Assertions](#6-interface-assertions-sva-contract),
[docs/33](33-debugging-and-bringup.md).

---

## 10. Loopback / BIST Mode

**Intent.** Test the block on the bench without the thing it normally talks to.

**Motivation.** A UART needs a terminal, an I2C master needs a slave, a link needs a
partner. On the bench, at bring-up, none of those is necessarily present or trustworthy —
and when the link does not work you cannot tell which end is wrong. An internal loopback
removes the other end from the question entirely: if TX-to-RX works, the wire is the
suspect; if it does not, it is not.

**Applicability.** Use it on every external interface, and on any internal interface
whose partner is large. **Do not** let the loopback path change the design's timing when
it is off — a mux in the data path that is only used in test mode is still a mux in the
data path — and do not let a loopback be *enabled* accidentally, which is a register
default nobody checks.

**Structure.** One mux and one bit, plus a pattern generator for the harder version:

```systemverilog
// (1) LOOPBACK -- the cheap version. One mux at the pin boundary.
assign rx_serial_int = loopback_en ? tx_serial : rx_pin;

// (2) BIST -- a generator and a checker, so the block tests itself with no
//     external stimulus at all. An LFSR is the usual generator: maximal-length,
//     so the pattern is long, and self-synchronising at the checker.
lfsr_galois #(.W(16)) u_gen (...);   // one XOR on the critical path
```

**Consequences.** *Buys:* a bring-up path that does not depend on anything external, and
a definite answer to "which end is broken". *Costs:* a mux in the data path (which is
there in normal mode too); a control bit that must default to off; and, for the BIST
version, a generator and a comparator.

**Implementation.**
1. **The loopback must default to off, and the default must be tested.** A design that
   ships in loopback mode passes every self-test and receives nothing.
2. **Loop back as close to the pin as possible.** A loopback that bypasses the I/O
   registers tests less than you think, and a "working" loopback with a dead pad is a
   confusing result.
3. **Use a maximal-length LFSR for BIST, and check its period.** A generator whose
   pattern repeats every few hundred bits does not exercise the scrambler or the
   equaliser it is meant to.
   [`rtl_smoke_tb.sv`](../examples/tb/rtl_smoke_tb.sv) checks maximal length over all
   2⁸−1 states.
4. **Loopback tests the data path, not the protocol timing.** A UART looped back runs at
   exactly the right baud rate by construction, so it cannot find a clock-rate error —
   which is the bug you most want to find at bring-up. Know what it does not cover.

**Known uses.** [`uart_periph.sv`](../examples/rtl/uart_periph.sv) with TX looped to RX,
driven through a real Wishbone slave in
[`integration_tb.sv`](../examples/tb/integration_tb.sv) so every byte survives the
transmitter, the wire, the receiver, both FIFOs and the bus;
[`spi_master.sv`](../examples/rtl/spi_master.sv) wired to
[`spi_slave.sv`](../examples/rtl/spi_slave.sv) in
[`serial_tb.sv`](../examples/tb/serial_tb.sv), which is loopback used as a *test*
strategy — a sign error in "which edge samples" cannot cancel out, because the two run on
different clocks;
[`lfsr_galois.sv`](../examples/rtl/lfsr_galois.sv) and
[`lfsr_fibonacci.sv`](../examples/rtl/lfsr_fibonacci.sv) as the BIST generators.

**Related.** [#8 Debug Hooks](#8-debug-hooks),
[#9 Performance Counters](#9-performance-counters),
[#26 Watchdog](41-structural-and-behavioral-patterns.md#26-watchdog--timeout),
[docs/33](33-debugging-and-bringup.md).

---

## See also

- [docs/40 — RTL design patterns: the catalogue](40-rtl-design-patterns.md) — the frame,
  the template, the index and the anti-patterns
- [docs/41 — Structural and behavioural patterns](41-structural-and-behavioral-patterns.md)
- [docs/42 — Clocking, elaboration-time and timing patterns](42-clocking-elaboration-and-timing-patterns.md)
- [docs/29 — Memories and inference](29-memories-and-inference.md) — the inference rules
  the first group depends on
- [docs/12 — Assertions and SVA](12-assertions-sva.md) — the mechanics of the second
  group, including `bind`
- [docs/25 — Formal verification with sby](25-formal-verification-with-sby.md) — where
  properties live, and what the frontend cannot read
- [docs/16 — Verification architecture](16-verification-architecture.md) — the layered
  testbench the checkers sit in
- [docs/33 — Debugging and bring-up](33-debugging-and-bringup.md) — the catalogue of bugs
  found building this repository, and how each was found
