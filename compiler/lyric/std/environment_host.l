// std/environment_host.l - trusted host boundary for process state.
//
// Environment variables, command-line arguments, and process exit are
// host-global effects. Public wrappers in Std.Environment keep the
// recoverable parts Result-based and make process termination explicit.

@axiom("System.Environment operations conform to their documented .NET contracts")
package Std.EnvironmentHost

extern package System.Environment {
  pub func getEnvironmentVariable(key: in String): String?
    requires: key.length > 0

  pub func getCommandLineArgs(): slice[String]

  // Terminates the current process. Public wrappers expose this as
  // Never/does-not-return even if the host method has a void signature.
  pub func exit(code: in Int): Never
}
