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
//!   - #677: `lyric test --properties` actually executes `property`
//!     declarations whose `forall` binders are all Int/Bool/Double,
//!     instead of unconditionally skipping them; an unsupported binder
//!     type still skips even under `--properties`; `--properties` is
//!     rejected on `--target native`.
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

// ─────────────────────────────────────────────────────────────────────────────
// #677: `lyric test --properties`.
// ─────────────────────────────────────────────────────────────────────────────
func propFixtureSource(propBody: in String): String {
  "@test_module\npackage PropFixture\n\nimport Std.Testing\n\ntest \"sanity\" {\n  Std.Testing.assertTrue(1 + 1 == 2, \"arithmetic works\")\n}\n\n" +
    propBody
}

test "lyric test --properties: an always-failing Int property is caught and fails the run" {
  val root = freshTempDir("prop-fail")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"always fails\" forall(x: Int) {\n  Std.Testing.assertTrue(false, \"always fails\")\n}\n"
    )
  )

  // Without --properties, the property is skipped (v1 behaviour, unchanged)
  // and the file passes on its one real test.
  val skipRc = mainWith("test", testFile)
  assertEqualInt(skipRc, 0, "without --properties the failing property is skipped, not run")

  // With --properties, the sampling-and-shrinking harness actually runs the
  // property and it genuinely fails.
  val runRc = mainWith3("test", testFile, "--properties")
  assertEqualInt(runRc, 1, "with --properties an always-failing property fails the test run")
}

test "lyric test --properties: an always-true Int property passes" {
  val root = freshTempDir("prop-pass")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"identity always holds\" forall(x: Int) {\n  Std.Testing.assertTrue(x == x, \"identity always holds\")\n}\n"
    )
  )

  val runRc = mainWith3("test", testFile, "--properties")
  assertEqualInt(runRc, 0, "with --properties a property that holds for every sample passes")
}

test "lyric test --properties: a Bool/Double forall also executes for real" {
  val root = freshTempDir("prop-booldouble")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"bool and double identities hold\" forall(b: Bool, d: Double) {\n  Std.Testing.assertTrue(b == b, \"bool identity\")\n  Std.Testing.assertTrue(d == d, \"double identity\")\n}\n"
    )
  )

  val runRc = mainWith3("test", testFile, "--properties")
  assertEqualInt(runRc, 0, "a multi-binder Bool/Double property samples and passes")
}

test "lyric test --properties: a where guard is honoured (a guard that is always false never fails the run)" {
  val root = freshTempDir("prop-guard")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"vacuous under an always-false guard\" forall(x: Int)\n  where false\n{\n  Std.Testing.assertTrue(false, \"never reached\")\n}\n"
    )
  )

  val runRc = mainWith3("test", testFile, "--properties")
  assertEqualInt(runRc, 0, "a guard that never holds means the body never runs, so the property never fails")
}

test "lyric test --properties: a property with no forall binders still runs its guarded body once" {
  val root = freshTempDir("prop-noforall")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"binder-less property fails\" {\n  Std.Testing.assertTrue(false, \"binder-less property always fails\")\n}\n"
    )
  )

  val runRc = mainWith3("test", testFile, "--properties")
  assertEqualInt(runRc, 1, "a property with no forall binders still executes its body under --properties")
}

test "lyric test --properties: an unsupported forall binder type still skips (no crash, no false failure)" {
  val root = freshTempDir("prop-unsupported")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"unsupported binder type\" forall(x: String) {\n  Std.Testing.assertTrue(true, \"never actually runs\")\n}\n"
    )
  )

  val runRc = mainWith3("test", testFile, "--properties")
  assertEqualInt(runRc, 0, "an unsupported binder type is skipped even under --properties, not a compile/runtime error")
}

test "lyric test --properties: rejected on --target native" {
  val root = freshTempDir("prop-native")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource("property \"whatever\" forall(x: Int) {\n  Std.Testing.assertTrue(true, \"n/a\")\n}\n")
  )

  // `--properties --target native` needs 5 argv slots; build it by hand
  // rather than adding another `mainWithN` helper for one call site.
  val args: List[String] = newList()
  args.add("test")
  args.add(testFile)
  args.add("--properties")
  args.add("--target")
  args.add("native")
  val realRc = Cli.main(argv(args))
  assertEqualInt(realRc, 1, "--properties is rejected outright on --target native")
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
