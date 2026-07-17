//! cli_shared_self_test.l — exercises `Lyric.Cli.resolveNugetAssets` and
//! `Lyric.Cli.resolveNugetNativeAssets` (cli/cli_shared.l), the
//! `project.assets.json` readers used by `buildProject` / `cmdTestManifest`
//! to locate restored NuGet assembly DLLs and native runtime assets
//! (`runtimes/<rid>/native/*`, #5573).  The underlying JSON navigation
//! (`extractPackagesPathFromYaml`, `extractDllPathsFromYaml`,
//! `extractNativeAssetPathsFromYaml`) is private, so these tests drive it
//! through the public entry points against real fixture files on disk — the
//! same code path `lyric build`/`lyric test` exercise for a real restore
//! (#4340).
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
import Lyric.Workspace as Ws
import Lyric.Discovery as Disc

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
  defer {
    cleanup(mfDir)
  }
  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetAssets: missing project.assets.json")
}

test "resolveNugetAssets: malformed JSON yields an empty list" {
  val mfDir = freshTempDir("malformed")
  defer {
    cleanup(mfDir)
  }
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
  defer {
    cleanup(mfDir)
  }
  val pkgsDir = freshTempDir("happy-path-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }

  val dllPath = touchNugetDll(pkgsDir, "Newtonsoft.Json", "13.0.3", "lib/netstandard2.0/Newtonsoft.Json.dll")

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"Newtonsoft.Json/13.0.3\": {\n" +
    "        \"type\": \"package\",\n" +
    "        \"runtime\": {\n" +
    "          \"lib/netstandard2.0/Newtonsoft.Json.dll\": {}\n" +
    "        }\n" +
    "      },\n" +
    "      \"Fixture.LocalProject/1.0.0\": {\n" +
    "        \"type\": \"project\",\n" +
    "        \"runtime\": {\n" +
    "          \"bin/Fixture.LocalProject.dll\": {}\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  },\n" +
    "  \"project\": {\n" +
    "    \"restore\": {\n" +
    "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") +
    "\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
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
  defer {
    cleanup(mfDir)
  }
  val pkgsDir = freshTempDir("missing-dll-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }
  // Deliberately do NOT create the DLL file under pkgsDir.

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"Widget/1.0.0\": {\n" +
    "        \"type\": \"package\",\n" +
    "        \"runtime\": {\n" +
    "          \"lib/netstandard2.0/Widget.dll\": {}\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  },\n" +
    "  \"project\": {\n" +
    "    \"restore\": {\n" +
    "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") +
    "\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetAssets: DLL declared but absent on disk yields no paths")
}

test "resolveNugetAssets: empty targets yields an empty list" {
  val mfDir = freshTempDir("empty-targets")
  defer {
    cleanup(mfDir)
  }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), "{\n  \"targets\": {},\n  \"project\": {}\n}\n")
  val paths = Cli.resolveNugetAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetAssets: no targets")
}

// Regression for #5573: a package (mirroring `SQLitePCLRaw.provider.e_sqlite3`)
// declares a native asset for the CURRENT host RID under `runtimeTargets`
// (sibling of `runtime`), plus a decoy entry for a different RID and a
// decoy `assetType: "runtime"` entry — only the host-RID native entry should
// resolve. Built against the real `Environment.runtimeIdentifier()` so the
// fixture matches whatever platform CI actually runs this test on.
test "resolveNugetNativeAssets: happy path resolves only the host-RID native asset" {
  val hostRid = Environment.runtimeIdentifier()
  if hostRid.length == 0 {
    // No host RID (e.g. under a JVM CLI host) — nothing to assert against.
    return
  }
  val mfDir = freshTempDir("native-happy-path")
  defer {
    cleanup(mfDir)
  }
  val pkgsDir = freshTempDir("native-happy-path-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }

  val nativeRelPath = "runtimes/" + hostRid + "/native/libe_sqlite3.so"
  val nativePath = touchNugetDll(pkgsDir, "SQLitePCLRaw.lib.e_sqlite3", "2.1.6", nativeRelPath)
  // Also materialise the decoy assets so a bug that ignores the assetType/rid
  // filters entirely would still find files on disk to resolve.
  val _ = touchNugetDll(
    pkgsDir,
    "SQLitePCLRaw.lib.e_sqlite3",
    "2.1.6",
    "runtimes/some-other-rid/native/libe_sqlite3.so"
  )
  val _ = touchNugetDll(
    pkgsDir,
    "SQLitePCLRaw.lib.e_sqlite3",
    "2.1.6",
    "lib/netstandard2.0/SQLitePCLRaw.lib.e_sqlite3.dll"
  )

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"SQLitePCLRaw.lib.e_sqlite3/2.1.6\": {\n" +
    "        \"type\": \"package\",\n" +
    "        \"runtimeTargets\": {\n" +
    "          \"" +
    nativeRelPath +
    "\": { \"assetType\": \"native\", \"rid\": \"" +
    hostRid +
    "\" },\n" +
    "          \"runtimes/some-other-rid/native/libe_sqlite3.so\": { \"assetType\": \"native\", \"rid\": \"some-other-rid\" },\n" +
    "          \"lib/netstandard2.0/SQLitePCLRaw.lib.e_sqlite3.dll\": { \"assetType\": \"runtime\", \"rid\": \"" +
    hostRid +
    "\" }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  },\n" +
    "  \"project\": {\n" +
    "    \"restore\": {\n" +
    "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") +
    "\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  val paths = Cli.resolveNugetNativeAssets(mfDir)
  assertEqualInt(paths.count, 1, "resolveNugetNativeAssets: only the host-RID native asset is resolved")
  assertTrue(
    listContains(paths, nativePath),
    "resolveNugetNativeAssets: resolved path matches the fixture native asset on disk"
  )
}

test "resolveNugetNativeAssets: no obj/project.assets.json yields an empty list" {
  val mfDir = freshTempDir("native-no-assets")
  defer {
    cleanup(mfDir)
  }
  val paths = Cli.resolveNugetNativeAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetNativeAssets: missing project.assets.json")
}

// A `runtimeTargets` entry declared for the host RID but never materialised
// on disk (declared in the assets file but not actually restored) must be
// skipped rather than returned as a dangling path — mirrors
// `resolveNugetAssets`'s "runtime entry with no file on disk" case.
test "resolveNugetNativeAssets: host-RID entry with no file on disk is skipped" {
  val hostRid = Environment.runtimeIdentifier()
  if hostRid.length == 0 {
    return
  }
  val mfDir = freshTempDir("native-missing-file")
  defer {
    cleanup(mfDir)
  }
  val pkgsDir = freshTempDir("native-missing-file-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }
  // Deliberately do NOT create the native asset file under pkgsDir.

  val nativeRelPath = "runtimes/" + hostRid + "/native/libwidget.so"
  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"Widget.Native/1.0.0\": {\n" +
    "        \"type\": \"package\",\n" +
    "        \"runtimeTargets\": {\n" +
    "          \"" +
    nativeRelPath +
    "\": { \"assetType\": \"native\", \"rid\": \"" +
    hostRid +
    "\" }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  },\n" +
    "  \"project\": {\n" +
    "    \"restore\": {\n" +
    "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") +
    "\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  val paths = Cli.resolveNugetNativeAssets(mfDir)
  assertEqualInt(paths.count, 0, "resolveNugetNativeAssets: declared asset absent on disk yields no paths")
}

// Regression for #5742: `resolveAllNugetAssets` must resolve both the
// managed DLL and the host-RID native asset from a single fixture in one
// call, matching what `resolveNugetAssets` + `resolveNugetNativeAssets`
// resolve independently for the same inputs.
test "resolveAllNugetAssets: resolves both managed DLL and host-RID native asset together" {
  val hostRid = Environment.runtimeIdentifier()
  if hostRid.length == 0 {
    return
  }
  val mfDir = freshTempDir("all-assets")
  defer {
    cleanup(mfDir)
  }
  val pkgsDir = freshTempDir("all-assets-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val objDir = Path.join(mfDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }

  val dllRelPath = "lib/netstandard2.0/SQLitePCLRaw.lib.e_sqlite3.dll"
  val nativeRelPath = "runtimes/" + hostRid + "/native/libe_sqlite3.so"
  val dllPath = touchNugetDll(pkgsDir, "SQLitePCLRaw.lib.e_sqlite3", "2.1.6", dllRelPath)
  val nativePath = touchNugetDll(pkgsDir, "SQLitePCLRaw.lib.e_sqlite3", "2.1.6", nativeRelPath)

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"SQLitePCLRaw.lib.e_sqlite3/2.1.6\": {\n" +
    "        \"type\": \"package\",\n" +
    "        \"runtime\": {\n" +
    "          \"" +
    dllRelPath +
    "\": {}\n" +
    "        },\n" +
    "        \"runtimeTargets\": {\n" +
    "          \"" +
    nativeRelPath +
    "\": { \"assetType\": \"native\", \"rid\": \"" +
    hostRid +
    "\" }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  },\n" +
    "  \"project\": {\n" +
    "    \"restore\": {\n" +
    "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") +
    "\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  val all = Cli.resolveAllNugetAssets(mfDir)
  assertEqualInt(all.dllPaths.count, 1, "resolveAllNugetAssets: one managed DLL resolved")
  assertTrue(listContains(all.dllPaths, dllPath), "resolveAllNugetAssets: managed DLL path matches fixture")
  assertEqualInt(all.nativePaths.count, 1, "resolveAllNugetAssets: one native asset resolved")
  assertTrue(listContains(all.nativePaths, nativePath), "resolveAllNugetAssets: native asset path matches fixture")
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
  defer {
    cleanup(mfDir)
  }
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
  defer {
    cleanup(mfDir)
  }

  val reason = Cli.nugetUnresolvedReason(mfDir, Some(value = oneEntryNugetSection()), newList())
  val r = expectSome(reason, "nugetUnresolvedReason: missing assets.json")
  assertEqual(r, "was not found", "nugetUnresolvedReason: missing assets.json reason text")
}

test "nugetUnresolvedReason: no [nuget] section yields no warning" {
  val mfDir = freshTempDir("no-nuget-section")
  defer {
    cleanup(mfDir)
  }

  val reason = Cli.nugetUnresolvedReason(mfDir, None, newList())
  match reason {
    case Some(_) -> panic("nugetUnresolvedReason: expected None when nugetOpt is None")
    case None -> ()
  }
}

test "nugetUnresolvedReason: resolved paths present yields no warning" {
  val mfDir = freshTempDir("resolved-paths")
  defer {
    cleanup(mfDir)
  }
  val resolved: List[String] = newList()
  resolved.add("/fake/pkgs/widget/1.0.0/lib/netstandard2.0/Widget.dll")

  val reason = Cli.nugetUnresolvedReason(mfDir, Some(value = oneEntryNugetSection()), resolved)
  match reason {
    case Some(_) -> panic("nugetUnresolvedReason: expected None when nugetPaths is non-empty")
    case None -> ()
  }
}

// Regression for #5004: a `[nuget]` dependency on a Lyric package (e.g.
// `Lyric.Web`) previously never had its embedded contract loaded — only
// third-party .NET assemblies without one went through the auto-FFI path,
// but a Lyric package's DLL was routed there too, and auto-FFI's raw
// metadata signature guess could misread a function's arity. This DLL
// (the running test's own compiled assembly) carries a real embedded
// `Lyric.Contract`, since every Lyric-emitted assembly does.
func selfDllPath(): String {
  Path.join(Environment.appBaseDirectory(), "cli_shared_self_test.dll")
}

test "partitionNugetLyricDeps: Lyric-contract DLL routes to restored deps, third-party DLL does not" {
  val pkgsDir = freshTempDir("partition-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val thirdPartyDll = touchNugetDll(pkgsDir, "Newtonsoft.Json", "13.0.3", "lib/netstandard2.0/Newtonsoft.Json.dll")

  val nugetPaths: List[String] = newList()
  nugetPaths.add(selfDllPath())
  nugetPaths.add(thirdPartyDll)

  val (restoredEntries, thirdPartyPaths) = Cli.partitionNugetLyricDeps(nugetPaths)
  assertEqualInt(restoredEntries.count, 1, "partitionNugetLyricDeps: exactly one Lyric-contract entry")
  assertTrue(
    Str.endsWith(restoredEntries[0], "\t" + selfDllPath()),
    "partitionNugetLyricDeps: the Lyric DLL's path is preserved after its depName prefix"
  )
  assertEqualInt(thirdPartyPaths.count, 1, "partitionNugetLyricDeps: exactly one third-party entry")
  assertEqual(thirdPartyPaths[0], thirdPartyDll, "partitionNugetLyricDeps: the non-Lyric DLL is left for auto-FFI")
}

// Direct coverage for `resolveProjectSources` (#5333): the shared
// discovery/collection helper now backs `cmdLint`/`cmdDoc`/`cmdBench`/
// `cmdFmt`/`cmdProve`'s project-mode fork, but previously had no test of
// its own. Both cases here pass an explicit `--manifest` path so the
// result is independent of the test process's current working directory
// (an implicit discovery walk from cwd is exercised end-to-end by the CLI
// self-tests instead, where cwd is controlled).
test "resolveProjectSources: explicit manifest with two package files resolves both paths" {
  val mfDir = freshTempDir("proj-sources-ok")
  defer {
    cleanup(mfDir)
  }
  val srcA = Path.join(mfDir, "a.l")
  val srcB = Path.join(mfDir, "b.l")
  writeFileOrPanic(srcA, "package Fixture.A\n\npub func a(): Int {\n  1\n}\n")
  writeFileOrPanic(srcB, "package Fixture.B\n\npub func b(): Int {\n  2\n}\n")
  val mfPath = Path.join(mfDir, "lyric.toml")
  writeFileOrPanic(
    mfPath,
    "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Fixture\"\n\n[project.packages]\n\"A\" = \"a.l\"\n\"B\" = \"b.l\"\n"
  )

  match Cli.resolveProjectSources(Some(value = mfPath)) {
    case Cli.ProjSourcesFound(foundMfPath, paths) -> {
      assertEqual(foundMfPath, mfPath, "resolveProjectSources: returns the manifest path it discovered/was given")
      assertEqualInt(paths.count, 2, "resolveProjectSources: both [project.packages] source files collected")
      assertTrue(listContains(paths, srcA), "resolveProjectSources: package A's source file is present")
      assertTrue(listContains(paths, srcB), "resolveProjectSources: package B's source file is present")
    }
    case Cli.ProjSourcesMissingManifest -> panic("resolveProjectSources: expected ProjSourcesFound, got ProjSourcesMissingManifest")
    case Cli.ProjSourcesFatal -> panic("resolveProjectSources: expected ProjSourcesFound, got ProjSourcesFatal")
  }
}

test "resolveProjectSources: a [project.packages] entry pointing at a missing file is fatal" {
  val mfDir = freshTempDir("proj-sources-fatal")
  defer {
    cleanup(mfDir)
  }
  val mfPath = Path.join(mfDir, "lyric.toml")
  writeFileOrPanic(
    mfPath,
    "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Fixture\"\n\n[project.packages]\n\"Missing\" = \"does_not_exist.l\"\n"
  )

  match Cli.resolveProjectSources(Some(value = mfPath)) {
    case Cli.ProjSourcesFatal -> ()
    case Cli.ProjSourcesFound(_, _) -> panic("resolveProjectSources: expected ProjSourcesFatal, got ProjSourcesFound")
    case Cli.ProjSourcesMissingManifest -> panic("resolveProjectSources: expected ProjSourcesFatal, got ProjSourcesMissingManifest")
  }
}

// isDotnetStdlibSource: the freshness-guard filter that keeps a JVM- or
// native-only kernel edit from spuriously flagging the .NET bundle stale
// (#5718).  Pure over the path string, so this is deterministic — no mtime
// timing dependence.
test "isDotnetStdlibSource: .NET-relevant sources included, JVM/native-only excluded" {
  // Public stdlib surface and the shared .NET kernel are relevant.
  assertTrue(Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/http.l"), "public stdlib file is .NET-relevant")
  assertTrue(
    Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/_kernel/format_host.l"),
    "shared _kernel host is .NET-relevant"
  )
  // JVM- and native-only kernel trees do not contribute to the .NET bundle.
  assertFalse(
    Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/_kernel_jvm/char_host.l"),
    "_kernel_jvm file is excluded"
  )
  assertFalse(
    Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/_kernel_native/file.l"),
    "_kernel_native file is excluded"
  )
  // Any `jvm*.l` file inside the shared _kernel dir is excluded (prefix match,
  // mirroring the loader — so a future `jvm_*.l` kernel is covered too).
  assertFalse(Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/_kernel/jvm.l"), "_kernel/jvm.l is excluded")
  assertFalse(
    Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/_kernel/jvm_exception.l"),
    "_kernel/jvm_exception.l is excluded"
  )
  assertFalse(
    Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/_kernel/jvm_future_host.l"),
    "a future _kernel/jvm_*.l file is excluded by the prefix match"
  )
  // A non-jvm host file whose name merely contains "jvm" mid-string is kept.
  assertTrue(
    Cli.isDotnetStdlibSource("/repo/lyric-stdlib/std/_kernel/webjvm_host.l"),
    "mid-name 'jvm' does not trip the prefix skip"
  )
}

// discoverManifest: a relative explicit `--manifest` path must be
// absolutized (#5626 item 2) so a caller like `runRestore` can
// `Path.dirname` it and walk up to a workspace root — `Path.dirname` of a
// bare relative path (e.g. "lyric-web/lyric.toml" -> "lyric-web") can never
// climb above the process's current directory.
test "discoverManifest: relative explicit manifest is absolutized" {
  val rel = "some/nested/lyric.toml"
  match Cli.discoverManifest(Some(value = rel)) {
    case Some(p) -> {
      assertTrue(Path.isAbsolute(p), "discoverManifest: absolutized relative path is absolute")
      assertEqual(p, Path.join(Environment.currentDirectory(), rel), "discoverManifest: matches cwd-joined path")
    }
    case None -> panic("discoverManifest: expected Some for an explicit manifest")
  }
}

test "discoverManifest: absolute explicit manifest passes through unchanged" {
  val abs = Path.join(Environment.currentDirectory(), "already/absolute/lyric.toml")
  match Cli.discoverManifest(Some(value = abs)) {
    case Some(p) -> assertEqual(p, abs, "discoverManifest: absolute path is returned unchanged")
    case None -> panic("discoverManifest: expected Some for an explicit manifest")
  }
}

// End-to-end proof that the absolutization actually unblocks the
// workspace-root walk-up `runRestore` does next (#5626 item 2): before
// this fix, `runRestore`'s `Path.dirname(mfPath)` on a RELATIVE explicit
// `--manifest` produced a relative directory that `Ws.findWorkspaceRoot`
// could never walk up from to find a workspace root above it — this test
// builds the exact absolute directory `discoverManifest` now produces
// (join(cwd, relativePath), the same shape a caller can't otherwise get
// from a bare relative dirname) and confirms `Ws.findWorkspaceRoot` finds
// the workspace root from it.
test "discoverManifest fix unblocks Ws.findWorkspaceRoot from a relative --manifest's absolutized dir" {
  val root = freshTempDir("restore-relative-manifest")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(
    Path.join(root, "lyric.toml"),
    "[workspace]\nmembers = [\"member\"]\n\n[package]\nname = \"Root\"\nversion = \"0.1.0\"\n"
  )
  val memberDir = Path.join(root, "member")
  match File.createDir(memberDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir " + memberDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(memberDir, "lyric.toml"), "[package]\nname = \"Member\"\nversion = \"0.1.0\"\n")

  // The fix: `discoverManifest` absolutizes the explicit manifest path
  // before returning it, so `Path.dirname` yields an absolute directory
  // that CAN walk up to the workspace root — reproduced here directly
  // against the fixture root (join(root, relativeManifestPath)) since the
  // test process's own cwd isn't controllable from within a `lyric test` run.
  val fixedAbsoluteDir = Path.dirname(Path.join(root, "member/lyric.toml"))
  match Ws.findWorkspaceRoot(fixedAbsoluteDir) {
    case Some(ctx) -> assertEqual(ctx.rootDir, root, "absolutized dir walks up to the fixture's workspace root")
    case None -> panic("expected the absolutized dir to find the fixture's workspace root")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyric.Discovery.findNearestManifestDetailed / findNearestManifest (#4881):
// an existing-but-unparseable lyric.toml must stop the upward walk and be
// reported, not be silently skipped as if it were "not a manifest".
// ─────────────────────────────────────────────────────────────────────────────
// A corrupt (unparseable-as-TOML) lyric.toml nearer to the start dir than a
// perfectly valid one further up: before #4881's fix, `findNearestManifest`
// silently walked past the corrupt file and returned the ancestor's valid
// manifest instead — adopting the WRONG project's configuration with no
// diagnostic at all.  `findNearestManifestDetailed` must instead stop at the
// corrupt file and report it, never falling through to the ancestor.
test "findNearestManifestDetailed: a corrupt lyric.toml nearer than a valid ancestor is reported, not skipped" {
  val root = freshTempDir("corrupt-above-valid")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[package]\nname = \"Root\"\nversion = \"0.1.0\"\n")
  val childDir = Path.join(root, "child")
  val grandchildDir = Path.join(childDir, "grandchild")
  match File.createDir(grandchildDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir " + grandchildDir + ": " + IOError.message(e))
  }
  // Malformed TOML: an unterminated section header.
  writeFileOrPanic(Path.join(childDir, "lyric.toml"), "[package\nname = \"Child\"\n")

  match Disc.findNearestManifestDetailed(grandchildDir) {
    case FoundBrokenManifest(path, error) -> {
      assertEqual(path, Path.join(childDir, "lyric.toml"), "reports the nearer, corrupt manifest's path")
      match error {
        case ParseError(_, _, _, _) -> assertTrue(true, "corrupt TOML syntax surfaces as ParseError")
        case _ -> panic("expected ParseError for malformed TOML, got a different ManifestError variant")
      }
    }
    case FoundManifest(path) -> panic("expected FoundBrokenManifest, but silently found " + path + " (walked past the corrupt manifest)")
    case NoManifestFound -> panic("expected FoundBrokenManifest, got NoManifestFound")
  }

  // The Option-returning wrapper collapses FoundBrokenManifest to None
  // (never to the ancestor's path) — same fallback shape every existing
  // caller already handles for "no manifest found".
  match Disc.findNearestManifest(grandchildDir) {
    case None -> assertTrue(true, "findNearestManifest collapses a broken nearer manifest to None")
    case Some(path) -> panic("findNearestManifest should not fall through to the ancestor manifest, got " + path)
  }
}

// A lyric.toml that exists and parses as valid TOML but has no `[package]`
// section (e.g. a virtual workspace root) is `MissingField`, not a real
// error — the walk must continue past it exactly as before #4881, finding a
// valid `[package]` manifest further up.
test "findNearestManifestDetailed: a workspace-root-only lyric.toml (no [package]) is skipped, not reported" {
  val root = freshTempDir("missingfield-above-valid")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[package]\nname = \"Root\"\nversion = \"0.1.0\"\n")
  val childDir = Path.join(root, "child")
  val grandchildDir = Path.join(childDir, "grandchild")
  match File.createDir(grandchildDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir " + grandchildDir + ": " + IOError.message(e))
  }
  // Valid TOML, but no [package] section — parses with MissingField.
  writeFileOrPanic(Path.join(childDir, "lyric.toml"), "[workspace]\nexclude = []\n")

  match Disc.findNearestManifestDetailed(grandchildDir) {
    case FoundManifest(path) -> assertEqual(path, Path.join(root, "lyric.toml"), "walks past the workspace-root-only manifest to the valid ancestor")
    case FoundBrokenManifest(path, _) -> panic("MissingField should not be reported as broken, got FoundBrokenManifest at " + path)
    case NoManifestFound -> panic("expected to find the valid ancestor manifest")
  }
}

// #5862: a `[package]` table that EXISTS but is missing a required field
// emits the same `MissingField("package", "name")` as "no [package] table
// at all" — before the fix the walk treated both as "not a package manifest"
// and silently adopted the valid ancestor, reproducing the exact misroute
// #4881 fixed for ParseError via a different malformed-manifest shape.
test "findNearestManifestDetailed: an incomplete [package] table nearer than a valid ancestor is reported, not skipped (#5862)" {
  val root = freshTempDir("incomplete-pkg-above-valid")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[package]\nname = \"Root\"\nversion = \"0.1.0\"\n")
  val childDir = Path.join(root, "child")
  val grandchildDir = Path.join(childDir, "grandchild")
  match File.createDir(grandchildDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir " + grandchildDir + ": " + IOError.message(e))
  }
  // Valid TOML with a [package] header, but the required `name` field is
  // missing — parses with MissingField("package", "name"), same as a file
  // with no [package] at all.
  writeFileOrPanic(Path.join(childDir, "lyric.toml"), "[package]\nversion = \"1.0.0\"\n")

  match Disc.findNearestManifestDetailed(grandchildDir) {
    case FoundBrokenManifest(path, error) -> {
      assertEqual(path, Path.join(childDir, "lyric.toml"), "reports the nearer, incomplete manifest's path")
      match error {
        case MissingField(_, _) -> assertTrue(true, "incomplete [package] surfaces as MissingField")
        case _ -> panic("expected MissingField for the incomplete [package] table")
      }
    }
    case FoundManifest(path) -> panic("expected FoundBrokenManifest, but silently found " + path + " (walked past the incomplete [package] manifest)")
    case NoManifestFound -> panic("expected FoundBrokenManifest, got NoManifestFound")
  }
}

// #5865: a bare `[package]` header with ZERO key/value lines produces no
// Entry rows at all, so an entries-based `hasSection` check cannot see it —
// the walk silently continued to the ancestor. The textual header-line scan
// must classify it as a broken package manifest.
test "findNearestManifestDetailed: a bare zero-field [package] header is reported, not skipped (#5865)" {
  val root = freshTempDir("bare-pkg-above-valid")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[package]\nname = \"Root\"\nversion = \"0.1.0\"\n")
  val childDir = Path.join(root, "child")
  val grandchildDir = Path.join(childDir, "grandchild")
  match File.createDir(grandchildDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir " + grandchildDir + ": " + IOError.message(e))
  }
  // Nothing but the section header — no fields at all.
  writeFileOrPanic(Path.join(childDir, "lyric.toml"), "[package]\n")

  match Disc.findNearestManifestDetailed(grandchildDir) {
    case FoundBrokenManifest(path, _) -> assertEqual(path, Path.join(childDir, "lyric.toml"), "reports the nearer, zero-field [package] manifest's path")
    case FoundManifest(path) -> panic("expected FoundBrokenManifest, but silently found " + path + " (walked past the bare [package] manifest)")
    case NoManifestFound -> panic("expected FoundBrokenManifest, got NoManifestFound")
  }
}

test "findNearestManifestDetailed: no lyric.toml anywhere reports NoManifestFound" {
  val root = freshTempDir("nothing-found")
  defer {
    cleanup(root)
  }
  val leafDir = Path.join(root, "leaf")
  match File.createDir(leafDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir " + leafDir + ": " + IOError.message(e))
  }
  // Temp dirs live outside the repo checkout (`tempBase()` is $TMPDIR/$TEMP/
  // $TMP or "/tmp"), so no ancestor of `leafDir` up to the filesystem root
  // carries a lyric.toml at all — same isolation assumption the workspace
  // fixture tests above already rely on.
  match Disc.findNearestManifestDetailed(leafDir) {
    case NoManifestFound -> assertTrue(true, "no manifest found anywhere above the fixture")
    case FoundManifest(path) -> panic("unexpected manifest found at " + path)
    case FoundBrokenManifest(path, _) -> panic("unexpected corrupt manifest found at " + path)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// #5860: no CLI-integration test exists for `Lyric.Cli.main`'s bare-dispatch
// `FoundBrokenManifest` arm (cli_main.l) or `cmdTest`'s auto-discovery
// `FoundBrokenManifest` arm (cli_test.l) — only the lower-level
// `Disc.findNearestManifestDetailed` primitive above is driven directly.
// Investigated adding one; documenting why it isn't possible in-process
// today rather than shipping a test that doesn't actually exercise the
// wiring it claims to cover:
//
//  1. Both call sites are hardcoded to
//     `Disc.findNearestManifestDetailed(Environment.currentDirectory())` —
//     the discovery PRIMITIVE takes an explicit `startDir` (which is how
//     the tests above drive it against fixture directories), but neither
//     `main`'s bare-argv branch nor `cmdTest`'s auto-discovery branch
//     exposes a way to substitute a fixture directory for the real process
//     cwd. `Std.Environment` has no `setCurrentDirectory`/chdir extern
//     either (checked `_kernel/environment_host.l`), so there is no way to
//     redirect discovery to a controlled fixture tree without changing
//     `main`/`cmdTest`'s own signatures — a production-code change, not a
//     test addition, and out of scope for this test-coverage follow-up.
//  2. `cmdTest` (cli_test.l) is package-private (not `pub`), so even
//     setting aside (1), this self-test's package (`Lyric.CliSharedSelfTest`)
//     cannot call it directly today.
//  3. `printErr`/`printUsage` write straight to `Std.Console.error`/stdout;
//     there is no capture facility, so even with (1) and (2) solved, the
//     exact warning text the issue calls out could not be asserted — only
//     the Int exit code could be.
//  4. Actually invoking `Lyric.Cli.main([])` for real (the one call of the
//     two that IS `pub`) is unsafe here regardless: it runs against
//     whatever the test process's ACTUAL cwd is, which under `lyric test`
//     is inside a real checkout with a valid `lyric.toml` — it would kick
//     off a full recursive `cmdBuild` of the discovered project rather
//     than hit the broken-manifest branch this issue is about.
//
// Closing this properly needs an injectable start-directory seam on
// `main`/`cmdTest` (or their discovery call) plus a stdout/stderr capture
// facility — both real production-code additions, not test-only changes.
// Filed as a documented gap rather than a fabricated assertion.
// ─────────────────────────────────────────────────────────────────────────────
