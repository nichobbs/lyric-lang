//! cli_shared_self_test.l — exercises `Lyric.Cli.resolveNugetAssets`
//! (cli/cli_shared.l), the `project.assets.json` reader used by
//! `buildProject` / `cmdTestManifest` to locate restored NuGet assembly
//! DLLs.  The underlying JSON navigation (`extractPackagesPathFromYaml`,
//! `extractDllPathsFromYaml`) is private, so these tests drive it through
//! the public `resolveNugetAssets` entry point against real fixture files
//! on disk — the same code path `lyric build`/`lyric test` exercise for a
//! real restore (#4340).
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_shared_self_test.l
@test_module
package Lyric.CliSharedSelfTest

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

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-cli-shared-" + label + "-" + uuidToString(newUuid()))
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

// Writes `pkgsDir/<lowerPkgName>/<pkgVersion>/<relDllPath>` (with empty
// content) and creates every intermediate directory, mirroring the layout
// `extractDllPathsFromYaml` expects under a NuGet global-packages folder.
func touchNugetDll(pkgsDir: in String, pkgName: in String, pkgVersion: in String, relDllPath: in String): String {
  val full = Path.join(pkgsDir, Path.join(Path.join(pkgName.toLower(), pkgVersion), relDllPath))
  val dir = Path.dirname(full)
  match File.createDir(dir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir " + dir + ": " + IOError.message(e))
  }
  writeFileOrPanic(full, "")
  full
}

func listContains(list: in List[String], value: in String): Bool {
  var i = 0
  while i < list.count {
    if list[i] == value {
      return true
    }
    i += 1
  }
  false
}

test "resolveNugetAssets: no obj/project.assets.json yields an empty list" {
  val mfDir = freshTempDir("no-assets")
  defer { cleanup(mfDir) }
  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetAssets: missing project.assets.json")
}

test "resolveNugetAssets: malformed JSON yields an empty list" {
  val mfDir = freshTempDir("malformed")
  defer { cleanup(mfDir) }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), "{ not valid json ][")
  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetAssets: malformed JSON")
}

// Realistic pretty-printed `dotnet restore` output — packagesPath under
// `project.restore`, a package-typed target entry with a runtime DLL, and a
// project-typed entry (a referenced local project, not a package) that must
// be excluded from the result.
test "resolveNugetAssets: happy path resolves a real runtime DLL and skips non-package entries" {
  val mfDir = freshTempDir("happy-path")
  defer { cleanup(mfDir) }
  val pkgsDir = freshTempDir("happy-path-pkgs")
  defer { cleanup(pkgsDir) }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }

  val dllPath = touchNugetDll(pkgsDir, "Newtonsoft.Json", "13.0.3", "lib/netstandard2.0/Newtonsoft.Json.dll")

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"Newtonsoft.Json/13.0.3\": {\n" + "        \"type\": \"package\",\n" + "        \"runtime\": {\n" +
    "          \"lib/netstandard2.0/Newtonsoft.Json.dll\": {}\n" + "        }\n" + "      },\n" +
    "      \"Fixture.LocalProject/1.0.0\": {\n" + "        \"type\": \"project\",\n" + "        \"runtime\": {\n" +
    "          \"bin/Fixture.LocalProject.dll\": {}\n" + "        }\n" + "      }\n" + "    }\n" + "  },\n" +
    "  \"project\": {\n" + "    \"restore\": {\n" + "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") + "\"\n" + "    }\n" + "  }\n" + "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 1, "resolveNugetAssets: only the package-typed runtime DLL is resolved")
  assertTrue(listContains(paths, dllPath), "resolveNugetAssets: resolved path matches the fixture DLL on disk")
}

// A `runtime` entry whose DLL was never materialised on disk (declared in
// the assets file but not actually restored) must be skipped rather than
// returned as a dangling path.
test "resolveNugetAssets: runtime entry with no file on disk is skipped" {
  val mfDir = freshTempDir("missing-dll")
  defer { cleanup(mfDir) }
  val pkgsDir = freshTempDir("missing-dll-pkgs")
  defer { cleanup(pkgsDir) }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }
  // Deliberately do NOT create the DLL file under pkgsDir.

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"Widget/1.0.0\": {\n" + "        \"type\": \"package\",\n" + "        \"runtime\": {\n" +
    "          \"lib/netstandard2.0/Widget.dll\": {}\n" + "        }\n" + "      }\n" + "    }\n" + "  },\n" +
    "  \"project\": {\n" + "    \"restore\": {\n" + "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") + "\"\n" + "    }\n" + "  }\n" + "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetAssets: DLL declared but absent on disk yields no paths")
}

test "resolveNugetAssets: empty targets yields an empty list" {
  val mfDir = freshTempDir("empty-targets")
  defer { cleanup(mfDir) }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), "{\n  \"targets\": {},\n  \"project\": {}\n}\n")
  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetAssets: no targets")
}

func oneEntryNugetSection(): Mf.NugetSection {
  val entries: List[Mf.NugetEntry] = newList()
  entries.add(Mf.NugetEntry(name = "Widget", version = "1.0.0"))
  Mf.NugetSection(entries = entries, target = None, allowNative = false)
}

func expectSome(reason: in Option[String], label: in String): String {
  match reason {
    case Some(r) -> r
    case None -> panic(label + ": expected Some(reason), got None")
  }
}

// The scenario #4770 flagged as untested: `project.assets.json` exists and
// parses cleanly (it is not missing) but resolves to zero package DLLs — the
// stale/corrupt case `nugetUnresolvedReason` was extended to cover alongside
// the pre-existing missing-file case (#4326).
test "nugetUnresolvedReason: assets.json present but resolves to zero paths warns with the stale reason" {
  val mfDir = freshTempDir("stale-assets")
  defer { cleanup(mfDir) }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }
  // Parses cleanly (empty targets) — present but stale/corrupt, not missing.
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), "{\n  \"targets\": {},\n  \"project\": {}\n}\n")

  val reason = Cli.nugetUnresolvedReason(mfDir, Some(value = oneEntryNugetSection()), newList())
  val r = expectSome(reason, "nugetUnresolvedReason: stale assets.json")
  assertEqual(r, "is stale or could not be resolved", "nugetUnresolvedReason: stale assets.json reason text")
}

// The pre-existing behavior #4770 wants preserved alongside the new stale
// case: no `obj/project.assets.json` at all (never restored).
test "nugetUnresolvedReason: missing assets.json warns with the not-found reason" {
  val mfDir = freshTempDir("missing-assets")
  defer { cleanup(mfDir) }

  val reason = Cli.nugetUnresolvedReason(mfDir, Some(value = oneEntryNugetSection()), newList())
  val r = expectSome(reason, "nugetUnresolvedReason: missing assets.json")
  assertEqual(r, "was not found", "nugetUnresolvedReason: missing assets.json reason text")
}

test "nugetUnresolvedReason: no [nuget] section yields no warning" {
  val mfDir = freshTempDir("no-nuget-section")
  defer { cleanup(mfDir) }

  val reason = Cli.nugetUnresolvedReason(mfDir, None, newList())
  match reason {
    case Some(_) -> panic("nugetUnresolvedReason: expected None when nugetOpt is None")
    case None -> ()
  }
}

test "nugetUnresolvedReason: resolved paths present yields no warning" {
  val mfDir = freshTempDir("resolved-paths")
  defer { cleanup(mfDir) }
  val resolved: List[String] = newList()
  resolved.add("/fake/pkgs/widget/1.0.0/lib/netstandard2.0/Widget.dll")

  val reason = Cli.nugetUnresolvedReason(mfDir, Some(value = oneEntryNugetSection()), resolved)
  match reason {
    case Some(_) -> panic("nugetUnresolvedReason: expected None when nugetPaths is non-empty")
    case None -> ()
  }
}
