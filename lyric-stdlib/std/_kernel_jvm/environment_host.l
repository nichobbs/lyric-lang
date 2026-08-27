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
//! process-wide argv retrieval API. Issue #5377 closed this with new JVM
//! codegen instead of an extern binding: `Jvm.Codegen`'s `hasMain`
//! entry-point synthesis (`codegen/06_items.l`) stores the incoming
//! `String[]` into a package-independent holder class
//! (`__LyricJvmRuntime.commandLineArgs`, `LPRuntimeArgsHolder` in
//! `Jvm.Lowering`) before forwarding argv to the Lyric `main` -- so the
//! value is captured even when `main()` itself declares no `argv`
//! parameter. Every *call site* naming `hostGetCommandLineArgs` is then
//! intercepted by `lowerBuiltinOrStaticCall` (`codegen/04_calls.l`,
//! following the same bare-name compiler-intrinsic convention already
//! used for `intToLong`/`stringToUtf8Bytes`) and lowered directly to a
//! `getstatic` read of that field -- the function body below is therefore
//! never actually invoked at runtime; it exists only so the package
//! type-checks and to fail loudly (rather than silently) in the
//! unreachable case where some future refactor removes the call-site
//! interception without updating this fallback.
@axiom("java.lang.System operations conform to their documented JVM contracts")
package Std.EnvironmentHost

import Std.Core

extern type JSystem = "java.lang.System"

// .NET's `System.AppContext.BaseDirectory` (the entry-ASSEMBLY's own
// directory, for resolving resources packaged alongside the binary) has no
// direct JVM equivalent without reflecting on a loaded class's
// `ProtectionDomain`/`CodeSource` -- and unlike the current working
// directory below, it is NOT interchangeable with `user.dir` (running
// `java -jar /opt/app/app.jar` from an unrelated `cwd` would silently
// return the wrong directory).  Returns "" per the "empty = unavailable"
// convention already used for `hostRuntimeDirectory`/`hostRuntimeIdentifier`
// rather than a plausible-looking but wrong answer.
pub func hostAppBaseDirectory(): String {
  ""
}

// Current working directory of the process — `pwd` on POSIX.  `user.dir`
// is a genuine, real JVM equivalent (guaranteed set at JVM startup), unlike
// `hostAppBaseDirectory` above.
pub func hostCurrentDirectory(): String {
  JSystem.getProperty("user.dir")
}

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
// (issue #4752): absent and error both surface as None here, matching
// `_kernel/environment_host.l`'s `try`/`catch Bug` wrapper exactly (a
// `SecurityManager`-denied `System.getenv` throws on JVM the same way a
// permission failure could on .NET).  `System.getenv` returns null for an
// unset variable; Lyric has no null pattern (issue #4775), so unset is
// detected via `??` with a NUL-string marker: POSIX and Windows
// environment blocks are NUL-delimited, so no real value can ever equal
// "\0".
pub func hostGetVarOpt(key: in String): Option[String] {
  try {
    val v = JSystem.getenv(key) ?? "\u{0000}"
    if v == "\u{0000}" {
      None
    } else {
      Some(value = v)
    }
  } catch Bug as _ {
    None
  }
}

// See the module header: every real call site is intercepted at compile
// time and lowered directly to a `getstatic __LyricJvmRuntime.
// commandLineArgs` read (issue #5377) -- this body never actually runs.
pub func hostGetCommandLineArgs(): slice[String] {
  panic(
    "Std.Environment.args() reached its unreachable JVM fallback body -- the compile-time call-site interception (Jvm.Codegen.lowerBuiltinOrStaticCall, issue #5377) should have replaced this call with a direct getstatic read. This indicates a compiler regression, not a missing feature."
  )
}

pub func hostExit(code: in Int): Never {
  JSystem.exit(code)
}
