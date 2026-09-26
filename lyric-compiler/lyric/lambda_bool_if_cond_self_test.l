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
//! Cases 5 and 6 cover a separate MSIL bug (D-progress-980): an
//! UN-annotated lambda parameter whose function type comes from the
//! lambda's expected type was never given its own return type, so calling
//! it left a boxed `object` that `if` tested for non-null.  That one needed
//! a codegen change (`lambdaParamFnRetTypes` in `lyric-compiler/msil/codegen.l`).
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

// 5. An UN-annotated lambda parameter whose function type comes from the
// lambda's expected type (a `val` annotation, or the parameter it is passed
// to).  MSIL typed the parameter from the erased delegate shape only, so
// `p()` stayed a boxed `object` and `if` tested it for non-null: a boxed
// `false` counted as true (D-progress-980).
func applyGuard(g: in (() -> Bool) -> String, answer: in Bool): String {
  g({ -> answer })
}

test "un-annotated function-typed lambda param used as an if condition" {
  val guard: (() -> Bool) -> String = { p -> if p() then "yes" else "no" }
  assertEqual(guard({ -> false }), "no", "local-annotated false")
  assertEqual(guard({ -> true }), "yes", "local-annotated true")
  val both: (() -> Bool) -> String = { p -> if not p() and true then "not" else "is" }
  assertEqual(both({ -> false }), "not", "negated in a conjunction")
  assertEqual(applyGuard({ p -> if p() then "yes" else "no" }, false), "no", "passed to a HOF, false")
  assertEqual(applyGuard({ p -> if p() then "yes" else "no" }, true), "yes", "passed to a HOF, true")
}

// 6. The same, passed to a GENERIC higher-order function: the callback's own
// `() -> Bool` parameter does not mention the function's type parameter, so
// its return type is recorded too (#7392).
func applyGuardG[T](x: in T, g: in (() -> Bool) -> String, answer: in Bool): String {
  g({ -> answer })
}

test "un-annotated function-typed lambda param of a generic HOF used as an if condition" {
  assertEqual(applyGuardG(1, { p -> if p() then "yes" else "no" }, false), "no", "generic HOF, false")
  assertEqual(applyGuardG("s", { p -> if p() then "yes" else "no" }, true), "yes", "generic HOF, true")
}

// 7. A boxed Bool reaches every Boolean consumer, not only `if`: the return
// type of `() -> T` is not recorded when it mentions the generic function's
// own `T`, so with `T = Bool` the call stays boxed.  MSIL now unboxes at the
// consumer (`lowerBoolOperandMsil`): `if`, `while`, `and`, `or`, `not` and
// match guards (#7408).
func viaGeneric[T](seed: in T, g: in (() -> T) -> String, v: in T): String {
  g({ -> v })
}

test "a generic callback returning Bool is unboxed wherever it is used as a condition" {
  assertEqual(viaGeneric(true, { p -> if p() then "yes" else "no" }, false), "no", "if, false")
  assertEqual(viaGeneric(true, { p -> if p() then "yes" else "no" }, true), "yes", "if, true")
  assertEqual(viaGeneric(true, { p -> if not p() then "not" else "is" }, false), "not", "not")
  assertEqual(viaGeneric(true, { p -> if p() and true then "both" else "one" }, false), "one", "and")
  assertEqual(viaGeneric(true, { p -> if false or p() then "some" else "none" }, false), "none", "or")
  assertEqual(
    viaGeneric(true, { p ->
      var n = 0
      while p() and n < 3 {
        n = n + 1
      }
      n.toString()
    }, false),
    "0",
    "while"
  )
  assertEqual(
    viaGeneric(true, { p -> match 1 { case 1 if p() -> "guarded"; case _ -> "fallthrough" } }, false),
    "fallthrough",
    "match guard"
  )
}

// 8. The same boxed Bool as an operand of a VALUE-producing logical
// operator (bound to a local, not branched on): `xor` on both targets, and
// `and`/`or`/`implies` on JVM, lowered their operands without unboxing
// (#7415).
test "a generic callback returning Bool is unboxed as an operand of xor, and, or and implies" {
  assertEqual(viaGeneric(true, { p -> toString(p() xor true) }, false), "true", "xor, false operand")
  assertEqual(viaGeneric(true, { p -> toString(p() xor true) }, true), "false", "xor, true operand")
  assertEqual(viaGeneric(true, { p -> toString(p() and true) }, false), "false", "and value")
  assertEqual(viaGeneric(true, { p -> toString(false or p()) }, false), "false", "or value")
  assertEqual(viaGeneric(true, { p -> toString(true or p()) }, false), "true", "or value, short-circuit")
}
