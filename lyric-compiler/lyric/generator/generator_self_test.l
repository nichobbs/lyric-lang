//! generator/generator_self_test.l — exercises `Lyric.Generator`: the
//! supply-chain checks, the directive scanner, response decoding and the
//! X-series diagnostics `preprocess` reports (D150).
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
// X0008 — generator package not in [dependencies]
// ─────────────────────────────────────────────────────────────────────────────
func testX0008_DepNotDeclared(): Unit {
  val consumer = parseOk(consumerNoDeps(), "/test/consumer/lyric.toml")
  match checkGeneratorDeclaredIn(consumer, "Foo.Bar") {
    case Ok(_) -> assertTrue(false, "X0008: expected Err when dep not declared")
    case Err(e) -> {
      assertTrue(e.contains("X0008"), "X0008: diagnostic code present")
      assertTrue(e.contains("Foo.Bar"), "X0008: mentions generator package")
    }
  }
}

func testX0008_DepDeclared(): Unit {
  val consumer = parseOk(consumerWithDep(), "/test/consumer/lyric.toml")
  match checkGeneratorDeclaredIn(consumer, "Foo.Bar") {
    case Ok(d) -> assertEqual(d.name, "Foo.Bar", "X0008: returns matched dep entry")
    case Err(e) -> assertTrue(false, "X0008: unexpected Err: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// X0002 — kind enforcement
// ─────────────────────────────────────────────────────────────────────────────
func testX0002_KindMatches(): Unit {
  val depMf = parseOk(depGenerator(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(s) -> assertEqual(s, "", "X0002 happy path: Ok value is empty string sentinel")
    case Err(e) -> assertTrue(false, "X0002 happy path: unexpected Err: " + e)
  }
}

func testX0002_KindWrong(): Unit {
  val depMf = parseOk(depWrongKind(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(_) -> assertTrue(false, "X0002: expected Err for kind=\"library\"")
    case Err(e) -> {
      assertTrue(e.contains("X0002"), "X0002: diagnostic code present")
      assertTrue(e.contains("library"), "X0002: reports observed kind")
      assertTrue(e.contains("source-generator"), "X0002: mentions expected kind")
    }
  }
}

func testX0002_KindMissing(): Unit {
  val depMf = parseOk(depNoKind(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(_) -> assertTrue(false, "X0002: expected Err for missing kind")
    case Err(e) -> {
      assertTrue(e.contains("X0002"), "X0002: diagnostic code present")
      assertTrue(e.contains("declares no"), "X0002: says no kind is declared")
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
  match preprocess(src, None, "p.l", emptyGeneratorSet()) {
    case Ok(res) -> assertEqual(res.source, src, "no-directives: source returned unchanged")
    case Err(e) -> assertTrue(false, "no-directives: unexpected Err: " + e)
  }
}

func testPreprocess_DirectiveWithoutManifest_ReturnsErr(): Unit {
  val src = "package P\n" + "@generate(Foo.Bar)\n" + "pub record Order { id: Int }\n"
  match preprocess(src, None, "p.l", emptyGeneratorSet()) {
    case Ok(_) -> assertTrue(false, "missing-manifest: expected Err, got Ok")
    case Err(e) -> {
      assertTrue(e.contains("error[X0008] 2:1:"), "missing-manifest: X0008 at the annotation (got: " + e + ")")
      assertTrue(e.contains("lyric.toml"), "missing-manifest: names the missing manifest")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test items
// ─────────────────────────────────────────────────────────────────────────────
test "X0008 dep not declared" {
  testX0008_DepNotDeclared()
}

test "X0008 dep declared" {
  testX0008_DepDeclared()
}

test "X0002 kind matches" {
  testX0002_KindMatches()
}

test "X0002 kind wrong" {
  testX0002_KindWrong()
}

test "X0002 kind missing" {
  testX0002_KindMissing()
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

// #7490: the compiler's own response parser rejects additionalImports
// entries that are not a single import statement.
test "generator imports: well-formed import statements are accepted" {
  assertTrue(isValidGeneratorImport("import Std.Json"), "plain import")
  assertTrue(isValidGeneratorImport("import extern System.Text.Json"), "import extern")
  assertTrue(isValidGeneratorImport("import MyApp.Models as M"), "aliased import")
}

test "generator imports: anything else is rejected" {
  assertFalse(isValidGeneratorImport("pub func backdoor(): Unit {}"), "a declaration")
  assertFalse(isValidGeneratorImport("import Std.Json\npub func x(): Unit {}"), "a second statement")
  assertFalse(isValidGeneratorImport("import Std..Json"), "empty segment")
  assertFalse(isValidGeneratorImport("import Std.Json as 1x"), "bad alias")
  assertFalse(isValidGeneratorImport("import "), "no name")
}

test "generator response with a smuggled statement in additionalImports is Err" {
  val json = "{\"lyricSource\":\"\",\"additionalImports\":[\"pub func backdoor(): Unit {}\"],\"diagnostics\":[]}"
  match parseResponseJson(json, "", 0, false) {
    case Ok(_) -> assertTrue(false, "a non-import entry must fail the response")
    case Err(e) -> assertTrue(e.contains("not a single import statement"), "message names the problem")
  }
  val ok = "{\"lyricSource\":\"\",\"additionalImports\":[\"import Std.Json\"],\"diagnostics\":[]}"
  match parseResponseJson(ok, "", 0, false) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "a valid import must be accepted: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// preprocess diagnostics (D150): each is reported at the annotation, and
// every failing directive is reported, not only the first.
// ─────────────────────────────────────────────────────────────────────────────
func consumerWith(deps: in String): Manifest {
  parseOk("[package]\nname = \"Consumer\"\nversion = \"0.1.0\"\n\n[dependencies]\n" + deps, "/test/app/lyric.toml")
}

func preprocessErr(src: in String, mf: in Manifest, gens: in GeneratorSet): String {
  match preprocess(src, Some(value = mf), "/test/app/src/app.l", gens) {
    case Ok(_) -> {
      assertTrue(false, "expected generator errors")
      ""
    }
    case Err(e) -> e
  }
}

test "X0001: @generate on something that is not a type" {
  val mf = consumerWith("\"Foo.Bar\" = { path = \"../foo-bar\" }\n")
  val e = preprocessErr("package P\n\n@generate(Foo.Bar)\nfunc helper(): Int { 1 }\n", mf, emptyGeneratorSet())
  assertTrue(e.contains("/test/app/src/app.l: error[X0001] 3:1:"), "X0001 with file and position: " + e)
}

test "X0008: a generator that is not declared" {
  val mf = consumerWith("")
  val e = preprocessErr("package P\n@generate(Foo.Bar)\nrecord R { x: Int }\n", mf, emptyGeneratorSet())
  assertTrue(e.contains("error[X0008] 2:1:"), "X0008 at the annotation: " + e)
  assertTrue(e.contains("Foo.Bar"), "names the generator")
}

test "X0002: a declared dependency that is not a generator" {
  val mf = consumerWith("\"Foo.Bar\" = { path = \"../foo-bar\" }\n")
  val gens = emptyGeneratorSet()
  gens.libraries["Foo.Bar"] = "library"
  val e = preprocessErr("package P\n@generate(Foo.Bar)\nrecord R { x: Int }\n", mf, gens)
  assertTrue(e.contains("error[X0002] 2:1:"), "X0002 at the annotation: " + e)
  assertTrue(e.contains("\"library\""), "reports the declared kind")
}

test "X0003 and X0009: a generator that could not be prepared is reported at each use" {
  val mf = consumerWith("\"Foo.Bar\" = { path = \"../foo-bar\" }\n\"Baz.Qux\" = \"1.0.0\"\n")
  val gens = emptyGeneratorSet()
  gens.failures["Foo.Bar"] = GeneratorFailure(
    code = "X0003",
    message = "source generator 'Foo.Bar' does not declare generate"
  )
  val src = "package P\n@generate(Foo.Bar)\nrecord A { x: Int }\n@generate(Baz.Qux)\nrecord B { y: Int }\n"
  val e = preprocessErr(src, mf, gens)
  assertTrue(e.contains("error[X0003] 2:1:"), "the first directive: " + e)
  assertTrue(e.contains("error[X0009] 4:1:"), "the second directive, a registry generator, is also reported")
  assertTrue(e.contains("registry or git generator is not supported"), "explains the registry case")
}

test "X0006: a generator package cannot be imported" {
  val mf = consumerWith("\"Foo.Bar\" = { path = \"../foo-bar\" }\n")
  val gens = emptyGeneratorSet()
  gens.dlls["Foo.Bar"] = "/nonexistent/Foo.Bar.dll"
  val e = preprocessErr("package P\n\nimport Foo.Bar\n\nfunc f(): Int { 1 }\n", mf, gens)
  assertTrue(e.contains("error[X0006] 3:1:"), "X0006 on the import line: " + e)
}

test "a generator response reports every diagnostic with its severity and code" {
  val json = "{\"lyricSource\":\"pub func f(): Int { 1 }\\n\",\"additionalImports\":[],\"diagnostics\":[" +
    "{\"severity\":\"Warning\",\"message\":\"careful\",\"code\":\"AD1\"}," +
    "{\"severity\":\"Error\",\"message\":\"broken\",\"code\":null}]}"
  match parseResponseJson(json, "", 0, false) {
    case Err(e) -> assertTrue(false, "a well-formed response decodes: " + e)
    case Ok(r) -> {
      assertEqual(r.lyricSource, "pub func f(): Int { 1 }\n", "the generated source")
      assertEqualInt(r.diagnostics.count, 2, "both diagnostics")
      assertEqual(r.diagnostics[0].severity, "Warning", "first severity")
      assertEqual(r.diagnostics[0].code, "AD1", "first code")
      assertEqual(r.diagnostics[1].message, "broken", "second message")
      assertEqual(r.diagnostics[1].code, "", "a null code is empty")
    }
  }
}

test "a generator response that is not usable says why" {
  match parseResponseJson("", "boom", 3, false) {
    case Ok(_) -> assertTrue(false, "no output is an error")
    case Err(e) -> assertTrue(e.contains("exited with code 3") and e.contains("boom"), "exit code and stderr: " + e)
  }
  match parseResponseJson("{not json", "", 0, false) {
    case Ok(_) -> assertTrue(false, "invalid JSON is an error")
    case Err(e) -> assertTrue(e.contains("not valid JSON"), "invalid JSON: " + e)
  }
  match parseResponseJson("{\"diagnostics\":[]}", "", 0, false) {
    case Ok(_) -> assertTrue(false, "a response without lyricSource is an error")
    case Err(e) -> assertTrue(e.contains("lyricSource"), "names the missing field: " + e)
  }
  match parseResponseJson("", "", 0, true) {
    case Ok(_) -> assertTrue(false, "a timeout is an error")
    case Err(e) -> assertTrue(e.contains("did not finish"), "timeout: " + e)
  }
}

test "scan directives keeps an annotation on a non-type, with its position" {
  val dirs = scanDirectives("package P\n\n  @generate(Foo.Bar)\nfunc f(): Int { 1 }\n", "P")
  assertEqualInt(dirs.count, 1, "the directive is kept")
  assertEqual(dirs[0].typeName, "", "with no type")
  assertEqualInt(dirs[0].line, 3, "line")
  assertEqualInt(dirs[0].column, 3, "column")
}
