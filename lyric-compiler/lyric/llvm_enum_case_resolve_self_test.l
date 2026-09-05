//! llvm_enum_case_resolve_self_test.l — end-to-end self-test for #6589
//! (native: a bare cross-package enum-case value reference fails to
//! resolve) and the same-root-cause same-file/record-default cases
//! `docs/03-decision-log.md` D-progress-823 item D worked around instead
//! of fixing.
//!
//! Before the fix, `Lyric.LlvmCodegen`'s enum-case registry
//! (`ctx.enumDefs`) only ever indexed a case under its qualified forms
//! (`EnumName.Case`, `pkgName.EnumName.Case`) — never the bare case name
//! alone — so a reference with no qualifying prefix at all
//! (`var v: HttpVersion = Http1_1` rather than
//! `var v: HttpVersion = HttpVersion.Http1_1`) fell through to
//! `loadLocal`'s "unknown name" panic, regardless of whether the
//! defining enum lived in the same file or a different package. The fix
//! (mirroring `Msil.Codegen.registerEnumDeclMsil`'s `cn` key exactly,
//! including its first-wins collision policy across the whole bundle)
//! also registers the bare case name, so the existing bare-`EPath`
//! lookup in `lowerExpr` — previously only ever hit by an
//! already-qualified path — now resolves a truly bare reference too.
//!
//! Six cases:
//!   - item A (#6589's exact reported shape): a bare reference to a
//!     CROSS-PACKAGE enum case (`Std.HttpEngine.HttpVersion.Http1_1`,
//!     the issue's own motivating example), assigned against an
//!     explicit type annotation. Exercises `Lyric.LlvmBridge`'s bundled
//!     compilation path (`compileToNativeWithFlags` + the native stdlib
//!     source set), since a genuinely separate package is needed.
//!   - item B (D-progress-823 item D, first half): a bare nullary
//!     enum-case reference as a function's trailing block value
//!     (`func f(): MyEnum { A }`), same file as the enum.
//!   - item C (D-progress-823 item D, second half): a record field's
//!     *default* value that is itself a bare enum case, exercised by
//!     omitting the field at a construction site.
//!   - item D (review finding on PR #6746): a bare case name shared by
//!     an enum and a union in the same bundle must resolve to the enum
//!     in VALUE position, matching `Msil.Codegen`'s bare-name check
//!     order (enum ordinal before nullary union case) — `lowerExpr`'s
//!     `EPath` arm checks `ctx.enumDefs` before `ctx.caseRefs` for
//!     exactly this reason.
//!   - item E (review finding #6753, found while fixing item D's own
//!     review round): the identical enum/union bare-name collision, but
//!     in PATTERN position — a `match` arm using the bare case name
//!     against a UNION scrutinee. Registering the bare enum-case name
//!     (the whole point of this fix) made `emitConstructorTest`'s
//!     unconditional `ctx.enumDefs` lookup a live hazard for the
//!     unrelated `PBinding` -> `scrutineeHasCase` redirect path, which
//!     is reached with a bare name only once the scrutinee is already
//!     confirmed to be a union — `emitConstructorTest` now gates its
//!     enum branch on `sv.ty == NI32` (the enum's actual runtime
//!     representation) so a union scrutinee (always a struct pointer)
//!     can never be misrouted into it.
//!   - item F (the other half of the bare-name collision space): an
//!     enum-vs-**enum** bare-name collision — the exact bug class
//!     `lyric-stdlib/std/http_engine.l`'s own module header documents
//!     as issue #5995 (two enums sharing a case name resolving against
//!     the wrong one once both compile into the same program). Two
//!     enums each declare a case named `Shared` at a different ordinal;
//!     a bare `Shared` reference against an explicit type annotation
//!     must resolve to the first-declared enum's ordinal — the
//!     deterministic first-wins outcome `Msil.Codegen`'s own comment
//!     documents, now mirrored on native. Does not re-litigate #5995
//!     itself (a pre-existing MSIL/JVM behavior); documents that
//!     native's collision semantics are deterministic and match the
//!     other two targets'.
//!   - item G (#6740, fixed): a bare pattern-position case name against
//!     an ENUM scrutinee. `scrutineeHasCase` only ever consulted
//!     `unionInfoOfType`, which is always `None` for an enum (an enum
//!     erases to bare `NI32`, indistinguishable from a real `Int` by
//!     type alone), so a bare-case `match` arm over an enum value always
//!     matched unconditionally as a catch-all bind — silently, no
//!     diagnostic, just a wrong answer for every arm after the first.
//!     Fixed by falling back to `ctx.enumDefs.containsKey(name)` when
//!     the scrutinee's type is `NI32`, delegating to the SAME
//!     `emitConstructorTest` enum branch item E's fix already gates on
//!     `sv.ty == NI32`.
//!   - item H (#6969, fixed): item G's own fix was reachable by a REAL
//!     `Int` scrutinee too, since `ctx.enumDefs.containsKey(name)` is a
//!     global, bundle-wide bare-case-name registry with no check that
//!     the scrutinee is actually of that enum's type — an ordinary
//!     catch-all bind pattern over a plain `Int` whose bind name happens
//!     to match ANY enum case name anywhere in the compiled bundle was
//!     silently reinterpreted as an equality test against that unrelated
//!     enum's ordinal, instead of binding. Fixed by threading
//!     `inferScrutineeEnumHint` (mirroring `Msil.Codegen`'s
//!     `inferScrutineeEnumHintMsil`, #5995) from the match scrutinee's
//!     own declared type through to `scrutineeHasCase`, which now scopes
//!     the enum-case check to `enumHint + "." + name` — the scrutinee's
//!     OWN enum — rather than any bare-name match in the whole bundle.
//!     An `Int` scrutinee has no enum hint, so it always falls through
//!     to a plain bind, exactly as it did before item G's fix existed.
//!
//! Items A-D and F's `match` arms use the fully-qualified `EnumType.Case`
//! pattern form deliberately, to isolate the value-position fix from the
//! pattern-position gap item G covers directly. Item E's bare pattern
//! deliberately targets a UNION scrutinee instead — a different path
//! (#6753), unrelated to item G's enum-scrutinee case.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`) for
//! items B/C; item A additionally needs the native stdlib source tree
//! (`findStdlibSourcesNative()`, i.e. run from the repo root or set
//! `LYRIC_STD_PATH`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_enum_case_resolve_self_test.l
@test_module
package Lyric.LlvmEnumCaseResolveSelfTest

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
import Lyric.Emitter
import Lyric.LlvmBridge

// ─────────────────────────────────────────────────────────────────────────────
// Harness A: single-file compile (`Lyric.LlvmCodegen.codegenNativePackage`
// direct, no bundled stdlib) — mirrors llvm_heap_self_test.l. Used by items
// B and C, which need no cross-package import.
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

func compileAndRun(source: in String): RunOutcome {
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
  val dir = Path.join(tempBase(), "lyric-llvm-enumcase-selftest")
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

// ─────────────────────────────────────────────────────────────────────────────
// Harness B: bundled compile through `Lyric.LlvmBridge` (mirrors
// llvm_tls_self_test.l) — used by item A, which needs a genuinely
// separate package (`Std.HttpEngine`) pulled in via `import`.
// ─────────────────────────────────────────────────────────────────────────────
func compileAndRunBundled(source: in String): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-enumcase-bundled-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val noFlags: List[String] = newList()
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", noFlags, newList(), "") {
    panic("native compilation failed for a bundled enum-case-resolve self-test program")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Item A (#6589): bare cross-package enum-case value reference.
// ─────────────────────────────────────────────────────────────────────────────
test "bare cross-package enum-case reference resolves via explicit type annotation (#6589 item A)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.HttpEngine\n" +
    "func classify(v: in HttpVersion): Int {\n" +
    "  match v {\n" +
    "    case HttpVersion.Http1_1 -> 11\n" +
    "    case HttpVersion.Http1_0 -> 10\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var version: HttpVersion = Http1_1\n" +
    "  var other: HttpVersion = Http1_0\n" +
    "  val a = classify(version)\n" +
    "  val b = classify(other)\n" +
    "  if a == 11 and b == 10 {\n" +
    "    42\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 42, "cross-package bare enum-case reference (#6589 item A)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item B (D-progress-823 item D, first half): bare nullary enum-case as a
// function's trailing block value, same file as the enum.
// ─────────────────────────────────────────────────────────────────────────────
test "bare same-file enum-case reference resolves as a function's trailing return value (D-progress-823 item D)" {
  val src = "package T\n" + "enum Color {\n" + "  case Red\n" + "  case Green\n" + "  case Blue\n" + "}\n" +
    "func pick(flag: in Int): Color {\n" +
    "  if flag == 0 {\n" +
    "    Red\n" +
    "  } else if flag == 1 {\n" +
    "    Green\n" +
    "  } else {\n" +
    "    Blue\n" +
    "  }\n" +
    "}\n" +
    "func toInt(c: in Color): Int {\n" +
    "  match c {\n" +
    "    case Color.Red -> 0\n" +
    "    case Color.Green -> 1\n" +
    "    case Color.Blue -> 2\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a = toInt(pick(0))\n" +
    "  val b = toInt(pick(1))\n" +
    "  val c = toInt(pick(2))\n" +
    "  if a == 0 and b == 1 and c == 2 {\n" +
    "    42\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "bare same-file enum-case as trailing return value (D-progress-823 item D)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item C (D-progress-823 item D, second half): a record field's default
// value is itself a bare enum case, exercised by omitting the field.
// ─────────────────────────────────────────────────────────────────────────────
test "bare enum-case record field default resolves when the field is omitted at construction (D-progress-823 item D)" {
  val src = "package T\n" + "enum Level {\n" + "  case Debug\n" + "  case Info\n" + "  case Warn\n" + "}\n" +
    "record Config {\n" +
    "  name: String\n" +
    "  level: Level = Info\n" +
    "}\n" +
    "func levelToInt(l: in Level): Int {\n" +
    "  match l {\n" +
    "    case Level.Debug -> 0\n" +
    "    case Level.Info -> 1\n" +
    "    case Level.Warn -> 2\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val c = Config(name = \"svc\")\n" +
    "  val d = Config(name = \"svc2\", level = Warn)\n" +
    "  if levelToInt(c.level) == 1 and levelToInt(d.level) == 2 {\n" +
    "    42\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "bare enum-case record field default (D-progress-823 item D)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item D (review finding on PR #6746): when a bare case name collides
// across an enum and a union in the same bundle, `lowerExpr`'s `EPath`
// arm must check `ctx.enumDefs` BEFORE `ctx.caseRefs`, matching
// `Msil.Codegen`'s bare-name resolution order (`enumCaseOrdinals` before
// `unionCaseCtorByName`) exactly, so identical unqualified source
// resolves the same way on `--target native` as on `--target dotnet`.
// `Status` (an enum) and `Wrapper` (a union) both declare a case named
// `Ready`; a bare `Ready` used against an explicit `Status`-typed
// annotation must resolve to `Status`'s enum ordinal, not `Wrapper`'s
// union-case constructor.
// ─────────────────────────────────────────────────────────────────────────────
test "a bare case name shared by an enum and a union resolves to the enum, matching Msil.Codegen's precedence (#6746 review)" {
  val src = "package T\n" + "enum Status {\n" + "  case Ready\n" + "  case Done\n" + "}\n" + "union Wrapper {\n" +
    "  case Ready\n" +
    "  case Pending\n" +
    "}\n" +
    "func statusToInt(s: in Status): Int {\n" +
    "  match s {\n" +
    "    case Status.Ready -> 1\n" +
    "    case Status.Done -> 2\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var s: Status = Ready\n" +
    "  statusToInt(s)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 1, "bare case name collision resolves to the enum, not the union (#6746 review)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item E (review finding #6753, follow-on from item D): the SAME
// enum/union bare-name collision as item D, but in PATTERN position — a
// `match` arm using the bare case name against a UNION scrutinee.
// `emitConstructorTest` is reached with a bare single-segment head from
// `emitPatternTest`'s `PBinding` -> `scrutineeHasCase` redirect only once
// the scrutinee is already confirmed to be a union with that case, so its
// enum-ordinal branch must never fire there just because an unrelated
// enum elsewhere in the bundle happens to share the bare case name — the
// scrutinee is a struct pointer, not an i32 discriminant. Asserts the
// `match` still resolves the union case correctly (not a panic, not a
// type-mismatched comparison) even with `Status.Ready` present in the
// same bundle.
// ─────────────────────────────────────────────────────────────────────────────
test "a bare case name in a match PATTERN against a union scrutinee still resolves to the union, even with a same-named enum in the bundle (#6753)" {
  val src = "package T\n" + "enum Status {\n" + "  case Ready\n" + "  case Done\n" + "}\n" + "union Wrapper {\n" +
    "  case Ready\n" +
    "  case Pending\n" +
    "}\n" +
    "func classify(w: in Wrapper): Int {\n" +
    "  match w {\n" +
    "    case Ready -> 1\n" +
    "    case Pending -> 2\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a = classify(Wrapper.Ready)\n" +
    "  val b = classify(Wrapper.Pending)\n" +
    "  if a == 1 and b == 2 {\n" +
    "    42\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(
    r.exitCode,
    42,
    "bare pattern-position match against a union resolves correctly despite a same-named enum (#6753)"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Item F: an enum-vs-ENUM bare-name collision — the bug class
// `lyric-stdlib/std/http_engine.l`'s own module header documents as
// issue #5995 (`Std.Http.HttpVersion` and `Std.HttpEngine.HttpVersion`
// both declaring a case named `Http11`, resolving against the *wrong*
// package's enum on MSIL/JVM once both compile into the same program —
// the reason `http_engine.l` renamed its own cases to `Http1_0`/
// `Http1_1` rather than fix the resolver). Items D/E cover enum-vs-union
// collisions; this covers the other half of the bare-name collision
// space. `First` (declaring `Shared` at ordinal 1) and `Second`
// (declaring `Shared` at ordinal 0) are declared in that order in one
// file; a bare `Shared` reference against an explicit `First`-typed
// annotation must resolve to `First`'s `Shared` (ordinal 1) — the
// deterministic first-wins outcome `Msil.Codegen.registerEnumDeclMsil`'s
// own comment documents ("first-wins... keeps the first registration"),
// now mirrored on native. Round-tripped through a fully-qualified
// `First.Case` match so a wrong-ordinal resolution (silently reading as
// `Second`'s `Shared`, ordinal 0, i.e. `First.OnlyFirst`) fails the
// assertion rather than merely not panicking. This does not re-litigate
// #5995 itself (a pre-existing MSIL/JVM behavior, out of scope here) —
// it documents that native's first-wins semantics are deterministic and
// match the other two targets' for the same collision shape.
// ─────────────────────────────────────────────────────────────────────────────
test "an enum-vs-enum bare-name collision resolves via first-wins, matching Msil.Codegen's documented semantics (#5995 shape)" {
  val src = "package T\n" + "enum First {\n" + "  case OnlyFirst\n" + "  case Shared\n" + "}\n" + "enum Second {\n" +
    "  case Shared\n" +
    "  case OnlySecond\n" +
    "}\n" +
    "func pickShared(): First {\n" +
    "  Shared\n" +
    "}\n" +
    "func firstToInt(f: in First): Int {\n" +
    "  match f {\n" +
    "    case First.OnlyFirst -> 0\n" +
    "    case First.Shared -> 1\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  if firstToInt(pickShared()) == 1 {\n" +
    "    42\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(
    r.exitCode,
    42,
    "enum-vs-enum bare-name collision resolves to the first-declared enum's case (#5995 shape)"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Item G (#6740): a bare pattern-position case name against an ENUM
// scrutinee. Before the fix, `case Http1_1 -> 1` (the FIRST arm) always
// matched unconditionally (an ordinary catch-all bind, since
// `scrutineeHasCase` never recognised an enum case) — so `toInt(Http1_0)`
// would wrongly also return 1 instead of falling through to the second
// arm's `0`. Both calls are asserted so an unconditional-first-arm-match
// regression fails, not just a "did it panic" check.
// ─────────────────────────────────────────────────────────────────────────────
test "a bare case name in a match PATTERN against an ENUM scrutinee gates on the value, not an unconditional bind (#6740)" {
  val src = "package T\n" + "enum Version {\n" + "  case Http1_0\n" + "  case Http1_1\n" + "}\n" +
    "func toInt(v: in Version): Int {\n" +
    "  match v {\n" +
    "    case Http1_1 -> 1\n" +
    "    case Http1_0 -> 0\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  if toInt(Http1_1) == 1 and toInt(Http1_0) == 0 {\n" +
    "    42\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(
    r.exitCode,
    42,
    "bare enum-case pattern gates correctly instead of always matching the first arm (#6740)"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Item H (#6969): item G's fix reinterpreted an ordinary Int catch-all
// bind as an enum-case equality test whenever the bind name collided
// with ANY enum case anywhere in the bundle — even though the scrutinee
// here is a plain `Int`, never the `Version` enum whose case happens to
// share the bind name. `classifyInt(99)` must echo 99 back (a plain
// bind), not compare 99 against `Version.Http1_1`'s ordinal (1) and
// fall through to the wildcard arm.
// ─────────────────────────────────────────────────────────────────────────────
test "a bare catch-all bind over a plain Int scrutinee is never reinterpreted as an enum-case test merely because its name collides with an unrelated enum's case (#6969)" {
  val src = "package T\n" + "enum Version {\n" + "  case Http1_0\n" + "  case Http1_1\n" + "}\n" +
    "func classifyInt(n: Int): Int {\n" +
    "  match n {\n" +
    "    case Http1_1 -> Http1_1\n" +
    "    case _ -> 0 - 1\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  if classifyInt(99) == 99 {\n" +
    "    42\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(
    r.exitCode,
    42,
    "an Int scrutinee's catch-all bind is unaffected by an unrelated enum's same-named case (#6969)"
  )
}
