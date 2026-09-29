# RTL Design Patterns: the Catalogue

A pattern is a name for a recurring problem, a solution that is known to work, and
an honest account of what the solution costs. That definition is Gamma, Helm,
Johnson and Vlissides' and it survives the move to hardware unchanged. Most of the
rest of the *Design Patterns* apparatus does not, and it is worth being precise
about which parts travel and which do not, because the parts that do not are
exactly where a software habit becomes a hardware bug.

This document is the frame: what a pattern means here, the six things a hardware
pattern can spend, the template every entry uses, the complete classified index,
how patterns stack in a real block, and the anti-patterns. The entries themselves
are in three companion documents:

- [docs/41 — Structural and behavioural patterns](41-structural-and-behavioral-patterns.md)
- [docs/42 — Clocking, elaboration-time and timing patterns](42-clocking-elaboration-and-timing-patterns.md)
- [docs/43 — Memory and verification patterns](43-memory-and-verification-patterns.md)

**46 of the 61 entries point at a module in this repository** that is linted,
simulated under XSIM and — where the Yosys frontend allows it — formally proved.
The other 15 carry a code sketch and say so in as many words. §7 lists which are
which, because a catalogue that blurs "this is verified" into "this looks right" is
worse than no catalogue.

---

## Contents

- [1. What translates from GoF, and what does not](#1-what-translates-from-gof-and-what-does-not)
- [2. The six currencies](#2-the-six-currencies)
- [3. The template](#3-the-template)
- [4. The index](#4-the-index)
- [5. Patterns compose: two worked stacks](#5-patterns-compose-two-worked-stacks)
- [6. Anti-patterns](#6-anti-patterns)
- [7. Coverage, and what is only a sketch](#7-coverage-and-what-is-only-a-sketch)

---

## 1. What translates from GoF, and what does not

### The engine is different

Almost every GoF pattern works by **deferring a binding decision to run time** and
paying for it with indirection: a virtual call, a delegated object, a strategy
swapped while the program runs. That is the mechanism, and the cost is a pointer
dereference nobody measures.

Synthesised hardware has no run time in that sense. The structure is fixed when the
netlist is written. A choice you want to defer is deferred to **elaboration**, and
the mechanism is `parameter` and `generate` rather than a pointer:

```systemverilog
// The RTL Strategy. Same intent as GoF's -- select an implementation without
// touching the code that uses it -- with the binding moved from run time to build
// time, and therefore free, because there is no run time to pay in.
if (MODE == M_TRAVEL) begin : g_travel
  ...
end else begin : g_shared
  ...
end
```

This is why GoF's whole Creational category becomes, here, a category about
elaboration. Factory, Builder and Template Method survive as
[Parameterized Generator](42-clocking-elaboration-and-timing-patterns.md#10-parameterized-generator),
[Elaboration-Time Tables](42-clocking-elaboration-and-timing-patterns.md#15-elaboration-time-tables)
and [Inference Template](42-clocking-elaboration-and-timing-patterns.md#13-inference-template);
Abstract Factory and Prototype have nothing to do, because there is no object
allocation to abstract over.

Where a run-time choice genuinely is needed, hardware pays for it with a
**multiplexer**, and the pattern becomes one of the structural stream patterns —
[Stream Router](41-structural-and-behavioral-patterns.md#10-stream-router-mux--demux--crossbar),
or the
[Resource Sharing](41-structural-and-behavioral-patterns.md#20-resource-sharing-time-multiplexing)
that a mux makes possible. The mux is the hardware's virtual dispatch, and unlike a
vtable it has an area and a delay you can look up.

### There is an axis GoF does not have

A third of this catalogue exists because a signal takes time to cross a wire, and
because a flip-flop sampled while its input is moving can sit between 0 and 1 for an
unbounded time. There is no Gang of Four pattern for metastability; software's
concurrency hazards are about *ordering*, and hardware's are about *the physics of a
sampling element*. So the whole
[clock-and-reset group](42-clocking-elaboration-and-timing-patterns.md#clock-and-reset-domains)
has no software ancestry, and the one thing to carry across from software concurrency
— that you cannot reason about a shared variable without a discipline — is true here
for a much harder reason.

The same axis explains why so many hardware patterns are about *latency* rather than
structure. [Skid Buffer](41-structural-and-behavioral-patterns.md#2-skid-buffer-full-register-slice),
[Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline),
[Ping-Pong Buffer](41-structural-and-behavioral-patterns.md#22-ping-pong-double-buffer)
and [Interleaving](41-structural-and-behavioral-patterns.md#21-interleaving-c-slowing)
are all answers to "a result arrives later than the thing that wanted it", which is
not a problem a class diagram can express.

### Two GoF sections collapse, and one gets sharper

GoF gives every pattern a **Participants** list (the classes) and a
**Collaborations** section (the message sequence). In RTL the participants are
signals and submodules, and the collaboration is a timing diagram — both of which are
better shown than listed, so this catalogue folds them into **Structure** and shows
code.

**Consequences**, by contrast, gets much sharper. GoF's consequences are qualitative:
coupling, extensibility, the number of classes. A hardware pattern's consequences are
six numbers, all measurable with tools you already run. So every entry below states
which of the six it spends, and where this repository has measured it, the entry
carries the number rather than an adjective.

### The GoF names, honestly

Where a GoF pattern really is doing the same job, the entry says so. Some of the
customary mappings are decorative rather than illuminating, and it is more use to say
which:

| RTL pattern | Usual GoF label | Verdict |
|---|---|---|
| Protocol Bridge | Adapter | **Exact.** Same intent, same structure, same reason. |
| Primitive Wrapper | Adapter / Bridge | **Exact.** Adapter when you are matching an interface, Bridge when you intend to swap the implementation. |
| CSR Bank | Facade | **Good.** One simple door onto a subsystem, and the door is the only thing software knows. |
| Microcoded Sequencer | Interpreter | **Exact,** to the point of being the same idea: a table of control words *is* a program, and the sequencer *is* its interpreter. |
| Arbiter | Mediator | **Good.** N peers that would otherwise have to know about each other. |
| Hierarchical FSM | Composite | **Good** structurally — a state that is itself a machine. The real ancestor is Harel's statecharts, not GoF. |
| Sticky Status | Observer | **Good,** with one difference worth noting: the hardware subject latches, so an observer that was not looking still learns. |
| Compile-Time Strategy | Strategy | **Good,** with the binding moved to elaboration. |
| Inference Template | Template Method | **Good** — you write the skeleton the tool expects and it fills in the primitive. |
| FSMD | State + Strategy | **State is good; Strategy is not.** The datapath is not an interchangeable algorithm, it is the other half of the machine. |
| Valid/Ready | Iterator | **Weak.** Iterator hides a collection's representation; valid/ready is flow control. The honest software analogue is a bounded blocking queue, or Reactive Streams' `request(n)`. |
| Packetizer | Decorator | **Weak.** Decorator adds behaviour transparently; a packetizer changes the stream's shape and its `tlast` framing. Pipes-and-Filters is the better ancestor. |
| Configuration Package | Singleton | **Weak.** Singleton is about controlling instantiation of a mutable object. A package of parameters is a compile-time constant pool with a namespace. Nothing is instantiated and nothing is mutable. |
| FIFO Decoupler | Producer–Consumer | Not GoF at all, and correctly so — it is a concurrency pattern. |
| Interface Assertions | Design by Contract | Not GoF; Meyer's. |
| Everything in the clock group | — | No ancestor. Do not look for one. |

---

## 2. The six currencies

Every pattern here spends some of these and saves others. An entry that does not say
which is not finished.

| Currency | Unit | How to measure it in this repository |
|---|---|---|
| **Latency** | clock cycles | count the pipeline stages, or measure it in a testbench |
| **Throughput** | beats per clock | drive both sides unthrottled and count transfers over cycles |
| **Area** | cells, flops, BRAM, DSP | `yosys -p "...; techmap; opt -fast; stat"` |
| **Depth** | logic levels on the critical path | `yosys -p "...; flatten; techmap; opt -fast; ltp -noff"` |
| **Fanout** | loads on one net | the synthesis report; or count them in the source |
| **Power** | switching activity | not measurable from RTL alone; reason about it structurally ([docs/35](35-low-power-architecture.md)) |

Three things follow that are worth internalising before reading any entry.

**Most patterns trade one currency for another, not "better" for "worse."** A skid
buffer buys depth with area. Resource sharing buys area with throughput. C-slowing
buys throughput with latency. There is no dominance ordering, so "which pattern is
best" is never a well-formed question; "which currency am I short of" always is.

**Two of the six are not visible in a functional simulation.** Depth and fanout do
not show up in a waveform, and a design can be functionally perfect and
unimplementable. That asymmetry is why this catalogue insists on tool measurements
rather than review.

**One of them is measurable but noisy.** Small differences in `ltp` depth are not
reliable, because the mapping the tool chose is one of many equivalent ones. Treat a
10% depth difference as no difference; treat 2.6× as real
([docs/38 §3](38-pipeline-staging-and-stalls.md#3-measuring-a-cut-set) has the
worked case).

---

## 3. The template

Every entry has these fields, in this order. They are GoF's, minus the two that
collapse (§1) and plus one that hardware needs.

| Field | What it holds |
|---|---|
| **Intent** | One sentence. What problem, solved how. |
| **Also known as** | The other names you will meet it under. Omitted when there is only one. |
| **Motivation** | The concrete situation, with the failure that happens without the pattern. |
| **Applicability** | *Use it when* — and, always, *do not use it when*. The second half is the one that saves time. |
| **Structure** | The smallest code that shows the shape. Real code from this repository wherever one exists. |
| **Consequences** | Which of the six currencies it spends and which it saves, with measured numbers where they exist. |
| **Implementation** | The traps. Numbered, because they are the part you will come back for. |
| **Known uses** | The verified module here, or an explicit statement that this entry is a sketch. |
| **Related** | Patterns that combine with it, compete with it, or are commonly confused with it. |

The extra field is **Implementation**, which GoF also has but treats as advice. Here
it is the most load-bearing section in the entry, because hardware patterns fail in
specific, repeatable ways: a handshake that withdraws `valid`, a synchroniser on a
bus, an `always_comb` missing a branch. Every trap listed was either hit while
building this repository or is documented with the measurement that would catch it.

---

## 4. The index

61 patterns. The one-line column is the Intent field; follow the link for the entry.

**The numbers restart in each companion document**, so a cross-reference is always
`#N` *within the document it points at* — `#4` means the Async FIFO in docs/42 and the
Read-Latency Compensation in docs/43. That is deliberate: one global sequence would mean
renumbering three files every time an entry is added.

### Structural — interfaces and composition ([docs/41](41-structural-and-behavioral-patterns.md))

| # | Pattern | Intent |
|---|---|---|
| 1 | [Valid/Ready Handshake](41-structural-and-behavioral-patterns.md#1-validready-handshake) | Transfer a beat when both sides agree, with neither side able to deadlock the other |
| 2 | [Skid Buffer](41-structural-and-behavioral-patterns.md#2-skid-buffer-full-register-slice) | Register both directions of a handshake without losing a cycle of throughput |
| 3 | [Forward Register Slice](41-structural-and-behavioral-patterns.md#3-forward-register-slice) | Register the forward path only, at half the flops and none of the backward relief |
| 4 | [FIFO Decoupler](41-structural-and-behavioral-patterns.md#4-fifo-decoupler) | Let a producer and consumer run at different instantaneous rates |
| 5 | [Primitive Wrapper](41-structural-and-behavioral-patterns.md#5-primitive-wrapper) | Put every vendor-specific instantiation behind one module of your own |
| 6 | [Protocol Bridge](41-structural-and-behavioral-patterns.md#6-protocol-bridge) | Convert one bus protocol to another so the logic behind it serves all of them |
| 7 | [CSR Bank](41-structural-and-behavioral-patterns.md#7-csr-bank-register-map) | Expose control and status to software through one door with one set of semantics |
| 8 | [Interface Bundle](41-structural-and-behavioral-patterns.md#8-interface-bundle) | Carry a whole bus as one port, so adding a signal does not edit every module |
| 9 | [Width Converter (Gearbox)](41-structural-and-behavioral-patterns.md#9-width-converter-gearbox) | Change a stream's width without losing the framing or the short final beat |
| 10 | [Stream Router](41-structural-and-behavioral-patterns.md#10-stream-router-mux--demux--crossbar) | Steer beats by a field in them while keeping each packet contiguous |
| 11 | [Fork / Join](41-structural-and-behavioral-patterns.md#11-fork--join) | Split a stream to N consumers, or merge N streams, without losing or duplicating a beat |
| 12 | [Packetizer / Depacketizer](41-structural-and-behavioral-patterns.md#12-packetizer--depacketizer) | Add or strip a header and maintain the framing around a payload |

### Behavioural — control and flow ([docs/41](41-structural-and-behavioral-patterns.md))

| # | Pattern | Intent |
|---|---|---|
| 13 | [FSMD](41-structural-and-behavioral-patterns.md#13-fsmd-controller--datapath) | Separate the machine that sequences from the logic that computes |
| 14 | [Hierarchical FSM](41-structural-and-behavioral-patterns.md#14-hierarchical-fsm) | Make a state be a machine, instead of letting one machine grow to fill the block |
| 15 | [Microcoded Sequencer](41-structural-and-behavioral-patterns.md#15-microcoded-sequencer) | Store the control as a table so behaviour changes without re-synthesising logic |
| 16 | [Start/Done Handshake](41-structural-and-behavioral-patterns.md#16-startdone-gobusy-handshake) | The command interface for a block whose latency the caller should not have to know |
| 17 | [Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline) | Carry a validity bit alongside the data so latency costs nothing in throughput |
| 18 | [Global Stall](41-structural-and-behavioral-patterns.md#18-global-stall-pipeline-enable) | Freeze every stage with one enable, and pay for it in fanout rather than in logic |
| 19 | [Arbiter](41-structural-and-behavioral-patterns.md#19-arbiter) | Grant one of N requesters a shared resource, fairly or by priority |
| 20 | [Resource Sharing](41-structural-and-behavioral-patterns.md#20-resource-sharing-time-multiplexing) | Serve N channels from one expensive datapath over N cycles |
| 21 | [Interleaving (C-slowing)](41-structural-and-behavioral-patterns.md#21-interleaving-c-slowing) | Fill a pipeline that a feedback loop forbids pipelining, with N independent contexts |
| 22 | [Ping-Pong Buffer](41-structural-and-behavioral-patterns.md#22-ping-pong-double-buffer) | Two buffers alternating, so a producer and a consumer never contend for one |
| 23 | [Credit-Based Flow Control](41-structural-and-behavioral-patterns.md#23-credit-based-flow-control) | Let a sender know the receiver's free space in advance, when the round trip is too long for ready |
| 24 | [Tagged Transactions / Reorder Buffer](41-structural-and-behavioral-patterns.md#24-tagged-transactions--reorder-buffer) | Let responses come back out of order and put them back in order |
| 25 | [Sticky Status / Interrupt Aggregator](41-structural-and-behavioral-patterns.md#25-sticky-status--interrupt-aggregator) | Latch an event so software learns about it even if it was not watching |
| 26 | [Watchdog / Timeout](41-structural-and-behavioral-patterns.md#26-watchdog--timeout) | Turn a hang into a reported error at a bounded time |

### Clock and reset domains ([docs/42](42-clocking-elaboration-and-timing-patterns.md))

| # | Pattern | Intent |
|---|---|---|
| 1 | [Two-Flop Synchronizer](42-clocking-elaboration-and-timing-patterns.md#1-two-flop-synchronizer) | Give a metastable sample a cycle to settle before anything looks at it |
| 2 | [Toggle (Pulse) Synchronizer](42-clocking-elaboration-and-timing-patterns.md#2-toggle-pulse-synchronizer) | Carry an event across domains when a one-cycle pulse would be missed entirely |
| 3 | [Req/Ack Handshake Synchronizer](42-clocking-elaboration-and-timing-patterns.md#3-reqack-handshake-synchronizer) | Cross a multi-bit value by holding it still and synchronising only the control |
| 4 | [Async FIFO](42-clocking-elaboration-and-timing-patterns.md#4-async-fifo-gray-pointers) | Stream continuously between two clocks |
| 5 | [Gray-Coded Counter Crossing](42-clocking-elaboration-and-timing-patterns.md#5-gray-coded-counter-crossing) | Cross a monotonic count so a mid-transition sample is off by at most one |
| 6 | [Reset Synchronizer](42-clocking-elaboration-and-timing-patterns.md#6-reset-synchronizer) | Assert reset without a clock and release it with one |
| 7 | [Reset Sequencer](42-clocking-elaboration-and-timing-patterns.md#7-reset-sequencer) | Release resets in a defined order when the blocks depend on each other |
| 8 | [Clock Enable over Derived Clock](42-clocking-elaboration-and-timing-patterns.md#8-clock-enable-over-derived-clock) | Run slow logic on the fast clock rather than making a new clock in fabric |
| 9 | [Glitch-Free Clock Switch](42-clocking-elaboration-and-timing-patterns.md#9-glitch-free-clock-switch) | Change clock source without emitting a runt pulse |

### Elaboration time ([docs/42](42-clocking-elaboration-and-timing-patterns.md))

| # | Pattern | Intent |
|---|---|---|
| 10 | [Parameterized Generator](42-clocking-elaboration-and-timing-patterns.md#10-parameterized-generator) | Build an N-wide or N-deep structure from one description |
| 11 | [Configuration Package](42-clocking-elaboration-and-timing-patterns.md#11-configuration-package) | One source of truth for the parameters, types and layout a design shares |
| 12 | [Compile-Time Strategy](42-clocking-elaboration-and-timing-patterns.md#12-compile-time-strategy) | Select an implementation at elaboration, at no run-time cost |
| 13 | [Inference Template](42-clocking-elaboration-and-timing-patterns.md#13-inference-template) | Write the exact shape the synthesiser maps onto a hard block |
| 14 | [Elaboration-Time Assertion](42-clocking-elaboration-and-timing-patterns.md#14-elaboration-time-assertion) | Fail the build on an illegal parameter instead of shipping it |
| 15 | [Elaboration-Time Tables](42-clocking-elaboration-and-timing-patterns.md#15-elaboration-time-tables) | Compute a ROM's contents with a function instead of maintaining a hex file |

### Timing and physical ([docs/42](42-clocking-elaboration-and-timing-patterns.md))

| # | Pattern | Intent |
|---|---|---|
| 16 | [Pipeline Insertion / Retiming](42-clocking-elaboration-and-timing-patterns.md#16-pipeline-insertion--retiming) | Cut a long combinational path into stages that each meet the clock |
| 17 | [Registered Boundaries](42-clocking-elaboration-and-timing-patterns.md#17-registered-boundaries) | Register every module output so each block closes timing by itself |
| 18 | [Register Duplication](42-clocking-elaboration-and-timing-patterns.md#18-register-duplication) | Copy a high-fanout driver so each copy drives a local region |
| 19 | [Tree Reduction](42-clocking-elaboration-and-timing-patterns.md#19-tree-reduction) | Combine N terms in log N depth instead of N |
| 20 | [Lookahead / Precomputation](42-clocking-elaboration-and-timing-patterns.md#20-lookahead--precomputation) | Compute a flag a cycle early and register it, so its consumer sees a flop |
| 21 | [One-Hot Encoding / AND-OR Mux](42-clocking-elaboration-and-timing-patterns.md#21-one-hot-encoding--and-or-mux) | Make a decode one gate deep by spending a wire per case |
| 22 | [SRL Delay Line](42-clocking-elaboration-and-timing-patterns.md#22-srl-delay-line) | Get a long fixed delay from one LUT per 16–32 stages instead of a flop per stage |
| 23 | [Multicycle Datapath](42-clocking-elaboration-and-timing-patterns.md#23-multicycle-datapath) | Let a path take more than one clock, and tell the timing tool so |
| 24 | [I/O Register Packing](42-clocking-elaboration-and-timing-patterns.md#24-io-register-packing) | Put the boundary flop in the pad so pin timing is deterministic |
| 25 | [Minimal Reset](42-clocking-elaboration-and-timing-patterns.md#25-minimal-reset) | Reset the control state and nothing else |

### Memory and buffering ([docs/43](43-memory-and-verification-patterns.md))

| # | Pattern | Intent |
|---|---|---|
| 1 | [Ring Buffer](43-memory-and-verification-patterns.md#1-ring-buffer) | Turn a RAM plus two pointers into a queue |
| 2 | [Line Buffer / Sliding Window](43-memory-and-verification-patterns.md#2-line-buffer--sliding-window) | Present a 2-D neighbourhood from a 1-D raster stream |
| 3 | [Memory Banking / Port Multiplication](43-memory-and-verification-patterns.md#3-memory-banking--port-multiplication) | Get more ports than the primitive has |
| 4 | [Read-Latency Compensation](43-memory-and-verification-patterns.md#4-read-latency-compensation) | Delay the control to match the memory's own output latency |
| 5 | [Content-Addressable Lookup](43-memory-and-verification-patterns.md#5-content-addressable-lookup) | Search by value instead of by address |

### Verification and observability ([docs/43](43-memory-and-verification-patterns.md))

| # | Pattern | Intent |
|---|---|---|
| 6 | [Interface Assertions](43-memory-and-verification-patterns.md#6-interface-assertions-sva-contract) | Write the protocol's rules at the port, where they are checked in every test |
| 7 | [Bind-In Checker](43-memory-and-verification-patterns.md#7-bind-in-checker) | Attach assertions to RTL you must not edit |
| 8 | [Debug Hooks](43-memory-and-verification-patterns.md#8-debug-hooks) | Decide before tape-out or bitstream what you will want to see afterwards |
| 9 | [Performance Counters](43-memory-and-verification-patterns.md#9-performance-counters) | Let software measure where the cycles went |
| 10 | [Loopback / BIST Mode](43-memory-and-verification-patterns.md#10-loopback--bist-mode) | Test the block on the bench without the thing it normally talks to |

---

## 5. Patterns compose: two worked stacks

Patterns are only interesting where they stack, and the useful skill is reading an
existing block as a stack rather than as code. Two from this repository.

### `uart_periph.sv` — a peripheral

[`uart_periph.sv`](../examples/rtl/uart_periph.sv) is 157 lines and it is eight
patterns:

| Layer | Pattern | What it contributes |
|---|---|---|
| bus | [Protocol Bridge](41-structural-and-behavioral-patterns.md#6-protocol-bridge) | the generic register port, so the same peripheral sits on APB, AXI-Lite or Wishbone |
| registers | [CSR Bank](41-structural-and-behavioral-patterns.md#7-csr-bank-register-map) | RW/RO/W1C semantics defined once |
| events | [Sticky Status](41-structural-and-behavioral-patterns.md#25-sticky-status--interrupt-aggregator) | an overrun that happened between two polls is still reported |
| buffering | [FIFO Decoupler](41-structural-and-behavioral-patterns.md#4-fifo-decoupler) ×2 | software's bursts and the line's steady rate stop being each other's problem |
| queues | [Ring Buffer](43-memory-and-verification-patterns.md#1-ring-buffer) | what each FIFO is made of |
| control | [FSMD](41-structural-and-behavioral-patterns.md#13-fsmd-controller--datapath) | the TX and RX bit engines |
| timing | [Clock Enable over Derived Clock](42-clocking-elaboration-and-timing-patterns.md#8-clock-enable-over-derived-clock) | the baud generator is an enable, not a clock |
| test | [Loopback](43-memory-and-verification-patterns.md#10-loopback--bist-mode) | TX to RX with no wire, which is how `integration_tb` tests it |

Nothing in that list is novel. That is the point: the module was assembled from parts
that were each verified alone, so the only new thing in it was the wiring — which is
the whole argument for having a pattern vocabulary in the first place.

### `csr_ctrl_top.sv` — configuration arriving from software

[`csr_ctrl_top.sv`](../examples/rtl/csr_ctrl_top.sv) stacks differently, and the
interesting part is one pattern that this catalogue's usual sources do not list:

| Layer | Pattern |
|---|---|
| bus | [Protocol Bridge](41-structural-and-behavioral-patterns.md#6-protocol-bridge) (`axil_slave`) |
| registers | [CSR Bank](41-structural-and-behavioral-patterns.md#7-csr-bank-register-map) |
| **commit** | **a staged/active double buffer** — [docs/39](39-control-registers-and-safe-reconfiguration.md) |
| consumers | [FSMD](41-structural-and-behavioral-patterns.md#13-fsmd-controller--datapath) and a [Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline) |
| events | [Sticky Status](41-structural-and-behavioral-patterns.md#25-sticky-status--interrupt-aggregator) |
| build | [Compile-Time Strategy](42-clocking-elaboration-and-timing-patterns.md#12-compile-time-strategy) — three reconfiguration policies from one datapath |
| test | [Interface Assertions](43-memory-and-verification-patterns.md#6-interface-assertions-sva-contract) |

The commit point is a pattern in exactly this catalogue's sense — recurring problem,
known solution, measurable cost — and it is missing from most pattern lists because
it only appears once you have a processor writing registers into a block that is
already running. [docs/39](39-control-registers-and-safe-reconfiguration.md) is its
entry, written before this catalogue existed and in the same shape.

**A catalogue is never complete, and the gap is always at the seams.** Both of these
stacks are fine as lists of parts. The bugs in both were at the joins: a register
write landing mid-burst, a start and a commit racing on one clock edge. Patterns
name the parts; they do not name the seams.

---

## 6. Anti-patterns

An anti-pattern is not merely bad style. Each of these is a case where the pattern
language is being bypassed, and each has a specific failure signature — which is what
makes them worth naming, because the signature is how you recognise one in somebody
else's code.

The fields are the template's, inverted: what it looks like, why it seemed
reasonable, what actually happens, how to detect it, and what to do instead.

### A1. Derived or gated clocks built in fabric logic

**Looks like** `always @(posedge clk) div <= ~div;` followed by
`always @(posedge div)`. Or `assign gclk = clk & enable;`.

**Seemed reasonable** because the logic really does only need to run at a quarter
rate, and a divided clock is the obvious way to say so.

**What actually happens.** A clock out of fabric arrives late and skewed relative to
the clock it came from, so every path between the two domains is a timing problem the
tool cannot fix. A LUT-based gate glitches on the way in and out of the gated state.
And the static timing analysis is now about a clock the tool has to infer rather than
one you declared.

**Detect it** by grepping for a `posedge` of anything that is not a port or a
clock-buffer output; and in the timing report, by any generated clock whose source is
a LUT.

**Instead** use [Clock Enable over Derived Clock](42-clocking-elaboration-and-timing-patterns.md#8-clock-enable-over-derived-clock)
for rate reduction, the dedicated primitive for genuine clock gating, and
[Glitch-Free Clock Switch](42-clocking-elaboration-and-timing-patterns.md#9-glitch-free-clock-switch)
for source selection. [docs/24](24-dft-clocking-and-x-discipline.md) is the rule in
full.

### A2. Inferred latch from an incomplete `always_comb`

**Looks like** a `case` with no `default`, or an `if` with no `else`, assigning a
signal that is not given a default first.

**Seemed reasonable** because the uncovered case "cannot happen".

**What actually happens.** The synthesiser builds a latch to hold the old value. A
latch in a synchronous design is transparent for part of the cycle, so its timing is
analysed differently or not at all, and it holds a value in simulation that hardware
may not hold.

**Detect it** structurally, not by review. `make lint` in this repository runs
`yosys -p "read_verilog ...; proc"` over every module and greps for
`ERROR: Latch inferred`, which is the only reliable way to be sure:

```
yosys: 90 modules latch-checked, 10 outside the frontend subset
LINT CLEAN
```

**Instead** assign a default to every output at the top of the block, then
conditionally override. [docs/20](20-synthesis-subset-and-gotchas.md) has the
mechanics.

### A3. Combinational loop through a handshake

**Looks like** `ready` computed from `valid` on one side and `valid` computed from
`ready` on the other.

**Seemed reasonable** because each module's version looks like ordinary
back-pressure, and each is fine on its own.

**What actually happens.** The loop closes when the two are connected, which is
usually in a different file from either. The tool reports a combinational loop, or
worse, breaks it somewhere arbitrary and the design behaves inconsistently between
builds.

**Detect it** by making the rule structural rather than reviewed: every `ready` a
function of registers only. `axil_slave.sv` states this as a design rule and holds it
by construction rather than by inspection —

```
//   2. VALID MUST NOT WAIT FOR READY. ... READY may depend on VALID, never the
//      other way round. Every *ready here is a function of registers only, so the
//      rule holds structurally rather than by inspection.
```

**Instead** keep the direction of dependence one-way, and insert a
[Skid Buffer](41-structural-and-behavioral-patterns.md#2-skid-buffer-full-register-slice)
where you need to break the backward path.

### A4. Multi-bit bus through per-bit synchronizers

**Looks like** a `cdc_bit` instance per bit of a vector, or a `for` loop generating
them.

**Seemed reasonable** because each bit individually is correctly synchronised, and
that is true.

**What actually happens.** Each bit resolves independently, so bits that changed in
the same source cycle arrive in different destination cycles and the destination sees
a value that is part old and part new. Adding synchroniser stages does not help; it
is not a metastability problem, it is a *skew* problem.

**Detect it** with a CDC linter, or by grepping for a synchroniser instantiated
inside a `for`/`generate` over a data vector.

**Instead** use [Async FIFO](42-clocking-elaboration-and-timing-patterns.md#4-async-fifo-gray-pointers)
for a stream, [Req/Ack Handshake Synchronizer](42-clocking-elaboration-and-timing-patterns.md#3-reqack-handshake-synchronizer)
for an occasional value, or [Gray-Coded Counter Crossing](42-clocking-elaboration-and-timing-patterns.md#5-gray-coded-counter-crossing)
for a monotonic count. There is one legitimate exception and it is worth knowing:
a bus that is **quasi-static** — provably stable for many destination cycles around a
synchronised qualifier — may cross as plain wires under
`set_max_delay -datapath_only`. [docs/39 §10](39-control-registers-and-safe-reconfiguration.md#10-when-the-ps-is-in-another-clock-domain)
is that case, and the word doing the work is *provably*.

### A5. Reconvergent synchronization

**Looks like** two related signals crossed through separate synchronisers and then
combined in the destination domain.

**Seemed reasonable** because each crossing is textbook.

**What actually happens.** The two crossings resolve in different cycles, so the
combination is momentarily a state that never existed in the source. A one-hot vector
crossed bit by bit can be briefly all-zero or two-hot; a value and its own valid flag
crossed separately can arrive apart.

**Detect it** by tracing back from every expression that combines two signals and
asking whether both came from the same domain through the *same* crossing.

**Instead** cross one thing: encode the combination in the source domain and cross
the result, or carry everything through a single handshake or FIFO.
[docs/28 §9](28-clock-domain-crossing.md#9-reconvergence) is the general treatment.

### A6. Asynchronous reset on datapath registers

**Looks like** `always_ff @(posedge clk or negedge rst_n)` on every register in the
design, including the pipeline and the accumulators.

**Seemed reasonable** because a reset that works without a clock is strictly safer,
and consistency is a virtue.

**What actually happens.** On an FPGA, the hard blocks — DSP, block RAM, SRL — have
no asynchronous reset on their internal registers, so a register that wants one
cannot be absorbed into them. The datapath falls out into fabric flops, the design
gets bigger and slower, and the reset net fans out to everything.

**Detect it** in the synthesis report: an SRL that became 32 flops, a DSP whose
pipeline register was not used, an MAC that did not infer.

**Instead** use [Minimal Reset](42-clocking-elaboration-and-timing-patterns.md#25-minimal-reset):
reset the control state, leave the datapath alone, and let the
[Valid-Bit Pipeline](41-structural-and-behavioral-patterns.md#17-valid-bit-pipeline)
make the uninitialised data unobservable. Note the two costs, because this one is a
genuine trade and not a free win: X-propagation in simulation needs discipline
([docs/24 §7](24-dft-clocking-and-x-discipline.md)), and DFT may want the
controllability.

### A7. The god module

**Looks like** one file, one `always_ff`, several hundred lines, control and
arithmetic and bus and framing interleaved.

**Seemed reasonable** because everything in it genuinely is related, and splitting it
would mean inventing interfaces.

**What actually happens.** No part of it can be verified alone, so every change
re-tests everything and every bug is a whole-module bug. The synthesiser also does
worse on it: a wide arithmetic expression inside a state decode makes both the
critical path and the state encoding worse than either would be apart.

**Detect it** by trying to write down what one of its signals means without
mentioning three others.

**Instead** [FSMD](41-structural-and-behavioral-patterns.md#13-fsmd-controller--datapath)
first — pull the arithmetic out of the sequencing — then
[Hierarchical FSM](41-structural-and-behavioral-patterns.md#14-hierarchical-fsm) if the
sequencing is still too big. `dot_rs_dp.sv` and `dot_rs_global.sv` in
[docs/38 §1](38-pipeline-staging-and-stalls.md#1-the-two-problems-kept-apart) are the
split done deliberately: one datapath, and the flow control somewhere else.

### A8. Relying on gate delays for timing or pulse shaping

**Looks like** a chain of inverters or buffers used as a delay, `#5` in synthesisable
code, or a pulse whose width comes from the difference between two paths.

**Seemed reasonable** because it works in simulation and it worked on the last
process.

**What actually happens.** The synthesiser is entitled to remove the chain, and the
router is entitled to give you any delay it likes. Neither is a bug in the tool. The
circuit then works at one temperature, or on one device, or until the next build.

**Detect it** by grepping synthesisable sources for `#` outside a `timescale`, and for
any `(* dont_touch *)` whose justification is "delay".

**Instead** count clock cycles. Anything you want to be N units long should be N
cycles of a clock you declared: [`pulse_extend.sv`](../examples/rtl/pulse_extend.sv)
for a widened pulse, [`srl_delay.sv`](../examples/rtl/srl_delay.sv) for a long delay,
[`clk_div_en.sv`](../examples/rtl/clk_div_en.sv) for a slow rate.

---

## 7. Coverage, and what is only a sketch

46 of the 61 entries point at a module in `examples/` that is analysed by `xvlog`,
latch-checked by `yosys`, exercised by a testbench under XSIM, and in many cases
proved with SymbiYosys. Those entries name the file.

**15 entries carry a code sketch and no module.** The sketch is there because the
pattern is worth knowing and the shape is worth seeing, but it has not been built or
run here, and an entry that pretended otherwise would undermine the ones that have:

| Pattern | Why there is no module | Where the idea is nonetheless covered |
|---|---|---|
| [Primitive Wrapper](41-structural-and-behavioral-patterns.md#5-primitive-wrapper) | needs a specific vendor primitive, which would make this repository unportable | [docs/34](34-coding-conventions-and-reuse.md) |
| [Stream Router](41-structural-and-behavioral-patterns.md#10-stream-router-mux--demux--crossbar) | — | [docs/30](30-flow-control-and-handshakes.md) |
| [Fork / Join](41-structural-and-behavioral-patterns.md#11-fork--join) | the **Join** half *is* built (`skew_buffer.sv`); the Fork is not | [docs/38 §11](38-pipeline-staging-and-stalls.md#11-reconvergence-and-the-skew-buffer) |
| [Packetizer / Depacketizer](41-structural-and-behavioral-patterns.md#12-packetizer--depacketizer) | the framing FSM *is* built (`cfg_burst_fsm.sv`); the header insertion is not | [docs/39 §2](39-control-registers-and-safe-reconfiguration.md#2-three-failure-modes-and-why-two-of-them-survive-review) |
| [Ping-Pong Buffer](41-structural-and-behavioral-patterns.md#22-ping-pong-double-buffer) | — | `vid_axis_line_buffer.sv` is the ring-buffer cousin |
| [Credit-Based Flow Control](41-structural-and-behavioral-patterns.md#23-credit-based-flow-control) | — | [docs/30](30-flow-control-and-handshakes.md) |
| [Tagged Transactions / Reorder Buffer](41-structural-and-behavioral-patterns.md#24-tagged-transactions--reorder-buffer) | `axil_slave.sv` is deliberately single-outstanding | [docs/30](30-flow-control-and-handshakes.md) |
| [Reset Sequencer](42-clocking-elaboration-and-timing-patterns.md#7-reset-sequencer) | depends on the platform's lock and power-good signals | [docs/24](24-dft-clocking-and-x-discipline.md) |
| [Glitch-Free Clock Switch](42-clocking-elaboration-and-timing-patterns.md#9-glitch-free-clock-switch) | must be a vendor primitive; a fabric version is anti-pattern A1 | [docs/24](24-dft-clocking-and-x-discipline.md) |
| [Multicycle Datapath](42-clocking-elaboration-and-timing-patterns.md#23-multicycle-datapath) | the pattern is mostly a constraint, not RTL | [docs/32 §7](32-timing-constraints.md) |
| [I/O Register Packing](42-clocking-elaboration-and-timing-patterns.md#24-io-register-packing) | needs real pins | [docs/24](24-dft-clocking-and-x-discipline.md), [docs/32](32-timing-constraints.md) |
| [Content-Addressable Lookup](43-memory-and-verification-patterns.md#5-content-addressable-lookup) | — | [docs/29](29-memories-and-inference.md) |
| [Bind-In Checker](43-memory-and-verification-patterns.md#7-bind-in-checker) | every module here is one we wrote, so its assertions live inside it | [docs/12 §9](12-assertions-sva.md) has the worked pattern |
| [Debug Hooks](43-memory-and-verification-patterns.md#8-debug-hooks) | needs a vendor debug core; **tier 1 (a status register) is built** | [docs/33](33-debugging-and-bringup.md) |
| [Performance Counters](43-memory-and-verification-patterns.md#9-performance-counters) | the counters are built, in `pipe_ripple_ctrl.sv`'s formal block rather than on a bus | [docs/38 §12](38-pipeline-staging-and-stalls.md#12-verifying-a-pipeline-that-stalls) |

**Three further entries are counted among the 46 but are only half built,** and each says
so in place rather than letting the reader assume:

- [Interface Bundle](41-structural-and-behavioral-patterns.md#8-interface-bundle) — the
  testbenches use an SV `interface` with `modport`s; **no RTL module here does**, because
  the modules take flat ports to stay readable to the Yosys frontend.
- [Lookahead / Precomputation](42-clocking-elaboration-and-timing-patterns.md#20-lookahead--precomputation)
  — the *threshold* form is built (`sync_fifo.sv`'s `almost_full`); the
  registered-prediction form is a sketch.
- [Memory Banking](43-memory-and-verification-patterns.md#3-memory-banking--port-multiplication)
  — the *combinational read-mux* form is built (`regfile.sv`, and it is what a register
  file actually is); replication, address banking and the live-value table are not.

That table is also the honest answer to "what would you add next": the entries in it,
in roughly that order.

---

## See also

- [docs/41 — Structural and behavioural patterns](41-structural-and-behavioral-patterns.md)
- [docs/42 — Clocking, elaboration-time and timing patterns](42-clocking-elaboration-and-timing-patterns.md)
- [docs/43 — Memory and verification patterns](43-memory-and-verification-patterns.md)
- [docs/34 — Coding conventions and reuse](34-coding-conventions-and-reuse.md) — the
  conventions the patterns are written in, and the failure each one prevents
- [docs/30 — Flow control and handshakes](30-flow-control-and-handshakes.md) — the
  valid/ready contract most of the structural group depends on
- [docs/33 — Debugging and bring-up](33-debugging-and-bringup.md) — the catalogue of
  bugs found building this repository, which is where most of the Implementation
  sections came from
