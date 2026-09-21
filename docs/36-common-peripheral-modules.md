# Common Peripheral Modules

The blocks that appear in almost every design: timers, debouncers, watchdogs,
serial interfaces, bus slaves, stream converters, interrupt controllers. None of
them is hard. All of them have two or three decisions that are easy to get
wrong in a way that works on the bench and fails in the field.

This document is the catalogue, the composition pattern that ties them together,
and the recurring rules — with the bugs that were actually hit building them,
because the way each was *found* transfers further than the fix.

Companion code, all verified:
[`examples/rtl/`](../examples/rtl/) ·
simulated by [`periph_tb.sv`](../examples/tb/periph_tb.sv),
[`serial_tb.sv`](../examples/tb/serial_tb.sv),
[`bus_tb.sv`](../examples/tb/bus_tb.sv),
[`sysmod_tb.sv`](../examples/tb/sysmod_tb.sv) and
[`integration_tb.sv`](../examples/tb/integration_tb.sv),
proved in [`formal/`](../formal/)

---

## Contents

- [1. The catalogue](#1-the-catalogue)
- [2. The composition pattern](#2-the-composition-pattern)
- [3. Six rules that keep recurring](#3-six-rules-that-keep-recurring)
- [4. Timers and I/O](#4-timers-and-io)
- [5. Serial interfaces](#5-serial-interfaces)
- [6. Bus slaves](#6-bus-slaves)
- [7. Stream converters](#7-stream-converters)
- [8. The bug catalogue](#8-the-bug-catalogue)
- [9. Checklist](#9-checklist)

---

## 1. The catalogue

| Module | What it is | The decision that matters |
|---|---|---|
| [`clk_div_en`](../examples/rtl/clk_div_en.sv) | periodic enable | it is an **enable**, not a divided clock |
| [`edge_detect`](../examples/rtl/edge_detect.sv) | rise / fall / any | the reset value of the delayed copy |
| [`pulse_extend`](../examples/rtl/pulse_extend.sv) | stretch a pulse | retrigger or not; it is **not** a CDC |
| [`debounce`](../examples/rtl/debounce.sv) | contact filter | an integrator, not a one-shot timer |
| [`watchdog`](../examples/rtl/watchdog.sv) | liveness check | **windowed**, and the expiry is sticky |
| [`timer`](../examples/rtl/timer.sv) | one-shot / periodic | counts **down**; period is reload+1 |
| [`pwm`](../examples/rtl/pwm.sv) | pulse-width modulator | both endpoints clean; duty shadowed |
| [`hex7seg`](../examples/rtl/hex7seg.sv) | hex to segments | polarity |
| [`seven_seg_mux`](../examples/rtl/seven_seg_mux.sv) | multiplexed display | refresh rate, and blanking to stop ghosting |
| [`gpio`](../examples/rtl/gpio.sv) | pins | output **enable**, never tristate internally |
| [`quad_decoder`](../examples/rtl/quad_decoder.sv) | encoder decode | an illegal transition is an **error**, not two steps |
| [`irq_ctrl`](../examples/rtl/irq_ctrl.sv) | interrupt controller | masking hides, it does not discard |
| [`spi_master`](../examples/rtl/spi_master.sv) | SPI | CPOL/CPHA = which edge samples |
| [`spi_slave`](../examples/rtl/spi_slave.sv) | SPI | oversampled; SCLK is an input, not a clock |
| [`i2c_master`](../examples/rtl/i2c_master.sv) | I2C | open-drain; read the lines back |
| [`uart_tx`](../examples/rtl/uart_tx.sv) / [`uart_rx`](../examples/rtl/uart_rx.sv) | UART | sample at the bit **midpoint** |
| [`uart_periph`](../examples/rtl/uart_periph.sv) | UART + FIFOs + registers | a side-effecting read |
| [`csr_bank`](../examples/rtl/csr_bank.sv) | registers | RW / RO / **W1C**, set beats clear |
| [`apb_slave`](../examples/rtl/apb_slave.sv) | APB4 | registered `pready`; one-cycle strobes |
| [`axil_slave`](../examples/rtl/axil_slave.sv) | AXI4-Lite | AW and W in **either order** |
| [`wb_slave`](../examples/rtl/wb_slave.sv) | Wishbone B4 | qualify on CYC **and** STB |
| [`axis_upsizer`](../examples/rtl/axis_upsizer.sv) / [`axis_downsizer`](../examples/rtl/axis_downsizer.sv) | stream width | TKEEP, for the short final group |

---

## 2. The composition pattern

Three of these modules are bus slaves and they all produce the **same
four-signal register port**:

```systemverilog
output [AW-1:0]   reg_addr;
output            reg_wen;
output [DW-1:0]   reg_wdata;
output [DW/8-1:0] reg_wstrb;
output            reg_ren;
input  [DW-1:0]   reg_rdata;     // combinational on reg_addr
input             reg_err;
```

So a peripheral is written once and put on any bus:

```
        ┌────────────┐     reg port     ┌──────────────┐
  APB ──┤ apb_slave  ├──────────────────┤              │
 AXIL ──┤ axil_slave ├──────────────────┤ uart_periph  │── pins
   WB ──┤ wb_slave   ├──────────────────┤  csr_bank    │
        └────────────┘                  └──────────────┘
                                               │ irq
                                        ┌──────┴─────┐
                                        │  irq_ctrl  │
                                        └────────────┘
```

This split is worth copying for a reason beyond reuse: **bus protocol bugs and
register behaviour bugs are different bugs.** They are found by different tests
and fixed in different places. Keeping them in one module means re-debugging
both every time either changes.
[`bus_tb.sv`](../examples/tb/bus_tb.sv) leans on that directly — it runs an
identical `csr_bank` behind both APB and AXI4-Lite, so a failure through one bus
and not the other is a bus bug, and one through both is a register bug.

The same reasoning applies to interrupts. Peripherals emit **one-cycle pulses**
and [`irq_ctrl`](../examples/rtl/irq_ctrl.sv) does the latching, masking and
prioritising once. A peripheral that latches its own interrupt flag duplicates
an interrupt controller, badly, and usually without the set-beats-clear rule.

[`uart_periph`](../examples/rtl/uart_periph.sv) exists to demonstrate the whole
stack: `uart_tx` + `uart_rx` + two `sync_fifo`s + a register map, every part of
it already tested on its own, so the only thing left to get wrong is the wiring.

---

## 3. Six rules that keep recurring

### An enable, not a clock

```systemverilog
always_ff @(posedge clk) slow <= ~slow;     // DON'T: now it is a clock
always_ff @(posedge clk) if (tick) ...      // DO
```

A clock made from logic needs its own tree, a `create_generated_clock`, and a
DFT bypass, and it turns one timing domain into two.
[`clk_div_en`](../examples/rtl/clk_div_en.sv) exists so this is a module
instantiation rather than a temptation. See
[docs/24](24-dft-clocking-and-x-discipline.md) and
[docs/32 §3](32-timing-constraints.md#3-generated-and-derived-clocks).

### Synchronize at the boundary, exactly once

Every asynchronous input gets a synchronizer before *anything* reads it, and
only one — two synchronizers on the same signal give two answers.
[`gpio`](../examples/rtl/gpio.sv) enforces this structurally: it does not expose
the raw pad at all, and the edge pulses come from the same synchronized copy the
software reads, so they cannot disagree.
[`spi_slave`](../examples/rtl/spi_slave.sv) and
[`debounce`](../examples/rtl/debounce.sv) say the same thing in their headers,
and debouncing does **not** substitute for synchronizing. See
[docs/28](28-clock-domain-crossing.md).

### Set beats clear

Whenever hardware sets a flag and software clears it, a set arriving in the
same cycle as the clear must **survive**:

```systemverilog
status_q <= (status_q & ~wdata) | status_set;   // set wins, by construction
```

Otherwise the event that arrived during the clear disappears. It is a lost
interrupt that reproduces about once a week.
[`csr_bank`](../examples/rtl/csr_bank.sv),
[`irq_ctrl`](../examples/rtl/irq_ctrl.sv) and
[`uart_periph`](../examples/rtl/uart_periph.sv) all follow it, all assert it,
and [`bus_tb.sv`](../examples/tb/bus_tb.sv) races it deliberately.

### One-cycle strobes for side-effecting access

Reading a FIFO pops it. Reading a clear-on-read counter clears it. So a bus
slave must pulse `ren` for exactly one cycle, not drive it from a decoded
address for the whole transfer:

```systemverilog
assign reg_ren = access && !pwrite && last_cycle;   // apb_slave
```

Hold it instead and the FIFO is popped once per cycle of the ACCESS phase, and
bytes vanish in a pattern that depends on the wait states.
`uart_periph` asserts the contract from the other side, so a slave that gets it
wrong is caught at the peripheral rather than three layers away.

### Drop and record, never overwrite

A receiver with nowhere to put data discards it and sets a sticky flag.
Overwriting a FIFO corrupts bytes software has not read yet, turning a
recoverable overrun into silent corruption:

```systemverilog
assign rxf_wr = rx_valid && !rxf_full;                 // drop when full
rx_overrun_q <= (rx_overrun_q && !err_clr) || (rx_valid && rxf_full);
```

The same instinct drives [`quad_decoder`](../examples/rtl/quad_decoder.sv):
two bits changing at once is reported as an error and the count does *not*
move. Counting it as a double step turns a sampling failure into a position that
drifts silently, which homing cannot fix because nothing reported it.

### Degenerate parameters must work

`DIV == 1`, `CYCLES == 1`, `LATENCY == 0`, `RATIO == 2`, a 1-beat packet.
These are the configurations a caller reaches by sweeping a parameter, and they
are where off-by-one bugs live. Two of the three real bugs in §8 were exactly
this. See [docs/34 §6](34-coding-conventions-and-reuse.md#6-parameterisation).

---

## 4. Timers and I/O

**Count down, not up.** The terminal condition `count == 0` is a NOR of the
count bits; counting up to a compare value needs a full-width comparator on the
critical path. [`timer`](../examples/rtl/timer.sv) counts down, and its period is
`reload + 1` ticks because the zero cycle is a cycle too — stated in the header
rather than discovered, and it is why every real timer peripheral wants `N-1`.

**Prescale with an enable.** Drive `tick_en` from `clk_div_en` rather than
making `reload` 32 bits of microseconds. One small counter beats a wide compare.

**A watchdog should be windowed.** A plain watchdog only catches kicks that are
*late*, which detects a hang but not a runaway: code stuck in a tight loop that
happens to contain the kick keeps it happy forever. Rejecting kicks that are too
*early* means the kick has to come from a path that takes roughly the right
time, which is a crude control-flow-integrity check and is why safety standards
ask for one.

**And its expiry must be sticky.** A watchdog that clears itself produces a
reset with no evidence of why, and a fault that happens once an hour in the
field becomes unattributable. `watchdog`'s stickiness is proved unbounded in
[`formal/watchdog_fv.sby`](../formal/watchdog_fv.sby).

**PWM endpoints are the whole design.** `cnt < duty` gives a constant low at 0%
and a constant high at 100% with no special cases; `cnt <= duty` emits a
one-cycle sliver at 0%, which a motor driver turns into an audible tick. Sample
`duty` once per period into a shadow register, or a mid-period change produces a
short or long pulse — harmless in an LED, not in a half-bridge.

**Debouncing is integration.** The counter must restart on any glitch back to
the old value, which is what makes it immune to a burst that straddles a timer
expiry. Size it between the worst-case bounce and the fastest human press:
roughly 1 ms to 20 ms.

---

## 5. Serial interfaces

### SPI: CPOL and CPHA reduce to one question

**Which edge samples?** CPHA picks it; CPOL picks the idle level, hence which
physical edge that is. Whichever edge samples, the other shifts — that is the
entire mode table.

The consequence people trip on is at the *start* of a transfer. With CPHA=0 the
first bit must already be on the wire before the first edge, because that edge
samples it; with CPHA=1 the first edge presents it. That is why the load path
differs between the two and the shift path does not.

**Do not clock a slave on SCLK.** It makes a pin into a clock: a clock tree, a
clock-capable input, a second domain that stops whenever the master stops, a CDC
on everything coming back, nothing under scan — and no noise margin, so one ring
on the board is one extra bit. [`spi_slave`](../examples/rtl/spi_slave.sv)
oversamples in the system clock domain instead. The cost is a sampling
requirement: at least 4 clocks per SCLK half period.

[`serial_tb.sv`](../examples/tb/serial_tb.sv) wires the master to the slave and
exchanges bytes in both directions at once, in all four modes and both bit
orders. A sign error in "which edge samples" cannot cancel out, because the
master runs on the system clock while the slave oversamples — it cannot be the
same mistake twice.

### I2C: read the lines back

Two open-drain wires with pull-ups. Nothing ever drives a one:

```systemverilog
assign scl_pad = scl_oe ? 1'b0 : 1'bz;    // never assign a 1
```

Reading the lines back is where two features come from:

**Clock stretching.** A slave that needs time holds SCL low after the master
releases it. The master must wait for `scl_i` to actually read high before
timing the high period. This is the most commonly omitted part of a hand-written
I2C master, and it fails *only* against slow slaves — so it passes every bench
test done with a fast one. `serial_tb` stretches the same transfer it has
already run unstretched, so the check is that the data is identical.

**Arbitration.** Release SDA and read back a zero and someone else is pulling
it low; that master has lost and must stop driving.

Every operation is the same four quarter-period phases, which is what keeps
START, STOP and data bits from each needing their own timing code. A START is
"SDA falls while SCL is high" and a STOP is "SDA rises while SCL is high" —
the only two moments SDA may move during a high SCL.

---

## 6. Bus slaves

| | APB4 | AXI4-Lite | Wishbone B4 |
|---|---|---|---|
| Channels | one | **five, independent** | one |
| Transfer | 2 cycles | handshake per channel | 1 handshake |
| Ordering trap | — | AW and W **either order** | — |
| Qualify on | `psel && penable` | each `*valid` | `cyc && stb` |
| Response | `pready`, `pslverr` | `bresp` / `rresp` | `ack` / `err` |

**Register the response.** `pready`, `ack` and every `*ready` must be functions
of registers, never combinational from the request. A manager may drive its
request from the response, and then the two form a loop; registering breaks it
by construction rather than by inspection.

**AXI4-Lite's AW and W arrive in either order**, with any gap, and nothing in
the specification lets a subordinate require one. A subordinate that waits for
AW before accepting W deadlocks against a manager that waits for W to be
accepted before sending AW. Accept each channel into its own holding register
the moment it arrives and do the write when both are present.
`bus_tb` issues every write three ways — address first, data first, together.

**Exactly one B per write, and none before both halves are accepted.** Issuing
B early looks fine until the manager counts outstanding writes.
[`formal/axil_slave_fv.sby`](../formal/axil_slave_fv.sby) proves the accounting
unbounded, with the manager's obligations as assumptions and the register bank
left free, so it holds for any bank behind the subordinate.

**Wishbone: qualify on CYC as well as STB.** CYC means a bus cycle is in
progress; STB means *this* transfer is valid. Answering on STB alone responds to
transfers aimed at another slave and corrupts someone else's read.

---

## 7. Stream converters

The only safety property worth proving is a **conservation law**: every input
beat becomes exactly one lane of exactly one output beat. Lose lanes and you drop
the tail of a packet; invent them and you pad it.

**The hard case is a packet whose length is not a multiple of the ratio.** It
ends mid-group, so the upsizer must emit a partial word immediately and say
which lanes are real — which is what TKEEP is for. Drop the partial group and
you lose the tail of every such packet; pad it without TKEEP and you silently
append zeros. Both failures depend on the length *modulo* the ratio, which is
exactly what a test sending round numbers of beats never exercises. So
[`sysmod_tb.sv`](../examples/tb/sysmod_tb.sv) sends 1, 5, 6 and 7 beats through
a ratio of 4, and tests the pair **round trip** rather than separately: lane
order and TLAST position are both wrong in ways a beat count alone would miss.

`s_tready` must not depend combinationally on `m_tready`, or two converters
back to back form a path the length of the chain
([docs/30](30-flow-control-and-handshakes.md)).

---

## 8. The bug catalogue

Every one of these was hit building the modules in this document.

| Bug | Why it hid | Found by |
|---|---|---|
| `pulse_extend` sized its counter `$clog2(CYCLES)` and loaded `CYCLES-1` | output one cycle narrow; nothing crashes | counting cycles in the testbench |
| `pwm` wrapped on `cnt >= period` instead of `period-1` | every period one cycle long; a stray low cycle at 100% duty | the duty sweep, at the endpoint |
| `i2c_master` sampled SDA in the `ph2` **branch** | a phase body runs every clock of the phase, so `rdata` shifted the same bit in `DIV4` times | reads returned nonsense while writes passed |
| `axis_downsizer` had no TKEEP | packets padded, TLAST 1–3 beats late | the round trip, at lengths off the ratio boundary |

Two of those are worth extracting.

**A phase body is not a one-shot.** In a multi-cycle phase, `case (ph) 2'd2: ...`
executes on *every* clock of that phase. Writes survived the I2C bug because
setting an output repeatedly is idempotent; shifting a register is not, which is
why it appeared only on reads. Anything that accumulates belongs in the
`if (phase_advance)` branch.

**Round numbers hide modular bugs.** Both the `pulse_extend` and
`axis_downsizer` bugs were invisible to a test using convenient values. Test the
degenerate parameter, the length that does not divide, and the endpoint.

And from the testbenches rather than the designs: the I2C behavioural slave
watched for a STOP with `fork ... join_any`, and because that branch completed on
*any* rise of SDA rather than only one while SCL was high, `join_any` killed the
byte receiver every time the master clocked out a 1. The model is now edge-driven
and pairs each SCL fall with the rise before it. See
[docs/33](33-debugging-and-bringup.md).

---

## 9. Checklist

**Clocking and inputs**
- [ ] No clock generated from logic; use a clock enable.
- [ ] Every asynchronous input synchronized exactly once, before anything reads
      it.
- [ ] Mechanical inputs debounced *after* synchronizing, not instead of it.
- [ ] Oversampled receivers have enough clocks per bit (≥ 4 per half period).

**Registers and interrupts**
- [ ] W1C flags: hardware set beats software clear, and it is asserted.
- [ ] Masking hides an interrupt without discarding it.
- [ ] Peripherals emit pulses; one interrupt controller does the latching.
- [ ] Side-effecting reads get a one-cycle strobe, and the peripheral asserts it.

**Buses**
- [ ] Responses registered, never combinational from the request.
- [ ] AXI4-Lite accepts AW and W in either order.
- [ ] Wishbone qualifies on CYC and STB.
- [ ] Unmapped addresses and writes to read-only registers report an error
      rather than silently succeeding.

**Data paths**
- [ ] Full means drop and record, never overwrite.
- [ ] Illegal input transitions are reported, not guessed at.
- [ ] Stream converters carry TKEEP and are tested at lengths that do not divide
      by the ratio.

**Parameters**
- [ ] Every degenerate value (0, 1, minimum ratio) works and is tested.
- [ ] Counter widths sized to hold the value being loaded, not the count of
      steps.
- [ ] Illegal configurations rejected at elaboration.

---

## See also

- [docs/26: FSM coding styles](26-fsm-coding-styles.md) — most of these modules
  are a state machine and a counter
- [docs/28: Clock domain crossing](28-clock-domain-crossing.md) — synchronizers,
  and why a stretched pulse is not a CDC
- [docs/29: Memories](29-memories-and-inference.md) — the FIFOs inside these
  peripherals
- [docs/30: Flow control](30-flow-control-and-handshakes.md) — valid/ready, skid
  buffers, arbitration
- [docs/32: Timing constraints](32-timing-constraints.md) — what a generated
  clock would have cost
- [docs/33: Debugging and bring-up](33-debugging-and-bringup.md) — how the bugs
  in §8 were found
- [docs/34: Coding conventions](34-coding-conventions-and-reuse.md) — degenerate
  parameters, elaboration-time checks
