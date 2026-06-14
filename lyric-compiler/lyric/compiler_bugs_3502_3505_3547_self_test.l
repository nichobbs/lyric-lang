//! compiler_bugs_3502_3505_3547_self_test.l — regression tests for three
//! compiler bugs fixed together.
//!
//! Bug #3547 — `inout`/`out` argument as field access panics in MSIL codegen.
//!   `emitByrefArgMsil` only handled `EPath` (simple variable); passing a
//!   field expression (`c.count`) panicked "out/inout argument must be an
//!   assignable variable".  Fixed by adding the `EMember` case: emit `ldarg.0`
//!   for the receiver, then `ldflda` for the field.
//!
//! Bug #3505 — Protected type: no-arg constructor + unit-returning entry method
//!   with invariant clauses emits invalid IL.
//!   Two sub-bugs:
//!   (a) `CircuitBreakerState()` (0 args) — `addPackageTokens` for `IProtected`
//!       didn't register `fieldDeclaredNames` / `ctorDefaultExprs`, so
//!       `fillCtorDefaultArgs` couldn't inject field defaults.
//!   (b) Contract elaborator treated explicitly-typed `: Unit` returns as
//!       non-void (`isVoid = false`), binding the trailing void expression to a
//!       `let` variable → `stloc` on empty stack → `InvalidProgramException`.
//!       Fixed by `isVoidReturnOpt` checking both `ret = None` and `ret =
//!       Some(TypeExpr{TUnit})` / `Some(TypeExpr{TRef("Unit")})`.
//!
//! Bug #3502 — `isOk`/`isErr` on `Result` over an interface type throws "match
//!   not exhaustive" at runtime.
//!   When `Ok(value = concreteImpl)` was constructed for a function returning
//!   `Result[SomeInterface, E]`, the codegen inferred the generic type arg from
//!   the concrete argument type (`ConcreteImpl`) rather than the declared return
//!   type (`SomeInterface`).  CLR generics are invariant, so `isinst
//!   Ok<SomeInterface, E>` on an `Ok<ConcreteImpl, E>` instance returned null →
//!   "match not exhaustive".  Fixed in `buildGenericCaseCtorTok` by preferring
//!   the context type arg over the inferred concrete type when the context
//!   provides a non-Object binding.
//!
//! All tests compile in-process via the self-hosted MSIL bridge; no
//! `LYRIC_LOAD_COMPILER=1` is needed because this module imports only `Std.*`.
//!
//! Run:
//!   lyric test lyric-compiler/lyric/compiler_bugs_3502_3505_3547_self_test.l
@test_module
package Lyric.CompilerBugs350235053547SelfTest

import Std.Core
import Std.Testing

// ─── Bug #3547 — inout/out argument as field access ──────────────────────────
record Counter {
  count: Int
}

func addTo(x: inout Int, delta: in Int): Unit {
  x = x + delta
}

test "#3547: inout field arg: addTo increments counter.count" {
  val c = Counter(count = 0)
  addTo(c.count, 3)
  assertEqualInt(c.count, 3, "after addTo(c.count, 3), c.count should be 3")
}

test "#3547: inout field arg: chained increments accumulate" {
  val c = Counter(count = 10)
  addTo(c.count, 5)
  addTo(c.count, 7)
  assertEqualInt(c.count, 22, "10+5+7 = 22")
}

// ─── Bug #3505 — protected type: no-arg constructor + unit-returning entry ────
@runtime_checked
protected type Circuit {
  var failures: Int = 0
  var open: Bool = false
  invariant: failures >= 0
  entry reset(): Unit {
    failures = 0
    open = false
  }
  entry recordFailure(threshold: in Int): Unit
    requires: threshold > 0
  {
    failures = failures + 1
    if failures >= threshold {
      open = true
    }
  }
  entry recordSuccess(): Unit {
    failures = 0
    open = false
  }
  func isOpen(): Bool {
    return open
  }
  func failureCount(): Int {
    return failures
  }
}

func makeCircuit(): Circuit {
  return Circuit()
}

test "#3505a: no-arg protected type constructor works" {
  val cb = makeCircuit()
  assertFalse(cb.isOpen(), "fresh circuit must be closed")
  assertEqualInt(cb.failureCount(), 0, "fresh circuit has 0 failures")
}

test "#3505b: unit-returning entry with invariant: recordFailure increments" {
  val cb = makeCircuit()
  cb.recordFailure(3)
  cb.recordFailure(3)
  assertEqualInt(cb.failureCount(), 2, "2 failures recorded")
  assertFalse(cb.isOpen(), "below threshold of 3: circuit closed")
}

test "#3505c: reaching threshold opens circuit" {
  val cb = makeCircuit()
  cb.recordFailure(2)
  cb.recordFailure(2)
  assertTrue(cb.isOpen(), "2 failures at threshold of 2: circuit opens")
}

test "#3505d: recordSuccess resets circuit" {
  val cb = makeCircuit()
  cb.recordFailure(1)
  assertTrue(cb.isOpen(), "1 failure at threshold 1: open")
  cb.recordSuccess()
  assertFalse(cb.isOpen(), "after success: closed")
  assertEqualInt(cb.failureCount(), 0, "after success: 0 failures")
}

test "#3505e: reset clears open circuit" {
  val cb = makeCircuit()
  cb.recordFailure(1)
  cb.reset()
  assertFalse(cb.isOpen(), "after reset: closed")
  assertEqualInt(cb.failureCount(), 0, "after reset: 0 failures")
}

// ─── Bug #3502 — isOk/isErr on Result over interface type ────────────────────
interface Greeter {
  func greet(): String
}

record EnglishGreeter {
  name: String
}

record FrenchGreeter {
  name: String
}

impl Greeter for EnglishGreeter {
  func greet(): String {
    return "Hello, " + name
  }
}

impl Greeter for FrenchGreeter {
  func greet(): String {
    return "Bonjour, " + name
  }
}

func makeGreeter(lang: in String, name: in String): Result[Greeter, String] {
  if lang == "en" {
    val g: Greeter = EnglishGreeter(name = name)
    Ok(value = g)
  } else if lang == "fr" {
    val g: Greeter = FrenchGreeter(name = name)
    Ok(value = g)
  } else {
    Err(err = "unknown language: " + lang)
  }
}

test "#3502: isOk returns true for Ok(interface value)" {
  val r = makeGreeter("en", "World")
  assertTrue(isOk(r), "Ok(EnglishGreeter) should be Ok")
}

test "#3502: isOk returns false for Err" {
  val r = makeGreeter("zz", "World")
  assertFalse(isOk(r), "Err(unknown language) should not be Ok")
}

test "#3502: isErr returns true for Err" {
  val r = makeGreeter("zz", "World")
  assertTrue(isErr(r), "Err(unknown language) should be Err")
}

test "#3502: isErr returns false for Ok(interface value)" {
  val r = makeGreeter("fr", "Monde")
  assertFalse(isErr(r), "Ok(FrenchGreeter) should not be Err")
}
