//! build_defines_self_test.l — exercises the docs/60 `@build_const`
//! substitution pass through the real compile pipeline.
//!
//! This module is compiled by `lyric test` with NO `--define` supplied, so
//! every `@build_const` here takes its in-source fallback literal — the
//! dev-checkout path (docs/60 §2.1, §6). It verifies that the substitution
//! pass integrates without disturbing normal compilation and that an
//! unsupplied define correctly leaves the fallback in place. The supplied
//! (substituted) path is exercised end-to-end by a `lyric build --define`
//! build+run, since `lyric test` does not thread `--define`.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/build_defines_self_test.l
@test_module
package Lyric.BuildDefinesSelfTest

import Std.Core
import Std.Collections
import Std.Testing

@build_const("bd_selftest_unsupplied_key")
val FALLBACK: String = "fallback-value"

@build_const("bd_selftest_also_unsupplied")
val OTHER: String = "other-fallback"

test "an unsupplied @build_const keeps the in-source fallback literal" {
  assertEqual(FALLBACK, "fallback-value", "no define supplied -> fallback preserved")
}

test "a second unsupplied @build_const is independent and also falls back" {
  assertEqual(OTHER, "other-fallback", "each @build_const falls back independently")
}

test "a plain (un-annotated) val is untouched by the pass" {
  val plain = "plain"
  assertEqual(plain, "plain", "the substitution pass leaves non-annotated bindings alone")
}
