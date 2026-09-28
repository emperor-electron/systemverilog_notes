# Control Registers and Safe Reconfiguration

A processor store is an asynchronous event that lands in the middle of your
design. The bus worked, the address decoded, the register took the value — and
the state machine it configures was three beats into a transfer, or the pipeline
it configures had two beats in flight computed under the old value. Nothing
reported an error, because from every individual module's point of view nothing
went wrong.

This document is about the gap between "the register was written correctly" and
"the design behaved correctly", and about the one structure that closes it: a
**commit point**, where a whole configuration becomes live at an instant the
hardware chose rather than at an instant the processor chose.

Every number below is measured — cell counts from `yosys stat`, torn cycles and
beat counts from XSIM, proof outcomes from `sby`.

Companion code, all verified:
[`csr_shadow.sv`](../examples/rtl/csr_shadow.sv) ·
[`cfg_burst_fsm.sv`](../examples/rtl/cfg_burst_fsm.sv) ·
[`cfg_pipe_scale.sv`](../examples/rtl/cfg_pipe_scale.sv) ·
[`csr_ctrl_top.sv`](../examples/rtl/csr_ctrl_top.sv) ·
[`cfg_pkg.sv`](../examples/rtl/cfg_pkg.sv) ·
reusing [`csr_bank.sv`](../examples/rtl/csr_bank.sv) and
[`axil_slave.sv`](../examples/rtl/axil_slave.sv),
measured by [`csr_config_tb.sv`](../examples/tb/csr_config_tb.sv),
proved in [`csr_shadow_fv.sby`](../formal/csr_shadow_fv.sby),
[`cfg_burst_fsm_fv.sby`](../formal/cfg_burst_fsm_fv.sby) and
[`cfg_pipe_scale_fv.sby`](../formal/cfg_pipe_scale_fv.sby)

---

## Contents

- [1. What a store from the PS actually does](#1-what-a-store-from-the-ps-actually-does)
- [2. Three failure modes, and why two of them survive review](#2-three-failure-modes-and-why-two-of-them-survive-review)
- [3. Staged and active](#3-staged-and-active)
- [4. Commit policies, and the tearing they do or do not prevent](#4-commit-policies-and-the-tearing-they-do-or-do-not-prevent)
- [5. Who defines "safe"](#5-who-defines-safe)
- [6. What the commit point costs](#6-what-the-commit-point-costs)
- [7. Reconfiguring a pipeline: quiesce or travel](#7-reconfiguring-a-pipeline-quiesce-or-travel)
- [8. Reconfiguring an FSM: snapshot at the start](#8-reconfiguring-an-fsm-snapshot-at-the-start)
- [9. The register map that makes it usable](#9-the-register-map-that-makes-it-usable)
- [10. When the PS is in another clock domain](#10-when-the-ps-is-in-another-clock-domain)
- [11. Verifying it, and what each check cannot see](#11-verifying-it-and-what-each-check-cannot-see)
- [12. Checklist](#12-checklist)

---

## 1. What a store from the PS actually does

Take the ordinary arrangement: a Zynq PS, an AXI4-Lite interface into the PL, a
register block, and a design that reads the register outputs as wires.

```
   PS  --AXI4-Lite-->  axil_slave  -->  csr_bank  --rw_q-->  your design
```

`csr_bank`'s `rw_q` is a bundle of wires off a flop array. It changes on the edge
the write lands and stays changed. That is exactly right, and it is exactly the
problem: the design on the other end has no say in when that edge happens.

Three things follow, and none of them is a bug in anything named above.

**A 64-bit parameter is two stores.** The bus is 32 bits wide, so software writes
the low half, then the high half. Between those two writes the hardware sees a
value that is half new and half old. If it happens to sample in that window, it
uses a number nobody wrote.

**A terminal condition can move behind the thing testing it.** A counter
comparing against a length register is comparing against a wire. Shorten the
length below the current count and `cnt == len-1` is simply never true again.

**A pipeline uses one configuration at several different times.** A three-stage
datapath reads `gain` at cycle T, `shift` at T+1 and the clamp bounds at T+2. A
write landing at T+1 gives that one beat the old gain and the new shift — a
result that corresponds to no configuration that ever existed.

The rest of this document is one mechanism and two worked consumers.

---

## 2. Three failure modes, and why two of them survive review

The first failure — tearing — is the one everybody knows about, and it is the
least dangerous, because it produces a wild value that tends to trip something
downstream.

The other two are worse, and it is worth being precise about why.

### The terminal condition: a legal write that hangs the design

[`cfg_burst_fsm.sv`](../examples/rtl/cfg_burst_fsm.sv) emits `len` beats at
`base`, `base+stride`, and so on. Built to read its configuration live, and asked
mid-burst to change `len` from 4 to 2 when the count has reached 2, it does this
(measured, `csr_config_tb` section 2a):

```
2a  SNAPSHOT: 4 data beats, addr_ok=1, hdr=1 trl=1, terminated=1
2a  LIVE    : 62 data beats, addr_ok=0, hdr=1 trl=0, terminated=0
```

62 data beats and still running when the testbench gave up. `cnt_q` was 2, the new
`len-1` is 1, and the comparison will not be true again until the 12-bit counter has
wrapped all the way round — 4096 beats of traffic to an address range nobody asked for. From a
perfectly legal store to a perfectly legal register.

The instinct here is to armour the comparison: write `cnt_q >= len_u - 1` instead
of `==`. That does stop the hang. It does not make the design correct — the burst
now ends after the wrong number of beats — and it does nothing at all for the
third failure below, which contains no comparison to armour.

### The state graph that changes shape

`cfg_burst_fsm` has a framing bit. With `hdr_en` set it emits a header beat before
the data and a trailer after; with it clear it emits neither. So the field does not
parameterize a *value* in the FSM, it parameterizes the FSM's *transition graph*.

Enter a burst with `hdr_en` set, so a header goes out, and then clear it. The DATA
state's exit now goes straight to IDLE. Measured (`csr_config_tb` section 2b, with
`len` and `stride` left completely alone):

```
2b  SNAPSHOT: hdr=1 trl=1   LIVE: hdr=1 trl=0
```

A packet with a header and no trailer. The beat count is right. Every address is
right. Every state the FSM visited was a legal state and every transition it took
was a legal transition — it walked a legal path through a graph that changed under
it, and the result is a frame nothing downstream can parse. The burst *terminated
normally*, so there is no timeout, no error bit, and no bus response to suggest
anything happened.

There is no arithmetic trick that defends against this. The configuration has to
hold still.

### The mixed-configuration beat

[`cfg_pipe_scale.sv`](../examples/rtl/cfg_pipe_scale.sv) computes
`y = clamp(round((x * gain) >> shift), lo, hi)` in three stages:

| stage | operation | field used |
|---|---|---|
| 0 | multiply | `gain` |
| 1 | round and shift | `shift` |
| 2 | clamp | `lo`, `hi` |

Reading the configuration live at each stage, and committing a new one mid-stream,
2 beats out of 26 came out wrong (`csr_config_tb` section 3a). Two beats is the
whole point: it is not a burst of obviously-bad output, it is a couple of samples
somewhere in the middle of a stream, each individually plausible, each a mixture of
two configurations. Range-checking the output would not flag them. A checksum over
a frame would flag the frame without localising anything. This is the failure mode
that gets diagnosed as noise.

---

## 3. Staged and active

Two copies of the configuration:

- **staged** — what software has written. Changes whenever the processor says so.
- **active** — what the hardware uses. Changes only at a **commit**.

A commit copies *all* of staged into active in one cycle, and only when the
consumer says it is safe. [`csr_shadow.sv`](../examples/rtl/csr_shadow.sv) is that,
and the whole mechanism is one register with one enable:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    active_q  <= '0;
    applied_q <= 1'b0;
  end else begin
    // The whole bundle, one enable. That single line is the atomicity
    // guarantee: there is no ordering for software to get wrong because
    // there is no ordering.
    if (commit) active_q <= staged;
    applied_q <= commit;
  end
end
```

Three properties come out of that, and they are worth naming separately because
different consumers need different ones:

**ATOMICITY.** Every field changes in the same cycle. A multi-word update cannot
tear, however software spreads it over the bus, because there is no intermediate
state for it to be caught in.

**ISOLATION.** `active` is stable for as long as the consumer keeps `safe` low. This
is what an FSM needs: not a correct value, a *motionless* one.

**VISIBILITY.** `pending` says the write has not taken effect yet and `applied` is a
one-cycle event software can turn into an interrupt. Without these, an
arm/commit scheme is worse than no scheme: the update happens at a moment software
cannot predict and has no way to observe.

### One wide port, not N narrow ones

Every consumer here takes its configuration as a single wide vector and unpacks it
internally, with the field offsets in [`cfg_pkg.sv`](../examples/rtl/cfg_pkg.sv).

That is not a style preference. A module with separate `gain`, `shift`, `lo` and
`hi` ports has four independently-timed inputs and nothing in its interface says
they must change together. A module with one `cfg` port has one input, and "the
configuration updates atomically" becomes a statement about a single register with
a single enable — which is a thing a proof can state in one line, and which
`csr_shadow_fv` does:

```systemverilog
// (2) and when it moves it takes the WHOLE of `staged`. This is
// ATOMICITY, and stating it over the full vector rather than per field
// is what makes a torn multi-word update unrepresentable.
if (f_com_q) assert (active == f_stg_q);
```

---

## 4. Commit policies, and the tearing they do or do not prevent

`csr_shadow`'s `MODE` selects when a commit happens. This is the only real design
decision in the module.

| MODE | policy | commit when |
|---|---|---|
| 0 `TRANSPARENT` | none — `active` is `staged` | never; there is no commit |
| 1 `SAFE_POINT` | automatic | `safe && (staged != active)` |
| 2 `ARM_COMMIT` | software-grouped | `armed && safe` |

`TRANSPARENT` exists as a negative control, so that every proof and every
testbench pass can be pointed at the unprotected design without a second copy of
it being written. Section 11 uses it.

### The measurement

`csr_config_tb` section 1 writes a four-word configuration one 32-bit word per
cycle — what a processor actually does — and counts the cycles in which `active`
held a value that is neither the complete old configuration nor the complete new
one. The experiment runs twice: once with the consumer's critical region closed
during the writes, once with it open.

```
torn cycles, consumer BUSY during the writes:  TRANSPARENT=3 SAFE_POINT=0 ARM_COMMIT=0
torn cycles, consumer IDLE during the writes:  TRANSPARENT=3 SAFE_POINT=3 ARM_COMMIT=0
```

| MODE | consumer busy | consumer idle |
|---|---|---|
| TRANSPARENT | 3 torn cycles | 3 torn cycles |
| SAFE_POINT | 0 | **3 torn cycles** |
| ARM_COMMIT | 0 | 0 |

**`SAFE_POINT` is only as atomic as the consumer's safe window.** If the consumer
happens to be idle while software is writing — which is the normal case, since
software usually reconfigures a design precisely because it is not busy — then
`safe` is high throughout the write sequence, the shadow dutifully commits after
every individual word, and the design sees each of the three intermediate values.
The double buffer is present, correct, and providing no atomicity at all.

`ARM_COMMIT` is atomic regardless of what the consumer is doing, because software
chooses the grouping. That is the argument for the extra register and the extra
bus write: not that it is safer in some vague sense, but that its atomicity does
not depend on a signal software cannot see.

`SAFE_POINT` remains the right choice when the thing being updated is a single
word — a gain, a threshold — where there is no grouping to get wrong. It costs
software nothing at all, which is worth something.

### `arm` is a write strobe, not a bit

```systemverilog
assign cmd_arm   = reg_wen && ctrl_hit && reg_wdata[0];
assign cmd_start = reg_wen && ctrl_hit && reg_wdata[1];
```

The CTRL register in [`csr_ctrl_top.sv`](../examples/rtl/csr_ctrl_top.sv) is an
address that is decoded and discarded. There is no flop.

The alternative — a real bit software sets and hardware clears — is the classic
self-clearing command bit, and it has two problems. It races: software's set and
hardware's clear can land on the same edge and one of them loses. And it cannot be
read back usefully: software sees "still set" and cannot distinguish "not started"
from "started, nearly finished". A command is an event, and events are strobes.
State that software wants to poll is a *different* register — `STATUS.pending` —
which is a genuine flop and reads back exactly what it means.

### The hazard the shadow does not remove

Software must write every register and *then* arm. Arm first and keep writing, and
a commit can land mid-sequence and publish half the new configuration —
atomically wrong.

`csr_shadow` therefore exports `lock`, asserted while a commit is pending, and
`csr_ctrl_top` turns a configuration write in that window into a bus error:

```systemverilog
assign late_wr  = reg_wen && cfg_lock && (idx < BAW'(N_RW));
assign bank_wen = reg_wen && !late_wr;
assign reg_err  = (bank_err && !ctrl_hit) || late_wr;
```

Both halves matter. Reporting without suppressing would leave the write in the
staged copy where the pending commit could still publish it — software would get an
error for a corruption that happened anyway. Suppressing without reporting is
worse: a silently dropped configuration write is close to undiagnosable from the
software side, because every subsequent read of the staged register says the write
worked.

This detects a driver bug. It does not prevent one.

---

## 5. Who defines "safe"

`safe` is an input to `csr_shadow` and an output of the consumer, and that
direction is the whole design. The shadow does not know what a safe point is; only
the thing being configured does.

| consumer | safe point | why |
|---|---|---|
| burst engine | idle | a burst is a unit; its configuration must not move inside one |
| pipeline, quiesced | empty, and admitting nothing | a beat in flight is mid-computation |
| pipeline, config travels | always | every beat carries its own configuration |
| single-word gain | always | there is nothing to be inconsistent with |

### The commit window is an intersection

```systemverilog
assign cfg_safe = burst_safe && dp_safe;
```

One line, and it is the composition cost of the whole scheme: a bank shared
between N consumers can only commit when **all** of them are safe.

In `csr_ctrl_top` the scaler runs in TRAVEL mode so `dp_safe` is constantly high,
and the window is just "the burst engine is idle". Build the scaler in QUIESCE mode
instead and the window becomes "burst idle **and** pipeline empty", which under a
continuous input stream is never — measured, section 7.

That failure is silent. There is no error, no timeout, no bus response: software
armed a commit, the commit is pending, and it will stay pending. The only
observable is `STATUS.pending` never clearing, and only if somebody is looking.

If two consumers have genuinely incompatible safe windows, the answer is two
shadows, not one. They cost 130 cells each (section 6) and they remove an
intersection that is otherwise permanent.

### The `safe` that was not sufficient

For the quiesced pipeline the obvious condition is "empty":

```systemverilog
assign safe = !busy;                        // not enough
assign safe = !busy && !(x_valid && en);    // correct
```

At the edge where a commit lands, a beat presented on that same cycle enters stage
0 and multiplies by the **old** gain — `active` updates on that edge, and a register
reads its old value on the edge it updates. One cycle later that beat meets the
**new** shift. Empty is not sufficient; empty *and admitting nothing* is.

Weakening this to `!busy` reproduces exactly the corruption of the unprotected
mode, just more rarely. Section 11 records it as a mutation, with what caught it.

---

## 6. What the commit point costs

`csr_shadow`, `NREG=4`, `DW=32` — a 128-bit configuration. Mapped with
`techmap; opt -fast` and counted with `stat`:

| MODE | cells | flops | what the rest is |
|---|---|---|---|
| 0 TRANSPARENT | **0** | 0 | wires |
| 1 SAFE_POINT | **385** | 129 | a 128-bit comparator: 128 XOR + 127 OR + 1 AND |
| 2 ARM_COMMIT | **134** | 130 | 2 MUX, 1 AND, 1 OR |

The shadow register itself is 128 flops, plus one for `applied`, plus one for
`pend_q` in `ARM_COMMIT`. Everything above that is the policy.

**The comparator is 256 of `SAFE_POINT`'s 385 cells** — two gates per
configuration bit — and it is the price of "software writes and forgets": without
it the mode cannot tell a pending update from a quiet one, so `pending` and
`applied` would be noise rather than information. `ARM_COMMIT` spends five cells on
a pending flop and its enable instead, so the net difference between the two
policies is 251 cells. Software already told it something changed.

Both are small against any real datapath — the three-stage scaler below is 2371
cells on its own — which is the useful conclusion. **The commit point is not where
the money goes.** It is worth deciding on its merits rather than on its area.

---

## 7. Reconfiguring a pipeline: quiesce or travel

Three ways to handle a pipeline whose configuration can change, selected by
`cfg_pipe_scale`'s `CFG_MODE`:

| CFG_MODE | stages read | `safe` | reconfiguration costs |
|---|---|---|---|
| 0 LIVE | `cfg`, live | `1'b1` (a lie) | nothing, and it is wrong |
| 1 QUIESCE | `cfg`, live | `!busy && !(x_valid && en)` | a drain: LATENCY cycles of bubble |
| 2 TRAVEL | delayed copies | `1'b1`, and it is true | 52 flops |

### Modes 0 and 1 are the same gates

This is the most useful fact in the file. Measured:

| CFG_MODE | cells | flops |
|---|---|---|
| 0 LIVE | 2371 | 74 |
| 1 QUIESCE | **2375** | **74** |
| 2 TRAVEL | 2423 | 126 |

LIVE and QUIESCE differ by **four cells and zero flops**, and those four cells are
the `!busy && !(x_valid && en)` expression. The datapath is bit-for-bit identical:

```systemverilog
end else begin : g_shared
  // MODES 0 AND 1 SHARE THIS BRANCH. Identical datapath, identical cost. The
  // difference between a correct design and a silently corrupting one is the
  // one assignment below.
  assign shift_s1 = cfg_pkg::scale_shift(cfg);
  assign lo_s2    = cfg_pkg::scale_lo(cfg);
  assign hi_s2    = cfg_pkg::scale_hi(cfg);

  if (CFG_MODE == M_QUIESCE) begin : g_quiesce
    assign safe = !busy && !(x_valid && en);
  end else begin : g_unsafe
    assign safe = 1'b1;
  end
end
```

Two consequences, and they point in opposite directions. The fix for a pipeline
that corrupts data when reconfigured can be **zero gates of datapath and one bit of
correctly-specified interface**. And a datapath that is completely correct in
isolation can be wrong in a system because of a bit it does not have — which is
why "this module is verified" and "this module is safe to reconfigure" are
different claims.

### Travel: delay each field to the stage that uses it

```systemverilog
// Each field is delayed to the stage that consumes it and no further.
logic [SHW-1:0]       sh_d1;
logic signed [YW-1:0] lo_d1, hi_d1, lo_d2, hi_d2;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    sh_d1 <= '0;
    lo_d1 <= '0;  hi_d1 <= '0;
    lo_d2 <= '0;  hi_d2 <= '0;
  end else if (en) begin
    sh_d1 <= cfg_pkg::scale_shift(cfg);
    lo_d1 <= cfg_pkg::scale_lo(cfg);
    hi_d1 <= cfg_pkg::scale_hi(cfg);
    lo_d2 <= lo_d1;
    hi_d2 <= hi_d1;
  end
end
```

Stage 0 reads the live configuration, in every mode, and that is correct in every
mode: the beat is entering now, so "now" *is* its entry configuration. `shift` is
needed one stage down, so one register. The clamp bounds are needed two stages
down, so two.

The naive version pipelines the whole bundle to the end. Measured separately: **128
flops for the whole 64-bit bundle × 2 stages, against 52 for the fields at the
depths they are actually used.** The saving is not subtle and it costs nothing but
paying attention to which field is consumed where.

**`en` has to gate the configuration registers too.** Freezing a beat in stage 1
while its `shift` advances is the same corruption one level down. Section 11
records what catches it.

### The number that decides between them

QUIESCE is free in gates. Its cost is that a commit has to wait for a drain — and
under load the drain never comes. `csr_config_tb` section 3b arms a commit and then
holds the input high for 100 cycles:

```
commits during 100 cycles of unbroken input:  LIVE=1 QUIESCE=0 TRAVEL=1
```

Zero. Not "delayed" — refused for as long as the load lasts, with nothing anywhere
reporting a problem. That is the argument for the 52 flops, and it is a system
argument rather than a module one: whether QUIESCE is acceptable depends entirely on
whether your input ever pauses, which is not a fact about the pipeline.

With gaps in the stream, both are correct and both commit (section 3a):

```
3a  LIVE   : 26 beats, 2 wrong, 1 commits
3a  QUIESCE: 26 beats, 0 wrong, 1 commits
3a  TRAVEL : 26 beats, 0 wrong, 1 commits
```

### The stall is part of the problem

`en` gates the travelling configuration registers alongside the data, and that is
not decoration. A beat frozen in stage 1 has to keep the `shift` it entered with; if
the configuration registers advance while the data does not, a stalled beat meets a
configuration that moved while it waited — the same corruption one level down.
Section 3c freezes a full pipeline and commits a different configuration on the same
cycle:

```
3c  stall across a commit:  LIVE 1/3 wrong, QUIESCE 0/3, TRAVEL 0/3
```

That case is directed rather than random, and §11 explains why it had to be.

### Flush instead of drain

Draining is not the only way to empty a pipeline. If the beats in flight are
disposable — a new configuration often means the old output is unwanted anyway —
flushing is one cycle instead of LATENCY. [docs/38 §10](38-pipeline-staging-and-stalls.md#10-flush-versus-drain)
covers the contract problem that comes with it: a flush has to be visible to both
ends of the handshake, because gating `m_valid` on it makes valid fall without
ready, which is a protocol violation by definition.

---

## 8. Reconfiguring an FSM: snapshot at the start

For an FSM the answer is simpler, and it is worth stating separately because the
mechanism is the same as the shadow's and lives in a different place.

```systemverilog
end else begin : g_snap
  logic [cfg_pkg::BURST_CFGW-1:0] cfg_q;

  // The whole bundle, one enable, at one instant -- the same shape as the
  // commit in csr_shadow.sv, for the same reason.
  always_ff @(posedge clk or negedge rst_n) begin
    if      (!rst_n)        cfg_q <= '0;
    else if (start && safe) cfg_q <= cfg;
  end

  assign cfg_u = cfg_q;
end
```

An FSM whose work comes in units — a burst, a packet, a frame, a command — has a
natural commit point: the start of the unit. Snapshot there and the configuration
is motionless for the whole unit by construction.

### This is a second, independent defence

`cfg_burst_fsm` with `LIVE_CFG=0` is correct **even behind a TRANSPARENT shadow**.
Its snapshot is its own; it does not depend on anything upstream holding still. That
is not an argument, it is what `csr_config_tb` section 2 measures: there is no shadow
in that section at all, the testbench drives `cfg` directly, and the snapshotting
instance still emits exactly the right burst while the configuration is rewritten
under it.

That is worth having. The shadow protects every consumer at once and is the right
place for the policy; the local snapshot protects one consumer against the shadow
being misconfigured, against a future integrator wiring `staged` instead of
`active`, and against the safe-window intersection quietly changing when a third
consumer is added. Two cheap defences at different levels beat one careful one.

It also means `safe` from the FSM has a second job. It is not only "do not commit
now" — it is the same condition that gates the FSM's own snapshot, so the two can
never disagree about when a burst boundary is.

### The property that matters is not arithmetic

`cfg_burst_fsm` carries six properties it promises and four more that tie its
burst-scoped bookkeeping to the snapshot it was taken from. The one that is hardest
to get by other means:

```systemverilog
// (5) WELL-FORMEDNESS. A trailer is emitted if and only if a header was.
// Purely control -- no arithmetic to make defensive -- and it is the
// property that no amount of careful comparison in the datapath can
// recover once the graph is allowed to change shape mid-run.
if (state_q == S_TRL) assert (f_saw_hdr);
if (done)             assert (f_saw_hdr == f_hdr_q);
```

And the isolation property everything else rests on:

```systemverilog
if (busy && f_busy_q) assert (cfg_u == f_cfgu_q);
```

`busy && f_busy_q`, not `busy`. Written the naive way this failed at step 3, on a
perfectly correct burst: the snapshot loads on the very edge that makes the engine
busy, so the first cycle of every burst legitimately shows a changed `cfg_u`. The
design was right and the property was wrong — the usual ratio, and the reason a
first failure is worth understanding before it is worth fixing.

The same mistake appeared again, independently, in the stall property of the
travelling configuration:

```systemverilog
if (rst_n && f_rst_q && !f_en_q) begin    // !f_en_q, not !en
```

The question is whether the registers moved at the **last edge**, and the enable
that governed that edge is the previous cycle's. Twice in one document is enough of
a pattern to name: **a property about a registered signal is a statement about an
edge, not about now.**

---

## 9. The register map that makes it usable

A correct commit point that software cannot observe is not much use.
`csr_ctrl_top`'s map, with the four entries that earn their keep:

```
0x00  SCALE0  RW   [15:0] gain      [19:16] shift
0x04  SCALE1  RW   [11:0] lo        [27:16] hi
0x08  BURST0  RW   [11:0] len       [23:16] stride     [24] hdr_en
0x0C  BURST1  RW   [15:0] base
0x10  STATUS  RO   [0] cfg_pending  [1] cfg_lock  [2] burst_busy  [3] dp_busy
0x14  ACTIVE_BURST0  RO   what the hardware is USING, not what was written
0x18  ACTIVE_SCALE0  RO   likewise
0x1C  EVENT   W1C  [0] burst done   [1] configuration applied
0x20  CTRL    WO   [0] arm (commit) [1] start burst      -- write strobes
```

**The ACTIVE mirrors.** Reading 0x08 tells software what it wrote. Reading 0x14
tells it what the hardware is using. Those are different values for as long as a
commit is pending, and having both turns "the engine is doing something I did not
ask for" from a day into a minute. The cost is wires:

```systemverilog
assign ro_d[1*DW +: DW] = cfg_burst[0 +: DW];   // ACTIVE_BURST0
assign ro_d[2*DW +: DW] = cfg_scale[0 +: DW];   // ACTIVE_SCALE0
```

**`EVENT.applied` as an interrupt source.** The commit is asynchronous with respect
to software: it happens whenever the consumer next becomes safe, which may be
thousands of cycles later. Polling `STATUS.cfg_pending` works; an event bit means
software does not have to. This is where `csr_bank`'s W1C semantics earn their
design — a hardware set beats a simultaneous software clear, which is what stops
the completion of a long-delayed commit from vanishing into a clear of some other
bit.

**CTRL outside the bank's map.** `csr_bank` correctly flags address 8 as unmapped,
because it is. Masking that is the one place the two address maps have to be
reconciled, and it is one gate:

```systemverilog
assign reg_err  = (bank_err && !ctrl_hit) || late_wr;
```

### The ordering bug that the map invites

Writing CTRL with both `arm` and `start` set in one store looks like an
optimisation. It is a race: the commit lands on the same edge the engine samples
its snapshot, and a register reads its old value on the edge it updates, so the
burst runs one configuration behind.

`csr_ctrl_top` handles it in hardware rather than documenting a footgun:

```systemverilog
assign start_ok  = !cmd_arm && !cfg_pending;
assign fsm_start = (cmd_start || start_pend_q) && start_ok;
```

With no commit outstanding, `commit` inside the shadow is zero, so `active` cannot
move across this edge and the snapshot is of a settled value. A start with nothing
armed therefore costs nothing, which is the common case.

**The first version of this was wrong**, and worth recording because the mistake is
natural. It tested `cfg_pending && cfg_safe` — "a commit is landing right now" —
and on the cycle of the arm+start write `cfg_pending` is still the registered zero:
the arm has not been latched yet. The start went out immediately and the burst ran
with the previous configuration. `csr_config_tb` section 4f caught it:

```
4f  beats=8 hdr=1 trl=1 first=0400 second=0403      <- the OLD configuration
4f  beats=3 hdr=0 trl=0 first=0800 second=0802      <- after the fix
```

A held start waits for the commit, and the commit waits for `cfg_safe` — so in a
top where `cfg_safe` can be permanently low, the start is held forever. One more
consequence of the intersection in section 5.

---

## 10. When the PS is in another clock domain

On a Zynq or Zynq MPSoC the AXI4-Lite interface usually runs on a PL clock the PS
generates, and the register block sits in that domain. If the datapath runs on the
same clock — the common case for a control-plane register block — nothing in this
document changes.

When it does not (a pixel clock, a line-rate clock, a clock recovered from a link),
the configuration has to cross, and the obvious approach is wrong in exactly the
way section 2 describes.

**Do not synchronize a multi-bit configuration bus bit by bit.** Two-flop
synchronizers on each bit resolve independently; bits that change in the same
source cycle arrive in different destination cycles, and the destination sees a
value that is part old and part new. That is tearing again, now generated by the
CDC rather than by the bus, and it is not fixable by adding synchronizer stages.
[docs/28 §6](28-clock-domain-crossing.md#6-crossing-a-bus-handshake) is the general
treatment, and [§9](28-clock-domain-crossing.md#9-reconvergence) is the same problem
stated as reconvergence.

**The structure in this document is already the answer.** Between commits, `staged`
is quasi-static — stable for as long as software takes to write it and then
stable until the next arm. So:

- Put `csr_bank` in the bus domain.
- Put `csr_shadow` in the **core** domain, and treat `staged` as a quasi-static
  bus: plain wires, no synchronizer, with a timing constraint saying so.
- Cross `arm` alone with [`cdc_pulse.sv`](../examples/rtl/cdc_pulse.sv), and let the
  synchronized pulse be the commit request. The data has been stable for many
  source cycles by then and stays stable until the next arm.
- Cross `applied` back the same way, for `EVENT` and the interrupt.
- `safe` never crosses. It is generated in the core domain and consumed there.

That last point is the reason to put the shadow on the far side. The alternative —
shadow in the bus domain — needs `safe` to cross *into* the bus domain, and a
`safe` that is two cycles stale is not a safe point at all: the consumer can have
started something in between. Keep the commit decision in the domain that owns the
definition of safe.

Where software needs positive confirmation rather than an event,
[`cdc_handshake.sv`](../examples/rtl/cdc_handshake.sv) carries data with a full
req/ack and reports completion back to the source, at the cost of a round trip.

The timing constraint for the quasi-static bus is
`set_max_delay -datapath_only` on it, not `set_false_path` — the path is real, it
just has many cycles to settle, and a bare false path stops *bounding* the delay,
which lets the router produce arbitrary skew between bits that have to arrive
together. [docs/28 §10](28-clock-domain-crossing.md#10-what-you-must-tell-the-tools)
has the form. Getting this wrong is the one part of the scheme that a functional
simulation cannot catch.

**Scope note:** this section is a design sketch and a pointer to the CDC primitives
in this repository. Unlike everything else in this document there is no module here
implementing it, and it is therefore neither simulated nor proved. Treat it
accordingly.

---

## 11. Verifying it, and what each check cannot see

Four checks, and the useful question is what each one is blind to.

### (a) Atomicity and isolation, in the module

`csr_shadow`'s properties are inside `csr_shadow`, because they are statements about
the relationship between the staged bundle and the commit, and both live there.
Four for every buffered mode, two more for `ARM_COMMIT`, one for `SAFE_POINT`.

`staged` is a **free 128-bit input** in the harness. That is deliberate on two
counts. It is the strongest possible model of software — every write order, every
partial update, every interleaving, including ones no processor would produce. And
it avoids the failure that
[`axis_reg_slice_fv.sv`](../formal/axis_reg_slice_fv.sv) exists to document: a
payload tied off in the harness while the module constrains it makes the
assumption unsatisfiable, every assertion passes, and a design that loses beats
passes with them.

`safe` is free too. "I commit only when told it is safe" has to hold against an
adversarial `safe`, not a plausible one.

### (b) Composition, not assumption

`cfg_pipe_scale_fv` **instantiates `csr_shadow`** rather than assuming its
behaviour:

```systemverilog
csr_shadow #(.NREG(2), .DW(cfg_pkg::CFG_DW), .MODE(2)) u_shadow (
  ... .safe (safe), .active (cfg) );

cfg_pipe_scale #(.CFG_MODE(CFG_MODE)) dut (
  ... .cfg (cfg), .safe (safe) );
```

The alternative is `assume` the contract — "the configuration only changes when
`safe` is high" — and get on with it. That proves the wrong thing. The assumption
is a paraphrase of what the shadow is supposed to do, and a paraphrase can be wrong
in the same way the design is wrong; if it is subtly unsatisfiable the whole proof
passes vacuously.

Wiring the real modules together means what is proved is the composition, which is
also the thing that ships. It is simultaneously the proof that the shadow's
handshake is strong enough to protect a pipeline and the proof that the pipeline
asks for the right protection. If either end of the contract is wrong, it fails.

### (c) The reference must be independent of the staging

```systemverilog
always_comb
  y_ref = cfg_pkg::scale_ref(cfg_pkg::scale_gain (fc[STAGES-1]), ...,
                             fx[STAGES-1]);
```

A three-deep delay line carrying `{x, cfg}`, gated by `en` exactly as the DUT's data
registers are, then the golden model in one expression. The DUT spreads the same
arithmetic over three stages and picks its configuration up at three different
times; the model does it all at once from the configuration that was live at entry.

The model is in `cfg_pkg` and **no module in `examples/rtl` calls it** — only the
testbench and the harness. A model that shared the DUT's staging could not detect a
beat picking up the wrong stage's configuration, which is the entire bug class.

What this does *not* test: the field offsets. The DUTs unpack with `cfg_pkg`'s
accessors and the checkers pack with them, so a wrong offset cancels out. That gap
is closed by one directed vector in `csr_config_tb` section 4a that writes literal
hex words over the bus and checks hand-computed results:

```
SCALE0 = 0x0003_0100 -> gain = 0x0100 (Q8.8 = 1.0), shift = 3
BURST0 = 0x0103_0004 -> len = 4, stride = 3, hdr_en = 1
BURST1 = 0x0000_0100 -> base = 0x0100
```

`y = 1600` for `x = 50`; four data beats from `0x100`, second at `0x103`, framed.
That is the only place in this repository where the register map is pinned to
something outside `cfg_pkg`.

### (d) Covers, because a hazard never exercised looks like a hazard survived

`cfg_burst_fsm_fv` leaves `cfg` free to change on every cycle — that *is* the
experiment. But a harness in which the solver happened to leave the configuration
alone would pass identically, and so would the `LIVE_CFG=1` build. So:

```systemverilog
// THE ONE THAT MATTERS. A burst that completed correctly while the
// configuration was being rewritten underneath it.
f_c_cfg_moved  : cover (rst_n && past_ok && done && cfg_moved);
f_c_long_moved : cover (rst_n && past_ok && done && cfg_moved && (beats == 4));
```

`csr_shadow_fv`'s equivalent asks for a *torn* commit published atomically — the two
halves of the bundle differing from each other and from what was active before, all
landing on one edge. Reached at step 4, so the atomicity assertion is about a
reachable situation rather than a vacuous one.

`cfg_pipe_scale_fv`'s `f_c_change_inflight` — a commit landing while beats are in
flight — is **reachable in TRAVEL mode and unreachable in QUIESCE mode**, and that
asymmetry is the cheapest possible summary of what each one costs. Measured, running
the same cover task at both settings:

```
CFG_MODE=2 (travel)    f_c_change_inflight   reached, step 4
CFG_MODE=1 (quiesce)   f_c_change_inflight   UNREACHED
```

An unreachable cover is normally an alarm. Here it is the proof: quiescing's entire
promise is that this situation cannot arise, so a solver failing to construct it is
the statement being made. The other five covers are reached in both modes, which is
what stops this from being an argument about a broken harness.

All six of `csr_shadow_fv`'s covers are reached (the torn-then-atomic one at step 4),
and all six of `cfg_burst_fsm_fv`'s — including a full-length burst completing
correctly while the configuration is rewritten underneath it, at step 7.

### (e) The mutation matrix

Nine mutations, each a single-line change to a shipped module, each run against
every check. **FAIL means the check caught it.**

Ten mutations, each a single-line change to a shipped module or harness, each run
against every check that could see it. **FAIL means the check caught it.** A dash
means the mutation is not in that check's scope.

| mutation | shadow proof | pipeline proof | burst proof | testbench |
|---|---|---|---|---|
| M1 commit ignores `safe` | **FAIL** | – | – | **FAIL** |
| M2 commit publishes only the low word | **FAIL** (both tasks) | – | – | **FAIL** |
| M3 `arm` not latched, so a pulse can be lost | **FAIL** | – | – | **FAIL** |
| M4 shadow made TRANSPARENT under the quiesced pipeline | – | **FAIL** | – | – |
| M5 quiesce `safe` weakened to `!busy` | – | **FAIL** | – | **FAIL** |
| M6 travelling config registers not gated by `en` | – | **FAIL** | – | **FAIL** ¹ |
| M7 burst FSM reads its configuration live | – | – | **FAIL** | PASS ² |
| M8 scaler reads its configuration live, in the top | – | – | – | **FAIL** ¹ |
| M9 no write lock on a pending commit | – | – | – | **FAIL** |
| M10 no start deferral | – | – | – | **FAIL** |

Everything the proofs are scoped for, they catch. The three entries with footnotes
are where the interesting information is.

**¹ M6 and M8 initially passed the testbench, and both were testbench bugs.**

M8 is the embarrassing one, because it is a mistake this repository already
documents. Integration section 4h streams samples through the top and commits a new
scale configuration mid-stream — and the two configurations it used were `gain=256,
shift=3` and `gain=64, shift=1`, which both compute `y = x*32`. The "change" changed
nothing. On top of that the sample range ran to ±512 at a gain of 32, so almost
every output clamped to ±2047 under either configuration: two independent reasons
the check could see nothing, and the second is verbatim the lesson
[docs/37](37-parameterized-video-pipelines.md) records as "a saturating
configuration hides arithmetic". The pair is now `x*32` against `x*12` with samples
kept inside the clamp, and a beat that mixes them lands on `x*8` — distinguishable
from both. **A test that exercises a configuration change has to be checked for
actually changing the function.**

M6 is more interesting because nothing was wrong with the test's construction. The
random stalls in section 3a fire about one cycle in ten and there is one commit in
the pass, so "a stall coinciding with the commit while a beat is in flight" almost
never happens. The proof catches it every time; the random testbench caught it
never. What closed the gap was a *directed* case — fill the pipeline, freeze it, arm
a genuinely different configuration on the same cycle — and that is the clearest
illustration in this document of the division of labour: coincidences are what
formal is for, and if you want a simulation to see one you have to construct it.

Adding that case also turned up a measurement error of its own. Under a global stall
the output register holds, so `y_valid` stays high and a count qualified only on
`y_valid` scored the same held beat once per stalled cycle — eight "beats" for
three. The count is now qualified on the enable.

**² M7's PASS is correct, not a gap.** With the shadow in `ARM_COMMIT`, `safe` wired
to "the engine is idle", and the start deferral of §9 in place, `active` provably
cannot move during a burst — so a burst engine that reads its configuration live is
harmless *in this top*. That is defence in depth working as intended, and the reason
the FSM keeps its own snapshot anyway is everything the top might become: a second
consumer narrowing the safe window, an integrator wiring `staged` by mistake, a
shadow built in the wrong mode. `cfg_burst_fsm_fv` sees the mutation immediately,
because at that level there is nothing upstream holding anything still.

### (f) Known limits

**Bounded depth on the scaler, and no `prove` task.** `cfg_pipe_scale_fv`'s BMC runs
at depth 7. The harness holds two 12×17 signed multipliers and two 30-bit variable
shifters — one set in the DUT, one in the independent reference — and a multiply
followed by a variable right shift is effectively a multiply by 2⁻ˢʰⁱᶠᵗ, which is
among the hardest things to hand a bit-vector solver. Measured:

| | result |
|---|---|
| depth 6, boolector | PASS, 1s |
| depth 7, boolector | PASS, <1s |
| depth 8, boolector | no result in 300s |
| depth 12, boolector / yices / z3 / `abc bmc3` | no result in 200s each |
| unbounded (`prove`) | no result in 240s |

That is a cliff rather than a curve, and it is why there is no `prove` task: an
unbounded claim that cannot be checked is worse than a bounded one that can.

Depth 7 is nonetheless enough for what this proof is for. With reset at step 0, a
beat entering at step 1 leaves at step 4, so a commit landing at step 2 or 3 shows
as a wrong value at step 4 — and the negative control confirms it rather than
arguing it: the same proof against the LIVE datapath **fails in one second at depth
7**. The arithmetic gets its depth from the testbench, which runs 26 random beats
per mode against the same golden model plus the directed cases above.

**One measurement that is a dividend rather than a limit.** Rebuild the harness with
the shadow made TRANSPARENT, so `cfg` is free to move on every cycle, and even the
*correct* TRAVEL proof stops terminating — no result in 300 seconds at the depth
that otherwise finishes in one. A configuration that only moves at commits is a
configuration the solver barely has to explore. **Safe reconfiguration is also
cheaper to verify**, which is not the reason to do it but is a pleasant thing to
discover.

**Bounded, and no `prove` task, on the burst engine either.** `cfg_burst_fsm_fv`
assumes `1 <= len <= 4`, purely so a burst can complete inside the window — a
4095-beat burst needs 4095 steps and nothing about the properties changes with the
number.

It had a `prove` task and it does not close: UNKNOWN after 677 seconds, *including*
the four extra invariants written specifically to close it. The obstruction is the
multiplier in the address law — showing `addr + stride == base + (cnt+1)*stride`
from an arbitrary starting state needs distributivity over a 16×16 multiply. The
four invariants stayed, because they are true and the bounded proof checks them, but
the unbounded claim went. `bmc` at depth 22 covers every burst up to length 4
through to completion with back-pressure, which is every distinct behaviour this
state machine has.

**No CDC proof.** Section 10 is a sketch. Nothing in it is built here.

**`inside` is not available.** The Yosys frontend rejects it, so a one-hot state
check in `cfg_burst_fsm`'s formal block had to be written differently — which was
lucky, because all four encodings of a 2-bit state are legal and that check would
have been vacuous anyway. What replaced it (a header precedes every data beat; a
trailer follows all of them) is not.

---

## 12. Checklist

Configuration that comes from software, arriving in a design that is running:

- [ ] Is there a **commit point** at all, or does the design read the bank's outputs
      directly?
- [ ] Does the whole configuration commit in **one cycle, under one enable**? Per-field
      loads put the tearing back.
- [ ] Who defines `safe`? It must be an output of the **consumer**, not a guess in the
      integration.
- [ ] For a quiesced pipeline, is `safe` **empty *and* admitting nothing**? `!busy` alone
      leaves one cycle of exposure.
- [ ] If the configuration travels with the data, are the travelling registers gated
      by the **same enable** as the datapath?
- [ ] For an FSM, is the configuration **snapshot at the start of the unit of work**?
      Especially if any field changes the transition graph rather than a value.
- [ ] Is the commit window an **intersection** of several consumers' safe windows, and
      can that intersection be permanently empty under load?
- [ ] Is `arm` a **write strobe**, not a self-clearing bit?
- [ ] Can software **see** what the hardware is using — an ACTIVE mirror — and not just
      what it wrote?
- [ ] Is there a `pending` flag and an `applied` **event**, so a delayed commit is
      observable?
- [ ] Is a configuration write during a pending commit **suppressed and reported**, or
      does it silently join the commit it raced?
- [ ] Does any command decode need the commit to have **already landed** (the arm+start
      race)?
- [ ] If the bank is in another clock domain, is the configuration crossed as a
      **quasi-static bus qualified by a synchronized pulse** — never bit by bit — and
      constrained with `set_max_delay -datapath_only`?
- [ ] Does the verification leave the configuration **free to move**, and is there a
      **cover** proving the solver actually moved it?

---

## See also

- [docs/36 — Common peripheral modules](36-common-peripheral-modules.md) — `csr_bank`,
  `apb_slave`, `axil_slave`, and the W1C semantics this document relies on
- [docs/38 — Pipeline staging and stall control](38-pipeline-staging-and-stalls.md) —
  `pipe_ctrl`, global stalls, and flush versus drain
- [docs/26 — FSM coding styles](26-fsm-coding-styles.md) — state encoding and
  illegal-state recovery
- [docs/28 — Clock domain crossing](28-clock-domain-crossing.md) — why a multi-bit
  bus cannot be synchronized bit by bit, and how to constrain one that crosses
- [docs/32 — Timing constraints](32-timing-constraints.md) — `set_max_delay
  -datapath_only`, and why `set_clock_groups -asynchronous` is not a substitute
- [docs/30 — Flow control and handshakes](30-flow-control-and-handshakes.md) — the
  valid/ready contract the burst engine obeys
- [docs/25 — Formal verification with sby](25-formal-verification-with-sby.md) —
  where properties live, and the Yosys frontend's limits
