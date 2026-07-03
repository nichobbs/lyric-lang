//! erased_generic_arith_jvm_self_test.l — CI gate for #4877: arithmetic on a
//! generic-payload value bound out of a `match` compiled to a silent miscompile
//! on the JVM backend.
//!
//! On the JVM, a generic union case payload (`Ok(value: T)`) erases its field to
//! `java/lang/Object`, UNLIKE MSIL which reifies the type-parameter field.  A
//! `match r { case Ok(v) -> v }` therefore bound `v` as a boxed `Object`; a
//! following `v + w` picked the reference-typed `+` (string concatenation) or
//! failed verification instead of integer addition.  The fix recovers the
//! scrutinee's instantiation (`Result[Int, String]` -> `[Int, String]`) from
//! the matched callee's declared return type and unboxes the payload to its
//! concrete primitive at the bind site (`lowerPatternBind` + `bindCaseField`).
//!
//! Run via the native test runner on BOTH targets (MSIL already reified the
//! field, so it was correct there — this file locks in parity):
//!
//!   lyric test --target dotnet lyric-compiler/jvm/erased_generic_arith_jvm_self_test.l
//!   lyric test --target jvm    lyric-compiler/jvm/erased_generic_arith_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Jvm.ErasedGenericArithJvmSelfTest

import Std.Core
import Std.Testing

// A generic union of our own so the payload erasure and the fix are exercised
// independently of the stdlib `Result`/`Option` shapes too.
union Slot[T] {
  case Filled(item: T)
  case Blank
}

func makeIntResult(s: String): Result[Int, String] {
  Ok(value = s.length)
}

func makeLongResult(n: Int): Result[Long, String] {
  Ok(value = n.toLong() * 1000i64)
}

func makeDoubleResult(x: Int): Result[Double, String] {
  Ok(value = x.toDouble() + 0.5)
}

func fillInt(n: Int): Slot[Int] {
  Filled(item = n * 2)
}

func fillChar(c: Char): Slot[Char] {
  Filled(item = c)
}

// A `Byte` payload deliberately above 127, to exercise the signed in-slot
// representation (`byteValue` yields -56 for 200) plus unsigned widening.
func fillByte(b: Byte): Slot[Byte] {
  Filled(item = b)
}

func fillBool(v: Bool): Slot[Bool] {
  Filled(item = v)
}

// Extract-and-add through a match: the headline #4877 shape.
func addTwoIntResults(a: String, b: String): Int {
  val x = match makeIntResult(a) { case Ok(v) -> v; case Err(_) -> 0 }
  val y = match makeIntResult(b) { case Ok(v) -> v; case Err(_) -> 0 }
  x + y
}

// Extract-and-add through the `?` operator (`propagate.l` desugars to a match on
// the same `ECall` scrutinee, so `scrutineeGenericArgs` still recovers the
// instantiation).  This is the issue's primary repro shape.
func addTwoViaPropagate(a: String, b: String): Result[Int, String] {
  val x = makeIntResult(a)?
  val y = makeIntResult(b)?
  Ok(value = x + y)
}

// Subtraction through `?`: the pre-fix JVM backend threw `java.lang.VerifyError`
// at class load here (no string-concat fallback for `-` on two `Object`s).
func subTwoViaPropagate(a: String, b: String): Result[Int, String] {
  val x = makeIntResult(a)?
  val y = makeIntResult(b)?
  Ok(value = x - y)
}

// Variable-bound scrutinee (#4938): the result is bound to a `val` first, then
// matched.  `scrutineeGenericArgs` recovers the instantiation from the binding's
// recorded `ctx.varGenericArgs` rather than from the `match` scrutinee directly.
func addViaValBinding(a: String, b: String): Int {
  val ra = makeIntResult(a)
  val rb = makeIntResult(b)
  val x = match ra { case Ok(v) -> v; case Err(_) -> 0 }
  val y = match rb { case Ok(v) -> v; case Err(_) -> 0 }
  x + y
}

// Variable-bound Long scrutinee through a `var`, then matched.
func addViaVarBindingLong(a: Int, b: Int): Long {
  var ra = makeLongResult(a)
  var rb = makeLongResult(b)
  val x = match ra { case Ok(v) -> v; case Err(_) -> 0i64 }
  val y = match rb { case Ok(v) -> v; case Err(_) -> 0i64 }
  x + y
}

// Captured `val`-bound generic result matched INSIDE a lambda (#4945).  The
// closure body runs in its own codegen ctx; before the fix that ctx started
// with an empty `varGenericArgs`, so `scrutineeGenericArgs` could not recover
// `r`'s `Result[Int, String]` instantiation and the `Ok(v)` payload stayed
// boxed — `x + delta` then string-concatenated / VerifyError'd across the
// closure ABI, the pre-#4877 bug resurfacing one scope deep.  The fix seeds the
// closure ctx's `varGenericArgs` from the enclosing scope (excluding shadowing
// lambda params).
func addCapturedIntResult(a: String, d: Int): Int {
  val r = makeIntResult(a)
  val f: (Int) -> Int = { delta: Int -> val x = match r { case Ok(v) -> v; case Err(_) -> 0 }; x + delta }
  f(d)
}

// Same, with a captured Long result and 64-bit arithmetic inside the lambda.
func addCapturedLongResult(n: Int): Long {
  val r = makeLongResult(n)
  val f: (Long) -> Long = { delta: Long -> val x = match r { case Ok(v) -> v; case Err(_) -> 0i64 }; x + delta }
  f(1i64)
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Int payload — arithmetic on the bound value (the #4877 repro).
// ─────────────────────────────────────────────────────────────────────────────
test "Int payload bound from match adds as an integer, not string-concat (#4877)" {
  // "hi".length + "yo".length = 2 + 2 = 4.  The pre-fix JVM backend produced
  // "22" (string concat of two boxed Integers) or a VerifyError.
  assertEqualInt(addTwoIntResults("hi", "yo"), 4, "2 + 2 == 4 (integer add)")
  // Asymmetric lengths so a stray concat would give a different-but-plausible
  // value than the correct sum.
  assertEqualInt(addTwoIntResults("abc", "de"), 5, "3 + 2 == 5")
}

test "Int payload participates in multiplication and comparison" {
  val v = match makeIntResult("hello") { case Ok(n) -> n; case Err(_) -> -1 }
  assertEqualInt(v * v, 25, "5 * 5 == 25 on the unboxed payload")
  assertTrue(v > 4, "unboxed payload compares as an int")
  assertTrue(v < 6, "unboxed payload compares as an int (upper)")
}

test "? operator + arithmetic adds as an integer (issue primary repro, #4877)" {
  val added = match addTwoViaPropagate("hi", "yo") { case Ok(v) -> v; case Err(_) -> -1 }
  assertEqualInt(added, 4, "getInt(hi)? + getInt(yo)? == 2 + 2 == 4")
}

test "? operator + subtraction loads without VerifyError (#4877)" {
  // `-` had no string-concat fallback, so the pre-fix backend failed class
  // verification rather than miscompiling.  A correct value here proves the
  // class both loads and computes.
  val subbed = match subTwoViaPropagate("abc", "de") { case Ok(v) -> v; case Err(_) -> -1 }
  assertEqualInt(subbed, 1, "getInt(abc)? - getInt(de)? == 3 - 2 == 1")
}

test "variable-bound Int scrutinee unboxes for arithmetic (#4938)" {
  // `val r = f(); match r { … }` — the bind site records r's generic args so the
  // match recovers them even though the scrutinee is a plain variable ref.
  assertEqualInt(addViaValBinding("hi", "yo"), 4, "val-bound: 2 + 2 == 4")
  assertEqualInt(addViaValBinding("abcd", "e"), 5, "val-bound: 4 + 1 == 5")
}

test "variable-bound Long scrutinee via var unboxes for arithmetic (#4938)" {
  assertEqualLong(addViaVarBindingLong(3, 4), 7000i64, "var-bound Long: 3000 + 4000 == 7000")
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Long payload — 64-bit arithmetic on the bound value.
// ─────────────────────────────────────────────────────────────────────────────
test "Long payload bound from match adds as a long (#4877)" {
  val a = match makeLongResult(3) { case Ok(v) -> v; case Err(_) -> 0i64 }
  val b = match makeLongResult(4) { case Ok(v) -> v; case Err(_) -> 0i64 }
  assertEqualLong(a + b, 7000i64, "3000 + 4000 == 7000 (long add)")
  assertEqualLong(a * 2i64, 6000i64, "3000 * 2 == 6000 (long mul)")
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Double payload — floating arithmetic on the bound value.
// ─────────────────────────────────────────────────────────────────────────────
test "Double payload bound from match adds as a double (#4877)" {
  val a = match makeDoubleResult(2) { case Ok(v) -> v; case Err(_) -> 0.0 }
  val b = match makeDoubleResult(3) { case Ok(v) -> v; case Err(_) -> 0.0 }
  // 2.5 + 3.5 = 6.0
  assertTrue(a + b == 6.0, "2.5 + 3.5 == 6.0 (double add)")
  assertTrue(a * 2.0 == 5.0, "2.5 * 2.0 == 5.0 (double mul)")
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. User-defined generic union payload — same erasure path as Result/Option.
// ─────────────────────────────────────────────────────────────────────────────
test "user-defined generic union payload unboxes for arithmetic (#4877)" {
  val v = match fillInt(21) { case Filled(n) -> n; case Blank -> 0 }
  assertEqualInt(v + 0, 42, "21 * 2 == 42, then +0 as an int")
  assertEqualInt(v - 2, 40, "unboxed payload subtracts as an int")
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Nested binding `n@` and guard over an unboxed payload.
// ─────────────────────────────────────────────────────────────────────────────
test "guard and binding over an unboxed Int payload" {
  val r = makeIntResult("test")   // length 4
  val picked = match r { case Ok(n) if n > 3 -> n + 100; case Ok(n) -> n; case Err(_) -> -1 }
  assertEqualInt(picked, 104, "4 > 3 guard fires, 4 + 100 == 104")
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Char / Byte / Bool payloads — the remaining `emitUnboxObjectTo` arms
//    (#4942 Char, #4941 Byte, #4932 Bool).
// ─────────────────────────────────────────────────────────────────────────────
test "Char payload unboxes to a real char (#4942)" {
  val c = match fillChar('A') { case Filled(ch) -> ch; case Blank -> ' ' }
  // A boxed Character would not compare/convert as a primitive char.
  assertEqualInt(c.toInt(), 65, "'A' unboxes to char 65")
  assertTrue(c == 'A', "unboxed char compares equal to the literal")
}

test "Byte payload above 127 unboxes with the signed representation (#4941)" {
  // 200 is held as the signed byte -56; `.toInt()` masks to the unsigned 200
  // (D-progress-566).  A boxed Object payload here would mis-dispatch `.toInt()`.
  val b = match fillByte(200.toByte()) { case Filled(x) -> x; case Blank -> 0.toByte() }
  assertEqualInt(b.toInt(), 200, "unboxed Byte 200 -> Int 200 (not -56)")
  assertEqualLong(b.toLong(), 200i64, "unboxed Byte 200 -> Long 200")
}

test "Bool payload unboxes to a real boolean (#4932)" {
  val t = match fillBool(true) { case Filled(v) -> v; case Blank -> false }
  val f = match fillBool(false) { case Filled(v) -> v; case Blank -> true }
  assertTrue(t, "unboxed true payload is true")
  assertFalse(f, "unboxed false payload is false")
  assertTrue(t and not f, "unboxed booleans combine in a boolean expression")
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Captured generic scrutinee matched INSIDE a lambda (#4945) — the closure
//    body inherits the enclosing scope's recorded instantiation.
// ─────────────────────────────────────────────────────────────────────────────
test "captured val-bound Int result unboxes inside a lambda (#4945)" {
  // Ok(2) captured by value, matched in the lambda, then + delta as an int.
  assertEqualInt(addCapturedIntResult("hi", 10), 12, "captured Ok(2) + 10 == 12 (int add, not concat)")
  assertEqualInt(addCapturedIntResult("abcd", 1), 5, "captured Ok(4) + 1 == 5")
}

test "captured val-bound Long result unboxes inside a lambda (#4945)" {
  assertEqualLong(addCapturedLongResult(3), 3001i64, "captured Ok(3000) + 1 == 3001 (long add)")
}
