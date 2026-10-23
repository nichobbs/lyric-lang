//! impl_self_spelling_self_test.l — dotnet runtime regression test for an
//! `impl` method that spells the target type where the interface slot says
//! `Self` (#8313).
//!
//! The interface slot erases `Self` to `object` on dotnet, so an impl method
//! declared `func takeFrom(self: in Box, other: in Box)` used to encode its own
//! `Box` parameter and no longer matched the slot: `TypeLoadException: Method
//! 'takeFrom' ... does not have an implementation`.  Covers an `in` parameter,
//! an `inout` parameter and the return position, called on the concrete
//! receiver and through an interface-typed binding.  The JVM backend has the
//! same mismatch for the interface-typed call (the concrete call works); it is
//! tracked separately, so this file is not run with `--target jvm`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/impl_self_spelling_self_test.l
@test_module
package Lyric.ImplSelfSpellingSelfTest

import Std.Core
import Std.Testing

record Box {
  n: Int
}

interface Taker {
  func takeFrom(self: in Self, other: in Self): Int
}

interface Merger {
  func merged(self: in Self, other: in Self): Self
}

interface Absorber {
  func absorb(self: in Self, other: inout Self): Int
}

impl Taker for Box {
  func takeFrom(self: in Box, other: in Box): Int {
    self.n + other.n
  }
}

impl Merger for Box {
  func merged(self: in Box, other: in Box): Box {
    Box(n = self.n * 10 + other.n)
  }
}

impl Absorber for Box {
  func absorb(self: in Box, other: inout Box): Int {
    val total = self.n + other.n
    other = Box(n = 0)
    total
  }
}

test "in parameter spelled as the target type" {
  assertEqualInt(Box(n = 1).takeFrom(Box(n = 2)), 3, "concrete receiver")
}

test "in parameter through an interface-typed binding" {
  val t: Taker = Box(n = 4)
  assertEqualInt(t.takeFrom(Box(n = 5)), 9, "interface dispatch")
}

test "return position spelled as the target type" {
  val m = Box(n = 1).merged(Box(n = 2))
  assertEqualInt(m.n, 12, "merged value")
}

test "inout parameter spelled as the target type" {
  var other = Box(n = 7)
  val total = Box(n = 3).absorb(other)
  assertEqualInt(total, 10, "sum before reset")
  assertEqualInt(other.n, 0, "inout write-back")
}
