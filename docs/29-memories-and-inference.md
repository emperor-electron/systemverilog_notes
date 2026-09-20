# Memories and Inference

A memory is the one construct where *how you write it* decides what physical
resource you get. The same storage described three slightly different ways
becomes a block RAM, a LUT-based distributed RAM, or several thousand flip-flops
— with an area difference of two orders of magnitude and no warning either way.

This document is about matching the inference templates, the read/write
behaviours that distinguish them, and the cases where you must stop relying on
inference.

Companion code, all verified:
[`ram_sp.sv`](../examples/rtl/ram_sp.sv) ·
[`ram_sp_wf.sv`](../examples/rtl/ram_sp_wf.sv) ·
[`ram_sdp.sv`](../examples/rtl/ram_sdp.sv) ·
[`ram_tdp.sv`](../examples/rtl/ram_tdp.sv) ·
[`ram_be.sv`](../examples/rtl/ram_be.sv) ·
[`regfile.sv`](../examples/rtl/regfile.sv) ·
[`rom_table.sv`](../examples/rtl/rom_table.sv) ·
exercised by [`rtl_smoke_tb.sv`](../examples/tb/rtl_smoke_tb.sv) and
[`fifo_tb.sv`](../examples/tb/fifo_tb.sv)

---

## Contents

- [1. The inference rules](#1-the-inference-rules)
- [2. Read-first, write-first, no-change](#2-read-first-write-first-no-change)
- [3. Port configurations](#3-port-configurations)
- [4. Byte enables](#4-byte-enables)
- [5. Register files are not RAMs](#5-register-files-are-not-rams)
- [6. ROMs and initialisation](#6-roms-and-initialisation)
- [7. Output registers and latency](#7-output-registers-and-latency)
- [8. Collisions](#8-collisions)
- [9. When inference is the wrong tool](#9-when-inference-is-the-wrong-tool)
- [10. Reset, X and simulation](#10-reset-x-and-simulation)
- [11. Checklist](#11-checklist)

---

## 1. The inference rules

Every synthesis tool recognises memories by pattern-matching against a template.
The rules that actually decide the outcome:

```systemverilog
logic [DW-1:0] mem [0:DEPTH-1];        // 1. UNPACKED array

always_ff @(posedge clk) begin          // 2. clocked
  if (en) begin
    if (we) mem[addr] <= din;
    dout <= mem[addr];                  // 3. read inside the clocked block
  end
end                                     // 4. NO reset on the array
```

1. **The array must be unpacked.** `logic [DW-1:0] mem [0:DEPTH-1]` is a memory;
   `logic [DEPTH-1:0][DW-1:0] mem` is one enormous vector, and you will get
   flops. This is the single most common reason a design that "should" use block
   RAM does not.

2. **The read must be synchronous** for a block RAM. Block RAMs have a
   registered read port; there is no such thing as an asynchronous block RAM. An
   asynchronous read forces distributed RAM (small, LUT-based) or flops.

3. **One address register, not a registered output of an async read.** These
   are not the same circuit:

   ```systemverilog
   // Infers block RAM: address registered by the RAM itself
   always_ff @(posedge clk) dout <= mem[addr];

   // Does NOT: asynchronous read, then a separate output flop
   assign rd = mem[addr];
   always_ff @(posedge clk) dout <= rd;
   ```
   The second has the same latency and different hardware — distributed RAM plus
   a flop, which for a 32 Kb memory is thousands of LUTs.

4. **No reset on the memory contents.** Block RAMs cannot be reset; there is no
   such port on the primitive. A reset that clears the array makes the memory
   un-inferrable and you get flops instead. Reset the *control* path and the
   output register if you must, never the array.

> Check, do not assume. Vivado reports every inferred memory in the synthesis
> log (`Number of BRAMs`, and a RAM inference table). If a memory you expected
> is not listed, you got flops. Utilisation is the symptom; the log tells you
> why.

---

## 2. Read-first, write-first, no-change

When a read and a write hit the **same address in the same cycle**, three
behaviours are possible. They are different circuits, they are all inferrable,
and picking the wrong one is a silent functional bug.

### Read-first — [`ram_sp.sv`](../examples/rtl/ram_sp.sv)

```systemverilog
always_ff @(posedge clk) begin
  if (en) begin
    if (we) mem[addr] <= din;
    dout <= mem[addr];          // the OLD contents
  end
end
```

`dout` gets what was there *before* the write. The ordering falls out of
non-blocking assignment semantics: both right-hand sides are evaluated before
either update happens, so `mem[addr]` is still the old value when it is read.

### Write-first — [`ram_sp_wf.sv`](../examples/rtl/ram_sp_wf.sv)

```systemverilog
always_ff @(posedge clk) begin
  if (en) begin
    if (we) begin
      mem[addr] <= din;
      dout      <= din;         // the NEW data, forwarded
    end else begin
      dout <= mem[addr];
    end
  end
end
```

Also called write-through. `dout` gets the data being written. Note it is
written as an explicit forward of `din` rather than a read of `mem` — that is
what makes the intent unambiguous to the inference engine.

### No-change

```systemverilog
always_ff @(posedge clk) begin
  if (en && !we) dout <= mem[addr];   // dout holds during a write
  if (en &&  we) mem[addr] <= din;
end
```

`dout` simply holds its previous value during a write. **This is the
lowest-power option** — the output register does not toggle — and it is the
right default when you never read and write the same address anyway.

| Mode | `dout` on a same-address collision | Power | Use when |
|---|---|---|---|
| Read-first | old contents | medium | you need the previous value (read-modify-write) |
| Write-first | new data | medium | a pipeline would otherwise need a bypass |
| No-change | unchanged | **lowest** | reads and writes never collide |

**Write-first is not free on every device.** Some block RAM primitives implement
it natively; others need the tool to build a bypass mux around a read-first RAM,
which costs a little logic and can cost timing. On some families write-first is
unavailable in certain width/port configurations. If the synthesis report says
your RAM did not infer, this is a common cause.

---

## 3. Port configurations

| Configuration | Ports | Module | Typical use |
|---|---|---|---|
| Single-port | 1 R/W | [`ram_sp`](../examples/rtl/ram_sp.sv) | scratchpad, lookup |
| Simple dual-port | 1 W, 1 R | [`ram_sdp`](../examples/rtl/ram_sdp.sv) | FIFOs, line buffers |
| True dual-port | 2 R/W | [`ram_tdp`](../examples/rtl/ram_tdp.sv) | shared memory, CDC |

**Simple dual-port is the workhorse.** One write port and one read port is what
a FIFO needs, what a delay line needs, and what a ping-pong buffer needs. It is
also the configuration that gives the widest data width on most devices, because
the primitive does not have to split its ports.

```systemverilog
always_ff @(posedge clk) begin
  if (we) mem[waddr] <= wdata;
  rdata <= mem[raddr];             // independent address, always reads
end
```

**True dual-port** gives two fully independent read/write ports, optionally on
two different clocks — which is what makes it the storage element inside an
async FIFO ([docs/28](28-clock-domain-crossing.md)).
[`ram_tdp.sv`](../examples/rtl/ram_tdp.sv) is genuinely written from two clock
domains, which is why it carries a multiple-driver lint waiver:

```systemverilog
/* verilator lint_off MULTIDRIVEN */
logic [DW-1:0] mem [0:DEPTH-1];
/* verilator lint_on MULTIDRIVEN */
```

That waiver is correct *here and only here*. A multiple-driven memory array
anywhere else is a bug. See §8 for what happens when both ports hit the same
address.

---

## 4. Byte enables

[`ram_be.sv`](../examples/rtl/ram_be.sv) — the indexed part-select is the
idiomatic byte lane, and it is what the tool matches on:

```systemverilog
always_ff @(posedge clk) begin
  if (en) begin
    foreach (be[i])
      if (be[i]) mem[addr][i*8 +: 8] <= din[i*8 +: 8];
    dout <= mem[addr];
  end
end
```

Block RAMs have byte-write-enable inputs natively, so this costs nothing — but
only if written in the recognised form. Writing it as a read-modify-write
(`mem[addr] <= (mem[addr] & ~mask) | (din & mask)`) describes the same function
and infers a *read-first RAM plus a mux*, which is slower, larger, and wrong on a
collision.

Two constraints to know:

- The lane width must match the device's byte width — 8 or 9 bits. A 4-bit
  "byte enable" does not map to the primitive and will be built out of logic.
- `foreach` is convenient here and **the Yosys frontend rejects it**, which is
  why `ram_be` is one of the modules outside this repository's formal flow
  ([docs/25](25-formal-verification-with-sby.md)).

---

## 5. Register files are not RAMs

[`regfile.sv`](../examples/rtl/regfile.sv) deliberately breaks the block RAM
rules, because a register file wants the opposite trade-off:

```systemverilog
// Asynchronous read: flops or distributed RAM, NOT a block RAM.
always_comb begin
  rdata0 = (ZERO_REG && raddr0 == '0)  ? '0    :
           (we && (waddr == raddr0))   ? wdata : regs[raddr0];
```

Three design decisions worth copying:

**Asynchronous read is correct here.** A 32×32 register file read twice per
cycle with zero latency is exactly what distributed RAM is for. Forcing it into
a block RAM would add a cycle of latency to every instruction and consume a
primitive sized for 1024 entries to hold 32.

**Write-through bypass is in the read path, not a pipeline stage.** A read in the
same cycle as a write to the same address returns the new value. Without it,
every pipeline that writes back and reads in adjacent cycles needs a forwarding
network one stage later — the bypass is cheaper here than downstream.

**Register 0 is handled at the read port, not the write port.** Both are needed,
in fact — the write is suppressed *and* the read returns zero — because the
reset value and the write suppression must agree with the read for the RISC-V
`x0` semantics to hold on every path.

**Two read ports means two copies.** A distributed-RAM register file with N read
ports is physically N banks written identically. That is fine at 32 entries and
ruinous at 4096; past a few hundred entries, use a banked block RAM and accept
the latency.

---

## 6. ROMs and initialisation

### Computed at elaboration

The best ROM has no initialisation file at all — the contents are computed by a
constant function, so the table cannot drift from the code that generated it.
[`rom_table.sv`](../examples/rtl/rom_table.sv) builds a reciprocal table this
way; see [docs/23 §1](23-structural-design-techniques.md#1-elaboration-time-computation).

```systemverilog
for (genvar i = 0; i < N; i++) begin : g_e
  localparam logic [W-1:0] E = recip(i);      // evaluated by the compiler
  assign rom[i] = E;
end
```

### From a file

```systemverilog
if (INIT_FILE != "") begin : g_init
  initial $readmemh(INIT_FILE, mem);
end
```

This is the form in [`ram_sp.sv`](../examples/rtl/ram_sp.sv), and it is
synthesizable — an `initial` block that only initialises a memory is recognised
by Vivado and Quartus and becomes the primitive's initial contents. It is one of
the few places `initial` means anything in RTL ([docs/05](05-procedural-blocks-and-flow.md)).

Four things to know:

- **`$readmemh` is hex, `$readmemb` is binary.** Mixing them up gives you a
  memory full of plausible-looking wrong numbers.
- **A file shorter than the array leaves the rest at X** in simulation, and
  usually zero in hardware. That divergence has caused real bugs; initialise the
  whole array or make the design not care.
- **The path is resolved relative to the simulator's working directory**, which
  is not where the source file is. Pass an absolute path or a parameter.
- **`string` parameters are rejected by the Yosys frontend**, which is why
  `ram_sp` is outside the formal flow here.

ASIC flows generally do *not* support memory initialisation — there is no
mechanism to preload a hard macro. If the design must run on both, load the
contents at run time through the normal write port.

---

## 7. Output registers and latency

A block RAM's registered read port gives one cycle of latency. Most devices
offer a **second, optional output register** inside the primitive:

```systemverilog
always_ff @(posedge clk) begin
  dout_raw <= mem[addr];       // latency 1: the RAM's own output register
  dout     <= dout_raw;        // latency 2: the RAM's optional pipeline register
end
```

Written this way, the second flop is absorbed into the primitive and costs no
fabric. It typically buys 30–50% more Fmax on the memory path, because the
block RAM's internal read path is one of the slowest things on the device.

The cost is a cycle of latency, which must be matched everywhere else in the
datapath — that is what [`pipe_delay.sv`](../examples/rtl/pipe_delay.sv) is for
([docs/21](21-pipelining.md)). If the memory path is the critical path, take the
register; if it is not, do not.

> This is also why a FIFO built on a block RAM has a *first-word-fall-through*
> variant that costs extra logic: the natural block RAM read has latency, and
> making the first word appear on the output without a read command means
> bypassing the RAM for that one case.

---

## 8. Collisions

A **collision** is two ports accessing the same address in the same cycle.
Within one port, §2 covers it. Between two ports of a true dual-port RAM it is
more serious:

| Both ports | Result |
|---|---|
| read the same address | fine |
| one reads, one writes | the reader gets read-first or write-first per configuration — **and on some devices, X** |
| both write | **undefined**, and on some devices physically damaging to the stored value |

[`ram_tdp.sv`](../examples/rtl/ram_tdp.sv) states this rather than pretending
otherwise:

```systemverilog
// Writing the same address from both ports in the same cycle gives an
// undefined result in the RAM primitive. Arbitrate above this level.
```

**Simulation will not warn you**, because the RTL model resolves the two
non-blocking assignments by scheduler order and produces a definite value. The
hardware does not. If two ports can collide, either arbitrate, or partition the
address space so they cannot, or assert that they never do:

```systemverilog
a_no_write_collision: assert property (@(posedge clk_a)
  !(we_a && we_b && (addr_a == addr_b)))
  else $error("dual-port write collision at %h", addr_a);
```

That assertion is cheap and is the only thing standing between you and a bug
that appears once every few million cycles.

**Across clock domains** the question does not even have an answer, since "the
same cycle" is undefined. An async FIFO avoids it structurally: the Gray-coded
pointers guarantee the read address never reaches the write address
([docs/28 §7](28-clock-domain-crossing.md#7-crossing-a-stream-the-async-fifo)).

---

## 9. When inference is the wrong tool

Inference is right for the common cases and wrong for these:

| Situation | Why inference fails | Instead |
|---|---|---|
| ECC, error injection, parity | the primitive's ECC ports are not inferrable | instantiate the macro |
| Asymmetric port widths (write ×32, read ×128) | no portable RTL expresses it | instantiate, or use the vendor IP |
| Specific placement / cascading | inference chooses the mapping | instantiate with location constraints |
| Very large memories | may infer as many small blocks with poor timing | vendor memory compiler |
| ASIC | there is no "inferred" SRAM at all | memory compiler, always |

On an ASIC, memories are **hard macros from a compiler**, with their own timing
models, test collars and physical footprint. Nothing is inferred. The RTL
instantiates a generated wrapper, and the templates in this document apply only
to the behavioural model used for simulation.

A practical middle path: keep the inferrable RTL as the reference model, wrap
both it and the instantiated macro behind one module with a parameter, and use
the RTL version for simulation and formal. That way the behaviour stays
readable and provable even though the silicon uses a macro.

---

## 10. Reset, X and simulation

**A block RAM powers up with undefined contents** unless initialised. In
simulation that is X, which is the honest model — and it propagates, which is
the point. Resist the urge to zero the array just to quiet the waveform: that
hides exactly the bug where something reads before it writes.

The usual symptom is an X appearing several cycles downstream of a memory,
long after the read that caused it. When chasing one:

- A memory read of an X address returns X — and an X address often comes from an
  uninitialised counter, not the memory.
- An `if (en)` around the read means `dout` *holds* when `en` is low. A stale
  value is not an X and will not announce itself.
- `$readmemh` of a short file leaves the tail X in simulation and zero in
  hardware (§6).

For memories whose contents must be defined at time zero in simulation but not
in hardware, gate the initialisation:

```systemverilog
`ifndef SYNTHESIS
  initial foreach (mem[i]) mem[i] = '0;    // simulation only
`endif
```

This is a debugging aid, not a fix. If the design genuinely requires a known
initial state, it needs an explicit clearing sequence in hardware too.

---

## 11. Checklist

**Inference**
- [ ] Memory array is an **unpacked** array.
- [ ] Read is inside a clocked block, with the address registered by the RAM
      itself — not an async read followed by a flop.
- [ ] No reset anywhere on the array.
- [ ] Synthesis log checked to confirm the memory actually inferred.

**Behaviour**
- [ ] Read-first / write-first / no-change chosen deliberately and documented.
- [ ] Byte enables written as indexed part-selects, with 8- or 9-bit lanes.
- [ ] Same-address collisions on a dual-port RAM arbitrated, partitioned, or
      asserted against.
- [ ] Output pipeline register used if the memory is on the critical path — and
      its latency matched in every parallel path.

**Initialisation**
- [ ] `$readmemh` file length matches the array, or the design tolerates the
      difference between X and zero.
- [ ] Init path resolved absolutely or via a parameter.
- [ ] ROM contents computed at elaboration where possible, rather than kept in
      a file that can drift.
- [ ] No reliance on memory initialisation if the design must also target an
      ASIC.

---

## See also

- [docs/21: Pipelining](21-pipelining.md) — latency matching around a memory's
  output register
- [docs/23: Structural techniques](23-structural-design-techniques.md) —
  elaboration-computed tables and when a ROM beats logic
- [docs/24: DFT, clocking and X](24-dft-clocking-and-x-discipline.md) — memory
  BIST, and why X propagation is a feature
- [docs/28: Clock domain crossing](28-clock-domain-crossing.md) — the true
  dual-port RAM inside an async FIFO
- [docs/30: Flow control](30-flow-control-and-handshakes.md) — the FIFOs built
  on these memories
- [docs/20: Synthesis subset](20-synthesis-subset-and-gotchas.md) — `initial`
  in RTL, and what else is and is not synthesizable
