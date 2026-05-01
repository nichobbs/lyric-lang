/// `lyric-lsp` entry point.  Reads JSON-RPC frames from stdin and
/// writes them to stdout per the Microsoft Language Server Protocol's
/// stdio transport.  No CLI flags in the bootstrap — point your editor
/// at this binary and the rest happens over the JSON-RPC stream.
module Lyric.Lsp.Program

open System

[<EntryPoint>]
let main _argv =
    // Configure stdout / stdin to bypass console echo and treat the
    // streams as raw byte channels.  Without this, the JSON payload
    // would get any platform-native line-ending munging applied.
    Console.OutputEncoding <- System.Text.Encoding.UTF8
    let stdin'  = Console.OpenStandardInput()
    let stdout' = Console.OpenStandardOutput()
    Server.runLoop stdin' stdout'
    0
