package Lyric.Cli.Lsp

import Std.Core
import Lyric.Lsp as Lsp

// Dispatch to the self-hosted LSP stdio loop (`lyric-compiler/lyric/lsp.l`).
// Isolated in its own package so `cli_main` need not import the heavy
// `Lyric.Lsp` surface, keeping the dispatcher assembly's string heap small.
pub func cmdLsp(): Int {
  Lsp.lspRunLoop()
  0
}
