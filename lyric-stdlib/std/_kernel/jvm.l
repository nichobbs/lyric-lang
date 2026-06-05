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
// ── Implementation (Q-J012) ───────────────────────────────────────────────
// Implemented as a JVM codegen intrinsic in `lowerCatchIntrinsic`
// (`compiler/lyric/jvm/codegen.l`).  When the JVM codegen sees
// `catch({ -> body })`, it macroexpands the call to an inline try-catch:
//
//   [tryStart]:
//     <inline body> → value on stack
//     ASTORE resultSlot
//     NEW Std/Core/Result$Ok  DUP  ALOAD resultSlot
//     INVOKESPECIAL Result$Ok.<init>(Object)V
//     GOTO afterL
//   [tryEnd]:
//   [catchStart]:                        // java/lang/Exception on stack
//     ASTORE exSlot
//     NEW Std/Core/Result$Err  DUP  ALOAD exSlot
//     INVOKESPECIAL Result$Err.<init>(Object)V
//     GOTO afterL
//   LTryCatch(tryStart, tryEnd, catchStart, "java/lang/Exception")
//   [afterL]:                            // Ok or Err on stack
//
// Limitation: the lambda body must not contain an explicit `return` statement.
// Passing a non-literal function value falls through to a general static call
// which will fail at JVM load time (no generated implementation body).
@stable(since="1.0")
pub func catch[T](action: func(): T): Result[T, JvmException] = ()
