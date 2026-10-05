//! inout_receiver_closure_self_test.l — runtime regression test for an
//! `inout`-receiver method call (`self: inout T`, #8179) whose receiver is a
//! `var` a closure captures, on `--target dotnet` and `--target jvm`.
//!
//! The call passes the captured variable's shared cell by reference (#8189),
//! so the closure sees the method's write and the caller sees the write of a
//! method the closure calls.  `--target native` still captures a `var` by
//! value (#7891 item 1), so this file is not run there; the rest of the
//! `inout`-receiver coverage, native included, is
//! `inout_receiver_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inout_receiver_closure_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_receiver_closure_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InoutReceiverClosureSelfTest

import Std.Core
import Std.Testing

record Pt {
  x: Int
  y: Int

  func reset(self: inout Pt): Unit {
    self = Pt(x = 0, y = 0)
  }

  func moved(self: inout Pt, d: in Int): Unit {
    self = Pt(x = x + d, y = y + d)
  }

  func sum(self: in Pt): Int = self.x + self.y
}

record Counter {
  var n: Int

  func bump(self: inout Counter, d: in Int): Unit {
    self.n = self.n + d
  }
}

record Box[T] {
  v: T

  func set(self: inout Box[T], v: in T): Unit {
    self = Box(v = v)
  }
}

test "a receiver captured by a closure" {
  var p = Pt(x = 3, y = 4)
  val read = { -> p.sum() }
  p.reset()
  val afterReset: Int = read()
  assertEqualInt(afterReset, 0, "closure reads the reset value")
  val move = { -> p.moved(5) }
  move()
  assertEqualInt(p.sum(), 10, "the closure's call writes the caller's variable")
}

test "a closure-captured counter advanced inside and outside the closure" {
  var c = Counter(n = 0)
  val step = { -> c.bump(1) }
  step()
  c.bump(10)
  step()
  assertEqualInt(c.n, 12, "count")
}

test "a closure-captured generic record as the receiver" {
  var b = Box(v = 1)
  val read = { -> b.v }
  b.set(9)
  val seen: Int = read()
  assertEqualInt(seen, 9, "closure reads the set value")
}

test "an `inout` receiver call inside a lambda on a lambda-local `var`" {
  val f = { -> var p = Pt(x = 1, y = 1); p.moved(2); p.sum() }
  val r: Int = f()
  assertEqualInt(r, 6, "result")
}
