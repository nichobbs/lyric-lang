//! lambda_bool_if_cond_self_test.l — runtime regression test for #5935 (JVM):
//! using the `Bool` a `(T) -> Bool`-typed function-parameter call returns
//! DIRECTLY as an `if`/`while` condition used to emit invalid bytecode (a
//! boxed `java.lang.Boolean` reaching `ifeq` without an unbox, `VerifyError:
//! Bad type on operand stack ... 'java/lang/Object' is not assignable to
//! integer`).  `lyric-stdlib/std/http_engine.l`'s `findByteWhere`/`allBytes`
//! document the bug and work around it by binding the call's result to an
//! explicit `: Bool` local before branching on it.
//!
//! Root cause / fix: `lowerBoolCond`/`lowerBoolCondTrue`
//! (`lyric-compiler/jvm/codegen/02_exprs.l`) already coerce a condition's
//! erased `Object` result to primitive `boolean` in their catch-all match
//! arm (`coerceArgTo(insns, condTy, JBoolean)` before the `ifeq`/`ifne`) —
//! landed generally for #5563 in commit 15bf300 (PR #5846), which predates
//! `Std.HttpEngine`'s workaround. No codegen change was needed; this file
//! closes the gap that #5935 had no dedicated regression test pinning the
//! direct-call-in-condition shape on both `if` and `while`.
//!
//! Run by the native `lyric test` on BOTH targets (like `bitwise_self_test.l`
//! / `block_shadow_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/lambda_bool_if_cond_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/lambda_bool_if_cond_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.LambdaBoolIfCondSelfTest

import Std.Core
import Std.Testing

func isEven(n: in Int): Bool {
  n % 2 == 0
}

// 1. Direct call through a function-typed parameter as an `if` condition —
// the #5935 shape: the erased-invoke result must be unboxed before `ifeq`.
func directIfCond(pred: in (Int) -> Bool, x: in Int): String {
  if pred(x) {
    "yes"
  } else {
    "no"
  }
}

// 2. `if not pred(x)` — `PreNot` routes through `lowerBoolCondTrue` on the
// same erased-invoke value; a separate coercion site from case 1.
func notIfCond(pred: in (Int) -> Bool, x: in Int): String {
  if not pred(x) {
    "yes"
  } else {
    "no"
  }
}

// 3. A direct predicate call as a `while` condition — `SWhile` shares
// `lowerBoolCond` with `if` (05_stmts.l), so this exercises the fix from a
// different statement-level call site.
func countWhile(pred: in (Int) -> Bool, start: in Int): Int {
  var i = start
  var count = 0
  while pred(i) {
    count = count + 1
    i = i + 1
  }
  count
}

// 4. The documented workaround shape (explicit `: Bool` local before the
// branch) — this path always worked (the unbox happens at the `val`
// assignment, not the branch), kept here as a control so a future
// regression in the direct-call path (cases 1-3) can't hide behind this one
// still passing.
func explicitLocalIfCond(pred: in (Int) -> Bool, x: in Int): String {
  val ok: Bool = pred(x)
  if ok {
    "yes"
  } else {
    "no"
  }
}

test "direct call through a function-typed param used as an if condition" {
  assertEqual(directIfCond({ n: Int -> isEven(n) }, 4), "yes", "even direct-if true")
  assertEqual(directIfCond({ n: Int -> isEven(n) }, 5), "no", "even direct-if false")
}

test "not-prefixed call through a function-typed param used as an if condition" {
  assertEqual(notIfCond({ n: Int -> isEven(n) }, 5), "yes", "not-even direct-if true")
  assertEqual(notIfCond({ n: Int -> isEven(n) }, 4), "no", "not-even direct-if false")
}

test "call through a function-typed param used directly as a while condition" {
  assertEqualInt(countWhile({ n: Int -> n < 3 }, 0), 3, "while-cond count")
}

test "call through a function-typed param bound to an explicit Bool local first" {
  assertEqual(explicitLocalIfCond({ n: Int -> isEven(n) }, 4), "yes", "explicit-local true")
  assertEqual(explicitLocalIfCond({ n: Int -> isEven(n) }, 5), "no", "explicit-local false")
}
