//! cli_run_native_project_self_test.l — CLI-level regression coverage for
//! #6815 items 2 and 3(a): `--triple`/`--opt` CLI-flag threading into a
//! `--manifest ... --target native` project build, and
//! `lyric run --manifest ... --target native` actually executing the
//! produced binary instead of refusing.
//!
//! Exercised at the exact CLI entry points a real `lyric build`/`lyric run`
//! invocation drives (`Lyric.Cli.buildProjectWithNativeFlags` /
//! `Lyric.Cli.runProjectOnce`), not the lower-level `Emitter.emitNativeProject`
//! /`Lyric.LlvmBridge.compileProjectToNativeWithFlags` API surface
//! `llvm_project_self_test.l` covers — a fixture calling those directly
//! would not catch a CLI-layer regression where `--triple`/`--opt` never
//! reach the request, or `runProjectOnce` refuses `Native` outright.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (this file imports
//! the compiler package `Lyric.Cli`):
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/cli_run_native_project_self_test.l
@test_module
package Lyric.CliRunNativeProjectSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-native-projrun-" + label + "-" + uuidToString(newUuid()))
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

// A minimal single-package native project manifest with NO `[native]`
// table, so any effective triple/opt comes ENTIRELY from the CLI flags
// under test (never a manifest fallback masking a plumbing regression).
func writeOnePkgNativeProject(root: in String, appName: in String, srcBody: in String): String {
  writeFileOrPanic(
    Path.join(root, "lyric.toml"),
    "[package]\n" + "name = \"" + appName + "\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" + "name = \"" +
      appName +
      "\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"" +
      appName +
      "\" = \"src/app.l\"\n"
  )
  match File.createDir(Path.join(root, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(root, "src/app.l"), srcBody)
  Path.join(root, "lyric.toml")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item 2: `--triple`/`--opt` project-mode threading.
// ─────────────────────────────────────────────────────────────────────────────
test "buildProjectWithNativeFlags: an empty --triple/--opt uses the host default and succeeds" {
  val root = freshTempDir("triple-empty")
  defer {
    cleanup(root)
  }
  val mfPath = writeOnePkgNativeProject(
    root,
    "Fixture.TripleEmpty",
    "package Fixture.TripleEmpty\n\nfunc main(): Int {\n  0\n}\n"
  )
  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProjectWithNativeFlags(
    mfPath,
    None,
    Emitter.Native,
    noFeatures,
    false,
    false,
    false,
    None,
    noPre,
    noDefines,
    "",
    ""
  )
  assertEqualInt(rc, 0, "empty --triple/--opt: host-default native project build succeeds")
}

test "buildProjectWithNativeFlags: a bogus --triple CLI override reaches native project codegen and fails the build (#6815 item 2)" {
  val root = freshTempDir("triple-bogus")
  defer {
    cleanup(root)
  }
  val mfPath = writeOnePkgNativeProject(
    root,
    "Fixture.TripleBogus",
    "package Fixture.TripleBogus\n\nfunc main(): Int {\n  0\n}\n"
  )
  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  // Before #6815 item 2, `buildProjectFromManifest`'s native branch only ever
  // read the manifest's own `[native]` table (absent here) and silently
  // ignored this CLI override entirely, so the build would have used the
  // host default triple and SUCCEEDED — masking the exact plumbing gap this
  // test exists to catch. Post-fix, the override reaches
  // `compileProjectToNativeWithFlags` -> clang, which rejects the unknown
  // triple, so the project build now fails.
  val rc = Cli.buildProjectWithNativeFlags(
    mfPath,
    None,
    Emitter.Native,
    noFeatures,
    false,
    false,
    false,
    None,
    noPre,
    noDefines,
    "bogus-target-triple-xyz",
    ""
  )
  assertTrue(
    rc != 0,
    "a bogus --triple override must reach codegen and fail the native project build, not be silently dropped"
  )
}

test "runWatchAction: --watch --manifest --target native threads --triple/--opt too, not just the non-watch path (#6899 review finding)" {
  val root = freshTempDir("watch-triple-bogus")
  defer {
    cleanup(root)
  }
  val mfPath = writeOnePkgNativeProject(
    root,
    "Fixture.WatchTripleBogus",
    "package Fixture.WatchTripleBogus\n\nfunc main(): Int {\n  0\n}\n"
  )
  val noFeatures: List[String] = newList()
  val noOut: Option[String] = None
  val noPkgVer: Option[String] = None
  // Before this fix, `WatchAction.BuildProj` carried no `nativeTriple`/
  // `nativeOpt` fields at all and `runWatchAction`'s arm called plain
  // `buildProject` (which always passes empty triple/opt) instead of
  // `buildProjectWithNativeFlags` — so a `--watch --manifest ... --target
  // native` invocation silently dropped `--triple`/`--opt` on every
  // rebuild, even though the exact same flags worked on the non-watch path
  // (the sibling test above). This action carries a bogus triple; if it
  // were still being dropped, the build would succeed using the host
  // default instead of failing at clang.
  val rc = Cli.runWatchAction(
    Cli.BuildProj(
      mfPath = mfPath,
      outArg = noOut,
      target = Emitter.Native,
      feats = noFeatures,
      noDef = false,
      allF = false,
      noRestore = false,
      pkgVer = noPkgVer,
      profile = Cli.ProfDebug,
      nativeTriple = "bogus-target-triple-xyz",
      nativeOpt = ""
    )
  )
  assertTrue(
    rc != 0,
    "a bogus --triple must reach codegen and fail the build under --watch too, not be silently dropped"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Item 3(a): `lyric run --manifest ... --target native` executes the binary.
// ─────────────────────────────────────────────────────────────────────────────
test "runProjectOnce: --target native builds and directly executes a single-package project's binary (#6815 item 3a)" {
  val root = freshTempDir("run-single")
  defer {
    cleanup(root)
  }
  val mfPath = writeOnePkgNativeProject(
    root,
    "Fixture.RunSingle",
    "package Fixture.RunSingle\n\nfunc main(): Int {\n  21 + 21\n}\n"
  )
  val noArgs: List[String] = newList()
  // Before #6815 item 3a this unconditionally returned 1 with "run: --target
  // native does not yet support manifest (multi-package) projects", even
  // though the build immediately above it in `runProjectOnce` had already
  // succeeded and produced a runnable binary.
  val rc = Cli.runProjectOnce(mfPath, noArgs, Emitter.Native)
  assertEqualInt(rc, 42, "runProjectOnce executes the native project binary directly and surfaces its real exit code")
}

test "runProjectOnce: --target native project run forwards user args to the binary's Environment.args()" {
  val root = freshTempDir("run-args")
  defer {
    cleanup(root)
  }
  // Exit with the forwarded argument count so the assertion doesn't depend
  // on capturing the child's inherited stdout (`Cli.runProjectOnce` runs the
  // native binary via `Std.Process.run`, which streams stdio through rather
  // than capturing it, matching the single-file `runOnce` Native case).
  val mfPath = writeOnePkgNativeProject(
    root,
    "Fixture.RunArgs",
    "package Fixture.RunArgs\n\nimport Std.Environment as Environment\n\nfunc main(): Int {\n  Environment.args().length\n}\n"
  )
  val userArgs: List[String] = newList()
  userArgs.add("one")
  userArgs.add("two")
  val rc = Cli.runProjectOnce(mfPath, userArgs, Emitter.Native)
  // `Environment.args()` includes argv[0] (the program path), matching the
  // managed `GetCommandLineArgs` convention (lyric_rt.h's `lyric_args_get`
  // doc comment) — 2 forwarded user args plus argv[0] is 3.
  assertEqualInt(rc, 3, "runProjectOnce: native project run forwards user args through to Environment.args()")
}
