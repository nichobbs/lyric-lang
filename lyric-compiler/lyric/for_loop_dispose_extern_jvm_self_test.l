//! for_loop_dispose_extern_jvm_self_test.l - runtime regression test for the
//! disposal of an extern iterator by a `for` loop on `--target jvm` (#7770,
//! D143).
//!
//! A Lyric record implements the JDK's own `java.lang.Iterable`,
//! `java.util.Iterator` and `java.lang.AutoCloseable` (docs/51), and the loop
//! iterates it through a binding typed as `Iterable`. The iterator counts its
//! `close()` calls, which makes the D143 guarantees observable: one `close()`
//! on every way out of the loop (end, `break`, `return`, `?`, `break outer`,
//! `continue outer`, a caught panic), none twice, and the consumer's panic
//! winning over one raised by `close()` (attached as suppressed).
//!
//! The dotnet half is `for_loop_dispose_extern_self_test.l`.
//!
//!   lyric test --target jvm lyric-compiler/lyric/for_loop_dispose_extern_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ForLoopDisposeExternJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

extern type Obj = "java.lang.Object"

extern type Iterable = "java.lang.Iterable"

extern type Iterator = "java.util.Iterator"

extern type AutoCloseable = "java.lang.AutoCloseable"

ref record Probe {
  var disposed: Int
  var made: Int
  var panicOnDispose: Bool
}

ref record Cursor {
  probe: Probe
  var pos: Int
  limit: Int
}

impl Iterator for Cursor {
  func hasNext(): Bool {
    self.pos < self.limit
  }

  func next(): Obj {
    self.pos = self.pos + 1
    Obj.new()
  }
}

impl AutoCloseable for Cursor {
  func close(): Unit {
    self.probe.disposed = self.probe.disposed + 1
    if self.probe.panicOnDispose {
      panic("dispose failed")
    }
  }
}

record Seq {
  probe: Probe
  limit: Int
}

impl Iterable for Seq {
  func iterator(): Iterator {
    self.probe.made = self.probe.made + 1
    Cursor(probe = self.probe, pos = 0, limit = self.limit)
  }
}

func newProbe(): Probe {
  Probe(disposed = 0, made = 0, panicOnDispose = false)
}

func seqOf(p: in Probe, limit: in Int): Iterable {
  Seq(probe = p, limit = limit)
}

func joinStrings(xs: in List[String]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + xs[i]
    i = i + 1
  }
  s
}

func countAll(s: in Iterable): Int {
  var n = 0
  for o in s {
    n = n + 1
  }
  n
}

func stopAtTwo(s: in Iterable): Int {
  var n = 0
  for o in s {
    n = n + 1
    if n == 2 {
      break
    }
  }
  n
}

func returnsAtTwo(s: in Iterable, log: in List[String]): Int {
  defer {
    log.add("consumer defer")
  }
  var n = 0
  for o in s {
    n = n + 1
    log.add("consumer ${n}")
    if n == 2 {
      return n
    }
  }
  -1
}

func reject(n: in Int): Result[Int, String] {
  if n == 2 {
    Err("two")
  } else {
    Ok(n)
  }
}

func tryAtTwo(s: in Iterable): Result[Int, String] {
  var n = 0
  for o in s {
    n = n + 1
    val v = reject(n)?
  }
  Ok(n)
}

func breakOuter(s: in Iterable): Int {
  var rounds = 0
  outer: for round in [1, 2, 3] {
    rounds = rounds + 1
    for o in s {
      break outer
    }
  }
  rounds
}

func continueOuter(s: in Iterable): Int {
  var rounds = 0
  outer: for round in [1, 2, 3] {
    rounds = rounds + 1
    for o in s {
      continue outer
    }
  }
  rounds
}

func nested(a: in Iterable, b: in Iterable): Int {
  var pairs = 0
  for x in a {
    for y in b {
      pairs = pairs + 1
    }
  }
  pairs
}

func panicsInBody(s: in Iterable): Int {
  var n = 0
  for o in s {
    n = n + 1
    panic("consumer failed")
  }
  n
}

test "for over an extern iterable: running to the end disposes the iterator once" {
  val p = newProbe()
  assertEqualInt(countAll(seqOf(p, 3)), 3, "every element is visited")
  assertEqualInt(p.made, 1, "one iterator was made")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}

test "for over an extern iterable: an empty sequence still disposes its iterator" {
  val p = newProbe()
  assertEqualInt(countAll(seqOf(p, 0)), 0, "no element")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}

test "for over an extern iterable: break disposes once" {
  val p = newProbe()
  assertEqualInt(stopAtTwo(seqOf(p, 5)), 2, "stopped at the second element")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}

test "for over an extern iterable: return disposes once, before the consumer's defer" {
  val p = newProbe()
  val log: List[String] = newList()
  assertEqualInt(returnsAtTwo(seqOf(p, 5), log), 2, "returned from the second element")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
  assertEqual(joinStrings(log), "consumer 1,consumer 2,consumer defer", "the consumer's defer ran once")
}

test "for over an extern iterable: ? propagation disposes once" {
  val p = newProbe()
  val r = tryAtTwo(seqOf(p, 5))
  assertTrue(match r { case Err(e) -> e == "two"; case Ok(_) -> false }, "the Err reached the caller")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}

test "for over an extern iterable: break outer disposes the inner iterator once" {
  val p = newProbe()
  assertEqualInt(breakOuter(seqOf(p, 3)), 1, "the outer loop stopped after one round")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}

test "for over an extern iterable: continue outer disposes each round's iterator once" {
  val p = newProbe()
  assertEqualInt(continueOuter(seqOf(p, 3)), 3, "every round ran")
  assertEqualInt(p.made, 3, "one iterator per round")
  assertEqualInt(p.disposed, 3, "each disposed exactly once")
}

test "for over an extern iterable: nested loops dispose each iterator once" {
  val pa = newProbe()
  val pb = newProbe()
  assertEqualInt(nested(seqOf(pa, 2), seqOf(pb, 3)), 6, "2 x 3 pairs")
  assertEqualInt(pa.disposed, 1, "the outer iterator disposed once")
  assertEqualInt(pb.made, 2, "one inner iterator per outer element")
  assertEqualInt(pb.disposed, 2, "each inner iterator disposed once")
}

test "for over an extern iterable: the same sequence iterated twice makes two iterators" {
  val p = newProbe()
  val s = seqOf(p, 2)
  assertEqualInt(countAll(s) + countAll(s), 4, "both passes visit every element")
  assertEqualInt(p.made, 2, "one iterator per pass")
  assertEqualInt(p.disposed, 2, "each disposed exactly once")
}

test "for over an extern iterable: a panic in the body disposes once and reaches the caller" {
  val p = newProbe()
  var caught = ""
  try {
    panicsInBody(seqOf(p, 3))
  } catch Bug as e {
    caught = e.message
  }
  assertTrue(caught.contains("consumer failed"), "the body's panic reached the caller: '" + caught + "'")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}

test "for over an extern iterable: a disposal that panics on a normal exit reaches the caller" {
  val p = newProbe()
  p.panicOnDispose = true
  var caught = ""
  try {
    countAll(seqOf(p, 2))
  } catch Bug as e {
    caught = e.message
  }
  assertTrue(caught.contains("dispose failed"), "the disposal's panic reached the caller: '" + caught + "'")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}

test "for over an extern iterable: the consumer's panic takes precedence over one from the disposal" {
  val p = newProbe()
  p.panicOnDispose = true
  var caught = ""
  try {
    panicsInBody(seqOf(p, 3))
  } catch Bug as e {
    caught = e.message
  }
  assertTrue(caught.contains("consumer failed"), "the consumer's panic reached the caller: '" + caught + "'")
  assertFalse(caught.contains("dispose failed"), "not the disposal's panic: '" + caught + "'")
  assertEqualInt(p.disposed, 1, "disposed exactly once")
}
