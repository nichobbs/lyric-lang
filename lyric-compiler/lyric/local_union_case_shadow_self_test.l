//! local_union_case_shadow_self_test.l — dual-target runtime regression test
//! for a bare case pattern whose name a local union also declares (#7761).
//!
//! This package declares its own `union Option` and `union Result`, then
//! matches `case Some(v)` / `case Ok(v)` against genuine `Std.Core.Option` /
//! `Std.Core.Result` values returned by the standard library.  The type checker
//! resolves each bare case name in the scrutinee's own union, and `--target
//! dotnet` agreed, but `--target jvm` erases a generic scrutinee to `Object`
//! and resolved the name by package first: it tested the stdlib value against
//! the LOCAL `Some`/`Ok` case class, no arm matched, and the program threw
//! `Jvm.Codegen: match not exhaustive` at runtime.
//!
//! The checker now records the union each case pattern matched, and the JVM
//! resolves the case name in that union first, falling back to the enclosing
//! package's unions only when nothing was recorded.  The companion cases match
//! values of the local unions themselves, which must keep resolving locally.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/local_union_case_shadow_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/local_union_case_shadow_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.LocalUnionCaseShadowSelfTest

import Std.String
import Std.Parse
import Std.Testing

union Option[T] {
  case Some(value: T)
  case None
}

union Result[T, E] {
  case Ok(value: T)
  case Err(error: E)
}

func describeIndex(s: in String, needle: in String): String {
  match s.indexOf(needle) {
    case Some(v) -> "some " + toString(v)
    case None -> "none"
  }
}

func describeParse(s: in String): String {
  match tryParseInt(s) {
    case Ok(v) -> "ok " + toString(v + 1)
    case Err(_) -> "err"
  }
}

func describeOptParse(s: in String): Int {
  match parseOptInt(s) {
    case None -> -1
    case Some(v) -> v * 2
  }
}

func localOption(b: in Bool): Option[Int] {
  if b {
    Some(value = 7)
  } else {
    None
  }
}

func localResult(n: in Int): Result[Int, String] {
  if n >= 0 {
    Ok(value = n)
  } else {
    Err(error = "negative")
  }
}

func describeLocalOption(o: in Option[Int]): String {
  match o {
    case Some(v) -> "local some " + toString(v)
    case None -> "local none"
  }
}

func describeLocalResult(r: in Result[Int, String]): String {
  match r {
    case Ok(v) -> "local ok " + toString(v)
    case Err(e) -> "local err " + e
  }
}

test "stdlib Option matched with the local union's case names" {
  assertEqual(describeIndex("abc", "b"), "some 1", "found")
  assertEqual(describeIndex("abc", "z"), "none", "not found")
}

test "stdlib Option matched with None first" {
  assertEqualInt(describeOptParse("21"), 42, "parsed")
  assertEqualInt(describeOptParse("x"), -1, "not a number")
}

test "stdlib Result matched with the local union's case names" {
  assertEqual(describeParse("41"), "ok 42", "parsed")
  assertEqual(describeParse("nope"), "err", "not a number")
}

test "local Option values still match the local cases" {
  assertEqual(describeLocalOption(localOption(true)), "local some 7", "local Some")
  assertEqual(describeLocalOption(localOption(false)), "local none", "local None")
}

test "local Result values still match the local cases" {
  assertEqual(describeLocalResult(localResult(3)), "local ok 3", "local Ok")
  assertEqual(describeLocalResult(localResult(-1)), "local err negative", "local Err")
}

test "stdlib and local Option in one function" {
  val a = match "xyz".indexOf("z") { case Some(i) -> i; case None -> -1 }
  val b = match localOption(true) { case Some(v) -> v; case None -> -1 }
  assertEqualInt(a + b, 9, "2 + 7")
}
