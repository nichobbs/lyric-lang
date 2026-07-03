//! manifest_self_test.l — exercises the self-hosted `Lyric.Manifest` TOML
//! parser.
//!
//! Run via `lyric test lyric-compiler/lyric/manifest_self_test.l`.
//! Replaces the F# SelfHostedManifestTests.fs wrapper (#2580).
@test_module
package Lyric.Manifest.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Manifest

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────
// Local workaround for `ManifestError.message`: the associated function
// `ManifestError.message(e)` from `Lyric.Manifest` is not resolvable via
// cross-package type-checker dispatch in the self-hosted pipeline (#2580 / type
// checker associated-function gap).  This duplicate provides the same formatting
// for test diagnostics without hitting the gap.
func manifestErrorText(e: in ManifestError): String {
  match e {
    case ParseError(fp, ln, col, msg) -> fp + ":" + toString(ln) + ":" + toString(col) + ": " + msg
    case MissingField(section, field) -> "[" + section + "] missing required field '" + field + "'"
    case InvalidField(section, field, msg) -> "[" + section + "] invalid value for '" + field + "': " + msg
  }
}

func parseOk(toml: in String): Manifest {
  match parseManifest(toml, "<test>") {
    case Ok(m) -> m
    case Err(e) -> panic("parseOk: unexpected error: " + manifestErrorText(e))
  }
}

func parseErr(toml: in String): ManifestError {
  match parseManifest(toml, "<test>") {
    case Ok(_) -> panic("parseErr: expected error but got Ok")
    case Err(e) -> e
  }
}

func isParseError(e: in ManifestError): Bool {
  match e {
    case ParseError(_, _, _, _) -> true
    case _ -> false
  }
}

func isMissingField(e: in ManifestError, section: in String, field: in String): Bool {
  match e {
    case MissingField(s, f) -> s == section and f == field
    case _ -> false
  }
}

func isInvalidField(e: in ManifestError, section: in String, field: in String): Bool {
  match e {
    case InvalidField(s, f, _) -> s == section and f == field
    case _ -> false
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
    case None -> ()
    case Some(_) -> assertTrue(false, "minimal: no project section")
  }
  assertTrue(m.deps.count == 0, "minimal: no deps")
  match m.nuget {
    case None -> ()
    case Some(_) -> assertTrue(false, "minimal: no nuget section")
  }
  match m.maven {
    case None -> ()
    case Some(_) -> assertTrue(false, "minimal: no maven section")
  }
  match m.features {
    case None -> ()
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
// §4. [dependencies] section — registry (version string) form
// ─────────────────────────────────────────────────────────────────────────────
func testDependencies(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nFoo = \"1.2.3\"\nBar.Baz = \"^0.5\"\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 2, "deps: two entries")
  assertEqual(m.deps[0].name, "Foo", "deps: first name")
  match m.deps[0].source {
    case Registry(version) -> assertEqual(version, "1.2.3", "deps: first version")
    case _ -> assertTrue(false, "deps: first source should be Registry")
  }
  assertEqual(m.deps[1].name, "Bar.Baz", "deps: second name")
  match m.deps[1].source {
    case Registry(version) -> assertEqual(version, "^0.5", "deps: second version")
    case _ -> assertTrue(false, "deps: second source should be Registry")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4b. [dependencies] — workspace dep form
// ─────────────────────────────────────────────────────────────────────────────
func testWorkspaceDep(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Lyric.Cache\" = { workspace = true }\n\"Lyric.Web\" = { workspace = true, version = \"0.1.0\" }\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 2, "workspace-dep: two entries")
  assertEqual(m.deps[0].name, "Lyric.Cache", "workspace-dep: first name")
  match m.deps[0].source {
    case Workspace(versionOpt) -> {
      match versionOpt {
        case None -> ()
        case Some(_) -> assertTrue(false, "workspace-dep: first dep has no version constraint")
      }
    }
    case _ -> assertTrue(false, "workspace-dep: first source should be Workspace")
  }
  assertEqual(m.deps[1].name, "Lyric.Web", "workspace-dep: second name")
  match m.deps[1].source {
    case Workspace(versionOpt) -> {
      match versionOpt {
        case Some(v) -> assertEqual(v, "0.1.0", "workspace-dep: version constraint")
        case None -> assertTrue(false, "workspace-dep: second dep should have version constraint")
      }
    }
    case _ -> assertTrue(false, "workspace-dep: second source should be Workspace")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4c. [dependencies] — path dep form
// ─────────────────────────────────────────────────────────────────────────────
func testPathDep(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nMyLib = { path = \"../mylib\" }\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 1, "path-dep: one entry")
  assertEqual(m.deps[0].name, "MyLib", "path-dep: name")
  match m.deps[0].source {
    case Path(dir) -> assertEqual(dir, "../mylib", "path-dep: dir")
    case _ -> assertTrue(false, "path-dep: source should be Path")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4d. [dependencies] — git dep forms (tag, rev, branch, subdir)
// ─────────────────────────────────────────────────────────────────────────────
func testGitDepTag(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nSomeLib = { git = \"https://github.com/user/repo\", tag = \"v1.0.0\" }\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 1, "git-dep-tag: one entry")
  match m.deps[0].source {
    case Git(url, refKind, refValue, subdir) -> {
      assertEqual(url, "https://github.com/user/repo", "git-dep-tag: url")
      assertEqual(refKind, "tag", "git-dep-tag: ref kind")
      assertEqual(refValue, "v1.0.0", "git-dep-tag: tag name")
      match subdir {
        case None -> ()
        case Some(_) -> assertTrue(false, "git-dep-tag: no subdir")
      }
    }
    case _ -> assertTrue(false, "git-dep-tag: source should be Git")
  }
}

func testGitDepRev(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nSomeLib = { git = \"https://github.com/user/repo\", rev = \"abc1234\" }\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 1, "git-dep-rev: one entry")
  match m.deps[0].source {
    case Git(url, refKind, refValue, _) -> {
      assertEqual(url, "https://github.com/user/repo", "git-dep-rev: url")
      assertEqual(refKind, "rev", "git-dep-rev: ref kind")
      assertEqual(refValue, "abc1234", "git-dep-rev: rev SHA")
    }
    case _ -> assertTrue(false, "git-dep-rev: source should be Git")
  }
}

func testGitDepBranch(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nSomeLib = { git = \"https://github.com/user/repo\", branch = \"main\" }\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 1, "git-dep-branch: one entry")
  match m.deps[0].source {
    case Git(url, refKind, refValue, _) -> {
      assertEqual(url, "https://github.com/user/repo", "git-dep-branch: url")
      assertEqual(refKind, "branch", "git-dep-branch: ref kind")
      assertEqual(refValue, "main", "git-dep-branch: branch name")
    }
    case _ -> assertTrue(false, "git-dep-branch: source should be Git")
  }
}

func testGitDepSubdir(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Lyric.Cache\" = { git = \"https://github.com/nichobbs/lyric-lang\", tag = \"v0.1.0\", subdir = \"lyric-cache\" }\n"
  val m = parseOk(toml)
  assertEqualInt(m.deps.count, 1, "git-dep-subdir: one entry")
  match m.deps[0].source {
    case Git(url, refKind, refValue, subdir) -> {
      assertEqual(url, "https://github.com/nichobbs/lyric-lang", "git-dep-subdir: url")
      assertEqual(refKind, "tag", "git-dep-subdir: ref kind")
      assertEqual(refValue, "v0.1.0", "git-dep-subdir: tag name")
      match subdir {
        case Some(d) -> assertEqual(d, "lyric-cache", "git-dep-subdir: subdir")
        case None -> assertTrue(false, "git-dep-subdir: should have subdir")
      }
    }
    case _ -> assertTrue(false, "git-dep-subdir: source should be Git")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4e. [workspace] section
// ─────────────────────────────────────────────────────────────────────────────
func testWorkspaceSection(): Unit {
  val toml = "[workspace]\nexclude = [\"bootstrap\", \"docs\"]\n"
  // Two-level match avoids nested constructor patterns (case Ok(None) / case
  // Ok(Some(wr)) in a single match), which the self-hosted MSIL emitter does not
  // test recursively — the outer isinst for Ok passes regardless of the inner
  // Option value, causing Ok(None) to always win (#2580).
  match parseWorkspaceRoot(toml, "<test>") {
    case Err(e) -> assertTrue(false, "workspace-section: " + manifestErrorText(e))
    case Ok(wsOpt) -> {
      match wsOpt {
        case None -> assertTrue(false, "workspace-section: expected Some")
        case Some(wr) -> {
          assertEqualInt(wr.workspace.exclude.count, 2, "workspace-section: exclude count")
          assertEqual(wr.workspace.exclude[0], "bootstrap", "workspace-section: exclude[0]")
          assertEqual(wr.workspace.exclude[1], "docs", "workspace-section: exclude[1]")
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4f. [registry] section
// ─────────────────────────────────────────────────────────────────────────────
func testRegistrySection(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[registry]\ndotnet = \"https://pkgs.dev.azure.com/my-org/_packaging/my-feed/nuget/v3/index.json\"\n"
  val m = parseOk(toml)
  match m.registry {
    case None -> assertTrue(false, "registry: expected Some")
    case Some(rc) -> {
      match rc.dotnet {
        case Some(url) -> assertEqual(url, "https://pkgs.dev.azure.com/my-org/_packaging/my-feed/nuget/v3/index.json", "registry: dotnet url")
        case None -> assertTrue(false, "registry: expected dotnet url")
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. [nuget] section
// ─────────────────────────────────────────────────────────────────────────────
func testNuget(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[nuget]\nNewtonsoft.Json = \"13.0.1\"\nSerilog = \"3.1.1\"\n\n[nuget.options]\ntarget = \"net10.0\"\nallow_native = true\n"
  val m = parseOk(toml)
  match m.nuget {
    case None -> assertTrue(false, "nuget: expected Some")
    case Some(n) -> {
      assertEqualInt(n.entries.count, 2, "nuget: entry count")
      assertEqual(n.entries[0].name, "Newtonsoft.Json", "nuget: entry[0].name")
      assertEqual(n.entries[0].version, "13.0.1", "nuget: entry[0].version")
      assertEqual(n.entries[1].name, "Serilog", "nuget: entry[1].name")
      match n.target {
        case None -> assertTrue(false, "nuget: expected target")
        case Some(t) -> assertEqual(t, "net10.0", "nuget: target")
      }
      assertTrue(n.allowNative, "nuget: allow_native")
    }
  }
}

// A non-string, non-table entry value (e.g. an integer) is rejected rather
// than silently skipped (#2744).
func testNugetInvalidValueType(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[nuget]\nNewtonsoft.Json = 42\n"
  val e = parseErr(toml)
  assertTrue(isInvalidField(e, "nuget", "Newtonsoft.Json"), "nuget-invalid-value: InvalidField for integer value")
}

// An inline table without a 'version' key is rejected rather than silently
// skipped (#2744).
func testNugetTableMissingVersion(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[nuget]\nSerilog = { features = [\"sinks\"] }\n"
  val e = parseErr(toml)
  assertTrue(isInvalidField(e, "nuget", "Serilog"), "nuget-table-no-version: InvalidField for missing 'version' key")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5b. [maven] section (docs/31-maven-linking.md, D053)
// ─────────────────────────────────────────────────────────────────────────────
// Single coordinate; no [maven.options] -> repositories defaults to ["central"]
// and javaVersion is None.
func testMavenSingle(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"org.postgresql:postgresql\" = \"42.7.3\"\n"
  val m = parseOk(toml)
  match m.maven {
    case None -> assertTrue(false, "maven-single: expected Some")
    case Some(mv) -> {
      assertEqualInt(mv.entries.count, 1, "maven-single: entry count")
      assertEqual(mv.entries[0].group, "org.postgresql", "maven-single: group")
      assertEqual(mv.entries[0].artifact, "postgresql", "maven-single: artifact")
      assertEqual(mv.entries[0].version, "42.7.3", "maven-single: version")
      assertEqualInt(mv.repositories.count, 1, "maven-single: default repo count")
      assertEqual(mv.repositories[0], "central", "maven-single: default repo")
      match mv.javaVersion {
        case None -> ()
        case Some(_) -> assertTrue(false, "maven-single: javaVersion defaults to None")
      }
    }
  }
}

// Multiple coordinates plus [maven.options] (repositories + java_version).
func testMavenMultiple(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"com.fasterxml.jackson.core:jackson-databind\" = \"2.17.0\"\n\"org.slf4j:slf4j-api\" = \"2.0.12\"\n\n[maven.options]\nrepositories = [\"central\"]\njava_version = \"21\"\n"
  val m = parseOk(toml)
  match m.maven {
    case None -> assertTrue(false, "maven-multi: expected Some")
    case Some(mv) -> {
      assertEqualInt(mv.entries.count, 2, "maven-multi: entry count")
      assertEqual(mv.entries[0].group, "com.fasterxml.jackson.core", "maven-multi: group[0]")
      assertEqual(mv.entries[0].artifact, "jackson-databind", "maven-multi: artifact[0]")
      assertEqual(mv.entries[0].version, "2.17.0", "maven-multi: version[0]")
      assertEqual(mv.entries[1].group, "org.slf4j", "maven-multi: group[1]")
      assertEqual(mv.entries[1].artifact, "slf4j-api", "maven-multi: artifact[1]")
      assertEqual(mv.entries[1].version, "2.0.12", "maven-multi: version[1]")
      assertEqualInt(mv.repositories.count, 1, "maven-multi: repo count")
      assertEqual(mv.repositories[0], "central", "maven-multi: repo[0]")
      match mv.javaVersion {
        case Some(jv) -> assertEqual(jv, "21", "maven-multi: java_version")
        case None -> assertTrue(false, "maven-multi: expected java_version")
      }
    }
  }
}

// Extended { version = "..." } inline-table form, mirroring [nuget].
func testMavenExtended(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"com.google.guava:guava\" = { version = \"33.2.1-jre\" }\n"
  val m = parseOk(toml)
  match m.maven {
    case None -> assertTrue(false, "maven-extended: expected Some")
    case Some(mv) -> {
      assertEqualInt(mv.entries.count, 1, "maven-extended: entry count")
      assertEqual(mv.entries[0].group, "com.google.guava", "maven-extended: group")
      assertEqual(mv.entries[0].artifact, "guava", "maven-extended: artifact")
      assertEqual(mv.entries[0].version, "33.2.1-jre", "maven-extended: version")
    }
  }
}

// Absence of a [maven] table -> None.
func testMavenAbsent(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[nuget]\nNewtonsoft.Json = \"13.0.1\"\n"
  val m = parseOk(toml)
  match m.maven {
    case None -> ()
    case Some(_) -> assertTrue(false, "maven-absent: expected None when no [maven] table")
  }
}

// A -SNAPSHOT version is rejected at parse time (B0054).
func testMavenSnapshotRejected(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"org.example:lib\" = \"1.0.0-SNAPSHOT\"\n"
  val e = parseErr(toml)
  assertTrue(isInvalidField(e, "maven", "org.example:lib"), "maven-snapshot: InvalidField(maven, org.example:lib)")
}

// [native] table: triple, opt_level, extra_libs (N6.4).
func testNativeSection(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[native]\ntriple = \"x86_64-unknown-linux-gnu\"\nopt_level = \"3\"\nextra_libs = [\"ssl\", \"crypto\"]\n"
  val m = parseOk(toml)
  match m.native {
    case None -> assertTrue(false, "native: expected Some")
    case Some(nc) -> {
      assertEqual(nc.triple, "x86_64-unknown-linux-gnu", "native: triple")
      assertEqual(nc.optLevel, "3", "native: opt_level")
      assertEqualInt(nc.extraLibs.count, 2, "native: extra_libs count")
      assertEqual(nc.extraLibs[0], "ssl", "native: extra_libs[0]")
      assertEqual(nc.extraLibs[1], "crypto", "native: extra_libs[1]")
    }
  }
}

// Partial [native] table: fields not set take their defaults (empty
// triple/opt, no libs) — the build layer then substitutes host triple and
// -O2.  (A header-only [native] table with no keys parses to None, like
// an empty [maven]/[nuget]; that is the `native absent` case.)
func testNativeDefaults(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[native]\ntriple = \"aarch64-apple-darwin\"\n"
  val m = parseOk(toml)
  match m.native {
    case None -> assertTrue(false, "native-defaults: expected Some when [native] sets a key")
    case Some(nc) -> {
      assertEqual(nc.triple, "aarch64-apple-darwin", "native-defaults: triple")
      assertEqual(nc.optLevel, "", "native-defaults: opt_level defaults to empty")
      assertEqualInt(nc.extraLibs.count, 0, "native-defaults: no extra_libs")
    }
  }
}

// Absence of a [native] table -> None.
func testNativeAbsent(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n"
  val m = parseOk(toml)
  match m.native {
    case None -> ()
    case Some(_) -> assertTrue(false, "native-absent: expected None when no [native] table")
  }
}

// A header-only [native] table with no key-value entries -> None, exactly
// like an empty [maven]/[nuget] (hasSection needs at least one entry), so
// the build layer applies its built-in defaults (#4862).
func testNativeEmptyTable(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[native]\n"
  val m = parseOk(toml)
  match m.native {
    case None -> ()
    case Some(_) -> assertTrue(false, "native-empty: header-only [native] table parses to None")
  }
}

// An out-of-range opt_level is rejected at parse time.
func testNativeInvalidOpt(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[native]\nopt_level = \"9\"\n"
  val e = parseErr(toml)
  assertTrue(isInvalidField(e, "native", "opt_level"), "native-invalid-opt: InvalidField(native, opt_level)")
}

// An extra_libs entry with whitespace (or empty) is rejected at parse time
// (#4865) — it would otherwise become a broken `-l<name>` clang flag.
func testNativeInvalidLib(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[native]\nextra_libs = [\"ssl bad\"]\n"
  val e = parseErr(toml)
  assertTrue(isInvalidField(e, "native", "extra_libs"), "native-invalid-lib: InvalidField(native, extra_libs)")
}

// Malformed coordinate keys (no ':' or more than one ':') are rejected.
func testMavenMalformedCoordinate(): Unit {
  val noColon = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"just-an-artifact\" = \"1.0.0\"\n"
  val e1 = parseErr(noColon)
  assertTrue(isInvalidField(e1, "maven", "just-an-artifact"), "maven-malformed: InvalidField for missing ':'")

  val twoColons = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"a:b:c\" = \"1.0.0\"\n"
  val e2 = parseErr(twoColons)
  assertTrue(isInvalidField(e2, "maven", "a:b:c"), "maven-malformed: InvalidField for two ':'")

  // Empty-half variants: ':artifact' (empty group) and 'group:' (empty artifact).
  // These are distinct validation branches from the no-colon / two-colon cases.
  val emptyGroup = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\":my-artifact\" = \"1.0.0\"\n"
  val e3 = parseErr(emptyGroup)
  assertTrue(isInvalidField(e3, "maven", ":my-artifact"), "maven-malformed: InvalidField for empty group half")

  val emptyArtifact = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"com.example:\" = \"1.0.0\"\n"
  val e4 = parseErr(emptyArtifact)
  assertTrue(isInvalidField(e4, "maven", "com.example:"), "maven-malformed: InvalidField for empty artifact half")
}

// A non-string, non-table entry value (e.g. an integer) is rejected rather
// than silently skipped (#2744).
func testMavenInvalidValueType(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"com.example:lib\" = 42\n"
  val e = parseErr(toml)
  assertTrue(isInvalidField(e, "maven", "com.example:lib"), "maven-invalid-value: InvalidField for integer value")
}

// An inline table without a 'version' key is rejected rather than silently
// skipped (#2744).
func testMavenTableMissingVersion(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[maven]\n\"com.example:lib\" = { classifier = \"tests\" }\n"
  val e = parseErr(toml)
  assertTrue(
    isInvalidField(e, "maven", "com.example:lib"),
    "maven-table-no-version: InvalidField for missing 'version' key"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. [project] section
// ─────────────────────────────────────────────────────────────────────────────
func testProject(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[project]\nname = \"MyApp\"\noutput = \"exe\"\n\n[project.packages]\nCore = \"../core\"\nUtils = \"../utils\"\n"
  val m = parseOk(toml)
  match m.project {
    case None -> assertTrue(false, "project: expected Some")
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

func testProjectMultiFilePkg(): Unit {
  val toml = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[project]\nname = \"MyApp\"\noutput = \"exe\"\n\n[project.packages]\nCore = \"../core\"\nLambda = [\"src/lambda.l\", \"src/lambda_web.l\"]\n"
  val m = parseOk(toml)
  match m.project {
    case None -> assertTrue(false, "multi-file pkg: expected Some project")
    case Some(p) -> {
      assertEqualInt(p.packages.count, 2, "multi-file pkg: packages count")
      assertEqual(p.packages[0].name, "Core", "multi-file pkg: pkg[0].name")
      assertEqual(p.packages[0].path, "../core", "multi-file pkg: pkg[0].path single")
      assertEqualInt(p.packages[0].paths.count, 0, "multi-file pkg: pkg[0].paths empty for single")
      assertEqual(p.packages[1].name, "Lambda", "multi-file pkg: pkg[1].name")
      assertEqualInt(p.packages[1].paths.count, 2, "multi-file pkg: pkg[1].paths count")
      assertEqual(p.packages[1].paths[0], "src/lambda.l", "multi-file pkg: pkg[1].paths[0]")
      assertEqual(p.packages[1].paths[1], "src/lambda_web.l", "multi-file pkg: pkg[1].paths[1]")
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
    case None -> assertTrue(false, "features: expected Some")
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

// CRLF (`\r\n`) line endings parse identically to LF — regression test for
// the `skipWhitespace` fix that treats `\r` as horizontal whitespace so a
// Windows checkout of a manifest doesn't fail with "unexpected character
// '\r'" (#3940).
func testCrlfLineEndings(): Unit {
  val toml = "[package]\r\nname = \"foo\"\r\nversion = \"0.1.0\"\r\n"
  val m = parseOk(toml)
  assertEqual(m.packageSection.name, "foo", "crlf: name parsed")
  assertEqual(m.packageSection.version, "0.1.0", "crlf: version parsed")
}

// CRLF tolerance also applies past the [package] section: dependencies,
// comments, and inline tables all sit behind the same `skipWhitespace` call.
func testCrlfFullManifest(): Unit {
  val toml = "# top comment\r\n[package]\r\nname = \"app\"\r\nversion = \"0.1.0\"\r\n\r\n" +
    "[dependencies]\r\nFoo = \"1.2.3\"\r\n\r\n[nuget]\r\nSerilog = \"3.1.1\" # trailing\r\n"
  val m = parseOk(toml)
  assertEqual(m.packageSection.name, "app", "crlf-full: name parsed")
  assertEqualInt(m.deps.count, 1, "crlf-full: one dependency")
  assertEqual(m.deps[0].name, "Foo", "crlf-full: dep name")
  match m.nuget {
    case None -> assertTrue(false, "crlf-full: expected nuget section")
    case Some(n) -> assertEqualInt(n.entries.count, 1, "crlf-full: one nuget entry")
  }
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
// §11. Error message formatting smoke test — exercises each ManifestError
// variant via the local manifestErrorText helper (mirrors ManifestError.message
// from Lyric.Manifest; the cross-package associated function is not resolvable
// in the self-hosted pipeline, #2580).
// ─────────────────────────────────────────────────────────────────────────────
func testErrorMessage(): Unit {
  val e1 = MissingField(section = "package", field = "name")
  val msg1 = manifestErrorText(e1)
  assertTrue(msg1.length > 0, "error-message: MissingField non-empty")
  val e2 = InvalidField(section = "package", field = "version", message = "bad")
  val msg2 = manifestErrorText(e2)
  assertTrue(msg2.length > 0, "error-message: InvalidField non-empty")
  val e3 = ParseError(filePath = "f", line = 1, column = 1, message = "unexpected")
  val msg3 = manifestErrorText(e3)
  assertTrue(msg3.length > 0, "error-message: ParseError non-empty")
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
// Test items
// ─────────────────────────────────────────────────────────────────────────────
test "minimal manifest" {
  testMinimal()
}

test "full package section" {
  testFullPackage()
}

test "dependencies registry form" {
  testDependencies()
}

test "workspace dep" {
  testWorkspaceDep()
}

test "path dep" {
  testPathDep()
}

test "git dep tag" {
  testGitDepTag()
}

test "git dep rev" {
  testGitDepRev()
}

test "git dep branch" {
  testGitDepBranch()
}

test "git dep subdir" {
  testGitDepSubdir()
}

test "workspace section" {
  testWorkspaceSection()
}

test "registry section" {
  testRegistrySection()
}

test "nuget section" {
  testNuget()
}

test "nuget invalid value type" {
  testNugetInvalidValueType()
}

test "nuget table missing version" {
  testNugetTableMissingVersion()
}

test "maven single entry" {
  testMavenSingle()
}

test "maven multiple entries" {
  testMavenMultiple()
}

test "maven extended options" {
  testMavenExtended()
}

test "maven absent" {
  testMavenAbsent()
}

test "maven snapshot rejected" {
  testMavenSnapshotRejected()
}

test "maven malformed coordinate" {
  testMavenMalformedCoordinate()
}

test "maven invalid value type" {
  testMavenInvalidValueType()
}

test "maven table missing version" {
  testMavenTableMissingVersion()
}

test "native section" {
  testNativeSection()
}

test "native defaults" {
  testNativeDefaults()
}

test "native absent" {
  testNativeAbsent()
}

test "native empty table" {
  testNativeEmptyTable()
}

test "native invalid opt_level" {
  testNativeInvalidOpt()
}

test "native invalid extra_libs" {
  testNativeInvalidLib()
}

test "project section" {
  testProject()
}

test "project multi-file package (VStrList)" {
  testProjectMultiFilePkg()
}

test "features section" {
  testFeatures()
}

test "comments and whitespace" {
  testComments()
}

test "CRLF line endings" {
  testCrlfLineEndings()
}

test "CRLF full manifest" {
  testCrlfFullManifest()
}

test "missing name error" {
  testMissingName()
}

test "missing version error" {
  testMissingVersion()
}

test "filePath recorded" {
  testFilePath()
}

test "error message formatting" {
  testErrorMessage()
}

test "unknown section ignored" {
  testUnknownSectionIgnored()
}
