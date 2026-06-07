//! cfg_self_test.l — exercises the self-hosted `Lyric.Cfg` feature-erasure
//! pass against parsed `Lyric.Parser` source files.  Run in CI via native
//! `lyric test` (no F# runner shim).
@test_module
package Lyric.Cfg.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Cfg
import Lyric.TypeChecker

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────
func parseOk(src: in String): SourceFile {
  val pr = parse(src)
  if pr.diagnostics.count > 0 {
    panic("parseOk: parser produced diagnostics, refusing to test against ill-formed source")
  }
  pr.file
}

func emptyFeatures(): List[String] {
  newList()
}

func singletonList(s: in String): List[String] {
  val l: List[String] = newList()
  l.add(s)
  l
}

func twoFeatures(a: in String, b: in String): List[String] {
  val l: List[String] = newList()
  l.add(a)
  l.add(b)
  l
}

func diagCount(diags: in List[Diagnostic], code: in String): Int {
  var i = 0
  var n = 0
  while i < diags.count {
    if diags[i].code == code {
      n = n + 1
    }
    i = i + 1
  }
  n
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Tests
// ─────────────────────────────────────────────────────────────────────────────
// No @cfg annotations → no erasure, no diagnostics.
test "no annotations" {
  val src = "package P\n" + "pub func a(): Int { 1 }\n" + "pub func b(): Int { 2 }\n"
  val sf = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 2, "no_annotations: both items kept")
  assertEqualInt(res.diagnostics.count, 0, "no_annotations: no diagnostics")
}

// `@cfg(feature = "X")` where X is NOT in active set → item is erased.
test "inactive feature erases" {
  val src = "package P\n" + "@cfg(feature = \"experimental\")\n" + "pub func gated(): Int { 1 }\n" +
    "pub func ungated(): Int { 2 }\n"
  val sf = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 1, "inactive_feature_erases: only ungated remains")
}

// `@cfg(feature = "X")` where X IS in active set → item is kept.
test "active feature kept" {
  val src = "package P\n" + "@cfg(feature = \"experimental\")\n" + "pub func gated(): Int { 1 }\n"
  val sf = parseOk(src)
  val res = applyCfgErasure(singletonList("experimental"), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 1, "active_feature_kept: item kept")
}

// Two `@cfg` on the same item AND together: erased unless ALL features active.
test "and semantics" {
  val src = "package P\n" + "@cfg(feature = \"alpha\")\n" + "@cfg(feature = \"beta\")\n" +
    "pub func gated(): Int { 1 }\n" +
    "pub func ungated(): Int { 2 }\n"
  val sf = parseOk(src)
  // Only alpha active -> gated erased.
  val r1 = applyCfgErasure(singletonList("alpha"), emptyFeatures(), sf)
  assertEqualInt(r1.file.items.count, 1, "and_semantics: alpha-only erases gated")
  // Both alpha and beta active -> gated kept.
  val r2 = applyCfgErasure(twoFeatures("alpha", "beta"), emptyFeatures(), sf)
  assertEqualInt(r2.file.items.count, 2, "and_semantics: both keeps gated")
}

// F0012 fires for malformed predicates (literal arg, not `feature = "X"`).
test "f0012 malformed" {
  val src = "package P\n" + "@cfg(\"experimental\")\n" + "pub func gated(): Int { 1 }\n"
  val sf = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertTrue(diagCount(res.diagnostics, "F0012") > 0, "f0012_malformed: F0012 fires")
}

// F0013 fires for a feature reference absent from a NON-EMPTY declared set
// (typo guard).
test "f0013 typo" {
  val src = "package P\n" + "@cfg(feature = \"experimntal\")\n" + "pub func gated(): Int { 1 }\n"
  val sf = parseOk(src)
  // Declared has the correctly-spelled feature; the @cfg references the
  // misspelt one.
  val res = applyCfgErasure(emptyFeatures(), singletonList("experimental"), sf)
  assertTrue(diagCount(res.diagnostics, "F0013") > 0, "f0013_typo: F0013 fires")
}

// F0013 is SUPPRESSED when the declared set is empty (no manifest [features]
// table — the typo guard is opt-in via the declared set).
test "f0013 suppressed when declared empty" {
  val src = "package P\n" + "@cfg(feature = \"anything\")\n" + "pub func gated(): Int { 1 }\n"
  val sf = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(diagCount(res.diagnostics, "F0013"), 0, "f0013_suppressed_when_declared_empty: F0013 does not fire")
}

// File-level `@cfg` (annotation above the `package` decl) erases every
// item in the file when the feature is inactive.
test "file level erases entire file" {
  val src = "@cfg(feature = \"never\")\n" + "package P\n" + "pub func a(): Int { 1 }\n" + "pub func b(): Int { 2 }\n"
  val sf = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 0, "file_level_erases_entire_file: all items dropped")
  assertEqualInt(res.file.imports.count, 0, "file_level_erases_entire_file: imports dropped too")
}

// File-level `@cfg` whose feature IS active keeps the file intact.
test "file level keeps when active" {
  val src = "@cfg(feature = \"always\")\n" + "package P\n" + "pub func a(): Int { 1 }\n"
  val sf = parseOk(src)
  val res = applyCfgErasure(singletonList("always"), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 1, "file_level_keeps_when_active: item retained")
}

// Regression for #1472: a `@cfg(feature = "dotnet")` / `@cfg(feature = "jvm")`
// overload PAIR whose two overloads have DIFFERENT arities.  The bug was that
// the inactive-feature overload could leak into the typechecker's signature
// map (a cfg-erasure-vs-signature-registration ordering interaction), so a
// call using the active overload's arity mis-resolved against the inactive
// overload and surfaced a spurious `T0042 expected N argument(s), got M`.
//
// The contract this guards: erasure runs BEFORE signature registration, so
// after erasure only the active overload's arity is in scope.  We assert both
// directions through the real `Lyric.Cfg` + `Lyric.TypeChecker` pipeline:
//
//   * dotnet active  → the 3-arg overload survives, and `combine(1, 2, 3)`
//     resolves with NO T0042.
//   * jvm active      → only the 2-arg overload survives, so the same 3-arg
//     call is now a *genuine* arity error (exactly one T0042).  This second
//     assertion is the real teeth: it fails if the dotnet 3-arg overload is
//     silently kept (the inactive overload leaking back in), which is the
//     precise failure mode #1472 describes.
test "cfg overload arity resolution" {
  val src = "package P\n" + "@cfg(feature = \"jvm\")\n" + "pub func combine(a: in Int, b: in Int): Int { a + b }\n" +
    "@cfg(feature = \"dotnet\")\n" +
    "pub func combine(a: in Int, b: in Int, c: in Int): Int { a + b + c }\n" +
    "pub func useIt(): Int { combine(1, 2, 3) }\n"
  val sf = parseOk(src)
  val declared = twoFeatures("dotnet", "jvm")

  // dotnet active → the 3-arg overload survives; combine(1, 2, 3) resolves.
  val dotnetErase = applyCfgErasure(singletonList("dotnet"), declared, sf)
  assertEqualInt(dotnetErase.diagnostics.count, 0, "cfg_overload_arity: dotnet erasure emits no diagnostics")
  assertEqualInt(dotnetErase.file.items.count, 2, "cfg_overload_arity: dotnet keeps combine/3 + useIt")
  val dotnetCheck = check(dotnetErase.file)
  assertEqualInt(
    diagCount(dotnetCheck.diagnostics, "T0042"),
    0,
    "cfg_overload_arity: dotnet-active 3-arg call resolves with no T0042"
  )
  assertEqualInt(dotnetCheck.diagnostics.count, 0, "cfg_overload_arity: dotnet-active check produces zero diagnostics")

  // jvm active → only the 2-arg overload survives, so the 3-arg call in useIt
  // is now a genuine arity error — proving the dotnet overload was erased.
  val jvmErase = applyCfgErasure(singletonList("jvm"), declared, sf)
  assertEqualInt(jvmErase.diagnostics.count, 0, "cfg_overload_arity: jvm erasure emits no diagnostics")
  assertEqualInt(jvmErase.file.items.count, 2, "cfg_overload_arity: jvm keeps combine/2 + useIt")
  val jvmCheck = check(jvmErase.file)
  assertEqualInt(
    diagCount(jvmCheck.diagnostics, "T0042"),
    1,
    "cfg_overload_arity: jvm-active leaves only combine/2, 3-arg call is T0042"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Driver
// ─────────────────────────────────────────────────────────────────────────────
