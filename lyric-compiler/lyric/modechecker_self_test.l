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

// ── V0014: a spawned task must be consumed (D119) ─────────────────────────────
test "non-trailing bare spawn outside scope is V0014" {
  val src = "package P\nasync func f(): Unit {\n  spawn g()\n  val done = 1\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "dropped spawn: V0014 emitted")
}

test "trailing spawn in value position is not V0014" {
  // #5141: the trailing statement is the block's value (the return value here),
  // so a trailing spawn is returned, not discarded — must not be flagged.
  val src = "package P\nasync func f(): Int {\n  val a = 1\n  spawn g()\n}\nasync func g(): Int { 1 }\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "trailing spawn (return value): no V0014")
}

test "spawn bound and awaited is not V0014" {
  val src = "package P\nasync func f(): Int {\n  val t = spawn g()\n  await t\n}\nasync func g(): Int { 1 }\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "spawn bound + awaited: no V0014")
}

test "await spawn is not V0014" {
  val src = "package P\nasync func f(): Int {\n  await spawn g()\n}\nasync func g(): Int { 1 }\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "await spawn: no V0014")
}

test "non-trailing bare spawn inside scope is not V0014" {
  val src = "package P\nasync func f(): Unit {\n  scope {\n    spawn g()\n    val done = 1\n  }\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "spawn inside scope: no V0014 (scope joins it)")
}

test "non-trailing dropped spawn inside a lambda is V0014" {
  val src = "package P\nasync func f(): Unit {\n  val h = { x: Int -> spawn g()\n    x\n  }\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "dropped spawn in lambda: V0014 (lambda may outlive scope)")
}

test "discarded spawn in an impl method is V0014" {
  // #5143: impl-method bodies must be checked too.
  val src = "package P\ninterface Svc {\n  func run(): Unit\n}\nrecord R {}\nimpl Svc for R {\n  func run(): Unit {\n    spawn g()\n    val done = 1\n  }\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "dropped spawn in impl method: V0014")
}

test "trailing spawn in a loop body is V0014" {
  // #5145: a loop body's trailing value is discarded, so a trailing spawn there
  // is fire-and-forget even though it is the block's last statement.
  val src = "package P\nasync func f(): Unit {\n  while true {\n    spawn g()\n  }\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "trailing spawn in loop body: V0014")
}

test "spawn in a non-trailing if branch is V0014" {
  // #5145: the `if` is a non-trailing statement, so its branch value is
  // discarded — a spawn ending the branch is fire-and-forget.
  val src = "package P\nasync func f(): Unit {\n  if true {\n    spawn g()\n  }\n  val done = 1\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "spawn in non-trailing if branch: V0014")
}

test "spawn in a value-position if branch is not V0014" {
  // The `if` is the function's trailing (return) value, so a branch-ending spawn
  // is returned, not discarded.
  val src = "package P\nasync func f(): Int {\n  if true { spawn g() } else { spawn h() }\n}\nasync func g(): Int { 1 }\nasync func h(): Int { 2 }\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "spawn in value-position if branch: no V0014")
}

test "discarded spawn in a protected entry is V0014" {
  // #5143: protected-type entry/func bodies must be checked too.
  val src = "package P\nprotected type Pt {\n  var n: Int = 0\n  entry go(): Unit {\n    spawn g()\n    n = 1\n  }\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "dropped spawn in protected entry: V0014")
}

test "spawn in a value-position try/catch is not V0014" {
  // #5148: a trailing try/catch is the block's value (the return value here),
  // so a spawn ending the try or a catch handler is returned, not discarded.
  val src = "package P\nasync func f(): Int {\n  try {\n    spawn g()\n  } catch Bug as _ {\n    spawn h()\n  }\n}\nasync func g(): Int { 1 }\nasync func h(): Int { 2 }\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "spawn in value-position try/catch: no V0014")
}

test "trailing spawn in a non-value try body is V0014" {
  // #5148 (converse): a non-trailing try statement discards its value, so a
  // trailing spawn in its body is fire-and-forget.
  val src = "package P\nasync func f(): Unit {\n  try {\n    spawn g()\n  } catch Bug as _ {\n  }\n  val done = 1\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "trailing spawn in non-value try body: V0014")
}

// #5164: EMatch arms share the same walkExprOrBlockForSpawn(ctx, valuePos,
// arms[i].body) call as EIf branches — mirror the if-branch tests above for
// a match arm. Block-bodied arms (`case _ -> { ... }`) mirror the if-branch
// tests' shape exactly: `if` branches are always block-bodied, and only the
// `EOBBlock` arm of `walkExprOrBlockForSpawn` reaches the statement-level
// V0014 check (a bare-expression arm body, `case _ -> spawn g()`, is an
// `EOBExpr` and never reaches that check at all — see "spawn in a
// non-trailing bare-expression match arm" below for that separate gap).
test "spawn in a non-trailing match arm is V0014" {
  val src = "package P\nasync func f(): Unit {\n  match 1 {\n    case _ -> { spawn g() }\n  }\n  val done = 1\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "spawn in non-trailing match arm: V0014")
}

test "spawn in a value-position match arm is not V0014" {
  val src = "package P\nasync func f(): Int {\n  match 1 {\n    case _ -> { spawn g() }\n  }\n}\nasync func g(): Int { 1 }\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "spawn in value-position match arm: no V0014")
}

// #5164 (bonus finding, not in the original issue list): a BARE-EXPRESSION
// match arm body (`case _ -> spawn g()`, an `EOBExpr`, as opposed to the
// block-bodied `case _ -> { spawn g() }` above) is a genuinely different
// code path — `walkExprOrBlockForSpawn`'s `EOBExpr` arm calls
// `walkExprForSpawn` directly, whose `ESpawn` case never emits V0014 itself
// (only `walkStmtForSpawn`'s `SExpr` case does, which is only reached via
// `EOBBlock` -> `walkBlockForSpawn` -> `walkStmtForSpawn`). A discarded
// bare-expression match arm's `spawn` is therefore NEVER flagged, regardless
// of value position — asymmetric with the block-bodied arm just above.
// Recorded here as a known gap rather than asserted as a bug (the assertion
// below documents current, not necessarily intended, behavior).
test "spawn in a non-trailing bare-expression match arm is currently NOT flagged (known gap)" {
  val src = "package P\nasync func f(): Unit {\n  match 1 {\n    case _ -> spawn g()\n  }\n  val done = 1\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertFalse(
    hasDiagCode(result, "V0014"),
    "bare-expression match arm spawn is discarded but NOT flagged V0014 (walkExprForSpawn's ESpawn case never emits)"
  )
}

// #5164: `finally_` is always walked with valuePos = false, regardless of
// whether the enclosing try/catch is itself in value position.
test "trailing spawn in a finally block is V0014" {
  val src = "package P\nasync func f(): Int {\n  try {\n    1\n  } finally {\n    spawn g()\n  }\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "trailing spawn in finally block: V0014")
}

// #5164: SAssign walks its RHS with valuePos = true, matching the val/var
// binding-initialiser rule — reassigning an existing var to a spawn's
// handle consumes it, a distinct code path from the LBVar declaration-
// initialiser case already covered by "spawn bound and awaited is not V0014".
test "plain assignment of spawn to an existing var is not V0014" {
  val src = "package P\nasync func f(): Int {\n  var x = spawn g()\n  x = spawn g()\n  await x\n}\nasync func g(): Int { 1 }\n"
  val result = parseCheck(src)
  assertFalse(hasDiagCode(result, "V0014"), "x = spawn g() (SAssign): no V0014")
}

test "discarded spawn in an aspect around body is V0014" {
  // #5158: aspect `around` advice is spliced into real functions during weaving
  // (after mode checking), so a fire-and-forget spawn there must be caught here.
  val src = "package P\naspect A {\n  matches: name like \"f*\"\n  around(args) -> ret {\n    spawn g()\n    proceed(args)\n  }\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "dropped spawn in aspect around: V0014")
}

test "non-var field write on a var-record local in an aspect around body is V0015 (#6203)" {
  // Same rationale as the V0014 case above: `around` advice is spliced into
  // real functions during weaving (after mode checking), so a field write
  // through a var-record local there must be caught here.  An aspect has no
  // enclosing `self` (it isn't a method on a type), so this exercises the
  // local-EPath receiver form, not the ESelf form #6181 added.
  val src = "package P\nrecord Counter {\n  total: Int\n}\naspect A {\n  matches: name like \"f*\"\n  around(args) -> ret {\n    var c = Counter(total = 0)\n    c.total = 1\n    proceed(args)\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "non-var field write in aspect around body: V0015 emitted")
}

test "discarded spawn in a test body is V0014" {
  // #5159: `test { }` bodies are executed code and their value is discarded.
  val src = "package P\ntest \"t\" {\n  spawn g()\n  val done = 1\n}\nasync func g(): Unit {}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0014"), "dropped spawn in test body: V0014")
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

test "n0100 nativeaddrof of a capture inside a lambda rejected" {
  // An enclosing function's var reaches a lambda as a by-value capture
  // (a closure heap field), not a stack slot (#4734).
  val src = "package P\n@unsafe_ffi\nfunc f(): Int {\n  var b = 0\n  val g: () -> Int = { -> w(nativeAddrOf(b), 1) }\n  g()\n}\nfunc w(p: Int, n: Int): Int { n }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "lambda-capture-addrof: N0100 emitted")
}

test "n0100 lambda-local var does not admit outer nativeaddrof" {
  val src = "package P\n@unsafe_ffi\nfunc f(): Int {\n  val g: () -> Int = { ->\n    var inner = 0\n    inner\n  }\n  val r = w(nativeAddrOf(inner), 1)\n  r\n}\nfunc w(p: Int, n: Int): Int { n }\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "N0100"), "outer-addrof-of-lambda-var: N0100 emitted")
}

test "n0100 lambda-local var admits nativeaddrof inside its own lambda" {
  val src = "package P\n@unsafe_ffi\nfunc f(): Int {\n  val g: () -> Int = { ->\n    var inner = 0\n    w(nativeAddrOf(inner), 1)\n  }\n  g()\n}\nfunc w(p: Int, n: Int): Int { n }\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "N0100")), "lambda-own-var: no N0100")
}

// ── V0015: write to a non-`var` record field (#1815 part 1) ────────────────────
test "var field reassigned through a var local compiles" {
  val src = "package P\nrecord Counter {\n  var count: Int\n  label: String\n}\nfunc f(): Int {\n  var c = Counter(count = 0, label = \"x\")\n  c.count = c.count + 1\n  c.count\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "var-field-write: no V0015")
}

test "non-var field reassigned through a var local is V0015" {
  val src = "package P\nrecord Counter {\n  var count: Int\n  label: String\n}\nfunc f(): String {\n  var c = Counter(count = 0, label = \"x\")\n  c.label = \"y\"\n  c.label\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "nonvar-field-write: V0015 emitted")
}

test "non-var field reassigned through a compound assignment is V0015" {
  val src = "package P\nrecord Box {\n  n: Int\n}\nfunc f(): Int {\n  var b = Box(n = 0)\n  b.n += 1\n  b.n\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "nonvar-field-compound-assign: V0015 emitted")
}

test "record construction is not V0015" {
  val src = "package P\nrecord Point {\n  x: Int\n  y: Int\n}\nfunc f(): Point {\n  Point(x = 1, y = 2)\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "construction: no V0015")
}

test "non-var field write through an inout param is V0015 (#1815 part 2 / #6155)" {
  // Part 1 (D-progress-706) deliberately left `inout` params untracked to
  // avoid flagging Std.Xml's cursor-state idiom (XmlState.pos mutated via
  // `st: inout XmlState` helpers). Part 2 widens tracking to `inout` params
  // under the SAME var/non-var rule locals already get: a genuinely non-`var`
  // field write through an `inout` alias is exactly the #1815 bug class, and
  // is now flagged. Making `pos` itself `var` (as Std.Xml's real `XmlState`
  // now is) is what keeps the legitimate idiom compiling — see the next case.
  val src = "package P\nrecord Cursor {\n  pos: Int\n}\nfunc advance(c: inout Cursor): Unit {\n  c.pos = c.pos + 1\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "inout-param-nonvar-write: V0015 emitted")
}

test "var field write through an inout param is not V0015 (#1815 part 2 / #6155)" {
  // The cursor-idiom shape that must keep compiling once `inout` params are
  // tracked: `pos` is `var`, so the same write through the same `inout` alias
  // is allowed. Mirrors Std.Xml.XmlState/Std.Yaml.YamlState/
  // Std.HttpEngine.Connection's real shape after the D-progress-706 follow-up.
  val src = "package P\nrecord Cursor {\n  var pos: Int\n}\nfunc advance(c: inout Cursor): Unit {\n  c.pos = c.pos + 1\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "inout-param-var-write: no V0015")
}

test "non-var field write through an inout param is V0015 through a compound assignment (#6155)" {
  val src = "package P\nrecord Cursor {\n  pos: Int\n}\nfunc advance(c: inout Cursor): Unit {\n  c.pos += 1\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "inout-param-nonvar-compound-assign: V0015 emitted")
}

test "an `in`-mode param's field write is not tracked (only `inout` is, #6155)" {
  // `in` params are never write-capable bindings, regardless of the target
  // field's mutability — only `var` locals and `inout` params are tracked.
  val src = "package P\nrecord Cursor {\n  var pos: Int\n}\nfunc peek(c: in Cursor): Unit {\n  c.pos = c.pos + 1\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "in-param-write: not tracked, no V0015")
}

test "non-var field write through an inout param of an imported (not same-file) record type is not tracked (#6155)" {
  // `checkFieldMutability` only ever fires for names resolved into
  // `ctx.recordFields`, which is built from records declared in *this* file
  // (`collectRecordFieldsOfFile`) — an `inout` param typed at an unresolved
  // (here: simply undeclared-in-file) record name is never seeded as a
  // write-capable binding, mirroring the existing `var`-local behavior.
  val src = "package P\nfunc advance(c: inout OtherPkgCursor): Unit {\n  c.pos = c.pos + 1\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "inout-param-unresolved-type: not tracked, no V0015")
}

test "non-var field write through a val binding is not tracked (pre-existing gap)" {
  val src = "package P\nrecord Box {\n  n: Int\n}\nfunc f(): Int {\n  val b = Box(n = 0)\n  b.n = 1\n  b.n\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "val-binding-write: no V0015 (not tracked; see docs)")
}

test "same-named var record locals in sibling scopes do not crash the pass (#6157)" {
  // `ctx.locals` is a single flat map with no scope push/pop, so both `b`
  // bindings reach `fieldWriteTrackLocal` with the same key; the unguarded
  // `Map.add` threw on the duplicate, crashing the mode checker on ordinary
  // valid source.  `n` is `var`, so no V0015 should fire either.
  val src = "package P\nrecord Box {\n  var n: Int\n}\nfunc f(cond: Bool): Int {\n  if cond {\n    var b = Box(n = 1)\n    b.n = 2\n    b.n\n  } else {\n    var b = Box(n = 3)\n    b.n = 4\n    b.n\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "sibling-same-name var locals: no crash, no V0015")
}

test "same-named var record locals in sequential blocks do not crash (#6157)" {
  val src = "package P\nrecord Box {\n  var n: Int\n}\nfunc f(): Int {\n  var acc = 0\n  {\n    var b = Box(n = 1)\n    b.n = 2\n    acc = acc + b.n\n  }\n  {\n    var b = Box(n = 3)\n    b.n = 4\n    acc = acc + b.n\n  }\n  acc\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "sequential same-name var locals: no crash, no V0015")
}

test "shadowed var local of a different record type does not leak its type past its scope (#6166 false positive)" {
  // Outer `box` is `Mut` (n is `var`); a nested block shadows `box` as `Other`
  // (n is NON-var).  After the block ends, `box.n = 2` writes the outer `Mut`
  // local, whose `n` IS `var` — so no V0015.  Before the scope-undo fix the
  // inner `Other` binding leaked, and the write was checked against
  // `Other.n` (non-var) → a false-positive V0015 on valid code.
  val src = "package P\nrecord Mut {\n  var n: Int\n}\nrecord Other {\n  n: Int\n}\nfunc f(cond: Bool): Int {\n  var box = Mut(n = 1)\n  if cond {\n    var box = Other(n = 9)\n    box.n\n  } else {\n    0\n  }\n  box.n = 2\n  box.n\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "outer Mut.n (var) write after shadow: no V0015")
}

test "shadowed var local of a different record type still catches the outer violation (#6166 false negative)" {
  // Mirror image: outer `b` is `Immut` (label is NON-var); a nested block
  // shadows `b` as `MutBox` (label is `var`).  After the block ends,
  // `b.label = \"d\"` writes the outer `Immut` local's non-var field and MUST
  // fire V0015.  Before the fix the leaked `MutBox` binding hid it (false
  // negative).
  val src = "package P\nrecord Immut {\n  label: String\n}\nrecord MutBox {\n  var label: String\n}\nfunc g(cond: Bool): String {\n  var b = Immut(label = \"a\")\n  if cond {\n    var b = MutBox(label = \"b\")\n    b.label = \"c\"\n    b.label\n  } else {\n    \"z\"\n  }\n  b.label = \"d\"\n  b.label\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "outer Immut.label (non-var) write after shadow: V0015 fires")
}

test "same-block re-declaration to a non-in-file-record type evicts the stale mapping (#6167)" {
  // `b` starts as `Frozen` (n non-var), then is re-declared IN THE SAME BLOCK
  // from `mkMut()` — a plain call, not a constructor, so its type doesn't
  // resolve to an in-file record.  The subsequent `b.n = 3` writes the new
  // `Mut` binding (n IS var) and must not fire V0015.  Before the eviction
  // fix, the stale `b -> Frozen` (n non-var) mapping stayed and the write was
  // rejected as a false positive.  #6166's block snapshot/restore does not
  // cover this — the re-declaration is inside a single flat block.
  val src = "package P\nrecord Frozen {\n  n: Int\n}\nrecord Mut {\n  var n: Int\n}\nfunc mkMut(): Mut {\n  Mut(n = 0)\n}\nfunc f(): Int {\n  var b = Frozen(n = 1)\n  var b = mkMut()\n  b.n = 3\n  b.n\n}\n"
  val result = parseCheck(src)
  assertTrue(
    not (hasDiagCode(result, "V0015")),
    "re-declared b (via non-ctor call) write: stale Frozen evicted, no V0015"
  )
}

test "val binding shadowing a var-record local evicts the stale mapping (#6185)" {
  // Outer `b` is `Immut` (label non-var); a nested block re-binds `b` via a
  // `val` to `MutBox` (label IS var) and writes `b.label`.  The write is on the
  // val binding, which we don't track — so no V0015.  Before the #6185 fix the
  // `val` arm never evicted, so `b.label` was checked against the outer
  // `Immut.label` (non-var) → a false positive.
  val src = "package P\nrecord Immut {\n  label: String\n}\nrecord MutBox {\n  var label: String\n}\nfunc f(): String {\n  var b = Immut(label = \"a\")\n  {\n    val b = MutBox(label = \"x\")\n    b.label = \"y\"\n    b.label\n  }\n  b.label\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "val-shadow write: no false-positive V0015")
}

test "match-arm pattern bind shadowing a var-record local evicts the stale mapping (#6185)" {
  // The arm pattern `W(b)` binds `b` to `MutBox` inside the arm; a write to
  // `b.label` (var) there must not be checked against the outer `Immut` local
  // of the same name.  Before #6185 the arm never evicted the pattern binder.
  val src = "package P\nrecord Immut {\n  label: String\n}\nrecord MutBox {\n  var label: String\n}\nunion Wrap {\n  case W(inner: MutBox)\n}\nfunc g(w: in Wrap): String {\n  var b = Immut(label = \"a\")\n  match w {\n    case W(b) -> {\n      b.label = \"y\"\n      b.label\n    }\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "match-arm-shadow write: no false-positive V0015")
}

test "lambda parameter shadowing a var-record local evicts the stale mapping (#6185)" {
  // The lambda param `b: MutBox` shadows the outer `Immut` local inside the
  // lambda body; the `b.label` (var) write there must not be checked against
  // `Immut.label`.  Before #6185 lambda params never evicted.
  val src = "package P\nrecord Immut {\n  label: String\n}\nrecord MutBox {\n  var label: String\n}\nfunc h(): String {\n  var b = Immut(label = \"a\")\n  val g = { b: MutBox -> b.label = \"y\"\n    b.label\n  }\n  b.label\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "lambda-param-shadow write: no false-positive V0015")
}

test "for-loop variable shadowing a var-record local evicts the stale mapping (#6185)" {
  // The loop variable `b` shadows the outer `Immut` local inside the body; the
  // `b.label` (var) write must not be checked against `Immut.label`.  Before
  // #6185 the for-loop variable never evicted.
  val src = "package P\nrecord Immut {\n  label: String\n}\nrecord MutBox {\n  var label: String\n}\nfunc k(items: in List[MutBox]): Int {\n  var b = Immut(label = \"a\")\n  for b in items {\n    b.label = \"y\"\n  }\n  0\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "for-var-shadow write: no false-positive V0015")
}

test "restore after a non-var-binder shadow still catches the outer violation (#6185 false negative)" {
  // A `val`-shadow of `b` in a nested block must be scoped: after the block,
  // the outer `Immut` binding is restored, so the outer `b.label = \"z\"` write
  // to the non-var field MUST still fire V0015.  Guards against the eviction
  // leaking past its scope (the false-negative dual of the four cases above).
  val src = "package P\nrecord Immut {\n  label: String\n}\nrecord MutBox {\n  var label: String\n}\nfunc fn(): String {\n  var b = Immut(label = \"a\")\n  {\n    val b = MutBox(label = \"x\")\n    b.label = \"ok\"\n  }\n  b.label = \"z\"\n  b.label\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "outer Immut.label write after val-shadow: V0015 still fires")
}

test "catch-clause bind name shadowing a var-record local evicts the stale mapping (#6194)" {
  // `catch Bug as b` binds `b` scoped to the catch body; a `b.label = x` there
  // (on the caught value, not the outer `Immut` local of the same name) must
  // not be checked against `Immut.label`.  Before #6194 the `STry` arm walked
  // the catch body without evicting the catch binder — the last #6185 binder
  // shape.
  val src = "package P\nrecord Immut {\n  label: String\n}\nfunc risky(): Int {\n  1\n}\nfunc g(): String {\n  var b = Immut(label = \"a\")\n  val r = try {\n    risky()\n    \"ok\"\n  } catch Bug as b {\n    b.label = \"z\"\n    \"caught\"\n  }\n  r\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "catch-bind-shadow write: no false-positive V0015")
}

// ── #6203: protected-type entry/func bodies were never visited at all ──────
// `checkImmutableFieldWrites`'s catch-all silently skipped `IProtected` (and
// `IAspect`), so a non-`var` protected-type field write through a `self.field`
// receiver never fired V0015, regardless of #6181's ESelf support below.
test "protected-type entry self-field write to a non-var field is V0015 (#6203)" {
  val src = "package P\nprotected type Pt {\n  var n: Int\n  label: String\n\n  entry poke(): Unit {\n    self.label = \"x\"\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "protected-type entry self.label write: V0015 emitted")
}

test "protected-type entry self-field write to a var field is not V0015" {
  val src = "package P\nprotected type Pt {\n  var n: Int\n\n  entry poke(): Unit {\n    self.n = 5\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "protected-type entry self.n (var) write: no V0015")
}

test "protected-type func member self-field write to a non-var field is V0015 (#6203)" {
  val src = "package P\nprotected type Pt {\n  var n: Int\n  label: String\n\n  func reset(): Unit {\n    self.label = \"x\"\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "protected-type func self.label write: V0015 emitted")
}

// ── #6181: `self.field = …` inside a method was silently ignored ───────────
// `checkFieldWriteTarget` only matched `EMember` over a single-segment
// `EPath` local; an `ESelf` receiver was invisible to the check entirely.
test "impl-method self-field write to a non-var field is V0015 (#6181)" {
  val src = "package P\nrecord Counter2 {\n  total: Int\n}\ninterface Nudge {\n  func poke(): Unit\n}\nimpl Nudge for Counter2 {\n  func poke(): Unit {\n    self.total = 0\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "impl-method self.total write: V0015 emitted")
}

test "impl-method self-field write to a var field is not V0015" {
  val src = "package P\nrecord Counter2 {\n  var total: Int\n}\ninterface Nudge {\n  func poke(): Unit\n}\nimpl Nudge for Counter2 {\n  func poke(): Unit {\n    self.total = 0\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "impl-method self.total (var) write: no V0015")
}

test "record inherent-method self-field write to a non-var field is V0015 (#6181)" {
  val src = "package P\nrecord Counter3 {\n  total: Int\n\n  func reset(self: in Counter3): Unit {\n    self.total = 0\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(hasDiagCode(result, "V0015"), "record inherent-method self.total write: V0015 emitted")
}

// A local variable of the same name as a field must not be confused with the
// implicit-self bare form: this exercises the (still-supported) local-EPath
// branch of `checkFieldWriteTarget`, unaffected by the new `ESelf` arm.
test "local variable shadowing a field name is not affected by the ESelf write check" {
  val src = "package P\nrecord Counter2 {\n  var total: Int\n}\ninterface Nudge {\n  func poke(): Unit\n}\nimpl Nudge for Counter2 {\n  func poke(): Unit {\n    var total = 9\n    total = total + 1\n  }\n}\n"
  val result = parseCheck(src)
  assertTrue(not (hasDiagCode(result, "V0015")), "shadowing local `total` reassignment: no V0015")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6596: whole-build field-write lock-safety audit
// (`computeFieldLockSafetyForBuild`).  V0015 above only resolves same-file
// `var`-local / `self` writes; every other write shape must exclude the
// field NAME from `Msil.Codegen.lowerRecordMsil` / `Jvm.Codegen.lowerRecord`
// locking it `initonly`/`ACC_FINAL`, or an unchecked write compiles into
// invalid/crashing IL — see that function's doc comment for the full
// rationale.  These tests exercise the audit function directly (not V0015's
// diagnostics), covering the four #6596 scenarios plus the two safe cases.
// ─────────────────────────────────────────────────────────────────────────────
func lockSafety(src: in String): Map[String, Bool] {
  val pr = parse(src)
  val files: List[SourceFile] = newList()
  files.add(pr.file)
  val unsafeSet: Map[String, Bool] = newMap()
  computeFieldLockSafetyForBuild(files, unsafeSet)
  unsafeSet
}

func lockSafetyMulti(srcs: in List[String]): Map[String, Bool] {
  val files: List[SourceFile] = newList()
  var i = 0
  while i < srcs.count {
    val pr = parse(srcs[i])
    files.add(pr.file)
    i = i + 1
  }
  val unsafeSet: Map[String, Bool] = newMap()
  computeFieldLockSafetyForBuild(files, unsafeSet)
  unsafeSet
}

test "a field never written anywhere is safe to lock" {
  val src = "package P\nrecord Point {\n  x: Int\n  y: Int\n}\nfunc f(): Point {\n  Point(x = 1, y = 2)\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(not (unsafeSet.containsKey("x")), "never-written x: safe to lock")
  assertTrue(not (unsafeSet.containsKey("y")), "never-written y: safe to lock")
}

test "a field written only through a checked var-local shape is safe to lock" {
  val src = "package P\nrecord Counter {\n  var count: Int\n  label: String\n}\nfunc f(): Int {\n  var c = Counter(count = 0, label = \"x\")\n  c.count = c.count + 1\n  c.count\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(not (unsafeSet.containsKey("count")), "checked var-local write: safe to lock")
  assertTrue(not (unsafeSet.containsKey("label")), "never-written label: safe to lock")
}

test "a field written only through a checked self write is safe to lock" {
  val src = "package P\nrecord Counter2 {\n  var total: Int\n}\ninterface Nudge {\n  func poke(): Unit\n}\nimpl Nudge for Counter2 {\n  func poke(): Unit {\n    self.total = 0\n  }\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(not (unsafeSet.containsKey("total")), "checked self write: safe to lock")
}

// Scenario 1 (#6596): a nested field-access chain write (`c.inner.n = 1`) is
// invisible to V0015's `EMember(EPath, field)`/`EMember(ESelf, field)`
// receiver match — the receiver here is itself an `EMember`.  Before this
// fix, codegen locked `Inner.n` regardless, so this write compiled into a
// field store that violates MSIL `initonly` / JVM `ACC_FINAL` — invalid IL
// CoreCLR tolerates at runtime but the JVM verifier rejects with
// `IllegalAccessError`.
test "nested field-access chain write marks the field unsafe to lock (#6596 scenario 1)" {
  val src = "package P\nrecord Inner {\n  n: Int\n}\nrecord Outer {\n  inner: Inner\n}\nfunc f(c: inout Outer): Unit {\n  c.inner.n = 1\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(unsafeSet.containsKey("n"), "nested-path write to Inner.n: unsafe to lock")
}

// Scenario 2 (#6596): a write through a `val`-bound receiver is a pre-
// existing, documented V0015 gap (see the "non-var field write through a
// val binding is not tracked" test above) — but the lock-safety audit must
// still catch it, or the field gets locked at the IL/bytecode level despite
// the write compiling cleanly.
test "val-bound receiver write marks the field unsafe to lock (#6596 scenario 2)" {
  val src = "package P\nrecord Box {\n  n: Int\n}\nfunc f(): Int {\n  val b = Box(n = 0)\n  b.n = 1\n  b.n\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(unsafeSet.containsKey("n"), "val-bound write to Box.n: unsafe to lock")
}

// Scenario 4 (#6596): a field passed as an `out`/`inout` call argument
// (`bump(c.pos)`) is a write-back target the JVM `writeBackHolderArg` /
// MSIL `emitByrefArgMsil` codegen paths `putfield`/`stfld` into after the
// call, but V0015's `walkExprForFieldWrite` never inspected call arguments
// at all.
test "out/inout call-argument write-back marks the field unsafe to lock (#6596 scenario 4)" {
  val src = "package P\nrecord Cursor {\n  pos: Int\n}\nfunc bump(n: inout Int): Unit {\n  n = n + 1\n}\nfunc f(c: inout Cursor): Unit {\n  bump(c.pos)\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(unsafeSet.containsKey("pos"), "inout call-arg write-back to Cursor.pos: unsafe to lock")
}

// A plain (`in`-mode, the default) call argument is not a write-back target
// — passing a field by value must not poison it.
test "a plain by-value call argument does not mark the field unsafe to lock" {
  val src = "package P\nrecord Cursor {\n  pos: Int\n}\nfunc show(n: Int): Unit {\n}\nfunc f(c: inout Cursor): Unit {\n  show(c.pos)\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(not (unsafeSet.containsKey("pos")), "by-value call-arg read of Cursor.pos: safe to lock")
}

// Scenario 3 (#6596) proxy: a genuinely cross-*package* restored-dependency
// write is outside what any same-invocation static analysis can see (see
// `computeFieldLockSafetyForBuild`'s doc comment) — but a write reaching a
// record from a DIFFERENT file in the SAME build (the common case for an
// actual multi-package `lyric build`/`lyric test` invocation, since the
// self-hosted bridges hand every in-build package's parsed source to this
// audit together) must still be caught.  This is the closest reproduction of
// the "Other is a different package" scenario reachable from a single-file
// self-test.
test "a write reaching a record from a different FILE in the same build marks the field unsafe to lock (#6596 scenario 3 proxy)" {
  val defSrc = "package Other\npub record Cursor {\n  pos: Int\n}\n"
  val useSrc = "package Consumer\nimport Other\nfunc bump(c: inout Other.Cursor): Unit {\n  c.pos = c.pos + 1\n}\n"
  val srcs: List[String] = newList()
  srcs.add(defSrc)
  srcs.add(useSrc)
  val unsafeSet = lockSafetyMulti(srcs)
  assertTrue(unsafeSet.containsKey("pos"), "cross-file write to Other.Cursor.pos: unsafe to lock")
}

// #6641: `walkFileForFieldWriteChecks` (shared by V0015's diagnostic pass and
// this whole-build audit) had no traversal case for `IInterface` — an
// interface DEFAULT method's body (`IMFunc`, distinct from a body-less
// `IMSig` signature) was never walked at all, so an unchecked write inside a
// default method was silently treated as safe to lock even though the
// default body compiles into real, executed code for any implementing
// record.  This uses a `val`-bound-receiver write (the same shape as the
// #6596 scenario 2 test above), not a `self.field` write: the language
// reference (§2.12) rejects `self.<field>` access inside a default method
// body at compile time (T0118, `Self` owns no fields there) — a real
// default-method body can still reach an ordinary record's field through
// any other unchecked shape (a `val`-bound local, a nested chain, an
// `out`/`inout` call argument), exactly the class this audit exists to
// catch.
test "a field written only through a val-bound receiver inside an interface default method marks it unsafe to lock (#6641)" {
  val src = "package P\nrecord Cursor {\n  pos: Int\n}\ninterface Helper {\n  func bump(): Int {\n    val c = Cursor(pos = 0)\n    c.pos = 1\n    c.pos\n  }\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(unsafeSet.containsKey("pos"), "interface default-method val-bound write to Cursor.pos: unsafe to lock")
}

// A body-less interface signature (`IMSig`, no default) carries no code to
// walk at all — must not spuriously mark anything unsafe.
test "an interface with only a body-less signature does not mark any field unsafe to lock (#6641)" {
  val src = "package P\nrecord Cursor2 {\n  pos: Int\n}\ninterface Helper2 {\n  func bump(): Unit\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(not (unsafeSet.containsKey("pos")), "no default body to walk: safe to lock")
}

// #6641: the same walker had no traversal case for `ITest` — a `@test_module`
// file's `test "..." { … }` body, on the file's RAW pre-`Lyric.TestSynth`
// AST, was never walked either. `Lyric.TestSynth.synthesize` always rewrites
// every `ITest` into a real `func __lyric_test_<i>` before the MSIL/JVM
// bridges parse the source `computeFieldLockSafetyForBuild` runs against, so
// an executed test's write is in practice caught by the (pre-existing)
// `IFunc` case post-synthesis — but `checkImmutableFieldWrites`'s V0015 pass
// (and any other caller of the shared walker) sees the RAW `ITest` AST
// directly, where this case was the only thing standing between a
// self-contained regression here and a silent gap in every other consumer of
// this shared traversal.
test "a field written only inside a test block body marks it unsafe to lock (#6641)" {
  val src = "@test_module\npackage P\nrecord Cursor {\n  pos: Int\n}\ntest \"bumps cursor\" {\n  val c = Cursor(pos = 0)\n  c.pos = 1\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(unsafeSet.containsKey("pos"), "test-block-only write to Cursor.pos: unsafe to lock")
}

// #6653: the "#6596 scenario 3 proxy" test above spells the cross-file
// receiver type QUALIFIED (`Other.Cursor`), a 2-segment `TRef` that
// `fieldWriteSimpleTypeName` rejects outright (returns `""`), so
// `fieldWriteSeedParams` never adds `c` to `ctx.locals` and the later
// `c.pos = …` write falls straight into `checkFieldWriteTarget`'s
// `case None -> markFieldNameUnsafeToLock(...)` catch-all — unsafe by
// accident, via a route that never exercises `checkFieldMutability` at all.
// The idiomatic, common spelling is UNQUALIFIED (`inout Cursor`, reached
// through an ordinary `import Other`): `fieldWriteSimpleTypeName` resolves
// this to the single segment `"Cursor"`, which — because
// `computeFieldLockSafetyForBuild` merges `recordFields` across every file
// in the build BEFORE walking any of them — is found in the whole-build map
// even though `Cursor` is declared in a different file, so `c` IS seeded
// into `ctx.locals`. The write then reaches `checkFieldMutability`, whose
// non-`var` branch previously only appended a (silently discarded, inside
// this whole-build audit) V0015 diagnostic and never called
// `markFieldNameUnsafeToLock` — so this exact shape was never marked unsafe
// and `Cursor.pos` would be locked `initonly`/`ACC_FINAL` despite `bump`
// legally mutating it through the `inout` cursor.
test "an unqualified cross-file inout-parameter write marks the field unsafe to lock (#6653)" {
  val defSrc = "package Other\npub record Cursor {\n  pos: Int\n}\n"
  val useSrc = "package Consumer\nimport Other\nfunc bump(c: inout Cursor): Unit {\n  c.pos = c.pos + 1\n}\n"
  val srcs: List[String] = newList()
  srcs.add(defSrc)
  srcs.add(useSrc)
  val unsafeSet = lockSafetyMulti(srcs)
  assertTrue(unsafeSet.containsKey("pos"), "unqualified cross-file inout write to Cursor.pos: unsafe to lock")
}

// #6679: `collectFuncSigsOfFile` populated the whole-build `funcSigs` map
// keyed by BARE function name, first-file-wins across the whole build. Package
// `A` here declares `reset`'s BY-VALUE (`in`) signature and is walked first,
// so the old first-wins behaviour would register only that signature; a
// DIFFERENT package `B` then declares an `inout` `reset` with the same bare
// name. `Consumer.bump`'s unqualified `reset(c.pos)` call can't be told which
// declaration it actually resolves to — checking it against `A`'s `in`
// signature via `callArgIsByrefMode` would wrongly report the argument safe
// (`PMIn -> false`), so `pos` would never be marked unsafe to lock even
// though a real `inout` write-back exists elsewhere in the build. Poisoning
// any bare name registered more than once (removing it from `funcSigs`
// rather than keeping the first-registered signature) routes an ambiguous
// callee through the existing `sigOpt == None` unresolved-callee branch,
// which is already conservative.
test "a duplicate bare function name across packages with differing by-ref modes marks the call unsafe to lock (#6679)" {
  val aSrc = "package A\nfunc reset(n: in Int): Unit {\n}\n"
  val bSrc = "package B\nfunc reset(n: inout Int): Unit {\n}\n"
  val consumerSrc = "package Consumer\nrecord Cursor {\n  pos: Int\n}\nfunc bump(c: inout Cursor): Unit {\n  reset(c.pos)\n}\n"
  val srcs: List[String] = newList()
  srcs.add(aSrc)
  srcs.add(bSrc)
  srcs.add(consumerSrc)
  val unsafeSet = lockSafetyMulti(srcs)
  assertTrue(unsafeSet.containsKey("pos"), "ambiguous bare-name callee reset(c.pos): unsafe to lock")
}

// #6680: `walkFileForFieldWriteChecks` had no traversal case for `IFixture` —
// a `fixture name = expr` declaration's `init: Expr` runs once per test that
// consumes it, but was silently treated as safe to lock even though it
// compiles into real, executed code. This is the exact repro from the issue:
// a fixture initialiser that constructs a record and then writes to one of
// its non-`var` fields before yielding it.
test "a field written only inside a fixture initializer marks it unsafe to lock (#6680)" {
  val src = "@test_module\npackage P\nrecord Cursor {\n  pos: Int\n}\nfixture c = {\n  val k = Cursor(pos = 0)\n  k.pos = 1\n  k\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(unsafeSet.containsKey("pos"), "fixture-initializer-only write to Cursor.pos: unsafe to lock")
}

// #6680: `Lyric.TestSynth` rewrites a `@test_module`'s `fixture name = expr`
// into a module-level `val name = expr` (a source-text splice, not an AST
// transform) before `lyric test` compiles the synthesised file — so on the
// POST-synthesis AST the walker sees an `IVal`, not an `IFixture`, which was
// also unhandled. This is the general case too: ANY module-level `val`/
// `const` initialiser was invisible to both the V0015 diagnostic pass and
// the whole-build lock-safety audit before this fix, not only the
// TestSynth-rewritten shape.
test "a field written only inside a module-level val initializer marks it unsafe to lock (#6680)" {
  val src = "package P\nrecord Cursor {\n  pos: Int\n}\nval c = {\n  val k = Cursor(pos = 0)\n  k.pos = 1\n  k\n}\n"
  val unsafeSet = lockSafety(src)
  assertTrue(unsafeSet.containsKey("pos"), "module-level val-initializer-only write to Cursor.pos: unsafe to lock")
}

// #6682: `computeFieldLockSafetyForBuild`'s `recordFields` merge was keyed by
// BARE record name, first-file-wins across packages — the same shape bug as
// #6653, but here the root cause is the merge itself resolving a write
// through the WRONG record's field-mutability map rather than the write-
// target resolution. Package `A` declares `record State { a: Int }` and is
// walked first, so the merged map holds only `{a}`. Package `B` declares a
// DIFFERENT `record State { b: Int }` plus a write to its own field `b`
// through a tracked `var` local; before the fix, `checkFieldMutability`
// looks up `"b"` in `A`'s field map, finds nothing (`case None -> {}`), and
// silently does nothing — `b` is never marked unsafe to lock despite the
// real, non-`var` write. Marking every field of BOTH colliding declarations
// unsafe to lock on the collision itself (not just the field actually
// written) closes the gap regardless of merge order.
test "two same-named records in different packages mark all colliding fields unsafe to lock (#6682)" {
  val aSrc = "package A\nrecord State {\n  a: Int\n}\n"
  val bSrc = "package B\nrecord State {\n  b: Int\n}\nfunc f(): Unit {\n  var s = State(b = 1)\n  s.b = 2\n}\n"
  val srcs: List[String] = newList()
  srcs.add(aSrc)
  srcs.add(bSrc)
  val unsafeSet = lockSafetyMulti(srcs)
  assertTrue(unsafeSet.containsKey("b"), "write to colliding B.State.b: unsafe to lock")
  assertTrue(
    unsafeSet.containsKey("a"),
    "colliding A.State.a also marked unsafe to lock (name collision, not just the written field)"
  )
}
