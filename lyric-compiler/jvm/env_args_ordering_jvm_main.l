//! env_args_ordering_jvm_main.l — `Std.Environment.args()` class-init
//! ordering-hazard check for `--target jvm` (#6587).
//!
//! Not a `@test_module`: the hazard this pins only manifests through real
//! JVM class-initialization ordering (`<clinit>` running ahead of the
//! entry-point wrapper's `putstatic`), which `lyric test`'s in-process
//! bridge does not reproduce — mirrors `env_args_jvm_main.l` /
//! `regex_redos_jvm_main.l`'s standalone-jar-under-`java` shape.
//!
//! `badArgv` is a module-level `val` calling `Std.Environment.args()`.
//! Per the JVM spec (JLS 12.4.1), invoking a class's own static method
//! (here: the synthesized JVM entry point `public static void
//! main(String[])`, itself living on this file's compiled class) forces
//! that class's `<clinit>` to run to completion FIRST — so `badArgv`'s
//! initializer runs, and calls `Std.Environment.args()`, strictly before
//! `main()`'s body (and therefore before its first instruction, the
//! `putstatic __LyricJvmRuntime.commandLineArgs = args` that
//! `Jvm.Codegen`'s `hasMain` synthesis emits) ever executes. This is
//! exactly the ordering hazard `_kernel_jvm/environment_host.l`'s module
//! header documents: `__LyricJvmRuntime.commandLineArgs` is still its
//! JVM zero-init default (`null`) at the point `badArgv` reads it.
//!
//! Before the #6587 fix, `hostGetCommandLineArgs`'s call-site interception
//! (`Jvm.Codegen.lowerBuiltinOrStaticCall`, `codegen/04_calls.l`) lowered
//! straight to an unguarded `getstatic`, so this crashed with a bare
//! `NullPointerException` (wrapped in an opaque `ExceptionInInitializerError`
//! at class-load) and no indication of the real cause. The fix guards that
//! read with an explicit null check that panics with a diagnostic naming
//! the ordering hazard — main() is never reached either way (the panic
//! happens during `<clinit>`, before the JVM can even resolve/invoke
//! `main`), so this program's `main` body is intentionally unreachable and
//! exists only so the file has an entry point to build. CI builds this
//! file, runs the jar, asserts a NON-zero exit (the panic aborts class
//! init before `main` starts), and greps stderr for the diagnostic message
//! rather than a bare "NullPointerException" trace.
package Main

import Std.Console
import Std.Environment

val badArgv: slice[String] = args()

func main(): Unit {
  println("FAIL: reached main() with argc=" + badArgv.count.toString() + " -- expected a class-init-time panic (#6587)")
}
