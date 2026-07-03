//! std/_kernel/verifier_env_host.l — null-safe environment variable
//! lookup for the self-hosted verifier.
//!
//! Null-safe environment-variable lookup, composed in pure Lyric (#1493)
//! over the audited `Std.EnvironmentHost.hostGetVarOpt` seam — no F#
//! `Lyric.Emitter.VerifierEnv` shim.  An unset variable (and any host
//! failure) converts to "".
//! Only Std.VerifierEnvHost and, transitively, Lyric.Verifier should import this.
package Std.VerifierEnvHost

import Std.Core
import Std.EnvironmentHost as Env

pub func hostGetEnv(name: in String): String {
  match Env.hostGetVarOpt(name) {
    case Some(v) -> v
    case None -> ""
  }
}

@externTarget("System.OperatingSystem.IsWindows")
pub func hostIsWindows(): Bool = ()
