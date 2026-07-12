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

// ── #5607: explicit-self (D037) interface methods ─────────────────────────────
// An interface method declared with an explicit `self: in Self` receiver got
// `self` included in the JVM interface method DESCRIPTOR, so every
// `invokeinterface` call site arity-mismatched — VerifyError "Attempt to pop
// empty stack" in the caller.  The canonical no-self spelling above was
// unaffected.  `stripLeadingSelfParam` now applies at interface registration
// (`registerIfaceSig`), abstract-method emission, and `lowerImplMethod`,
// mirroring the MSIL fix's placement discipline (D-progress-657).
pub interface SelfNamer {
  func nameOf(self: in Self): String
  func tagged(self: in Self, tag: String): String
}

pub record SelfNamed {
  label: String
}

impl SelfNamer for SelfNamed {
  func nameOf(self: in SelfNamed): String {
    self.label
  }

  func tagged(self: in SelfNamed, tag: String): String {
    self.label + ":" + tag
  }
}

func nameThrough(n: in SelfNamer): String {
  n.nameOf()
}

test "explicit-self interface dispatch through an interface-typed binding (#5607)" {
  val n: SelfNamer = SelfNamed(label = "named")
  assertEqual(n.nameOf(), "named", "explicit-self nameOf through binding")
}

test "explicit-self interface dispatch with an argument (#5607)" {
  val n: SelfNamer = SelfNamed(label = "x")
  assertEqual(n.tagged("t"), "x:t", "explicit-self descriptor keeps only real params")
  assertEqual(nameThrough(SelfNamed(label = "via")), "via", "explicit-self through param")
}

// The async form of the same shape (the MSIL twin lives in
// async_sm_self_test.l ok 58-61, dotnet-only per #2736).
pub interface SelfFetcher {
  async func fetchSelf(self: in Self, q: in String): String
}

pub record SelfFetch {
}

impl SelfFetcher for SelfFetch {
  async func fetchSelf(self: in SelfFetch, q: in String): String {
    q + "?"
  }
}

test "explicit-self async interface dispatch (#5607)" {
  val c: SelfFetcher = SelfFetch()
  val r = await c.fetchSelf("yo")
  assertEqual(r, "yo?", "explicit-self async dispatch")
}
