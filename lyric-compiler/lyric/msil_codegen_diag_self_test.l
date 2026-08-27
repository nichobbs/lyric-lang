//! msil_codegen_diag_self_test.l — regression tests for #4898.
//!
//! `msil/codegen.l`'s external-interface conformance validation (F0020–
//! F0024) and its try-catch-as-expression Unit/value mismatch check
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
//! Every "bad" case below compiles a small package payload through the
//! in-process `Msil.Bridge` and asserts the build **fails cleanly**
//! (`compileProjectToMsilWithFeatures` returns `false`, no panic
//! propagates out of this test process) — mirroring how
//! `msil_project_bridge_self_test.l`'s "cfg erasure F0012 malformed" test
//! already pins the identical hard-error-diagnostic contract for
//! `Lyric.Cfg`.  A "good" companion case per condition pins that the
//! corresponding conforming shape still compiles, so the new diagnostic
//! logic cannot spuriously reject legitimate code.
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
// these tests, only the boolean result matters (did the build reject
// the F002x condition without panicking).
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

// ─── F0020: `impl` target resolves but is not a .NET interface ─────────────
test "F0020: impl block against a non-interface extern type fails cleanly" {
  val src = "package F0020App\n" + "\n" + "extern type NotIface = \"System.String\"\n" + "\n" + "record R0020 {\n" +
    "  tag: Int\n" +
    "}\n" +
    "\n" +
    "impl NotIface for R0020 {\n" +
    "  func whatever(): Unit {\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(\"unreachable\")\n" +
    "}\n"
  assertTrue(not compiles("F0020Bad", src), "impl against System.String (a class) must be rejected, not panic")
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
  assertTrue(not compiles("F0021Bad", src), "impl IDisposable missing Dispose() must be rejected, not panic")
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
  assertTrue(
    not compiles("F0022CountBad", src),
    "Dispose(extra: Int) takes one parameter more than the .NET interface declares; must be rejected"
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
  assertTrue(
    not compiles("F0022TypeBad", src),
    "Equals(other: Int) instead of Equals(other: GenRec0022t) must be rejected"
  )
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
  assertTrue(not compiles("F0023Bad", src), "Equals returning Int instead of Bool must be rejected")
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
  assertTrue(
    not compiles("F0024Bad", src),
    "a typo'd extern-type FQN absent from every indexed assembly must be rejected, not silently accepted"
  )
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
  assertTrue(
    not compiles("F0025Bad", src),
    "try-catch expr with a Unit catch arm beside an Int try body must be rejected, not panic"
  )
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
