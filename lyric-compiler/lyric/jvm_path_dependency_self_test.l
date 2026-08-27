//! jvm_path_dependency_self_test.l — regression coverage for #6264: on
//! `--target jvm`, a project declaring a local `[dependencies]` entry
//! (`Dep = { path = "../dep" }`) used to compile as if the dependency's code
//! didn't exist — only its `pub aspect` / `pub wire` templates were
//! consumed, so any reference to the dependency's ordinary functions/types
//! type-checked as unknown or crashed at runtime with `NoClassDefFoundError`.
//!
//! The core compile mechanism (a path dependency's SOURCE, not its DLL, is
//! compiled directly into the JVM bundle) was already fixed as a side effect
//! of #6136 (D-progress-720): `resolveManifestDependencies` collects a
//! `path` dependency's package sources into `depTemplateSrcs`
//! unconditionally, and `buildProjectFromManifest` / `emitSingleFileOrProject`
//! append those collected packages to the bundle for `target = Jvm`. What
//! #6264 fixes ON TOP of that: `resolveManifestDependencies`'s Path branch
//! still treated an unbuilt `.dll` as FATAL (`hadUnbuiltLocalDep`)
//! regardless of target — a Dotnet-only concern (the JVM bundler never
//! reads `restoredDllPaths`) — which blocked
//! `emitSingleFileOrProject`'s single-file build path (the ONLY caller that
//! actually gates on `hadUnbuiltLocalDep`) for a `--target jvm` build of a
//! FRESH checkout whose path dependency had never been built for
//! `--target dotnet` first. Both fixtures below never build the
//! dependency's own DLL, confirming the fresh-checkout scenario the issue's
//! acceptance criteria describes.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_path_dependency_self_test.l
@test_module
package Lyric.JvmPathDependencySelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter
import Lyric.Manifest as Mf

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-pathdep-" + label + "-" + uuidToString(newUuid()))
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

func runJarAndAssertGreeting(jarPath: in String, label: in String): Unit {
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  assertEqualInt(result.exitCode, 0, label + ": exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "hello-from-path-dep", label + ": calls the function defined in the dependency")
}

// ─── Manifest (multi-package project) path: `App` declares `[project.packages]`
// AND a `path = "../Dep"` dependency, mirroring `lyric build --manifest
// app/lyric.toml --target jvm` on a real multi-file project.
test "buildProject: --target jvm compiles a path dependency's code into the bundle and it runs (#6264)" {
  val root = freshTempDir("manifest")
  defer {
    cleanup(root)
  }
  val depDir = mkPackageDir(
    root,
    "Dep",
    "[package]\n" + "name = \"Fixture.PathDep\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathDep\"\n" +
      "output_assembly = \"PathDep.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathDep\" = \"src/dep.l\"\n"
  )
  match File.createDir(Path.join(depDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dep src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(depDir, "src/dep.l"),
    "package Fixture.PathDep\n\npub func pathDepGreeting(): String {\n  \"hello-from-path-dep\"\n}\n"
  )

  val appDir = mkPackageDir(
    root,
    "App",
    "[package]\n" + "name = \"Fixture.PathApp\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathApp\"\n" +
      "output_assembly = \"PathApp.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathApp\" = \"src/app.l\"\n" +
      "\n" +
      "[dependencies]\n" +
      "\"Fixture.PathDep\" = { path = \"../Dep\" }\n"
  )
  match File.createDir(Path.join(appDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create app src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(appDir, "src/app.l"),
    "package Fixture.PathApp\n\nimport Std.Console as Console\nimport Fixture.PathDep\n\nfunc main(): Int {\n  Console.println(pathDepGreeting())\n  0\n}\n"
  )

  // Never build Dep's own DLL: the fresh-checkout scenario the acceptance
  // criteria describes. A pre-#6264 `--target dotnet` build would have
  // needed it; `--target jvm` never should.
  assertFalse(
    File.fileExists(Path.join(Path.join(depDir, "bin"), "PathDep.dll")),
    "sanity: the path dependency's own DLL is never built for this fixture"
  )

  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProject(
    Path.join(appDir, "lyric.toml"),
    None,
    Emitter.Jvm,
    noFeatures,
    false,
    false,
    true,
    None,
    noPre,
    noDefines
  )
  assertEqualInt(
    rc,
    0,
    "buildProject: a --target jvm manifest build with a path dependency succeeds without building the dep's DLL"
  )
  val jarPath = Path.join(Path.join(appDir, "bin"), "PathApp.dll")
  assertTrue(File.fileExists(jarPath), "buildProject: the Jvm build produced an output artifact")
  runJarAndAssertGreeting(jarPath, "buildProject output")
}

// ─── Single-file path: a bare `.l` file sitting next to a manifest that
// declares ONLY `[dependencies]` (no `[project.packages]` of its own) — the
// `emitSingleFileOrProject` leg `Cli.buildOne` routes through. This is the
// path `resolveManifestDependencies`'s pre-#6264 `hadUnbuiltLocalDep`
// fatality actually gated: `emitSingleFileOrProject` is the only caller
// that checks it.
test "buildOne: --target jvm single-file build near a manifest resolves a path dependency without its DLL (#6264)" {
  val root = freshTempDir("singlefile")
  defer {
    cleanup(root)
  }
  val depDir = mkPackageDir(
    root,
    "Dep2",
    "[package]\n" + "name = \"Fixture.PathDep2\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathDep2\"\n" +
      "output_assembly = \"PathDep2.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathDep2\" = \"src/dep2.l\"\n"
  )
  match File.createDir(Path.join(depDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dep2 src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(depDir, "src/dep2.l"),
    "package Fixture.PathDep2\n\npub func pathDepGreeting(): String {\n  \"hello-from-path-dep\"\n}\n"
  )

  val appDir = Path.join(root, "App2")
  match File.createDir(appDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create app2 dir: " + IOError.message(e))
  }
  val appMfPath = Path.join(appDir, "lyric.toml")
  writeFileOrPanic(
    appMfPath,
    "[package]\n" + "name = \"Fixture.PathApp2\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" +
      "\"Fixture.PathDep2\" = { path = \"../Dep2\" }\n"
  )
  val appSrcPath = Path.join(appDir, "app2.l")
  writeFileOrPanic(
    appSrcPath,
    "package Fixture.PathApp2\n\nimport Std.Console as Console\nimport Fixture.PathDep2\n\nfunc main(): Int {\n  Console.println(pathDepGreeting())\n  0\n}\n"
  )

  assertFalse(
    File.fileExists(Path.join(Path.join(depDir, "bin"), "PathDep2.dll")),
    "sanity: the path dependency's own DLL is never built for this fixture"
  )

  val jarPath = Path.join(appDir, "app2.jar")
  val rc = Cli.buildOne(appSrcPath, jarPath, Emitter.Jvm, Some(value = appMfPath))
  assertEqualInt(
    rc,
    0,
    "buildOne: a --target jvm single-file build with an unbuilt path dependency succeeds — previously " +
      "'build failed (unresolved dependency ...)' even though Jvm never needed the dep's DLL (#6264)"
  )
  assertTrue(File.fileExists(jarPath), "buildOne: the Jvm build produced an output artifact")
  runJarAndAssertGreeting(jarPath, "buildOne output")
}

// ─── Regression guard: the manifest fixture still builds on --target dotnet
// via the restored-DLL path once the dependency IS built first.
test "buildProject: the same path-dependency fixture still builds on --target dotnet once the dep is built (regression guard)" {
  val root = freshTempDir("manifest-dotnet")
  defer {
    cleanup(root)
  }
  val depDir = mkPackageDir(
    root,
    "Dep",
    "[package]\n" + "name = \"Fixture.PathDep\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathDep\"\n" +
      "output_assembly = \"PathDep.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathDep\" = \"src/dep.l\"\n"
  )
  match File.createDir(Path.join(depDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dep src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(depDir, "src/dep.l"),
    "package Fixture.PathDep\n\npub func pathDepGreeting(): String {\n  \"hello-from-path-dep\"\n}\n"
  )

  val appDir = mkPackageDir(
    root,
    "App",
    "[package]\n" + "name = \"Fixture.PathApp\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathApp\"\n" +
      "output_assembly = \"PathApp.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathApp\" = \"src/app.l\"\n" +
      "\n" +
      "[dependencies]\n" +
      "\"Fixture.PathDep\" = { path = \"../Dep\" }\n"
  )
  match File.createDir(Path.join(appDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create app src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(appDir, "src/app.l"),
    "package Fixture.PathApp\n\nimport Std.Console as Console\nimport Fixture.PathDep\n\nfunc main(): Int {\n  Console.println(pathDepGreeting())\n  0\n}\n"
  )

  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPreDep: Option[Cli.ResolvedManifestDeps] = None
  val depRc = Cli.buildProject(
    Path.join(depDir, "lyric.toml"),
    None,
    Emitter.Dotnet,
    noFeatures,
    false,
    false,
    true,
    None,
    noPreDep,
    noDefines
  )
  assertEqualInt(depRc, 0, "buildProject: the path dependency itself builds on --target dotnet")

  val noPreApp: Option[Cli.ResolvedManifestDeps] = None
  val appRc = Cli.buildProject(
    Path.join(appDir, "lyric.toml"),
    None,
    Emitter.Dotnet,
    noFeatures,
    false,
    false,
    true,
    None,
    noPreApp,
    noDefines
  )
  assertEqualInt(appRc, 0, "buildProject: --target dotnet still builds the path-dependency fixture")
}

// ─── The OTHER half of #6264's diagnostic-policy change: a path
// dependency's SOURCE (as opposed to its DLL) failing to read must still be
// fatal on Jvm — unlike a merely-unbuilt DLL, Jvm has no fallback for a
// dependency it can't even read. Exercises `resolveManifestDependencies`
// directly (the precise unit under test — `hadUnbuiltLocalDep`'s two
// `if not dllMatters { hadUnbuiltLocalDep = true }` branches in the
// `pkgEntry.paths` / bare-`pkgEntry.path` source-read-failure arms),
// mirroring `cli_workspace_builder_self_test.l`'s #6136
// `resolveManifestDependencies` fixture-level test.
test "resolveManifestDependencies: a path dependency's unreadable source is fatal on --target jvm (#6264)" {
  val root = freshTempDir("srcfail")
  defer {
    cleanup(root)
  }
  // A [project.packages] entry naming a source file that is never written —
  // the manifest is well-formed, but the dependency's own source is not
  // actually readable, unlike the DLL-missing case the other tests above
  // cover.
  val depDir = mkPackageDir(
    root,
    "DepBroken",
    "[package]\n" + "name = \"Fixture.PathDepBroken\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathDepBroken\"\n" +
      "output_assembly = \"PathDepBroken.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathDepBroken\" = \"src/missing.l\"\n"
  )
  assertFalse(
    File.fileExists(Path.join(depDir, "src/missing.l")),
    "sanity: the dependency's declared source file is never written"
  )

  val appDir = Path.join(root, "AppBroken")
  match File.createDir(appDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create appBroken dir: " + IOError.message(e))
  }
  val appMfPath = Path.join(appDir, "lyric.toml")
  writeFileOrPanic(
    appMfPath,
    "[package]\n" + "name = \"Fixture.PathAppBroken\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" +
      "\"Fixture.PathDepBroken\" = { path = \"../DepBroken\" }\n"
  )
  val appMfText = match File.readText(appMfPath) {
    case Ok(t) -> t
    case Err(e) -> panic("cannot read appBroken manifest: " + IOError.message(e))
  }
  val appManifest = match Mf.parseManifest(appMfText, appMfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("cannot parse appBroken manifest: " + ManifestError.message(e))
  }

  val noFeatures: List[String] = newList()
  val resolvedJvm = Cli.resolveManifestDependencies(appManifest, appMfPath, Emitter.Jvm, noFeatures, false)
  assertTrue(
    resolvedJvm.hadUnbuiltLocalDep,
    "resolveManifestDependencies: an unreadable path-dependency source is fatal on --target jvm, even though a " +
      "merely-unbuilt DLL is not (#6264)"
  )

  val resolvedDotnet = Cli.resolveManifestDependencies(appManifest, appMfPath, Emitter.Dotnet, noFeatures, false)
  assertTrue(
    resolvedDotnet.hadUnbuiltLocalDep,
    "resolveManifestDependencies: an unreadable path-dependency source is (still) fatal on --target dotnet too " +
      "(regression guard — dotnet already fails here via the missing-DLL check, unaffected by #6264)"
  )
}

// End-to-end companion to the resolver-level test above: `buildProject`
// (`buildProjectFromManifest`) never reads `hadUnbuiltLocalDep` at all — it
// is a non-fatal warning for that path by design (see
// `ResolvedManifestDeps.hadUnbuiltLocalDep`'s doc comment). A dependency
// whose source can't be read still surfaces as a build failure there, but
// via a DOWNSTREAM missing-symbol type-check error on the consumer package
// that imports it, not an early return. This pins that claim empirically
// rather than leaving it asserted only in a comment.
test "buildProject: a path dependency's unreadable source still fails the --target jvm manifest build, via downstream type-check (#6264)" {
  val root = freshTempDir("srcfail-e2e")
  defer {
    cleanup(root)
  }
  val depDir = mkPackageDir(
    root,
    "DepBroken2",
    "[package]\n" + "name = \"Fixture.PathDepBroken2\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathDepBroken2\"\n" +
      "output_assembly = \"PathDepBroken2.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathDepBroken2\" = \"src/missing.l\"\n"
  )

  val appDir = mkPackageDir(
    root,
    "AppBroken2",
    "[package]\n" + "name = \"Fixture.PathAppBroken2\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.PathAppBroken2\"\n" +
      "output_assembly = \"PathAppBroken2.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.PathAppBroken2\" = \"src/app.l\"\n" +
      "\n" +
      "[dependencies]\n" +
      "\"Fixture.PathDepBroken2\" = { path = \"../DepBroken2\" }\n"
  )
  match File.createDir(Path.join(appDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create appBroken2 src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(appDir, "src/app.l"),
    "package Fixture.PathAppBroken2\n\nimport Std.Console as Console\nimport Fixture.PathDepBroken2\n\nfunc main(): Int {\n  Console.println(pathDepGreeting())\n  0\n}\n"
  )

  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProject(
    Path.join(appDir, "lyric.toml"),
    None,
    Emitter.Jvm,
    noFeatures,
    false,
    false,
    true,
    None,
    noPre,
    noDefines
  )
  assertTrue(
    rc != 0,
    "buildProject: an unreadable path-dependency source still fails the --manifest --target jvm build overall — " +
      "buildProjectFromManifest itself never checks hadUnbuiltLocalDep, so the failure comes from the consumer " +
      "package's downstream reference to the now-absent 'pathDepGreeting' symbol, not an early return"
  )
}
