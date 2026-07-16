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
import Lyric.BuildDefines as BD

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

// ── decodeDefines unit coverage (the CLI/bridge `List[String]` -> Define path) ──
test "decodeDefines parses KEY=VALUE" {
  val kvs: List[String] = newList()
  kvs.add("greeting=hello")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "greeting") {
    case Some(v) -> assertEqual(v, "hello", "value parsed after the first '='")
    case None -> assertTrue(false, "greeting should decode")
  }
}

test "decodeDefines keeps everything after the first '=' (values may contain '=')" {
  val kvs: List[String] = newList()
  kvs.add("expr=a==b")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "expr") {
    case Some(v) -> assertEqual(v, "a==b", "only the first '=' splits key from value")
    case None -> assertTrue(false, "expr should decode")
  }
}

test "decodeDefines is last-wins for a repeated key (#5873)" {
  val kvs: List[String] = newList()
  kvs.add("k=first")
  kvs.add("k=second")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "k") {
    case Some(v) -> assertEqual(v, "second", "the later --define wins")
    case None -> assertTrue(false, "k should decode")
  }
}

test "decodeDefines skips entries without '='" {
  val kvs: List[String] = newList()
  kvs.add("novalue")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "novalue") {
    case Some(_) -> assertTrue(false, "an entry with no '=' should not decode")
    case None -> assertTrue(true, "skipped as expected")
  }
}
