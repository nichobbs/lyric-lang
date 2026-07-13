//! ufcs_self_field_self_test.l — runtime regression test for out-of-body
//! UFCS methods that read a `self` field, on the JVM backend (#5565).
//!
//! `self` always parses to the ESelf AST node, even in a top-level UFCS
//! function `func Outer.m(self: in Outer)` (not a true instance method).  The
//! JVM ESelf lowering only consulted `ctx.selfClass` (set for genuine instance
//! methods), so for a top-level self-param it reported the receiver as erased
//! `Object` and the field read panicked ("member cannot be resolved on an
//! erased receiver").  The fix falls back to `ctx.types["self"]` — where the
//! static-param setup registers the declared receiver type — before degrading
//! to Object, mirroring the MSIL emitter.  `--target dotnet` already worked.
//!
//! Run by native `lyric test` on BOTH targets (JVM is load-bearing here):
//!   lyric test --target dotnet lyric-compiler/lyric/ufcs_self_field_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/ufcs_self_field_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.UfcsSelfFieldSelfTest

import Std.Core
import Std.Testing

record Pt {
  a: Int
  b: String
}

// Out-of-body UFCS method with an explicit `self` receiver reading an Int field
// — the exact shape that panicked JVM codegen.
func Pt.ptArea(self: in Pt): Int {
  self.a * self.a
}

// Reference-typed (String) self field read.
func Pt.label(self: in Pt): String {
  self.b
}

record Line {
  p1: Pt
  p2: Pt
}

// Chained read through a nested self field (self.p2.a - self.p1.a).
func Line.dx(self: in Line): Int {
  self.p2.a - self.p1.a
}

test "out-of-body UFCS method reads self Int field (#5565)" {
  assertEqualInt(Pt(a = 9, b = "z").ptArea(), 81, "Pt(9,z).ptArea() == 81")
}

test "out-of-body UFCS method reads self String field" {
  assertEqual(Pt(a = 1, b = "hello").label(), "hello", "Pt.label reads the String field")
}

test "out-of-body UFCS method chains through a nested self field" {
  assertEqualInt(Line(p1 = Pt(a = 3, b = "x"), p2 = Pt(a = 10, b = "y")).dx(), 7, "Line.dx() == 10 - 3")
}
