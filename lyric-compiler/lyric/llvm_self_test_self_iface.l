//! llvm_self_test_self_iface.l — end-to-end self-test for `Self` in an
//! interface method signature on `--target native` (#7585).
//!
//! Before this feature, ANY interface whose method mentions `Self` (as a
//! parameter, a return, or the implicit receiver's own type) failed to
//! compile: `registerInterfaceTypes` resolves every interface method's
//! declared param/return types through `typeExprToNType`, whose fallback
//! arm panicked ("this type form is not yet supported for --target
//! native") on a bare `TSelf` — a hard compile-time failure at interface
//! registration, before any record- or protected-type-specific lowering
//! ever ran. This affected record impls (pre-existing) and protected-type
//! impls (newly reachable once D-progress-1013/#7550 lifted the shared
//! type checker's T0136 rejection for `Self` on protected impls).
//!
//! Fix (D-progress-1016): a bare `Self` erases to a pointer-width `i8*` in the
//! interface's own vtable slot signature — matching the interface box's
//! own erased `obj` slot, ABI-compatible with every concrete impl's
//! pointer-width receiver via the SAME unchecked function-pointer bitcast
//! `ifaceVtableInitStr` already performs for every vtable slot. A
//! `Self`-typed argument dispatched through an interface receiver (its
//! checker-assigned static type is the interface itself, T0113) is
//! unboxed to its raw object pointer at the call site (`coerceTo`); a
//! `Self`-returning call dispatched through an interface receiver reboxes
//! the erased result into a FRESH interface value reusing the receiver's
//! own already-loaded vtable pointer (`lowerIfaceDispatch`). A record or
//! protected impl method's OWN signature is substituted to the concrete
//! type before it ever reaches codegen (`substSelfInFn`/
//! `collectImplMethods`/`registerProtectedMember`), so calling on the
//! CONCRETE receiver needs no narrowing bookkeeping at all.
//!
//! `Self` NESTED inside a generic type argument (`List[Self]`,
//! `Option[Self]`) is a separate, still-unsupported shape: native's
//! generic types monomorphize per concrete type argument (`Lyric.Mono`),
//! and there is no call site to infer `T = Self` from at an interface
//! DECLARATION, so this shape is rejected with a named diagnostic
//! (`panicUnsupportedSelfShape`) instead of falling through to the vaguer
//! generic-type-not-supported panic.
//!
//! Note: calling an ordinary (non-`Self`) `impl` method directly on a
//! CONCRETE record receiver (`sq.area()` where `sq: Square`, not
//! interface-typed) was a separate, pre-existing native gap unrelated to
//! this feature — impl methods on a record were only reachable through an
//! interface-typed receiver on `--target native` (`collectImplMethods`
//! registers them under the collision-free `<Record>.<Iface>.<method>` IR
//! name, which ordinary UFCS resolution never looked up). Fixed in #7600
//! (`registerImplDirectMethods`, `llvm_self_test_impl_direct.l`).
//! Protected-type members were unaffected by that gap
//! (`registerProtectedMember` always registers under the bare
//! `<pkg>.<method>` name), so this file's concrete-receiver cases still use
//! a protected type; every record case here is exercised via an
//! interface-typed receiver, matching every other record/interface test in
//! `llvm_self_test_n3.l`.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_self_test_self_iface.l
@test_module
package Lyric.LlvmSelfTestSelfIface

import Std.Core
import Std.Collections
import Std.Errors
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.String as Str
import Std.Uuid as Uuid
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering
import Lyric.LlvmBridge
import Lyric.ContractElaborator

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_heap_self_test.l's ASan-capable variant).
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
  // `impl Iface for ProtectedType` methods are moved into the protected
  // type as locked entries by the contract elaborator BEFORE codegen ever
  // sees them (D-progress-1009/#7457) — run it here since this harness
  // drives `codegenNativePackage` directly on the parsed AST, bypassing
  // the full `Lyric.Pipeline` sequence `lyric build`/`lyric test` uses.
  val elaborated = elaborateFile(pr.file)
  val pkg = codegenNativePackage(elaborated, "")
  val ll = lowerNativePackage(pkg)
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-self-iface-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
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
/// non-zero, so `exitCode == 0` verifies the emitted ARC protocol for the
/// erased `Self` slot, the interface-box unboxing extraction, and the
/// rebox-on-return path.
func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

// ─────────────────────────────────────────────────────────────────────────────
// Record impl: `Self` parameter and `Self` return, dispatched through an
// interface-typed receiver (records are only reachable this way on native
// today — see the file header note).
// ─────────────────────────────────────────────────────────────────────────────
val mergeableRecordSrc: String = "package T\n" + "interface Mergeable {\n" + "  func merge(other: in Self): Int\n" + "  func fresh(): Self\n" + "  func value(): Int\n" + "}\n" + "record R {\n" + "  x: Int\n" + "}\n" + "impl Mergeable for R {\n" + "  func merge(other: in Self): Int {\n" + "    self.x + other.x\n" + "  }\n" + "  func fresh(): Self {\n" + "    R(x = self.x + 1)\n" + "  }\n" + "  func value(): Int {\n" + "    self.x\n" + "  }\n" + "}\n"

test "record: a Self parameter through an interface receiver reads the other instance's own field" {
  val src = mergeableRecordSrc + "func callMerge(m: in Mergeable, other: in Mergeable): Int {\n" + "  m.merge(other)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val r: Mergeable = R(x = 5)\n" +
    "  val r2: Mergeable = R(x = 7)\n" +
    "  callMerge(r, r2)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 12, "5 + 7 through Mergeable.merge, other unboxed from the interface")
}

test "record: a Self return through an interface receiver types as the interface, and chains" {
  val src = mergeableRecordSrc + "func viaIface(m: in Mergeable): Int {\n" + "  val f = m.fresh()\n" +
    "  val g = f.fresh()\n" +
    "  g.value()\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val r: Mergeable = R(x = 5)\n" +
    "  viaIface(r)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 7, "5 + 1 + 1: fresh() rebox lets the untyped local chain a second interface call")
}

test "record: Self through the interface is ASan-clean (retain/release balanced across box and rebox)" {
  val src = mergeableRecordSrc + "func viaIface(m: in Mergeable, other: in Mergeable): Int {\n" +
    "  val n = m.merge(other)\n" +
    "  val f = m.fresh()\n" +
    "  n + f.value()\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var i = 0\n" +
    "  var total = 0\n" +
    "  while i < 50 {\n" +
    "    val r: Mergeable = R(x = i)\n" +
    "    val r2: Mergeable = R(x = i + 1)\n" +
    "    total = total + viaIface(r, r2)\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if total == total { 0 } else { 1 }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "no leak / use-after-free / double-free through the interface-box + rebox path")
}

test "record: a not-yet-boxed CONCRETE argument at a Self-through-interface parameter upcasts, not just an already-boxed one" {
  val src = mergeableRecordSrc + "func main(): Int {\n" + "  val r: Mergeable = R(x = 5)\n" + "  val r2 = R(x = 7)\n" +
    "  r.merge(r2)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(
    r.exitCode,
    12,
    "r2's static type is the concrete record R (never boxed), not Mergeable — coerceTo must bitcast it to the erased i8* slot directly instead of only handling an already-boxed interface value"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Protected type impl: `Self` parameter and `Self` return, both via the
// CONCRETE receiver (protected members are registered under a bare name,
// reachable via ordinary UFCS — see D-progress-1013) and via an
// interface-typed receiver.
// ─────────────────────────────────────────────────────────────────────────────
val mergerProtectedSrc: String = "package T\n" + "interface Merger {\n" + "  func merge(other: in Self): Int\n" + "  func fresh(): Self\n" + "  func value(): Int\n" + "}\n" + "protected type Acc {\n" + "  var n: Int = 0\n" + "}\n" + "impl Merger for Acc {\n" + "  func merge(other: in Self): Int {\n" + "    n = n + other.value()\n" + "    n\n" + "  }\n" + "  func fresh(): Self {\n" + "    Acc(n = n)\n" + "  }\n" + "  func value(): Int {\n" + "    self.n\n" + "  }\n" + "}\n"

test "protected: a Self parameter and Self return via the CONCRETE receiver" {
  val src = mergerProtectedSrc + "func main(): Int {\n" + "  val a = Acc(n = 10)\n" + "  val b = Acc(n = 5)\n" +
    "  val sum = a.merge(b)\n" +
    "  val f = a.fresh()\n" +
    "  sum + f.value()\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 30, "(10+5) + 15: merge mutates a.n, fresh() snapshots it concretely")
}

test "protected: a Self parameter and Self return via an interface receiver" {
  val src = mergerProtectedSrc + "func viaIface(m: in Merger, other: in Merger): Int {\n" +
    "  val sum = m.merge(other)\n" +
    "  val f = m.fresh()\n" +
    "  sum + f.value()\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a: Merger = Acc(n = 3)\n" +
    "  val b: Merger = Acc(n = 4)\n" +
    "  viaIface(a, b)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 14, "(3+4) + 7: same result dispatched through the interface")
}

test "protected: Self through the interface is ASan-clean" {
  val src = mergerProtectedSrc + "func viaIface(m: in Merger, other: in Merger): Int {\n" +
    "  val sum = m.merge(other)\n" +
    "  val f = m.fresh()\n" +
    "  sum + f.value()\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var i = 0\n" +
    "  var total = 0\n" +
    "  while i < 50 {\n" +
    "    val a: Merger = Acc(n = i)\n" +
    "    val b: Merger = Acc(n = i + 1)\n" +
    "    total = total + viaIface(a, b)\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if total == total { 0 } else { 1 }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "no leak / use-after-free / double-free for the protected-impl interface path")
}

// ─────────────────────────────────────────────────────────────────────────────
// Nested `Self` (`List[Self]`): a named diagnostic, not an untyped panic.
// ─────────────────────────────────────────────────────────────────────────────
// `List[Self]` and `newList()` here are unimported builtins from this
// program's own point of view (no `import Std.Collections`, deliberately
// — see below) — the middle end's typecheck is advisory-only on the
// native target (real T0010/T0020 diagnostics from it are printed but do
// NOT gate the build; only mode-check/propagate/mono/weave and, since
// #7585, this N0006 pre-pass gate), so this still exercises exactly what
// this test is about without needing to plumb real bundled stdlib
// sources through `compileToNativeWithFlags`'s `stdlibSources` parameter.
val nestedSelfSrc: String = "package T\n" + "interface Snapshot {\n" + "  func snapshot(): List[Self]\n" + "}\n" + "record Ledger {\n" + "  n: Int\n" + "}\n" + "impl Snapshot for Ledger {\n" + "  func snapshot(): List[Self] {\n" + "    newList()\n" + "  }\n" + "}\n" + "func main(): Int { 0 }\n"

test "Self nested inside a generic type argument reports a structured N0006 diagnostic, not a panic" {
  // Exercises the PRIMARY path (#7585 review): `nativeSelfShapeDiagnostics`
  // is the pre-pass `Lyric.LlvmBridge` runs BEFORE codegen, so this is a
  // pure diagnostic-producing function — no exception, no stack trace.
  val pr = parse(nestedSelfSrc)
  assertTrue(pr.diagnostics.count == 0, "source parses cleanly")
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile("T", pr.file))
  val diags = nativeSelfShapeDiagnostics(units)
  assertTrue(diags.count == 1, "exactly one diagnostic for the one nested-Self return")
  val d = diags[0]
  assertEqual(d.code, "N0006", "the diagnostic carries the N0006 code")
  assertTrue(d.span.startPos.line > 0, "the diagnostic carries a real source span")
  assertTrue(Str.contains(d.message, "Snapshot"), "diagnostic names the interface")
  assertTrue(Str.contains(d.message, "snapshot"), "diagnostic names the method")
  assertTrue(Str.contains(d.message, "nested"), "diagnostic distinguishes the nested shape from bare Self")
}

test "Self nested inside a generic type argument fails the full native build cleanly, before codegen" {
  // End-to-end proof that `lyric build --target native` on this source
  // prints a normal `error[N0006]` line and exits non-zero -- no
  // exception ever reaches this call, unlike before this fix (an
  // unhandled `System.Exception` with a `Lyric.LlvmCodegen` stack trace).
  val dir = Path.join(tempBase(), "lyric-self-iface-nested-diag-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
  val noStdlib: List[String] = newList()
  val noFlags: List[String] = newList()
  val ok = compileToNativeWithFlags(nestedSelfSrc, stem, noStdlib, "", "0", noFlags, newList(), "")
  assertTrue(not ok, "the build fails (Bool false), not an unhandled exception")
}
