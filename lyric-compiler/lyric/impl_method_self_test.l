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
