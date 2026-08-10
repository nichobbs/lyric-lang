//! impl_method_self_test.l — #1784: interface/impl methods with value-type
//! parameters, and early `return` / `?` in their bodies.
//!
//! The user-method / interface dispatch in codegen boxed every argument, but
//! the impl/interface method signature declares each parameter's concrete type
//! (`typeExprToMsil(Bool)` → `MBool`, `Int` → `MInt`).  Passing a boxed `object`
//! where the signature expected `bool`/`int32` was invalid IL
//! (`InvalidProgramException`) — so any interface/impl method with a value-type
//! parameter faulted when dispatched virtually.  The fix boxes an argument only
//! when the parameter is a reference/object type.  (The early-`return` / `?`
//! cases here were originally mis-attributed to the body shape; they were the
//! `Bool` parameter all along.)
//!
//! Run in CI via native `lyric test --target dotnet`.  Imports only `Std.*`.
//! MSIL target only (epic #1470 defers JVM).
@test_module
package Lyric.ImplMethodSelfTest

import Std.Core
import Std.Testing

func okIf(cond: in Bool, v: in Int, label: in String): Result[Int, String] {
  if cond {
    Ok(v)
  } else {
    Err(label)
  }
}

func rl(r: in Result[Int, String]): String {
  match r {
    case Ok(_) -> "ok"
    case Err(e) -> e
  }
}

func rv(r: in Result[Int, String]): Int {
  match r {
    case Ok(v) -> v
    case Err(_) -> -1
  }
}

// ── Value-type parameters on an interface method ──────────────────────────────
interface Calc {
  func run(n: in Int, ok: in Bool): Result[Int, String]
}

record CalcImpl {
}

impl Calc for CalcImpl {
  func run(n: in Int, ok: in Bool): Result[Int, String] {
    // early `return` on the failure path, value tail on success
    if not ok {
      return Err("disabled")
    }
    Ok(n * 10)
  }
}

test "interface method with Int + Bool params (early return)" {
  val c: Calc = CalcImpl()
  assertEqualInt(rv(c.run(4, true)), 40, "4*10 via value-type params")
  assertEqual(rl(c.run(4, false)), "disabled", "early-return path")
}

// ── `?` inside an impl method (was blocked by the same value-type-param bug) ───
record Chain {
}

impl Calc for Chain {
  func run(n: in Int, ok: in Bool): Result[Int, String] {
    val v = okIf(ok, n, "no")?
    Ok(v + 1)
  }
}

test "`?` propagation inside an impl method" {
  val c: Calc = Chain()
  assertEqualInt(rv(c.run(5, true)), 6, "5 + 1 via ?")
  assertEqual(rl(c.run(5, false)), "no", "? early-returns Err")
}

// ── Other value types as parameters ───────────────────────────────────────────
interface Pred {
  func above(d: in Double): Bool
  func pick(c: in Char): Int
}

record PredImpl {
}

impl Pred for PredImpl {
  func above(d: in Double): Bool {
    d > 1.0
  }
  func pick(c: in Char): Int {
    if c == 'a' {
      1
    } else {
      0
    }
  }
}

test "Double and Char value-type params" {
  val p: Pred = PredImpl()
  assertTrue(p.above(1.5), "1.5 > 1.0")
  assertTrue(not p.above(0.5), "0.5 not > 1.0")
  assertEqualInt(p.pick('a'), 1, "pick 'a' -> 1")
  assertEqualInt(p.pick('z'), 0, "pick 'z' -> 0")
}

// ── Reference-type params still work (no regression) ──────────────────────────
interface Greeter {
  func greet(name: in String): String
}

record GreeterImpl {
}

impl Greeter for GreeterImpl {
  func greet(name: in String): String {
    "hi " + name
  }
}

test "reference-type param (no regression)" {
  val g: Greeter = GreeterImpl()
  assertEqual(g.greet("bob"), "hi bob", "string param")
}

// ── Mixed value + reference params ────────────────────────────────────────────
interface Fmt {
  func line(label: in String, n: in Int, on: in Bool): String
}

record FmtImpl {
}

impl Fmt for FmtImpl {
  func line(label: in String, n: in Int, on: in Bool): String {
    if on {
      label + "=" + toString(n)
    } else {
      label + "=off"
    }
  }
}

test "mixed reference + value-type params" {
  val f: Fmt = FmtImpl()
  assertEqual(f.line("x", 7, true), "x=7", "on")
  assertEqual(f.line("x", 7, false), "x=off", "off")
}

// ── Lambda literal inside an impl method body (#6119) ─────────────────────────
// `liftLambdasMsil` (the pre-pass that extracts `ELambda` nodes into synthetic
// top-level functions before codegen) walked IFunc/IVal/IConst/IRecord items
// but had no IImpl case, so a lambda inside an impl method body was never
// lifted and codegen panicked with "lambda token missing ... liftLambdasMsil
// pre-pass was not run".
interface Adder {
  func addOne(): Int
}

record AdderImpl {
  x: Int
}

func applyFn(g: () -> Int): Int {
  g()
}

impl Adder for AdderImpl {
  func addOne(): Int {
    applyFn({ -> self.x + 1 })
  }
}

test "lambda literal inside impl method body (#6119)" {
  val r: Adder = AdderImpl(x = 10)
  assertEqualInt(r.addOne(), 11, "lambda captures self field from within impl method")
}

// ── Lambda literal inside a protected-type member body (#6119 follow-up) ──────
// `liftLambdasMsil` also had no `IProtected` case, so a lambda inside a
// `protected type` `func`/`entry` body hit the same "lambda token missing"
// panic. A bare field reference inside a protected member body is
// `EPath([name])` at parse time; `lowerProtectedMsil` rewrites it to
// `EMember(ESelf, name)` in a SEPARATE, later desugar pass over its own copy
// of the body before actually lowering. Fixing the lift pre-pass without also
// desugaring its own walked copy would leave the lifted lambda's synthesized
// body with the RAW (never-desugared) field reference — not a capture the
// call site's own capture-name collector would recognize under the same
// name, so it would silently resolve to nothing meaningful instead of the
// captured field (a wrong-value miscompile, not a crash). Covers both
// `PMFunc` (routed through `lowerImplMethodMsil`, the same shape as `IImpl`
// above) and `PMEntry` (routed through `lowerProtectedMsil` directly).
protected type Circuit {
  var count: Int = 0
  func peek(): Int {
    applyFn({ -> count + 1 })
  }
  entry bump(): Int {
    applyFn({ -> count + 1 })
  }
}

test "lambda literal inside a protected-type func body (#6119 follow-up)" {
  val c = Circuit()
  assertEqualInt(c.peek(), 1, "lambda captures protected field from within a protected-type func")
}

test "lambda literal inside a protected-type entry body (#6119 follow-up)" {
  val c = Circuit()
  assertEqualInt(c.bump(), 1, "lambda captures protected field from within a protected-type entry")
}

// ── Bare self-field read/write in an impl method (#6173) ──────────────────────
// A bare field reference/assignment inside an `impl` method body (no `self.`
// prefix) is `this.<name>` — the receiver's field.  The MSIL codegen's EPath
// read/write fallbacks previously had no "is this a receiver field?" check
// (unlike the JVM `selfFieldType` path) and silently produced `MLdNull` for
// the read and dropped the write (`MPop` on the RHS) — the value never
// updated and every read returned `null`/0.
interface Counter {
  func bumpBy(n: Int): Int
}

record CounterImpl {
  var x: Int
}

impl Counter for CounterImpl {
  func bumpBy(n: Int): Int {
    x = x + n
    x
  }
}

test "bare self-field read + write in an impl method (#6173)" {
  val c: Counter = CounterImpl(x = 10)
  assertEqualInt(c.bumpBy(5), 15, "bare field write persists and bare field read sees it")
  assertEqualInt(c.bumpBy(1), 16, "second bump accumulates on the same instance")
}

// ── Bare self-field read/write in a record in-body method (#6173) ─────────────
record Tally {
  var total: Int
  func add(n: Int): Int {
    total = total + n
    total
  }
}

test "bare self-field read + write in a record in-body method (#6173)" {
  val t = Tally(total = 100)
  assertEqualInt(t.add(5), 105, "in-body method bare field write persists")
  assertEqualInt(t.add(0 - 3), 102, "in-body method bare field write handles negative RHS")
}

// ── impl method with an EXPLICIT `self` receiver + a same-file matching
//    interface (#6408) ─────────────────────────────────────────────────────
// D037 allows an impl method to spell its receiver explicitly
// (`self: in <Target>`, or `self: in Self` on the interface side — #6417).
// `addPackageTokens`' IImpl pre-pass registered the CONCRETE-receiver
// dispatch key (`"<Target>/<method>"`, consulted by `lowerMethodCallMsil`
// for a call resolved directly against the record's own type, e.g.
// `y.method(...)` where `y`'s static type IS the record) from the impl
// method's RAW, unstripped `params` list — `self` at index 0 followed by
// the real params — while `lowerImplMethodMsil` (the actual MethodDef
// emission) always strips the explicit `self` before building the real
// signature. The registered per-index expected types (`registerMethod-
// ParamTypes`/`Modes`) were therefore shifted by one against the real
// emitted parameter list, so a direct call pushed its explicit arguments
// against the WRONG per-index expectation (arg 0 checked against `self`'s
// registered type instead of the first real parameter's) and produced
// invalid IL (`InvalidProgramException`). Calls through an INTERFACE-typed
// binding/parameter were unaffected — those resolve through a SEPARATE
// registration (`"<Interface>/<method>"`) that already stripped `self`
// (#5566) — so only the direct-on-record-value dispatch axis crashed.
interface Adder6408 {
  func add(self: in Self, n: Int, extra: Bool): Int
}

record Accum6408 {
  base: Int
}

impl Adder6408 for Accum6408 {
  func add(self: in Accum6408, n: Int, extra: Bool): Int {
    if extra {
      self.base + n + 1
    } else {
      self.base + n
    }
  }
}

test "direct call on the record value with an explicit `self` receiver (#6408)" {
  val a = Accum6408(base = 10)
  assertEqualInt(a.add(5, false), 15, "direct dispatch: 10 + 5")
  assertEqualInt(a.add(5, true), 16, "direct dispatch, second arg path: 10 + 5 + 1")
}

test "interface-typed local binding dispatch with an explicit `self` receiver (#6408)" {
  val a: Adder6408 = Accum6408(base = 10)
  assertEqualInt(a.add(5, false), 15, "interface-typed binding dispatch still correct")
  assertEqualInt(a.add(5, true), 16, "interface-typed binding dispatch, second arg path")
}

func useAdder6408(a: in Adder6408, n: Int): Int {
  a.add(n, false)
}

test "interface-typed function parameter dispatch with an explicit `self` receiver (#6408)" {
  val a = Accum6408(base = 10)
  assertEqualInt(useAdder6408(a, 7), 17, "interface-typed parameter dispatch still correct")
}

// ── impl method whose receiver is spelled `self: in Self`, MIRRORING the
//    interface's own `Self` receiver verbatim (#6417) ─────────────────────
// Before the fix, `checkImplConformance` (T0106/C11) substituted `Self` ->
// the impl's concrete target on the INTERFACE side of the comparison only;
// the impl side's own literal `Self` stayed unsubstituted `TySelf`, so it
// could never equal the substituted concrete type and every impl mirroring
// the interface's `Self` spelling verbatim was rejected at compile time
// (`self: in <Target>`, as `Accum6408` above uses, was the only accepted
// spelling). The fix substitutes `Self` on BOTH sides. Codegen needed no
// change for the receiver position: an explicit `self` param — spelled
// either way — is always stripped before signature lowering and dispatches
// through the implicit `this` slot (`ESelf` -> `ldarg.0`), so the receiver
// position was already correct end-to-end even before this fix; #6417 was
// purely a front-end over-rejection.
interface Tagger6417 {
  func tag(self: in Self): Int
}

record Applier6417 {
  seed: Int
}

impl Tagger6417 for Applier6417 {
  func tag(self: in Self): Int {
    self.seed
  }
}

test "direct call on the record value with a Self receiver matching the interface (#6417)" {
  val a = Applier6417(seed = 42)
  assertEqualInt(a.tag(), 42, "direct dispatch: Self-receiver impl reads seed")
}

test "interface-typed local binding dispatch with a Self receiver matching the interface (#6417)" {
  val a: Tagger6417 = Applier6417(seed = 7)
  assertEqualInt(a.tag(), 7, "interface-typed binding dispatch: Self-receiver impl")
}

func useTagger6417(t: in Tagger6417): Int {
  t.tag()
}

test "interface-typed function parameter dispatch with a Self receiver matching the interface (#6417)" {
  val a = Applier6417(seed = 99)
  assertEqualInt(useTagger6417(a), 99, "interface-typed parameter dispatch: Self-receiver impl")
}

// NOTE (#6417): `Self` in a NON-receiver parameter position (e.g.
// `func combine(self: in Self, other: in Self): Int`) now TYPE-CHECKS after
// this fix, but is deliberately NOT covered by a runtime test here — it
// exposed a separate, pre-existing MSIL codegen soundness bug in
// `msil/codegen.l`'s `fieldTokensByName` map (keyed by `"<package>/<field
// name>"`, first-registration-wins, no owning-type disambiguation): field
// access on a non-receiver `Self`-typed parameter (erased to `Object` in the
// real IL signature, same as the interface slot) falls back to this
// package-wide, field-NAME-only table to find which record's field to read.
// When a SECOND record in the same package declares a field with the SAME
// name, the fallback silently keeps resolving to the FIRST record ever
// registered under that name — reading `other.<field>` on a genuinely
// different record throws `System.InvalidCastException` (confirmed with a
// minimal two-record repro: `Accum6408`/`Accum6417`, both with a `base:
// Int` field, in the same package). This was unreachable before #6417
// because a non-receiver `Self` param never type-checked at all (T0106
// always rejected it); the fix newly exposes it. The RECEIVER position
// (`self`, always stripped and dispatched via the implicit `this` slot) and
// the RETURN position (call-site `Self` substitution using the receiver's
// own static type, no field-name-keyed lookup involved) do not share this
// mechanism and are unaffected — both are covered above/below. Tracked in
// #6421 (MSIL unsoundness; JVM's structured-refusal rough edge is #6422);
// not attempted here (real fix needs type-directed field resolution for
// erased-Self locals, not a field-name index).
// ── `Self` as the RETURN type (#6417) ────────────────────────────────────
// Mirrors the language reference's `Cloneable`-style `func clone(): Self`
// shape (docs/01 uses `Self` as a return type in interface examples), now
// exercised on an impl whose own method also spells the return `Self`.
// MSIL already lowers this correctly end-to-end with no code change.
interface Cloner6417 {
  func dup(self: in Self): Self
}

record Box6417 {
  v: Int
}

impl Cloner6417 for Box6417 {
  func dup(self: in Self): Self {
    Box6417(v = self.v + 1)
  }
}

func dupValue6417(c: in Box6417): Int {
  val d = c.dup()
  d.v
}

test "direct call with a Self return type (#6417)" {
  val a = Box6417(v = 41)
  val b = a.dup()
  assertEqualInt(b.v, 42, "direct dispatch: Self-return impl reads incremented v")
}

test "interface-typed function parameter/return dispatch with a Self return type (#6417)" {
  val a = Box6417(v = 9)
  assertEqualInt(dupValue6417(a), 10, "Self-returning impl method call through a concrete-typed local")
}
