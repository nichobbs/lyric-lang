/// Public entry point of the Lyric MSIL emitter.
///
/// Phase 1 milestone M1.3 — work in progress. The current state
/// (E0 scaffolding) compiles a skeleton emitter that wires together
/// the parser, type checker, and persisted-assembly backend without
/// yet emitting any user code. E1 fills in Hello World.
module Lyric.Emitter.Emitter

open System
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Parser.Ast
open Lyric.Emitter.Backend

/// Result of an emit run.
///   * `OutputPath`  — the path the .dll was written to (when no fatal
///                      diagnostics fired).
///   * `Diagnostics` — the union of parser, type-checker, and emitter
///                      diagnostics. The emitter contributes codes in
///                      the `E####` range; everything else is
///                      pass-through.
type EmitResult =
    { OutputPath:  string option
      Diagnostics: Diagnostic list }

/// Description of one emit invocation.
type EmitRequest =
    { Source:      string
      AssemblyName: string
      OutputPath:  string }

/// Emit a single Lyric source string to a persistent assembly. Phase 1
/// targets only single-file programs; multi-package linking lands in
/// M1.4.
let emit (req: EmitRequest) : EmitResult =
    let parsed = parse req.Source
    // Type-checking is required (no untyped emit path) but the actual
    // T-pass result isn't consumed by E0 — E1 onwards reads symbols
    // and signatures from the checker to drive codegen.
    let _checked = Lyric.TypeChecker.Checker.check parsed.File

    let allDiags = parsed.Diagnostics @ _checked.Diagnostics

    // Bail out early on any non-recoverable diagnostic. Phase 1 uses
    // the heuristic "fatal = any error severity" — refining this to
    // "fatal = any P/T diagnostic of class Critical" is M1.4 work.
    let hasErrors =
        allDiags
        |> List.exists (fun d -> d.Severity = DiagError)

    if hasErrors then
        { OutputPath = None; Diagnostics = allDiags }
    else
        // E0 stub: open the backend so we exercise the
        // PersistedAssemblyBuilder path, but emit no types yet. E1
        // will replace this with a real codegen walk.
        let desc =
            { Name        = req.AssemblyName
              Version     = Version(0, 1, 0, 0)
              OutputPath  = req.OutputPath }
        let _ctx = Backend.create desc
        // Intentionally not saving yet — without an entry point the
        // generated PE wouldn't be runnable, and E0 isn't ready to
        // synthesise one. E1 wires the entry-point method and calls
        // `Backend.save`.

        { OutputPath = None
          Diagnostics = allDiags }
