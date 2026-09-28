//! int_to_nat_self_test.l — executable regression test for the `.toNat()`
//! checked conversion (#2050 gotcha, cloud-agents docs/lyric/gotchas.md:
//! "Int.toNat() does not resolve at runtime").
//!
//! Before this fix, `.toNat()` compiled cleanly on every target (the type
//! checker's `numericConvTarget` had no `toNat` entry, so the call fell
//! through to lenient/deferred dispatch instead of a type error) but threw
//! "unsupported method 'toNat' on the receiver type" the moment it actually
//! ran, on both backends — the reverse direction, `Nat.toInt()`, worked by
//! accident (`Nat` and `Long` share the same MSIL/JVM erasure).
//!
//! **`--target dotnet` ONLY.** This PR implements `.toNat()` in
//! `Msil.Codegen` alone, matching the scope of the originating gotcha (this
//! project's own target). `.toNat()` on `--target jvm` fails cleanly at
//! BUILD time instead (`error[J008]: method 'toNat' cannot be called on a
//! primitive-typed receiver` — `Jvm.Codegen`'s numeric-conversion dispatch
//! has no `toNat` arm either, and unlike the MSIL backend's pre-fix
//! lenient/deferred dispatch, JVM codegen rejects the call outright rather
//! than deferring to a runtime throw) — a still-open, tracked gap, NOT
//! silently skipped: see docs/01-language-reference.md §4.1 and
//! `docs/59-compiler-stdlib-deep-review.md`'s FFI/parity ethic. Run only via:
//!
//!   lyric test lyric-compiler/lyric/int_to_nat_self_test.l
//!
//! (no `--target jvm` variant — deliberately, unlike `conv_methods_self_test.l`'s
//! sibling cases, which this file does not touch).
@test_module
package Lyric.IntToNatSelfTest

import Std.Core
import Std.Testing

test "toNat accepts every non-negative source value" {
  val i: Int = 5
  assertEqualInt(i.toNat().toInt(), 5, "5.toNat()")
  val zero: Int = 0
  assertEqualInt(zero.toNat().toInt(), 0, "0.toNat() is valid (non-negative boundary)")
  val b: Byte = 200.toByte()
  assertEqualInt(b.toNat().toInt(), 200, "Byte(200).toNat()")
  val c: Char = 65.toChar()
  assertEqualInt(c.toNat().toInt(), 65, "Char(65).toNat()")
  val l: Long = 123456789i64
  assertEqualInt(l.toNat().toInt(), 123456789, "Long 123456789.toNat()")
  val d: Double = 3.7
  assertEqualInt(d.toNat().toInt(), 3, "3.7.toNat() truncates toward zero")
  val negZero: Double = 0.0 - 0.5
  assertEqualInt(negZero.toNat().toInt(), 0, "-0.5.toNat() truncates to 0, not rejected")
}

test "toNat rejects negative source values" {
  val negInt: Int = 0 - 1
  assertPanicsWith("(-1).toNat()", "non-negative", { -> val _ = negInt.toNat() })
  val negLong: Long = 0i64 - 5i64
  assertPanicsWith("Long -5.toNat()", "non-negative", { -> val _ = negLong.toNat() })
  val negDouble: Double = 0.0 - 1.5
  assertPanicsWith("(-1.5).toNat()", "non-negative", { -> val _ = negDouble.toNat() })
  val nan: Double = 0.0 / 0.0
  assertPanics("NaN.toNat()", { -> val _ = nan.toNat() })
}
