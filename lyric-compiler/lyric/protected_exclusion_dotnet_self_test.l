//! Protected-type members are mutually exclusive on dotnet (#7363).
//!
//! `spawn` is synchronous on --target dotnet, so this uses `Task.Run` for real
//! threads: concurrent entries must not lose updates, a `func` (which took
//! no lock before) must never observe a half-applied entry, and a `when:`
//! barrier (ignored before) must make the caller wait.
@test_module
package ProtectedExclusionDotnetSelfTest

import Std.Core
import Std.Testing

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

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
    var spin2 = 0
    while spin2 < 200 {
      spin2 = spin2 + 1
    }
    b = cur + 1
  }
  func consistent(): Bool = a == b
  entry noteTorn(): Unit {
    torn = torn + 1
  }
  func count(): Int = a
  func tornCount(): Int = torn
}

func bumpMany(p: in Pair): Unit {
  var i = 0
  while i < 2000 {
    p.bump()
    i = i + 1
  }
}

func readMany(p: in Pair): Unit {
  var i = 0
  while i < 4000 {
    if not p.consistent() {
      p.noteTorn()
    }
    i = i + 1
  }
}

test "concurrent entries do not lose updates and funcs see whole entries" {
  val p = Pair()
  val t1 = taskRun({ -> bumpMany(p) })
  val t2 = taskRun({ -> bumpMany(p) })
  val t3 = taskRun({ -> bumpMany(p) })
  val t4 = taskRun({ -> bumpMany(p) })
  val r = taskRun({ -> readMany(p) })
  taskWait(t1)
  taskWait(t2)
  taskWait(t3)
  taskWait(t4)
  taskWait(r)
  assertTrue(p.count() == 8000, "4 x 2000 increments (got " + toString(p.count()) + ")")
  assertTrue(p.tornCount() == 0, "no func saw a half-applied entry (saw " + toString(p.tornCount()) + ")")
}

protected type Slot {
  var full: Bool = false
  var item: Int = 0
  var sum: Int = 0
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
  entry add(x: in Int): Unit {
    sum = sum + x
  }
  func total(): Int = sum
}

func produce(s: in Slot): Unit {
  var i = 1
  while i <= 100 {
    s.put(i)
    i = i + 1
  }
}

func consume(s: in Slot): Unit {
  var i = 0
  while i < 100 {
    s.add(s.take())
    i = i + 1
  }
}

test "when: barriers make a caller wait for the state it needs" {
  val s = Slot()
  val c = taskRun({ -> consume(s) })
  val p = taskRun({ -> produce(s) })
  taskWait(p)
  taskWait(c)
  assertTrue(s.total() == 5050, "every item delivered exactly once (got " + toString(s.total()) + ")")
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

test "a func that opens a barrier wakes an entry and a func waiting on it (#7384)" {
  val g = Gate()
  val w = taskRun({ -> g.pass() })
  val f = taskRun({ -> assertTrue(g.peekOpen() == 7, "func barrier") })
  g.open()
  taskWait(w)
  taskWait(f)
  assertTrue(g.passedCount() == 1, "the waiting entry ran once the func opened the gate")
}
