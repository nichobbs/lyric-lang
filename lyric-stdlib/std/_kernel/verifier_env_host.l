// std/_kernel/verifier_env_host.l — null-safe environment variable
// lookup for the self-hosted verifier.
//
// Null-safe environment-variable lookup, composed in pure Lyric (#1493)
// over the existing audited `Std.EnvironmentHost.hostGetEnvironmentVariable`
// BCL extern — no F# `Lyric.Emitter.VerifierEnv` shim.  `GetEnvironmentVariable`
// returns null when the variable is unset; this converts that to "".
// Only Std.VerifierEnvHost and, transitively, Lyric.Verifier should import this.

package Std.VerifierEnvHost

import Std.EnvironmentHost as Env

pub func hostGetEnv(name: in String): String {
  Env.hostGetEnvironmentVariable(name) ?? ""
}

@externTarget("System.OperatingSystem.IsWindows")
pub func hostIsWindows(): Bool = ()
