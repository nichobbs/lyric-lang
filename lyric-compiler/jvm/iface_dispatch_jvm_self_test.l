//! iface_dispatch_jvm_self_test.l — JVM interface-dispatch regression test
//! (#3687, epic #2663).
//!
//! A record implementing a Lyric `interface` and dispatched through an
//! interface-typed binding or parameter previously failed at class load with
//! "Found interface X, but class was expected": interface members were never
//! registered in the `funcSigs` registry, so the call site fell through to
//! the `()Object`-guess `invokevirtual` — and `invokevirtual` against an
//! interface owner is a class-format violation.  `collectFileSigs` now
//! registers each interface member under `<ifaceClass>#<method>` with
//! `isIface = true`, and the J3 M-3 dispatch path emits `invokeinterface`
//! for those sigs.  This module pins the behaviour at runtime.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.IfaceDispatchSelfTest

import Std.Core
import Std.Testing

pub interface Shape {
  func area(): Int
  func scaled(factor: Int): Int
}

pub record Square {
  side: Int
}

pub record Rect {
  w: Int
  h: Int
}

impl Shape for Square {
  func area(): Int {
    self.side * self.side
  }

  func scaled(factor: Int): Int {
    self.side * self.side * factor
  }
}

impl Shape for Rect {
  func area(): Int {
    self.w * self.h
  }

  func scaled(factor: Int): Int {
    self.w * self.h * factor
  }
}

// Dispatch through an interface-typed parameter — the #3687 repro shape.
func areaThrough(s: in Shape): Int {
  s.area()
}

// Dispatch with an argument, pinning the descriptor/arg-slot path of
// `invokeinterface` (count operand = receiver + args).
func scaledThrough(s: in Shape, factor: Int): Int {
  s.scaled(factor)
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "interface dispatch through an interface-typed parameter" {
  assertEqualInt(areaThrough(Square(side = 3)), 9, "Square through Shape")
  assertEqualInt(areaThrough(Rect(w = 2, h = 5)), 10, "Rect through Shape")
}

test "interface dispatch with an argument" {
  assertEqualInt(scaledThrough(Square(side = 2), 10), 40, "Square scaled through Shape")
  assertEqualInt(scaledThrough(Rect(w = 3, h = 3), 2), 18, "Rect scaled through Shape")
}

test "interface dispatch on a direct record value still works" {
  val sq = Square(side = 4)
  assertEqualInt(sq.area(), 16, "direct record method call unaffected")
}
