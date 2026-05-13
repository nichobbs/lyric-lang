// std/_kernel/jvm.l — Std.Jvm package: JVM-target escape hatches.
//
// JVM-target only.  The .NET-target build never loads this file.
// Per docs/14-native-stdlib-plan.md Decision F: every @externTarget here
// counts toward the kernel cap.
//
// See docs/31-maven-linking.md Q-J012 for design rationale.

@axiom("Std.Jvm provides JVM-target escape hatches for interoperating with \
        Java exception semantics per docs/31-maven-linking.md Q-J012")
package Std.Jvm

import Std.JvmExceptionHost

// Wrap `action()` in a Java try-catch.  If `action` completes normally,
// returns `Ok(result)`.  If any `java.lang.Exception` propagates (checked
// or unchecked), returns `Err(exception)`.
//
// `Error` subclasses (OutOfMemoryError etc.) are NOT caught and propagate
// as unrecoverable JVM errors — consistent with docs/31-maven-linking.md Q-J012.
//
// ── Implementation status (Q-J012) ────────────────────────────────────────
// This declaration is a stub.  Two prerequisites must land before it works:
//
//   1. ELambda support in JVM codegen (`compiler/lyric/jvm/codegen.l`
//      `lowerExpr` case ELambda) — so callers can write
//      `Std.Jvm.catch({ -> … })`.  A `func(): T` value must lower to a
//      `java.util.concurrent.Callable` whose `call()` invokes the body.
//
//   2. The `catch` intrinsic in `lowerBuiltinOrStaticCall` (codegen.l) —
//      marked TODO-JvmCatch.  It should emit a try-catch block around
//      `invokeinterface Callable.call()`, wrap the result in `Ok`, and on
//      `java/lang/Exception` wrap the caught reference directly in `Err`
//      (JvmException is `extern type … = "java.lang.Exception"`, so the
//      exception object is the JvmException value — no wrapping needed).
//
// Until both prerequisites ship, any call to this function in --target jvm
// mode will fail at JVM load time: `lyric.runtime.jvm.ExceptionHelper` does
// not exist.  The @externTarget below is superseded by the intrinsic once
// those prerequisites land; remove it at that point.
@experimental
@externTarget("lyric.runtime.jvm.ExceptionHelper.catch")
pub generic[T] func catch(action: func(): T): Result[T, JvmException] = ()
