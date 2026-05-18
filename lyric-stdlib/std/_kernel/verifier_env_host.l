// std/_kernel/verifier_env_host.l — null-safe environment variable
// lookup for the self-hosted verifier.
//
// Wraps System.Environment.GetEnvironmentVariable through
// Lyric.Emitter.VerifierEnv.getEnv (which converts null → "").
// Only Std.VerifierEnvHost and, transitively, Lyric.Verifier should
// import this.

@axiom("System.Environment.GetEnvironmentVariable with null → empty-string safety")
package Std.VerifierEnvHost

import Std.Core

@externTarget("Lyric.Emitter.VerifierEnv.getEnv")
pub func hostGetEnv(name: in String): String = ()

@externTarget("System.OperatingSystem.IsWindows")
pub func hostIsWindows(): Bool = ()
