namespace Lyric.Lexer

/// A position in source. Offset is a 0-based byte offset into the
/// (UTF-8) source. Line and Column are 1-based.
type Position =
    { Offset: int
      Line:   int
      Column: int }

module Position =

    let initial : Position =
        { Offset = 0; Line = 1; Column = 1 }

    /// Advance past a single ASCII character that is not a newline.
    let advanceChar (p: Position) : Position =
        { p with
            Offset = p.Offset + 1
            Column = p.Column + 1 }

    /// Advance past a single LF newline. (CR is normalised away by the
    /// lexer's input pipeline before positions are computed.)
    let advanceNewline (p: Position) : Position =
        { Offset = p.Offset + 1
          Line   = p.Line + 1
          Column = 1 }

/// A half-open span [Start, End) over the source.
type Span =
    { Start: Position
      End:   Position }
    member this.Length = this.End.Offset - this.Start.Offset

module Span =

    let make (start: Position) (endP: Position) : Span =
        { Start = start; End = endP }

    /// A zero-length span at the given position. Useful for synthetic
    /// tokens (e.g. STMT_END inserted by the lexer at end of input).
    let pointAt (p: Position) : Span =
        { Start = p; End = p }
