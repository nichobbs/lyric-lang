//! bool_tostring_self_test.l — cross-target regression test pinning `Bool`
//! stringification to lowercase `true`/`false` (#5552).
//!
//! Before this fix, string concatenation (`"" + b`), string interpolation
//! (`"${b}"`), the `toString(b)` builtin, and the `b.toString()` member call
//! all rendered a `Bool` via the BCL's `Boolean.ToString()` on `--target
//! dotnet` ("True"/"False"), but Java's `String.valueOf(boolean)` on
//! `--target jvm` ("true"/"false") — any program building output from `Bool`
//! values produced target-dependent text.  Lowercase was picked as the
//! canonical spelling (it matches the language's own `true`/`false` literals
//! and `Std.Json`), and the `.NET` backend (`lyric-compiler/msil/codegen.l`)
//! was pinned to it directly — unlike `Double`'s `#2462` fix, `bool.ToString()`
//! has no `IFormatProvider` overload to route through `InvariantCulture`, so
//! the fix branches on the runtime value and pushes the matching literal.
//!
//! Run via the native `lyric test` on **both targets**, mirroring
//! `bitwise_self_test.l` / `conv_methods_self_test.l`:
//!
//!   lyric test lyric-compiler/lyric/bool_tostring_self_test.l              (MSIL)
//!   lyric test --target jvm lyric-compiler/lyric/bool_tostring_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.BoolToStringSelfTest

import Std.Core
import Std.Testing

test "toString(Bool) renders lowercase true/false" {
  assertEqual(toString(true), "true", "toString(true)")
  assertEqual(toString(false), "false", "toString(false)")
}

test "Bool.toString() member call renders lowercase true/false" {
  val t: Bool = true
  val f: Bool = false
  assertEqual(t.toString(), "true", "true.toString()")
  assertEqual(f.toString(), "false", "false.toString()")
}

test "string concatenation of a Bool renders lowercase true/false" {
  assertEqual("" + true, "true", "\"\" + true")
  assertEqual("" + false, "false", "\"\" + false")
  assertEqual("flag=" + true, "flag=true", "prefix concat with true")
  assertEqual("flag=" + false, "flag=false", "prefix concat with false")
}

test "string interpolation of a Bool renders lowercase true/false" {
  val ok: Bool = true
  val bad: Bool = false
  assertEqual("ok=${ok}", "ok=true", "interpolated true")
  assertEqual("bad=${bad}", "bad=false", "interpolated false")
  assertEqual("${ok} and ${bad}", "true and false", "two interpolation holes")
}

// NOTE: a `s += true`-shaped compound-assignment case is deliberately NOT
// covered here. `SAssign` type-checking (typechecker_stmts.l) requires the
// RHS to satisfy the target's exact type for EVERY assignment op, including
// `+=` — it doesn't special-case `+=`'s "any operand + String = String"
// semantics the way the binary `+` operator's inference does. So `s +=
// true` (and equally `s += 3.5`, `s += 42`, for any String-typed `s`) is
// currently rejected by the type checker with T0063 on both targets, a
// pre-existing gap unrelated to this issue's Bool-stringification scope.
// Tracked separately as #5657; not fixed here.
