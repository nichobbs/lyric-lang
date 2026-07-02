//! modechecker_self_test.l — exercises the self-hosted Lyric.ModeChecker library.
//! Run in CI via native `lyric test` (no F# runner shim).
//!
@test_module
package Lyric.ModeCheckerSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func parseCheck(src: in String): ModeCheckResult {
  val pr = parse(src)
  checkFile(pr.file)
}

func hasDiagCode(result: in ModeCheckResult, code: in String): Bool {
  var i = 0
  while i < result.diagnostics.count {
    if result.diagnostics[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

func diagCount(result: in ModeCheckResult): Int {
  result.diagnostics.count
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "runtime checked default" {
  val result = parseCheck("package P\nfunc f(): Int { 1 }\n")
  match result.level {
    case VLRuntimeChecked -> {
    }
    case _ -> {
      assertTrue(false, "default-level: expected VLRuntimeChecked")
    }
  }
  assertEqualInt(diagCount(result), 0, "default-level: no diagnostics")
}

test "explicit runtime checked" {
  val result = parseCheck("@runtime_checked\npackage P\nfunc f(): Int { 1 }\n")
  match result.level {
    case VLRuntimeChecked -> {
    }
    case _ -> {
      assertTrue(false, "explicit-rc: expected VLRuntimeChecked")
    }
  }
  assertEqualInt(diagCount(result), 0, "explicit-rc: no diagnostics")
}

test "proof required" {
  val result = parseCheck("@proof_required\npackage P\nfunc f(): Int { 1 }\n")
  match result.level {
    case VLProofRequired -> {
    }
    case _ -> {
      assertTrue(false, "proof-req: expected VLProofRequired")
    }
  }
  assertEqualInt(diagCount(result), 0, "proof-req: no diagnostics")
}

test "proof required unsafe" {
  val result = parseCheck("@proof_required(unsafe_blocks_allowed)\npackage P\nfunc f(): Unit {}\n")
  match result.level {
    case VLProofRequiredUnsafe -> {
    }
    case _ -> {
      assertTrue(false, "pr-unsafe: expected VLProofRequiredUnsafe")
    }
  }
  assertEqualInt(diagCount(result), 0, "pr-unsafe: no diagnostics")
}

test "axiom level" {
  val result = parseCheck("@axiom\npackage P\nfunc f(): Int\n")
  match result.level {
    case VLAxiom -> {
    }
    case _ -> {
      assertTrue(false, "axiom-level: expected VLAxiom")
    }
  }
  assertEqualInt(diagCount(result), 0, "axiom-level: no diagnostics")
}

test "conflicting annotations" {
  val result = parseCheck("@runtime_checked\n@axiom\npackage P\nfunc f(): Int { 1 }\n")
  assertTrue(hasDiagCode(result, "V0010"), "conflict: V0010 emitted")
}

test "unknown modifier" {
  val result = parseCheck("@proof_required(badmod)\npackage P\nfunc f(): Int { 1 }\n")
  assertTrue(hasDiagCode(result, "V0011"), "unknown-mod: V0011 emitted")
}

test "pure callee passing" {
  // @pure callee is admissible from proof-required code.
  val src = "@proof_required\npackage P\n@pure\nfunc helper(): Int { 42 }\nfunc f(): Int { helper() }\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "pure-callee: no diagnostics")
}

test "impure callee v0002" {
  // Calling a runtime-checked function from proof-required → V0002.
  // In the self-hosted checker, a function without @pure in a @proof_required
  // file inherits proof-required level, so a callee imported from a
  // runtime-checked package would produce V0002.  We simulate this by using
  // checkFileWithImports with a runtime-checked import.
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Ext.Lib", level = "runtime_checked"))
  val pr = parse("@proof_required\npackage P\nimport Ext.Lib\nfunc f(): Unit {}\n")
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(hasDiagCode(result, "V0001"), "impure-callee: V0001 emitted")
}

test "await v0002" {
  val src = "@proof_required\npackage P\nfunc f(): Unit { await someAsync() }\nfunc someAsync(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0002"), "await: V0002 emitted")
}

test "unsafe block v0003" {
  val src = "@proof_required\npackage P\nfunc f(): Unit { unsafe { } }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0003"), "unsafe: V0003 emitted")
}

test "unsafe allowed no error" {
  val src = "@proof_required(unsafe_blocks_allowed)\npackage P\nfunc f(): Unit { unsafe { } }\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "unsafe-allowed: no diagnostics")
}

test "axiom with body v0004" {
  val src = "@proof_required\npackage P\n@axiom\nfunc assume(p: in Bool): Unit { p }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0004"), "axiom-body: V0004 emitted")
}

test "axiom no body ok" {
  val src = "@proof_required\npackage P\n@axiom\nfunc assume(p: in Bool): Unit\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "axiom-no-body: no diagnostics")
}

test "loop without invariant v0005" {
  val src = "@proof_required\npackage P\nfunc f(): Unit {\n  var i = 0\n  while i < 10 { i = i + 1 }\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0005"), "loop-no-inv: V0005 emitted")
}

test "unbounded quantifier v0006" {
  // forall with Int binder in a requires: clause — unbounded domain.
  val src = "@proof_required\npackage P\nfunc f(): Bool\n  requires: forall (n: Int) { n >= 0 }\n{ true }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0006"), "unbounded-q: V0006 emitted")
}

test "runtime checked no checks" {
  // @runtime_checked packages skip all proof-mode checks.
  val src = "@runtime_checked\npackage P\nfunc f(): Unit {\n  var i = 0\n  while i < 10 { i = i + 1 }\n}\n"
  val result = parseCheck(src)
  assertEqualInt(diagCount(result), 0, "rc-no-checks: no diagnostics")
}

test "cross package call v0002" {
  // A proof-required function calling a function from a runtime_checked
  // package via a multi-segment path (e.g. Ext.Lib.someFunc()) must trigger
  // V0002 at the call site, in addition to V0001 at the import.
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Ext.Lib", level = "runtime_checked"))
  val src = "@proof_required\npackage P\nimport Ext.Lib\nfunc f(): Unit { Ext.Lib.someFunc() }\n"
  val pr = parse(src)
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(hasDiagCode(result, "V0002"), "cross-pkg: V0002 emitted for cross-package call")
}

test "cross package call proof ok" {
  // Calling into a proof_required package from proof_required is fine.
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Safe.Lib", level = "proof_required"))
  val src = "@proof_required\npackage P\nimport Safe.Lib\nfunc f(): Unit { Safe.Lib.helper() }\n"
  val pr = parse(src)
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(not (hasDiagCode(result, "V0002")), "cross-pkg-ok: V0002 not emitted for proof_required callee")
}

test "cross package single segment v0002" {
  // Covers the EPath-receiver branch (single-segment package name).
  val imports: List[ImportedMeta] = newList()
  imports.add(ImportedMeta(name = "Pkg", level = "runtime_checked"))
  val src = "@proof_required\npackage P\nimport Pkg\nfunc f(): Unit { Pkg.someFunc() }\n"
  val pr = parse(src)
  val result = checkFileWithImports(pr.file, imports)
  assertTrue(
    hasDiagCode(result, "V0002"),
    "single-seg-pkg: V0002 emitted for single-segment runtime_checked package call"
  )
}

test "await in try v0012" {
  // await inside a try block in a proof_required async func must emit V0012;
  // the CLR verifier rejects AwaitUnsafeOnCompleted inside a protected region,
  // and the self-hosted Phase B.1 emitter cannot hoist awaits out of try bodies.
  val src = "@proof_required\npackage P\nasync func f(): Unit {\n  try {\n    await someTask()\n  } catch (e: Exception) {\n  }\n}\nfunc someTask(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0012"), "await-in-try: V0012 emitted")
}

test "await in finally v0012" {
  val src = "@proof_required\npackage P\nasync func f(): Unit {\n  try {\n    doSomething()\n  } finally {\n    await cleanup()\n  }\n}\nfunc doSomething(): Unit {}\nfunc cleanup(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0012"), "await-in-finally: V0012 emitted")
}

test "await outside try no v0012" {
  // await outside a try block is fine even in proof_required — no V0012.
  val src = "@proof_required\npackage P\nasync func f(): Unit {\n  await someTask()\n  try {\n    doSomething()\n  } catch (e: Exception) {\n  }\n}\nfunc someTask(): Unit {}\nfunc doSomething(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0012")), "await-before-try: no V0012")
}

test "await in try non-async no v0012" {
  // Non-async functions don't emit V0012 even if they contain await-like text
  // (the parser won't produce EAwait in a non-async func, but the walker must
  // skip non-async funcs regardless).
  val src = "@proof_required\npackage P\nfunc f(): Unit {\n  try {\n    doSomething()\n  } catch (e: Exception) {\n  }\n}\nfunc doSomething(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0012")), "non-async-try: no V0012")
}

test "await in try runtime checked v0012" {
  // V0012 now covers @runtime_checked packages (issue #2985 resolved): the CLR
  // constraint applies regardless of verification level.  Stdlib callsites in
  // Std.Http were restructured to hoist awaits before try blocks; the
  // vlIsProofRequired guard was replaced with a VLAxiom-only exclusion (kernel
  // files compile through the F# emitter which can hoist, so they are exempt).
  val src = "@runtime_checked\npackage P\nasync func f(): Unit {\n  try {\n    await someTask()\n  } catch (e: Exception) {\n  }\n}\nfunc someTask(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0012"), "rc-await-in-try: V0012 emitted for @runtime_checked")
}

test "await in lambda inside try no v0012" {
  // A lambda defined inside a try block has its own independent state; the
  // await in its body must NOT be flagged as V0012 for the outer function.
  // Uses Lyric zero-param lambda syntax `{ -> body }`.
  val src = "@proof_required\npackage P\nasync func f(): Unit {\n  try {\n    val lam = { -> await someTask() }\n  } catch (e: Exception) {\n  }\n}\nfunc someTask(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0012")), "lambda-await-in-outer-try: no V0012")
}

test "await in try inside record method v0012" {
  // V0012 must fire for async methods defined inside a record in a
  // @proof_required package, not just top-level functions.
  val src = "@proof_required\npackage P\nrecord R {\n  async func doWork(): Unit {\n    try {\n      await someTask()\n    } catch (e: Exception) {\n    }\n  }\n}\nfunc someTask(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0012"), "record-method-await-in-try: V0012 emitted")
}

test "await in try inside interface default method v0012" {
  // V0012 must fire for an async default method (IMFunc — a method body on the
  // interface itself, not a bare signature) in a @proof_required package.
  val src = "@proof_required\npackage P\ninterface Svc {\n  async func doWork(): Unit {\n    try {\n      await someTask()\n    } catch (e: Exception) {\n    }\n  }\n}\nfunc someTask(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0012"), "interface-method-await-in-try: V0012 emitted")
}

test "await in try inside impl method v0012" {
  // V0012 must fire for an async method defined in an impl block (IMplFunc) in a
  // @proof_required package.
  val src = "@proof_required\npackage P\ninterface Svc {\n  async func doWork(): Unit\n}\nrecord R {\n}\nimpl Svc for R {\n  async func doWork(): Unit {\n    try {\n      await someTask()\n    } catch (e: Exception) {\n    }\n  }\n}\nfunc someTask(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0012"), "impl-method-await-in-try: V0012 emitted")
}

test "await in try axiom no v0012" {
  // @axiom packages are exempt from V0012 — the guard changed from
  // `not vlIsProofRequired` to `vlIsAxiom` in #3113, making @axiom the sole
  // exemption.  An @axiom package with await inside a try block must NOT
  // emit V0012; the F# bootstrap emitter can hoist awaits for kernel files.
  val src = "@axiom\npackage P\nasync func f(): Unit {\n  try {\n    await someTask()\n  } catch (e: Exception) {\n  }\n}\nfunc someTask(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0012")), "axiom-await-in-try: @axiom is exempt from V0012")
}

// ─────────────────────────────────────────────────────────────────────────────
// N0100 — native FFI boundary (NativePtr[T] / nativeAddrOf placement).
// ─────────────────────────────────────────────────────────────────────────────
test "n0100 nativeptr param outside unsafe_ffi" {
  val src = "package P\nfunc f(p: NativePtr[Byte]): Int { 1 }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativeptr-param: N0100 emitted")
}

test "n0100 nativeptr return outside unsafe_ffi" {
  val src = "package P\nfunc f(): NativePtr[Byte] { g() }\nfunc g(): NativePtr[Byte] { g() }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativeptr-return: N0100 emitted")
}

test "n0100 nativeptr local annotation outside unsafe_ffi" {
  val src = "package P\nfunc f(): Int {\n  var p: NativePtr[Byte] = g()\n  1\n}\nfunc g(): NativePtr[Byte] { g() }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativeptr-local: N0100 emitted")
}

test "n0100 nativeaddrof outside unsafe_ffi" {
  val src = "package P\nfunc f(): Int {\n  var b = 0\n  val r = w(nativeAddrOf(b), 1)\n  r\n}\nfunc w(p: Int, n: Int): Int { n }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativeaddrof-placement: N0100 emitted")
}

test "n0100 unsafe_ffi function is admitted" {
  val src = "package P\nextern func w(buf: NativePtr[Byte], n: Long): Long = \"write\"\n@unsafe_ffi\nfunc f(): Long {\n  var b = 0\n  w(nativeAddrOf(b), 1)\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "N0100")), "unsafe-ffi-positive: no N0100")
}

test "n0100 extern func params exempt" {
  val src = "package P\nextern func w(buf: NativePtr[Byte], n: Long): Long = \"write\"\nextern func m(n: Long): NativePtr[Byte] = \"malloc\"\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "N0100")), "extern-exempt: no N0100")
}

test "n0100 nativeaddrof operand must be var local" {
  val src = "package P\n@unsafe_ffi\nfunc f(): Int {\n  val b = 0\n  val r = w(nativeAddrOf(b), 1)\n  r\n}\nfunc w(p: Int, n: Int): Int { n }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativeaddrof-val-operand: N0100 emitted")
}

test "n0100 nativeaddrof must not be returned" {
  val src = "package P\n@unsafe_ffi\nfunc f(): NativePtr[Byte] {\n  var b = 0.toByte()\n  return nativeAddrOf(b)\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativeaddrof-return-escape: N0100 emitted")
}

test "n0100 nativeaddrof trailing value escape" {
  val src = "package P\n@unsafe_ffi\nfunc f(): NativePtr[Byte] {\n  var b = 0.toByte()\n  nativeAddrOf(b)\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativeaddrof-tail-escape: N0100 emitted")
}

test "n0100 record field nativeptr rejected" {
  val src = "package P\nrecord Holder {\n  p: NativePtr[Byte]\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "record-field: N0100 emitted")
}

test "n0100 union payload nativeptr rejected" {
  val src = "package P\nunion U {\n  case Raw(p: NativePtr[Byte])\n  case Empty\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "union-payload: N0100 emitted")
}

test "n0100 clean file no diagnostics" {
  val src = "package P\nfunc f(x: Int): Int { x + 1 }\nrecord R {\n  n: Int\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "N0100")), "clean: no N0100")
}


test "n0100 nativenullptr outside unsafe_ffi" {
  val src = "package P\nfunc f(): Int {\n  val p = g(nativeNullPtr())\n  p\n}\nfunc g(x: Int): Int { x }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "nativenullptr-placement: N0100 emitted")
}

test "n0100 nativenullptr inside unsafe_ffi admitted" {
  val src = "package P\nextern func cFree(p: NativePtr[Byte]): Unit = \"free\"\n@unsafe_ffi\nfunc f(): Int {\n  cFree(nativeNullPtr())\n  0\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "N0100")), "nativenullptr-positive: no N0100")
}
