/// Env-var and file-probe helpers for the self-hosted verifier.
///
/// Exposed as `Lyric.Emitter.VerifierEnv.*` so the stdlib kernel can
/// target them via `@externTarget`.  Returns empty string / false
/// rather than null so Lyric callers never receive a null reference.
module Lyric.Emitter.VerifierEnv

/// Read an environment variable; returns "" if the variable is unset.
let getEnv (name: string) : string =
    System.Environment.GetEnvironmentVariable(name) |> Option.ofObj |> Option.defaultValue ""
