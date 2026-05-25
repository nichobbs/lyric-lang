// cfg_self_test.l — exercises the self-hosted `Lyric.Cfg` feature-erasure
// pass against parsed `Lyric.Parser` source files.  Compiled and executed
// by SelfHostedCfgTests.fs.  Exit 0 + "ok" in stdout means every
// assertion held.

package Lyric.Cfg.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Cfg

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

func emptyFeatures(): List[String] { newList() }

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
    if diags[i].code == code { n = n + 1 }
    i = i + 1
  }
  n
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Tests
// ─────────────────────────────────────────────────────────────────────────────

// No @cfg annotations → no erasure, no diagnostics.
func testNoAnnotations(): Unit {
  val src =
    "package P\n" +
    "pub func a(): Int { 1 }\n" +
    "pub func b(): Int { 2 }\n"
  val sf  = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 2, "no_annotations: both items kept")
  assertEqualInt(res.diagnostics.count, 0, "no_annotations: no diagnostics")
}

// `@cfg(feature = "X")` where X is NOT in active set → item is erased.
func testInactiveFeatureErases(): Unit {
  val src =
    "package P\n" +
    "@cfg(feature = \"experimental\")\n" +
    "pub func gated(): Int { 1 }\n" +
    "pub func ungated(): Int { 2 }\n"
  val sf  = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 1, "inactive_feature_erases: only ungated remains")
}

// `@cfg(feature = "X")` where X IS in active set → item is kept.
func testActiveFeatureKept(): Unit {
  val src =
    "package P\n" +
    "@cfg(feature = \"experimental\")\n" +
    "pub func gated(): Int { 1 }\n"
  val sf  = parseOk(src)
  val res = applyCfgErasure(singletonList("experimental"), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 1, "active_feature_kept: item kept")
}

// Two `@cfg` on the same item AND together: erased unless ALL features active.
func testAndSemantics(): Unit {
  val src =
    "package P\n" +
    "@cfg(feature = \"alpha\")\n" +
    "@cfg(feature = \"beta\")\n" +
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
func testF0012Malformed(): Unit {
  val src =
    "package P\n" +
    "@cfg(\"experimental\")\n" +
    "pub func gated(): Int { 1 }\n"
  val sf  = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertTrue(diagCount(res.diagnostics, "F0012") > 0, "f0012_malformed: F0012 fires")
}

// F0013 fires for a feature reference absent from a NON-EMPTY declared set
// (typo guard).
func testF0013Typo(): Unit {
  val src =
    "package P\n" +
    "@cfg(feature = \"experimntal\")\n" +
    "pub func gated(): Int { 1 }\n"
  val sf  = parseOk(src)
  // Declared has the correctly-spelled feature; the @cfg references the
  // misspelt one.
  val res = applyCfgErasure(emptyFeatures(), singletonList("experimental"), sf)
  assertTrue(diagCount(res.diagnostics, "F0013") > 0, "f0013_typo: F0013 fires")
}

// F0013 is SUPPRESSED when the declared set is empty (no manifest [features]
// table — the typo guard is opt-in via the declared set).
func testF0013SuppressedWhenDeclaredEmpty(): Unit {
  val src =
    "package P\n" +
    "@cfg(feature = \"anything\")\n" +
    "pub func gated(): Int { 1 }\n"
  val sf  = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(diagCount(res.diagnostics, "F0013"), 0,
    "f0013_suppressed_when_declared_empty: F0013 does not fire")
}

// File-level `@cfg` (annotation above the `package` decl) erases every
// item in the file when the feature is inactive.
func testFileLevelErasesEntireFile(): Unit {
  val src =
    "@cfg(feature = \"never\")\n" +
    "package P\n" +
    "pub func a(): Int { 1 }\n" +
    "pub func b(): Int { 2 }\n"
  val sf  = parseOk(src)
  val res = applyCfgErasure(emptyFeatures(), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 0,
    "file_level_erases_entire_file: all items dropped")
  assertEqualInt(res.file.imports.count, 0,
    "file_level_erases_entire_file: imports dropped too")
}

// File-level `@cfg` whose feature IS active keeps the file intact.
func testFileLevelKeepsWhenActive(): Unit {
  val src =
    "@cfg(feature = \"always\")\n" +
    "package P\n" +
    "pub func a(): Int { 1 }\n"
  val sf  = parseOk(src)
  val res = applyCfgErasure(singletonList("always"), emptyFeatures(), sf)
  assertEqualInt(res.file.items.count, 1,
    "file_level_keeps_when_active: item retained")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Driver
// ─────────────────────────────────────────────────────────────────────────────

func main(): Int {
  testNoAnnotations()
  testInactiveFeatureErases()
  testActiveFeatureKept()
  testAndSemantics()
  testF0012Malformed()
  testF0013Typo()
  testF0013SuppressedWhenDeclaredEmpty()
  testFileLevelErasesEntireFile()
  testFileLevelKeepsWhenActive()
  println("cfg-self-test: ok")
  return 0
}
