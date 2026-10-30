//! `Self` in branch joins and bindings inside impls and record methods
//! (#7793): `if c { self } else { other }` with `other: in Self` joins with
//! the impl target, for generic and non-generic targets.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/self_join_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/self_join_self_test.l
//!   lyric test --target native lyric-compiler/lyric/self_join_self_test.l
@test_module
package Lyric.SelfJoinSelfTest

import Std.Core
import Std.Testing

interface Pick {
  func pk(self: in Self, other: in Self, c: in Bool): Self
}

record Acc {
  n: Int
}

record Box[T] {
  v: T
  func pick(self: in Box[T], other: in Self, c: in Bool): Box[T] {
    if c {
      self
    } else {
      other
    }
  }
  func mk(self: in Self, c: in Bool): Self {
    val a = if c { self } else { Box(v = self.v) }
    a
  }
}

impl Pick for Acc {
  func pk(self: in Self, other: in Self, c: in Bool): Self {
    val r = if c { self } else { Acc(n = other.n) }
    if c {
      r
    } else {
      other
    }
  }
}

impl[T] Pick for Box[T] {
  func pk(self: in Self, other: in Self, c: in Bool): Self {
    if c {
      self
    } else {
      other
    }
  }
}

test "Self joins with the impl target in an if or a binding" {
  assertEqualInt(Acc(n = 1).pk(Acc(n = 2), false).n, 2, "plain impl")
  assertEqualInt(Box(v = 1).pk(Box(v = 2), false).v, 2, "generic impl")
  assertEqualInt(Box(v = 1).pick(Box(v = 2), false).v, 2, "record method, Self parameter")
  assertEqualInt(Box(v = 1).mk(false).v, 1, "record method, bound join")
}
