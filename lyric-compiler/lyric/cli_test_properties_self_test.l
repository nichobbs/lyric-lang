//! cli_test_properties_self_test.l — end-to-end regression coverage for
//! `Lyric.Cli`'s `lyric test --properties` sampling-and-shrinking harness
//! (#677), driven for real via `Cli.main([...])` (the same entry point
//! `lyric test` itself runs through) rather than by calling private helpers
//! directly, so these tests exercise the actual compile-and-run round trip
//! a user sees.
//!
//! Split out of `cli_test_self_test.l` (#7202 CI follow-up). Every case
//! here performs at least one REAL `dotnet exec` subprocess round trip
//! (running the compiled property-test binary), and bundling every
//! `--properties`/`--property-trials`/`--seed`/dependency-resolution/
//! snapshot case into one compiled test binary risked the single-file
//! `lyric test` 600s subprocess watchdog (`cli_test.l`'s
//! `ProcessCapture.runCaptureWithDiagnosticsTimeout(..., 600000)`) under
//! contention on a shared CI runner (run 35669328920 only got through ~7 of
//! `cli_test_self_test.l`'s original 23 cases in 600s). This is not a hang
//! in any individual case: the 0-binder property driver in
//! `tryBuildPropertyDriver` (`test_synth.l`) takes a single guarded
//! execution with no loop at all, and the N-binder sampling/shrink loops
//! are all bounded — `shrinkInt`/`shrinkBool` (`testing_property.l`) shrink
//! toward `0`/`false` and terminate in `O(log n)` steps, so the panic/
//! shrink path an always-failing property takes converges quickly rather
//! than looping. A local repro confirmed this further: even a *non*-
//! property six-case slice of the original file (dependency resolution +
//! snapshots, zero property tests) alone approached the same 600s ceiling
//! under this-environment contention, which is why the `--property-trials`/
//! `--seed` cases (#6907) live in their own further-split sibling file,
//! `cli_test_property_trials_self_test.l`, rather than bundled in here —
//! keeping each compiled test binary's real-subprocess-round-trip count in
//! the same ballpark real CI demonstrated it can clear in 600s, each with
//! its own independent budget. Same shape `native-backend-self-tests` was
//! pulled into its own CI job for: many sequential subprocess-spawning
//! cases contending for one shared budget.
//!
//! Covers #677: `lyric test --properties` actually executes `property`
//! declarations whose `forall` binders are all Int/Bool/Double, instead of
//! unconditionally skipping them; an unsupported binder type still skips
//! even under `--properties`; `--properties` is rejected on `--target
//! native`.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_test_properties_self_test.l
@test_module
package Lyric.CliTestPropertiesSelfTest

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
