/// `lyric-lsp` entry point.  Reads JSON-RPC frames from stdin and writes
/// them to stdout per the Language Server Protocol's stdio transport.
/// Delegates to the self-hosted `Lyric.Lsp` package via `SelfHostedLsp`.
module Lyric.Lsp.Program

open System

[<EntryPoint>]
let main _argv =
    // UTF-8 on stdout so non-ASCII content in JSON bodies is transmitted
    // correctly; the self-hosted run loop reads stdin byte-by-byte via
    // Console.Read() which returns UTF-16 code units.
    Console.OutputEncoding <- Text.Encoding.UTF8
    SelfHostedLsp.runLoop ()
    0
