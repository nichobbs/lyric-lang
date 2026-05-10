// manifest_self_test.l — exercises the self-hosted `Lyric.Manifest` TOML
// parser.  Compiled and executed by SelfHostedManifestTests.fs.
// Exit 0 + "ok" in stdout means every assertion held.

package Lyric.Manifest.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Manifest

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────

func parseOk(toml: in String): Manifest {
  match parse(toml, "<test>") {
    case Ok(m)  -> m
    case Err(e) -> panic("parseOk: unexpected error: " + ManifestError.message(e))
  }
}

func parseErr(toml: in String): ManifestError {
  match parse(toml, "<test>") {
    case Ok(_)  -> panic("parseErr: expected error but got Ok")
    case Err(e) -> e
  }
}

func isParseError(e: in ManifestError): Bool {
  match e {
    case ParseError(_, _, _, _) -> true
    case _                      -> false
  }
}

func isMissingField(e: in ManifestError, section: in String, field: in String): Bool {
  match e {
    case MissingField(s, f) -> s == section and f == field
    case _                  -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Minimal manifest — only [package] section
// ─────────────────────────────────────────────────────────────────────────────

func testMinimal(): Unit {
  val toml = "[package]\nname = \"hello\"\nversion = \"1.0.0\"\n"
  val m = parseOk(toml)
  assertEqual(m.packageSection.name, "hello", "minimal: name")
  assertEqual(m.packageSection.version, "1.0.0", "minimal: version")
  assertEqual(m.packageSection.description, "", "minimal: description defaults to empty")
  assertEqual(m.packageSection.license, "", "minimal: license defaults to empty")
  assertTrue(m.packageSection.authors.count == 0, "minimal: no authors")
  match m.project {
    case None    -> ()
    case Some(_) -> assertTrue(false, "minimal: no project section")
  }
  assertTrue(m.deps.count == 0, "minimal: no deps")
  match m.nuget {
    case None    -> ()
    case Some(_) -> assertTrue(false, "minimal: no nuget section")
  }
  match m.features {
    case None    -> ()
    case Some(_) -> assertTrue(false, "minimal: no features section")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Full [package] section with all optional fields
// ─────────────────────────────────────────────────────────────────────────────

func testFullPackage(): Unit {
  val toml = "[package]\nname = \"my-pkg\"\nversion = \"0.2.1\"\ndescription = \"A sample package\"\nauthors = [\"Alice\", \"Bob\"]\nlicense = \"MIT\"\n"
  val m = parseOk(toml)
  assertEqual(m.packageSection.name, "my-pkg", "full-pkg: name")
  assertEqual(m.packageSection.version, "0.2.1", "full-pkg: version")
  assertEqual(m.packageSection.description, "A sample package", "full-pkg: description")
  assertEqual(m.packageSection.license, "MIT", "full-pkg: license")
  assertEqualInt(m.packageSection.authors.count, 2, "full-pkg: author count")
  assertEqual(m.packageSection.authors[0], "Alice", "full-pkg: author[0]")
  assertEqual(m.packageSection.authors[1], "Bob", "full-pkg: author[1]")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. [dependencies] section
// ─────────────────────────────────────────────────────────────────────────────

func testDependencies(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nFoo = \"1.2.3\"\nBar.Baz = \"^0.5\"\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 2, "deps: two entries")
  assertEqual(m.deps[0].name, "Foo", "deps: first name")
  assertEqual(m.deps[0].version, "1.2.3", "deps: first version")
  assertEqual(m.deps[1].name, "Bar.Baz", "deps: second name")
  assertEqual(m.deps[1].version, "^0.5", "deps: second version")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. [nuget] section
// ─────────────────────────────────────────────────────────────────────────────

func testNuget(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[nuget]\nNewtonsoft.Json = \"13.0.1\"\nSerilog = \"3.1.1\"\n\n[nuget.options]\ntarget = \"net10.0\"\nallow_native = true\n"
  val m = parseOk(toml)
  match m.nuget {
    case None    -> assertTrue(false, "nuget: expected Some")
    case Some(n) -> {
      assertEqualInt(n.entries.count, 2, "nuget: entry count")
      assertEqual(n.entries[0].name, "Newtonsoft.Json", "nuget: entry[0].name")
      assertEqual(n.entries[0].version, "13.0.1", "nuget: entry[0].version")
      assertEqual(n.entries[1].name, "Serilog", "nuget: entry[1].name")
      match n.target {
        case None    -> assertTrue(false, "nuget: expected target")
        case Some(t) -> assertEqual(t, "net10.0", "nuget: target")
      }
      assertTrue(n.allowNative, "nuget: allow_native")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. [project] section
// ─────────────────────────────────────────────────────────────────────────────

func testProject(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[project]\nname = \"MyApp\"\noutput = \"exe\"\n\n[project.packages]\nCore = \"../core\"\nUtils = \"../utils\"\n"
  val m = parseOk(toml)
  match m.project {
    case None    -> assertTrue(false, "project: expected Some")
    case Some(p) -> {
      assertEqual(p.name, "MyApp", "project: name")
      assertEqual(p.output, "exe", "project: output")
      assertEqualInt(p.packages.count, 2, "project: packages count")
      assertEqual(p.packages[0].name, "Core", "project: pkg[0].name")
      assertEqual(p.packages[0].path, "../core", "project: pkg[0].path")
      assertEqual(p.packages[1].name, "Utils", "project: pkg[1].path")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. [features] section
// ─────────────────────────────────────────────────────────────────────────────

func testFeatures(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[features]\ndefault = [\"logging\"]\nlogging = []\nmetrics = []\n"
  val m = parseOk(toml)
  match m.features {
    case None    -> assertTrue(false, "features: expected Some")
    case Some(f) -> {
      assertTrue(f.declared.count >= 2, "features: at least 2 declared")
      assertTrue(f.defaults.count >= 1, "features: at least 1 default")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Comments and whitespace tolerance
// ─────────────────────────────────────────────────────────────────────────────

func testComments(): Unit {
  val toml = "# Top-level comment\n[package]\n# inline comment\nname = \"hello\" # trailing comment\nversion = \"1.0.0\"\n"
  val m = parseOk(toml)
  assertEqual(m.packageSection.name, "hello", "comments: name parsed")
  assertEqual(m.packageSection.version, "1.0.0", "comments: version parsed")
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Error: missing required [package] section fields
// ─────────────────────────────────────────────────────────────────────────────

func testMissingName(): Unit {
  val toml = "[package]\nversion = \"1.0.0\"\n"
  val e = parseErr(toml)
  assertTrue(isMissingField(e, "package", "name"), "missing-name: MissingField(package, name)")
}

func testMissingVersion(): Unit {
  val toml = "[package]\nname = \"mylib\"\n"
  val e = parseErr(toml)
  assertTrue(isMissingField(e, "package", "version"), "missing-version: MissingField(package, version)")
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. filePath is recorded correctly
// ─────────────────────────────────────────────────────────────────────────────

func testFilePath(): Unit {
  val toml = "[package]\nname = \"x\"\nversion = \"0.0.1\"\n"
  val m = parseOk(toml)
  assertEqual(m.filePath, "<test>", "filepath: stored verbatim")
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. ManifestError.message smoke test
// ─────────────────────────────────────────────────────────────────────────────

func testErrorMessage(): Unit {
  val e = MissingField(section = "package", field = "name")
  val msg = ManifestError.message(e)
  assertTrue(msg.length > 0, "error-message: non-empty")
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Unknown sections are silently ignored
// ─────────────────────────────────────────────────────────────────────────────

func testUnknownSectionIgnored(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"1.0.0\"\n\n[unknown_section]\nsome_key = \"some_value\"\n"
  val m = parseOk(toml)
  assertEqual(m.packageSection.name, "app", "unknown-section: name unchanged")
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

func main(): Unit {
  testMinimal()
  testFullPackage()
  testDependencies()
  testNuget()
  testProject()
  testFeatures()
  testComments()
  testMissingName()
  testMissingVersion()
  testFilePath()
  testErrorMessage()
  testUnknownSectionIgnored()
  println("manifest self-test: ok")
}
