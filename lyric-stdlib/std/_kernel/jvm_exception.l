// std/_kernel/jvm_exception.l — JVM-target extern boundary for
// Java checked-exception wrapping (docs/31-maven-linking.md §5, D052).
//
// `JvmException` is the canonical type callers see when a Java
// method's checked exception propagates across the FFI boundary.
// The JVM emitter wraps every checked-exception-declaring Java method
// return in `Result[T, JvmException]`; unchecked exceptions
// (`RuntimeException` / `Error` subclasses) propagate as unrecoverable
// bugs rather than `Result` arms.
//
// This file is JVM-target only.  The .NET-target build never loads it;
// it is guarded by the same target-gating mechanism as other
// platform-specific kernel modules.  Per docs/14-native-stdlib-plan.md
// Decision F (D038): every `@externTarget` here counts toward the
// kernel cap.
//
// Internal: only `Std.Jvm` (and the JVM emitter's call-site wrapper
// codegen) should import this; do not use directly from application
// packages.

@axiom("java.lang.Exception is the Java checked-exception root; \
        JvmException wraps it for Lyric callers at the FFI boundary \
        per docs/31-maven-linking.md §5")
package Std.JvmExceptionHost

// The canonical JVM exception type.  Represents any Java
// `java.lang.Exception` (or subclass) caught at the FFI boundary.
// Backed by `java.lang.Exception` on the JVM; the Lyric type is
// opaque to application code (no structural matching on subtypes —
// open-hierarchy subtype matching is Q-J010).
extern type JvmException = "java.lang.Exception"

// Return the exception's detail message, or the empty string when
// `getMessage()` returns null.  Routes to `java.lang.Throwable`
// because `Exception extends Throwable` and `getMessage` is declared
// on `Throwable`.
@externTarget("java.lang.Throwable.getMessage")
pub func jvmExceptionMessage(e: in JvmException): String = ()

// Return the causing exception, or `null` when there is no cause.
// The JVM emitter wraps the null return in `Option` at the call site;
// callers see `JvmException option`.
@externTarget("java.lang.Throwable.getCause")
pub func jvmExceptionCause(e: in JvmException): JvmException = ()

// Return the fully-qualified Java class name of the exception
// (e.g. `"java.io.FileNotFoundException"`).  Routes through a static
// helper in the Lyric JVM runtime JAR because Lyric's @externTarget
// mechanism does not support chained instance dispatch
// (`getClass().getName()`).  The helper is:
//   `lyric.runtime.jvm.ExceptionHelper.typeName(Throwable) → String`
@externTarget("lyric.runtime.jvm.ExceptionHelper.typeName")
pub func jvmExceptionTypeName(e: in JvmException): String = ()
