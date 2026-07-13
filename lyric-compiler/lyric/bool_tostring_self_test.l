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

// NOTE: `s += true`-shaped compound-assignment onto a String *plain variable*
// is covered by `compound_string_assign_self_test.l` (#5657, fixed): the type
// checker now special-cases `+=` onto a String plain-var target to accept any
// RHS, mirroring binary `+`. Field (`obj.f += x`) and indexed (`xs[i] += x`)
// String targets with a non-String RHS remain rejected by T0063 pending a
// codegen fix, tracked as #5688.
