//! bench/bench_synth.l — self-hosted benchmark synthesizer for `lyric bench`.
//!
//! Given a Lyric source string annotated with `@bench_module` at the file
//! level and one or more `@bench` annotations on zero-argument functions,
//! produce a new source string where a synthesised `func main(): Int` is
//! appended that:
//!
//!   1. Warms up each `@bench` function <warmup> times (un-timed).
//!   2. Runs each `@bench` function <runs> times and records wall-clock time
//!      via `Std.Time.now()` / `since()` / `totalMillis()`.
//!   3. Runs each `@bench` function <runs> more times, untimed, between two
//!      `Std.Bench.allocatedBytes()` readings.
//!   4. Prints min / max / mean milliseconds and the bytes allocated per run
//!      for each bench to stdout.
//!
//! The rewrite preserves the original source bytes for all non-synthesised
//! items so that type-checker diagnostics still point at user code.
//!
//! Requirements for the input bench module:
//!   * `@bench_module` annotation at the file level.
//!   * `import Std.Time` and `import Std.Bench` — used by the synthesised
//!     harness.
//!   * Each benchmarked function must have signature `func name(): Unit`.
//!   * No user-defined `func main()`.
//!
//! Either import the module does not already have is injected immediately
//! before the first item so the harness functions resolve correctly.
package Lyric.BenchSynth

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public surface.
// ─────────────────────────────────────────────────────────────────────────────
pub union Outcome {
  case BenchSynthesised(source: String, benchCount: Int)
  case NoBenchModule(span: Span)
  case BenchUserMainExists(span: Span)
  case BenchParseFailures(diagnostics: List[Diagnostic])
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Helpers.
  // ─────────────────────────────────────────────────────────────────────────────
}

record BenchSlot {
  name: String
}

func annotationName(a: in Annotation): String {
  if a.name.segments.count == 0 {
    return ""
  }
  var s = a.name.segments[0]
  var i = 1
  while i < a.name.segments.count {
    s = s + "." + a.name.segments[i]
    i = i + 1
  }
  s
}

func hasBenchModule(file: in SourceFile): Bool {
  var i = 0
  var found = false
  while i < file.fileAnnotations.count {
    if annotationName(file.fileAnnotations[i]) == "bench_module" {
      found = true
    }
    i = i + 1
  }
  found
}

func hasBenchAnnotation(item: in Item): Bool {
  var i = 0
  var found = false
  while i < item.annotations.count {
    if annotationName(item.annotations[i]) == "bench" {
      found = true
    }
    i = i + 1
  }
  found
}

func userMainSpan(items: in List[Item]): Option[Span] {
  var i = 0
  var found: Option[Span] = None
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IFunc(decl) -> {
        if decl.name == "main" and isNone(found) {
          found = Some(value = it.span)
        }
      }
      case _ -> {
      }
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
      case _ -> {
      }
    }
    i = i + 1
  }
  acc
}

func hasStdImport(imports: in List[ImportDecl], module: in String): Bool {
  var i = 0
  var found = false
  while i < imports.count {
    val imp = imports[i]
    if imp.path.segments.count == 2 {
      if imp.path.segments[0] == "Std" and imp.path.segments[1] == module {
        found = true
      }
    }
    i = i + 1
  }
  found
}

func escapeForLiteral(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
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
      // The raw code unit, so a supplementary-plane character (an emoji in
      // a test name) is copied intact rather than as U+FFFD.
      acc = acc + Str.substring(s, i, 1)
    }
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Synthesised main builder.
// ─────────────────────────────────────────────────────────────────────────────
func synthesizeMain(benches: in List[BenchSlot], runs: in Int, warmup: in Int): String {
  val runsStr = toString(runs)
  val warmupStr = toString(warmup)
  // runs as a Double literal for mean computation (avoids Int/Double division).
  val runsF = runsStr + ".0"
  var sb = ""
  sb = sb + "func main(): Int {\n"
  sb = sb + "  println(\"benchmark  runs=" + runsStr + "  warmup=" + warmupStr + "\")\n"
  sb = sb + "  println(\"\")\n"
  var i = 0
  while i < benches.count {
    val b = benches[i]
    val name = b.name
    val nameEsc = escapeForLiteral(name)
    val idx = toString(i)
    val wVar = "__lyric_w_" + idx
    val rVar = "__lyric_r_" + idx
    val minV = "__lyric_min_" + idx
    val maxV = "__lyric_max_" + idx
    val sumV = "__lyric_sum_" + idx
    val meanV = "__lyric_mean_" + idx
    val t0V = "__lyric_t0_" + idx
    val t1V = "__lyric_t1_" + idx
    val msV = "__lyric_ms_" + idx
    // Warmup loop.
    sb = sb + "  var " + wVar + " = 0\n"
    sb = sb + "  while " + wVar + " < " + warmupStr + " {\n"
    sb = sb + "    " + name + "()\n"
    sb = sb + "    " + wVar + " = " + wVar + " + 1\n"
    sb = sb + "  }\n"
    // Timed loop.
    sb = sb + "  var " + minV + " = 1000000000.0\n"
    sb = sb + "  var " + maxV + " = 0.0\n"
    sb = sb + "  var " + sumV + " = 0.0\n"
    sb = sb + "  var " + rVar + " = 0\n"
    sb = sb + "  while " + rVar + " < " + runsStr + " {\n"
    sb = sb + "    val " + t0V + " = now()\n"
    sb = sb + "    " + name + "()\n"
    sb = sb + "    val " + t1V + " = now()\n"
    sb = sb + "    val " + msV + " = totalMillis(since(" + t1V + ", " + t0V + "))\n"
    sb = sb + "    if " + msV + " < " + minV + " { " + minV + " = " + msV + " }\n"
    sb = sb + "    if " + msV + " > " + maxV + " { " + maxV + " = " + msV + " }\n"
    sb = sb + "    " + sumV + " = " + sumV + " + " + msV + "\n"
    sb = sb + "    " + rVar + " = " + rVar + " + 1\n"
    sb = sb + "  }\n"
    sb = sb + "  val " + meanV + " = " + sumV + " / " + runsF + "\n"
    // Allocation: a separate untimed loop, so the clock reads (which
    // allocate on some targets) are not counted against the benchmark.
    val a0V = "__lyric_a0_" + idx
    val a1V = "__lyric_a1_" + idx
    val kVar = "__lyric_k_" + idx
    sb = sb + "  val " + a0V + " = allocatedBytes()\n"
    sb = sb + "  var " + kVar + " = 0\n"
    sb = sb + "  while " + kVar + " < " + runsStr + " {\n"
    sb = sb + "    " + name + "()\n"
    sb = sb + "    " + kVar + " = " + kVar + " + 1\n"
    sb = sb + "  }\n"
    sb = sb + "  val " + a1V + " = allocatedBytes()\n"
    // Output line: "name  min=Xms  max=Xms  mean=Xms  alloc=NB/run".
    sb = sb + "  println(\"" + nameEsc + "\" + \"  min=\" + toString(" + minV + ") + \"ms\""
    sb = sb + "       + \"  max=\" + toString(" + maxV + ") + \"ms\""
    sb = sb + "       + \"  mean=\" + toString(" + meanV + ") + \"ms\""
    sb = sb + "       + \"  alloc=\" + toString((" + a1V + " - " + a0V + ") / " + runsStr + "i64) + \"B/run\")\n"
    i = i + 1
  }
  sb = sb + "  return 0\n"
  sb = sb + "}\n"
  sb
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. `synthesize` — main entry point.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub func synthesizeBench(source: in String, runs: in Int, warmup: in Int, filter: in String): Outcome {
  val pf = parse(source)
  val errs = parseErrors(pf.diagnostics)
  if errs.count > 0 {
    return BenchParseFailures(diagnostics = errs)
  }
  if not hasBenchModule(pf.file) {
    return NoBenchModule(span = pf.file.span)
  }
  match userMainSpan(pf.file.items) {
    case Some(sp) -> return BenchUserMainExists(span = sp)
    case None -> {
    }
  }

  // Collect @bench function names by walking the AST items.
  // We do NOT use item spans to carve out source regions because
  // Item.span.endPos points at the first token of the *next* item
  // (a parser artefact of how endSpan = peekSpan(st) is captured),
  // which would cause every adjacent item to be emitted twice.
  var benches: List[BenchSlot] = newList()
  var i = 0
  while i < pf.file.items.count {
    val it = pf.file.items[i]
    match it.kind {
      case IFunc(decl) -> {
        if hasBenchAnnotation(it) {
          if filter == "" or Str.contains(decl.name, filter) {
            benches.add(BenchSlot(name = decl.name))
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }

  // Emit the original source verbatim, with `import Std.Time` (now /
  // since / totalMillis) and `import Std.Bench` (allocatedBytes) injected
  // before the first item when the module does not already import them.
  var injected = ""
  if not hasStdImport(pf.file.imports, "Time") {
    injected = injected + "import Std.Time\n"
  }
  if not hasStdImport(pf.file.imports, "Bench") {
    injected = injected + "import Std.Bench\n"
  }
  var sb = ""
  if injected.length > 0 and pf.file.items.count > 0 {
    val firstItemStart = pf.file.items[0].span.startPos.offset
    if firstItemStart > 0 {
      sb = source.substring(0, firstItemStart)
    }
    sb = sb + "\n" + injected
    sb = sb + source.substring(firstItemStart, source.length - firstItemStart)
  } else {
    sb = source
  }
  sb = sb + "\n\n"
  sb = sb + synthesizeMain(benches, runs, warmup)
  BenchSynthesised(source = sb, benchCount = benches.count)
}
