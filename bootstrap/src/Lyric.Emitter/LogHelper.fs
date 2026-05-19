/// Helper for Std.Log: write a diagnostic log message.
/// Exposed as `Lyric.Emitter.LogHelper.write` so log_host.l can
/// target it via `@externTarget`.  Always loaded in the AppDomain
/// when emitting or running self-hosted Lyric code.
module Lyric.Emitter.LogHelper

/// Write a log entry to stderr in the format "[LEVEL] message".
let write (level: string) (message: string) : unit =
    System.Console.Error.WriteLine(sprintf "[%s] %s" (level.ToUpperInvariant()) message)
