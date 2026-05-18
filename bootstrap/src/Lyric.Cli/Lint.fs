/// `lyric lint` — style and quality checks for Lyric source files.
///
/// Domain logic has been ported to the self-hosted `Lyric.Lint` package
/// (`lyric-compiler/lyric/lint/lint.l`).  This file retains only the
/// F#-side types and the diagnostic renderer so `Program.fs` and
/// `SelfHostedLint.fs` share a common result shape without depending on
/// reflection on Lyric union types.
///
/// Diagnostic codes (implemented in Lyric.Lint):
///   L001  PascalCase required for type names.
///   L002  camelCase required for function names.
///   L003  Missing doc comment on a `pub` item.
///   L004  `TODO` or `FIXME` found in a doc comment.
///   L005  `pub func` has no requires/ensures contracts.
module Lyric.Cli.Lint

open Lyric.Lexer

type LintSeverity = LintError | LintWarning

type LintDiagnostic =
    { Code:     string
      Severity: LintSeverity
      Message:  string
      Span:     Span }

type LintResult =
    { Diagnostics: LintDiagnostic list }

/// Render a lint diagnostic in the `<code> <sev> [line:col]: message` format.
let renderDiagnostic (d: LintDiagnostic) : string =
    let sev =
        match d.Severity with
        | LintError   -> "error"
        | LintWarning -> "warning"
    sprintf "%s %s [%d:%d]: %s"
        d.Code sev d.Span.Start.Line d.Span.Start.Column d.Message
