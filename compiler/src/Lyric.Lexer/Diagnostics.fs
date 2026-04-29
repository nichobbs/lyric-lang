namespace Lyric.Lexer

type DiagnosticSeverity =
    | DiagError
    | DiagWarning

/// A diagnostic produced during lexing. The lexer keeps producing tokens
/// after recoverable errors (it inserts whatever placeholder makes the
/// stream still readable) so the parser can run downstream and surface
/// further problems in a single pass.
type Diagnostic =
    { Severity: DiagnosticSeverity
      Code:     string                  // e.g. "L0001"
      Message:  string
      Span:     Span }

module Diagnostic =

    let error code msg span =
        { Severity = DiagError; Code = code; Message = msg; Span = span }

    let warning code msg span =
        { Severity = DiagWarning; Code = code; Message = msg; Span = span }
