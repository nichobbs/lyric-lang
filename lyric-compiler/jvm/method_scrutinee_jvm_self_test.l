//! method_scrutinee_jvm_self_test.l — CI gate for #4933: arithmetic on a
//! generic-payload value bound out of a `match` over a METHOD-CALL scrutinee
//! (`match recv.method(...) { … }`) on the JVM backend.
//!
//! This is the third form of the #4877 erased-generic-payload bug (after the
//! direct `match callee(...)` and `?` forms in #4931, and the variable-bound
//! `let r = callee(...); match r` form in #4944).  An in-body / `impl` method
//! returning a generic instantiation registers under `<receiverClass>#<method>`
//! with its `retGenericArgs`; `scrutineeGenericArgs` resolves the receiver's
//! class (local / param / `self`) to recover them, so the payload unboxes at the
//! bind site instead of string-concatenating (`"22"`) or VerifyError-ing.
//!
//! JVM-ONLY (unlike `erased_generic_arith_jvm_self_test.l`, which runs on both
//! targets): the test needs an in-body record method to define the callee, and
//! in-body methods break MSIL entry-point emission (#4947 — any dotnet program
//! combining `main` with an in-body method fails with "Entry point not found").
//! MSIL reifies generics, so it never had the erased-payload bug this fix
//! addresses; the JVM run alone therefore fully covers the fix.  Once #4947 is
//! fixed this module can move into the dual-target file.
//!
//!   lyric test --target jvm lyric-compiler/jvm/method_scrutinee_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Jvm.MethodScrutineeJvmSelfTest

import Std.Core
import Std.Testing

// A record with in-body methods returning generic instantiations, so a
// method-call scrutinee `match repo.lookup(...) { … }` exercises #4933.
record Repo {
  base: Int
  func lookup(self: in Repo, key: String): Result[Int, String] {
    Ok(value = self.base + key.length)
  }
  func measure(self: in Repo, key: String): Result[Long, String] {
    Ok(value = (self.base + key.length).toLong() * 1000i64)
  }
  func gauge(self: in Repo, key: String): Result[Double, String] {
    Ok(value = (self.base + key.length).toDouble() + 0.5)
  }
  // Exercises a `self.method()` scrutinee: the match receiver is `self`, so
  // `receiverClassOf` resolves the class through `ctx.selfClass` (not `ctx.types`).
  func addLookups(self: in Repo, a: String, b: String): Int {
    val x = match self.lookup(a) { case Ok(v) -> v; case Err(_) -> 0 }
    val y = match self.lookup(b) { case Ok(v) -> v; case Err(_) -> 0 }
    x + y
  }
}

test "method-call Int scrutinee unboxes for arithmetic (#4933)" {
  // Two results added detects boxing: a boxed pair string-concatenates to "22"
  // (and `-` would VerifyError) instead of computing 4.
  val repo = Repo(base = 0)
  val x = match repo.lookup("hi") { case Ok(v) -> v; case Err(_) -> 0 }
  val y = match repo.lookup("yo") { case Ok(v) -> v; case Err(_) -> 0 }
  assertEqualInt(x + y, 4, "method-call: 2 + 2 == 4 (not string-concat 22)")
  assertEqualInt(x - y, 0, "method-call: 2 - 2 == 0 (loads without VerifyError)")
}

test "method-call Int scrutinee with a non-zero base (#4933)" {
  val repo = Repo(base = 10)
  val x = match repo.lookup("hi") { case Ok(v) -> v; case Err(_) -> -1 }
  assertEqualInt(x * 2, 24, "(10 + 2) * 2 == 24 on the unboxed payload")
}

test "method-call Long scrutinee unboxes for arithmetic (#4933)" {
  val repo = Repo(base = 0)
  val a = match repo.measure("abc") { case Ok(v) -> v; case Err(_) -> 0i64 }
  val b = match repo.measure("de") { case Ok(v) -> v; case Err(_) -> 0i64 }
  assertEqualLong(a + b, 5000i64, "3000 + 2000 == 5000 (long add on unboxed payloads)")
}

test "method-call Double scrutinee unboxes for arithmetic (#4933)" {
  val repo = Repo(base = 0)
  val a = match repo.gauge("ab") { case Ok(v) -> v; case Err(_) -> 0.0 }
  val b = match repo.gauge("cde") { case Ok(v) -> v; case Err(_) -> 0.0 }
  // (2 + 0.5) + (3 + 0.5) = 6.0
  assertTrue(a + b == 6.0, "2.5 + 3.5 == 6.0 (double add on unboxed payloads)")
}

test "self.method() scrutinee unboxes for arithmetic (#4933, #4950)" {
  // The receiver is `self`, resolved via ctx.selfClass rather than ctx.types.
  val repo = Repo(base = 0)
  assertEqualInt(repo.addLookups("hi", "yo"), 4, "self.lookup: 2 + 2 == 4")
}
