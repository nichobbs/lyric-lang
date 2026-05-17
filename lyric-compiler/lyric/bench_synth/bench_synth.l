// bench/bench_synth.l — self-hosted benchmark synthesizer for `lyric bench`.
//
// Given a Lyric source string annotated with `@bench_module` at the file
// level and one or more `@bench` annotations on zero-argument functions,
// produce a new source string where a synthesised `func main(): Int` is
// appended that:
//
//   1. Warms up each `@bench` function <warmup> times (un-timed).
//   2. Runs each `@bench` function <runs> times and records wall-clock time
//      via `Std.Time.now()` / `since()` / `totalMillis()`.
//   3. Prints min / max / mean milliseconds per bench to stdout.
//
// The rewrite preserves the original source bytes for all non-synthesised
// items so that type-checker diagnostics still point at user code.
//
// Requirements for the input bench module:
//   * `@bench_module` annotation at the file level.
//   * `import Std.Time` — used by the synthesised harness.
//   * Each benchmarked function must have signature `func name(): Unit`.
//   * No user-defined `func main()`.
//
// If `Std.Time` is not already imported, the synthesiser injects
// `import Std.Time` immediately before the first item so the
// harness functions resolve correctly.

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
  case Synthesised(source: String, benchCount: Int)
  case NoBenchModule(span: Span)
  case UserMainExists(span: Span)
  case ParseFailures(diagnostics: List[Diagnostic])
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Helpers.
// ─────────────────────────────────────────────────────────────────────────────

record BenchSlot {
  name: String
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

func hasTimeImport(imports: in List[ImportDecl]): Bool {
  var i = 0
  var found = false
  while i < imports.count {
    val imp = imports[i]
    if imp.path.segments.count == 2 {
      if imp.path.segments[0] == "Std" and imp.path.segments[1] == "Time" {
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

// ─────────────────────────────────────────────────────────────────────────────
// §3. Synthesised main builder.
// ─────────────────────────────────────────────────────────────────────────────

func synthesizeMain(benches: in List[BenchSlot], runs: in Int, warmup: in Int): String {
  val runsStr  = toString(runs)
  val warmupStr = toString(warmup)
  // runs as a Double literal for mean computation (avoids Int/Double division).
  val runsF = runsStr + ".0"
  var sb = ""
  sb = sb + "func main(): Int {\n"
  sb = sb + "  println(\"benchmark  runs=" + runsStr + "  warmup=" + warmupStr + "\")\n"
  sb = sb + "  println(\"\")\n"
  var i = 0
  while i < benches.count {
    val b     = benches[i]
    val name  = b.name
    val nameEsc = escapeForLiteral(name)
    val idx   = toString(i)
    val wVar  = "__lyric_w_"   + idx
    val rVar  = "__lyric_r_"   + idx
    val minV  = "__lyric_min_" + idx
    val maxV  = "__lyric_max_" + idx
    val sumV  = "__lyric_sum_" + idx
    val meanV = "__lyric_mean_" + idx
    val t0V   = "__lyric_t0_"  + idx
    val t1V   = "__lyric_t1_"  + idx
    val msV   = "__lyric_ms_"  + idx
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
    // Output line: "name  min=Xms  max=Xms  mean=Xms".
    sb = sb + "  println(\"" + nameEsc + "\" + \"  min=\" + toString(" + minV + ") + \"ms\""
    sb = sb + "       + \"  max=\" + toString(" + maxV + ") + \"ms\""
    sb = sb + "       + \"  mean=\" + toString(" + meanV + ") + \"ms\")\n"
    i = i + 1
  }
  sb = sb + "  return 0\n"
  sb = sb + "}\n"
  sb
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. `synthesize` — main entry point.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub func synthesize(source: in String, runs: in Int, warmup: in Int, filter: in String): Outcome {
  val pf   = parse(source)
  val errs = parseErrors(pf.diagnostics)
  if errs.count > 0 {
    return ParseFailures(diagnostics = errs)
  }
  if not hasBenchModule(pf.file) {
    return NoBenchModule(span = pf.file.span)
  }
  match userMainSpan(pf.file.items) {
    case Some(sp) -> return UserMainExists(span = sp)
    case None     -> {}
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
      case _ -> {}
    }
    i = i + 1
  }

  // Emit the original source verbatim.  If Std.Time is not already
  // imported we inject it just before the first item so the synthesised
  // harness can call now() / since() / totalMillis().
  val injectTime = not hasTimeImport(pf.file.imports)
  var sb = ""
  if injectTime and pf.file.items.count > 0 {
    val firstItemStart = pf.file.items[0].span.startPos.offset
    if firstItemStart > 0 {
      sb = source.substring(0, firstItemStart)
    }
    sb = sb + "\nimport Std.Time\n"
    sb = sb + source.substring(firstItemStart)
  } else {
    sb = source
  }
  sb = sb + "\n\n"
  sb = sb + synthesizeMain(benches, runs, warmup)
  Synthesised(source = sb, benchCount = benches.count)
}
