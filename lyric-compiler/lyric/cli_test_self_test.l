//! cli_test_self_test.l — end-to-end regression coverage for `Lyric.Cli`
//! behavior that lives in `cli/cli_test.l`, driven for real via
//! `Cli.main([...])` (the same entry point `lyric test` itself runs
//! through) rather than by calling private helpers directly, so these
//! tests exercise the actual compile-and-run round trip a user sees.
//!
//! Covers:
//!   - #5341: `lyric test <file.l>`'s single-file path resolves manifest
//!     dependencies from a nearby `lyric.toml`, exactly like `lyric build`/
//!     `lyric run` (D123) — a loose test file next to a manifest with a
//!     real path dependency can now import it; an unbuilt dependency fails
//!     the test run loudly rather than silently compiling without it.
//!   - #6659: `cmdTest`'s argv-parsing loop advances past `--coverage`
//!     instead of spinning on the same index forever.
//!   - #678: `lyric test --update-snapshots` rewrites a stale snapshot
//!     instead of failing the run.
//!
//! `lyric test --properties` / `--property-trials` / `--seed` coverage
//! (#677, #6907) lives in the sibling file
//! `cli_test_properties_self_test.l` — split out (#7202 CI follow-up) so
//! that file's real `dotnet exec` subprocess round trips get their own
//! independent 600s single-file `lyric test` subprocess-watchdog budget
//! instead of sharing one with every case here.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_test_self_test.l
@test_module
package Lyric.CliTestSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Uuid
import Std.Testing
import Lyric.Cli as Cli

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-clitest-" + label + "-" + uuidToString(newUuid()))
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

func argv(args: in List[String]): slice[String] {
  args.toArray()
}

func mainWith(a0: in String, a1: in String): Int {
  val args: List[String] = newList()
  args.add(a0)
  args.add(a1)
  Cli.main(argv(args))
}

func mainWith3(a0: in String, a1: in String, a2: in String): Int {
  val args: List[String] = newList()
  args.add(a0)
  args.add(a1)
  args.add(a2)
  Cli.main(argv(args))
}

func mainWithArgs(args: in List[String]): Int {
  Cli.main(argv(args))
}

// ─────────────────────────────────────────────────────────────────────────────
// #5341: single-file `lyric test` manifest dependency resolution.
// ─────────────────────────────────────────────────────────────────────────────
test "lyric test <file.l>: resolves a workspace-path dependency declared in a nearby lyric.toml" {
  val root = freshTempDir("dep-ok")
  defer {
    cleanup(root)
  }
  val libDir = Path.join(root, "libpkg")
  val appDir = Path.join(root, "app")
  match File.createDir(Path.join(libDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }
  match File.createDir(Path.join(appDir, "tests")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }

  writeFileOrPanic(
    Path.join(libDir, "lyric.toml"),
    "[package]\nname = \"libpkg\"\nversion = \"0.1.0\"\n\n[project]\nname = \"libpkg\"\noutput = \"single\"\noutput_assembly = \"libpkg.dll\"\n\n[project.packages]\n\"Libpkg\" = \"src/lib.l\"\n"
  )
  writeFileOrPanic(Path.join(libDir, "src/lib.l"), "package Libpkg\n\npub func triple(x: in Int): Int {\n  x * 3\n}\n")

  writeFileOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[project]\nname = \"app\"\noutput = \"single\"\noutput_assembly = \"app.dll\"\n\n[project.packages]\n\"App\" = \"src/app.l\"\n\n[dependencies]\nlibpkg = { path = \"../libpkg\" }\n"
  )
  match File.createDir(Path.join(appDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(appDir, "src/app.l"), "package App\n\npub func addOne(x: in Int): Int {\n  x + 1\n}\n")

  val testFile = Path.join(appDir, "tests/app_test.l")
  writeFileOrPanic(
    testFile,
    "@test_module\npackage AppDepTest\n\nimport Libpkg\nimport Std.Testing\n\ntest \"triple via dependency\" {\n  Std.Testing.assertEqualInt(Libpkg.triple(4), 12, \"triple(4)\")\n}\n"
  )

  // Build the dependency first (mirrors a real workflow: `lyric build` the
  // library, then `lyric test` a file that depends on it).
  val libBuildRc = mainWith3("build", "--manifest", Path.join(libDir, "lyric.toml"))
  assertEqualInt(libBuildRc, 0, "dependency builds cleanly")

  val testRc = mainWith("test", testFile)
  assertEqualInt(testRc, 0, "lyric test <file.l> resolves and runs against the path dependency")
}

test "lyric test <file.l>: an unbuilt dependency fails the test run loudly (no silent skip)" {
  val root = freshTempDir("dep-unbuilt")
  defer {
    cleanup(root)
  }
  val libDir = Path.join(root, "libpkg")
  val appDir = Path.join(root, "app")
  match File.createDir(Path.join(libDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }
  match File.createDir(Path.join(appDir, "tests")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }

  writeFileOrPanic(
    Path.join(libDir, "lyric.toml"),
    "[package]\nname = \"libpkg2\"\nversion = \"0.1.0\"\n\n[project]\nname = \"libpkg2\"\noutput = \"single\"\noutput_assembly = \"libpkg2.dll\"\n\n[project.packages]\n\"Libpkg2\" = \"src/lib.l\"\n"
  )
  writeFileOrPanic(Path.join(libDir, "src/lib.l"), "package Libpkg2\n\npub func triple(x: in Int): Int {\n  x * 3\n}\n")

  writeFileOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\nname = \"app2\"\nversion = \"0.1.0\"\n\n[project]\nname = \"app2\"\noutput = \"single\"\noutput_assembly = \"app2.dll\"\n\n[project.packages]\n\"App2\" = \"src/app.l\"\n\n[dependencies]\nlibpkg2 = { path = \"../libpkg\" }\n"
  )
  match File.createDir(Path.join(appDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(appDir, "src/app.l"), "package App2\n\npub func addOne(x: in Int): Int {\n  x + 1\n}\n")

  val testFile = Path.join(appDir, "tests/app_test.l")
  writeFileOrPanic(
    testFile,
    "@test_module\npackage AppDepUnbuiltTest\n\nimport Libpkg2\nimport Std.Testing\n\ntest \"triple via dependency\" {\n  Std.Testing.assertEqualInt(Libpkg2.triple(4), 12, \"triple(4)\")\n}\n"
  )

  // The dependency is declared but deliberately never built — the run must
  // fail loud, not silently compile without it (D123's conservative
  // single-file contract, now also honored by `lyric test`).
  val testRc = mainWith("test", testFile)
  assertEqualInt(
    testRc,
    1,
    "an unbuilt declared dependency fails the test run rather than silently compiling without it"
  )
}

test "lyric test <file.l>: a loose file with no nearby manifest still works unchanged" {
  val root = freshTempDir("no-manifest")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "plain_test.l")
  writeFileOrPanic(
    testFile,
    "@test_module\npackage PlainTest\n\nimport Std.Testing\n\ntest \"sanity\" {\n  Std.Testing.assertTrue(1 + 1 == 2, \"arithmetic works\")\n}\n"
  )
  val rc = mainWith("test", testFile)
  assertEqualInt(rc, 0, "a standalone test file with no manifest anywhere compiles and passes as before")
}

// #6659: `cmdTest`'s argv-parsing loop's `--coverage` branch was missing its
// own `i += 1`, so ANY invocation with `--coverage` in argv spun forever
// re-processing the same index instead of advancing — a busy-loop that
// never reached the java/coverage codegen the original #6659 investigation
// suspected, explaining why the internal 600s/120s timeouts inside that
// codegen never fired. Places `--coverage` before `--target dotnet` (not
// the last argv token) so a still-buggy parser would spin here forever
// instead of ever reaching --target's own validation; a fixed parser
// reaches the (fast, deterministic, no JaCoCo jars needed) "--coverage
// requires --target jvm" rejection.
test "lyric test --coverage: argv parser advances past --coverage to a later flag (regression, #6659)" {
  val root = freshTempDir("coverage-argv-order")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "cov_test.l")
  writeFileOrPanic(
    testFile,
    "@test_module\npackage CovArgvOrder\nimport Std.Testing\n\ntest \"trivial\" {\n  Std.Testing.assertTrue(true, \"ok\")\n}\n"
  )

  val args: List[String] = newList()
  args.add("test")
  args.add(testFile)
  args.add("--coverage")
  args.add("--target")
  args.add("dotnet")
  val rc = mainWithArgs(args)
  assertEqualInt(
    rc,
    1,
    "--coverage before --target dotnet reaches the --target-jvm-required rejection, proving the parser advanced past --coverage"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// #678: `lyric test --update-snapshots`.
// ─────────────────────────────────────────────────────────────────────────────
// This test runs BEFORE the `--update-snapshots` one below on purpose: both
// run in-process via `Cli.main` in this same test binary, and
// `Environment.setVar` (which `--update-snapshots` uses to signal
// `Std.Testing.Snapshot`) is a real, persistent OS-level env var with no
// automatic per-call scoping — the "without the flag" case must run first,
// before anything in this process has ever set `LYRIC_UPDATE_SNAPSHOTS`.
test "lyric test (no --update-snapshots): a stale snapshot still fails the run and is left untouched" {
  val root = freshTempDir("snap-noupdate")
  defer {
    cleanup(root)
  }
  val snapDir = Path.join(root, "snapshots")
  match File.createDir(snapDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }
  val snapPath = Path.join(snapDir, "greeting.txt")
  writeFileOrPanic(snapPath, "old-hello")

  val testFile = Path.join(root, "snap_test.l")
  writeFileOrPanic(
    testFile,
    "@test_module\npackage SnapNoUpdateTest\n\nimport Std.Testing.Snapshot\nimport Std.Testing\n\ntest \"greeting matches\" {\n  Snapshot.snapshotMatchIn(\"" +
      snapDir +
      "\", \"greeting\", \"new-hello\")\n}\n"
  )

  val rc = mainWith("test", testFile)
  assertEqualInt(rc, 1, "a real mismatch against a stale snapshot still fails the run without --update-snapshots")

  val afterContent = match File.readText(snapPath) {
    case Ok(s) -> s
    case Err(e) -> panic("cannot read " + snapPath + ": " + IOError.message(e))
  }
  assertEqual(afterContent, "old-hello", "without --update-snapshots the stale snapshot file is left untouched")
}

test "lyric test --update-snapshots: rewrites a stale snapshot instead of failing the run (#678)" {
  val root = freshTempDir("snap-update")
  defer {
    cleanup(root)
    // Reset for hygiene: this is a real OS-level env var in this
    // long-lived in-process test binary, and nothing else in this file
    // should ever see LYRIC_UPDATE_SNAPSHOTS=1 leak forward.
    Environment.setVar("LYRIC_UPDATE_SNAPSHOTS", "")
  }
  val snapDir = Path.join(root, "snapshots")
  match File.createDir(snapDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create dir: " + IOError.message(e))
  }
  val snapPath = Path.join(snapDir, "greeting.txt")
  writeFileOrPanic(snapPath, "old-hello")

  val testFile = Path.join(root, "snap_test.l")
  writeFileOrPanic(
    testFile,
    "@test_module\npackage SnapUpdateTest\n\nimport Std.Testing.Snapshot\nimport Std.Testing\n\ntest \"greeting matches\" {\n  Snapshot.snapshotMatchIn(\"" +
      snapDir +
      "\", \"greeting\", \"new-hello\")\n}\n"
  )

  val rc = mainWith3("test", testFile, "--update-snapshots")
  assertEqualInt(rc, 0, "--update-snapshots rewrites the stale snapshot instead of failing the run")

  val afterContent = match File.readText(snapPath) {
    case Ok(s) -> s
    case Err(e) -> panic("cannot read " + snapPath + ": " + IOError.message(e))
  }
  assertEqual(afterContent, "new-hello", "--update-snapshots overwrote the stale snapshot file with the actual value")
}
