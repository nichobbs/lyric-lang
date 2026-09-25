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
