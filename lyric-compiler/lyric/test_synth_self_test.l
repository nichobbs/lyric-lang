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

func fixtureNoTypeSource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\nfixture count = 42\n\ntest \"a\" { assertTrue(true, \"x\") }\n"
}

func multiFixtureSource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\nfixture x: Int = 1\nfixture y: Int = 2\n\ntest \"a\" { assertTrue(true, \"x\") }\ntest \"b\" { assertTrue(true, \"y\") }\n"
}

func annotatedFixtureSource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\n@stable(since = \"0.1\")\nfixture clock: Int = 0\n\ntest \"a\" { assertTrue(true, \"x\") }\n"
}

func propertySource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\ntest \"unit\" { assertTrue(true, \"x\") }\nproperty \"prop\" forall (n: Int) { assertTrue(true, \"x\") }\n"
}

// #5609 item 4: a `@cfg(...)`-annotated `test { }` block must keep its
// annotation on the synthesized `func` — mirrors `annotatedFixtureSource`
// above for `fixture`.  Before the fix, the `ITest` rewrite arm dropped the
// annotation text entirely, so a feature-gated test whose body referenced a
// symbol that only exists under that feature (`nonexistentSymbol` here)
// would fail to type-check even with the feature inactive: the erasure pass
// (which runs on the REWRITTEN source, after `synthesize`) never saw the
// `@cfg` annotation on `__lyric_test_0` and so never dropped it.
func annotatedCfgTestSource(): String {
  "@test_module\npackage P\n\nimport Std.Testing\n\n@cfg(feature = \"exp\")\ntest \"a\" { assertTrue(nonexistentSymbol, \"x\") }\ntest \"b\" { assertTrue(true, \"y\") }\n"
}

func testSynthesisesAnnotatedCfgTest(): Unit {
  match synthesize(annotatedCfgTestSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 2, "both tests detected (synthesis itself doesn't erase — cfg erasure is a later pipeline stage)")
      assertEqualInt(sk, 0, "no skips")
      assertTrue(
        Str.contains(rewritten, "@cfg(feature = \"exp\")\nfunc __lyric_test_0(): Unit"),
        "cfg annotation preserved directly before the synthesized func, so the later erasure pass can see and act on it"
      )
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

// #6642: a multi-line module-level `//!` doc-comment header, plus the
// `@test_module` annotation line itself, both land in separate `SourceFile`
// fields (`moduleDoc` / `fileAnnotations`) ahead of `packageDecl`. Slicing
// only `packageDecl.span` when building the rewritten source drops that
// leading text entirely, shifting every subsequent line number in the
// rewritten (and then re-parsed) source by however many lines the header
// occupied — a `lyric test` diagnostic named the right file but the wrong
// line. `helper()` below is a plain (non-`test`, non-`fixture`) item, which
// the rewrite always copies byte-for-byte regardless of what it does to
// `test { }` blocks elsewhere in the file, so this isolates the header-drop
// bug from any line-count change the `ITest` rewrite itself might introduce.
func headerLineNumbersSource(): String {
  "//! Header line 1.\n" + "//! Header line 2.\n" + "//! Header line 3.\n" + "@test_module\n" +
    "package HeaderLineRepro\n" +
    "\n" +
    "import Std.Testing\n" +
    "\n" +
    "func helper(): Int {\n" +
    "  totallyUnknownIdentifierXYZ\n" +
    "}\n" +
    "\n" +
    "test \"trivial\" {\n" +
    "  assertTrue(true, \"x\")\n" +
    "}\n"
}

func testHeaderLineNumbersPreserved(): Unit {
  match synthesize(headerLineNumbersSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 1, "one test")
      assertEqualInt(sk, 0, "no skips")
      val lines = Str.split(rewritten, "\n")
      // Line 10 (1-indexed) of the ORIGINAL source is
      // "  totallyUnknownIdentifierXYZ" — line index 9 in a 0-indexed split.
      // Before the fix, dropping the 3-line header + the `@test_module` line
      // (4 lines total) shifted this content up to index 5 (line 6).
      assertTrue(lines.length > 9, "rewritten source has fewer than 10 lines:\n" + rewritten)
      assertTrue(
        Str.contains(lines[9], "totallyUnknownIdentifierXYZ"),
        "expected line 10 (index 9) of the rewritten source to still be the helper() body, got '" + lines[9] +
          "'\nfull rewritten source:\n" +
          rewritten
      )
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

// #6687: a comment block (or an extra blank line) BETWEEN two `import`
// statements — a shape several real `@test_module` files use, e.g.
// `stdlib_jvm_kernels_self_test.l`'s two import groups split by a
// multi-line comment.  The #6642 fix above reproduces the header exactly,
// but the import-copy loop that followed it still stitched each import's
// own span onto a single synthetic newline, discarding any trivia between
// two imports — collapsing the comment block (plus its surrounding blank
// lines) here would have shifted `helper()`'s body up by several lines.
// Same isolation trick as `headerLineNumbersSource`: the compile error
// lives in a plain helper `func`, not inside a `test { }` block, so this
// checks the import-loop rewrite alone.
func importGapLineNumbersSource(): String {
  "@test_module\n" + "package ImportGapRepro\n" + "\n" + "import Std.Core\n" + "\n" + "// This is a comment block\n" +
    "// spanning multiple lines\n" +
    "// between two import groups.\n" +
    "\n" +
    "import Std.Testing\n" +
    "\n" +
    "func helper(): Int {\n" +
    "  totallyUnknownIdentifierABC\n" +
    "}\n" +
    "\n" +
    "test \"trivial\" {\n" +
    "  assertTrue(true, \"x\")\n" +
    "}\n"
}

func testImportGapLineNumbersPreserved(): Unit {
  match synthesize(importGapLineNumbersSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 1, "one test")
      assertEqualInt(sk, 0, "no skips")
      val lines = Str.split(rewritten, "\n")
      // Line 13 (1-indexed) of the ORIGINAL source is
      // "  totallyUnknownIdentifierABC" — line index 12 in a 0-indexed split.
      // Before the fix, collapsing the blank line before the first import
      // plus the blank/comment/blank gap between the two imports (6 lines
      // total) shifted this content up to index 6 (line 7).
      assertTrue(lines.length > 12, "rewritten source has fewer than 13 lines:\n" + rewritten)
      assertTrue(
        Str.contains(lines[12], "totallyUnknownIdentifierABC"),
        "expected line 13 (index 12) of the rewritten source to still be the helper() body, got '" + lines[12] +
          "'\nfull rewritten source:\n" +
          rewritten
      )
    }
    case _ -> panic("expected Synthesised outcome")
  }
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

func testSynthesisesFixtureNoType(): Unit {
  match synthesize(fixtureNoTypeSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 1, "one test")
      assertEqualInt(sk, 0, "no skips")
      assertTrue(Str.contains(rewritten, "val count = 42"), "fixture without type annotation rewritten as val")
      assertTrue(not Str.contains(rewritten, "fixture "), "no fixture keyword in output")
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

func testSynthesisesMultipleFixtures(): Unit {
  match synthesize(multiFixtureSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 2, "two tests")
      assertEqualInt(sk, 0, "no skips")
      assertTrue(Str.contains(rewritten, "val x: Int = 1"), "first fixture rewritten")
      assertTrue(Str.contains(rewritten, "val y: Int = 2"), "second fixture rewritten")
      assertTrue(not Str.contains(rewritten, "fixture "), "no fixture keyword in output")
    }
    case _ -> panic("expected Synthesised outcome")
  }
}

func testSynthesisesAnnotatedFixture(): Unit {
  match synthesize(annotatedFixtureSource(), Some(value = "")) {
    case Synthesised(rewritten, n, sk) -> {
      assertEqualInt(n, 1, "one test")
      assertEqualInt(sk, 0, "no skips")
      assertTrue(Str.contains(rewritten, "val clock: Int = 0"), "annotated fixture rewritten as val")
      assertTrue(Str.contains(rewritten, "@stable(since = \"0.1\")"), "annotation preserved before val")
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

test "module //! header line numbers preserved in rewritten source (#6642)" {
  testHeaderLineNumbersPreserved()
}

test "comment block between imports preserves line numbers (#6687)" {
  testImportGapLineNumbersPreserved()
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

test "synthesises fixture without type annotation" {
  testSynthesisesFixtureNoType()
}

test "synthesises multiple fixtures" {
  testSynthesisesMultipleFixtures()
}

test "synthesises annotated fixture" {
  testSynthesisesAnnotatedFixture()
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
