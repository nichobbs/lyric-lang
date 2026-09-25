//! cli_test_property_trials_self_test.l — end-to-end regression coverage for
//! `lyric test --property-trials <N>` / `--seed <N>` (property-testing v2
//! slice 1, #6907), driven for real via `Cli.main([...])` (the same entry
//! point `lyric test` itself runs through) rather than by calling private
//! helpers directly, so these tests exercise the actual compile-and-run
//! round trip a user sees.
//!
//! Split out of `cli_test_properties_self_test.l` (#7202 CI follow-up,
//! second pass): local timing showed that even a *non*-property-testing
//! six-case slice of the original `cli_test_self_test.l` could alone
//! approach the single-file `lyric test` 600s subprocess watchdog
//! (`cli_test.l`'s `ProcessCapture.runCaptureWithDiagnosticsTimeout(...,
//! 600000)`) under this-environment contention — and the real CI run this
//! split responds to (run 35669328920) only got through ~7 of
//! `cli_test_self_test.l`'s 23 cases before hitting that same 600s ceiling.
//! A single file bundling every `--properties`/`--property-trials`/`--seed`
//! case (17 real `dotnet exec` subprocess round trips) would not have had
//! enough margin under that budget even split just once from the
//! dependency-resolution/snapshot cases. Splitting the `#677` core property
//! cases (`cli_test_properties_self_test.l`, 7 cases) from this file's
//! `#6907` v2-slice-1 cases (10 cases, 5 of which are argv-validation-only
//! and return before ever compiling/running anything) keeps each compiled
//! test binary's real-subprocess-round-trip count in the same ballpark
//! real CI demonstrated it can clear in 600s, each with its own independent
//! budget — the same shape `native-backend-self-tests` was pulled into its
//! own CI job for: many sequential subprocess-spawning cases contending for
//! one shared budget.
//!
//! Covers #6907 (property-testing v2 slice 1): `--property-trials <N>` /
//! `--seed <N>` tune the `--properties` sampling-and-shrinking harness
//! (`PropertyRunConfig`, `test_synth.l`); both flags require `--properties`
//! itself, a loud error rather than a silent no-op.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_test_property_trials_self_test.l
@test_module
package Lyric.CliTestPropertyTrialsSelfTest

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

func mainWithArgs(args: in List[String]): Int {
  Cli.main(argv(args))
}

func propFixtureSource(propBody: in String): String {
  "@test_module\npackage PropFixture\n\nimport Std.Testing\n\ntest \"sanity\" {\n  Std.Testing.assertTrue(1 + 1 == 2, \"arithmetic works\")\n}\n\n" +
    propBody
}

// ─────────────────────────────────────────────────────────────────────────────
// v2 slice 1 (#6907): `--property-trials <N>` / `--seed <N>` tune the
// `--properties` sampling-and-shrinking harness (`PropertyRunConfig`,
// `test_synth.l`).  Both flags require `--properties` itself — a loud error,
// not a silent no-op.
// ─────────────────────────────────────────────────────────────────────────────
func mainWithExtra(testFile: in String, extra: in List[String]): Int {
  val args: List[String] = newList()
  args.add("test")
  args.add(testFile)
  var i = 0
  while i < extra.count {
    args.add(extra[i])
    i = i + 1
  }
  mainWithArgs(args)
}

func listOf2(a: in String, b: in String): List[String] {
  val l: List[String] = newList()
  l.add(a)
  l.add(b)
  l
}

func listOf3(a: in String, b: in String, c: in String): List[String] {
  val l: List[String] = newList()
  l.add(a)
  l.add(b)
  l.add(c)
  l
}

test "lyric test --property-trials: rejected without --properties" {
  val root = freshTempDir("prop-trials-noflag")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource("property \"whatever\" forall(x: Int) {\n  Std.Testing.assertTrue(true, \"n/a\")\n}\n")
  )
  val rc = mainWithExtra(testFile, listOf2("--property-trials", "10"))
  assertEqualInt(rc, 1, "--property-trials without --properties is a loud error, not a silent no-op")
}

test "lyric test --seed: rejected without --properties" {
  val root = freshTempDir("prop-seed-noflag")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource("property \"whatever\" forall(x: Int) {\n  Std.Testing.assertTrue(true, \"n/a\")\n}\n")
  )
  val rc = mainWithExtra(testFile, listOf2("--seed", "5"))
  assertEqualInt(rc, 1, "--seed without --properties is a loud error, not a silent no-op")
}

test "lyric test --property-trials: rejects a count below 1" {
  val root = freshTempDir("prop-trials-zero")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource("property \"whatever\" forall(x: Int) {\n  Std.Testing.assertTrue(true, \"n/a\")\n}\n")
  )
  val rc = mainWithExtra(testFile, listOf3("--properties", "--property-trials", "0"))
  assertEqualInt(rc, 1, "--property-trials 0 is rejected (must be >= 1)")
}

test "lyric test --property-trials: rejects a non-integer value" {
  val root = freshTempDir("prop-trials-notint")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource("property \"whatever\" forall(x: Int) {\n  Std.Testing.assertTrue(true, \"n/a\")\n}\n")
  )
  val rc = mainWithExtra(testFile, listOf3("--properties", "--property-trials", "abc"))
  assertEqualInt(rc, 1, "--property-trials abc is rejected (not an integer)")
}

test "lyric test --seed: rejects a non-integer value" {
  val root = freshTempDir("prop-seed-notint")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource("property \"whatever\" forall(x: Int) {\n  Std.Testing.assertTrue(true, \"n/a\")\n}\n")
  )
  val rc = mainWithExtra(testFile, listOf3("--properties", "--seed", "abc"))
  assertEqualInt(rc, 1, "--seed abc is rejected (not an integer)")
}

test "lyric test --property-trials 1: an always-failing property still fails with a single trial" {
  val root = freshTempDir("prop-trials-one-fail")
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
  val rc = mainWithExtra(testFile, listOf3("--properties", "--property-trials", "1"))
  assertEqualInt(rc, 1, "an always-failing property still fails the run even sampled just once")
}

test "lyric test --property-trials 500 --seed 42: an always-true property still passes with a larger sample and an explicit seed" {
  val root = freshTempDir("prop-trials-many-pass")
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
  val args: List[String] = newList()
  args.add("test")
  args.add(testFile)
  args.add("--properties")
  args.add("--property-trials")
  args.add("500")
  args.add("--seed")
  args.add("42")
  val rc = mainWithArgs(args)
  assertEqualInt(rc, 0, "a property that holds for every sample passes under a larger trial count and an explicit seed")
}

// #6907: two properties in the same file must not collide on the same RNG
// seed — `tryBuildPropertyDriver` offsets each property's seed by its own
// index (`cfg.seed.xor(idx)`), so an explicit `--seed` still gives every
// property in the file a distinct starting seed, not the literal same one.
test "lyric test --seed: two properties in one file each still pass under an explicit shared seed" {
  val root = freshTempDir("prop-seed-multi")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"first identity\" forall(x: Int) {\n  Std.Testing.assertTrue(x == x, \"first identity\")\n}\n\n" +
        "property \"second identity\" forall(y: Int) {\n  Std.Testing.assertTrue(y == y, \"second identity\")\n}\n"
    )
  )
  val rc = mainWithExtra(testFile, listOf3("--properties", "--seed", "7"))
  assertEqualInt(rc, 0, "both properties pass under the same explicit --seed")
}

// Regression test for the fix that replaced `cfg.seed + idx` with
// `cfg.seed.xor(idx)` in `tryBuildPropertyDriver` (test_synth.l): `Int` is
// 32-bit, so an addition-based offset overflows (and panics, since overflow
// checks are unconditional pending #6263) the moment a second property's
// index is added to a `--seed` near `Int32.MaxValue`. XOR is always
// in-range. Pins this down against a future accidental revert to `+`.
test "lyric test --seed 2147483647: a two-property file does not overflow-panic (XOR offset, not addition)" {
  val root = freshTempDir("prop-seed-overflow")
  defer {
    cleanup(root)
  }
  val testFile = Path.join(root, "prop_test.l")
  writeFileOrPanic(
    testFile,
    propFixtureSource(
      "property \"first identity\" forall(x: Int) {\n  Std.Testing.assertTrue(x == x, \"first identity\")\n}\n\n" +
        "property \"second identity\" forall(y: Int) {\n  Std.Testing.assertTrue(y == y, \"second identity\")\n}\n"
    )
  )
  val rc = mainWithExtra(testFile, listOf3("--properties", "--seed", "2147483647"))
  assertEqualInt(rc, 0, "an extreme --seed near Int32.MaxValue does not overflow-panic on a multi-property file")
}

// D-progress-0942 documents that a negative --seed is intentionally
// accepted (any Int is a valid RNG seed for Std.Random.makeRandom, unlike
// --property-trials, which is validated >= 1) rather than merely
// unrejected by omission. Pins that down against a future accidental
// tightening of the validation.
test "lyric test --seed -1: a negative seed is accepted, not rejected" {
  val root = freshTempDir("prop-seed-negative")
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
  val rc = mainWithExtra(testFile, listOf3("--properties", "--seed", "-1"))
  assertEqualInt(rc, 0, "a negative --seed is accepted (any Int is a valid RNG seed), not rejected")
}
