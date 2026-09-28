//! conversion_name_resolution_self_test.l — a bare call to a conversion
//! function name resolves like any other name (#7465), generalized to
//! every backend-intercepted stdlib-kernel name (#7508).
//!
//! Both backends used to lower the bare names `longToInt`, `intToLong`,
//! `charToInt` and `intToDouble` to unchecked conversion opcodes before name
//! resolution ran, so a bare `longToInt(x)` never reached the range-checked
//! `Std.Math.longToInt` and silently truncated, and a package's own function
//! with one of those names was never called.  The explicit truncating
//! conversion is the `.toInt()` / `.toLong()` / `.toDouble()` method family.
//!
//! #7508 generalizes the same fix to the REST of the MSIL/JVM/native
//! `lowerBuiltinOrStaticCall{Msil,}`/`lowerCallEx` intercept tables
//! (`newList`, `newMap`, `mapGet`, `newListWithCapacity`, …): those names
//! were still matched by STRING before name resolution, so a package's own
//! function with one of those names was silently uncallable.  The fix
//! (`hasFuncOverrideMsil`/`hasFuncOverrideJvm`/`hasFuncOverrideNative`)
//! resolves a bare/qualified call through the same registry ordinary
//! (non-intercepted) calls use, and only falls back to the fast intrinsic
//! path when that resolution is `Std`-owned (the exact stdlib function the
//! intrinsic implements) or absent.  A handful of OTHER names
//! (`println`, `toString`, `panic`, `assert`, `default`, `expect`,
//! `format1`-`format4`, `hashCode`, `__lyric_protected_wait`/`notify`) are
//! true language built-ins with no ordinary Lyric signature and are now
//! reserved outright — a non-`Std.*` package declaring one is **T0140**
//! (see `typechecker_self_test.l`).
@test_module
package Lyric.ConversionNameResolutionSelfTest

import Std.Core
import Std.Collections
import Std.CollectionsHost
import Std.Math
import Std.Testing

// Declared here so a bare call must reach this body, not a conversion opcode.
func charToInt(c: in Char): Int {
  -7
}

func intToDouble(n: in Int): Double {
  0.25
}

// #7508: package-local declarations of stdlib-kernel-intercepted names.
// Both take a DIFFERENT arity from the real `Std.Collections`/kernel
// functions of the same bare name, so a call here can only reach one body
// or the other — never both by coincidence.
func newList(n: in Int): Int {
  n * 1000
}

func newMap(n: in Int): Int {
  n * 2000
}

func bareLongToIntAboveRange(): Unit {
  val ignored = longToInt(3000000000i64)
}

func bareLongToIntBelowRange(): Unit {
  val ignored = longToInt(-2147483649i64)
}

func qualifiedLongToIntAboveRange(): Unit {
  val ignored = Std.Math.longToInt(3000000000i64)
}

func aliasedLongToIntAboveRange(): Unit {
  val ignored = Math.longToInt(3000000000i64)
}

test "bare longToInt converts an in-range value" {
  assertEqualInt(longToInt(42i64), 42, "longToInt(42)")
  assertEqualInt(longToInt(2147483647i64), 2147483647, "longToInt(Int max)")
  assertEqualInt(longToInt(-2147483648i64), -2147483648, "longToInt(Int min)")
}

test "bare longToInt rejects a value outside Int" {
  assertPanics("bare longToInt(3_000_000_000)", bareLongToIntAboveRange)
  assertPanics("bare longToInt(Int min - 1)", bareLongToIntBelowRange)
}

test "qualified longToInt behaves like the bare call" {
  assertEqualInt(Std.Math.longToInt(2147483647i64), 2147483647, "Std.Math.longToInt(Int max)")
  assertEqualInt(Math.longToInt(-5i64), -5, "Math.longToInt(-5)")
  assertPanics("Std.Math.longToInt(3_000_000_000)", qualifiedLongToIntAboveRange)
  assertPanics("Math.longToInt(3_000_000_000)", aliasedLongToIntAboveRange)
}

test "bare intToLong resolves to Std.Math" {
  val widened: Long = intToLong(2000000000)
  assertTrue(widened + widened == 4000000000i64, "intToLong widens before the addition")
}

test "toInt is the explicit truncating conversion" {
  assertEqualInt(3000000000i64.toInt(), -1294967296, "3_000_000_000.toInt() wraps")
  assertEqualInt(2147483647i64.toInt(), 2147483647, "Int max round-trips")
}

test "a package's own conversion-named function is called" {
  assertEqualInt(charToInt('A'), -7, "local charToInt")
  assertTrue(intToDouble(3) == 0.25, "local intToDouble")
}

// #7508: a package's own `newList`/`newMap` (a different arity from the
// stdlib-kernel functions of the same bare name) must be called, not
// silently captured by the backends' `ArrayList`/`HashMap` intrinsic.
test "a package's own 'newList' is called" {
  assertEqualInt(newList(7), 7000, "local newList(n)")
}

test "a package's own 'newMap' is called" {
  assertEqualInt(newMap(7), 14000, "local newMap(n)")
}

// The REAL stdlib `newListWithCapacity`/`mapGet` (not locally overridden in
// this package) must still resolve to `Std.Collections`, unaffected by the
// local overrides above of the DIFFERENT names `newList`/`newMap`.
test "the real Std.Collections.newListWithCapacity still builds a list" {
  val xs: List[Int] = newListWithCapacity(4)
  xs.add(1)
  xs.add(2)
  assertEqualInt(xs.count, 2, "newListWithCapacity(4) builds a real, usable list")
}

test "the real Std.Collections.mapGet still returns an Option" {
  // `newMap` is declared in `Std.CollectionsHost` (`Std.Collections`
  // re-imports it whole so bare `newMap()` normally reaches it) — this
  // package's own bare `newMap` above shadows that, so the real one is
  // reached qualified instead, exactly as a caller who needs both would
  // have to (docs/01 §9.2/#7495: `Std.CollectionsHost` is reachable
  // qualified here because `Std.Collections`, which this file imports,
  // itself imports it whole).
  val m: Map[String, Int] = Std.CollectionsHost.newMap()
  m.add("a", 1)
  match mapGet(m, "a") {
    case Some(v) -> assertEqualInt(v, 1, "mapGet finds the key")
    case None -> assertTrue(false, "mapGet(m, \"a\") should be Some")
  }
  match mapGet(m, "missing") {
    case Some(_) -> assertTrue(false, "mapGet(m, \"missing\") should be None")
    case None -> ()
  }
}
