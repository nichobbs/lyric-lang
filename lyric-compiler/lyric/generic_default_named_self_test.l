//! `T.default()` under `where T: Default` at a distinct type or a record (#8531).
//!
//! D224 lowered `T.default()` at a scalar primitive only. At a distinct type the
//! specialisation is `X.from(<zero of the underlying type>)`; at a record it is
//! the constructor with each field at its declared default or its own zero.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_default_named_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generic_default_named_self_test.l
//!   lyric test --target native lyric-compiler/lyric/generic_default_named_self_test.l
@test_module
package Lyric.GenericDefaultNamedSelfTest

import Std.Core
import Std.Testing

type Level = Int derives Default

type Ratio = Double derives Default

@derive(Default)
record Slot {
  n: Int
  label: String
  level: Level
}

func zeroOf[T](x: in T): T
  where T: Default
{
  T.default()
}

test "T.default() at a distinct type is the underlying zero" {
  assertEqual(toString(zeroOf(Level.from(7))), "0", "distinct Int")
  assertEqual(toString(zeroOf(Ratio.from(2.5))), "0", "distinct Double")
}

test "T.default() at a record is each field's zero" {
  val z = zeroOf(Slot(n = 3, label = "x", level = Level.from(9)))
  assertEqual(toString(z.n), "0", "Int field")
  assertEqual(z.label, "", "String field")
  assertEqual(toString(z.level), "0", "distinct field")
}

test "T.default() at a scalar is unchanged" {
  assertEqual(toString(zeroOf(5)), "0", "Int")
  assertEqual(zeroOf("abc"), "", "String")
}
