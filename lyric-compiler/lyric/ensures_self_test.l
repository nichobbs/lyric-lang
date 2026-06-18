//! ensures_self_test.l — #1871: a function carrying an `ensures:` contract
//! clause must compile and run through the self-hosted MSIL path.
//!
//! The contract elaborator (`Lyric.ContractElaborator`) lowers each `ensures:`
//! clause into a synthesised `let __lyric_result_<n> = <body value>` binding
//! plus `assert(<ensures>)` statements at the function exit.  That `let`
//! binding was built with a bare `LBLet(..., ty = None, ...)`; when the
//! stage-0 F# compiler builds the elaborator package, the bare `None` widens
//! to `Option[obj]` with a stale generic arg (#1451), so the value reaching
//! the MSIL codegen's `match binding.ty` could not dispatch — `annoTy`
//! resolved to null and `annoTy != MObject` threw a `NullReferenceException`
//! in `lowerStmtMsil`'s `LBLet` arm.  Every `ensures:`-bearing function
//! therefore crashed codegen (a hard NRE, not a diagnostic), which also broke
//! `lyric build --manifest` on any package whose sources use `ensures:` (the
//! whole stdlib).  `requires:`-only functions were unaffected (no `result`
//! binding).  Pinning `val noTy: Option[TypeExpr] = None` in the elaborator's
//! `mkLetBinding` fixes it.
//!
//! No prior test caught this: `contract_elaborator_self_test.l` checks the
//! elaborated AST *shape* but never compiles + runs the result, and the
//! verifier tests use `lyric prove`, not codegen.  This module closes that gap
//! by running `ensures:`-bearing functions end-to-end and asserting their
//! return values.
//!
//! Run in CI via native `lyric test --target dotnet` (compiles in-process
//! through the self-hosted `Msil.Bridge`).  Imports only `Std.*`.
@test_module
package Lyric.EnsuresSelfTest

import Std.Core
import Std.Testing

// Implicit fall-off (trailing expression) body — the elaborator binds the
// trailing value into `__lyric_result_0` and asserts the ensures over it.
func inc(x: in Int): Int
  ensures: result > x
{
  x + 1
}

// requires: + ensures: together (the exact #1871 repro shape).
func incPos(x: in Int): Int
  requires: x > 0
  ensures: result > 0
{
  x + 1
}

// Explicit `return` body — the elaborator rewrites `return e` into a bind +
// asserts + `return __lyric_result_0`.
func five(): Int
  ensures: result == 5
{
  return 5
}

// Multi-statement body so the trailing `SExpr` is preceded by real locals.
func sum3(a: in Int, b: in Int, c: in Int): Int
  ensures: result >= a
{
  val ab = a + b
  ab + c
}

// `ensures:` on a String return — exercises a non-Int `result` binding.
func greet(name: in String): String
  ensures: true
{
  val msg = "hi " + name
  msg
}

// `ensures:` on a String return whose body is a bare `if`-expression — the
// synthesised `let __lyric_result = if … else …` binds an `if`-as-value of
// String type.  This was the #1977 repro (invalid IL); it is fixed and guarded
// here so it stays fixed.
func pickStr(ok: in Bool): String
  ensures: result == "yes" or result == "no"
{
  if ok {
    "yes"
  } else {
    "no"
  }
}

// `ensures:` over an Option return — exercises the result binding on a
// generic-union value (None-first match in the helper, per #1855).
func maybe(n: in Int): Option[Int]
  ensures: true
{
  if n > 0 {
    Some(n)
  } else {
    None
  }
}

func optOr(o: in Option[Int], d: in Int): Int {
  match o {
    case None -> d
    case Some(v) -> v
  }
}

test "ensures on a trailing-expression body compiles and runs" {
  assertEqualInt(inc(2), 3, "inc(2) == 3")
  assertEqualInt(inc(41), 42, "inc(41) == 42")
}

test "requires + ensures together (the #1871 repro)" {
  assertEqualInt(incPos(2), 3, "incPos(2) == 3")
}

test "ensures on an explicit-return body" {
  assertEqualInt(five(), 5, "five() == 5")
}

test "ensures on a multi-statement body" {
  assertEqualInt(sum3(1, 2, 3), 6, "1+2+3 == 6")
}

test "ensures over a String result" {
  assertEqual(greet("ann"), "hi ann", "greet(ann)")
}

test "ensures over a String result from an if-expression body (#1977)" {
  assertEqual(pickStr(true), "yes", "pickStr(true)")
  assertEqual(pickStr(false), "no", "pickStr(false)")
}

test "ensures over an Option result" {
  assertEqualInt(optOr(maybe(7), -1), 7, "maybe(7) -> Some(7)")
  assertEqualInt(optOr(maybe(0), -1), -1, "maybe(0) -> None")
}
