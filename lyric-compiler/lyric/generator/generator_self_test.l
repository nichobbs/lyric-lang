//! generator/generator_self_test.l — exercises the supply-chain
//! enforcement helpers in `Lyric.Generator`.
//!
//! Run via `lyric test lyric-compiler/lyric/generator/generator_self_test.l`.
//! Replaces the F# SelfHostedGeneratorTests.fs wrapper (#2580).
@test_module
package Lyric.GeneratorSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Manifest
import Lyric.Generator

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
func parseOk(toml: in String, path: in String): Manifest {
  match parseManifest(toml, path) {
    case Ok(m) -> m
    case Err(_) -> panic("parseOk: unexpected manifest parse error in fixture")
  }
}

func consumerWithDep(): String {
  "[package]\nname = \"Consumer\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Foo.Bar\" = { path = \"../foo-bar\" }\n"
}

func consumerNoDeps(): String {
  "[package]\nname = \"Consumer\"\nversion = \"0.1.0\"\n"
}

func depGenerator(): String {
  "[package]\nname = \"Foo.Bar\"\nversion = \"0.1.0\"\nkind = \"source-generator\"\n"
}

func depWrongKind(): String {
  "[package]\nname = \"Foo.Bar\"\nversion = \"0.1.0\"\nkind = \"library\"\n"
}

func depNoKind(): String {
  "[package]\nname = \"Foo.Bar\"\nversion = \"0.1.0\"\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// G0008 — generator package not in [dependencies]
// ─────────────────────────────────────────────────────────────────────────────
func testG0008_DepNotDeclared(): Unit {
  val consumer = parseOk(consumerNoDeps(), "/test/consumer/lyric.toml")
  match checkGeneratorDeclaredIn(consumer, "Foo.Bar") {
    case Ok(_) -> assertTrue(false, "G0008: expected Err when dep not declared")
    case Err(e) -> {
      assertTrue(e.contains("G0008"), "G0008: diagnostic code present")
      assertTrue(e.contains("Foo.Bar"), "G0008: mentions generator package")
    }
  }
}

func testG0008_DepDeclared(): Unit {
  val consumer = parseOk(consumerWithDep(), "/test/consumer/lyric.toml")
  match checkGeneratorDeclaredIn(consumer, "Foo.Bar") {
    case Ok(d) -> assertEqual(d.name, "Foo.Bar", "G0008: returns matched dep entry")
    case Err(e) -> assertTrue(false, "G0008: unexpected Err: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// G0002 — kind enforcement
// ─────────────────────────────────────────────────────────────────────────────
func testG0002_KindMatches(): Unit {
  val depMf = parseOk(depGenerator(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(s) -> assertEqual(s, "", "G0002 happy path: Ok value is empty string sentinel")
    case Err(e) -> assertTrue(false, "G0002 happy path: unexpected Err: " + e)
  }
}

func testG0002_KindWrong(): Unit {
  val depMf = parseOk(depWrongKind(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(_) -> assertTrue(false, "G0002: expected Err for kind=\"library\"")
    case Err(e) -> {
      assertTrue(e.contains("G0002"), "G0002: diagnostic code present")
      assertTrue(e.contains("library"), "G0002: reports observed kind")
      assertTrue(e.contains("source-generator"), "G0002: mentions expected kind")
    }
  }
}

func testG0002_KindMissing(): Unit {
  val depMf = parseOk(depNoKind(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(_) -> assertTrue(false, "G0002: expected Err for missing kind")
    case Err(e) -> {
      assertTrue(e.contains("G0002"), "G0002: diagnostic code present")
      assertTrue(e.contains("missing"), "G0002: mentions 'missing'")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// scanDirectives — detection + false-positive guards (#698, #702)
// ─────────────────────────────────────────────────────────────────────────────
func testScanDirectives_DotInArg(): Unit {
  val src = "package P\n@generate(Foo.Bar)\npub record User { name: String }\n"
  val dirs = scanDirectives(src, "P")
  assertEqualInt(dirs.count, 1, "dotted directive detected")
  if dirs.count >= 1 {
    val d = dirs[0]
    assertEqual(d.generatorArg, "Foo.Bar", "dotted arg captured")
    assertEqual(d.typeName, "User", "type name captured")
    assertEqual(d.typeKind, "record", "type kind captured")
  }
}

func testScanDirectives_BareNameSkipped(): Unit {
  val src = "package P\n@generate(Json)\npub record User { name: String }\n"
  val dirs = scanDirectives(src, "P")
  assertEqualInt(dirs.count, 0, "bare-name generator stays out of the custom pipeline")
}

func testScanDirectives_StringLiteralIgnored(): Unit {
  // The @generate(Foo.Bar) sits inside a double-quoted literal and
  // must NOT trigger a directive (#702).
  val src = "package P\n" + "func help(): String { \"@generate(Foo.Bar) pub record Doc { x: Int }\" }\n" +
    "@generate(Foo.Bar)\n" +
    "pub record Real { y: Int }\n"
  val dirs = scanDirectives(src, "P")
  assertEqualInt(dirs.count, 1, "only the out-of-string directive fires")
  if dirs.count >= 1 {
    assertEqual(dirs[0].typeName, "Real", "the string-embedded directive was skipped")
  }
}

func testScanDirectives_LineCommentIgnored(): Unit {
  val src = "package P\n" + "// @generate(Foo.Bar) pub record Skip {}\n" + "@generate(Foo.Bar)\n" +
    "pub record Keep { x: Int }\n"
  val dirs = scanDirectives(src, "P")
  assertEqualInt(dirs.count, 1, "line-commented directive ignored")
  if dirs.count >= 1 {
    assertEqual(dirs[0].typeName, "Keep", "only the live directive surfaces")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// preprocess regression tests (#867 / #890).
//
// Both tests must JIT and run `preprocess` to completion — that's the
// load-bearing assertion.  If the F# bootstrap emitter regresses to the
// pre-#867 IL shape, calling `preprocess` from this self-test would
// throw `InvalidProgramException` before any assertion executes, and the
// test binary would exit non-zero with a clear stack trace pointing at
// `Lyric.Generator.Program.preprocess`.
// ─────────────────────────────────────────────────────────────────────────────
func testPreprocess_NoDirectives_PassesThrough(): Unit {
  val src = "package P\nfunc main(): Unit { println(\"hi\") }\n"
  match preprocess(src, "", "p.l") {
    case Ok(s) -> assertEqual(s, src, "no-directives: source returned unchanged")
    case Err(e) -> assertTrue(false, "no-directives: unexpected Err: " + e)
  }
}

func testPreprocess_DirectiveWithoutManifest_ReturnsErr(): Unit {
  val src = "package P\n" + "@generate(Foo.Bar)\n" + "pub record Order { id: Int }\n"
  match preprocess(src, "", "p.l") {
    case Ok(_) -> assertTrue(false, "missing-manifest: expected Err, got Ok")
    case Err(e) -> assertTrue(e.contains("--manifest"), "missing-manifest: error mentions --manifest (got: " + e + ")")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test items
// ─────────────────────────────────────────────────────────────────────────────
test "G0008 dep not declared" {
  testG0008_DepNotDeclared()
}

test "G0008 dep declared" {
  testG0008_DepDeclared()
}

test "G0002 kind matches" {
  testG0002_KindMatches()
}

test "G0002 kind wrong" {
  testG0002_KindWrong()
}

test "G0002 kind missing" {
  testG0002_KindMissing()
}

test "scan directives dot in arg" {
  testScanDirectives_DotInArg()
}

test "scan directives bare name skipped" {
  testScanDirectives_BareNameSkipped()
}

test "scan directives string literal ignored" {
  testScanDirectives_StringLiteralIgnored()
}

test "scan directives line comment ignored" {
  testScanDirectives_LineCommentIgnored()
}

test "preprocess no directives passes through" {
  testPreprocess_NoDirectives_PassesThrough()
}

test "preprocess directive without manifest returns err" {
  testPreprocess_DirectiveWithoutManifest_ReturnsErr()
}
