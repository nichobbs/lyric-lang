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
    Err(error = "unknown language: " + lang)
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

// Direct construction: the concrete record is passed straight into Ok(...)
// with no intermediate `Greeter`-typed variable, so codegen only sees the
// concrete EnglishGreeter/FrenchGreeter type at the call site. This is the
// path that actually exercises the buildGenericCaseCtorTok context-priority
// fix (the intermediate-variable pattern above widens to `Greeter` before
// Ok(...) is built and so does not by itself require the fix).
func makeGreeterDirect(lang: in String, name: in String): Result[Greeter, String] {
  if lang == "en" {
    Ok(value = EnglishGreeter(name = name))
  } else if lang == "fr" {
    Ok(value = FrenchGreeter(name = name))
  } else {
    Err(error = "unknown language: " + lang)
  }
}

test "#3502: isOk returns true for Ok(directly-constructed interface value)" {
  val r = makeGreeterDirect("en", "World")
  assertTrue(isOk(r), "Ok(EnglishGreeter(...)) should be Ok")
}

test "#3502: isErr returns false for Ok(directly-constructed interface value)" {
  val r = makeGreeterDirect("fr", "Monde")
  assertFalse(isErr(r), "Ok(FrenchGreeter(...)) should not be Err")
}

test "#3502: isErr returns true for Err from makeGreeterDirect" {
  val r = makeGreeterDirect("zz", "World")
  assertTrue(isErr(r), "Err(unknown language) should be Err")
}

// #7752: `makeGreeterDirect`'s branches build `Ok` over two DIFFERENT
// concrete records; the type checker checks each branch against the declared
// `Result[Greeter, String]` (it used to join them bottom-up and reject the
// function with T0067), and each backend must build the value at that
// declared instantiation.  Assert the payloads themselves, not just the case:
// the interface dispatch reaches the right record, and the `Err` payload
// survives (the JVM backend used to store `null` for a misnamed `Err` field).
func describe(r: in Result[Greeter, String]): String {
  match r {
    case Ok(g) -> g.greet()
    case Err(e) -> "error: " + e
  }
}

test "#7752: Ok(EnglishGreeter) branch dispatches through Greeter" {
  assertEqual(describe(makeGreeterDirect("en", "World")), "Hello, World", "English branch")
}

test "#7752: Ok(FrenchGreeter) branch dispatches through Greeter" {
  assertEqual(describe(makeGreeterDirect("fr", "Monde")), "Bonjour, Monde", "French branch")
}

test "#7752: Err branch keeps its payload" {
  assertEqual(describe(makeGreeterDirect("zz", "World")), "error: unknown language: zz", "Err branch")
}

// #7752: the same shape as a `match`, and with the interface itself (not a
// `Result` over it) as the expected type.
func makeGreeterMatch(n: in Int, name: in String): Result[Greeter, String] {
  match n {
    case 0 -> Ok(value = EnglishGreeter(name = name))
    case 1 -> Ok(value = FrenchGreeter(name = name))
    case _ -> Err(error = "no greeter " + toString(n))
  }
}

func pickGreeter(lang: in String, name: in String): Greeter {
  if lang == "en" {
    EnglishGreeter(name = name)
  } else {
    FrenchGreeter(name = name)
  }
}

test "#7752: match arms over different records against Result[Greeter, String]" {
  assertEqual(describe(makeGreeterMatch(0, "A")), "Hello, A", "match arm 0")
  assertEqual(describe(makeGreeterMatch(1, "B")), "Bonjour, B", "match arm 1")
  assertEqual(describe(makeGreeterMatch(2, "C")), "error: no greeter 2", "match arm _")
}

test "#7752: if over different records against Greeter" {
  assertEqual(pickGreeter("en", "E").greet(), "Hello, E", "if then-branch")
  assertEqual(pickGreeter("fr", "F").greet(), "Bonjour, F", "if else-branch")
}

test "#7752: annotated binding and call argument positions" {
  val lang = "fr"
  val r: Result[Greeter, String] = if lang == "en" {
    Ok(value = EnglishGreeter(name = "V"))
  } else {
    Ok(value = FrenchGreeter(name = "V"))
  }
  assertEqual(describe(r), "Bonjour, V", "annotated val")
  val arg = describe(
    if lang == "en" { Ok(value = EnglishGreeter(name = "A")) } else { Ok(value = FrenchGreeter(name = "A")) }
  )
  assertEqual(arg, "Bonjour, A", "call argument")
  val direct: Option[Greeter] = Some(value = EnglishGreeter(name = "O"))
  val viaOpt = match direct { case Some(g) -> g.greet(); case None -> "none" }
  assertEqual(viaOpt, "Hello, O", "annotated Option[Greeter] binding")
}
