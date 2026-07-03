//! std/_kernel_jvm/environment_host.l - JVM host boundary for process state.
//!
//! Mirrors _kernel/environment_host.l for the JVM target.
//!
//! getEnvironmentVariable routes to java.lang.System.getenv(String),
//! which returns null on a missing key (mapped to None by String?).
//!
//! getCommandLineArgs is routed through a shim because the JVM does not
//! expose a global argv; the shim stores the array passed to main() at
//! JVM entry and returns it here.
//!
//! exit routes through a shim that calls java.lang.System.exit(code)
//! and then throws an unreachable exception to satisfy the JVM bytecode
//! verifier's return-type check for a Never-typed function.
@axiom("lyric.stdlib.jvm.EnvHost operations conform to their documented JVM contracts")
package Std.EnvironmentHost

import Std.Core

extern package lyric.stdlib.jvm.EnvHost {
  pub func getEnvironmentVariable(key: in String): String?
    requires: key.length > 0

  // Returns the argv array captured at JVM entry by the Lyric runtime.
  pub func getCommandLineArgs(): slice[String]

  // Calls System.exit(code) then throws to satisfy the verifier.
  pub func exit(code: in Int): Never
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
// (issue #4752).  `System.getenv` returns null for an unset variable;
// Lyric has no null pattern (issue #4775), so unset is detected via
// `??` with a NUL-string marker: POSIX and Windows environment blocks
// are NUL-delimited, so no real value can ever equal "\0".
pub func hostGetVarOpt(key: in String): Option[String] {
  val v = getEnvironmentVariable(key) ?? "\u{0000}"
  if v == "\u{0000}" {
    None
  } else {
    Some(value = v)
  }
}
