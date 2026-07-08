//! std/_kernel_jvm/environment_host.l - JVM host boundary for process state.
//!
//! Mirrors _kernel/environment_host.l for the JVM target.  Pure Lyric over
//! JVM auto-FFI against `java.lang.System`, replacing a `lyric.stdlib.jvm.
//! EnvHost` shim class that never existed at runtime (the `extern package`
//! mechanism it used is a no-op in both the type checker and both codegens
//! -- same elimination as the `console_host.l` / `time_host.l` /
//! `collections_host.l` / `file_host.l` rewrites).
//!
//! `System.getenv(String)` returns null on a missing key, mapped to `None`
//! by `hostGetVarOpt` below (matching the .NET kernel's `??`-based Option
//! seam).
//!
//! `hostExit` calls `System.exit(int)` directly: `Never` erases to `void`
//! on the JVM (`Jvm.Codegen.typeExprToJvm`), which is exactly `System.exit`'s
//! real return type, so no "throw after call" trick is needed.
//!
//! `hostGetCommandLineArgs` has no extern-bindable host equivalent: unlike
//! .NET's `System.Environment.GetCommandLineArgs()`, the JDK exposes no
//! process-wide argv retrieval -- the JVM entry-point wrapper only threads
//! argv into the user's own `main` parameter (`Jvm.Codegen`'s `hasMain`
//! synthesis), with no static holder field any other function could read.
//! Implementing this needs new codegen (a synthesized static field plus an
//! entry-point store instruction), not an extern binding -- tracked as
//! issue #5377. Panics with a clear diagnostic rather than the generic
//! "unsupported method" crash the old extern package no-op produced.
@axiom("java.lang.System operations conform to their documented JVM contracts")
package Std.EnvironmentHost

import Std.Core

extern type JSystem = "java.lang.System"

// The .NET runtime shared-framework directory has no JVM equivalent.
// Returns "" so that callers following the "empty = unavailable" convention
// (documented in Std.Environment.runtimeDirectory) behave correctly on JVM.
pub func hostRuntimeDirectory(): String {
  ""
}

// The .NET runtime identifier is a .NET-only concept with no JVM equivalent.
// Returns "" per the "empty = unavailable" convention.
pub func hostRuntimeIdentifier(): String {
  ""
}

// SetEnvironmentVariable has no portable JVM equivalent (the JVM exposes no
// `setenv(3)` equivalent without unsafe reflection).  This is a no-op stub
// so JVM programs that import Std.Environment still compile.
pub func hostSetEnvironmentVariable(key: in String, value: in String): Unit {
  ()
}

// Option seam — the exception-free surface every kernel twin implements
// (issue #4752).  `System.getenv` returns null for an unset variable;
// Lyric has no null pattern (issue #4775), so unset is detected via
// `??` with a NUL-string marker: POSIX and Windows environment blocks
// are NUL-delimited, so no real value can ever equal "\0".
pub func hostGetVarOpt(key: in String): Option[String] {
  val v = JSystem.getenv(key) ?? "\u{0000}"
  if v == "\u{0000}" {
    None
  } else {
    Some(value = v)
  }
}

// See the module header: the JDK has no process-wide argv retrieval, and
// implementing one needs new entry-point codegen, not an extern binding.
pub func hostGetCommandLineArgs(): slice[String] {
  panic(
    "Std.Environment.args() is not implemented on --target jvm: the JDK exposes no process-wide argv retrieval, and capturing it needs new entry-point codegen (a synthesized static holder field), not an extern binding. Tracked as issue #5377. Use the `main(args: slice[String])` parameter directly instead."
  )
}

pub func hostExit(code: in Int): Never {
  JSystem.exit(code)
}
