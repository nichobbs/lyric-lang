//! cfg_gate_self_test.l — exercises Lyric.CfgGate via the native
//! `@test_module` test runner.
//!
//! Covers #1123 (comment-aware detection).  #1124's multi-file assembly (one
//! stub when every file of a directory package is gated out) moved into the
//! package merge, which gates each file on its parse (`Lyric.PackageMerge`,
//! #8234; `package_merge_self_test.l`).
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/cfg_gate_self_test.l
//!
//! (#1436 / CLAUDE.md no-new-F#-code policy: no `SelfHostedCfgGateTests.fs`
//! runner — discovery is the native Lyric path mirroring `weaver_self_test.l`.)
@test_module
package Lyric.CfgGateSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.CfgGate

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
func emptyFeatures(): List[String] {
  newList()
}

func features1(a: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs
}

func features2(a: in String, b: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

// ---------------------------------------------------------------------------
// isCfgGatedOut — basic cases
// ---------------------------------------------------------------------------
test "isCfgGatedOut: no @cfg → not gated" {
  val src = "package Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()), "no @cfg → not gated")
}

test "isCfgGatedOut: no `package` declaration → not gated" {
  // Not a top-level Lyric file we can gate.
  val src = "@cfg(feature = \"x\")\nfunc foo(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()), "no `package` declaration → not gated")
}

test "isCfgGatedOut: inactive feature → gated" {
  val src = "@cfg(feature = \"redis\")\npackage Foo\n\nfunc main(): Unit {}\n"
  assertTrue(isCfgGatedOut(src, emptyFeatures()), "inactive feature → gated")
}

test "isCfgGatedOut: active feature → not gated" {
  val src = "@cfg(feature = \"redis\")\npackage Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, features1("redis")), "active feature → not gated")
}

test "isCfgGatedOut: @cfg after package → not whole-file gated" {
  // An @cfg annotation that appears AFTER the `package` declaration
  // gates only the item it precedes, not the whole file.
  val src = "package Foo\n\n@cfg(feature = \"redis\")\nfunc only(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()), "@cfg after package → not whole-file gated")
}

// ---------------------------------------------------------------------------
// #1123 — line comments containing @cfg must NOT trip the detector
// ---------------------------------------------------------------------------
test "isCfgGatedOut: @cfg in // line comment → not gated (#1123)" {
  // Reproduces the #1123 false positive: a line comment that mentions
  // `@cfg(feature = "x")` must not gate the package out.
  val src = "// this was @cfg(feature = \"x\") before we removed it\n" + "package Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()), "@cfg in // line comment → not gated (#1123)")
}

test "isCfgGatedOut: @cfg in /// doc comment → not gated" {
  // Doc comments use `///` which still starts with `//`.
  val src = "/// example: @cfg(feature = \"x\") used to wrap this file\n" + "package Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()), "@cfg in /// doc comment → not gated")
}

test "isCfgGatedOut: commented @cfg + real inactive @cfg → still gated" {
  // A commented-out @cfg followed by a real inactive @cfg: the real one
  // should still gate the file.
  val src = "// removed: @cfg(feature = \"old\")\n" + "@cfg(feature = \"new\")\n" + "package Foo\n"
  assertTrue(isCfgGatedOut(src, emptyFeatures()), "commented @cfg + real inactive @cfg → still gated by real one")
}

test "isCfgGatedOut: commented @cfg + real active @cfg → not gated" {
  val src = "// removed: @cfg(feature = \"old\")\n" + "@cfg(feature = \"redis\")\n" + "package Foo\n"
  assertTrue(not isCfgGatedOut(src, features1("redis")), "commented @cfg + real active @cfg → not gated")
}

test "isCfgGatedOut: active @cfgs followed by inactive @cfg → gated" {
  // Two active @cfgs first, then an inactive one. The scanner must keep
  // walking past the actives to find the inactive that actually gates.
  val src = "@cfg(feature = \"a\")\n" + "@cfg(feature = \"b\")\n" + "@cfg(feature = \"missing\")\n" + "package Foo\n"
  assertTrue(isCfgGatedOut(src, features2("a", "b")), "active @cfgs followed by inactive @cfg → gated")
}

test "any/all/not compositions gate a whole file" {
  val anySrc = "@cfg(any(feature = \"dotnet\", feature = \"native\"))\npackage P\n"
  assertTrue(isCfgGatedOut(anySrc, features1("jvm")), "any(...) with no active operand → gated")
  assertTrue(not isCfgGatedOut(anySrc, features1("native")), "any(...) with one active operand → not gated")
  val allSrc = "@cfg(all(feature = \"a\", feature = \"b\"))\npackage P\n"
  assertTrue(isCfgGatedOut(allSrc, features1("a")), "all(...) missing an operand → gated")
  assertTrue(not isCfgGatedOut(allSrc, features2("a", "b")), "all(...) fully active → not gated")
  val notSrc = "@cfg(not(feature = \"jvm\"))\npackage P\n"
  assertTrue(isCfgGatedOut(notSrc, features1("jvm")), "not(active) → gated")
  assertTrue(not isCfgGatedOut(notSrc, emptyFeatures()), "not(inactive) → not gated")
}

test "a target atom does not gate a file before the target is known" {
  val src = "@cfg(target = \"native\")\npackage P\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()), "target = X is left to per-target erasure")
}

test "a negated or composed target atom does not gate a file before the target is known" {
  val negated = "@cfg(not(target = \"jvm\"))\npackage P\n"
  assertTrue(not isCfgGatedOut(negated, emptyFeatures()), "not(target = X) must not erase the file on every target")
  val composed = "@cfg(not(all(feature = \"a\", target = \"jvm\")))\npackage P\n"
  assertTrue(
    not isCfgGatedOut(composed, features1("a")),
    "a composition containing a target atom is left to per-target erasure"
  )
  val mixed = "@cfg(feature = \"a\")\n@cfg(not(target = \"jvm\"))\npackage P\n"
  assertTrue(isCfgGatedOut(mixed, emptyFeatures()), "a feature-only @cfg on the same file still gates it")
}
