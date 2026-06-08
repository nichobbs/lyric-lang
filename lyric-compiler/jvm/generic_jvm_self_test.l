//! generic_jvm_self_test.l — executable regression test for J4 M-1: correct
//! erased-generics codegen on the self-hosted JVM backend (docs/44 §5 J4,
//! epic #2663, #2667, #1707, #2574).
//!
//! Generic `Result[T, E]` / `Option[T]` and user generic records/unions are
//! erased to `java/lang/Object` on the JVM (no reified generics — docs/44 M-1 /
//! Q-J001).  Before this fix the erased model was *incorrect*: constructing
//! `Ok(5)` did not box its `int` payload into the `Object` field, and a
//! `match`-extraction (`case Ok(v) -> v`) read the `Object` field and used it
//! at a typed op without a `checkcast` + unbox — both VerifyError'd at class
//! load (`Bad type on operand stack` / `Operand stack underflow`).  This module
//! asserts the runtime values of construction + match-extraction (Int / String
//! payloads), `Option` round-trip including `None`, user generic record/union
//! payloads, and the `?`-propagation chain (short-circuit on `Err` + unwrap on
//! `Ok`) all run correctly under `java`.
//!
//! Run via the native `lyric test --target jvm` (issue tracking per docs/44):
//!
//!   lyric test --target jvm lyric-compiler/jvm/generic_jvm_self_test.l
//!
//! `lyric test --target jvm` synthesises a runnable program from the `test`
//! blocks and compiles it IN-PROCESS through the self-hosted `Jvm.Bridge`
//! (`compileToJarBundled` bundles the user package plus its transitive
//! stdlib-import closure into one runnable JAR), then runs it under `java` and
//! asserts every embedded assertion held.  Imports only `Std.*` (Std.Core gives
//! `Option` / `Result`), so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GenericJvmSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// User generic record + union (exercise the erased-payload field path for
// user-defined generics, not just the stdlib `Option` / `Result`).
// ─────────────────────────────────────────────────────────────────────────────
record Box[T] {
  value: T
}

union Tagged[T] {
  case Payload(v: T)
  case Empty(reason: String)
}

// ─────────────────────────────────────────────────────────────────────────────
// `?`-propagation: each `?` early-returns on `Err` and unwraps the `Ok`
// payload.  The chain returns `Result[Int, String]`, exercising the J2-parked
// JVM runtime case (construct + match-extract + early-return all on erased
// generics).
// ─────────────────────────────────────────────────────────────────────────────
func divide(a: in Int, b: in Int): Result[Int, String] {
  if b == 0 {
    return Err("div by zero")
  }
  Ok(a / b)
}

func chain(a: in Int, b: in Int, c: in Int): Result[Int, String] {
  val x = divide(a, b)?
  val y = divide(x, c)?
  Ok(y + 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// Result construct + match-extract.
// ─────────────────────────────────────────────────────────────────────────────
test "Result Ok extracts Int payload" {
  val r: Result[Int, String] = Ok(5)
  val v = match r { case Ok(x) -> x; case Err(_) -> -1 }
  assertEqualInt(v, 5, "Ok(5) -> 5")
}

test "Result Err extracts String payload" {
  val r: Result[Int, String] = Err("boom")
  val s = match r { case Ok(_) -> "no"; case Err(m) -> m }
  assertEqual(s, "boom", "Err(boom) -> boom")
}

test "Result Ok payload usable in arithmetic" {
  val r: Result[Int, String] = Ok(20)
  val v = match r { case Ok(x) -> x + 1; case Err(_) -> -1 }
  assertEqualInt(v, 21, "Ok(20) -> +1 -> 21")
}

// ─────────────────────────────────────────────────────────────────────────────
// Option construct + match-extract, including None round-trip.
// ─────────────────────────────────────────────────────────────────────────────
test "Option Some extracts payload" {
  val o: Option[Int] = Some(42)
  val v = match o { case Some(x) -> x; case None -> -1 }
  assertEqualInt(v, 42, "Some(42) -> 42")
}

test "Option None round-trips" {
  val o: Option[Int] = None
  val v = match o { case Some(x) -> x; case None -> 99 }
  assertEqualInt(v, 99, "None -> default 99")
}

test "Option Some with String payload" {
  val o: Option[String] = Some("hi")
  val s = match o { case Some(x) -> x; case None -> "none" }
  assertEqual(s, "hi", "Some(hi) -> hi")
}

// ─────────────────────────────────────────────────────────────────────────────
// User generic record + union.
// ─────────────────────────────────────────────────────────────────────────────
test "Generic record Box[Int] field read" {
  val b = Box(value = 7)
  assertEqualInt(b.value, 7, "Box(7).value -> 7")
}

test "Generic record Box[String] field read" {
  val b = Box(value = "lyric")
  assertEqual(b.value, "lyric", "Box(lyric).value -> lyric")
}

test "Generic union Tagged extracts payload" {
  val t: Tagged[Int] = Payload(v = 13)
  val v = match t { case Payload(x) -> x; case Empty(_) -> -1 }
  assertEqualInt(v, 13, "Payload(13) -> 13")
}

test "Generic union Tagged Empty branch" {
  val t: Tagged[Int] = Empty(reason = "missing")
  val s = match t { case Payload(_) -> "has"; case Empty(r) -> r }
  assertEqual(s, "missing", "Empty(missing) -> missing")
}

// ─────────────────────────────────────────────────────────────────────────────
// `?`-propagation runtime (the J2-parked JVM case).
// ─────────────────────────────────────────────────────────────────────────────
test "?-propagation unwraps on the Ok path" {
  val r = chain(100, 5, 2)
  val v = match r { case Ok(x) -> x; case Err(_) -> -1 }
  assertEqualInt(v, 11, "chain(100,5,2) -> Ok(11)")
}

test "?-propagation short-circuits on Err" {
  val r = chain(100, 0, 2)
  val isErr = match r { case Ok(_) -> false; case Err(_) -> true }
  assertTrue(isErr, "chain(100,0,2) -> Err")
}

test "?-propagation Err carries the message" {
  val r = chain(100, 0, 2)
  val msg = match r { case Ok(_) -> "ok"; case Err(m) -> m }
  assertEqual(msg, "div by zero", "chain Err message")
}
