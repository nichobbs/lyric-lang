//! result_ensures_accessor_self_test.l — #5183: `ensures: result.isOk implies
//! result.value ...` on a `Result[T, E]` whose error type `E` is a
//! payload-carrying union compiled cleanly but threw
//! `System.InvalidProgramException` at the first call.
//!
//! Root cause was NOT specific to `E` carrying a payload: `.isOk`/`.isErr`/
//! `.value`/`.error` on `Result[T, E]` (and `.isSome`/`.isNone`/`.value` on
//! `Option[T]`) are direct field-style accessors on the two builtin monadic
//! unions (docs/01 §generics, docs/08 §6.2, docs/02 worked examples) that
//! were never actually resolved anywhere in the pipeline: `Result`/`Option`
//! are unions, so `inferMemberBase` (`typechecker_exprs.l`) never finds a
//! matching field, and there is no `func Result.isOk(...)`-style dot-named
//! function either — so the access silently typed as `TyError` with no
//! diagnostic (unions are excluded from the member-complete gate that would
//! otherwise flag it). Codegen then had to resolve the SAME bare `EMember`
//! independently: it looked up a field token under the RECEIVER's own class
//! name (`Std.Core.Result/value`), but case fields are registered under the
//! CASE class name (`Std.Core.Result_Ok/value`) — so the lookup always
//! missed, and the generic unregistered-field fallback popped the receiver
//! without pushing a replacement, corrupting the evaluation stack
//! (`InvalidProgramException` at the first call). This reproduces
//! identically for a trivial `E` (`Result[Int, String]`) as for a
//! payload-carrying one — verified by hand against `main` before the fix.
//!
//! The fix adds real support for these six accessors: the type checker
//! (`typechecker_exprs.l`'s `builtinMember`) now types them against
//! `Result`/`Option`'s type arguments, and both backends
//! (`lyric-compiler/msil/codegen.l`, `lyric-compiler/jvm/codegen/02_exprs.l`)
//! lower `.isOk`/`.isErr`/`.isSome`/`.isNone` to an `isinst`/`instanceof`
//! boolean test against the matching case class, and `.value`/`.error` to a
//! cast + field read on that case.
//!
//! Run in CI via native `lyric test` on **both targets** (like
//! `bitwise_self_test.l`): `--target dotnet` through `Msil.Bridge`,
//! `--target jvm` through `Jvm.Bridge` `compileToJarBundled`. Imports only
//! `Std.*`.
@test_module
@runtime_checked
package Lyric.ResultEnsuresAccessorSelfTest

import Std.Core
import Std.Testing

// A payload-carrying union as the `Result`'s error type — the exact shape
// #5183 was filed against (`ContractRepro.Domain.DbError` in the issue).
pub union DbError {
  case NotFound
  case ConnectionFailed(message: String)
  case QueryError(sql: String, code: Int)
}

// The exact repro shape from #5183: `ensures: result.isOk implies
// result.value >= 0` on a `Result[Int, DbError]`-returning function.
pub func runQuery(sql: in String): Result[Int, DbError]
  requires: sql.length > 0
  ensures: result.isOk implies result.value >= 0
{
  if sql == "bad" {
    return Err(DbError.QueryError(sql = sql, code = 1))
  }
  return Ok(42)
}

// The `Err`-side counterpart: `.isErr implies .error` must read the payload
// union's own field correctly (not just prove the accessor doesn't crash).
pub func runQueryErrCode(sql: in String): Result[Int, DbError]
  requires: sql.length > 0
  ensures: result.isErr implies (match result.error { case QueryError(_, code) -> code > 0; case _ -> true })
{
  if sql == "bad" {
    return Err(DbError.QueryError(sql = sql, code = 7))
  }
  return Ok(1)
}

// `Option[T]`'s twin accessors (`.isSome`/`.isNone`/`.value`) share the same
// codegen path (#5183's fix covers both builtin monadic unions) — covered
// here so a future regression in the Option half is also caught.
pub func firstPositive(xs: in slice[Int]): Option[Int]
  ensures: result.isSome implies result.value > 0
{
  var i = 0
  while i < xs.length {
    if xs[i] > 0 {
      return Some(xs[i])
    }
    i += 1
  }
  return None
}

test "ensures: result.isOk implies result.value >= 0 -- Ok path returns the value, no crash" {
  match runQuery("SELECT 1") {
    case Ok(n) -> assertEqualInt(n, 42, "runQuery(\"SELECT 1\") Ok value")
    case Err(_) -> assertTrue(false, "expected Ok, got Err")
  }
}

test "ensures: result.isOk implies result.value >= 0 -- Err path short-circuits, no crash" {
  match runQuery("bad") {
    case Ok(_) -> assertTrue(false, "expected Err, got Ok")
    case Err(e) -> {
      match e {
        case QueryError(sql, code) -> {
          assertTrue(sql == "bad", "QueryError.sql")
          assertEqualInt(code, 1, "QueryError.code")
        }
        case _ -> assertTrue(false, "expected QueryError")
      }
    }
  }
}

test "ensures: result.isErr implies result.error reads the payload union's own field -- Err path" {
  match runQueryErrCode("bad") {
    case Ok(_) -> assertTrue(false, "expected Err, got Ok")
    case Err(e) -> {
      match e {
        case QueryError(_, code) -> assertEqualInt(code, 7, "QueryError.code")
        case _ -> assertTrue(false, "expected QueryError")
      }
    }
  }
}

test "ensures: result.isErr implies result.error -- Ok path short-circuits, no crash" {
  match runQueryErrCode("SELECT 1") {
    case Ok(n) -> assertEqualInt(n, 1, "runQueryErrCode(\"SELECT 1\") Ok value")
    case Err(_) -> assertTrue(false, "expected Ok, got Err")
  }
}

test "ensures: result.isSome implies result.value > 0 -- Option accessor parity, Some path" {
  val xs: slice[Int] = [-3, -1, 0, 5, 8]
  match firstPositive(xs) {
    case Some(v) -> assertEqualInt(v, 5, "firstPositive Some value")
    case None -> assertTrue(false, "expected Some, got None")
  }
}

test "ensures: result.isSome implies result.value > 0 -- Option accessor parity, None path" {
  val xs: slice[Int] = [-3, -1, 0]
  match firstPositive(xs) {
    case Some(_) -> assertTrue(false, "expected None, got Some")
    case None -> assertTrue(true, "firstPositive None path did not crash")
  }
}
