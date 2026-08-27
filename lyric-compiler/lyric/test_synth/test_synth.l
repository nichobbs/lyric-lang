//! test/test_synth.l — self-hosted port of the F# `lyric test` source
//! rewriter (compiler/src/Lyric.Cli/TestSynth.fs).
//!
//! Given a Lyric source string carrying `@test_module` plus zero or
//! more `test "title" { … }` items, produce a *new* source string
//! where:
//!
//!   * Each `test "title" { body }` becomes a regular
//!     `func __lyric_test_<idx>(): Unit { body }`.
//!   * A synthesised `func main(): Int` is appended that runs each
//!     test inside `try`/`catch Bug as b { … }` and prints a
//!     TAP-shaped report to stdout.
//!   * Properties parse but skip with a `# skip` line by default; with
//!     `--properties` (`synthesizeWithProperties`, #677), a `property`
//!     whose `forall` binders are all Int/Bool/Double gets a real
//!     sampling-and-shrinking harness instead — see §3a below.
//!   * Fixtures are rewritten to module-level `val` declarations
//!     (D-progress-474).
//!
//! The rewrite operates on *spans into the original source string*
//! so user-authored test bodies stay byte-identical (line numbers
//! reported by the type-checker / emitter still point at user code).
//! See `docs/24-test-runner-plan.md` for the rationale.
//!
//! Phase 5 §M5.3-equivalent port.  `lyric test` routes through this
//! library: the self-hosted CLI dispatcher (`cli.l`) calls
//! `synthesize` / `listEntries` directly (D-progress-260).  The earlier
//! F# `Lyric.Cli.TestSynth` has been removed along with the rest of the
//! F# user-facing CLI (#860).
//!
//! Fixtures (`fixture name[: T] = expr`) are rewritten to `val` declarations
//! at the package level of the synthesised source so their initialiser runs
//! once and the name is in scope for all test functions.
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
  case ParseFailures(diagnostics: List[Diagnostic])
}

pub union ListEntry {
  case TestEntry(title: String)
  case PropertyEntry(title: String, reason: String)
  case FixtureEntry(name: String)
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Helpers.  `escapeForLiteral` mirrors `escapeStr` in fmt_core.l but is
  // inlined here so the test-runner library doesn't pull in `Lyric.Fmt` just
  // for one tiny helper.
  // ─────────────────────────────────────────────────────────────────────────────
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
    case None -> true
    case Some(f) -> Str.contains(title, f)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Synthesised main builder.  Walks the collected (functionName, title)
// pairs plus skipped entries, emits a TAP-shaped report into a `func main():
// Int` body.  Returns `1` on any test failure, `0` otherwise.
// ─────────────────────────────────────────────────────────────────────────────
record TestSlot {
  funcName: String
  title: String
}

record SkipSlot {
  title: String
  reason: String
}

// ─────────────────────────────────────────────────────────────────────────────
// §3a. Property execution (#677, `lyric test --properties`).  A `property`
// declaration whose `forall` binders are all auto-derived primitive types
// (Int/Bool/Double) is synthesised into a real sampling-and-shrinking
// harness; any other binder type still reports `# skip` (v1's "parses but
// never runs" behaviour, unconditionally — see `tryBuildPropertyDriver`).
// ─────────────────────────────────────────────────────────────────────────────
// The simple (single-segment) type name of a `forall` binder's declared
// type, e.g. `Int` for `x: Int`.  `None` for anything not a bare named type
// (generic instantiations, tuples, qualified paths, …) — none of those are
// auto-derivable in v1.
func propBinderTypeName(ty: in TypeExpr): Option[String] {
  match ty.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        Some(value = path.segments[0])
      } else {
        None
      }
    }
    case _ -> None
  }
}

func isSupportedPropType(name: in String): Bool {
  name == "Int" or name == "Bool" or name == "Double"
}

// Random-sample generator expression for one binder, evaluated fresh each
// sampling iteration.
func propGenExpr(tyName: in String, rngVar: in String): String {
  if tyName == "Int" {
    "Std.Random.nextIntRange(" + rngVar + ", -1000, 1000)"
  } else if tyName == "Bool" {
    "Std.Random.nextBool(" + rngVar + ")"
  } else {
    "Std.Random.nextDouble(" + rngVar + ")"
  }
}

// Shrink-candidate list expression for one binder's current failing value.
// Doubles are not shrunk (mirrors `Std.Testing.Property.forAllDouble`) — an
// explicitly empty list makes the shrink loop below run zero iterations
// rather than needing a separate no-shrink code path.
func propShrinkExpr(tyName: in String, valueExpr: in String): String {
  if tyName == "Int" {
    "Std.Testing.Property.shrinkInt(" + valueExpr + ", -1000)"
  } else if tyName == "Bool" {
    "Std.Testing.Property.shrinkBool(" + valueExpr + ")"
  } else {
    "newList()"
  }
}

func propZeroLiteral(tyName: in String): String {
  if tyName == "Int" {
    "0"
  } else if tyName == "Bool" {
    "false"
  } else {
    "0.0"
  }
}

record PropBinderInfo {
  name: String
  tyName: String
}

func propCallArgs(binders: in List[PropBinderInfo]): String {
  var s = ""
  var i = 0
  while i < binders.count {
    if i > 0 {
      s = s + ", "
    }
    s = s + binders[i].name
    i = i + 1
  }
  s
}

// `var <varName> = <guardText>` (or `= true` with no `where` clause), at the
// given indentation.
func propGuardAssign(guardText: in Option[String], varName: in String, indent: in String): String {
  match guardText {
    case Some(g) -> indent + "var " + varName + " = " + g + "\n"
    case None -> indent + "var " + varName + " = true\n"
  }
}

// One shrink phase for binder `j`: repeatedly try simpler candidates for
// binder `j` alone (holding every other binder fixed at its currently-known
// failing value) until no candidate reduces the failure further.  A
// property's `forall` arity is small and fixed at synthesis time, so each
// phase is unrolled directly into the generated source — there is no
// variadic-generic way to call the stdlib's single-`T`
// `Std.Testing.Property` shrink helpers once for an N-ary property. This
// reimplements the same greedy "first smaller failure wins" fixed-point
// algorithm `shrinkToFixedPoint` / `forAllIntPair`'s
// `shrinkPairLeft`/`shrinkPairRight` already use in `testing_property.l`,
// at whatever arity this property actually has.
func propShrinkPhase(idx: in Int, binders: in List[PropBinderInfo], j: in Int, guardText: in Option[String]): String {
  val jStr = toString(j)
  val binder = binders[j]
  var sb = ""
  sb = sb + "    var __lyric_shrinking_" + jStr + " = true\n"
  sb = sb + "    while __lyric_shrinking_" + jStr + " {\n"
  sb = sb + "      __lyric_shrinking_" + jStr + " = false\n"
  sb = sb + "      val __lyric_cands_" + jStr + ": List[" + binder.tyName + "] = " +
    propShrinkExpr(binder.tyName, "__lyric_fail_" + binder.name) +
    "\n"
  sb = sb + "      var __lyric_ci_" + jStr + " = 0\n"
  sb = sb + "      while __lyric_ci_" + jStr + " < __lyric_cands_" + jStr + ".count {\n"
  sb = sb + "        val __lyric_cand_" + jStr + " = __lyric_cands_" + jStr + "[__lyric_ci_" + jStr + "]\n"
  var bi = 0
  while bi < binders.count {
    val b = binders[bi]
    if bi == j {
      sb = sb + "        val " + b.name + " = __lyric_cand_" + jStr + "\n"
    } else {
      sb = sb + "        val " + b.name + " = __lyric_fail_" + b.name + "\n"
    }
    bi = bi + 1
  }
  sb = sb + propGuardAssign(guardText, "__lyric_guard_ok_" + jStr, "        ")
  sb = sb + "        var __lyric_stillFails_" + jStr + " = false\n"
  sb = sb + "        if __lyric_guard_ok_" + jStr + " {\n"
  sb = sb + "          try {\n"
  sb = sb + "            __lyric_prop_body_" + toString(idx) + "(" + propCallArgs(binders) + ")\n"
  sb = sb + "          } catch Bug as __lyric_pe2_" + jStr + " {\n"
  sb = sb + "            __lyric_stillFails_" + jStr + " = true\n"
  sb = sb + "          }\n"
  sb = sb + "        }\n"
  sb = sb + "        if __lyric_stillFails_" + jStr + " {\n"
  sb = sb + "          __lyric_fail_" + binder.name + " = __lyric_cand_" + jStr + "\n"
  sb = sb + "          __lyric_shrinking_" + jStr + " = true\n"
  sb = sb + "          __lyric_ci_" + jStr + " = __lyric_cands_" + jStr + ".count\n"
  sb = sb + "        } else {\n"
  sb = sb + "          __lyric_ci_" + jStr + " = __lyric_ci_" + jStr + " + 1\n"
  sb = sb + "        }\n"
  sb = sb + "      }\n"
  sb = sb + "    }\n"
  sb
}

// The `panic("property failed: \"<title>\" forall(x = ..., y = ...)")`
// expression reporting every binder's final shrunk value.
func propFailureMessageExpr(titleEsc: in String, binders: in List[PropBinderInfo]): String {
  var expr = "\"property failed: \\\"" + titleEsc + "\\\" forall(\""
  var i = 0
  while i < binders.count {
    val b = binders[i]
    if i > 0 {
      expr = expr + " + \", \""
    }
    expr = expr + " + \"" + b.name + " = \" + toString(__lyric_fail_" + b.name + ")"
    i = i + 1
  }
  expr = expr + " + \")\""
  expr
}

func propAllBindersSupported(p: in PropertyDecl): Bool {
  var i = 0
  while i < p.forAll.count {
    match propBinderTypeName(p.forAll[i].ty) {
      case Some(n) -> {
        if not isSupportedPropType(n) {
          return false
        }
      }
      case None -> return false
    }
    i = i + 1
  }
  true
}

// Whether ANY property in the file will get a real driver (as opposed to a
// `# skip` line) — decides whether `Std.Random` / `Std.Testing.Property`
// need injecting.  A `forall`-less property never calls either, so it alone
// does not trigger the injection.
func anyPropertyNeedsStdlibImports(items: in List[Item], runProperties: in Bool): Bool {
  if not runProperties {
    return false
  }
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IProperty(p) -> {
        if p.forAll.count > 0 and propAllBindersSupported(p) {
          return true
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

func importPathText(mp: in ModulePath): String {
  var s = ""
  var i = 0
  while i < mp.segments.count {
    if i > 0 {
      s = s + "."
    }
    s = s + mp.segments[i]
    i = i + 1
  }
  s
}

// Whether the user's own file already imports `dottedPath` (any alias) —
// checked before injecting `import Std.Random` / `import Std.Testing.Property`
// so the synthesised source never carries a duplicate import of the same
// path.
func hasImportOfPath(imports: in List[ImportDecl], dottedPath: in String): Bool {
  var i = 0
  while i < imports.count {
    if importPathText(imports[i].path) == dottedPath {
      return true
    }
    i = i + 1
  }
  false
}

// Builds the pair of synthesised functions (`__lyric_prop_body_<idx>` /
// `__lyric_prop_<idx>`) for one `property` declaration, or `Err(reason)`
// naming the first unsupported `forall` binder type encountered — the
// caller reports that as a `# skip` line, exactly like v1's unconditional
// skip.
func tryBuildPropertyDriver(
  source: in String, p: in PropertyDecl, idx: in Int, annText: in String
): Result[String, String] {
  val binders: List[PropBinderInfo] = newList()
  var bi = 0
  while bi < p.forAll.count {
    val b = p.forAll[bi]
    match propBinderTypeName(b.ty) {
      case Some(n) -> {
        if isSupportedPropType(n) {
          binders.add(PropBinderInfo(name = b.name, tyName = n))
        } else {
          return Err(error = "unsupported generator type '" + n + "' for auto-derived properties (Int/Bool/Double only in v1)")
        }
      }
      case None -> return Err(error = "unsupported generator type for auto-derived properties (Int/Bool/Double only in v1)")
    }
    bi = bi + 1
  }

  val idxStr = toString(idx)
  val bodyFn = "__lyric_prop_body_" + idxStr
  val driverFn = "__lyric_prop_" + idxStr

  var params = ""
  var pi = 0
  while pi < binders.count {
    if pi > 0 {
      params = params + ", "
    }
    params = params + binders[pi].name + ": " + binders[pi].tyName
    pi = pi + 1
  }

  val bodyText = slice(source, p.body.span)
  val guardText: Option[String] = match p.guardExpr {
    case Some(g) -> Some(value = slice(source, g.span))
    case None -> None
  }
  val titleEsc = escapeForLiteral(p.title)

  var sb = ""
  sb = sb + annText + "func " + bodyFn + "(" + params + "): Unit " + bodyText + "\n\n"
  sb = sb + annText + "func " + driverFn + "(): Unit {\n"

  if binders.count == 0 {
    // No `forall` binders at all: a single guarded execution, no sampling
    // or shrinking (there is nothing to shrink toward).
    sb = sb + propGuardAssign(guardText, "__lyric_guard_ok", "  ")
    sb = sb + "  if __lyric_guard_ok {\n"
    sb = sb + "    " + bodyFn + "()\n"
    sb = sb + "  }\n"
    sb = sb + "}\n"
    return Ok(value = sb)
  }

  sb = sb + "  val __lyric_rng = Std.Random.makeRandom(" + toString(1000 + idx) + ")\n"
  sb = sb + "  val __lyric_n = 100\n"
  sb = sb + "  var __lyric_iter = 0\n"
  sb = sb + "  var __lyric_failed = false\n"
  var fi = 0
  while fi < binders.count {
    val b = binders[fi]
    sb = sb + "  var __lyric_fail_" + b.name + ": " + b.tyName + " = " + propZeroLiteral(b.tyName) + "\n"
    fi = fi + 1
  }
  sb = sb + "  while __lyric_iter < __lyric_n and not __lyric_failed {\n"
  var gi = 0
  while gi < binders.count {
    val b = binders[gi]
    sb = sb + "    val " + b.name + " = " + propGenExpr(b.tyName, "__lyric_rng") + "\n"
    gi = gi + 1
  }
  sb = sb + propGuardAssign(guardText, "__lyric_guard_ok", "    ")
  sb = sb + "    if __lyric_guard_ok {\n"
  sb = sb + "      var __lyric_ok = true\n"
  sb = sb + "      try {\n"
  sb = sb + "        " + bodyFn + "(" + propCallArgs(binders) + ")\n"
  sb = sb + "      } catch Bug as __lyric_pe {\n"
  sb = sb + "        __lyric_ok = false\n"
  sb = sb + "      }\n"
  sb = sb + "      if not __lyric_ok {\n"
  sb = sb + "        __lyric_failed = true\n"
  var si = 0
  while si < binders.count {
    val b = binders[si]
    sb = sb + "        __lyric_fail_" + b.name + " = " + b.name + "\n"
    si = si + 1
  }
  sb = sb + "      }\n"
  sb = sb + "    }\n"
  sb = sb + "    __lyric_iter = __lyric_iter + 1\n"
  sb = sb + "  }\n"
  sb = sb + "  if __lyric_failed {\n"
  var shi = 0
  while shi < binders.count {
    sb = sb + propShrinkPhase(idx, binders, shi, guardText)
    shi = shi + 1
  }
  sb = sb + "    panic(" + propFailureMessageExpr(titleEsc, binders) + ")\n"
  sb = sb + "  }\n"
  sb = sb + "}\n"
  Ok(value = sb)
}

// `nativeMode` drops the try/catch isolation `--target native` cannot lower
// (D-N-003: native has no unwinding — try/catch panics the codegen with
// "not supported for --target native").  Each test calls straight through;
// a passing test prints its "ok" line and execution continues to the next,
// but an assertion failure `panic`s the whole process immediately (no
// "not ok" line, no summary) — the same "panics abort" model every other
// native program already has.  N7.2.
func synthesizeMain(
  tests: in List[TestSlot], skipped: in List[SkipSlot], filter: in Option[String], nativeMode: in Bool
): String {
  // Native has no builtin-`println` prelude special case (see the import
  // note above) — emit calls to the real `Std.Console.println` there.
  val pfn = if nativeMode { "__lyric_console.println" } else { "println" }
  val total = tests.count + skipped.count
  var sb = ""
  sb = sb + "func main(): Int {\n"
  sb = sb + "  " + pfn + "(\"1.." + toString(total) + "\")\n"
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
      sb = sb + "  " + pfn + "(\"# skip " + nStr + " - " + titleEsc + " (filter)\")\n"
      sb = sb + "  __lyric_skipped = __lyric_skipped + 1\n"
    } else if nativeMode {
      sb = sb + "  " + t.funcName + "()\n"
      sb = sb + "  " + pfn + "(\"ok " + nStr + " - " + titleEsc + "\")\n"
      sb = sb + "  __lyric_passed = __lyric_passed + 1\n"
    } else {
      sb = sb + "  try {\n"
      sb = sb + "    " + t.funcName + "()\n"
      sb = sb + "    " + pfn + "(\"ok " + nStr + " - " + titleEsc + "\")\n"
      sb = sb + "    __lyric_passed = __lyric_passed + 1\n"
      sb = sb + "  } catch Bug as __lyric_e {\n"
      sb = sb + "    " + pfn + "(\"not ok " + nStr + " - " + titleEsc + "\")\n"
      sb = sb + "    " + pfn + "(\"  \" + __lyric_e.message)\n"
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
    sb = sb + "  " + pfn + "(\"# skip " + nStr + " - " + titleEsc + ": " + reasonEsc + "\")\n"
    sb = sb + "  __lyric_skipped = __lyric_skipped + 1\n"
    seq = seq + 1
    j = j + 1
  }
  sb = sb + "  " + pfn + "(\"\")\n"
  sb = sb + "  " + pfn + "(\"# tests \" + toString(__lyric_passed + __lyric_failed + __lyric_skipped))\n"
  sb = sb + "  " + pfn + "(\"# pass  \" + toString(__lyric_passed))\n"
  sb = sb + "  " + pfn + "(\"# fail  \" + toString(__lyric_failed))\n"
  sb = sb + "  " + pfn + "(\"# skip  \" + toString(__lyric_skipped))\n"
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

@stable(since = "0.1")
pub func synthesize(source: in String, filter: in Option[String]): Outcome {
  synthesizeFor(source, filter, false, false)
}

// Native variant (N7.2): synthesises straight-through test calls instead of
// try/catch isolation (see `synthesizeMain`'s nativeMode branch).  Not
// `@stable` — `synthesize` is the stable dotnet/jvm entry point; this is a
// separate, additive entry point rather than a breaking signature change.
pub func synthesizeNative(source: in String, filter: in Option[String]): Outcome {
  synthesizeFor(source, filter, true, false)
}

// `lyric test --properties` variant (#677): `property` declarations whose
// `forall` binders are all auto-derivable primitive types (Int/Bool/Double)
// are synthesised into a real sampling-and-shrinking harness (see
// `tryBuildPropertyDriver`) and run alongside ordinary tests; a property
// with any other binder type still reports `# skip` with a reason naming
// the unsupported type.  Not `@stable` — additive alongside `synthesize`,
// which keeps skipping every property unconditionally (byte-for-byte
// unchanged) for callers that don't pass `--properties`.
pub func synthesizeWithProperties(source: in String, filter: in Option[String]): Outcome {
  synthesizeFor(source, filter, false, true)
}

func synthesizeFor(source: in String, filter: in Option[String], nativeMode: in Bool, runProperties: in Bool): Outcome {
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
    case None -> {
    }
  }
  var sb = slice(source, pf.file.packageDecl.span)
  sb = sb + "\n"
  // Native has no builtin-`println` prelude special case (unlike the dotnet/
  // jvm emitters) — the synthesised main below calls the real, already
  // native-compilable `Std.Console.println` instead, so it needs the
  // import.  The alias is `__lyric_console` (matching the `__lyric_*`
  // naming already used for synthesised locals below) rather than the
  // more natural `Console`, so injecting this import can never collide
  // with the user's own `import Std.Console [as X]` in the original file
  // (#4983) — two imports of the same path under different aliases are
  // harmless, unlike two bindings fighting over the same alias name.
  if nativeMode {
    sb = sb + "import Std.Console as __lyric_console\n"
  }
  // #677: inject the two stdlib imports the synthesised property harness
  // needs, unaliased (referenced by full qualified name everywhere below,
  // so an alias collision with the user's own imports is impossible) and
  // only when at least one property will actually get a real driver, and
  // only when the user hasn't already imported the path themselves.
  val needsPropertyStdlib = anyPropertyNeedsStdlibImports(pf.file.items, runProperties)
  if needsPropertyStdlib {
    if not hasImportOfPath(pf.file.imports, "Std.Random") {
      sb = sb + "import Std.Random\n"
    }
    if not hasImportOfPath(pf.file.imports, "Std.Testing.Property") {
      sb = sb + "import Std.Testing.Property\n"
    }
  }
  var ii = 0
  while ii < pf.file.imports.count {
    sb = sb + slice(source, pf.file.imports[ii].span) + "\n"
    ii = ii + 1
  }

  var cursor = if pf.file.imports.count > 0 {
    pf.file.imports[pf.file.imports.count - 1].span.endPos.offset
  } else {
    pf.file.packageDecl.span.endPos.offset
  }

  var tests: List[TestSlot] = newList()
  var skipped: List[SkipSlot] = newList()
  var testIdx = 0
  var propIdx = 0
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
        // #5609 item 4: preserve any annotation prefix (e.g. `@cfg(...)`)
        // before the `test` keyword — mirrors the `IFixture` arm below.
        // Previously the annotation text was dropped entirely by the
        // rewrite, so a `@cfg`-gated `test { }` block always ran regardless
        // of feature state (the erasure pass never saw the annotation on the
        // synthesized `func`).
        val testStart = t.span.startPos.offset
        val annLen = testStart - s
        if annLen > 0 {
          sb = sb + source.substring(s, annLen)
        }
        val bodyText = slice(source, t.body.span)
        val fname = "__lyric_test_" + toString(testIdx)
        testIdx = testIdx + 1
        sb = sb + "\nfunc " + fname + "(): Unit " + bodyText
        tests.add(TestSlot(funcName = fname, title = t.title))
      }
      case IProperty(p) -> {
        if runProperties {
          // Preserve any annotation prefix (e.g. `@cfg(...)`) before the
          // `property` keyword, mirroring the `ITest`/`IFixture` arms
          // (#5609 item 4) — repeated before EACH synthesised func below so
          // `@cfg` erasure (which gates whole items) sees it on both, not
          // just the first.
          val propStart = p.span.startPos.offset
          val annLen = propStart - s
          val annText = if annLen > 0 { source.substring(s, annLen) } else { "" }
          match tryBuildPropertyDriver(source, p, propIdx, annText) {
            case Ok(driverCode) -> {
              val fname = "__lyric_prop_" + toString(propIdx)
              sb = sb + "\n" + driverCode
              tests.add(TestSlot(funcName = fname, title = "property: " + p.title))
            }
            case Err(reason) -> {
              skipped.add(SkipSlot(title = p.title, reason = "property: " + reason))
            }
          }
          propIdx = propIdx + 1
        } else {
          skipped.add(SkipSlot(title = p.title, reason = "property: not implemented in v1"))
        }
      }
      case IFixture(f) -> {
        // Preserve any annotations before the `fixture` keyword, then replace
        // "fixture <name>" with "val <name>" so the initialiser becomes a
        // module-level val in scope for all test functions.  Use the AST
        // nameSpan to locate the name start rather than a magic byte offset,
        // so the rewrite is correct regardless of the whitespace between
        // `fixture` and the name.
        val fixStart = f.span.startPos.offset
        val annLen = fixStart - s
        if annLen > 0 {
          sb = sb + source.substring(s, annLen)
        }
        sb = sb + "val "
        val nameStart = f.nameSpan.startPos.offset
        val fixEnd = f.span.endPos.offset
        if fixEnd > nameStart {
          sb = sb + source.substring(nameStart, fixEnd - nameStart)
        }
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
    sb = sb + source.substring(cursor, source.length - cursor)
  }
  sb = sb + "\n\n"
  sb = sb + synthesizeMain(tests, skipped, filter, nativeMode)
  Synthesised(source = sb, testCount = tests.count, skipCount = skipped.count)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. `listEntries` — used by `lyric test --list`.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
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
      case ITest(t) -> acc.add(TestEntry(title = t.title))
      case IProperty(p) -> acc.add(PropertyEntry(title = p.title, reason = "property: not implemented in v1"))
      case IFixture(f) -> acc.add(FixtureEntry(name = f.name))
      case _ -> {
      }
    }
    i = i + 1
  }
  Ok(value = acc)
}
