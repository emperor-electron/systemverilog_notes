# Processes, `fork`, and Synchronization **[V]**

## 1. Process creation

```systemverilog
initial   begin ... end          // one process, starts at time 0
always    begin ... end          // one process, restarts forever
fork ... join                    // spawn children, wait for ALL
fork ... join_any                // spawn children, wait for the FIRST
fork ... join_none               // spawn children, do not wait
```

```systemverilog
initial begin
  fork
    a_task();
    b_task();
  join                     // both must finish

  fork
    timeout(1000);
    wait_for_done();
  join_any                 // whichever finishes first
  disable fork;            // kill the loser
end
```

With `join_none`, the children do not start until the parent **blocks** or
finishes — they are scheduled, not run. That surprises people:

```systemverilog
initial begin
  fork  $display("child");  join_none
  $display("parent");
  #0;                      // parent blocks -> child runs here
end
// prints: parent, child
```

## 2. The `fork` loop-variable trap

```systemverilog
// WRONG: all four processes see the final value of i
for (int i = 0; i < 4; i++)
  fork
    drive_lane(i);
  join_none

// RIGHT: a fresh automatic per iteration
for (int i = 0; i < 4; i++) begin
  automatic int k = i;
  fork
    drive_lane(k);
  join_none
end
```

The `int i` in a `for` header *is* automatic per the LRM, but the process body
captures the variable by reference, and by the time the child runs the loop has
advanced. The explicit `automatic int k = i;` inside the loop body creates a new
object each iteration that the child captures. Always write it.

## 3. Killing processes

```systemverilog
disable fork;                    // kill all children of the CURRENT process
disable label;                   // kill a named block or task, anywhere
wait fork;                       // block until all children finish
```

```systemverilog
// Timeout wrapper -- the idiomatic form
task automatic with_timeout(input int cycles);
  fork : timeout_blk
    begin
      do_the_thing();
    end
    begin
      repeat (cycles) @(posedge clk);
      $error("timeout after %0d cycles", cycles);
    end
  join_any
  disable fork;         // kills whichever branch is still running
endtask
```

`disable fork` kills **all** descendants of the current process, including ones
spawned by a task you called. If a monitor was started elsewhere in the same
process tree, it dies too. The safer modern form uses the `process` class:

```systemverilog
process p_worker, p_timer;

fork
  begin p_worker = process::self(); do_the_thing(); end
  begin p_timer  = process::self(); repeat (N) @(posedge clk); end
join_any

if (p_worker.status() != process::FINISHED) p_worker.kill();
else                                         p_timer.kill();
```

### The `process` class

```systemverilog
process p = process::self();
p.status();       // CREATED, RUNNING, WAITING, SUSPENDED, KILLED, FINISHED
p.kill();
p.suspend();  p.resume();
p.await();        // block until p finishes
p.srandom(seed);
p.get_randstate();  p.set_randstate(s);
```

## 4. Event control

```systemverilog
@(posedge clk)          // rising edge (0->1, x->1, z->1)
@(negedge clk)
@(edge clk)             // either
@(sig)                  // any value change
@(a or b or c)          // any of
@(a, b, c)              // same
@*                      // all signals read in the following statement
@(e)                    // named event
wait (expr);            // level: returns immediately if expr is already true
wait_order(a, b, c);    // events must fire in this order, else fail
```

**`@` vs `wait`** is the single most common source of hangs:

```systemverilog
@(posedge done);        // waits for an EDGE -- hangs forever if done is
                        //   already 1 and never toggles
wait (done);            // returns IMMEDIATELY if done is already 1
```

Use `wait` for level conditions and `@` for edges. For "wait until the next
clock edge where a condition holds":

```systemverilog
do @(posedge clk); while (!ready);         // at least one edge, then poll
// or
@(posedge clk iff ready);                  // SystemVerilog `iff` qualifier
```

## 5. Named events

```systemverilog
event e;

->e;             // trigger (blocking semantics: fires in the current region)
->>e;            // non-blocking trigger (fires in the NBA region)
@(e);            // wait for the trigger
wait (e.triggered);   // true for the whole time step in which e fired
```

`@(e)` is an edge — if the trigger happened one delta earlier, you miss it.
`e.triggered` is level-ish within the time step and is race-immune:

```systemverilog
// Racy: if ->e happens before this process reaches @(e), it hangs
initial begin @(e); $display("got it"); end
initial begin ->e; end

// Safe
initial begin wait (e.triggered); $display("got it"); end
```

Events can be assigned (`e1 = e2` makes them the same event) and compared to
`null`.

## 6. Semaphores

```systemverilog
semaphore sem = new(1);     // 1 key: a mutex

task automatic critical();
  sem.get(1);               // blocks until a key is available
  ... exclusive access ...
  sem.put(1);
endtask

sem.try_get(1);             // returns 0 immediately instead of blocking
```

A semaphore with `n` keys models a resource pool of size `n`. There is no
ownership tracking: any process can `put` a key it never got, so a bug here
manifests as a slow key leak.

## 7. Mailboxes

```systemverilog
mailbox #(Packet) mbx = new();      // unbounded
mailbox #(Packet) b   = new(4);     // bounded: put() blocks when full

mbx.put(p);         // blocking
mbx.get(p);         // blocking, REMOVES the item
mbx.peek(p);        // blocking, leaves the item
mbx.try_put(p);     // 0 if full
mbx.try_get(p);     // 0 if empty
mbx.try_peek(p);
mbx.num();          // current count
```

A **parameterized** mailbox (`mailbox #(Packet)`) is type-checked; a bare
`mailbox` accepts anything and fails at run time. Always parameterize.

A bounded mailbox provides backpressure between testbench components, which is
how you keep a fast generator from allocating a million transactions ahead of a
slow driver.

## 8. Putting it together: a producer/consumer

```systemverilog
class Env;
  mailbox #(Packet) gen2drv = new(8);
  mailbox #(Packet) mon2scb = new();
  semaphore         bus_lock = new(1);
  event             done_e;

  task run(int n);
    fork
      generator(n);
      driver();
      monitor();
      scoreboard(n);
    join_none

    wait (done_e.triggered);
    disable fork;
  endtask

  task generator(int n);
    repeat (n) begin
      Packet p = new();
      if (!p.randomize()) $fatal(1, "rand failed");
      gen2drv.put(p);            // blocks when the driver is 8 behind
    end
  endtask

  task driver();
    forever begin
      Packet p;
      gen2drv.get(p);
      bus_lock.get(1);
      drive_on_bus(p);
      bus_lock.put(1);
    end
  endtask

  task scoreboard(int n);
    repeat (n) begin
      Packet p;
      mon2scb.get(p);
      check(p);
    end
    ->done_e;
  endtask
endclass
```

## 9. Determinism checklist

Races in a testbench are usually one of these:

| Symptom | Cause | Fix |
|---|---|---|
| Value read one cycle late/early, varies by tool | reading a DUT signal directly at a clock edge | use a clocking block |
| Hang that depends on process start order | `@(e)` racing `->e` | `wait (e.triggered)` |
| Every forked process uses the same index | loop variable captured by reference | `automatic` copy in the loop body |
| Different results with the same seed | a `static` task called concurrently | `automatic` |
| Works alone, fails in a regression | reliance on `$unit` compile order | move types to a package |
