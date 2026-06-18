// test/test_synth.l — self-hosted port of the F# `lyric test` source
// rewriter (compiler/src/Lyric.Cli/TestSynth.fs).
//
// Given a Lyric source string carrying `@test_module` plus zero or
// more `test "title" { … }` items, produce a *new* source string
// where:
//
//   * Each `test "title" { body }` becomes a regular
//     `func __lyric_test_<idx>(): Unit { body }`.
//   * A synthesised `func main(): Int` is appended that runs each
//     test inside `try`/`catch Bug as b { … }` and prints a
//     TAP-shaped report to stdout.
//   * Properties parse but skip with a `# skip` line.
//   * Fixtures emit a `T0901`-shaped outcome.
//
// The rewrite operates on *spans into the original source string*
// so user-authored test bodies stay byte-identical (line numbers
// reported by the type-checker / emitter still point at user code).
// See `docs/24-test-runner-plan.md` for the rationale.
//
// Phase 5 §M5.3-equivalent port.  `lyric test` routes through this
// library: the self-hosted CLI dispatcher (`cli.l`) calls
// `synthesize` / `listEntries` directly (D-progress-260).  The earlier
// F# `Lyric.Cli.TestSynth` has been removed along with the rest of the
// F# user-facing CLI (#860).
package Lyric.TestSynth

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public surface.
// ─────────────────────────────────────────────────────────────────────────────

pub union Outcome {
  case Synthesised(source: String, testCount: Int, skipCount: Int)
  case NoTestModule(span: Span)
  case UserMainExists(span: Span)
  case FixtureUnsupported(span: Span)
  case ParseFailures(diagnostics: List[Diagnostic])
}

pub union ListEntry {
  case TestEntry(title: String)
  case PropertyEntry(title: String, reason: String)
  case FixtureEntry(name: String)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Helpers.  `escapeForLiteral` mirrors `escapeStr` in fmt_core.l but is
// inlined here so the test-runner library doesn't pull in `Lyric.Fmt` just
// for one tiny helper.
// ─────────────────────────────────────────────────────────────────────────────

func escapeForLiteral(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == '"' {
      acc = acc + "\\\""
    } else if c == '\\' {
      acc = acc + "\\\\"
    } else if c == '\n' {
      acc = acc + "\\n"
    } else if c == '\r' {
      acc = acc + "\\r"
    } else if c == '\t' {
      acc = acc + "\\t"
    } else {
      acc = acc + ("" + c)
    }
    i = i + 1
  }
  acc
}

func annotationName(a: in Annotation): String {
  if a.name.segments.count == 0 { return "" }
  var s = a.name.segments[0]
  var i = 1
  while i < a.name.segments.count {
    s = s + "." + a.name.segments[i]
    i = i + 1
  }
  s
}

func hasTestModule(file: in SourceFile): Bool {
  var i = 0
  var found = false
  while i < file.fileAnnotations.count {
    if annotationName(file.fileAnnotations[i]) == "test_module" {
      found = true
    }
    i = i + 1
  }
  found
}

func slice(source: in String, sp: in Span): String {
  val s = sp.startPos.offset
  val e = sp.endPos.offset
  if s >= 0 and e <= source.length and e >= s {
    source.substring(s, e - s)
  } else {
    ""
  }
}

func filterAccepts(filter: in Option[String], title: in String): Bool {
  match filter {
    case None       -> true
    case Some(f)    -> Str.contains(title, f)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Synthesised main builder.  Walks the collected (functionName, title)
// pairs plus skipped entries, emits a TAP-shaped report into a `func main():
// Int` body.  Returns `1` on any test failure, `0` otherwise.
// ─────────────────────────────────────────────────────────────────────────────

record TestSlot {
  funcName: String
  title:    String
}

record SkipSlot {
  title:  String
  reason: String
}

func synthesizeMain(
    tests: in List[TestSlot],
    skipped: in List[SkipSlot],
    filter: in Option[String]): String {
  val total = tests.count + skipped.count
  var sb = ""
  sb = sb + "func main(): Int {\n"
  sb = sb + "  println(\"1.." + toString(total) + "\")\n"
  sb = sb + "  var __lyric_passed: Int = 0\n"
  sb = sb + "  var __lyric_failed: Int = 0\n"
  sb = sb + "  var __lyric_skipped: Int = 0\n"
  var seq = 1
  var i = 0
  while i < tests.count {
    val t = tests[i]
    val titleEsc = escapeForLiteral(t.title)
    val nStr = toString(seq)
    if not filterAccepts(filter, t.title) {
      sb = sb + "  println(\"# skip " + nStr + " - " + titleEsc + " (filter)\")\n"
      sb = sb + "  __lyric_skipped = __lyric_skipped + 1\n"
    } else {
      sb = sb + "  try {\n"
      sb = sb + "    " + t.funcName + "()\n"
      sb = sb + "    println(\"ok " + nStr + " - " + titleEsc + "\")\n"
      sb = sb + "    __lyric_passed = __lyric_passed + 1\n"
      sb = sb + "  } catch Bug as __lyric_e {\n"
      sb = sb + "    println(\"not ok " + nStr + " - " + titleEsc + "\")\n"
      sb = sb + "    println(\"  \" + __lyric_e.message)\n"
      sb = sb + "    __lyric_failed = __lyric_failed + 1\n"
      sb = sb + "  }\n"
    }
    seq = seq + 1
    i = i + 1
  }
  var j = 0
  while j < skipped.count {
    val sk = skipped[j]
    val titleEsc = escapeForLiteral(sk.title)
    val reasonEsc = escapeForLiteral(sk.reason)
    val nStr = toString(seq)
    sb = sb + "  println(\"# skip " + nStr + " - " + titleEsc + ": " + reasonEsc + "\")\n"
    sb = sb + "  __lyric_skipped = __lyric_skipped + 1\n"
    seq = seq + 1
    j = j + 1
  }
  sb = sb + "  println(\"\")\n"
  sb = sb + "  println(\"# tests \" + toString(__lyric_passed + __lyric_failed + __lyric_skipped))\n"
  sb = sb + "  println(\"# pass  \" + toString(__lyric_passed))\n"
  sb = sb + "  println(\"# fail  \" + toString(__lyric_failed))\n"
  sb = sb + "  println(\"# skip  \" + toString(__lyric_skipped))\n"
  sb = sb + "  if __lyric_failed > 0 {\n"
  sb = sb + "    return 1\n"
  sb = sb + "  }\n"
  sb = sb + "  return 0\n"
  sb = sb + "}\n"
  sb
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. `synthesize` — main entry point.
// ─────────────────────────────────────────────────────────────────────────────

func userMainSpan(items: in List[Item]): Option[Span] {
  var i = 0
  var found: Option[Span] = None
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IFunc(fn) -> {
        if fn.name == "main" and isNone(found) {
          found = Some(value = it.span)
        }
      }
      case _ -> {}
    }
    i = i + 1
  }
  found
}

func fixtureSpan(items: in List[Item]): Option[Span] {
  var i = 0
  var found: Option[Span] = None
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IFixture(_) -> {
        if isNone(found) { found = Some(value = it.span) }
      }
      case _ -> {}
    }
    i = i + 1
  }
  found
}

func parseErrors(diags: in List[Diagnostic]): List[Diagnostic] {
  var acc: List[Diagnostic] = newList()
  var i = 0
  while i < diags.count {
    val d = diags[i]
    match d.severity {
      case DiagError -> acc.add(d)
      case _ -> {}
    }
    i = i + 1
  }
  acc
}

@stable(since="0.1")
pub func synthesize(source: in String, filter: in Option[String]): Outcome {
  val pf = parse(source)
  val errs = parseErrors(pf.diagnostics)
  if errs.count > 0 {
    return ParseFailures(diagnostics = errs)
  }
  if not hasTestModule(pf.file) {
    return NoTestModule(span = pf.file.span)
  }
  match userMainSpan(pf.file.items) {
    case Some(sp) -> return UserMainExists(span = sp)
    case None     -> {}
  }
  match fixtureSpan(pf.file.items) {
    case Some(sp) -> return FixtureUnsupported(span = sp)
    case None     -> {}
  }

  // Walk items.  For each item: emit the source slice from the
  // previous cursor up to the item's start verbatim; then either
  // (a) replace an `ITest` with a synthesised `func __lyric_test_<i>`
  // whose body is the original block slice, (b) drop an `IProperty`
  // and record it as a skip, or (c) emit the item slice unchanged.
  // After the loop, append everything from the last cursor to the
  // end of the source, then the synthesised main.
  var sb = ""
  var cursor = 0
  var tests: List[TestSlot] = newList()
  var skipped: List[SkipSlot] = newList()
  var testIdx = 0
  var i = 0
  while i < pf.file.items.count {
    val it = pf.file.items[i]
    val s = it.span.startPos.offset
    val e = it.span.endPos.offset
    val gap = s - cursor
    if gap > 0 {
      sb = sb + source.substring(cursor, gap)
    }
    cursor = e
    match it.kind {
      case ITest(t) -> {
        val bodyText = slice(source, t.body.span)
        val fname = "__lyric_test_" + toString(testIdx)
        testIdx = testIdx + 1
        sb = sb + "\nfunc " + fname + "(): Unit " + bodyText
        tests.add(TestSlot(funcName = fname, title = t.title))
      }
      case IProperty(p) -> {
        // Drop the property item entirely; record as skip.
        skipped.add(SkipSlot(
          title  = p.title,
          reason = "property: not implemented in v1"))
      }
      case _ -> {
        if e > s {
          sb = sb + source.substring(s, e - s)
        }
      }
    }
    i = i + 1
  }
  if cursor < source.length {
    sb = sb + source.substring(cursor)
  }
  sb = sb + "\n\n"
  sb = sb + synthesizeMain(tests, skipped, filter)
  // Strip @test_module from the synthesised source — the annotation is
  // not meaningful in the compiled program and triggers a P0040 parse
  // cascade in the in-process bridge parser (issue #1442).
  sb = Str.replace(sb, "@test_module\n", "\n")
  Synthesised(
    source     = sb,
    testCount  = tests.count,
    skipCount  = skipped.count)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. `listEntries` — used by `lyric test --list`.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub func listEntries(source: in String): Result[List[ListEntry], List[Diagnostic]] {
  val pf = parse(source)
  val errs = parseErrors(pf.diagnostics)
  if errs.count > 0 {
    return Err(error = errs)
  }
  var acc: List[ListEntry] = newList()
  var i = 0
  while i < pf.file.items.count {
    val it = pf.file.items[i]
    match it.kind {
      case ITest(t) ->
        acc.add(TestEntry(title = t.title))
      case IProperty(p) ->
        acc.add(PropertyEntry(
          title  = p.title,
          reason = "property: not implemented in v1"))
      case IFixture(f) ->
        acc.add(FixtureEntry(name = f.name))
      case _ -> {}
    }
    i = i + 1
  }
  Ok(value = acc)
}
