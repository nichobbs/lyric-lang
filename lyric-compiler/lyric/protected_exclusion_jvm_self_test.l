//! Protected-type members are mutually exclusive (#7363).
//!
//! §7.5: `entry` and `func` operations on a protected type run one at a time.
//! The JVM backend emitted them as plain methods, so concurrent entries lost
//! updates (4 x 2000 increments ended at ~5300) and a `func` could observe a
//! half-applied entry, and `when:` barriers were ignored.  Every member is
//! now `synchronized` and a barrier waits on the monitor.  `spawn` runs on
//! real threads on the JVM (on dotnet it is synchronous, so the dotnet
//! counterpart, `protected_exclusion_dotnet_self_test.l`, uses `Task.Run`).
@test_module
package ProtectedExclusionJvmSelfTest

import Std.Core
import Std.Testing

protected type Pair {
  var a: Int = 0
  var b: Int = 0
  var torn: Int = 0
  entry bump(): Unit {
    val cur = a
    var spin = 0
    while spin < 200 {
      spin = spin + 1
    }
    a = cur + 1
    b = cur + 1
  }
  func consistent(): Bool = a == b
  entry noteTorn(): Unit {
    torn = torn + 1
  }
  func count(): Int = a
  func tornCount(): Int = torn
}

async func bumper(p: in Pair): Int {
  var i = 0
  while i < 2000 {
    p.bump()
    i = i + 1
  }
  0
}

async func reader(p: in Pair): Int {
  var i = 0
  var seen = 0
  while i < 2000 {
    if not p.consistent() {
      seen = seen + 1
    }
    i = i + 1
  }
  seen
}

async func race(): Int {
  val p = Pair()
  var torn = 0
  scope {
    val w1 = spawn bumper(p)
    val w2 = spawn bumper(p)
    val w3 = spawn bumper(p)
    val w4 = spawn bumper(p)
    val r = spawn reader(p)
    val _ = await w1
    val _ = await w2
    val _ = await w3
    val _ = await w4
    torn = await r
  }
  if torn > 0 {
    return -torn
  }
  p.count()
}

test "concurrent entries do not lose updates and funcs see whole entries" {
  val result = await race()
  assertTrue(result == 8000, "4 x 2000 increments, no torn read (got " + toString(result) + ")")
}

// A one-element buffer: `put` waits while it is full, `take` while it is
// empty.  Without barriers `take` reads an empty slot.
protected type Slot {
  var full: Bool = false
  var item: Int = 0
  entry put(x: in Int): Unit
    when: not full
  {
    item = x
    full = true
  }
  entry take(): Int
    when: full
  {
    full = false
    item
  }
}

async func producer(s: in Slot): Int {
  var i = 1
  while i <= 100 {
    s.put(i)
    i = i + 1
  }
  0
}

async func consumer(s: in Slot): Int {
  var sum = 0
  var i = 0
  while i < 100 {
    sum = sum + s.take()
    i = i + 1
  }
  sum
}

async func pipeline(): Int {
  val s = Slot()
  var total = 0
  scope {
    val c = spawn consumer(s)
    val p = spawn producer(s)
    val _ = await p
    total = await c
  }
  total
}

test "when: barriers make a caller wait for the state it needs" {
  val total = await pipeline()
  assertTrue(total == 5050, "every item delivered exactly once (got " + toString(total) + ")")
}

// A func that changes barrier state must wake the waiters too, and a func
// may carry its own `when:` barrier (#7384).  Before, only entries notified,
// so a waiter released only by `open()` blocked forever.
protected type Gate {
  var isOpen: Bool = false
  var passed: Int = 0
  entry pass(): Unit
    when: isOpen
  {
    passed = passed + 1
  }
  func peekOpen(): Int
    when: isOpen
  {
    7
  }
  func open(): Unit {
    isOpen = true
  }
  func passedCount(): Int = passed
}

async func passer(g: in Gate): Int {
  g.pass()
  0
}

async func peeker(g: in Gate): Int {
  g.peekOpen()
}

async func opener(g: in Gate): Int {
  g.open()
  0
}

async func gateRun(): Int {
  val g = Gate()
  var seen = 0
  scope {
    val w = spawn passer(g)
    val f = spawn peeker(g)
    val o = spawn opener(g)
    val opened = await o
    val passedAt = await w
    seen = await f + opened + passedAt
  }
  seen + g.passedCount()
}

test "a func that opens a barrier wakes an entry and a func waiting on it (#7384)" {
  val r = await gateRun()
  assertTrue(r == 8, "func barrier saw 7 and the entry passed once (got " + toString(r) + ")")
}

// Expression-bodied `Unit` members, whose expression pushes nothing (a void
// call) or a value that must be discarded (#7400).
func noteInto(c: in Tally): Unit {
  c.bump()
}

protected type Tally {
  var n: Int = 0
  entry bump(): Unit {
    n = n + 1
  }
  func viaVoidCall(): Unit = noteInto(self)
  entry viaUnitLiteral(): Unit = ()
  func value(): Int = n
}

test "expression-bodied Unit protected members run (#7400)" {
  val t = Tally()
  t.viaVoidCall()
  t.viaUnitLiteral()
  t.viaVoidCall()
  assertTrue(t.value() == 2, "two bumps through the expression-bodied func (got " + toString(t.value()) + ")")
}
