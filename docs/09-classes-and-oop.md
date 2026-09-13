# Classes and Object-Oriented SystemVerilog **[V]**

Classes are simulation-only. Everything here belongs in a testbench.

## 1. Declaration

```systemverilog
class Packet;
  // properties
  rand  bit [7:0]  payload [];
  rand  bit [3:0]  id;
  local int        secret;
  protected string name;
  static int       count;         // one per class, not per object
  const  int       tag;           // assigned once, in the constructor

  // constructor
  function new(string n = "pkt", int t = 0);
    name  = n;
    tag   = t;                    // `const` may only be set here
    count++;
  endfunction

  // methods
  virtual function void display();
    $display("[%s] id=%0h len=%0d", name, id, payload.size());
  endfunction

  function Packet clone();
    Packet p = new(name, tag);
    p.id      = id;
    p.payload = new[payload.size()] (payload);   // deep copy of the array
    return p;
  endfunction
endclass
```

## 2. Handles, not values

```systemverilog
Packet a, b;
a = new();
b = a;              // b and a point to the SAME object
b.id = 4'h5;        // a.id is now 4'h5 too
b = a.clone();      // now they are independent
a = null;           // the object survives while b references it
```

There is no `delete` — SystemVerilog is garbage collected. An object lives until
the last handle to it goes out of scope or is set to `null`. The corollary: a
handle stored in a long-lived queue keeps its object alive forever, which is how
testbench memory leaks happen.

### Shallow copy

```systemverilog
Packet b = new a;      // "shallow copy" constructor
```

Copies every property bit-for-bit, including **handles** — so `b.payload` and
`a.payload` are the same dynamic array. This is almost never what you want.
Write an explicit `copy()`/`clone()` and be deliberate about depth.

## 3. Access control

| Qualifier | Visible to |
|---|---|
| (none) | everyone |
| `protected` | the class and its subclasses |
| `local` | the class only — **not** subclasses |

```systemverilog
class Base;
  local     int a;      // Derived cannot see this
  protected int b;      // Derived can
  int           c;      // everyone
endclass
```

`local` is stricter than most languages' `private` in one respect: another
object *of the same class* can still access it (like C++ `private`), but a
subclass cannot.

## 4. Static members

```systemverilog
class Counter;
  static int  instances = 0;
  static bit  debug     = 0;
  int         id;

  function new();
    id = instances++;          // instance count is shared
  endfunction

  static function void enable_debug();   // callable without an object
    debug = 1;
  endfunction
endclass

Counter::enable_debug();
$display("%0d created", Counter::instances);
```

A `static` method may only touch `static` properties — it has no `this`.

## 5. Inheritance and polymorphism

```systemverilog
class Base;
  virtual function void run();  $display("base");  endfunction
  function void nonvirt();      $display("base");  endfunction
endclass

class Derived extends Base;
  function new();
    super.new();                // must be first if Base::new takes arguments
  endfunction
  virtual function void run();    $display("derived"); endfunction
  function void nonvirt();        $display("derived"); endfunction
endclass

Base b = Derived::new();
b.run();        // "derived"  -- virtual dispatch on the ACTUAL type
b.nonvirt();    // "base"     -- static dispatch on the DECLARED type
```

**Mark every method `virtual`** unless you have a specific reason not to. A
non-virtual method silently breaks every factory-override and
polymorphic-callback pattern, and the failure is invisible — the code runs, it
just runs the wrong version.

### Abstract classes

```systemverilog
virtual class Transaction;              // cannot be instantiated
  pure virtual function void pack(ref byte b[]);   // no body; subclass MUST
  virtual function string name();       // has a body; subclass MAY override
    return "txn";
  endfunction
endclass
```

`pure virtual` is only legal inside a `virtual class`.

### Interface classes

```systemverilog
interface class Comparable;
  pure virtual function bit compare(Comparable other);
endinterface

interface class Printable;
  pure virtual function string to_str();
endinterface

class Packet extends Base implements Comparable, Printable;
  virtual function bit compare(Comparable other);  ...  endfunction
  virtual function string to_str();                ...  endfunction
endclass
```

This gives multiple inheritance of **API only** — no implementation, no data.
It is how you write a generic sorter or comparator without a common base class.

### Downcasting

```systemverilog
Base    b = Derived::new();
Derived d;
if ($cast(d, b))  d.derived_only_method();
else              $error("not a Derived");
```

`$cast` is the only safe downcast. A plain assignment `d = b;` is a compile
error (upcast is implicit, downcast is not).

## 6. Parameterized classes

```systemverilog
class Fifo #(type T = int, int DEPTH = 16);
  local T q[$];
  function bit push(T item);
    if (q.size() >= DEPTH) return 0;
    q.push_back(item);
    return 1;
  endfunction
  function bit pop(ref T item);
    if (q.size() == 0) return 0;
    item = q.pop_front();
    return 1;
  endfunction
endclass

Fifo #(Packet, 8)  pkt_fifo = new();
Fifo #(int)        int_fifo = new();
```

Each specialization is a **distinct type**: `Fifo#(int)` and `Fifo#(bit)` have
separate static members and are not assignment-compatible. `Fifo#(int, 16)` and
`Fifo#(int)` (with the default 16) are the *same* type.

A common idiom is a parameterized class used purely as a namespace for static
functions, working around the lack of parameterized package functions:

```systemverilog
class BitOps #(int W = 8);
  static function logic [W-1:0] reverse(logic [W-1:0] v);
    logic [W-1:0] r;
    foreach (v[i]) r[W-1-i] = v[i];
    return r;
  endfunction
endclass

logic [15:0] x = BitOps#(16)::reverse(y);
```

## 7. `extern` and out-of-body definitions

```systemverilog
class Driver;
  extern function      new(string name);
  extern virtual task  run();
  extern function void report();
endclass

function Driver::new(string name);
  this.name = name;
endfunction

task Driver::run();
  forever begin ... end
endtask
```

This keeps the class declaration readable as an interface summary, with the
bodies below. It is the dominant style in large verification libraries.

## 8. `this`, chaining, and common patterns

```systemverilog
class Config;
  int len, kind;
  function Config set_len(int v);   len  = v; return this;  endfunction
  function Config set_kind(int v);  kind = v; return this;  endfunction
endclass

Config c = Config::new().set_len(64).set_kind(2);   // fluent builder
```

### Singleton

```systemverilog
class Registry;
  local static Registry inst;
  local function new(); endfunction        // local constructor
  static function Registry get();
    if (inst == null) inst = new();
    return inst;
  endfunction
endclass
```

### Factory (the core of UVM's override mechanism)

```systemverilog
class Factory;
  static function Transaction create(string type_name);
    case (type_name)
      "read":  return ReadTxn::new();
      "write": return WriteTxn::new();
      default: return null;
    endcase
  endfunction
endclass
```

A real factory registers types dynamically using a proxy-class table so that new
types can be added without editing the factory; UVM's `uvm_object_registry` is
that pattern.

### Callback

```systemverilog
virtual class DriverCb;
  virtual task pre_send(ref Packet p);  endtask
  virtual task post_send(Packet p);     endtask
endclass

class Driver;
  DriverCb cbs[$];
  task send(Packet p);
    foreach (cbs[i]) cbs[i].pre_send(p);
    ... drive ...
    foreach (cbs[i]) cbs[i].post_send(p);
  endtask
endclass
```

Callbacks let a test inject error behaviour (corrupt a packet, delay a
handshake) without subclassing or editing the driver.

## 9. Practical guidance

1. `virtual` on every method, always.
2. `extern` the bodies out of big classes.
3. Give every class a `convert2string()`/`to_str()` — you will need it the first
   time a test fails at 3am.
4. Never store a raw handle you did not create without documenting ownership;
   a handle in a queue is a reference that keeps the object alive.
5. Prefer composition over deep inheritance. Three levels is usually one too
   many.
6. Use a parameterized class as a namespace when you need a parameterized
   function.
