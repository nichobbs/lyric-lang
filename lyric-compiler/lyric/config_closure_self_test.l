//! config_closure_self_test.l — regression test for #6096: a module-level
//! `config { … }` block and a capturing closure in the SAME package used
//! to abort MSIL lowering entirely with
//!
//!   Msil.Lowering: MNewobjByName could not resolve .ctor for type '.__Closure_0'
//!
//! Root cause: `lowerMConfig` (`lyric-compiler/msil/lowering.l`) registered
//! its synthesized static class's `TypeDef` row via `addTypeDef` but never
//! called `recordUserTypeDefRow` afterward — unlike every other
//! type-lowering function (record, union, distinct type, enum, interface,
//! opaque). That omission desynced the positionally-indexed
//! `ctx.typeDefRowFqns` list that `findMethodDefRowOfType`'s reverse-lookup
//! fallback depends on for every type registered afterward in the same
//! package — including closure classes (`__Closure_N`), which are drained
//! and appended only after the rest of the package's items are lowered.
//! Same bug class as #5361 (`lowerMEnum`, fixed in D-progress-624;
//! see `enum_closure_pattern_bind_self_test.l` for that regression test).
//!
//! Either construct alone (a config block with no closures, or a closure
//! with no config block) always compiled fine — only the combination in one
//! package reproduced the abort, so this test deliberately keeps both in
//! one file/package.
//!
//! MSIL-only bug (JVM's `IConfig` lowering path is unaffected), so this
//! runs `--target dotnet` only via `lyric test`.
//! Imports only `Std.*`.
@test_module
package Lyric.ConfigClosureSelfTest

import Std.Core
import Std.Testing

config ClosureDefaults {
  base: Int = 10
}

test "module-level config block + a capturing closure in the same package compiles and runs" {
  val captured = 5
  val addCaptured = { x: Int -> x + captured }
  assertEqualInt(addCaptured(7), 12, "capturing closure runs correctly alongside a config block")
  assertEqualInt(ClosureDefaults.base, 10, "config block field still reads back its default")
}

test "a second closure and a second config read stay independently correct" {
  val multiplier = 3
  val scale = { x: Int -> x * multiplier }
  assertEqualInt(scale(ClosureDefaults.base), 30, "closure result composed with a config-block value")
}
