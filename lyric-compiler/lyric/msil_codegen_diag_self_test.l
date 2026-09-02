//! msil_codegen_diag_self_test.l — regression tests for #4898.
//!
//! `msil/codegen.l`'s external-interface conformance validation (F0021–
//! F0024, F0034) and its try-catch-as-expression Unit/value mismatch check
//! (F0025) used to fail a genuine, compile-time-detectable user error by
//! calling `panic`, which unwinds as an escaped exception rather than a
//! clean, positioned build diagnostic.  They now append a positioned
//! `Diagnostic` to `CodegenCtx.diagnostics` instead; `Msil.Bridge` checks
//! that list right after `codegenMPackage` returns and aborts the build
//! (via `Lyric.DiagnosticUtil.diagReportAndAbort`, the same convention
//! `Lyric.Pipeline.gate` uses for the type-checker / mode-checker /
//! cfg-erasure diagnostic lists) instead of proceeding to lower invalid
//! IR.
//!
//! Every "good" case below compiles a small package payload through the
//! in-process `Msil.Bridge` and asserts the build succeeds — pinning that
//! the F002x checks don't spuriously reject legitimate code.
//!
//! Every "bad" case compiles through `Msil.Bridge.compileProjectToMsilWith
//! FeaturesDiag` (added alongside this fix) instead of the plain
//! `compileProjectToMsilWithFeatures`: the plain variant only ever returns a
//! `Bool` (this file's own original form), which proved the build merely
//! FAILED — never which diagnostic fired, its code, or its position, so a
//! future change that deleted the `errorDiagnostic("F00xx", …, decl.span)`
//! call (or fed it an empty/wrong span) could regress silently as long as
//! *some* failure still resulted. `...Diag` threads `cctx.diagnostics`
//! (`Msil.Codegen`'s F0021–F0025, F0034 accumulator) back through an `outDiagnostics`
//! out-list, so each "bad" case asserts the EXACT diagnostic — code AND the
//! real source position of the offending construct (the `impl` keyword for
//! F0034/F0024, the mismatching `func` for F0022/F0023, the `catch` keyword
//! for F0025) — not merely that the build failed.
//!
//! In-process, not a spawned `./bin/lyric build` subprocess (contrast
//! `source_path_diagnostics_self_test.l`, added alongside this fix for
//! #6282/#6284): the self-hosted emitter's cross-PACKAGE emission is not
//! execution-clean today (docs/41 §R7 — see
//! `scripts/stage-selfhosted-compiler.sh`'s header for the canonical
//! writeup), so reading a `CodegenCtx` field like `cctx.diagnostics` from a
//! caller compiled into a DIFFERENT assembly than the one that populated it
//! is exactly the shape that corrupts. `./bin/lyric`'s own CLI bundle
//! compiles `Msil.Codegen` / `Msil.Bridge` / `Lyric.Emitter` as separate
//! per-package DLLs (cross-assembly), which is confirmed to hit this: a
//! `lyric build` subprocess on any of this file's "bad" fixtures degrades
//! the clean `error[F0034] 9:1: …` diagnostic into a generic, position-lost
//! `error[T0120]: MSIL codegen failed: …` panic wrapper instead. `lyric
//! test` avoids the corruption by resolving this file's own compiler-package
//! imports (`Msil.Bridge`) from the single merged `Lyric.Compiler.dll`
//! bundle (D111) — every cross-package reference stays in-bundle — so the
//! in-process calls below see the real, correctly-positioned diagnostics.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/msil_codegen_diag_self_test.l
@test_module
package Lyric.MsilCodegenDiagSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment as Environment
import Msil.Bridge

func mkPkg(name: in String, source: in String): ProjectPackagePayload {
  ProjectPackagePayload(name = name, source = source)
}

// Mirrors `msil_project_bridge_self_test.l`'s `tempBase()` — honour
// $TMPDIR/$TEMP/$TMP before falling back to /tmp, per scripts/bootstrap.sh's
// own convention, so a sandbox with a read-only /tmp doesn't fail these
// "good" cases on a spurious disk-write error instead of the diagnostic
// logic under test.
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

// Compiles `source` as a single-package project bundle to a throwaway
// path and returns whether the bridge accepted it.  Never writes
// anything meaningful to disk — `outputPath` is never read back by
// these tests, only the boolean result matters.  Used by the "good"
// companion cases, where a plain pass/fail is all that's needed.
func compiles(label: in String, source: in String): Bool {
  val pkgs: List[ProjectPackagePayload] = newList()
  pkgs.add(mkPkg(label, source))
  val empty: List[String] = newList()
  val stdlibSources: List[String] = newList()
  compileProjectToMsilWithFeatures(
    pkgs,
    label,
    tempBase() + "/lyric-msil-codegen-diag-" + label + ".dll",
    stdlibSources,
    empty,
    empty
  )
}

// Compiles `source` the same way as `compiles`, but through the
// diagnostics-returning bridge entry point — used by every "bad" case so it
// can assert the exact F00xx code and position, not just pass/fail.
func compileDiag(label: in String, source: in String, outDiagnostics: in List[Diagnostic]): Bool {
  val pkgs: List[ProjectPackagePayload] = newList()
  pkgs.add(mkPkg(label, source))
  val empty: List[String] = newList()
  val stdlibSources: List[String] = newList()
  compileProjectToMsilWithFeaturesDiag(
    pkgs,
    label,
    tempBase() + "/lyric-msil-codegen-diag-" + label + ".dll",
    stdlibSources,
    empty,
    empty,
    outDiagnostics
  )
}

// Asserts `diags` carries exactly one error-severity diagnostic with the
// given `code` at the given `line`/`col` — proving a real, positioned
// `Diagnostic` fired with THIS specific code at THIS specific source
// location, not merely "the build failed for some reason".
func assertDiagAt(diags: in List[Diagnostic], code: in String, line: in Int, col: in Int, label: in String): Unit {
  var found = false
  var i = 0
  while i < diags.count {
    val d = diags[i]
    if d.code == code and d.span.startPos.line == line and d.span.startPos.column == col {
      found = true
    }
    i = i + 1
  }
  var seen = ""
  var j = 0
  while j < diags.count {
    val d = diags[j]
    seen = seen + d.code + "@" + toString(d.span.startPos.line) + ":" + toString(d.span.startPos.column) + " "
    j = j + 1
  }
  assertTrue(
    found,
    label + ": expected " + code + "@" + toString(line) + ":" + toString(col) + " among the returned diagnostics, got: " +
      seen
  )
}

// ─── F0034: `impl` target resolves but is not a .NET interface ─────────────
// Numbered F0034, not F0020, to avoid colliding with propagate.l's
// pre-existing F0020 (`?` used in a function returning neither Result nor
// Option) — see #6648.
test "F0034: impl block against a non-interface extern type fails cleanly" {
  val src = "package F0034App\n" + "\n" + "extern type NotIface = \"System.String\"\n" + "\n" + "record R0034 {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl NotIface for R0034 {\n" +
    "  func whatever(): Unit {\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"unreachable\")\n" +
    "}\n"
  // `impl` keyword on line 9, column 1 — `decl.span` starts there
  // (`parser_items.l::parseImplBody`'s `startTok`).
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0034Bad", src, diags)
  assertTrue(not ok, "impl against System.String (a class) must be rejected, not panic")
  assertDiagAt(diags, "F0034", 9, 1, "F0034: impl against System.String (a class)")
}

// ─── F0021: `impl` is missing a required interface method ──────────────────
test "F0021: impl block missing a required method fails cleanly" {
  val src = "package F0021App\n" + "\n" + "extern type IDisposable0021 = \"System.IDisposable\"\n" + "\n" +
    "record R0021 {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl IDisposable0021 for R0021 {\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"unreachable\")\n" +
    "}\n"
  // `impl` keyword on line 9, column 1 — F0021 also uses `decl.span`
  // (`checkOneInterfaceMethodMsil`'s `None` arm, no matching impl method
  // found for the interface's `Dispose`).
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0021Bad", src, diags)
  assertTrue(not ok, "impl IDisposable missing Dispose() must be rejected, not panic")
  assertDiagAt(diags, "F0021", 9, 1, "F0021: impl IDisposable missing Dispose()")
}

// Companion "good" case: the same interface, correctly implemented,
// still compiles — pins that F0021's conversion from panic to a
// diagnostic didn't turn into a false positive on conforming code.
test "impl block correctly implementing IDisposable still compiles" {
  val src = "package F0021Good\n" + "\n" + "extern type IDisposable0021g = \"System.IDisposable\"\n" + "\n" +
    "record R0021g {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl IDisposable0021g for R0021g {\n" +
    "  func Dispose(): Unit {\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"ok\")\n" +
    "}\n"
  assertTrue(compiles("F0021Good", src), "a conforming impl of IDisposable must still compile cleanly")
}

// ─── F0022: impl method parameter count mismatch ───────────────────────────
test "F0022: impl method with wrong parameter count fails cleanly" {
  val src = "package F0022CountApp\n" + "\n" + "extern type IDisposable0022c = \"System.IDisposable\"\n" + "\n" +
    "record R0022c {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl IDisposable0022c for R0022c {\n" +
    "  func Dispose(extra: in Int): Unit {\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"unreachable\")\n" +
    "}\n"
  // F0022/F0023 use `implFn.span`, whose start is the impl method's `func`
  // token (`parseFunctionDeclBody`'s `startSpan`) — line 10, column 3
  // (two-space indent before `func Dispose`).
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0022CountBad", src, diags)
  assertTrue(not ok, "Dispose(extra: Int) takes one parameter more than the .NET interface declares; must be rejected")
  assertDiagAt(
    diags,
    "F0022",
    10,
    3,
    "F0022: Dispose(extra: Int) takes one parameter more than the .NET interface declares"
  )
}

// ─── F0022: impl method parameter type mismatch ────────────────────────────
// `System.IEquatable<T>.Equals(T)` closed over `GenRec` expects a
// `GenRec`-typed parameter after substitution; declaring it `Int`
// instead keeps the parameter COUNT right (so the count check above
// passes) but trips the per-parameter type comparison.
test "F0022: impl method with wrong parameter type fails cleanly" {
  val src = "package F0022TypeApp\n" + "\n" + "extern type IEquatable0022t[T] = \"System.IEquatable`1\"\n" + "\n" +
    "record GenRec0022t {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl IEquatable0022t[GenRec0022t] for GenRec0022t {\n" +
    "  func Equals(other: in Int): Bool {\n" +
    "    true\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"unreachable\")\n" +
    "}\n"
  // `func Equals` is on line 10, column 3.
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0022TypeBad", src, diags)
  assertTrue(not ok, "Equals(other: Int) instead of Equals(other: GenRec0022t) must be rejected")
  assertDiagAt(diags, "F0022", 10, 3, "F0022: Equals(other: Int) instead of Equals(other: GenRec0022t)")
}

// ─── F0023: impl method return type mismatch ───────────────────────────────
test "F0023: impl method with wrong return type fails cleanly" {
  val src = "package F0023App\n" + "\n" + "extern type IEquatable0023[T] = \"System.IEquatable`1\"\n" + "\n" +
    "record GenRec0023 {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl IEquatable0023[GenRec0023] for GenRec0023 {\n" +
    "  func Equals(other: in GenRec0023): Int {\n" +
    "    0\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"unreachable\")\n" +
    "}\n"
  // `func Equals` is on line 10, column 3 (same shape as F0022's type case).
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0023Bad", src, diags)
  assertTrue(not ok, "Equals returning Int instead of Bool must be rejected")
  assertDiagAt(diags, "F0023", 10, 3, "F0023: Equals returning Int instead of Bool")
}

// Companion "good" case: the closed generic interface correctly
// implemented, mirroring `ffi_iface_impl_self_test.l`'s own coverage —
// pins that F0022/F0023's conversion didn't spuriously reject the
// exact shape D105 already ships.
test "closed generic impl (IEquatable[T]) correctly implemented still compiles" {
  val src = "package F0023Good\n" + "\n" + "extern type IEquatable0023g[T] = \"System.IEquatable`1\"\n" + "\n" +
    "record GenRec0023g {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl IEquatable0023g[GenRec0023g] for GenRec0023g {\n" +
    "  func Equals(other: in GenRec0023g): Bool {\n" +
    "    other.tag == self.tag\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"ok\")\n" +
    "}\n"
  assertTrue(compiles("F0023Good", src), "a conforming closed-generic impl of IEquatable[T] must still compile cleanly")
}

// ─── F0024: `extern type` FQN typo — not present in any indexed assembly ───
test "F0024: impl target FQN typo (not in reference metadata) fails cleanly" {
  val src = "package F0024App\n" + "\n" + "extern type IDisposableTypo = \"System.IDisposableXYZNotReal\"\n" + "\n" +
    "record R0024 {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl IDisposableTypo for R0024 {\n" +
    "  func Dispose(): Unit {\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"unreachable\")\n" +
    "}\n"
  // F0024 uses `decl.span` too (`validateOneExternImplMsil`'s typo-not-
  // present arm) — `impl` keyword on line 9, column 1.
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0024Bad", src, diags)
  assertTrue(
    not ok,
    "a typo'd extern-type FQN absent from every indexed assembly must be rejected, not silently accepted"
  )
  assertDiagAt(diags, "F0024", 9, 1, "F0024: typo'd extern-type FQN absent from every indexed assembly")
}

// ─── F0025: try-catch-as-expression Unit/value mismatch ────────────────────
// A NON-generic function with this shape is now rejected earlier, at
// type-check time, by T0067 (#2355/#3262) — so it never reaches
// `lowerTryCatchExprMsil` at all.  To exercise the codegen-level F0025
// path specifically (mirroring `jvm_trycatch_bridge_self_test.l`'s
// identical reasoning for the JVM backend's `error[J004]` twin), the
// mismatch must hide behind a **generic** type parameter: the type
// checker treats the still-unbound `T` leniently (it unifies with
// anything, so no T0067 fires at the generic definition), and it is
// only `Lyric.Mono`'s monomorphized copy — specialised for the `Int`
// argument at the `wrap(1)` call site — where the try body's inferred
// type (`Int`) and the catch arm's `Unit` genuinely collide.  That
// collision is exactly the type-checker gap #2042 shape
// `lowerTryCatchExprMsil` used to `panic("F0025: …")` on.
test "F0025: try-catch expression with a Unit-yielding, non-diverging catch arm fails cleanly" {
  val src = "package F0025App\n" + "\n" + "func wrap[T](v: in T): T {\n" + "  val r = try {\n" + "    v\n" +
    "  } catch Bug as _ {\n" +
    "    println(0)\n" +
    "  }\n" +
    "  r\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(toString(wrap(1)))\n" +
    "}\n"
  // F0025 uses `c.span` (the catch clause's own span, `parseCatchClause`'s
  // `startTok` = the `catch` keyword) — line 6, column 5 (`  } catch …`:
  // two-space indent, `}`, space, then `catch` starts at column 5).
  // `Lyric.Mono` preserves the original clause span verbatim when it clones
  // `wrap`'s body for the `Int`-specialised copy (`mono.l`'s `STry`
  // substitution threads `span = cc.span` through unchanged), so the
  // diagnostic still points at the generic source, not a synthetic location.
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0025Bad", src, diags)
  assertTrue(not ok, "try-catch expr with a Unit catch arm beside an Int try body must be rejected, not panic")
  assertDiagAt(diags, "F0025", 6, 5, "F0025: try-catch expr with a Unit catch arm beside an Int try body")
}

// Companion "good" case: the catch arm yields the same type as the try
// body (an `Int` trailing expression) — the ordinary, well-typed
// try-catch-as-expression shape must still compile and (when run)
// produce the try body's value on the non-throwing path.
test "try-catch expression with matching arm types still compiles" {
  val src = "package F0025Good\n" + "\n" + "func risky(x: in Int): Int {\n" + "  x\n" + "}\n" + "\n" +
    "func run(): Int {\n" +
    "  try {\n" +
    "    risky(1)\n" +
    "  } catch Bug as e {\n" +
    "    0\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(toString(run()))\n" +
    "}\n"
  assertTrue(compiles("F0025Good", src), "a well-typed try-catch expression must still compile cleanly")
}

// ─── F0015: @externTarget literal-constant kind vs declared return type ────
// `emitExternTargetConstMsil` (#6727) covers the shape where an
// `@externTarget` names a BCL literal (Constant-table) field whose decoded
// kind doesn't match the wrapper's declared Lyric return type — a literal
// field has no storage, so falling through to `ldsfld` would fault at run
// time with `MissingFieldException` instead of failing here at build time.
// `System.Math.PI` is a real `public const double PI` field; declaring the
// wrapper's return as `Int` (not `Double`) hits the `ECVR8Bits` /
// `not retIsDouble` arm.
test "F0015: @externTarget literal-constant field with a mismatched declared return type fails cleanly" {
  val src = "package F0015App\n" + "\n" + "@externTarget(\"System.Math.PI\")\n" + "func mathPiWrongType(): Int = ()\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(toString(mathPiWrongType()))\n" +
    "}\n"
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0015Bad", src, diags)
  assertTrue(
    not ok,
    "an @externTarget literal-constant field with a mismatched declared return type must be rejected, not panic"
  )
  var found = false
  var i = 0
  while i < diags.count {
    if diags[i].code == "F0015" {
      found = true
    }
    i = i + 1
  }
  assertTrue(found, "F0015: Math.PI (a Double literal) declared as Int must raise F0015")
}

// Companion "good" case: the same literal field, declared with the correct
// (`Double`) return type, must still compile and inline the real constant.
test "@externTarget literal-constant field with a matching declared return type still compiles" {
  val src = "package F0015Good\n" + "\n" + "@externTarget(\"System.Math.PI\")\n" + "func mathPi(): Double = ()\n" + "\n" +
    "func main(): Unit {\n" +
    "  println(toString(mathPi()))\n" +
    "}\n"
  assertTrue(compiles("F0015Good", src), "Math.PI declared as Double must still compile cleanly")
}

// ─── F0026: @externTarget typed-delegate parameter passed a non-literal ────
// A function-typed `@externTarget` parameter that binds to a real closed
// `System.Action`N`/`System.Func`N`` delegate (docs/50/D122) only builds
// that typed delegate for a lambda LITERAL passed directly at the call
// site — any other argument shape (here, a `val`-bound lambda passed by
// name) would still carry the pre-existing uniform boxed ABI value, which
// no longer matches the callee's now-really-typed parameter. `Task.
// ContinueWith(Action<Task>)` is a real, minimal BCL target for this: a
// one-param, `Unit`-returning delegate is a genuinely *generic* `Action`1`
// instantiation (not the always-safe zero-arg `System.Action` shape),
// so it is at risk of the mismatch this check exists to catch.
test "F0026: @externTarget typed-delegate parameter passed a val-bound lambda (not a literal) fails cleanly" {
  val src = "package F0026App\n" + "\n" + "extern type Task0026 = \"System.Threading.Tasks.Task\"\n" + "\n" +
    "@externStatic\n" +
    "@externTarget(\"System.Threading.Tasks.Task.Delay\")\n" +
    "func taskDelay0026(ms: in Int): Task0026 = ()\n" +
    "\n" +
    "@externInstance\n" +
    "@externTarget(\"System.Threading.Tasks.Task.ContinueWith\")\n" +
    "func continueWith0026(t: in Task0026, action: in (Task0026) -> Unit): Task0026 = ()\n" +
    "\n" +
    "func makeAction0026(): (Task0026) -> Unit {\n" +
    "  { t: Task0026 -> () }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val t = taskDelay0026(0)\n" +
    "  val cb = makeAction0026()\n" +
    "  val _ = continueWith0026(t, cb)\n" +
    "}\n"
  val diags: List[Diagnostic] = newList()
  val ok = compileDiag("F0026Bad", src, diags)
  assertTrue(
    not ok,
    "an @externTarget typed-delegate parameter passed a val-bound (non-literal) lambda must be rejected, not panic"
  )
  var found = false
  var i = 0
  while i < diags.count {
    if diags[i].code == "F0026" {
      found = true
    }
    i = i + 1
  }
  assertTrue(found, "F0026: a val-bound lambda passed to a typed-delegate @externTarget parameter must raise F0026")
}

// Companion "good" case: the same target, called with a direct lambda
// literal at the call site instead of a `val`-bound reference — must still
// compile cleanly (the whole point of the ELambda-literal exemption).
test "@externTarget typed-delegate parameter passed a direct lambda literal still compiles" {
  val src = "package F0026Good\n" + "\n" + "extern type Task0026g = \"System.Threading.Tasks.Task\"\n" + "\n" +
    "@externStatic\n" +
    "@externTarget(\"System.Threading.Tasks.Task.Delay\")\n" +
    "func taskDelay0026g(ms: in Int): Task0026g = ()\n" +
    "\n" +
    "@externInstance\n" +
    "@externTarget(\"System.Threading.Tasks.Task.ContinueWith\")\n" +
    "func continueWith0026g(t: in Task0026g, action: in (Task0026g) -> Unit): Task0026g = ()\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val t = taskDelay0026g(0)\n" +
    "  val _ = continueWith0026g(t, { x: Task0026g -> () })\n" +
    "}\n"
  assertTrue(
    compiles("F0026Good", src),
    "a direct lambda-literal argument to a typed-delegate parameter must still compile cleanly"
  )
}
