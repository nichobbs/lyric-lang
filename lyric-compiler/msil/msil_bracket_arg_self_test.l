//! msil_bracket_arg_self_test.l — regression coverage for
//! `Msil.Codegen.parseBracketArgFqns`'s `[`/`]`-nesting depth tracking
//! (#4044, #4728): a comma inside a nested closed-generic type argument
//! (e.g. `Dictionary`2[String,Int32]` inside a `Tuple`2[...]`) must not be
//! treated as a top-level argument separator.
//!
//! Run in CI via native `lyric test` (imports `Msil.Codegen`, resolved by
//! linking the already-compiled compiler DLLs as restored deps):
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_bracket_arg_self_test.l
@test_module
package Msil.BracketArgSelfTest

import Msil.Codegen
import Std.Core
import Std.Collections
import Std.Testing

test "parseBracketArgFqns: single non-generic type argument" {
  val args = parseBracketArgFqns("System.Threading.Tasks.Task`1[System.String]")
  assertEqualInt(args.count, 1, "single arg count")
  assertEqual(args[0], "System.String", "single arg value")
}

test "parseBracketArgFqns: two non-nested type arguments" {
  val args = parseBracketArgFqns("System.Tuple`2[System.String,System.Int32]")
  assertEqualInt(args.count, 2, "two-arg count")
  assertEqual(args[0], "System.String", "first arg")
  assertEqual(args[1], "System.Int32", "second arg")
}

test "parseBracketArgFqns: nested generic argument is not split at its inner comma" {
  // Without depth tracking, the inner comma between String and Int32 would
  // be mistaken for the outer Tuple`2 separator, producing three broken
  // elements instead of the correct two.
  val args = parseBracketArgFqns(
    "System.Tuple`2[System.Collections.Generic.Dictionary`2[System.String,System.Int32],System.Boolean]"
  )
  assertEqualInt(args.count, 2, "nested-arg count stays at 2")
  assertEqual(
    args[0],
    "System.Collections.Generic.Dictionary`2[System.String,System.Int32]",
    "nested Dictionary arg kept whole"
  )
  assertEqual(args[1], "System.Boolean", "trailing Boolean arg")
}

test "parseBracketArgFqns: no brackets yields an empty list" {
  val args = parseBracketArgFqns("System.String")
  assertEqualInt(args.count, 0, "no-bracket input yields empty list")
}

test "parseBracketArgFqns: doubly-nested generic argument stays whole" {
  val args = parseBracketArgFqns(
    "System.Tuple`2[System.Collections.Generic.List`1[System.Collections.Generic.List`1[System.Int32]],System.Boolean]"
  )
  assertEqualInt(args.count, 2, "doubly-nested-arg count stays at 2")
  assertEqual(
    args[0],
    "System.Collections.Generic.List`1[System.Collections.Generic.List`1[System.Int32]]",
    "doubly-nested List arg kept whole"
  )
  assertEqual(args[1], "System.Boolean", "trailing Boolean arg")
}
