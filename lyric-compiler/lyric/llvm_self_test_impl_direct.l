//! llvm_self_test_impl_direct.l — end-to-end self-test for calling an
//! `impl Iface for Record` method directly on a CONCRETE record receiver
//! on `--target native` (#7600).
//!
//! Before this fix, `sq.area()` where `sq: Square` (not interface-typed)
//! failed to lower: `collectImplMethods` registers an impl method under
//! the collision-free `<Record>.<Iface>.<method>` name for the vtable
//! (`ifaceVtableInitStr`), but `lowerUfcsCall`'s ordinary method-call
//! resolution (curPkg/tyName/bareTyName/legacy-fallback/bare-name tiers)
//! never looks that name up — only an interface-typed receiver
//! (`ifaceBoxInfoOfType` + `lowerIfaceDispatch`) ever reached an impl
//! method. Protected-type impls were unaffected: the contract elaborator
//! moves their methods into the type's own `entry`/`func` members
//! (#7457), which register under the bare `<pkg>.<method>` name any
//! ordinary UFCS lookup already finds.
//!
//! Fix: `registerImplDirectMethods` indexes every non-generic `impl I for
//! R` method under `<pkg>.<R>.<method>/<arity>` -> its `ctx.sigs` key
//! (PACKAGE-QUALIFIED, #7627 review follow-up — a bare record name would
//! alias two same-named records declared in different packages of a
//! multi-package native bundle to whichever package's impl happened to
//! register first), in the SAME units/impls/members order the type
//! checker's own `symTableAddImpl`/`methodCandidatesFor` walk `tbl.impls`.
//! `lowerUfcsCall` consults this index before the bare `curPkg + "." +
//! name` fallback (so an UNRELATED same-named free function never shadows
//! a real impl method) and after no own-body method claims the name (a
//! record can no longer declare both an own-body method and a same-named
//! impl method at all — the type checker rejects that shape as T0139,
//! #7626 review follow-up, the same way it already rejected the
//! protected-type analog as T0136).
//!
//! A `Self`-returning impl method needs no special handling when called
//! directly: `collectImplMethods`/`implMethodToFn` already substitutes
//! `Self` to the concrete record type in the method's OWN signature
//! before it ever reaches codegen, so the registered `ctx.sigs` entry's
//! return type is already concrete.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_self_test_impl_direct.l
@test_module
package Lyric.LlvmSelfTestImplDirect

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
import Lyric.Emitter
import Lyric.DiagnosticUtil as DiagUtil

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_self_test_self_iface.l's ASan-capable variant).
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
  val dir = Path.join(tempBase(), "lyric-llvm-self-impl-direct-selftest")
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
/// non-zero, so `exitCode == 0` verifies the direct-call path's ARC
/// protocol (no box, no unbox — the plain concrete-receiver call).
func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

// Multi-package project harness (mirrors llvm_project_self_test.l), used
// only by the #7627 cross-package aliasing regression below — the rest of
// this file's tests are single-package (`compileAndRun`/`compileAndRunAsan`).
func compileAndRunProject(packages: in List[NativeSourcePackage]): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-impl-direct-project-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
  val noFlags: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noOriginsByPkg: List[DiagUtil.PackageLineOrigins] = newList()
  if not compileProjectToNativeWithFlags(packages, stem, stdlib, "", "0", noFlags, newList(), noFeatures, noFeatures, "", noOriginsByPkg, true) {
    panic("native project compilation failed")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Plain return, direct call on a concrete record receiver.
// ─────────────────────────────────────────────────────────────────────────────
val shapeSrc: String = "package T\n" + "interface Shape {\n" + "  func area(): Int\n" + "}\n" + "record Square {\n" + "  side: Int\n" + "}\n" + "impl Shape for Square {\n" + "  func area(): Int {\n" + "    self.side * self.side\n" + "  }\n" + "}\n"

test "a plain-returning impl method is callable directly on the concrete record receiver" {
  val src = shapeSrc + "func main(): Int {\n" + "  val sq = Square(side = 4)\n" + "  sq.area()\n" + "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 16, "4*4 via Square.area(), called directly (not through an interface receiver)")
}

test "a plain-returning impl method direct call is ASan-clean" {
  val src = shapeSrc + "func main(): Int {\n" + "  var total = 0\n" + "  var i = 0\n" + "  while i < 50 {\n" +
    "    val sq = Square(side = i)\n" +
    "    total = total + sq.area()\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if total == total { 0 } else { 1 }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "no leak / use-after-free / double-free through the direct-call path")
}

// ─────────────────────────────────────────────────────────────────────────────
// `Self`-returning impl method, direct call: the result is concrete (no
// interface box, no rebox — Self is already substituted to the record
// type in the impl method's own registered signature).
// ─────────────────────────────────────────────────────────────────────────────
val cloneableSrc: String = "package T\n" + "interface Cloneable {\n" + "  func doubled(): Self\n" + "  func value(): Int\n" + "}\n" + "record Box {\n" + "  n: Int\n" + "}\n" + "impl Cloneable for Box {\n" + "  func doubled(): Self {\n" + "    Box(n = self.n * 2)\n" + "  }\n" + "  func value(): Int {\n" + "    self.n\n" + "  }\n" + "}\n"

test "a Self-returning impl method direct call yields a concrete value, chainable without a rebox" {
  val src = cloneableSrc + "func main(): Int {\n" + "  val b = Box(n = 5)\n" + "  val d = b.doubled()\n" +
    "  d.value()\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 10, "5*2: doubled() returns a concrete Box, .value() then calls directly on it too")
}

// ─────────────────────────────────────────────────────────────────────────────
// A free function sharing a name with an impl method: the two never
// collide (disjoint ctx.sigs keys — the impl method's own name is
// qualified by both the record and the interface).
// ─────────────────────────────────────────────────────────────────────────────
val freeFnSameNameSrc: String = "package T\n" + "interface Shape {\n" + "  func area(): Int\n" + "}\n" + "record Square {\n" + "  side: Int\n" + "}\n" + "impl Shape for Square {\n" + "  func area(): Int {\n" + "    self.side * self.side\n" + "  }\n" + "}\n" + "func area(x: Int): Int {\n" + "  x + 3\n" + "}\n"

test "a free function with the same name as an impl method resolves independently on both call forms" {
  // Process exit codes are 8-bit (POSIX), so the sum stays under 256 —
  // this is a value-carrying-in-the-exit-code test harness constraint,
  // not a language one.
  val src = freeFnSameNameSrc + "func main(): Int {\n" + "  val sq = Square(side = 4)\n" + "  val direct = sq.area()\n" +
    "  val free = area(5)\n" +
    "  direct + free\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 24, "16 (Square.area(), method call) + 8 (area(5), plain call) -- no cross-talk")
}

// ─────────────────────────────────────────────────────────────────────────────
// Two packages each declare a record with the SAME bare name ("Widget"),
// each implementing its own interface's same-named method ("value") with a
// DIFFERENT body (#7627): a bare-name-keyed index would alias whichever
// package registered first, so both packages' `.value()` calls would
// silently return the SAME (wrong, for one of them) result. Package-
// qualified keys keep them independent. `A`'s formula (n+1) and `B`'s
// (n+2) are chosen so an aliasing bug is numerically visible in the sum.
// ─────────────────────────────────────────────────────────────────────────────
test "two packages with a same-named record and same-named impl method resolve independently (#7627)" {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "Proj7.A",
      path = "",
      source = "package Proj7.A\n" + "interface AIfc {\n" + "  func value(): Int\n" + "}\n" + "pub record Widget {\n" +
        "  n: Int\n" +
        "}\n" +
        "impl AIfc for Widget {\n" +
        "  func value(): Int {\n" +
        "    self.n + 1\n" +
        "  }\n" +
        "}\n" +
        "pub func run(): Int {\n" +
        "  Widget(n = 10).value()\n" +
        "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj7.B",
      path = "",
      source = "package Proj7.B\n" + "interface BIfc {\n" + "  func value(): Int\n" + "}\n" + "pub record Widget {\n" +
        "  n: Int\n" +
        "}\n" +
        "impl BIfc for Widget {\n" +
        "  func value(): Int {\n" +
        "    self.n + 2\n" +
        "  }\n" +
        "}\n" +
        "pub func run(): Int {\n" +
        "  Widget(n = 10).value()\n" +
        "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj7.App",
      path = "",
      source = "package Proj7.App\n" + "import Proj7.A\n" + "import Proj7.B\n" + "func main(): Int {\n" +
        "  Proj7.A.run() + Proj7.B.run()\n" +
        "}\n"
    )
  )
  val outcome = compileAndRunProject(pkgs)
  assertEqualInt(
    outcome.exitCode,
    23,
    "10+1 (Proj7.A.Widget.value()) + 10+2 (Proj7.B.Widget.value()) = 23 -- no cross-package aliasing"
  )
}
