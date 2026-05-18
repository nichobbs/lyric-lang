namespace Lyric.Lexer

type DiagnosticSeverity =
    | DiagError
    | DiagWarning

/// A suggested text edit attached to a diagnostic (used by LSP code actions).
type TextEdit =
    { /// The source span to replace.
      EditSpan: Span
      /// The replacement text.
      NewText: string }

/// A diagnostic produced during lexing, type-checking, or code generation.
/// The lexer keeps producing tokens after recoverable errors so the parser
/// can run downstream and surface further problems in a single pass.
///
/// Extended for LSP: `Help` carries a one-line hint, `Related` carries
/// secondary spans (e.g. conflicting declarations), and `Fix` carries a
/// machine-applicable edit for IDE code-action support.
type Diagnostic =
    { Severity: DiagnosticSeverity
      Code:     string                    // e.g. "L0001"
      Message:  string
      Span:     Span
      Help:     string option             // supplementary hint shown after the message
      Related:  (Span * string) list      // secondary spans with labels
      Fix:      TextEdit option }         // machine-applicable edit for LSP code actions

module Diagnostic =

    let error code msg span =
        { Severity = DiagError; Code = code; Message = msg; Span = span
          Help = None; Related = []; Fix = None }

    let warning code msg span =
        { Severity = DiagWarning; Code = code; Message = msg; Span = span
          Help = None; Related = []; Fix = None }

    let withHelp help (d: Diagnostic) = { d with Help = Some help }
    let withRelated related (d: Diagnostic) = { d with Related = related }
    let withFix fix (d: Diagnostic) = { d with Fix = Some fix }
