/// Lyric parser entry point.
///
/// Phase 1 milestone M1.1 work-in-progress: this module currently
/// provides the public `parse` function and the `ParseResult` type;
/// the actual recursive-descent parsing of items, types, expressions
/// and so on is added in subsequent slices (P2 through P9 per the
/// project plan). For now `parse` runs the lexer, performs no further
/// analysis, and reports a single diagnostic if the input contains
/// any non-trivial tokens.
module Lyric.Parser.Parser

open Lyric.Lexer
open Lyric.Lexer.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Cursor

/// A parsed source file together with the diagnostics produced during
/// parsing. The lexer's diagnostics are merged into the same list so
/// callers see a unified error report.
type ParseResult =
    { File:        SourceFile
      Diagnostics: Diagnostic list }

let private syntheticSpan = Span.pointAt Position.initial

let private emptySourceFile : SourceFile =
    let placeholder =
        { Path =
              { Segments = []
                Span     = syntheticSpan }
          Span = syntheticSpan }
    { ModuleDoc            = []
      FileLevelAnnotations = []
      Package              = placeholder
      Imports              = []
      Items                = []
      Span                 = syntheticSpan }

/// Parse a Lyric source string into a SourceFile plus diagnostics.
let parse (source: string) : ParseResult =
    let lexed  = lex source
    let cursor = Cursor.make lexed.Tokens

    let diags = ResizeArray<Diagnostic>(lexed.Diagnostics)

    // Skip any leading STMT_END tokens the lexer inserts at the very
    // start of input. They carry no information here and would cause
    // the "unconsumed tokens" diagnostic to fire on otherwise-empty
    // files that contain only blank lines.
    Cursor.skipStmtEnds cursor |> ignore

    if not (Cursor.isAtEnd cursor) then
        diags.Add(
            Diagnostic.error "P0001"
                "parser not yet implemented; tokens past lexer remain unconsumed"
                (Cursor.peekSpan cursor))

    { File        = emptySourceFile
      Diagnostics = List.ofSeq diags }
