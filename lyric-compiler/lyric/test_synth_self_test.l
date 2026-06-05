//! test_synth_self_test.l — exercises the self-hosted Lyric.TestSynth
//! library.  Compiled and executed by the F# Expecto runner at
//! compiler/tests/Lyric.Emitter.Tests/SelfHostedTestSynthTests.fs.
//! Each in-program assertion panics on mismatch; exit 0 + an "ok"
//! line in stdout means every check held.
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
  match synthesize(passingSource(), None) {
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

func testRejectsFixture(): Unit {
  match synthesize(fixtureSource(), None) {
    case FixtureUnsupported(_) -> {
    }
    case _ -> panic("expected FixtureUnsupported")
  }
}

func testPropertyReportedAsSkip(): Unit {
  match synthesize(propertySource(), None) {
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

func main(): Unit {
  testSynthesisesPassingTwoTests()
  testRejectsMissingTestModule()
  testRejectsUserMain()
  testRejectsFixture()
  testPropertyReportedAsSkip()
  testFilterSkipsNonMatching()
  testListEntriesEnumerates()
  println("ok")
}
