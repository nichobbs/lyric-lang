//! impl_self_spelling_self_test.l — runtime regression test for an `impl`
//! method that spells the target type where the interface slot says `Self`
//! (#8313 on dotnet, #8426 on the JVM).
//!
//! The interface slot erases `Self` to `object` / `Object`, so an impl method
//! declared `func takeFrom(self: in Box, other: in Box)` used to encode its own
//! `Box` signature and no longer matched the slot: `TypeLoadException` on
//! dotnet, `AbstractMethodError` for an interface-typed call on the JVM, where
//! the concrete call worked.  Covers an `in` parameter, an `inout` parameter
//! and the return position, called on the concrete receiver and through an
//! interface-typed binding.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/impl_self_spelling_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/impl_self_spelling_self_test.l
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

test "return position through an interface-typed binding" {
  val m: Merger = Box(n = 4)
  val r: Merger = m.merged(Box(n = 5))
  val again = r.merged(Box(n = 6))
  assertEqualInt(Box(n = 1).merged(Box(n = 2)).n, 12, "concrete merge still works")
}

test "inout parameter through an interface-typed binding" {
  val a: Absorber = Box(n = 3)
  var other = Box(n = 7)
  assertEqualInt(a.absorb(other), 10, "sum before reset")
  assertEqualInt(other.n, 0, "inout write-back")
}
