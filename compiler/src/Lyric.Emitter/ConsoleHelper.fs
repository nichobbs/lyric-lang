/// Helper for Std.Console: write to stderr.
/// Exposed as `Lyric.Emitter.ConsoleHelper.writeErrorLine` so the
/// stdlib kernel can target it via `@externTarget`.  Always loaded in
/// the AppDomain when emitting or running self-hosted Lyric code.
module Lyric.Emitter.ConsoleHelper

/// Write `text` followed by the platform newline to stderr.
let writeErrorLine (text: string) : unit =
    System.Console.Error.WriteLine text
