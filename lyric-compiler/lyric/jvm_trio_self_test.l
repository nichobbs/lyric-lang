//! jvm_trio_self_test.l — runtime regression tests for three JVM-only
//! silent-miscompiles found building `lyric-jsonrpc` (docs/62), all rooted in
//! `lyric-compiler/jvm/codegen/` (#6122, #6123, #6124).
//!
//! Run by the native `lyric test` on both targets:
//!   lyric test --target dotnet lyric-compiler/lyric/jvm_trio_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/jvm_trio_self_test.l
//! `lyric test` synthesises a program from the `test` blocks and compiles it
//! in-process through the self-hosted `Msil.Bridge` / `Jvm.Bridge`, then
//! asserts every embedded value. Imports only `Std.*` (no
//! `LYRIC_LOAD_COMPILER=1`).
//!
//! #6122 — a `while` loop whose body is a `match` with arms mixing
//! loop-continuing and loop-ending control flow stopped after exactly one
//! iteration on JVM. Root cause: `03_match.l`'s `PConstructor` TEST phase
//! only isinst-tested the outer case (`Ok`), never recursing into a nested
//! constructor sub-pattern (`None` vs `Some(x)`) — so `case Ok(None) ->`
//! silently matched every `Ok(..)` value regardless of its actual payload,
//! and whichever `Ok(..)` arm came first in source order always "won".
//! Fixed by `patternIsRefutableJvm`/`testCaseFieldJvm`, mirroring the MSIL
//! backend's existing `patternIsRefutableMsil`/`testCaseFieldMsil`.
//!
//! #6123 — a `JObject`/`JArray`-shaped (or, isolated further here, any
//! reference-typed) value returned from the LAST arm of an
//! `if … else if … else …` chain came back corrupted whenever an EARLIER
//! arm in the same chain was a terminating `panic(...)`. Root cause:
//! `02_exprs.l`'s `lowerIfExpr` decided "is this whole if-expression
//! void-typed?" from the THEN-arm's reported JVM type even when the
//! then-arm had unconditionally transferred control — and `panic(...)`
//! reports `JVoid` as a pure codegen convention despite being a
//! bottom-typed terminator. That misclassified the entire (nested)
//! if-expression as void, discarding whatever a LATER, value-producing arm
//! actually computed. Fixed by determining the if-expression's type from
//! the first NON-terminating arm only (mirroring `lowerMatchExpr`'s
//! `resultTyFixed` rule).
//!
//! #6124 — a plain `Int`-typed `s.indexOf(needle)` call (no `Std.String`
//! import in the calling file) came back as a boxed `Option$Some` object
//! instead of an `Int` whenever some OTHER file in the same compiled
//! bundle happened to import `Std.String` — a
//! `ClassCastException: Option$Some cannot be cast to Integer` the moment
//! the bogus value was used. Root cause: `04_calls.l`'s `.indexOf`/
//! `.lastIndexOf` UFCS routing checked only "is `Std/String/indexOf@2`
//! registered ANYWHERE in the bundle-wide `ctx.funcSigs`", not "does THIS
//! FILE actually import `Std.String`". This is NOT a divergence from any
//! type-checker invariant — a `String` receiver's `.indexOf` types as
//! lenient `TyError` on either side of the import (`typechecker_exprs.l`'s
//! method-call resolution only ever considers a `TyUser` receiver), so the
//! checker never distinguished the two cases at all; `.indexOf`'s
//! Option[Int]-when-imported behavior is purely a codegen-side design
//! choice. Fixed by `FuncCtx.importsStdString`, computed once per file from
//! its own `import` list and threaded through every function/method/
//! wire-binding lowered.  This file imports `Std.Testing.Snapshot`
//! (transitively `Std.String`) WITHOUT importing `Std.String` itself, so
//! `Std/String/indexOf@2` is present in the bundle-wide registry exactly as
//! it was in the real `lyric-jsonrpc` build, reproducing the cross-file
//! condition. The companion positive path — a file that DOES import
//! `Std.String` still getting the `Option[Int]` routing — lives in
//! `jvm_trio_positive_self_test.l` (it needs `Std.String` imported directly,
//! which would defeat this file's deliberate no-direct-import setup for the
//! negative cases above).
@test_module
package Lyric.JvmTrioSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Testing.Snapshot

// ─────────────────────────────────────────────────────────────────────────────
// #6122 — while + match with mixed loop-continuing/loop-ending arms.
// ─────────────────────────────────────────────────────────────────────────────
interface Transport {
  func receive(): Result[Option[String], String]
}

record FakeTransport {
  var idx: Int
  msgs: List[String]
}

impl Transport for FakeTransport {
  func receive(): Result[Option[String], String] {
    if self.idx >= self.msgs.count {
      Ok(None)
    } else {
      val m = self.msgs[self.idx]
      self.idx = self.idx + 1
      Ok(Some(m))
    }
  }
}

func runLoop(t: in FakeTransport): Int {
  var running = true
  var count = 0
  while running {
    match t.receive() {
      case Err(e) -> {
        running = false
      }
      case Ok(None) -> {
        running = false
      }
      case Ok(Some(text)) -> {
        count = count + 1
      }
    }
  }
  count
}

test "while+match with mixed continue/stop arms loops fully (#6122)" {
  val msgs: List[String] = newList()
  msgs.add("a")
  msgs.add("b")
  msgs.add("c")
  val t = FakeTransport(idx = 0, msgs = msgs)
  val n = runLoop(t)
  assertEqualInt(n, 3, "should process all 3 messages, not stop after the first")
}

test "while+match: reordering Ok(Some)/Ok(None) still discriminates correctly (#6122)" {
  // Same shape, arms reordered — the historical fix for this bug on its own
  // (without also fixing #6123's if-expression bug) still left the
  // REORDERED-arms case throwing a ClassCastException on the second
  // iteration; both orderings must work.
  val msgs: List[String] = newList()
  msgs.add("x")
  msgs.add("y")
  val t = FakeTransport(idx = 0, msgs = msgs)
  var running = true
  var count = 0
  while running {
    match t.receive() {
      case Ok(Some(text)) -> {
        count = count + 1
      }
      case Ok(None) -> {
        running = false
      }
      case Err(e) -> {
        running = false
      }
    }
  }
  assertEqualInt(count, 2, "both messages counted regardless of arm order")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6123 — an if/else-if/else chain's LATER value-producing arm must survive
// an EARLIER terminating (`panic`) arm in the same chain.
// ─────────────────────────────────────────────────────────────────────────────
union Reply {
  case ReplyOk(payload: List[String])
  case ReplyErr(message: String)
}

func classify(method: in String, payload: in List[String]): Reply {
  if method == "echo" {
    ReplyOk(payload = payload)
  } else if method == "boom" {
    panic("deliberate panic")
  } else if method == "unknown" {
    ReplyErr(message = "method not found")
  } else {
    ReplyOk(payload = payload)
  }
}

test "if-chain: a later value arm survives an earlier mid-chain panic arm (#6123)" {
  val payload: List[String] = newList()
  payload.add("x")
  payload.add("1")
  val r = classify("echo", payload)
  match r {
    case ReplyOk(items) -> {
      assertEqualInt(items.count, 2, "container payload survives past the panic arm")
      assertEqual(items[0], "x", "first element intact")
      assertEqual(items[1], "1", "second element intact")
    }
    case ReplyErr(_) -> assertTrue(false, "expected ReplyOk, got ReplyErr")
  }
}

test "if-chain: the arm after the panic arm still resolves correctly (#6123)" {
  val payload: List[String] = newList()
  val r = classify("unknown", payload)
  match r {
    case ReplyOk(_) -> assertTrue(false, "expected ReplyErr, got ReplyOk")
    case ReplyErr(msg) -> assertEqual(msg, "method not found", "unknown-method arm still resolves")
  }
}

// A terminating then-arm paired with a genuinely VOID (non-terminating)
// else-arm: the whole if-expression must stay correctly void (mirrors the
// `case JVoid ->` sub-branch of the `thenTerminated` split in `lowerIfExpr`,
// as opposed to the value-producing else-arm the tests above exercise). The
// `if` here is used purely for effect — its own value is never read — and
// `count` is read from a SEPARATE trailing statement, so a stack-discipline
// regression in the void path would surface as a class-load VerifyError
// (bad operand stack) rather than a wrong value.
func voidThenTerminated(method: in String): Int {
  var count = 0
  if method == "boom" {
    panic("deliberate panic")
  } else {
    count = 42
  }
  count
}

test "if-chain: terminating then-arm + void else-arm stays void (#6123)" {
  assertEqualInt(voidThenTerminated("ok"), 42, "void else-arm's side effect still applies")
}

// A doubly-nested constructor pattern: `Ok(Some(Ok(x)))` vs
// `Ok(Some(Err(e)))` exercises `testCaseFieldJvm`'s recursion into a
// SECOND level of refutable sub-pattern (the outer `Ok`'s field is itself an
// `Option` whose `Some` field is itself a `Result`), not just the one level
// the tests above cover.
func classifyNested(r: in Result[Option[Result[Int, String]], String]): String {
  match r {
    case Ok(Some(Ok(x))) -> "double-ok:" + toString(x)
    case Ok(Some(Err(e))) -> "inner-err:" + e
    case Ok(None) -> "ok-none"
    case Err(e) -> "outer-err:" + e
  }
}

test "match: doubly-nested constructor pattern discriminates correctly (#6122)" {
  assertEqual(classifyNested(Ok(value = Some(value = Ok(value = 7)))), "double-ok:7", "Ok(Some(Ok(x))) picked")
  assertEqual(
    classifyNested(Ok(value = Some(value = Err(error = "bad")))),
    "inner-err:bad",
    "Ok(Some(Err(e))) picked, not Ok(Some(Ok(x)))"
  )
  assertEqual(classifyNested(Ok(value = None)), "ok-none", "Ok(None) picked, not either Some(..) arm")
  assertEqual(classifyNested(Err(error = "outer")), "outer-err:outer", "Err(e) picked")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6124 — `.indexOf`/`.lastIndexOf` on a String receiver, in a file that does
// NOT import `Std.String`, must use the raw Int (-1 sentinel) semantics even
// when `Std.String` is present elsewhere in the compiled bundle (transitively
// pulled in above via `Std.Testing.Snapshot`).
// ─────────────────────────────────────────────────────────────────────────────
func findColon(line: in String): Int {
  line.indexOf(":")
}

test "String.indexOf without importing Std.String returns a plain Int (#6124)" {
  val idx = findColon("Content-Length: 7")
  assertEqualInt(idx, 14, "colon is at index 14")
  assertTrue(idx > 0, "positive index compares fine as a plain Int")
}

test "String.indexOf without importing Std.String returns -1 for a missing needle (#6124)" {
  val idx = findColon("no colon here")
  assertEqualInt(idx, 0 - 1, "missing needle is the -1 sentinel, not None")
}

test "String.lastIndexOf without importing Std.String returns a plain Int (#6124)" {
  val idx = "a:b:c".lastIndexOf(":")
  assertEqualInt(idx, 3, "last colon is at index 3")
}
