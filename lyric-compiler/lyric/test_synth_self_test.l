//! test_synth_self_test.l — exercises the self-hosted Lyric.TestSynth
//! library.
//!
//! Run via `lyric test lyric-compiler/lyric/test_synth_self_test.l`.
//! Replaces the F# SelfHostedTestSynthTests.fs wrapper (#2580).
@test_module
package Lyric.TestSynthSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.TestSynth

func passingSource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\ntest \"a\" { assertTrue(true, \"x\") }\ntest \"b\" { assertTrue(true, \"y\") }\n"
}

func noModuleSource(): String {
  "package P\n\nfunc main(): Unit { println(\"hi\") }\n"
}

func userMainSource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\nfunc main(): Unit { println(\"oops\") }\ntest \"a\" { assertTrue(true, \"x\") }\n"
}

func fixtureSource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\nfixture clock: Int = 0\n\ntest \"a\" { assertTrue(true, \"x\") }\n"
}

func propertySource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\ntest \"unit\" { assertTrue(true, \"x\") }\nproperty \"prop\" forall (n: Int) { assertTrue(true, \"x\") }\n"
}

func testSynthesisesPassingTwoTests(): Unit {
  // Use Some(value = "") rather than None: both mean "no active filter"
  // (empty string is a substring of every title), but Some avoids the
  // cross-assembly nullary-union ABI mismatch for Option[String] between
  // the self-hosted emitter (test program) and the F# bootstrap-compiled
  // Lyric.TestSynth.dll (#2557).
  match synthesize(passingSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 2, "two tests detected")
      assertEqualInt(sk, 0, "no skips")
      // Synthesised source includes two helper functions and a main.
      assertTrue(Str.contains(rewritten, "func __lyric_test_0(): Unit"), "test 0 fn")
      assertTrue(Str.contains(rewritten, "func __lyric_test_1(): Unit"), "test 1 fn")
      assertTrue(Str.contains(rewritten, "func main(): Int"), "synth main")
      assertTrue(Str.contains(rewritten, "println(\"1..2\")"), "TAP plan line")
      assertTrue(Str.contains(rewritten, "ok 1 - a"), "ok 1 line")
      assertTrue(Str.contains(rewritten, "ok 2 - b"), "ok 2 line")
      assertTrue(Str.contains(rewritten, "catch Bug as __lyric_e"), "catch")
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

func testRejectsMissingTestModule(): Unit {
  match synthesize(noModuleSource(), None) {
    case NoTestModule(_) -> {
    }
    case _ -> panic("expected NoTestModule")
  }
}

func testRejectsUserMain(): Unit {
  match synthesize(userMainSource(), None) {
    case UserMainExists(_) -> {
    }
    case _ -> panic("expected UserMainExists")
  }
}

func testSynthesisesFixture(): Unit {
  match synthesize(fixtureSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 1, "one test")
      assertEqualInt(sk, 0, "no skips")
      assertTrue(Str.contains(rewritten, "val clock: Int = 0"), "fixture rewritten as val")
      assertTrue(not Str.contains(rewritten, "fixture "), "no fixture keyword in output")
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

func testPropertyReportedAsSkip(): Unit {
  // Use Some(value = "") for the same reason as testSynthesisesPassingTwoTests
  // (#2557 cross-assembly nullary-union ABI).
  match synthesize(propertySource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 1, "one runnable test")
      assertEqualInt(sk, 1, "one skip")
      assertTrue(Str.contains(rewritten, "ok 1 - unit"), "test runs")
      assertTrue(Str.contains(rewritten, "# skip 2 - prop: property: not implemented in v1"), "property skip line")
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

func testFilterSkipsNonMatching(): Unit {
  match synthesize(passingSource(), Some(value = "a")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 2, "still two tests parsed")
      assertEqualInt(sk, 0, "skip count is zero (skips here come from filter, not from properties)")
      assertTrue(Str.contains(rewritten, "ok 1 - a"), "matching test runs")
      assertTrue(Str.contains(rewritten, "# skip 2 - b (filter)"), "non-matching test skipped")
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

func testListEntriesEnumerates(): Unit {
  match listEntries(propertySource()) {
    case Ok(xs) -> {
      assertEqualInt(xs.count, 2, "test + property entry")
      match xs[0] {
        case TestEntry(t) -> assertEqual(t, "unit", "first entry is test 'unit'")
        case _ -> panic("expected TestEntry first")
      }
      match xs[1] {
        case PropertyEntry(t, _) -> assertEqual(t, "prop", "second entry is property 'prop'")
        case _ -> panic("expected PropertyEntry second")
      }
    }
    case Err(_) -> panic("listEntries unexpectedly errored")
  }
}

test "synthesises passing two tests" {
  testSynthesisesPassingTwoTests()
}

test "rejects missing @test_module" {
  testRejectsMissingTestModule()
}

test "rejects user-defined main" {
  testRejectsUserMain()
}

test "synthesises fixture as val" {
  testSynthesisesFixture()
}

test "property reported as skip" {
  testPropertyReportedAsSkip()
}

test "filter skips non-matching tests" {
  testFilterSkipsNonMatching()
}

test "listEntries enumerates entries" {
  testListEntriesEnumerates()
}
