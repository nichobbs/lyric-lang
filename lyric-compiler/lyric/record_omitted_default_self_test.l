//! record_omitted_default_self_test.l — record construction with omitted
//! default-valued fields, both targets (#5908 / #5920, and the #6146
//! non-trailing-omission field-misalignment follow-up).
//!
//! #5908 (JVM) / #5920 (MSIL): constructing a record while omitting a
//! default-valued field must materialise the field's declared default
//! expression, not a zero value.  #6146: when a NON-trailing defaulted field
//! is omitted while a LATER field is supplied (`R(a = 1, c = 9)` on
//! `record R { a: Int, b: Int = 2, c: Int = 3 }`), each field must resolve
//! against its OWN slot — the earlier JVM `orderCtorArgs` compacted the
//! supplied-args list, so `c`'s value landed in `b` and `c` got its default.
//! These bugs reproduce same-package, so a single-file `@test_module` pins
//! them (the cross-package framing of the original #5908 report was
//! incidental — see D-progress-704).
//!
//! Run in CI via native `lyric test` on BOTH targets (like
//! `block_shadow_self_test.l`).  Imports only `Std.*`.
@test_module
package Lyric.RecordOmittedDefaultSelfTest

import Std.Core
import Std.Testing

enum Colour {
  case Red
  case Green
  case Blue
}

record Cfg {
  a: Int
  b: Int = 2
  c: Int = 3
}

record Mixed {
  name: String
  tint: Colour = Green
  level: Int = 7
  tag: String = "def"
}

test "trailing default omitted: R(a = 1) uses b, c defaults" {
  val r = Cfg(a = 1)
  assertEqualInt(r.a, 1, "a")
  assertEqualInt(r.b, 2, "b default")
  assertEqualInt(r.c, 3, "c default")
}

test "non-trailing default omitted, later field supplied (#6146): R(a = 1, c = 9)" {
  val r = Cfg(a = 1, c = 9)
  assertEqualInt(r.a, 1, "a")
  assertEqualInt(r.b, 2, "b keeps its default, not c's value")
  assertEqualInt(r.c, 9, "c takes the supplied value, not its default")
}

test "middle field supplied, trailing default omitted: R(a = 1, b = 5)" {
  val r = Cfg(a = 1, b = 5)
  assertEqualInt(r.a, 1, "a")
  assertEqualInt(r.b, 5, "b supplied")
  assertEqualInt(r.c, 3, "c default")
}

test "all fields explicit: R(a = 1, b = 5, c = 9)" {
  val r = Cfg(a = 1, b = 5, c = 9)
  assertEqualInt(r.a, 1, "a")
  assertEqualInt(r.b, 5, "b")
  assertEqualInt(r.c, 9, "c")
}

test "positional, trailing defaults omitted: R(1)" {
  val r = Cfg(1)
  assertEqualInt(r.a, 1, "a")
  assertEqualInt(r.b, 2, "b default")
  assertEqualInt(r.c, 3, "c default")
}

test "mixed field types, enum + int + string defaults, non-trailing omission" {
  // Omit tint (enum default Green) and level (int default 7); supply the
  // trailing tag — exercises #6146 across differently-typed default slots.
  val m = Mixed(name = "x", tag = "custom")
  assertEqual(m.name, "x", "name")
  val tintOk = match m.tint { case Green -> true; case _ -> false }
  assertTrue(tintOk, "tint keeps its enum default Green")
  assertEqualInt(m.level, 7, "level keeps its int default")
  assertEqual(m.tag, "custom", "tag supplied, not defaulted")
}
