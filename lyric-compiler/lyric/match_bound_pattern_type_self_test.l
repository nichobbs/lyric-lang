//! match_bound_pattern_type_self_test.l — runtime regression test for two
//! match-pattern-bound variable type-erasure bugs, both reported from the
//! same investigation (#5422, #5423).
//!
//! #5422: `Std.Collections.mapKeys(mm)` called directly on a `Map` value
//! bound by `case Some(mm) -> …` (an `Option[Map[K, V]]` destructure) threw
//! a runtime cast exception on `--target dotnet` (`Dictionary` cannot be
//! cast to `Dictionary<Object, Object>`). Root cause: `Lyric.Mono`'s
//! call-site type-argument inference tracked a `val`/`var`/`let` binding's
//! type into its `env`, but never tracked a `match`-arm PATTERN binding —
//! so a generic call argument sourced from a match-bound name had no known
//! type. `mapKeys` is an IMPORTED generic (erased from the compiled
//! assembly; every call site must specialise), so the unresolved type
//! parameters silently defaulted to `Object` instead of the real `Map[K,
//! V]` instantiation, producing a specialisation whose body operates on the
//! WRONG generic instantiation. Fixed in `Lyric.Mono.rewriteMatchArms` /
//! `bindPatternEnvMono` (`lyric-compiler/lyric/mono.l`): each arm's pattern
//! is now typed from the scrutinee's own (possibly generic) instantiation,
//! mirroring `rewriteBinding`'s existing `val` tracking, before the arm
//! body is rewritten.
//!
//! #5423: calling a native `String` method (`.contains`) on a `String`
//! value bound inside a `match { case Ok(json) -> … }` arm was reported to
//! crash `--target jvm` compilation entirely (the JVM backend's own
//! `ctx.types` tracking losing the payload's `String` type and falling
//! through to JVM auto-FFI resolution against the erased `java.lang.Object`
//! receiver). Investigated alongside #5422 as a possibly-shared root cause;
//! this repro (matching the issue's own minimal repro and the closer
//! lambda-wrapped / cross-package shapes exercised by
//! `lyric-i18n/tests/i18n_kernel_tests.l`) could not be reproduced against
//! current `HEAD` — the JVM backend's `bindCaseField`/`scrutineeGenericArgs`
//! machinery (`lyric-compiler/jvm/codegen/03_match.l`) already resolves the
//! match-bound payload's concrete JVM type correctly. Kept here as a
//! standing regression guard on both targets in case future JVM codegen
//! changes reopen the gap.
//!
//! Run by the native `lyric test` on BOTH targets (like
//! `block_shadow_self_test.l` / `bitwise_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/match_bound_pattern_type_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/match_bound_pattern_type_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.MatchBoundPatternTypeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// #5422 — mapKeys() on a match-pattern-bound Map payload.
// ─────────────────────────────────────────────────────────────────────────────
// The exact shape from the issue: a `Map[String, String]` wrapped in
// `Some(...)`, destructured by `match`, and passed DIRECTLY (no rebind) to
// the imported generic `mapKeys`.
func mapKeysOnMatchBoundMap(): Int {
  val m: Map[String, String] = newMap()
  m.add("a", "1")
  val opt: Option[Map[String, String]] = Some(value = m)
  match opt {
    case Some(mm) -> mapKeys(mm).count
    case None -> -1
  }
}

// A multi-entry map, plus `mapValues` (a second imported generic sharing the
// same K/V erasure shape) on the same match-bound name.
func mapKeysAndValuesOnMatchBoundMap(): Int {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  m.add("c", 3)
  val opt: Option[Map[String, Int]] = Some(value = m)
  match opt {
    case Some(mm) -> {
      val keys = mapKeys(mm)
      val values = mapValues(mm)
      keys.count + values.count
    }
    case None -> -1
  }
}

// `Result` (not `Option`) as the outer union, `Err`/`Ok` arm naming — the
// mapKeys call sits in the SECOND field position's case.
func mapKeysOnMatchBoundMapViaResult(): Int {
  val m: Map[String, String] = newMap()
  m.add("x", "1")
  m.add("y", "2")
  val r: Result[String, Map[String, String]] = Err(error = m)
  match r {
    case Ok(_) -> -1
    case Err(mm) -> mapKeys(mm).count
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// #5423 — native String method on a match-pattern-bound String payload.
// ─────────────────────────────────────────────────────────────────────────────
func getGreeting(): Result[String, String] {
  Ok(value = "hello world")
}

// The exact shape from the issue: `.contains` called directly (no rebind) on
// a `String` bound by `case Ok(json) -> …`.
func containsOnMatchBoundString(): Bool {
  val someResult = getGreeting()
  match someResult {
    case Ok(json) -> json.contains("hello")
    case Err(e) -> panic(e)
  }
}

// Direct-call scrutinee (no intermediate `val`) — the closer shape to the
// `lyric-i18n` kernel's `match loadFromPath(path) { case Ok(text) -> … }`.
func containsOnMatchBoundStringDirectCall(): Bool {
  match getGreeting() {
    case Ok(json) -> json.contains("world")
    case Err(e) -> panic(e)
  }
}

// A String-returning function invoked inside a lambda body, matched
// directly — mirrors `withFixtureFile(path, { p -> match loadFromPath(p) {
// case Ok(text) -> text.contains(...) } })`.
func withValue(v: in String, body: in (String) -> Bool): Bool {
  body(v)
}

func containsOnMatchBoundStringInLambda(): Bool {
  withValue(
    "ignored",
    { _ -> match getGreeting() { case Ok(json) -> json.contains("hello"); case Err(e) -> panic(e) } }
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "mapKeys on a match-bound Map payload returns the real key count (#5422)" {
  assertEqualInt(mapKeysOnMatchBoundMap(), 1, "one key in the match-bound map")
}

test "mapKeys/mapValues on a multi-entry match-bound Map payload (#5422)" {
  assertEqualInt(mapKeysAndValuesOnMatchBoundMap(), 6, "3 keys + 3 values")
}

test "mapKeys on an Err-bound Map payload (#5422)" {
  assertEqualInt(mapKeysOnMatchBoundMapViaResult(), 2, "two keys in the Err-bound map")
}

test "contains on a match-bound String payload resolves natively (#5423)" {
  assertTrue(containsOnMatchBoundString(), "contains finds 'hello'")
}

test "contains on a directly-matched call's String payload resolves natively (#5423)" {
  assertTrue(containsOnMatchBoundStringDirectCall(), "contains finds 'world'")
}

test "contains on a match-bound String payload inside a lambda resolves natively (#5423)" {
  assertTrue(containsOnMatchBoundStringInLambda(), "contains finds 'hello' inside the lambda")
}
