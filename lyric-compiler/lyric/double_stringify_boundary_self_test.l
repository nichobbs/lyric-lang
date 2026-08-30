//! double_stringify_boundary_self_test.l — dual-target boundary regression for
//! the JVM `Double`-stringification normalizer's fixed/scientific threshold
//! (#5660, docs/44 m-21; review finding #6749 against PR #6631).
//!
//! `emitNormalizeDoubleString` (`lyric-compiler/jvm/codegen/02_exprs.l`)
//! reformats Java's `Double.toString()` output onto .NET's default
//! `Double.ToString()` spelling, including .NET's own fixed-vs-scientific
//! switchover at `-4 <= exp <= 16` (scientific outside that range). Every
//! case previously asserted for that switchover (in
//! `lyric-compiler/jvm/silent_miscompile_guard_jvm_self_test.l`) sat well
//! clear of the boundary itself, and only ran on `--target jvm` — so the
//! "exp <= 16" constant was pinned by a code comment, never verified against
//! real .NET output.
//!
//! This file closes both gaps: every case here sits at or one ULP from the
//! exp=16/exp=17 transition, and the SAME assertions run on BOTH targets
//! (`--target dotnet` produces the real .NET string directly; `--target jvm`
//! exercises the reimplementation), so a real divergence between the two
//! fails the JVM leg without needing to hand-derive expected .NET output.
//! The literal expected strings below were captured from a real `dotnet run`
//! against `Double.ToString(CultureInfo.InvariantCulture)` on .NET 10, not
//! hand-derived.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/double_stringify_boundary_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/double_stringify_boundary_self_test.l
//!
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.DoubleStringifyBoundarySelfTest

import Std.Core
import Std.Testing

test "exp=15, one exponent below the boundary, stays fixed-point" {
  val d: Double = 1e15
  assertEqual(d.toString(), "1000000000000000", "1e15 (exp=15) renders fixed, not scientific")
}

test "exp=15 with multiple significant digits stays fixed-point" {
  val d: Double = 9.99e15
  assertEqual(d.toString(), "9990000000000000", "9.99e15 (exp=15) renders fixed, not scientific")
}

test "the largest Double strictly below 1e16 (exp=15) stays fixed-point" {
  val d: Double = 9999999999999998.0
  assertEqual(d.toString(), "9999999999999998", "largest Double < 1e16 renders fixed")
}

test "exp=16, .NET's own fixed/scientific boundary value, stays fixed-point" {
  val d: Double = 1e16
  assertEqual(d.toString(), "10000000000000000", "1e16 (exp=16) is still fixed under .NET's -4<=exp<=16 range")
}

test "one ULP above 1e16 (exp=16) stays fixed-point" {
  val d: Double = 10000000000000002.0
  assertEqual(d.toString(), "10000000000000002", "one ULP above 1e16 still renders fixed")
}

test "the largest Double strictly below 1e17 (exp=16) stays fixed-point" {
  val d: Double = 99999999999999984.0
  assertEqual(
    d.toString(),
    "99999999999999980",
    "largest Double < 1e17 renders fixed (.NET's shortest round-trip digits)"
  )
}

test "exp=17, .NET's documented scientific threshold, switches to scientific" {
  val d: Double = 1e17
  assertEqual(d.toString(), "1E+17", "1e17 (exp=17) crosses .NET's boundary into scientific notation")
}

test "one ULP above 1e17 (exp=17) stays scientific" {
  val d: Double = 1.0000000000000002e17
  assertEqual(d.toString(), "1.0000000000000002E+17", "one ULP above 1e17 renders scientific with the full mantissa")
}

test "a negative Double at the fixed boundary (exp=16) stays fixed-point" {
  val d: Double = -1e16
  assertEqual(d.toString(), "-10000000000000000", "-1e16 (exp=16) stays fixed, sign preserved")
}

test "a negative Double past the scientific threshold (exp=17) uses scientific" {
  val d: Double = -1e17
  assertEqual(d.toString(), "-1E+17", "-1e17 (exp=17) crosses into scientific, sign preserved")
}
