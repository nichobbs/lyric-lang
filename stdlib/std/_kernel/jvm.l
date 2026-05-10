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
// Bootstrap note: `Error` subclasses (OutOfMemoryError etc.) are NOT caught
// and propagate as unrecoverable JVM errors, consistent with the conservative
// default in docs/31-maven-linking.md Q-J012.  Phase 6 will revisit whether
// `Error` coverage is needed.
//
// Implementation: routes to `lyric.runtime.jvm.ExceptionHelper.catch`, a
// static helper in the JVM stdlib kernel JAR that accepts a
// `java.util.concurrent.Callable<Object>` and returns the Result value.
// The JVM emitter inserts the necessary boxing/unboxing at the call site.
@experimental
@externTarget("lyric.runtime.jvm.ExceptionHelper.catch")
pub generic[T] func catch(action: func(): T): Result[T, JvmException] = ()
