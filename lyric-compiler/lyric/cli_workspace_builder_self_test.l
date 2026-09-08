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
import Lyric.Workspace as Ws

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

func isSomeWs(o: in Option[Ws.WorkspaceContext]): Bool {
  match o {
    case Some(_) -> true
    case None -> false
  }
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

// buildWorkspaceDeps tuple-return regression; see D-progress-555 (#4925).
test "buildWorkspaceDeps: tuple's Option element round-trips without crashing on destructure" {
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

  val directIsWorkspace = isSomeWs(Ws.findWorkspaceRoot(Path.dirname(mfPath)))
  val noFeatures: List[String] = newList()
  val (dllPaths, hadError, wsCtxOpt) = Cli.buildWorkspaceDeps(manifest, mfPath, Emitter.Dotnet, noFeatures, false)
  val tupleIsWorkspace = isSomeWs(wsCtxOpt)

  assertEqualInt(dllPaths.count, 0, "buildWorkspaceDeps: no {workspace = true} deps declared, so nothing is built")
  assertFalse(hadError, "buildWorkspaceDeps: no build error with no workspace-form deps declared")
  assertTrue(
    tupleIsWorkspace == directIsWorkspace,
    "buildWorkspaceDeps: the tuple's Option element must agree with a direct findWorkspaceRoot call"
  )

  cleanup(root)
}

// Direct coverage for `resolveManifestFeatures` (#5333): the shared helper
// now backs both `buildProject` and `buildOneNative`'s single-file
// synthetic project path, but previously had no test of its own.
test "resolveManifestFeatures: manifest defaults are active with no CLI overrides" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[features]\ndefault = [\"a\", \"b\"]\na = []\nb = []\nc = []\n"
  val (active, declared) = Cli.resolveManifestFeatures(mfText, mfPath, newList(), false, false, Emitter.Dotnet)
  assertEqualInt(active.count, 2, "resolveManifestFeatures: default features are active")
  assertTrue(
    listContainsPrefix(active, "a") and listContainsPrefix(active, "b"),
    "resolveManifestFeatures: both defaults present"
  )
  assertEqualInt(declared.count, 3, "resolveManifestFeatures: all declared features returned regardless of activation")
}

test "resolveManifestFeatures: noDefaultFeatures suppresses defaults, CLI features still apply" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[features]\ndefault = [\"a\"]\na = []\nb = []\n"
  val cliFeatures: List[String] = newList()
  cliFeatures.add("b")
  val (active, _) = Cli.resolveManifestFeatures(mfText, mfPath, cliFeatures, true, false, Emitter.Dotnet)
  assertEqualInt(active.count, 1, "resolveManifestFeatures: only the CLI feature is active, default suppressed")
  assertTrue(listContainsPrefix(active, "b"), "resolveManifestFeatures: CLI-supplied feature is active")
}

test "resolveManifestFeatures: allFeatures activates every declared feature" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[features]\ndefault = []\na = []\nb = []\nc = []\n"
  val (active, declared) = Cli.resolveManifestFeatures(mfText, mfPath, newList(), false, true, Emitter.Dotnet)
  assertEqualInt(
    active.count,
    declared.count,
    "resolveManifestFeatures: --all-features activates every declared feature"
  )
}

test "resolveManifestFeatures: no [features] table yields empty active and declared sets" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n"
  val (active, declared) = Cli.resolveManifestFeatures(mfText, mfPath, newList(), false, false, Emitter.Dotnet)
  assertEqualInt(active.count, 0, "resolveManifestFeatures: no [features] table means no active features")
  assertEqualInt(declared.count, 0, "resolveManifestFeatures: no [features] table means no declared features")
}

// Target normalization (#5571): a platform-split manifest (`default =
// ["dotnet"]`, declared `dotnet` + `jvm`) must resolve to the ACTIVE
// target's feature, not the default target's, so `--target jvm` builds do
// not compile `@cfg(feature = "dotnet")` kernels into JVM bytecode.
func platformSplitMf(): String {
  "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[features]\ndefault = [\"dotnet\"]\ndotnet = []\njvm = []\n"
}

test "resolveManifestFeatures: --target jvm swaps a dotnet default for the declared jvm feature" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val (active, _) = Cli.resolveManifestFeatures(platformSplitMf(), mfPath, newList(), false, false, Emitter.Jvm)
  assertEqualInt(active.count, 1, "target-normalize: exactly one platform feature active on jvm")
  assertTrue(listContainsPrefix(active, "jvm"), "target-normalize: the jvm feature is active")
  assertFalse(listContainsPrefix(active, "dotnet"), "target-normalize: the dotnet default is deactivated on jvm")
}

test "resolveManifestFeatures: --target dotnet leaves a dotnet default untouched" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val (active, _) = Cli.resolveManifestFeatures(platformSplitMf(), mfPath, newList(), false, false, Emitter.Dotnet)
  assertEqualInt(active.count, 1, "target-normalize: dotnet default stays the sole active feature on dotnet")
  assertTrue(listContainsPrefix(active, "dotnet"), "target-normalize: the dotnet feature is active")
}

test "resolveManifestFeatures: explicit --features overrides target normalization" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val cliFeatures: List[String] = newList()
  cliFeatures.add("dotnet")
  val (active, _) = Cli.resolveManifestFeatures(platformSplitMf(), mfPath, cliFeatures, false, false, Emitter.Jvm)
  assertEqualInt(active.count, 1, "target-normalize: the explicit selection is honored verbatim")
  assertTrue(
    listContainsPrefix(active, "dotnet"),
    "target-normalize: an explicitly-requested other-target feature is honored"
  )
}

test "resolveManifestFeatures: an undeclared target feature is not invented" {
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[features]\ndefault = [\"a\"]\na = []\n"
  val (active, _) = Cli.resolveManifestFeatures(mfText, mfPath, newList(), false, false, Emitter.Jvm)
  assertEqualInt(active.count, 1, "target-normalize: non-platform features pass through unchanged")
  assertTrue(
    listContainsPrefix(active, "a"),
    "target-normalize: a manifest with no target-named features is unaffected"
  )
}

test "resolveManifestFeatures: an empty-default manifest keeps its deliberate opt-out on every target" {
  // lyric-session's shape: dotnet/jvm are declared but neither is a
  // default, because each kernel carries a mandatory NuGet/Maven
  // dependency.  The swap fires only on a removed mismatch, so no
  // target-named feature may be introduced here.
  val mfPath = "/tmp/fixture-not-read/lyric.toml"
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[features]\ndefault = []\ndotnet = []\njvm = []\n"
  val (activeJvm, _) = Cli.resolveManifestFeatures(mfText, mfPath, newList(), false, false, Emitter.Jvm)
  assertEqualInt(activeJvm.count, 0, "target-normalize: empty defaults stay empty on jvm")
  val (activeNet, _) = Cli.resolveManifestFeatures(mfText, mfPath, newList(), false, false, Emitter.Dotnet)
  assertEqualInt(activeNet.count, 0, "target-normalize: empty defaults stay empty on dotnet")
}

// Direct coverage for `injectMavenClasspathForJvm` / `restoreMavenClasspath`
// (#5333): the shared helper backs both `buildProject`'s JVM path and
// `buildOneNative`'s single-file synthetic project path.
test "injectMavenClasspathForJvm: no classpath file and no [maven] entries is a silent no-op" {
  val mfDir = freshTempDir("maven-noop")
  defer {
    cleanup(mfDir)
  }
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n"
  val mfPath = Path.join(mfDir, "lyric.toml")
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("cannot parse fixture manifest: " + ManifestError.message(e))
  }
  val injection = Cli.injectMavenClasspathForJvm(mfDir, manifest)
  match injection.savedFfiJars {
    case Some(_) -> panic("injectMavenClasspathForJvm: expected no injection with no classpath file")
    case None -> ()
  }
  assertEqual(injection.classpathColonSep, "", "injectMavenClasspathForJvm: empty classpath with no restore output")
}

test "injectMavenClasspathForJvm: existing classpath file injects LYRIC_FFI_JARS, restore undoes it" {
  val mfDir = freshTempDir("maven-inject")
  defer {
    cleanup(mfDir)
  }
  val restoreDir = Path.join(Path.join(mfDir, "target"), "restore")
  match File.createDir(restoreDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + restoreDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(restoreDir, "jvm-classpath.txt"), "/fake/a.jar\n/fake/b.jar\n")
  val mfText = "[package]\nname = \"Fixture\"\nversion = \"0.1.0\"\n\n[maven]\n\"com.example:widget\" = \"1.0.0\"\n"
  val mfPath = Path.join(mfDir, "lyric.toml")
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("cannot parse fixture manifest: " + ManifestError.message(e))
  }

  // Normalized to the underlying value (defaulting absent to ""), matching
  // how `injectMavenClasspathForJvm`/`restoreMavenClasspath` themselves
  // treat "was unset" as "" rather than truly removing the variable —
  // pre-existing behavior this test isn't changing, just verifying.
  val prevFfi = match Environment.getVar("LYRIC_FFI_JARS") { case Ok(v) -> v; case Err(_) -> "" }

  val injection = Cli.injectMavenClasspathForJvm(mfDir, manifest)
  // Safety net: guarantees LYRIC_FFI_JARS is restored even if an assertion
  // below fails, so this test can never leak env-var state into later
  // tests. The explicit restore call further down still runs first and is
  // itself verified; this defer just makes a second, idempotent restore.
  defer {
    Cli.restoreMavenClasspath(injection.savedFfiJars)
  }
  assertEqual(
    injection.classpathColonSep,
    "/fake/a.jar:/fake/b.jar",
    "injectMavenClasspathForJvm: classpath lines are colon-joined in file order"
  )
  val duringInject = match Environment.getVar("LYRIC_FFI_JARS") { case Ok(v) -> v; case Err(_) -> "" }
  assertEqual(
    duringInject,
    "/fake/a.jar:/fake/b.jar",
    "injectMavenClasspathForJvm: LYRIC_FFI_JARS reflects the injected classpath"
  )

  Cli.restoreMavenClasspath(injection.savedFfiJars)
  val afterRestore = match Environment.getVar("LYRIC_FFI_JARS") { case Ok(v) -> v; case Err(_) -> "" }
  assertEqual(afterRestore, prevFfi, "restoreMavenClasspath: LYRIC_FFI_JARS restored to its prior value")
}

// ─── #6136: a `{ workspace = true }` dependency's symbols on --target jvm ──
// Before this fix, `resolveManifestDependencies`'s dependency loop only
// handled `Mf.DepSource.Path` — a `Workspace` dep's source never reached
// `depTemplateSrcs`, and the JVM backend has no restored-DLL symbol
// resolution path at all (`buildWorkspaceDeps` deliberately skips building a
// workspace dep's DLL for Jvm). So a `--target jvm` build/test of a
// workspace-dep consumer saw every cross-package symbol from the dep as
// "unknown" even though the identical `--target dotnet` build passed via the
// restored-DLL path. Fixture: a two-package workspace, Producer exposing one
// `pub func`, Consumer declaring `"Fixture.WsProducer" = { workspace = true
// }` and calling it.
func writeWs6136Fixture(root: in String): (String, String) {
  // `exclude = []` is required, not decorative: a bare `[workspace]` header
  // with no key/value line under it produces zero parsed `Entry` rows
  // (the same #5865-class gap `textHasPackageSection`'s doc comment
  // documents for `[package]`), so `hasSection(entries, "workspace")` sees
  // nothing and `assembleWorkspace` returns `None` — `findWorkspaceRoot`
  // then treats this file as "not a workspace root" and keeps walking
  // up the real filesystem tree past `/tmp` until it hits this repo's own
  // root `lyric.toml` instead.
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[workspace]\nexclude = []\n")
  val producerDir = mkPackageDir(
    root,
    "Producer",
    "[package]\n" + "name = \"Fixture.WsProducer\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.WsProducer\"\n" +
      "output_assembly = \"WsProducer.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.WsProducer\" = \"src/producer.l\"\n"
  )
  match File.createDir(Path.join(producerDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create producer src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(producerDir, "src/producer.l"),
    "package Fixture.WsProducer\n\npub func producerGreeting(): String {\n  \"hello-from-producer\"\n}\n"
  )

  val consumerDir = mkPackageDir(
    root,
    "Consumer",
    "[package]\n" + "name = \"Fixture.WsConsumer\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.WsConsumer\"\n" +
      "output_assembly = \"WsConsumer.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.WsConsumer\" = \"src/consumer.l\"\n" +
      "\n" +
      "[dependencies]\n" +
      "\"Fixture.WsProducer\" = { workspace = true }\n"
  )
  match File.createDir(Path.join(consumerDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create consumer src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(consumerDir, "src/consumer.l"),
    "package Fixture.WsConsumer\n\nimport Fixture.WsProducer\n\npub func consumerCallsProducer(): String {\n  producerGreeting()\n}\n"
  );
  (producerDir, consumerDir)
}

test "resolveManifestDependencies: a { workspace = true } dependency's source is collected into depTemplateSrcs (#6136)" {
  val root = freshTempDir("ws6136-deps")
  defer {
    cleanup(root)
  }
  val (producerDir, consumerDir) = writeWs6136Fixture(root)

  val consumerMfPath = Path.join(consumerDir, "lyric.toml")
  val consumerMfText = match File.readText(consumerMfPath) {
    case Ok(t) -> t
    case Err(e) -> panic("cannot read consumer manifest: " + IOError.message(e))
  }
  val consumerManifest = match Mf.parseManifest(consumerMfText, consumerMfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("cannot parse consumer manifest: " + ManifestError.message(e))
  }

  val noFeatures: List[String] = newList()
  // The Jvm target is the load-bearing case: it never reads `restoredDlls`,
  // so `depTemplateSrcs` is the ONLY channel through which a workspace dep's
  // symbols reach the consumer.
  val resolved = Cli.resolveManifestDependencies(consumerManifest, consumerMfPath, Emitter.Jvm, noFeatures, false)
  assertFalse(
    resolved.hadWorkspaceError,
    "resolveManifestDependencies: no workspace error resolving Fixture.WsProducer"
  )
  assertEqualInt(
    resolved.depTemplateSrcs.count,
    1,
    "resolveManifestDependencies: the workspace dep's package is collected into depTemplateSrcs"
  )
  val producerPkg = resolved.depTemplateSrcs[0]
  assertEqual(
    producerPkg.name,
    "Fixture.WsProducer",
    "resolveManifestDependencies: dep template package is named after its own [project.packages] entry"
  )
  assertTrue(
    producerPkg.sources.count > 0 and Str.contains(producerPkg.sources[0], "producerGreeting"),
    "resolveManifestDependencies: dep template source contains the producer's function"
  )
}

test "buildProject: a Jvm build compiles a { workspace = true } dependency's symbols into the bundle (#6136)" {
  val root = freshTempDir("ws6136-jvm-build")
  defer {
    cleanup(root)
  }
  val (producerDir, consumerDir) = writeWs6136Fixture(root)

  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProject(
    Path.join(consumerDir, "lyric.toml"),
    None,
    Emitter.Jvm,
    noFeatures,
    false,
    false,
    // noRestore = true: this fixture has no lyric.lock, and auto-restore's
    // `{ workspace = true }` handling is a separate, unrelated gap
    // (`runRestore` doesn't resolve workspace-form deps against the
    // on-disk member index the way `Ws.resolveDep` does) — irrelevant to
    // what this test is proving, so it is bypassed rather than routed
    // around.
    true,
    None,
    noPre,
    noDefines
  )
  assertEqualInt(
    rc,
    0,
    "buildProject: a --target jvm build of a workspace-dep consumer succeeds — previously every cross-package " +
      "symbol from the dependency type-checked as 'unknown' (#6136)"
  )
  val outArtifact = Path.join(Path.join(consumerDir, "bin"), "WsConsumer.dll")
  assertTrue(File.fileExists(outArtifact), "buildProject: the Jvm build produced an output artifact")
  // Jvm never builds a workspace dep's own DLL (`buildWorkspaceDeps` skips
  // it deliberately) — the fix works purely by compiling the dep's SOURCE
  // into the consumer's bundle, so no Producer artifact should exist.
  assertFalse(
    File.fileExists(Path.join(Path.join(producerDir, "bin"), "WsProducer.dll")),
    "buildProject: Jvm never builds the workspace dep's own DLL — it is only ever consumed as bundled source"
  )
}

test "buildProject: the same workspace-dep fixture still builds on --target dotnet (regression guard)" {
  val root = freshTempDir("ws6136-dotnet-build")
  defer {
    cleanup(root)
  }
  val (producerDir, consumerDir) = writeWs6136Fixture(root)

  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProject(
    Path.join(consumerDir, "lyric.toml"),
    None,
    Emitter.Dotnet,
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
    "buildProject: --target dotnet still builds the workspace-dep fixture via the restored-DLL path"
  )
  assertTrue(
    File.fileExists(Path.join(Path.join(producerDir, "bin"), "WsProducer.dll")),
    "buildProject: --target dotnet builds the workspace dep's own DLL (the restored-dependency path)"
  )
}

// ─── Regression for #6697 on the OTHER caller that feeds
// `EmitProjectRequest.restoredDllPaths` — `emitSingleFileWithWorkspaceMembers`
// (cli/cli_build.l, #6503), the single-file-inside-a-workspace leg
// `Cli.buildOne` routes through when no manifest with a `[package]` section
// sits above the source. `resolveWorkspaceImportDeps` matches an import
// against an already-built member DLL the same way `resolveManifestDependencies`
// matches a `path = "..."` dependency — so the identical stray-DLL crash
// applies: a member built for `--target dotnet` once, then imported by a
// single `.l` file built for `--target jvm`, used to feed that member's MSIL
// `.dll` straight into the JVM restored-dep JAR loader and hard-fail.
test "buildOne: --target jvm single-file import of a workspace member succeeds even though the member's --target dotnet DLL exists on disk (#6697)" {
  val root = freshTempDir("ws-import-stray-dll")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[workspace]\nexclude = []\n")

  val memberDir = mkPackageDir(
    root,
    "Member4",
    "[package]\n" + "name = \"Fixture.WsMember4\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.WsMember4\"\n" +
      "output_assembly = \"WsMember4.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.WsMember4\" = \"src/member4.l\"\n"
  )
  match File.createDir(Path.join(memberDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create member4 src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(memberDir, "src/member4.l"),
    "package Fixture.WsMember4\n\npub func memberGreeting(): String {\n  \"hello-from-member\"\n}\n"
  )

  // Build the member for --target dotnet FIRST, so its bin/WsMember4.dll (a
  // real MSIL PE) exists on disk before the single-file JVM build runs.
  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val memberRc = Cli.buildProject(
    Path.join(memberDir, "lyric.toml"),
    None,
    Emitter.Dotnet,
    noFeatures,
    false,
    false,
    true,
    None,
    noPre,
    noDefines
  )
  assertEqualInt(memberRc, 0, "buildProject: the workspace member itself builds on --target dotnet")
  assertTrue(
    File.fileExists(Path.join(Path.join(memberDir, "bin"), "WsMember4.dll")),
    "sanity: the member's --target dotnet DLL now exists on disk"
  )

  val standalonePath = Path.join(root, "standalone4.l")
  writeFileOrPanic(
    standalonePath,
    "package Fixture.Standalone4\n\nimport Std.Console as Console\nimport Fixture.WsMember4\n\nfunc main(): Int {\n  Console.println(memberGreeting())\n  0\n}\n"
  )
  val outJar = Path.join(root, "standalone4.jar")
  val noManifest: Option[String] = None
  val rc = Cli.buildOne(standalonePath, outJar, Emitter.Jvm, noManifest)
  assertEqualInt(
    rc,
    0,
    "buildOne: a --target jvm single-file build importing a workspace member must not crash just because the " +
      "member has a stray --target dotnet DLL on disk (#6697)"
  )
  assertTrue(File.fileExists(outJar), "buildOne: the Jvm build produced an output artifact")
}

// ─── Regression for #6771 — `resolveWorkspaceImportDeps` took no `target`
// param, so its DLL-existence probe (and the fatal "DLL is not built" path)
// applied unconditionally: a `--target jvm` single-file build importing a
// workspace member that was NEVER built for any target (no `bin/` DLL at
// all — the common fresh-checkout case, unlike #6697's "stray dotnet DLL"
// scenario) hard-failed even though Jvm never reads that DLL and compiles
// the member's source directly into the bundle.
test "buildOne: --target jvm single-file import of a never-built workspace member succeeds by compiling its source directly (#6771)" {
  val root = freshTempDir("ws-import-unbuilt-jvm")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[workspace]\nexclude = []\n")

  val memberDir = mkPackageDir(
    root,
    "Member5",
    "[package]\n" + "name = \"Fixture.WsMember5\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.WsMember5\"\n" +
      "output_assembly = \"WsMember5.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Fixture.WsMember5\" = \"src/member5.l\"\n"
  )
  match File.createDir(Path.join(memberDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create member5 src dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(memberDir, "src/member5.l"),
    "package Fixture.WsMember5\n\npub func memberGreeting(): String {\n  \"hello-from-unbuilt-member\"\n}\n"
  )

  // Deliberately never build the member for ANY target — no bin/ dir, no
  // DLL of any kind exists on disk.  A prior --target dotnet build is not a
  // precondition on Jvm: the member's source compiles straight into the
  // bundle (#6771).
  assertFalse(
    File.fileExists(Path.join(Path.join(memberDir, "bin"), "WsMember5.dll")),
    "sanity: the member has never been built for any target"
  )

  val standalonePath = Path.join(root, "standalone5.l")
  writeFileOrPanic(
    standalonePath,
    "package Fixture.Standalone5\n\nimport Std.Console as Console\nimport Fixture.WsMember5\n\nfunc main(): Int {\n  Console.println(memberGreeting())\n  0\n}\n"
  )
  val outJar = Path.join(root, "standalone5.jar")
  val noManifest: Option[String] = None
  val rc = Cli.buildOne(standalonePath, outJar, Emitter.Jvm, noManifest)
  assertEqualInt(
    rc,
    0,
    "buildOne: a --target jvm single-file build importing a workspace member must succeed even though the " +
      "member has never been built for any target — Jvm compiles its source directly (#6771)"
  )
  assertTrue(File.fileExists(outJar), "buildOne: the Jvm build produced an output artifact")
}

// ─── #5611 part 1: checkDllIsStale detects a --features/--target change ──────
// mtime alone cannot see that a cached dependency DLL was built under a
// DIFFERENT `--features` selection or `--target`: nothing on disk under the
// dependency's own source tree changes when the CONSUMER's invocation asks
// for different features, so the old mtime-only check silently reused the
// wrong build. `checkDllIsStale` now also compares a sidecar feature stamp
// (`writeFeatureStamp`/`featureStampPath`, `<dll>.featurestamp`) written
// after every successful workspace-dep build.
func setupStaleFixture(label: in String): (String, String, String, String) {
  val root = freshTempDir(label)
  val mfPath = Path.join(root, "lyric.toml")
  writeFileOrPanic(mfPath, "[package]\nname = \"App\"\nversion = \"0.1.0\"\n")
  val srcDir = Path.join(root, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(srcDir, "a.l"), "package App\n")
  // Written last, so it is >= the manifest/source mtimes (`fileStatIsNewer`
  // is a strict `>`, so equal timestamps still count as fresh) — isolates
  // the assertions below to the FEATURE-STAMP half of staleness, not mtime.
  val binDir = Path.join(root, "bin")
  match File.createDir(binDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create bin dir: " + IOError.message(e))
  }
  val dllPath = Path.join(binDir, "App.dll")
  writeFileOrPanic(dllPath, "not a real DLL; checkDllIsStale never opens it");
  (root, mfPath, srcDir, dllPath)
}

test "checkDllIsStale: an existing DLL with no feature stamp is stale even though mtimes are fresh (#5611)" {
  val (root, mfPath, srcDir, dllPath) = setupStaleFixture("stale-no-stamp")
  defer {
    cleanup(root)
  }
  val noFeatures: List[String] = newList()
  assertTrue(
    Cli.checkDllIsStale(dllPath, mfPath, srcDir, noFeatures, false, Emitter.Dotnet),
    "no feature stamp at all must be treated as stale, not silently trusted"
  )
}

test "checkDllIsStale: a matching feature stamp with fresh mtimes is NOT stale" {
  val (root, mfPath, srcDir, dllPath) = setupStaleFixture("stale-matching-stamp")
  defer {
    cleanup(root)
  }
  val noFeatures: List[String] = newList()
  Cli.writeFeatureStamp(dllPath, noFeatures, false, Emitter.Dotnet)
  assertFalse(
    Cli.checkDllIsStale(dllPath, mfPath, srcDir, noFeatures, false, Emitter.Dotnet),
    "identical (features, target) and fresh mtimes must resolve to NOT stale"
  )
}

test "checkDllIsStale: a different --features selection invalidates the cache even though nothing on disk changed (#5611)" {
  val (root, mfPath, srcDir, dllPath) = setupStaleFixture("stale-diff-features")
  defer {
    cleanup(root)
  }
  val builtWith: List[String] = newList()
  builtWith.add("a")
  Cli.writeFeatureStamp(dllPath, builtWith, false, Emitter.Dotnet)
  val queriedWith: List[String] = newList()
  queriedWith.add("b")
  assertTrue(
    Cli.checkDllIsStale(dllPath, mfPath, srcDir, queriedWith, false, Emitter.Dotnet),
    "a DLL built with --features a must not be silently reused for --features b"
  )
}

test "checkDllIsStale: --features order does not matter (the stamp comparison is order-independent)" {
  val (root, mfPath, srcDir, dllPath) = setupStaleFixture("stale-feature-order")
  defer {
    cleanup(root)
  }
  val builtWith: List[String] = newList()
  builtWith.add("a")
  builtWith.add("b")
  Cli.writeFeatureStamp(dllPath, builtWith, false, Emitter.Dotnet)
  val queriedReordered: List[String] = newList()
  queriedReordered.add("b")
  queriedReordered.add("a")
  assertFalse(
    Cli.checkDllIsStale(dllPath, mfPath, srcDir, queriedReordered, false, Emitter.Dotnet),
    "--features b,a must match a stamp written for --features a,b"
  )
}

test "checkDllIsStale: --no-default-features changes the stamp key too" {
  val (root, mfPath, srcDir, dllPath) = setupStaleFixture("stale-no-default-features")
  defer {
    cleanup(root)
  }
  val noFeatures: List[String] = newList()
  Cli.writeFeatureStamp(dllPath, noFeatures, false, Emitter.Dotnet)
  assertTrue(
    Cli.checkDllIsStale(dllPath, mfPath, srcDir, noFeatures, true, Emitter.Dotnet),
    "the stamp must distinguish --no-default-features from the default"
  )
}

test "checkDllIsStale: a different --target invalidates the cache" {
  val (root, mfPath, srcDir, dllPath) = setupStaleFixture("stale-diff-target")
  defer {
    cleanup(root)
  }
  val noFeatures: List[String] = newList()
  Cli.writeFeatureStamp(dllPath, noFeatures, false, Emitter.Dotnet)
  assertTrue(
    Cli.checkDllIsStale(dllPath, mfPath, srcDir, noFeatures, false, Emitter.Jvm),
    "a DLL stamped for --target dotnet must not be silently reused for --target jvm"
  )
}
