// generator/generator_self_test.l — exercises the supply-chain
// enforcement helpers in `Lyric.Generator`.  Compiled and executed by
// SelfHostedGeneratorTests.fs.  Exit 0 + "ok" in stdout means every
// assertion held.

package Lyric.Generator.SelfTest

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
    case Ok(m)  -> m
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
    case Ok(_)  -> assertTrue(false, "G0008: expected Err when dep not declared")
    case Err(e) -> {
      assertTrue(e.contains("G0008"), "G0008: diagnostic code present")
      assertTrue(e.contains("Foo.Bar"), "G0008: mentions generator package")
    }
  }
}

func testG0008_DepDeclared(): Unit {
  val consumer = parseOk(consumerWithDep(), "/test/consumer/lyric.toml")
  match checkGeneratorDeclaredIn(consumer, "Foo.Bar") {
    case Ok(d)  -> assertEqual(d.name, "Foo.Bar", "G0008: returns matched dep entry")
    case Err(e) -> assertTrue(false, "G0008: unexpected Err: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// G0002 — kind enforcement
// ─────────────────────────────────────────────────────────────────────────────

func testG0002_KindMatches(): Unit {
  val depMf = parseOk(depGenerator(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(_)  -> ()
    case Err(e) -> assertTrue(false, "G0002 happy path: unexpected Err: " + e)
  }
}

func testG0002_KindWrong(): Unit {
  val depMf = parseOk(depWrongKind(), "/test/foo-bar/lyric.toml")
  match checkGeneratorKind("Foo.Bar", "/test/foo-bar/lyric.toml", depMf) {
    case Ok(_)  -> assertTrue(false, "G0002: expected Err for kind=\"library\"")
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
    case Ok(_)  -> assertTrue(false, "G0002: expected Err for missing kind")
    case Err(e) -> {
      assertTrue(e.contains("G0002"), "G0002: diagnostic code present")
      assertTrue(e.contains("missing"), "G0002: mentions 'missing'")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

func main(): Int {
  testG0008_DepNotDeclared()
  testG0008_DepDeclared()
  testG0002_KindMatches()
  testG0002_KindWrong()
  testG0002_KindMissing()

  println("generator self-test: ok")
  return 0
}
