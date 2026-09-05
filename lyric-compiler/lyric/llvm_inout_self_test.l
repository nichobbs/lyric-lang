//! llvm_inout_self_test.l — end-to-end self-test for `out`/`inout`
//! function-parameter lowering in `Lyric.LlvmCodegen` (N9.6, #6794,
//! unblocks #6808).
//!
//! Before this fix, `lowerFunctionEnv` panicked unconditionally on any
//! `out`/`inout` parameter for `--target native`. The fix synthesizes an
//! implicit pointer parameter for each `out`/`inout` parameter — the
//! ADDRESS of the caller's storage cell rather than a copy of its value —
//! with no separate alloca on the callee side: every local read
//! (`loadLocal`) and write (`lowerAssign`/`lowerFieldAssign`) already
//! treats `ctx.varSlots[name]` as a bare pointer-to-declared-type SSA
//! value (exactly what an `alloca` produces), so binding the parameter
//! name directly to the incoming pointer makes every read/write alias the
//! CALLER's cell — true reference semantics, matching the MSIL backend's
//! `MByRef` and the JVM backend's boxed-cell by-ref lowering. See
//! `lowerFunctionEnv`'s and `lowerByRefArg`'s doc comments in
//! `llvm_codegen.l` for the full ARC reasoning (04-arc-design.md Rules
//! 3-5 apply unchanged: a write through the by-ref cell runs through the
//! ordinary retain-new/release-old assignment path exactly as a direct
//! `x = newVal` at the caller site would, and the callee never retains on
//! entry or releases on exit since it never owns the pointed-to value).
//!
//! Covered (verified against a real `--target native` build + run, ARC
//! cases under `-fsanitize=address`):
//!   - a scalar `Int` `inout` parameter mutated across repeated calls
//!     (the general "thread an evolving value through a loop" idiom
//!     #6794 cites as the motivating use case);
//!   - an `out Int` parameter that is write-only from the caller's
//!     perspective (T0086 definite-assignment is a type-checker concern;
//!     codegen lowers `out` and `inout` identically — see the doc
//!     comment on `lowerFunctionEnv`);
//!   - two independent `inout` parameters mutated in one call;
//!   - the exact `record St { var n: Int }` / `func bump(s: inout St)`
//!     repro from #6808's own writeup, called twice;
//!   - `inout` mutating a STRING field (ARC-managed: retain-new/
//!     release-old on every reassignment) across a churn loop;
//!   - `inout` mutating a record field that itself holds an ARC-managed
//!     value, AND being reassigned to a wholly fresh record value
//!     partway through a loop (old record released, new one retained);
//!   - chained `inout` forwarding: a parameter received `inout` is
//!     forwarded unchanged to another `inout` call one level down — the
//!     exact shape `Std.HttpEngine`'s H2 frame-dispatch chain
//!     (`dispatchFrame` -> per-frame-type handlers -> nested mutators)
//!     uses pervasively;
//!   - an `inout` argument that is a nested record FIELD access
//!     (`o.inner.count`), not a bare local;
//!   - a loud, named diagnostic (never a silent miscompile) for an
//!     unsupported by-ref argument shape (a list-index expression) —
//!     the documented N9.6 scope cut.
//!
//! Deferred (out of scope for this slice — loud diagnostics, not silent
//! miscompiles): `out`/`inout` on an `extern func` C-ABI declaration;
//! `out`/`inout` on a `protected type` method (the hand-built lock/unlock
//! wrapper does not thread by-ref pointers); `out`/`inout` on an async
//! function's parameter (a suspended coroutine cannot safely hold a
//! pointer into caller-frame storage across a suspend point); a by-ref
//! argument that is an index/element expression or a qualified
//! module-level path.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_inout_self_test.l
@test_module
package Lyric.LlvmInoutSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Uuid as Uuid
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_heap_self_test.l).
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

func findLyricRt(): String {
  var dir = Environment.currentDirectory()
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(Path.join(Path.join(dir, "lyric-rt"), "build"), "lyric_rt.a")
    if File.fileExists(candidate) {
      return candidate
    }
    val parent = Path.dirname(dir)
    if parent.length == 0 or parent == dir {
      return ""
    }
    dir = parent
    hop = hop + 1
  }
  ""
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

func compileAndRunWith(source: in String, sanitize: in Bool): RunOutcome {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    var msg = "test source has parse diagnostics:"
    var i = 0
    while i < pr.diagnostics.count {
      msg = msg + " " + pr.diagnostics[i].code
      i = i + 1
    }
    panic(msg)
  }
  val pkg = codegenNativePackage(pr.file, "")
  val ll = lowerNativePackage(pkg)
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-inout-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val llPath = stem + ".ll"
  match File.writeText(llPath, ll) {
    case Ok(_) -> {
    }
    case Err(_) -> panic("cannot write " + llPath)
  }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O0")
  if sanitize {
    clangArgs.add("-fsanitize=address")
  }
  clangArgs.add(llPath)
  clangArgs.add(rt)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  clangArgs.add("-o")
  clangArgs.add(stem)
  match Process.runCapture("clang", clangArgs, 120000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        panic("clang failed on " + llPath + ": " + res.stderr)
      }
    }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

func compileAndRun(source: in String): RunOutcome {
  compileAndRunWith(source, false)
}

/// ASan+LSan build: leaks, use-after-free, and double-free all exit
/// non-zero, so `exitCode == 0` verifies the emitted ARC protocol around
/// the by-ref alias.
func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

/// Compile only, discarding the codegen result — used by the diagnostic
/// case, which must panic before `lowerNativePackage`/clang ever run.
func codegenOnly(source: in String): Unit {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    panic("test source has parse diagnostics")
  }
  val pkg = codegenNativePackage(pr.file, "")
  val _ = lowerNativePackage(pkg)
}

// ─────────────────────────────────────────────────────────────────────────────
// Scalars.
// ─────────────────────────────────────────────────────────────────────────────
test "inout Int mutated across repeated calls" {
  val src = "package T\n" + "func incr(x: inout Int): Unit {\n" + "  x = x + 1\n" + "}\n" + "func main(): Int {\n" +
    "  var n = 5\n" +
    "  incr(n)\n" +
    "  incr(n)\n" +
    "  incr(n)\n" +
    "  n\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 8, "inout Int loop")
}

test "out Int parameter is written by the callee" {
  val src = "package T\n" + "func setTo(x: out Int, v: in Int): Unit {\n" + "  x = v\n" + "}\n" + "func main(): Int {\n" +
    "  var m = 0\n" +
    "  setTo(m, 100)\n" +
    "  m\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 100, "out Int write")
}

test "two independent inout parameters mutated in one call" {
  val src = "package T\n" + "func addAll(a: inout Int, b: inout Int): Unit {\n" + "  a = a + b\n" + "  b = b * 2\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var a = 10\n" +
    "  var b = 7\n" +
    "  addAll(a, b)\n" +
    "  a + b\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 31, "two inout params: a=17, b=14")
}

test "chained inout forwarding through a nested call" {
  val src = "package T\n" + "func inner(x: inout Int): Unit {\n" + "  x = x * 2\n" + "}\n" +
    "func outer(x: inout Int): Unit {\n" +
    "  inner(x)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var v = 3\n" +
    "  outer(v)\n" +
    "  outer(v)\n" +
    "  v\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 12, "chained inout doubles v twice: 3 -> 6 -> 12")
}

// ─────────────────────────────────────────────────────────────────────────────
// Records (#6808's own minimal repro, plus a nested field target).
// ─────────────────────────────────────────────────────────────────────────────
test "inout record field mutation (#6808 repro)" {
  val src = "package T\n" + "record St {\n" + "  var n: Int\n" + "}\n" + "func bump(s: inout St): Unit {\n" +
    "  s.n = s.n + 1\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var st = St(n = 0)\n" +
    "  bump(st)\n" +
    "  bump(st)\n" +
    "  st.n\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 2, "#6808 repro: bump(st) twice")
}

test "inout argument is a nested record field access" {
  val src = "package T\n" + "record Inner {\n" + "  var count: Int\n" + "}\n" + "record Outer {\n" + "  inner: Inner\n" +
    "}\n" +
    "func bumpInner(c: inout Int): Unit {\n" +
    "  c = c + 1\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val o = Outer(inner = Inner(count = 0))\n" +
    "  bumpInner(o.inner.count)\n" +
    "  bumpInner(o.inner.count)\n" +
    "  bumpInner(o.inner.count)\n" +
    "  o.inner.count\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 3, "nested field inout target")
}

// ─────────────────────────────────────────────────────────────────────────────
// ARC: reference-typed values behind a by-ref alias.
// ─────────────────────────────────────────────────────────────────────────────
test "arc: inout String field reassignment churn is leak-free" {
  val src = "package T\n" + "func setStr(s: inout String, v: in String): Unit {\n" + "  s = v\n" + "}\n" +
    "func main(): Int {\n" +
    "  var s = \"hello\"\n" +
    "  var i = 0\n" +
    "  while i < 3000 {\n" +
    "    setStr(s, \"value-\" + i.toString())\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if s.length > 3 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "inout String churn leak-free (ASan)")
}

test "arc: inout record with a ref-typed field, mutated and wholesale-replaced" {
  val src = "package T\n" + "record St {\n" + "  var tag: String\n" + "}\n" + "func bump(s: inout St): Unit {\n" +
    "  s.tag = s.tag + \"!\"\n" +
    "}\n" +
    "func replaceRec(s: inout St): Unit {\n" +
    "  s = St(tag = \"fresh\")\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var st = St(tag = \"a\")\n" +
    "  var i = 0\n" +
    "  while i < 2000 {\n" +
    "    bump(st)\n" +
    "    if i % 400 == 0 {\n" +
    "      replaceRec(st)\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if st.tag.length > 0 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "inout record field mutation + wholesale replace leak-free (ASan)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Scope cut: a loud diagnostic for an unsupported by-ref argument shape.
// ─────────────────────────────────────────────────────────────────────────────
test "an index-expression out/inout argument is a loud diagnostic, not a miscompile" {
  val src = "package T\n" + "func bump(x: inout Int): Unit {\n" + "  x = x + 1\n" + "}\n" + "func main(): Int {\n" +
    "  var xs: List[Int] = newList()\n" +
    "  xs.add(1)\n" +
    "  bump(xs[0])\n" +
    "  xs[0]\n" +
    "}\n"
  assertPanicsWith(
    "index-expression inout argument",
    "out/inout argument shape is not yet supported",
    { -> codegenOnly(src) }
  )
}

test "an Int local passed to an inout Long parameter is a loud diagnostic, not a silent width mismatch (#6813)" {
  // The type checker's `argSatisfiesParam` widens arithmetic uniformly
  // across every parameter mode, so this type-checks; codegen must catch
  // the width mismatch itself rather than alias an i32 alloca through an
  // i64 by-ref pointer.
  val src = "package T\n" + "func bump(x: inout Long): Unit {\n" + "  x = x + 1\n" + "}\n" + "func main(): Int {\n" +
    "  var n = 5\n" +
    "  bump(n)\n" +
    "  0\n" +
    "}\n"
  assertPanicsWith(
    "Int local against an inout Long parameter",
    "must match the parameter's exactly",
    { -> codegenOnly(src) }
  )
}

test "a record field passed to a mismatched-type inout parameter is a loud diagnostic (#6813)" {
  val src = "package T\n" + "record Box {\n" + "  var n: Int\n" + "}\n" + "func bump(x: inout Long): Unit {\n" +
    "  x = x + 1\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val b = Box(n = 5)\n" +
    "  bump(b.n)\n" +
    "  0\n" +
    "}\n"
  assertPanicsWith(
    "Int field against an inout Long parameter",
    "must match the parameter's exactly",
    { -> codegenOnly(src) }
  )
}
