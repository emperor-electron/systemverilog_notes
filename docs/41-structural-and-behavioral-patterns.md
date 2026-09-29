# Structural and Behavioural Patterns

Twenty-six entries: twelve about how blocks connect, fourteen about how they
sequence. The template, the six currencies and the GoF correspondences are in
[docs/40](40-rtl-design-patterns.md); read §1–§3 there first if you have not.

Entries whose **Known uses** names a file point at code in `examples/` that is
linted, simulated and in many cases proved. Entries that say *sketch only* have not
been built here, and say so.

---

## Contents

**Structural** —
[1 Valid/Ready](#1-validready-handshake) ·
[2 Skid Buffer](#2-skid-buffer-full-register-slice) ·
[3 Forward Register Slice](#3-forward-register-slice) ·
[4 FIFO Decoupler](#4-fifo-decoupler) ·
[5 Primitive Wrapper](#5-primitive-wrapper) ·
[6 Protocol Bridge](#6-protocol-bridge) ·
[7 CSR Bank](#7-csr-bank-register-map) ·
[8 Interface Bundle](#8-interface-bundle) ·
[9 Width Converter](#9-width-converter-gearbox) ·
[10 Stream Router](#10-stream-router-mux--demux--crossbar) ·
[11 Fork / Join](#11-fork--join) ·
[12 Packetizer](#12-packetizer--depacketizer)

**Behavioural** —
[13 FSMD](#13-fsmd-controller--datapath) ·
[14 Hierarchical FSM](#14-hierarchical-fsm) ·
[15 Microcoded Sequencer](#15-microcoded-sequencer) ·
[16 Start/Done](#16-startdone-gobusy-handshake) ·
[17 Valid-Bit Pipeline](#17-valid-bit-pipeline) ·
[18 Global Stall](#18-global-stall-pipeline-enable) ·
[19 Arbiter](#19-arbiter) ·
[20 Resource Sharing](#20-resource-sharing-time-multiplexing) ·
[21 Interleaving](#21-interleaving-c-slowing) ·
[22 Ping-Pong Buffer](#22-ping-pong-double-buffer) ·
[23 Credit-Based Flow Control](#23-credit-based-flow-control) ·
[24 Tagged Transactions](#24-tagged-transactions--reorder-buffer) ·
[25 Sticky Status](#25-sticky-status--interrupt-aggregator) ·
[26 Watchdog](#26-watchdog--timeout)

---

# Structural

## 1. Valid/Ready Handshake

*GoF analogue: none that is illuminating. See [docs/40 §1](40-rtl-design-patterns.md#1-what-translates-from-gof-and-what-does-not).*

**Intent.** Transfer one beat on any clock edge where the producer has data and the
consumer can take it, with neither side able to deadlock the other.

**Also known as.** AXI-Stream handshake, ready/valid, `TVALID`/`TREADY`, elastic
interface.

**Motivation.** Two blocks rarely run at the same instantaneous rate. Without a
protocol you either fix the rate by construction — brittle, and it breaks the first
time either side gains a pipeline stage — or you hand-shake, and then the question is
which of the two signals may depend on the other. Get that wrong and you have either
a combinational loop or a deadlock, and both appear only after integration.

**Applicability.** Use it for essentially every internal stream interface. **Do not
use it** when the consumer can never refuse — a fixed-rate video timing generator, a
DAC — because then `ready` is a constant and the protocol is a wire you still have to
verify; and do not use it across a long round trip, where
[Credit-Based Flow Control](#23-credit-based-flow-control) is the right answer.

**Structure.** Four rules, of which the third is the one that bites:

```systemverilog
// 1. A beat transfers iff (valid && ready) on a rising edge.
// 2. READY MAY DEPEND ON VALID. VALID MAY NEVER DEPEND ON READY.
// 3. Once valid is asserted it stays asserted, payload unchanged, until ready.
// 4. Neither side may require the other to move first.
assign xfer = m_valid && m_ready;
```

Rule 2 is what makes rule 4 achievable and what prevents the loop; the repository
states it as a structural property rather than a review item:

```systemverilog
// axil_slave.sv
//   2. VALID MUST NOT WAIT FOR READY. A manager may not delay AWVALID until it
//      sees AWREADY; likewise a subordinate may not delay BVALID until BREADY.
//      READY may depend on VALID, never the other way round. Every *ready here
//      is a function of registers only, so the rule holds structurally rather
//      than by inspection.
```

**Consequences.** *Buys:* composability — any two conforming blocks connect, and a
stage can be inserted anywhere without redesigning either side. *Costs:* one extra
wire per direction, and a `ready` that is combinational by default, so the backward
path becomes a timing problem the moment the chain gets long ([#2](#2-skid-buffer-full-register-slice),
[#18](#18-global-stall-pipeline-enable)).

**Implementation.**
1. **Never withdraw an offer.** If `valid` falls before `ready` rises, the beat is
   lost and the loss depends on timing, so it reproduces once a week. Assert it at
   the port: `(m_valid && !m_ready) |=> (m_valid && $stable(m_data))`.
2. **`ready` must be a function of registers.** Writing it as a function of the
   incoming `valid` is how anti-pattern
   [A3](40-rtl-design-patterns.md#a3-combinational-loop-through-a-handshake) happens,
   and it closes in whichever file connects the two.
3. **A testbench driver has to obey the protocol too.** Randomly toggling `s_valid`
   withdraws offers; the bug then looks like the DUT dropping beats.
   `pipeline_stall_tb.sv` holds `valid` until accepted for exactly this reason.
4. **`ready` high while idle is legal and usually right.** A consumer that only
   raises `ready` after seeing `valid` adds a cycle of latency per hop for nothing.

**Known uses.** Every stream port in this repository.
[`skid_buffer.sv`](../examples/rtl/skid_buffer.sv) and
[`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv) are the canonical ones, both
formally proved for no loss, no duplication and no reordering
([`skid_buffer_fv.sby`](../formal/skid_buffer_fv.sby),
[`axis_reg_slice_fv.sby`](../formal/axis_reg_slice_fv.sby)).

**Related.** [#2](#2-skid-buffer-full-register-slice), [#3](#3-forward-register-slice)
and [#4](#4-fifo-decoupler) all exist to manage its costs;
[#23](#23-credit-based-flow-control) replaces it when the loop is long.
[docs/30](30-flow-control-and-handshakes.md) is the full treatment.

---

## 2. Skid Buffer (Full Register Slice)

**Intent.** Put a register in *both* directions of a valid/ready link without losing
a cycle of throughput.

**Also known as.** Full register slice, elastic buffer, two-entry pipeline register.

**Motivation.** A registered forward path is easy ([#3](#3-forward-register-slice)).
Registering `ready` is not, because the producer will present a beat in the cycle
before the registered `ready` falls, and something must hold it. The obvious fix —
stop accepting a cycle early — halves the rate ([HALF mode](#3-forward-register-slice)).
The skid buffer instead keeps one spare slot for exactly that beat.

**Applicability.** Use it when the backward path is your critical path, or at any
hierarchical boundary you want to close timing independently
([#17 Registered Boundaries](42-clocking-elaboration-and-timing-patterns.md#17-registered-boundaries)).
**Do not use it** where only the forward path is long — you would be paying double the
flops for nothing — and do not scatter them for latency insurance: each one adds a
cycle, and in a control loop that latency is not free.

**Structure.** Two slots and one rule: accept whenever the spare is empty.

```systemverilog
// skid_buffer.sv -- `in_ready` depends on a REGISTER, not on out_ready.
assign in_ready = !skid_valid;

always_ff @(posedge clk or negedge rst_n) begin
  if (skid_valid) begin
    if (!out_valid || out_ready) begin          // drain the spare first
      out_valid  <= 1'b1;
      out_data   <= skid_data;
      skid_valid <= 1'b0;
    end
  end else if (!out_valid || out_ready) begin   // pass straight through
    out_valid <= in_valid;
    if (in_valid) out_data <= in_data;
  end else if (in_valid) begin                  // output blocked: skid
    ...
  end
end
```

**Consequences.** Measured across all five ways of registering a handshake, at
`DW=8` ([docs/38 §8](38-pipeline-staging-and-stalls.md#8-register-slices-the-five-ways-to-cut-a-handshake)):

| mode | flops | beats/100 cycles | forward path | backward path |
|---|---|---|---|---|
| PASS (no slice) | 0 | 100 | combinational | combinational |
| FWD | 9 | 99 | **registered** | combinational |
| REV | 9 | 100 | combinational | **registered** |
| **FULL (skid)** | **18** | **99** | **registered** | **registered** |
| HALF | 9 | **50** | registered | registered |

*Buys:* both paths registered at full rate. *Costs:* 2× the flops of a one-sided
slice, and one cycle of latency.

**Implementation.**
1. **`in_ready` must not mention `out_ready`.** That is the entire point; if it does,
   you have built a PASS slice with extra flops.
2. **Occupancy is the property to prove, and as an equality.** `accepted − delivered
   == out_valid + skid_valid`. Stated as a bound (`<= 2`) it is still true but
   induction returns UNKNOWN.
3. **Do not confuse it with a 2-deep FIFO.** A FIFO's `ready` is also registered, but
   it costs a RAM and its latency is data-dependent. For depth 2, the flop version is
   smaller and has fixed latency.
4. **The rate column is invisible to a data check.** A half-rate slice passes every
   integrity test ever written; only counting beats per cycle finds it.

**Known uses.** [`skid_buffer.sv`](../examples/rtl/skid_buffer.sv), proved unbounded
in [`skid_buffer_fv.sby`](../formal/skid_buffer_fv.sby);
[`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv) `MODE=3` instantiates it, so
the five modes share one implementation.

**Related.** [#1](#1-validready-handshake), [#3](#3-forward-register-slice),
[#4](#4-fifo-decoupler), [#16 Pipeline Insertion](42-clocking-elaboration-and-timing-patterns.md#16-pipeline-insertion--retiming).

---

## 3. Forward Register Slice

**Intent.** Register the forward path of a handshake at half the flops of a skid
buffer, accepting that `ready` stays combinational.

**Also known as.** FWD slice, valid/data register, "pipeline stage with valid".

**Motivation.** Most long paths in a stream are forward paths — a wide datapath
feeding the next stage. Paying for a skid buffer to fix a problem you do not have is
a habit worth breaking, and the catalogue is more useful if it names the cheaper
member of the family explicitly.

**Applicability.** Use it when the forward path is long and the backward path is
short, which is the common case in a shallow chain. **Do not use it** in a long chain:
`ready` is combinational through every FWD slice, so the backward path grows linearly
and eventually becomes the critical path all by itself. At that point either switch to
skid buffers or break the chain with one.

**Structure.** One register, and a ready that passes straight through when empty:

```systemverilog
// The essential shape. `s_ready` still mentions `m_ready`.
assign s_ready = !m_valid || m_ready;
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n)          m_valid <= 1'b0;
  else if (s_ready)  begin m_valid <= s_valid; if (s_valid) m_data <= s_data; end
```

**Consequences.** From the table in [#2](#2-skid-buffer-full-register-slice): 9 flops
against 18, 99 beats per 100 cycles either way, and the backward path unrelieved.
There is also a **REV** member — registered backward, combinational forward — which
costs the same 9 flops and is the right choice when `ready` is the problem and the
data path is short.

**Implementation.**
1. **Count the chain.** *k* FWD slices in a row means *k* levels of `ready` logic.
   Measure it (`ltp -noff`) rather than estimating.
2. **FWD and REV are not interchangeable.** Reaching for "a register slice" without
   asking which path is long is how you end up with the wrong one.
3. **The HALF variant is a trap, not an option.** It registers both directions with 9
   flops, and its 50% rate is forced rather than incidental: it cannot reload in the
   cycle it drains, because deciding to reload would need `m_ready` — which is exactly
   what would put it back in the `s_ready` path. Use it only where the source is known
   to be at most half rate.

**Known uses.** [`axis_reg_slice.sv`](../examples/rtl/axis_reg_slice.sv), `MODE=1`
(FWD), `MODE=2` (REV), `MODE=4` (HALF); one proof task per mode in
[`axis_reg_slice_fv.sby`](../formal/axis_reg_slice_fv.sby).

**Related.** [#2](#2-skid-buffer-full-register-slice) for the full version,
[#18 Register Duplication](42-clocking-elaboration-and-timing-patterns.md#18-register-duplication)
when the problem is fanout rather than depth.

---

## 4. FIFO Decoupler

*Concurrency analogue: Producer–Consumer / bounded blocking queue.*

**Intent.** Put a queue between two blocks so each can run at its own instantaneous
rate and a burst on one side does not stall the other.

**Motivation.** A register slice smooths one cycle of mismatch. It does nothing for a
producer that emits 16 beats back to back and a consumer that takes one every four
cycles: with only slices in between, the producer stalls. A FIFO converts a rate
mismatch into a *depth* requirement, which is a number you can compute.

**Applicability.** Use it when the two sides' rates differ in bursts but match on
average; when you need to cross clock domains ([#4 Async FIFO](42-clocking-elaboration-and-timing-patterns.md#4-async-fifo-gray-pointers));
or when the consumer has a long, variable latency. **Do not use it** to paper over a
rate mismatch that is not bursty but *sustained* — no depth is enough, and the FIFO
just moves where the design falls over. And do not use it where latency is bounded by
a specification: a FIFO's latency is its occupancy, which varies.

**Structure.** A [Ring Buffer](43-memory-and-verification-patterns.md#1-ring-buffer)
plus flags:

```systemverilog
// sync_fifo.sv -- the lookahead flags are part of the interface, not a courtesy.
assign almost_full  = (level >= (AW+1)'(DEPTH - 1));
assign almost_empty = (level <= (AW+1)'(1));
```

**Consequences.** *Buys:* both sides run at their natural rate, bursts are absorbed,
and back-pressure becomes rare rather than per-cycle. *Costs:* a RAM (often a whole
block RAM, whatever the depth you asked for), latency that varies with occupancy, and
two pointer comparators. In a control loop the variable latency is the real cost.

**Implementation.**
1. **Sizing is a calculation, not a guess.** Depth ≥ burst length × (1 − consumer rate
   ÷ producer rate), plus the round-trip latency of whatever generates back-pressure.
   Write the calculation in the file.
2. **`full` must be combinational for the write side.** Gating a write on a
   *registered* `full` overruns by one. [docs/28](28-clock-domain-crossing.md) has the
   async-FIFO version of this, where it is worse.
3. **`almost_full` exists because `full` is too late.** A producer that needs a cycle
   to react must be told a cycle early — which is
   [#20 Lookahead](42-clocking-elaboration-and-timing-patterns.md#20-lookahead--precomputation).
4. **Depth 1 and depth 2 are special cases.** A parameterised FIFO at depth 2 is
   usually worse than a skid buffer: more logic, a RAM, and the same behaviour. Check
   the degenerate parameters.

**Known uses.** [`sync_fifo.sv`](../examples/rtl/sync_fifo.sv)
([`sync_fifo_fv.sby`](../formal/sync_fifo_fv.sby)),
[`async_fifo.sv`](../examples/rtl/async_fifo.sv), and two instances inside
[`uart_periph.sv`](../examples/rtl/uart_periph.sv).

**Related.** [#2](#2-skid-buffer-full-register-slice) for one cycle of slack,
[#22 Ping-Pong](#22-ping-pong-double-buffer) when the unit is a whole buffer rather
than a beat, [#1 Ring Buffer](43-memory-and-verification-patterns.md#1-ring-buffer)
for the mechanism.

---

## 5. Primitive Wrapper

*GoF analogue: **Adapter** (matching an interface) or **Bridge** (intending to swap
the implementation). Exact in both cases.*

**Intent.** Put every vendor-specific instantiation behind one module of your own, so
that porting or swapping it touches one file.

**Motivation.** A design that instantiates `BUFGCTRL`, `DSP48E2`, `RAMB36E2` and
`IOBUF` directly, in twelve places, is a design that cannot move to another family or
another vendor without twelve edits — and, worse, cannot be simulated without the
vendor's library. The wrapper is the same trick as an Adapter: name the capability you
need, hide the thing that provides it.

**Applicability.** Use it for every hard primitive: clock buffers, I/O buffers, DSP
and RAM macros you instantiate rather than infer, transceivers, PLL/MMCM. **Do not
use it** where inference works — a wrapper around an inferred RAM is one more
indirection for no portability gain, and the
[Inference Template](42-clocking-elaboration-and-timing-patterns.md#13-inference-template)
is the pattern you want instead. Also do not abstract so hard that the primitive's
real constraints vanish: a wrapper that hides a BRAM's one-cycle read latency will be
wrong for every user.

**Structure.** *Sketch only — no module here, because a vendor primitive would make
this repository unportable.*

```systemverilog
// my_clk_mux.sv -- the ONLY place a vendor clock mux is named.
module my_clk_mux (
  input  var logic clk0, clk1, sel,
  output var logic clk_out
);
`ifdef XILINX
  BUFGCTRL u_mux (.I0(clk0), .I1(clk1), .S0(~sel), .S1(sel),
                  .CE0(1'b1), .CE1(1'b1), .IGNORE0(1'b0), .IGNORE1(1'b0),
                  .O(clk_out));
`elsif SIMULATION
  assign clk_out = sel ? clk1 : clk0;    // NOT glitch-free; simulation only
`else
  $error("my_clk_mux: no implementation selected");
`endif
endmodule
```

**Consequences.** *Buys:* one file to port, one file to stub for simulation, and one
place where the primitive's constraints are documented. *Costs:* an extra level of
hierarchy (free after flattening), and the discipline to keep the wrapper's interface
honest about latency and legal input combinations.

**Implementation.**
1. **The simulation branch must be labelled as not equivalent.** A behavioural clock
   mux is not glitch-free. If the stub silently pretends otherwise, the bug shows up
   only in hardware.
2. **Do not let the wrapper's interface be the union of all vendors'.** That is not an
   Adapter, it is a leak. Define the interface from what your design needs.
3. **Keep the `ifdef` at the bottom of the hierarchy.** One `ifdef` in one leaf module
   is maintainable; the same `ifdef` in the middle of a datapath is
   [docs/31](31-preprocessor-and-directives.md)'s cautionary tale.
4. **Write the elaboration-time failure.** A wrapper with no branch selected should
   fail the build ([#14](42-clocking-elaboration-and-timing-patterns.md#14-elaboration-time-assertion)),
   not quietly synthesise to nothing.

**Known uses.** *None in this repository* — deliberately, since everything here is
built to run on `xvlog` and `yosys` with no vendor library. The closest relatives are
the [Inference Templates](42-clocking-elaboration-and-timing-patterns.md#13-inference-template)
in [`ram_sp.sv`](../examples/rtl/ram_sp.sv) and
[`mac_pipelined.sv`](../examples/rtl/mac_pipelined.sv), which get hard blocks without
naming them.

**Related.** [#6 Protocol Bridge](#6-protocol-bridge) (the same idea applied to a bus
rather than a cell), [#13 Inference Template](42-clocking-elaboration-and-timing-patterns.md#13-inference-template),
[#12 Compile-Time Strategy](42-clocking-elaboration-and-timing-patterns.md#12-compile-time-strategy).

---

## 6. Protocol Bridge

*GoF analogue: **Adapter**. Exact.*

**Intent.** Convert one bus protocol into another, so that the logic behind it is
written once and serves all of them.

**Motivation.** A peripheral wired directly to AXI4-Lite is an AXI4-Lite peripheral
for ever. Worse, its bus handling and its register behaviour are in the same module,
so every change to either re-tests both — and bus bugs and register bugs are found by
completely different tests.

**Applicability.** Use it whenever a block might meet more than one bus, or whenever
the bus is complicated enough to be worth verifying separately from what it carries
(AXI4-Lite's five independent channels qualify). **Do not use it** for a
single-protocol block with two registers, where the bridge is more code than the thing
it serves.

**Structure.** Three subordinates, one target interface. The target is four signals
each way, and it is where the register semantics live:

```systemverilog
// apb_slave.sv, axil_slave.sv and wb_slave.sv all produce THIS:
output var logic [AW-1:0]   reg_addr;
output var logic            reg_wen;
output var logic [DW-1:0]   reg_wdata;
output var logic [DW/8-1:0] reg_wstrb;
output var logic            reg_ren;
input  var logic [DW-1:0]   reg_rdata;
input  var logic            reg_err;
```

**Consequences.** *Buys:* the register block is written and proved once; a new bus is
one new module; and `bus_tb.sv` can run *identical* register tests through two
different buses, so "fails through one bus and not the other" localises the bug
immediately. *Costs:* the lowest common denominator — the generic port here is
single-outstanding, so a bridge cannot expose AXI's pipelining even though the bus
has it. That is a real ceiling and worth stating in the file.

**Implementation.**
1. **Decide who owns the addressing, and write it down.** `axil_slave.sv` passes the
   address through untouched on purpose, because byte-address versus register-index is
   the integrator's decision; `csr_ctrl_top.sv` is where that decision is made
   (`idx = reg_addr[BAW+1:2]`). Making it inside the bridge bakes in an assumption
   half its users do not share.
2. **`ren` and `wen` must be exactly one cycle.** A side-effecting register accessed
   twice because the strobe was level-held is a classic; `apb_slave.sv` asserts it.
3. **Do not let the error path evaporate.** A write to a read-only register must be
   `SLVERR`, not a silent no-op, or a driver bug survives to the field.
4. **Reconciling two address maps is the bridge's job, and it is one gate.** When
   something outside the register block decodes an address — a command strobe —
   remember to mask the bank's "unmapped" error for it.

**Known uses.** [`apb_slave.sv`](../examples/rtl/apb_slave.sv),
[`axil_slave.sv`](../examples/rtl/axil_slave.sv)
([`axil_slave_fv.sby`](../formal/axil_slave_fv.sby)),
[`wb_slave.sv`](../examples/rtl/wb_slave.sv) — three bridges, one target, exercised
through [`bus_tb.sv`](../examples/tb/bus_tb.sv).

**Related.** [#7 CSR Bank](#7-csr-bank-register-map) is what sits behind it;
[#5 Primitive Wrapper](#5-primitive-wrapper) is the same idea for cells;
[#9 Width Converter](#9-width-converter-gearbox) is a bridge in the stream domain.

---

## 7. CSR Bank (Register Map)

*GoF analogue: **Facade**. Good.*

**Intent.** Expose a subsystem's control and status to software through one door, with
one definition of each register's behaviour.

**Motivation.** Register semantics are more subtle than they look, and there are only
about three of them — read/write, read-only, and write-1-to-clear — so defining them
once is strictly better than defining them per peripheral. W1C in particular has to be
exactly right: a "read, then write zero" clear loses every event that arrived in
between, and a hardware set losing to a simultaneous software clear is a dropped
interrupt that reproduces weekly.

**Applicability.** Use it for every software-visible block. **Do not use it** as the
place to put a block's internal state: a register bank whose fields are wired straight
into an FSM's next-state logic is how [docs/39](39-control-registers-and-safe-reconfiguration.md)
starts, and that ends badly.

**Structure.** The behaviour that has to be right, in one expression so its precedence
is not an accident of statement order:

```systemverilog
// csr_bank.sv -- W1C, with SET beating CLEAR in the same cycle.
if (wen && hit_stat) status_q <= (status_q & ~wdata) | status_set;
else                 status_q <=  status_q          | status_set;
```

**Consequences.** *Buys:* one implementation of the semantics, one place to review
against the register document, and a clean split from the bus
([#6](#6-protocol-bridge)) so the two kinds of bug are found separately. *Costs:* one
flop per writable bit (unavoidable), a read mux as wide as the map, and an address
decoder whose depth grows with the map.

**Implementation.**
1. **Hardware set must beat software clear.** If it does not, the event that arrived
   during the clear disappears. Assert it:
   `(|status_set) |=> ((status_q & $past(status_set)) == $past(status_set))`.
2. **A write to a read-only register is an error, not a no-op.**
3. **Byte strobes want an indexed part-select.** `rw_r[addr][b*8 +: 8] <= wdata[b*8 +: 8]`
   maps onto a byte write enable; a read-modify-write does not.
4. **A command is a strobe, not a register.** A bit software sets and hardware clears
   races its own clear and reads back uselessly. Decode the write instead — see
   [docs/39 §4](39-control-registers-and-safe-reconfiguration.md#4-commit-policies-and-the-tearing-they-do-or-do-not-prevent).
5. **Give software a mirror of what the hardware is *using*,** not only of what it
   wrote. Those differ whenever there is a commit point between them, and having both
   turns a day of debugging into a minute. The cost is wires.

**Known uses.** [`csr_bank.sv`](../examples/rtl/csr_bank.sv), behind all three bridges;
the register map of [`uart_periph.sv`](../examples/rtl/uart_periph.sv) and
[`csr_ctrl_top.sv`](../examples/rtl/csr_ctrl_top.sv).

**Related.** [#6](#6-protocol-bridge), [#25 Sticky Status](#25-sticky-status--interrupt-aggregator),
[#9 Performance Counters](43-memory-and-verification-patterns.md#9-performance-counters),
and [docs/39](39-control-registers-and-safe-reconfiguration.md) for what has to happen
between the bank and a running design.

---

## 8. Interface Bundle

**Intent.** Carry a whole bus as one port, so that adding a signal does not edit every
module list it passes through.

**Motivation.** An AXI4-Lite port is about twenty signals. Threaded through five
levels of hierarchy by hand, that is a hundred port declarations and a hundred
connections, and adding `awprot` means editing all of them. SystemVerilog's
`interface` with `modport`s makes it one port with a direction.

**Applicability.** Use it for wide, standard, stable bundles that cross several levels
— buses and stream interfaces — and in testbenches, where `clocking` blocks inside the
interface also solve the sampling-race problem. **Do not use it** for a leaf module's
two or three signals, and be careful using it at a synthesis boundary you do not
control: interface support in synthesis is good but not universal, and an IP
integrator may want flat ports. Flattening at the top boundary and bundling inside is
the usual compromise.

**Structure.** *Sketch on the RTL side; the testbenches here do use it.*

```systemverilog
interface axis_if #(parameter int DW = 32) (input logic clk, input logic rst_n);
  logic [DW-1:0] tdata;
  logic          tvalid, tready, tlast;

  modport src  (output tdata, tvalid, tlast, input  tready, input clk, rst_n);
  modport dst  (input  tdata, tvalid, tlast, output tready, input clk, rst_n);

  // The protocol rule lives with the bundle, so every user gets it for free.
  a_hold: assert property (@(posedge clk) disable iff (!rst_n)
    (tvalid && !tready) |=> (tvalid && $stable(tdata)));
endinterface
```

**Consequences.** *Buys:* one edit to add a signal; a natural home for the protocol's
assertions ([#6](43-memory-and-verification-patterns.md#6-interface-assertions-sva-contract))
so they are checked at every instance; and `modport` makes the direction a compile-time
check rather than a convention. *Costs:* a level of indirection in every waveform and
every cross-probe; weaker tool support than plain ports; and the temptation to put
logic in the interface, which makes it a module wearing a disguise.

**Implementation.**
1. **One `modport` per role, and no "both" modport.** A modport that exposes
   everything defeats the direction checking that is half the value.
2. **Do not put logic in an interface.** Assertions and `clocking` blocks yes;
   arithmetic no. The moment it has state, hierarchy and reset become ambiguous.
3. **A monitor needs its own all-input `clocking` block.** Reusing the driver's
   modport in a monitor is how a testbench samples its own stimulus.
   [`fifo_tb.sv`](../examples/tb/fifo_tb.sv) has `drv` and `mon` separately for this
   reason.
4. **Parameterise the interface, not just its users.** An `axis_if` hard-coded to 32
   bits is a bundle you will copy.

**Known uses.** [`fifo_tb.sv:24`](../examples/tb/fifo_tb.sv) (`fifo_if` with `drv`/`mon`
modports and two clocking blocks) and
[`skid_buffer_tb.sv:25`](../examples/tb/skid_buffer_tb.sv). **No RTL module here uses
an interface** — the modules take flat ports so they stay readable to the Yosys
frontend, which is a real constraint of this repository rather than a recommendation.
[docs/07](07-interfaces-and-packages.md) is the full treatment.

**Related.** [#11 Configuration Package](42-clocking-elaboration-and-timing-patterns.md#11-configuration-package)
(the same "one source of truth" instinct applied to parameters and types),
[#6 Interface Assertions](43-memory-and-verification-patterns.md#6-interface-assertions-sva-contract).

---

## 9. Width Converter (Gearbox)

**Intent.** Change a stream's data width without losing the framing, the byte
enables, or the short final beat.

**Also known as.** Upsizer/downsizer, serialiser/deserialiser, gearbox (for non-integer
ratios such as 64b/66b).

**Motivation.** A 64-bit datapath meeting a 16-bit peripheral is an ordinary
situation, and the ordinary bug is the last beat. A packet whose length is not a
multiple of the ratio produces a *partial* wide word, and a converter that pads it to
full width has silently changed the packet — with `tlast` now in the wrong place, so
every downstream framing decision is wrong too.

**Applicability.** Use it at any width change. **Do not use it** to fix a *rate*
mismatch, which is [#4 FIFO Decoupler](#4-fifo-decoupler)'s job: a 4:1 upsizer does not
make a slow consumer faster, it just changes the shape of the stall. A **gearbox** —
for a non-integer ratio — is a different and harder animal: it needs an accumulator and
a phase counter, not a shift register, and it emits at an irregular cadence.

**Structure.** The part that matters is the short final beat:

```systemverilog
// axis_upsizer.sv -- TKEEP marks which lanes of the final wide word are real.
// Without it the downsizer cannot know how many narrow beats to emit, and a
// 3-of-4 group becomes a padded 4, with TLAST one beat late for ever after.
output var logic [RATIO-1:0] m_tkeep;
```

**Consequences.** *Buys:* two datapaths of different widths can meet. *Costs:* latency
of up to (ratio − 1) beats on the upsizing side; a register file of the wide width; and
an interface that now carries `tkeep`, which every downstream block must honour or
ignore *deliberately*.

**Implementation.**
1. **Test the lengths that are not multiples of the ratio.** This is the whole bug
   class. `sysmod_tb.sv` runs an upsizer→downsizer round trip at lengths on and off the
   boundary, which is the shortest description of a sufficient test.
2. **`tlast` must arrive with the beat that contains the last byte,** not the beat
   after it.
3. **Decide what a downsizer does with a `tkeep` hole in the middle.** AXI-Stream
   permits it; most designs cannot handle it. Refuse it with an assertion rather than
   producing something plausible.
4. **A gearbox is not a wide shift register.** If the ratio is not an integer, the
   output cadence is irregular and the design needs an explicit phase accumulator.

**Known uses.** [`axis_upsizer.sv`](../examples/rtl/axis_upsizer.sv)
([`axis_upsizer_fv.sby`](../formal/axis_upsizer_fv.sby)),
[`axis_downsizer.sv`](../examples/rtl/axis_downsizer.sv), round-tripped in
[`sysmod_tb.sv`](../examples/tb/sysmod_tb.sv).

**Related.** [#12 Packetizer](#12-packetizer--depacketizer) for the framing itself,
[#4 FIFO Decoupler](#4-fifo-decoupler) for the rate problem it does not solve.

---

## 10. Stream Router (Mux / Demux / Crossbar)

**Intent.** Steer beats to one of N destinations by a field in the stream, while
keeping each packet contiguous.

**Motivation.** Routing beat by beat is easy and wrong. A packet is a sequence of
beats that must arrive together and in order; a router that re-decides on every beat
interleaves two packets onto one output, and nothing downstream can separate them
again.

**Applicability.** Use it where one producer feeds several consumers by address or tag,
or several producers share one sink. **Do not use** a full crossbar where a shared bus
would do: N×M costs N×M muxes and an arbiter per output, and most designs have one hot
path and several cold ones. And do not route by anything that is not in the beat —
routing on a side-band signal that is not held for the packet is the same bug as
re-deciding per beat.

**Structure.** *Sketch only — no module here.* The lock is the pattern:

```systemverilog
// Decide at the FIRST beat of a packet; hold until tlast.
logic [$clog2(N)-1:0] dest_q;
logic                 locked_q;

always_comb dest = locked_q ? dest_q : dest_of(s_tdata);   // decode the header

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)                         locked_q <= 1'b0;
  else if (s_tvalid && s_tready) begin
    if (!locked_q) begin dest_q <= dest; locked_q <= 1'b1; end
    if (s_tlast)         locked_q <= 1'b0;                 // release at tlast
  end
end

// Back-pressure comes from the SELECTED output only.
assign s_tready = m_tready[dest];
for (genvar i = 0; i < N; i++)
  assign m_tvalid[i] = s_tvalid && (dest == i);
```

**Consequences.** *Buys:* one stream serves N consumers. *Costs:* a mux per output and
a decoder; head-of-line blocking, because a packet for a busy output stalls the beats
behind it even if their outputs are idle; and, for a crossbar, an
[Arbiter](#19-arbiter) per output.

**Implementation.**
1. **Lock the decision for the packet.** Everything else here is detail.
2. **`s_tready` must come from the selected output only.** ORing all the readies
   accepts a beat nobody can take; ANDing them stalls on idle outputs.
3. **Head-of-line blocking is a design decision, not an accident.** If you cannot
   accept it, you need per-destination queues in front of the router — which is N
   FIFOs, and that cost is the honest price of avoiding it.
4. **A demux and a fork are different patterns.** A demux sends each beat to *one*
   output; a [Fork](#11-fork--join) sends every beat to *all* of them. Confusing them
   loses or duplicates data.

**Known uses.** *None in this repository — sketch only.* The arbitration half is
[`arb_round_robin.sv`](../examples/rtl/arb_round_robin.sv);
[docs/30](30-flow-control-and-handshakes.md) covers the flow control.

**Related.** [#11 Fork / Join](#11-fork--join), [#19 Arbiter](#19-arbiter),
[#24 Tagged Transactions](#24-tagged-transactions--reorder-buffer).

---

## 11. Fork / Join

**Intent.** Copy one stream to N consumers without losing or duplicating a beat
(fork), or combine N streams beat-for-beat (join).

**Motivation.** Both directions have one difficulty and it is the same difficulty:
**partial acceptance.** A fork whose consumers have independent `ready` signals will
have some accept a beat and others not; if it advances anyway, the slow ones lose the
beat, and if it waits, it must remember which ones already took it. A join with no
storage couples its inputs, so a stall on one branch becomes a stall on all of them.

**Applicability.** Fork when several consumers genuinely need every beat — a datapath
and a checksum, a datapath and a monitor. Join where two branches of a computation
reconverge. **Do not fork** to a consumer that only needs occasional beats; give it a
[Stream Router](#10-stream-router-mux--demux--crossbar) or let it sample. **Do not
join** without asking how far the branches may drift: if the answer is "more than a
beat or two", you need per-side FIFOs — which is what `skew_buffer.sv` is, and
[docs/38 §11](38-pipeline-staging-and-stalls.md#11-reconvergence-and-the-skew-buffer)
is its treatment.

**Structure.** The fork's accepted-mask is the whole pattern. *Fork is a sketch; the
join is built.*

```systemverilog
// FORK -- sketch. Remember who has already taken this beat.
logic [N-1:0] taken_q;
assign m_tvalid  = {N{s_tvalid}} & ~taken_q;
assign s_tready  = &(taken_q | m_tready);          // all have taken it
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n)              taken_q <= '0;
  else if (s_tvalid && s_tready) taken_q <= '0;    // beat complete, start over
  else if (s_tvalid)       taken_q <= taken_q | (m_tvalid & m_tready);
```

```systemverilog
// JOIN -- skew_buffer.sv. A FIFO per side, and an output valid only when both
// have something. `skew` is the measured drift, and it is bounded by the depth.
assign m_valid = !a_empty && !b_empty;
assign skew    = a_level - b_level;
```

**Consequences.** Fork *buys* one producer serving N consumers; it *costs* an N-bit
register and a `ready` that is an AND of N — which is a depth problem as N grows, and
it couples the consumers' timing. Join *buys* decoupled branches; it *costs* two
FIFOs, and the depth of those FIFOs is the maximum drift you are permitting.

**Implementation.**
1. **`s_tready = &(taken | m_tready)`, not `&m_tready`.** The latter waits for a
   consumer that has already taken the beat, which deadlocks the moment one consumer is
   faster than another.
2. **A storage-free join turns every local stall into a global one.** That is
   sometimes fine and always worth stating explicitly.
3. **Assert pairing.** A join must pop both sides on the same cycle;
   `skew_buffer.sv` asserts it on the two FIFOs' read strobes.
4. **A join does not reorder.** If the branches can return results out of order, you
   need [#24 Tagged Transactions](#24-tagged-transactions--reorder-buffer), not a
   deeper FIFO.

**Known uses.** [`skew_buffer.sv`](../examples/rtl/skew_buffer.sv) is the Join, with
the pairing and bounded-skew assertions. **The Fork is a sketch** — there is no fork
module here.

**Related.** [#10 Stream Router](#10-stream-router-mux--demux--crossbar),
[#4 FIFO Decoupler](#4-fifo-decoupler),
[docs/38 §11](38-pipeline-staging-and-stalls.md#11-reconvergence-and-the-skew-buffer).

---

## 12. Packetizer / Depacketizer

*GoF analogue: usually given as **Decorator**; Pipes-and-Filters is closer. See
[docs/40 §1](40-rtl-design-patterns.md#1-what-translates-from-gof-and-what-does-not).*

**Intent.** Add a header to a payload stream, or strip one, maintaining the `tlast`
framing across the change in length.

**Motivation.** A payload is N beats; a packet is a header plus N beats plus possibly
a trailer. The framing is what makes them separable downstream, and the framing is
what breaks: a header emitted without its trailer, or a `tlast` on the header instead
of the last payload beat, produces a stream that is *individually* plausible at every
beat and unparseable as a whole.

**Applicability.** Use it wherever a stream gains or loses a framing layer — Ethernet,
a DMA descriptor, an internal message bus. **Do not** build the header into the
payload producer: the producer then has to know the framing, and you cannot reuse
either half.

**Structure.** *Sketch only.* The state machine is small and the invariant is what
matters:

```systemverilog
// PACKETIZER -- sketch. Note the invariant, not the code:
//   a trailer is emitted if and only if a header was.
typedef enum logic [1:0] { P_HDR, P_PAY, P_TRL } pstate_e;

always_comb begin
  m_tvalid = (state_q == P_HDR) ? 1'b1 : s_tvalid;
  m_tdata  = (state_q == P_HDR) ? header : s_tdata;
  m_tlast  = (state_q == P_TRL);
  s_tready = (state_q == P_PAY) && m_tready;
end
```

**Consequences.** *Buys:* the payload producer knows nothing about framing. *Costs:*
one or two beats of latency per packet, a small FSM, and — the real cost — a
correctness property that no single-beat check can see.

**Implementation.**
1. **The header/trailer pairing is the property to prove.** "A trailer is emitted iff
   a header was" is pure control, needs no arithmetic, and cannot be recovered by any
   amount of defensive comparison once the framing decision is allowed to change
   mid-packet. [`cfg_burst_fsm.sv`](../examples/rtl/cfg_burst_fsm.sv) is exactly this
   FSM, and [docs/39 §2](39-control-registers-and-safe-reconfiguration.md#2-three-failure-modes-and-why-two-of-them-survive-review)
   measures what happens when a register write changes `hdr_en` mid-burst: `hdr=1
   trl=0`, terminated normally, no error anywhere.
2. **Latch the framing configuration at the start of the packet.** See above. This is
   the single most important line in the entry.
3. **A depacketizer must handle a truncated packet.** `tlast` arriving during the
   header is a real input from a real link. Decide what it does.
4. **Do not put the length in the header unless you can know it.** A streaming
   packetizer does not know the length until the last beat; if the protocol needs it in
   the header, you need a buffer for the whole packet, and that changes the design.

**Known uses.** *Sketch only.* The half that is built is the framing FSM in
[`cfg_burst_fsm.sv`](../examples/rtl/cfg_burst_fsm.sv) (header/payload/trailer with the
pairing property proved in [`cfg_burst_fsm_fv.sby`](../formal/cfg_burst_fsm_fv.sby)),
and the `tkeep`/`tlast` handling in
[`axis_upsizer.sv`](../examples/rtl/axis_upsizer.sv).

**Related.** [#9 Width Converter](#9-width-converter-gearbox),
[#13 FSMD](#13-fsmd-controller--datapath),
[#10 Stream Router](#10-stream-router-mux--demux--crossbar).

---

# Behavioural

## 13. FSMD (Controller + Datapath)

*GoF analogue: **State** for the controller — good. **Strategy** for the datapath —
no; the datapath is the other half of the machine, not an interchangeable algorithm.*

**Intent.** Separate the machine that sequences from the logic that computes, so each
is written, optimised and verified on its own terms.

**Motivation.** A wide arithmetic expression inside a state decode makes both worse:
the critical path now runs through the state bits into the adder, and the synthesiser
cannot re-encode the states without disturbing the arithmetic. It also makes the block
untestable in halves, which is [anti-pattern A7](40-rtl-design-patterns.md#a7-the-god-module).

**Applicability.** Use it for essentially any block with both control and arithmetic —
which is most of them. **Do not** split so finely that the "controller" is a single
flop: a two-state machine and one adder in one module is clearer than two modules and
an interface.

**Structure.** The split this repository uses is per-stage enables in the datapath and
the flow control somewhere else entirely:

```systemverilog
// dot_rs_dp.sv -- the DATAPATH. No valid, no ready, no flush, no `en`.
// Just `adv[]`, one bit per cut.
if (CUTS[1]) begin : g_cut2
  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n)   sum_q <= '0;
    else if (adv[1])   sum_q <= sum_d;
  end
end
```

```systemverilog
// dot_rs_global.sv -- one CONTROLLER choice: every enable is the same wire.
dot_rs_dp #(...) u_dp (.adv({4{en}}), ...);
// dot_rs_elastic.sv -- a different controller, the SAME datapath file untouched.
dot_rs_dp #(...) u_dp (.adv(4'(adv_ctrl)), ...);
```

**Consequences.** *Buys:* two controllers over one datapath with the datapath file
never edited; each half verified separately; better synthesis on both. *Costs:* an
interface between them (the `adv` bus), and one more module to read.

**Implementation.**
1. **The datapath should have no opinion about flow control.** If it mentions `valid`
   or `ready`, the split is not clean and you cannot swap controllers.
2. **Give the datapath per-stage enables, not one.** A global stall is then the
   *degenerate case* — `{N{en}}` — rather than a different design. That single
   observation is what lets one datapath serve both schemes.
3. **Beware what a global stall hides in verification.** With `adv = {4{en}}` all four
   enables are one wire, so an equivalence proof *provably cannot* see a stage
   registered on the wrong enable. Measured: the mutation passes cleanly. A second
   proof task with independent enables is what catches it
   ([docs/38 §12](38-pipeline-staging-and-stalls.md#12-verifying-a-pipeline-that-stalls)).
4. **Registered outputs cost no latency if you plan for them.** The three-process style
   computes the next state and the next outputs together, so outputs are registered
   without a cycle of delay.

**Known uses.** [`dot_rs_dp.sv`](../examples/rtl/dot_rs_dp.sv) with
[`dot_rs_global.sv`](../examples/rtl/dot_rs_global.sv) and
[`dot_rs_elastic.sv`](../examples/rtl/dot_rs_elastic.sv);
[`fsm_two_process.sv`](../examples/rtl/fsm_two_process.sv),
[`fsm_three_process.sv`](../examples/rtl/fsm_three_process.sv) and
[`fsm_one_process.sv`](../examples/rtl/fsm_one_process.sv) are the same controller in
three styles, proved to produce identical waveforms in
[`fsm_tb.sv`](../examples/tb/fsm_tb.sv).

**Related.** [#14 Hierarchical FSM](#14-hierarchical-fsm),
[#15 Microcoded Sequencer](#15-microcoded-sequencer),
[#18 Global Stall](#18-global-stall-pipeline-enable),
[docs/26](26-fsm-coding-styles.md).

---

## 14. Hierarchical FSM

*GoF analogue: **Composite**, structurally. The real ancestor is Harel's statecharts.*

**Intent.** Let a state *be* a machine, so that one machine does not grow to fill the
block.

**Motivation.** A protocol with three nested levels — bit timing inside byte framing
inside a transaction — written as one flat machine has a state count that is the
product of the levels, and every state has to know about all three. Split it and each
level has a handful of states and one interface: `start` down, `done` up.

**Applicability.** Use it when the state count is multiplying rather than adding, or
when one level is reusable on its own (a bit engine used by two protocols). **Do not
use it** for a machine with six states; the handshakes will be more code than the
states they separate. And do not nest more than two or three deep — each level adds a
cycle of `start`/`done` latency, and debugging a four-level nest is worse than
debugging a flat machine.

**Structure.** The interface between levels is [#16 Start/Done](#16-startdone-gobusy-handshake).
`i2c_master.sv` exposes a *byte-level* command interface over a bit-level engine:

```systemverilog
// i2c_master.sv -- the outer level speaks in commands, not in SCL edges.
input  var logic       cmd_valid,
input  var logic [1:0] cmd,           // START / WRITE / READ / STOP
output var logic       cmd_ready,
output var logic       done,          // one cycle per completed command
output var logic       busy,
output var logic       arb_lost,      // sticky until the next START
```

**Consequences.** *Buys:* each level is small enough to read and to verify alone; the
inner level is reusable. *Costs:* a cycle or two of latency per level crossing; a
`done` pulse per level that must not be missed; and the fact that a waveform now shows
two state variables that have to be read together.

**Implementation.**
1. **`done` must be a pulse, and the parent must not be able to miss it.** If the
   parent can be in a state that ignores `done`, the machine hangs. The safest shape is
   for the child to hold `done` until the parent acknowledges, or for the parent's wait
   state to be the only state that can be in while the child runs.
2. **Exactly one level owns each resource.** Two levels both driving SDA is the
   commonest hierarchical-FSM bug.
3. **Error escalation needs a path.** An inner-level failure — an I2C arbitration loss,
   a UART framing error — must reach the outer level and the CSR
   ([#25 Sticky Status](#25-sticky-status--interrupt-aggregator)). Sticky is the right
   semantic: the outer level may not be looking at the instant it happens.
4. **Reset the child when the parent aborts.** Otherwise a sub-machine keeps running
   the transaction its parent has given up on.

**Known uses.** [`i2c_master.sv`](../examples/rtl/i2c_master.sv) (byte commands over a
bit engine), [`uart_periph.sv`](../examples/rtl/uart_periph.sv) (register level over
TX/RX bit engines), [`spi_master.sv`](../examples/rtl/spi_master.sv).

**Related.** [#13 FSMD](#13-fsmd-controller--datapath),
[#15 Microcoded Sequencer](#15-microcoded-sequencer) (the alternative when the
sequence is long rather than nested), [#16 Start/Done](#16-startdone-gobusy-handshake).

---

## 15. Microcoded Sequencer

*GoF analogue: **Interpreter**. Exact, to the point of being the same idea — a table of
control words is a program, and the sequencer is its interpreter.*

**Intent.** Store the control as a table so that behaviour changes by editing data
rather than logic.

**Motivation.** A long, linear, occasionally-branching sequence — a memory
controller's initialisation, a link-training protocol, a DMA descriptor walk — written
as a `case` statement is a hundred states that all look the same and none of which can
be reviewed against the specification. As a table, each step is one row, and the rows
can be diffed against the protocol document line by line.

**Applicability.** Use it past the crossover, which in practice is somewhere around
fifteen to twenty states of mostly-linear sequence. **Do not use it** below that: the
engine plus the table is more code than the `case`, and a waveform now shows you a
program counter instead of a named state, which is strictly worse when there are only
six states to name.

**Structure.** The control outputs *are* ROM fields, so there is no decode at all:

```systemverilog
// useq.sv -- each ROM word is {next-address info, control outputs}. Adding a step
// is a table edit. The outputs are a ROM read: one register deep, no decode.
//
// The microcode is built by a constant function, so the table is elaboration-time
// data -- see rom_table.sv for the same idea applied to a numeric table.
```

**Consequences.** *Buys:* a sequence that is reviewable as data; one engine reusable
for any sequence; outputs one register deep regardless of sequence length. *Costs:*
indirection — a bug is now in the engine *or* in the table, and you have to work out
which; a ROM (which on an FPGA may be a whole block RAM); and one cycle of fetch
latency unless you pipeline it, which reintroduces branch timing.

**Implementation.**
1. **Build the table with a constant function, not a hex file.** A `$readmemh` file is
   a second source of truth that no linter checks against the design. An elaboration-time
   function is checked by the compiler
   ([#15](42-clocking-elaboration-and-timing-patterns.md#15-elaboration-time-tables)).
2. **Decide the branch discipline before writing the table.** One conditional branch
   plus a halt covers most sequences; a full instruction set is a CPU, and if you are
   building a CPU, build one deliberately.
3. **The program counter is the thing to watch, so make it observable.** Expose it to a
   status register ([#8 Debug Hooks](43-memory-and-verification-patterns.md#8-debug-hooks));
   the whole benefit of the pattern evaporates if you cannot see where the sequence got
   stuck.
4. **Guard the halt.** A sequencer that walks off the end of its table into
   uninitialised ROM is a hang with no diagnosis. Make the last word an explicit halt
   and assert that the PC never exceeds the table length.

**Known uses.** [`useq.sv`](../examples/rtl/useq.sv), exercised in
[`techniques_tb.sv`](../examples/tb/techniques_tb.sv) walking a
request → grant → write → ack → done protocol.
[docs/23](23-structural-design-techniques.md) has the crossover argument.

**Related.** [#14 Hierarchical FSM](#14-hierarchical-fsm) (the alternative when the
sequence is nested rather than long),
[#15 Elaboration-Time Tables](42-clocking-elaboration-and-timing-patterns.md#15-elaboration-time-tables),
[#13 FSMD](#13-fsmd-controller--datapath).

---

## 16. Start/Done (Go/Busy) Handshake

*GoF analogue: **Command**. Good.*

**Intent.** Give a multi-cycle block a command interface, so the caller does not have
to know its latency.

**Motivation.** A caller that waits a fixed number of cycles is coupled to the
implementation for ever: change the divider from restoring to SRT and every caller
breaks. `start` in, `done` out, and the latency becomes an implementation detail.

**Applicability.** Use it for any block whose latency is multi-cycle, variable or
likely to change: dividers, CORDIC, a DMA, an accelerator. **Do not use it** for a
fixed-latency pipeline — there, [#17 Valid-Bit Pipeline](#17-valid-bit-pipeline) gives
you one result per cycle instead of one per transaction, which is usually an order of
magnitude more throughput. This is the single most common misapplication in the
catalogue: `start`/`done` on something that could have been pipelined throws away
almost all of its throughput.

**Structure.** Two shapes, and the second is better where it applies:

```systemverilog
// (a) Classic start/done, for a block that does one thing at a time.
input  var logic start;     // one cycle
output var logic busy;      // high from start until done
output var logic done;      // one cycle
```

```systemverilog
// (b) valid/ready on both ends, which is start/done plus back-pressure and
// composes with everything else. div_restoring.sv does this:
input  var logic valid_i;   output var logic ready_o;   // accept a command
output var logic valid_o;   input  var logic ready_i;   // deliver a result
```

**Consequences.** *Buys:* the caller is decoupled from the latency. *Costs:* one
transaction at a time unless you add tagging ([#24](#24-tagged-transactions--reorder-buffer)),
so throughput is 1/latency — which for a 32-cycle divider is 3% of a pipelined block's.

**Implementation.**
1. **`done` must be a pulse and `busy` a level, and both must be unambiguous at the
   boundaries.** The cycle `start` is asserted, and the cycle `done` is asserted, are
   where callers get it wrong. Assert `done |-> !busy` or whichever convention you
   chose, and state it in the header.
2. **Prefer form (b).** `valid_i`/`ready_o` in and `valid_o`/`ready_i` out is the same
   handshake as everything else in the design, so the block drops into a stream without
   an adapter, and the result can be back-pressured instead of dropped.
3. **A `start` while busy must be defined.** Ignored is the usual and safest choice;
   assert that it is ignored rather than leaving it to chance.
4. **Report the degenerate inputs.** Divide-by-zero, zero-length transfer: a status
   output, not a hang. `div_restoring.sv` has `div_by_zero` for this.

**Known uses.** [`div_restoring.sv`](../examples/arith/div_restoring.sv) (form b, with
`div_by_zero`), [`bin2bcd.sv`](../examples/rtl/bin2bcd.sv),
the five `fsm_*.sv` controllers (form a, `start`/`busy`/`done`),
[`i2c_master.sv`](../examples/rtl/i2c_master.sv).

**Related.** [#17 Valid-Bit Pipeline](#17-valid-bit-pipeline) (use this instead when
you can), [#14 Hierarchical FSM](#14-hierarchical-fsm) (this is the interface between
its levels), [#26 Watchdog](#26-watchdog--timeout) (what catches a `done` that never
comes).

---

## 17. Valid-Bit Pipeline

**Intent.** Send a validity bit down the pipeline beside the data, so that latency
costs nothing in throughput.

**Motivation.** An N-deep pipeline produces N beats of garbage after reset, and
nothing downstream can tell garbage from data. The naive fix — wait N cycles, then
trust everything — fails the moment there is a gap in the input, and forbids the gap
being there at all. A valid bit travelling with the beat makes the pipeline
self-describing, and then gaps are free.

**Applicability.** Use it in every pipeline. Genuinely every one. **Do not** bother
only when the pipeline is provably never empty and never flushed and its latency is in
a specification — a fixed-rate video path, for example — and even then the valid bit
costs one flop per stage.

**Structure.** One shift register, and the flush only has to touch it:

```systemverilog
// pipe_ctrl.sv
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)      valid_q <= '0;
  else if (flush)  valid_q <= '0;                      // flush wins over `en`
  else if (en)     valid_q <= {valid_q[STAGES-2:0], valid_i};
end
assign valid_o = valid_q[STAGES-1];
assign busy    = |valid_q;
```

**Consequences.** *Buys:* one result per clock at any latency; gaps in the input cost
nothing; flush and reset become cheap because they only touch the control path — the
datapath keeps its stale contents and nothing will look at them. *Costs:* one flop per
stage, and `busy` becomes an OR across all of them.

**Implementation.**
1. **Flush must win over the stall.** An aborted pipeline has to clear even while
   stalled, or the stale beats reappear when the stall lifts.
2. **The valid chain and the data must be the same depth.** Two copies of "how deep is
   this pipeline" is two chances to disagree, and the failure looks like data
   corruption rather than a parameter mistake. Compute it once, in a package:
   `pipe_pkg::cuts_below(CUTS, 4)`.
3. **Do not reset the datapath just because you reset the valid bits.** That is
   precisely what [#25 Minimal Reset](42-clocking-elaboration-and-timing-patterns.md#25-minimal-reset)
   is for, and the valid bit is what makes it safe.
4. **`busy` is an OR tree, and in a deep pipeline it is a real path.** If it feeds a
   `safe` or `ready`, register it — or accept that it is on your critical path.

**Known uses.** [`pipe_ctrl.sv`](../examples/rtl/pipe_ctrl.sv)
([`pipe_ctrl_fv.sby`](../formal/pipe_ctrl_fv.sby)), used by
[`cfg_pipe_scale.sv`](../examples/rtl/cfg_pipe_scale.sv) and the `dot_rs_*` family;
[`pipe_delay.sv`](../examples/rtl/pipe_delay.sv) for the sideband version.

**Related.** [#18 Global Stall](#18-global-stall-pipeline-enable),
[#16 Pipeline Insertion](42-clocking-elaboration-and-timing-patterns.md#16-pipeline-insertion--retiming),
[#25 Minimal Reset](42-clocking-elaboration-and-timing-patterns.md#25-minimal-reset).

---

## 18. Global Stall (Pipeline Enable)

**Intent.** Freeze every stage of a pipeline with one enable.

**Motivation.** Stalling stages independently is how data gets duplicated or dropped.
One enable makes that impossible by construction, which is why this is the first stall
scheme to reach for — and its cost is not logic but *fanout*, which is a different
kind of problem and one the tools can partly fix.

**Applicability.** Use it for a short pipeline whose stall is rare. **Do not use it**
when the pipeline is deep and the stall frequent: bubbles do not collapse, so a
pipeline that is stalled 20% of the time delivers 80% of its throughput even when the
downstream block could have taken a beat from the middle. At that point you want
[elastic control](#1-validready-handshake) — and note that a global stall is the
*degenerate case* of elastic control, with every enable tied together, so the
transition is a controller change and not a redesign.

**Structure.**

```systemverilog
// dot_rs_global.sv -- the whole pattern is the replication.
dot_rs_dp #(.CUTS(CUTS), ...) u_dp ( .adv({4{en}}), ... );
```

**Consequences.** *Buys:* correctness by construction, and the simplest possible
control. *Costs:* fanout — one net to every register in the datapath, which is the
thing that eventually fails timing; and no bubble collapsing, so throughput under
back-pressure is worse than elastic control's. Measured, for comparison: a ripple
`ready` chain costs about `N+3` gates of depth (4 at one stage, 35 at 32), which is the
price elastic control pays instead
([docs/38 §7](38-pipeline-staging-and-stalls.md#7-ripple-back-pressure)).

**Implementation.**
1. **Fix the fanout with replication, not by abandoning the scheme.**
   [#18 Register Duplication](42-clocking-elaboration-and-timing-patterns.md#18-register-duplication)
   gives each region its own copy of the enable, and one extra cycle of latency on the
   enable is usually acceptable where a global stall was acceptable.
2. **Everything the beat carries must be gated by the same enable.** A configuration
   register that advances while the data it belongs to is frozen is the same corruption
   one level down; [docs/39 §7](39-control-registers-and-safe-reconfiguration.md#7-reconfiguring-a-pipeline-quiesce-or-travel)
   measures it.
3. **It hides per-stage bugs from verification.** With all enables one wire, an
   equivalence proof cannot distinguish stage 0's enable from stage 3's. A testbench has
   the same blind spot for the same reason, and worse: a continuously-offered input
   keeps the pipeline full so every enable collapses to `ready` anyway. **Put gaps in
   the stimulus.** Bubbles are what make per-stage control observable.
4. **Clock-gate rather than merely disable, if power matters.** The enable is already
   there; [docs/35](35-low-power-architecture.md) is the follow-through.

**Known uses.** [`dot_rs_global.sv`](../examples/rtl/dot_rs_global.sv) and
[`pipe_ctrl.sv`](../examples/rtl/pipe_ctrl.sv);
[`dot_rs_elastic.sv`](../examples/rtl/dot_rs_elastic.sv) and
[`pipe_ripple_ctrl.sv`](../examples/rtl/pipe_ripple_ctrl.sv) are the elastic
alternative over the same datapath.

**Related.** [#17 Valid-Bit Pipeline](#17-valid-bit-pipeline),
[#13 FSMD](#13-fsmd-controller--datapath),
[#18 Register Duplication](42-clocking-elaboration-and-timing-patterns.md#18-register-duplication),
[docs/38 §5–§9](38-pipeline-staging-and-stalls.md#5-the-stall-taxonomy).

---

## 19. Arbiter

*GoF analogue: **Mediator**. Good — N peers that would otherwise have to know about
each other.*

**Intent.** Grant one of N requesters access to a shared resource, by priority or
fairly.

**Motivation.** Two masters on one bus, four channels on one DSP, eight ports on one
memory. Without an arbiter each requester has to know about the others; with one, each
knows only `req` and `grant`. The interesting part is *which* policy, because
fixed-priority is one gate and starves, and fair costs more.

**Applicability.** Fixed priority when the requesters genuinely have a priority order
and the low-priority ones can wait for ever (an error path, a debug port). Round-robin
when they are peers. Weighted when they are peers with different bandwidth shares.
**Do not** use fixed priority "for now" on peers — starvation under load is a
bug that appears only under load, which is the worst time to find it.

**Structure.** Round-robin is two fixed-priority arbiters and a mask, which is worth
knowing because it is so much cheaper than a rotating barrel:

```systemverilog
// arb_round_robin.sv
assign masked_req = req & mask;                  // those above the pointer
arb_fixed #(.N(N)) u_hi (.req(masked_req), .grant(grant_masked));
arb_fixed #(.N(N)) u_lo (.req(req),        .grant(grant_unmasked));
assign grant = (|masked_req) ? grant_masked : grant_unmasked;

always_ff @(posedge clk or negedge rst_n)
  if (!rst_n)               mask <= '1;
  else if (update && valid) mask <= ~((grant - 1'b1) | grant);   // point past
```

**Consequences.** Fixed priority: one lowest-set-bit circuit, zero state, starves.
Round-robin: two of those plus an N-bit mask register, and no starvation. Weighted:
add a credit counter per agent. All three are combinational in `req`→`grant`, so the
arbiter is on the requester's critical path unless you register the grant — which costs
a cycle of latency on every transaction.

**Implementation.**
1. **`$onehot0(grant)` and "grant only to a requester" are the two assertions,** and
   they are cheap enough that there is no reason not to have them.
2. **Separate `grant` from `update`.** The pointer must advance when the transaction
   *completes*, not when it is granted; advancing on grant with a multi-beat
   transaction lets a second requester in mid-burst.
3. **Fairness is a liveness property, and bounded formal cannot prove it.** What you
   *can* prove in bounded mode is the bounded version: "no requester waits more than N
   grants". `rtl_smoke_tb.sv` measures fairness with all eight agents requesting, which
   is the practical complement.
4. **Grant-hold for multi-beat transactions is a separate decision from the policy.**
   Forgetting it interleaves two masters' bursts, which downstream is indistinguishable
   from corruption.

**Known uses.** [`arb_fixed.sv`](../examples/rtl/arb_fixed.sv)
(**exhaustively** proved equivalent to an independent lowest-set-bit reference in
[`arb_fixed_fv.sby`](../formal/arb_fixed_fv.sby)),
[`arb_round_robin.sv`](../examples/rtl/arb_round_robin.sv),
[`arb_weighted.sv`](../examples/rtl/arb_weighted.sv).

**Related.** [#10 Stream Router](#10-stream-router-mux--demux--crossbar) (needs one per
output), [#20 Resource Sharing](#20-resource-sharing-time-multiplexing),
[#3 Memory Banking](43-memory-and-verification-patterns.md#3-memory-banking--port-multiplication).

---

## 20. Resource Sharing (Time-Multiplexing)

**Intent.** Serve N channels from one expensive datapath over N cycles.

**Motivation.** A DSP block, a divider, a wide multiplier — there are a fixed number
on the die and they cost real area. If the required throughput is one result per N
cycles per channel, one unit plus a mux serves N channels, and the trade is explicit:
area down by roughly N, throughput per channel down by N.

**Applicability.** Use it when per-channel throughput requirement × N ≤ one unit's
throughput, and when the channels are independent. **Do not use it** when the mux and
the state needed to remember whose turn it is cost more than the unit you saved — which
happens sooner than people expect for cheap units — and do not use it across channels
that must be low-latency, because a channel now waits its turn.

**Structure.** A counter, a mux in, a demux out, and per-channel state:

```systemverilog
// seven_seg_mux.sv -- one segment driver, N digits, with the blanking that stops
// the previous digit ghosting onto the next.
// The general shape:
assign operand    = channel_data[turn];
always_ff @(posedge clk) result[turn] <= f(operand);
```

**Consequences.** *Buys:* area, roughly divided by N. *Costs:* throughput per channel,
divided by N; a mux and demux of the datapath width, which for a wide datapath is not
free; N× the state, because each channel needs its own accumulator or context; and
latency, because a channel waits up to N−1 cycles for its turn.

**Implementation.**
1. **Count the mux.** For a narrow operation the mux plus the per-channel state can
   exceed the unit. Measure both with `stat` before committing.
2. **Per-channel state is the hidden cost.** Sharing an *adder* is cheap; sharing an
   *accumulator* means N accumulators plus the adder, which is usually most of the area
   back.
3. **Do not share across clock-enable domains.** If channel 2 is sometimes disabled, a
   fixed round-robin wastes its slot; a request-driven [Arbiter](#19-arbiter) does not.
4. **Blanking and dead cycles are part of the pattern in the physical case.** A
   time-multiplexed display driver needs an inter-digit blank or the previous digit
   ghosts; the general lesson is that the shared resource's *output* may need settling
   time the datapath version did not.

**Known uses.** [`seven_seg_mux.sv`](../examples/rtl/seven_seg_mux.sv) (one driver, N
digits, with blanking), [`vid_axis_csc.sv`](../examples/rtl/vid_axis_csc.sv)
(per-component reuse of one matrix structure across N pixels).

**Related.** [#21 Interleaving](#21-interleaving-c-slowing) (the same mux, used to fill
a pipeline rather than to save one), [#19 Arbiter](#19-arbiter),
[#3 Memory Banking](43-memory-and-verification-patterns.md#3-memory-banking--port-multiplication).

---

## 21. Interleaving (C-Slowing)

**Intent.** Keep a pipeline full when a feedback loop forbids pipelining, by rotating N
independent contexts through it.

**Motivation.** An accumulator cannot be pipelined: the next add needs this add's
result, so the adder's latency is the cycle time and no amount of registering helps.
But if there are N independent accumulations to do, they can take turns: while
context 0's add is in flight, contexts 1..N−1 issue theirs. The loop is still there;
it just has N cycles to close.

**Also known as.** C-slow retiming (strictly: register every path N times and
interleave N contexts — the general technique), multi-context pipelining.

**Applicability.** Use it when you have a recurrence *and* N independent instances of
it: N channels of a filter, N accumulators, N CRC streams. **Do not use it** with one
stream — there is nothing to interleave, and the right answer is a
[carry-save accumulator](../examples/rtl/csa_accumulator.sv) or a
[tree reduction](42-clocking-elaboration-and-timing-patterns.md#19-tree-reduction) over
blocks. And note it does not reduce *latency* for any single context; it increases it.

**Structure.** Lanes plus a rotating select, with the adder's latency as a parameter:

```systemverilog
// acc_interleaved.sv -- LANES independent partial sums, PIPE cycles of adder
// latency. The elaboration-time check is the pattern's precondition.
if (PIPE < 1 || PIPE > LANES) begin : g_chk
  $error("acc_interleaved: need 1 <= PIPE (%0d) <= LANES (%0d)", PIPE, LANES);
end

assign sum_issue = lane[sel] + ACCW'(din);      // din signed -> sign-extends
```

**Consequences.** *Buys:* the clock rate of a pipelined datapath despite a
recurrence; full utilisation of one expensive unit. *Costs:* N× the state (one context
each); latency per context multiplied by roughly N; and a final reduction step to
combine the N partial results, which is itself a
[tree](42-clocking-elaboration-and-timing-patterns.md#19-tree-reduction).

**Implementation.**
1. **`PIPE <= LANES` is a hard precondition, so check it at elaboration.** With fewer
   lanes than the adder's latency, a context's next issue arrives before its previous
   result is written back, and the accumulation is silently wrong. This is the clearest
   case in the catalogue for [#14](42-clocking-elaboration-and-timing-patterns.md#14-elaboration-time-assertion).
2. **Do not forget the final reduction.** `total` is the sum of the lanes, and it is
   only valid once every lane's in-flight add has landed — hence a `busy` output.
3. **Clearing must clear every lane.** A partial clear leaves one context carrying the
   previous frame's sum, which looks like an occasional large error.
4. **Check it against a plain accumulator over thousands of samples,** at several
   `LANES`/`PIPE` combinations including the degenerate 1/1.
   [`pipeline_tb.sv`](../examples/tb/pipeline_tb.sv) runs 1/1, 4/1, 4/4 and 8/2.

**Known uses.** [`acc_interleaved.sv`](../examples/rtl/acc_interleaved.sv);
[`csa_accumulator.sv`](../examples/rtl/csa_accumulator.sv) is the
*other* answer to the same problem (one full-adder delay per cycle, independent of
width), and worth comparing.

**Related.** [#20 Resource Sharing](#20-resource-sharing-time-multiplexing),
[#16 Pipeline Insertion](42-clocking-elaboration-and-timing-patterns.md#16-pipeline-insertion--retiming),
[docs/21](21-pipelining.md) on loops.

---

## 22. Ping-Pong (Double) Buffer

**Intent.** Two buffers alternating, one filling while the other drains, so a producer
and a consumer never contend for the same storage.

**Motivation.** A frame buffer, a line buffer for a block-based algorithm, an ADC
capture: the unit of work is a whole buffer, not a beat. A single buffer means the
producer must wait for the consumer to finish reading, which halves the rate. Two
buffers and a swap remove the wait entirely, at exactly 2× the memory.

**Applicability.** Use it when the unit of exchange is a whole buffer and the two sides
take comparable times. **Do not use it** when the unit is a beat — that is a
[FIFO](#4-fifo-decoupler), which needs far less than 2× the storage for the same
decoupling — and do not use it when one side is much slower, because the fast side ends
up waiting anyway and you have paid double for nothing.

**Structure.** *Sketch only.* One bit of state, and the whole difficulty is the swap:

```systemverilog
// Sketch. The swap must be atomic and only at a point where BOTH sides are done.
logic        sel_q;            // which buffer the producer owns
logic        wr_done, rd_done;

assign wr_addr_full = {sel_q,  wr_addr};       // producer writes buffer sel_q
assign rd_addr_full = {~sel_q, rd_addr};       // consumer reads the other

always_ff @(posedge clk or negedge rst_n)
  if (!rst_n)                  sel_q <= 1'b0;
  else if (wr_done && rd_done) sel_q <= ~sel_q;   // BOTH, not either
```

**Consequences.** *Buys:* full rate on both sides with no beat-level handshake.
*Costs:* exactly 2× the memory, and — the part that is easy to miss — latency of one
whole buffer period, because the consumer cannot start until the producer has finished
the buffer.

**Implementation.**
1. **The swap condition is `wr_done && rd_done`, not either alone.** Swapping when only
   the writer is done hands the consumer a buffer it has not finished reading. This is
   the bug, and it is the same *shape* as the commit-point problem in
   [docs/39](39-control-registers-and-safe-reconfiguration.md): a shared resource may
   only change hands at a point both parties agree is safe.
2. **If the two sides are in different clock domains, the swap is a CDC.** One bit,
   but it must cross with [#2](42-clocking-elaboration-and-timing-patterns.md#2-toggle-pulse-synchronizer)
   and the *memory* must then be a true dual-port with independent clocks.
3. **Address the buffers by concatenation, not by a mux.** `{sel, addr}` into one
   double-depth memory usually maps better than two memories and a mux, and it makes the
   "which buffer" question a single bit everywhere.
4. **N-buffering generalises it, and three is often the right number.** With two, a
   slow consumer stalls the producer for a whole buffer period; with three, it has
   slack. The state becomes a small ring rather than one bit.

**Known uses.** *Sketch only — no ping-pong module here.*
[`vid_axis_line_buffer.sv`](../examples/rtl/vid_axis_line_buffer.sv) is the
ring-buffer cousin: TAPS lines held simultaneously, which is N-buffering with the
consumer reading all N at once rather than alternating.

**Related.** [#4 FIFO Decoupler](#4-fifo-decoupler),
[#2 Line Buffer](43-memory-and-verification-patterns.md#2-line-buffer--sliding-window),
[#4 Async FIFO](42-clocking-elaboration-and-timing-patterns.md#4-async-fifo-gray-pointers).

---

## 23. Credit-Based Flow Control

**Intent.** Let a sender track the receiver's free space directly, so it never has to
wait for a `ready` that is many cycles away.

**Motivation.** `ready` works because the answer comes back in the same cycle. Across
a long pipeline, a chip boundary or a serial link, it does not: by the time `ready`
falls the sender has already launched several beats. Credits invert the problem — the
receiver tells the sender how much room it has, in advance, and the sender spends
credits as it sends.

**Applicability.** Use it when the round-trip latency between sender and receiver
exceeds the depth of slack you are willing to build at the receiver — links, NoCs,
anything crossing a chip. **Do not use it** for a local connection: it costs a counter
at each end plus a return path, and `ready` is free and exact. Do not use it where the
receiver's consumption rate is unbounded-variable either; credits bound the *space*, not
the rate.

**Structure.** *Sketch only.* Two counters and a return channel:

```systemverilog
// Sketch. Sender side.
logic [CW-1:0] credit_q;                       // beats the receiver can accept

assign can_send = (credit_q != '0);
assign s_ready  = can_send;                    // never mentions a remote signal

always_ff @(posedge clk or negedge rst_n)
  if (!rst_n)                       credit_q <= INITIAL_CREDIT;
  else credit_q <= credit_q - CW'(send) + CW'(credit_return);

// INITIAL_CREDIT must be >= round-trip latency, or the link idles waiting for
// returns even though the receiver has room.
```

**Consequences.** *Buys:* full rate over an arbitrarily long round trip; and the
sender's `ready` is purely local, so no timing path crosses the link. *Costs:* a
counter at each end, a credit-return channel, and an initial-credit value that must be
at least the round-trip latency — which means the receiver must have that much buffer,
so you have not removed the storage, you have moved it and made it explicit.

**Implementation.**
1. **Initial credit ≥ round-trip latency, or the link idles.** This is the sizing
   calculation and it is the whole design.
2. **Credit returns must not be lost.** A dropped return permanently reduces the
   link's capacity — a slow leak that looks like gradual performance degradation.
   Return them as a *count* that is idempotent to re-send, or acknowledge them.
3. **Never let credit go negative.** Assert it. An underflow means the sender sent
   without credit, and the receiver has already overflowed.
4. **Credits bound space, not time.** A receiver that stops consuming still stops the
   link; credits just make it stop cleanly.

**Known uses.** *Sketch only.*
[`arb_weighted.sv`](../examples/rtl/arb_weighted.sv) uses per-agent credits, but for
*fairness* rather than flow control — a different use of the same counter.
[docs/30](30-flow-control-and-handshakes.md) covers the scheme.

**Related.** [#1 Valid/Ready](#1-validready-handshake) (what this replaces),
[#4 FIFO Decoupler](#4-fifo-decoupler) (where the receiver's space actually lives),
[#20 Lookahead](42-clocking-elaboration-and-timing-patterns.md#20-lookahead--precomputation).

---

## 24. Tagged Transactions / Reorder Buffer

**Intent.** Let several transactions be outstanding at once and returned out of order,
then put the responses back in order.

**Motivation.** A single-outstanding interface has throughput 1/latency. If the
latency is a DRAM access, that is catastrophic, and the fix is to have many requests in
flight. But responses then come back in whatever order the targets finish, and most
consumers need them in issue order — so something has to remember the order and hold
the early ones.

**Applicability.** Use it where latency is long, variable and the target genuinely can
reorder: AXI with multiple IDs, a memory controller, several parallel accelerators.
**Do not use it** to fix a latency you could have pipelined away, and do not use it if
the consumer can tolerate out-of-order responses — then you only need the *tag*, which
is cheap, and not the *buffer*, which is not.

**Structure.** *Sketch only.* A tag, and slots indexed by it:

```systemverilog
// Sketch. Issue: allocate a tag. Return: write the slot. Retire: in order.
logic [NSLOT-1:0]           busy_q, done_q;
logic [DW-1:0]              slot   [NSLOT];
logic [$clog2(NSLOT)-1:0]   head_q;            // next tag to RETIRE

assign issue_ok  = !busy_q[alloc_tag];
assign retire_ok = done_q[head_q];             // in-order retirement
assign m_tdata   = slot[head_q];
```

**Consequences.** *Buys:* throughput limited by the target rather than by latency.
*Costs:* a slot's worth of storage per outstanding transaction (which is the *product*
of width and outstanding count, and is usually the dominant cost); tag allocation and
free logic; and an interface that now has a `tag` field everything must carry. Debug
gets substantially harder — a waveform no longer shows request and response adjacent.

**Implementation.**
1. **Tag reuse is the bug.** A tag freed before its response has arrived matches the
   *next* transaction's response to the previous requester. Free on retirement, not on
   response, and assert `!busy_q[alloc_tag]` at issue.
2. **Sequence numbering is exactly the right verification technique.** Make the payload
   a counter and check the output sequence: loss, duplication and reordering all become
   one assertion.
3. **The buffer must be sized for the worst reordering, not the average.** With N
   outstanding, N−1 responses may have to wait for the head.
4. **Do not reorder to "fix" a join.** If two branches of a pipeline can return out of
   order, a deeper [Join](#11-fork--join) does not help; tag them. And conversely, a
   skew buffer is *not* a reorder buffer — it has no mechanism to reorder anything.

**Known uses.** *Sketch only.*
[`axil_slave.sv`](../examples/rtl/axil_slave.sv) is deliberately single-outstanding and
says so in its header: "the cost is throughput, not correctness", which is the honest
version of not implementing this pattern.

**Related.** [#16 Start/Done](#16-startdone-gobusy-handshake) (single outstanding, the
degenerate case), [#11 Fork / Join](#11-fork--join),
[#10 Stream Router](#10-stream-router-mux--demux--crossbar).

---

## 25. Sticky Status / Interrupt Aggregator

*GoF analogue: **Observer**. Good, with one difference worth noting: the hardware
subject **latches**, so an observer that was not looking still learns.*

**Intent.** Latch an event into a write-1-to-clear bit, mask it, and OR the unmasked
bits into one interrupt line.

**Motivation.** An event lasting one cycle, reported by a level, is invisible to
software that polls every millisecond. A sticky bit records that it happened. Masking
must then hide the interrupt *without discarding the record*, so software can enable
the source later and still learn what it missed.

**Applicability.** Use it for every asynchronous event software needs to know about:
errors, completions, overruns, FIFO thresholds. **Do not** make a *state* sticky —
"FIFO is full" is a level and should read as one; sticky is for *events*. Confusing the
two gives software a bit it cannot clear because the condition is still true.

**Structure.** Set beats clear, and masking does not discard:

```systemverilog
// csr_bank.sv -- W1C with the set winning a same-cycle race.
if (wen && hit_stat) status_q <= (status_q & ~wdata) | status_set;
else                 status_q <=  status_q          | status_set;

// irq_ctrl.sv -- mask affects the OUTPUT, never the latch.
assign irq = |(status_q & mask_q);
```

**Consequences.** *Buys:* no event is lost between polls; one interrupt line for N
sources; software can enable a source retrospectively. *Costs:* two flops per source
(status and mask), a read mux, and an OR tree for the line. The real cost is a
*protocol* software must get right — read, then write back the bits you saw.

**Implementation.**
1. **The hardware set must beat a simultaneous software clear.** Otherwise the event
   that arrived during the clear disappears — a lost interrupt that reproduces once a
   week. Assert it:
   `(|status_set) |=> ((status_q & $past(status_set)) == $past(status_set))`.
2. **W1C, not "write zero".** "Read it, then write zero" clears every event that
   arrived in between. Writing a one to the bit you read clears only what you saw.
3. **Masking hides, it does not discard.** Mask the OR into the interrupt line, never
   the write into the latch.
4. **Give each source its own bit.** An aggregated "something went wrong" bit costs the
   same and tells software nothing.

**Known uses.** [`irq_ctrl.sv`](../examples/rtl/irq_ctrl.sv) (latch, mask, prioritise),
[`csr_bank.sv`](../examples/rtl/csr_bank.sv)'s W1C register, exercised with a
same-cycle set/clear race in [`bus_tb.sv`](../examples/tb/bus_tb.sv) and
[`sysmod_tb.sv`](../examples/tb/sysmod_tb.sv).

**Related.** [#7 CSR Bank](#7-csr-bank-register-map),
[#26 Watchdog](#26-watchdog--timeout),
[#9 Performance Counters](43-memory-and-verification-patterns.md#9-performance-counters).

---

## 26. Watchdog / Timeout

**Intent.** Turn a hang into a reported error at a bounded time.

**Motivation.** Every handshake in a design is a potential hang: a `done` that never
comes, a `ready` that never rises, a bus that never responds. Without a timeout the
symptom is "the system stopped", with no information about where. With one, it is an
error bit naming the block — and the difference in debugging time is enormous.

**Applicability.** Put one on every interface where the other side could stop
responding: external buses, links, anything off-chip, and any internal handshake whose
completion depends on data. **Do not** put one on a handshake whose partner is
provably always ready, and do not set the period so tight that a legitimate slow
response trips it — a watchdog that fires spuriously gets disabled, and then it is
worse than nothing.

**Structure.** A counter and a reload, plus — for the harder version — a *window*:

```systemverilog
// watchdog.sv -- a WINDOWED watchdog: a kick that is too EARLY is also a fault.
// Late means hung; early means the kicker is looping without doing the work.
// One counter, two comparators, two distinct error outputs.
```

**Consequences.** *Buys:* a bounded time to diagnosis, and an error that names a
block. *Costs:* a counter per monitored interface (wide, because the period is long), a
comparator, and a decision about what to *do* — flag, reset the block, or reset the
system — which is a system-level question, not a module one.

**Implementation.**
1. **Decide flag-versus-recover explicitly, and per interface.** A watchdog that resets
   the whole system on a transient bus stall is a denial of service you built yourself.
2. **A too-early kick is also a fault.** The windowed form catches a kicker stuck in a
   loop that kicks but does not progress — which a simple timeout cannot see, because
   from its point of view everything is fine.
3. **The timeout must be a parameter, and the default must be generous.** It depends on
   the clock rate and on the slowest legitimate partner, neither of which the module
   knows.
4. **Make the fault sticky.** By the time software looks, the interface may have
   recovered; [#25 Sticky Status](#25-sticky-status--interrupt-aggregator) is how it
   still learns.
5. **Test both edges of the window.** [`periph_tb.sv`](../examples/tb/periph_tb.sv)
   injects an early kick and a late one, because a watchdog that only catches late is
   half a watchdog.

**Known uses.** [`watchdog.sv`](../examples/rtl/watchdog.sv) — windowed, with early and
late faults, proved in [`watchdog_fv.sby`](../formal/watchdog_fv.sby).

**Related.** [#16 Start/Done](#16-startdone-gobusy-handshake) (what it watches),
[#25 Sticky Status](#25-sticky-status--interrupt-aggregator),
[#6 Interface Assertions](43-memory-and-verification-patterns.md#6-interface-assertions-sva-contract)
(the simulation-time equivalent).

---

## See also

- [docs/40 — RTL design patterns: the catalogue](40-rtl-design-patterns.md) — the frame,
  the template, the index and the anti-patterns
- [docs/42 — Clocking, elaboration-time and timing patterns](42-clocking-elaboration-and-timing-patterns.md)
- [docs/43 — Memory and verification patterns](43-memory-and-verification-patterns.md)
- [docs/30 — Flow control and handshakes](30-flow-control-and-handshakes.md) — the
  contract behind the whole structural group
- [docs/26 — FSM coding styles](26-fsm-coding-styles.md) — the behavioural group's
  mechanics
- [docs/38 — Pipeline staging and stall control](38-pipeline-staging-and-stalls.md) —
  where the slice and stall numbers were measured
- [docs/39 — Control registers and safe reconfiguration](39-control-registers-and-safe-reconfiguration.md)
  — the commit point, which is a pattern this catalogue's usual sources omit
