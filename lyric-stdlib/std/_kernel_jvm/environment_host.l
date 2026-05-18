// std/_kernel_jvm/environment_host.l - JVM host boundary for process state.
//
// Mirrors _kernel/environment_host.l for the JVM target.
//
// getEnvironmentVariable routes to java.lang.System.getenv(String),
// which returns null on a missing key (mapped to None by String?).
//
// getCommandLineArgs is routed through a shim because the JVM does not
// expose a global argv; the shim stores the array passed to main() at
// JVM entry and returns it here.
//
// exit routes through a shim that calls java.lang.System.exit(code)
// and then throws an unreachable exception to satisfy the JVM bytecode
// verifier's return-type check for a Never-typed function.

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
