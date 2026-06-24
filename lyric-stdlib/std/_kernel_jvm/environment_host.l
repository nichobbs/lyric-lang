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
// Returns "" per the "empty = unavailable" convention; the only caller
// (apphost pack selection in Lyric.AppHost) is a .NET-only build path, so the
// JVM empty string is never exercised in practice.
pub func hostRuntimeIdentifier(): String {
  ""
}

// SetEnvironmentVariable has no portable JVM equivalent (the JVM exposes no
// `setenv(3)` equivalent without unsafe reflection).  This is a no-op stub
// so JVM programs that import Std.Environment still compile; in practice the
// Lyric CLI (the only caller of setVar) always runs on .NET.
pub func hostSetEnvironmentVariable(key: in String, value: in String): Unit {
  ()
}
