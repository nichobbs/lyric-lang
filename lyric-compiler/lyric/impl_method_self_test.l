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
