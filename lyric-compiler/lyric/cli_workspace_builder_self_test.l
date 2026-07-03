//! cli_workspace_builder_self_test.l — regression coverage for
//! `Lyric.Cli.collectTransitiveDepDlls` (cli/workspace_builder.l), added to
//! fix T0010 errors on cross-DLL types in restored-package synthesis
//! (#4517).  The scenario: package B declares a `path` dependency on
//! package C; when B itself is used as a dependency of A, the synthesis
//! preamble for A must also see C's DLL (a transitive dependency), or a
//! type from C referenced through B's API surface fails to resolve
//! (T0010).  These tests exercise the filesystem-walking logic directly
//! against real (fixture) `lyric.toml` files and DLL stand-ins on disk —
//! no compilation is involved, so no `dotnet`/`java` toolchain is required.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_workspace_builder_self_test.l
@test_module
package Lyric.CliWorkspaceBuilderSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.String as Str
import Std.Environment as Environment
import Std.Uuid
import Std.Testing
import Lyric.Cli as Cli
import Lyric.Manifest as Mf
import Lyric.Emitter as Emitter

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-wsbuilder-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func writeFileOrPanic(path: in String, content: in String): Unit {
  match File.writeText(path, content) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

func mkPackageDir(root: in String, name: in String, tomlBody: in String): String {
  val dir = Path.join(root, name)
  match File.createDir(dir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create package dir " + dir + ": " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(dir, "lyric.toml"), tomlBody)
  dir
}

func touchBinDll(pkgDir: in String, dllFileName: in String): Unit {
  val binDir = Path.join(pkgDir, "bin")
  match File.createDir(binDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create bin dir " + binDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(binDir, dllFileName), "")
}

func listContainsPrefix(list: in List[String], prefix: in String): Bool {
  var i = 0
  while i < list.count {
    if Str.startsWith(list[i], prefix) {
      return true
    }
    i += 1
  }
  false
}

// B depends on C via `path = "../C"`; C's DLL is present on disk.  Walking
// B's dep tree from `collectTransitiveDepDlls` must discover C.
test "collectTransitiveDepDlls: path dep is discovered" {
  val root = freshTempDir("path-dep")
  val cDir = mkPackageDir(root, "C", "[package]\nname = \"Fixture.C\"\nversion = \"0.1.0\"\n")
  touchBinDll(cDir, "Fixture.C.dll")
  val bDir = mkPackageDir(
    root,
    "B",
    "[package]\nname = \"Fixture.B\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Fixture.C\" = { path = \"../C\" }\n"
  )

  val seen: List[String] = newList()
  val result: List[String] = newList()
  Cli.collectTransitiveDepDlls(bDir, None, seen, result)

  assertTrue(listContainsPrefix(seen, "Fixture.C"), "collectTransitiveDepDlls: seen contains Fixture.C")
  assertEqualInt(result.count, 1, "collectTransitiveDepDlls: exactly one transitive dep recorded")
  // Built via the same `Path.join(depDir, "../C")` the production code uses
  // (rather than the fixture's own canonical `cDir`), so this assertion does
  // not depend on whether `Path.join` normalizes `..` segments — it only
  // pins that the resolution formula matches what `addTransitiveDepFromDir`
  // actually computes.
  val expectedCDir = Path.join(bDir, "../C")
  assertEqual(
    result[0],
    "Fixture.C\t" + Path.join(Path.join(expectedCDir, "bin"), "Fixture.C.dll"),
    "collectTransitiveDepDlls: recorded name\\tpath entry for C"
  )

  cleanup(root)
}

// B -> C -> D: multi-level transitivity must be walked recursively, not
// just one hop.
test "collectTransitiveDepDlls: multi-level transitive chain" {
  val root = freshTempDir("multi-level")
  val dDir = mkPackageDir(root, "D", "[package]\nname = \"Fixture.D\"\nversion = \"0.1.0\"\n")
  touchBinDll(dDir, "Fixture.D.dll")
  val cDir = mkPackageDir(
    root,
    "C",
    "[package]\nname = \"Fixture.C\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Fixture.D\" = { path = \"../D\" }\n"
  )
  touchBinDll(cDir, "Fixture.C.dll")
  val bDir = mkPackageDir(
    root,
    "B",
    "[package]\nname = \"Fixture.B\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Fixture.C\" = { path = \"../C\" }\n"
  )

  val seen: List[String] = newList()
  val result: List[String] = newList()
  Cli.collectTransitiveDepDlls(bDir, None, seen, result)

  assertTrue(listContainsPrefix(seen, "Fixture.C"), "multi-level: seen contains Fixture.C")
  assertTrue(listContainsPrefix(seen, "Fixture.D"), "multi-level: seen contains Fixture.D (two hops away)")
  assertEqualInt(result.count, 2, "multi-level: both C and D recorded")

  cleanup(root)
}

// A missing DLL on disk (dep declared but never built) must be skipped
// rather than recorded with a bogus path.
test "collectTransitiveDepDlls: missing DLL is skipped" {
  val root = freshTempDir("missing-dll")
  val cDir = mkPackageDir(root, "C", "[package]\nname = \"Fixture.C\"\nversion = \"0.1.0\"\n")
  // Deliberately do NOT call touchBinDll(cDir, ...) — C's DLL was never built.
  val bDir = mkPackageDir(
    root,
    "B",
    "[package]\nname = \"Fixture.B\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Fixture.C\" = { path = \"../C\" }\n"
  )

  val seen: List[String] = newList()
  val result: List[String] = newList()
  Cli.collectTransitiveDepDlls(bDir, None, seen, result)

  assertEqualInt(result.count, 0, "missing-dll: nothing recorded when the DLL is absent")
  cleanup(root)
}

// A dependency name already present in `seen` (e.g. a direct dep of the
// top-level package) must not be re-added or re-walked — this is the
// dedup/cycle-avoidance behaviour `buildWorkspaceDeps` relies on.
test "collectTransitiveDepDlls: already-seen name is not re-added" {
  val root = freshTempDir("already-seen")
  val cDir = mkPackageDir(root, "C", "[package]\nname = \"Fixture.C\"\nversion = \"0.1.0\"\n")
  touchBinDll(cDir, "Fixture.C.dll")
  val bDir = mkPackageDir(
    root,
    "B",
    "[package]\nname = \"Fixture.B\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Fixture.C\" = { path = \"../C\" }\n"
  )

  val seen: List[String] = newList()
  seen.add("Fixture.C")
  val result: List[String] = newList()
  Cli.collectTransitiveDepDlls(bDir, None, seen, result)

  assertEqualInt(result.count, 0, "already-seen: pre-seeded name is not re-recorded")
  cleanup(root)
}

// #4925 regression: `lyric build`/`lyric test` crashed with
// `System.InvalidCastException: Unable to cast object of type
// 'Std.Core.Option_None`1[System.Object]' to type
// 'Std.Core.Option`1[Lyric.Workspace.WorkspaceContext]'` on ANY manifest
// outside a workspace (not specific to `[nuget]`, contrary to the issue's
// initial theory — confirmed by reproducing against the published 0.4.10
// binary with and without a `[nuget]` table).  Root cause: the early-return
// arm in `buildWorkspaceDeps` returned a bare `None` literal as the third
// tuple element; a `None` constructed directly inside a tuple loses its
// type argument under the bootstrap emitter, so the caller's
// `val (a, b, c) = buildWorkspaceDeps(...)` destructuring failed to cast it
// back to `Option[Ws.WorkspaceContext]`.  This test destructures the tuple
// exactly as `buildProject` (cli_build.l) and `cmdTestManifest` (cli_test.l)
// do, against a manifest with no `[workspace]` ancestor, so it reproduces
// the crash on the old code and passes on the fix.
test "buildWorkspaceDeps: outside a workspace returns cleanly instead of crashing on the tuple's Option element" {
  val root = freshTempDir("no-workspace")
  val mfPath = Path.join(root, "lyric.toml")
  writeFileOrPanic(
    mfPath,
    "[package]\nname = \"Fixture.NoWs\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Fixture.NoWs\"\n\n[project.packages]\n\"Fixture\" = \"src/main.l\"\n"
  )
  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> panic("cannot read " + mfPath + ": " + IOError.message(e))
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("cannot parse " + mfPath + ": " + ManifestError.message(e))
  }

  val (dllPaths, hadError, wsCtxOpt) = Cli.buildWorkspaceDeps(manifest, mfPath, Emitter.Dotnet)

  assertEqualInt(dllPaths.count, 0, "buildWorkspaceDeps: no workspace deps outside a workspace")
  assertFalse(hadError, "buildWorkspaceDeps: no build error outside a workspace")
  match wsCtxOpt {
    case Some(_) -> panic("buildWorkspaceDeps: expected None outside a workspace")
    case None -> ()
  }

  cleanup(root)
}
