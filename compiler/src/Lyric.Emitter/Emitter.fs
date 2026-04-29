/// Public entry point of the Lyric MSIL emitter.
///
/// E1 — Hello-World vertical slice. Recognises a `func main(): Unit`
/// in the source, emits a `<Program>` static class with a `main` method
/// containing the body's IL, and a host-runnable `Main` entry point
/// that calls it.
module Lyric.Emitter.Emitter

open System
open System.IO
open System.Reflection
open System.Reflection.Emit
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Parser.Ast
open Lyric.Emitter.Backend

type EmitResult =
    { OutputPath:  string option
      Diagnostics: Diagnostic list }

type EmitRequest =
    { Source:       string
      AssemblyName: string
      OutputPath:   string }

let private err (code: string) (msg: string) (span: Span) : Diagnostic =
    Diagnostic.error code msg span

/// Pull every top-level `IFunc` out of a parsed source file.
let private functionItems (sf: SourceFile) : FunctionDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IFunc fn -> Some fn
        | _ -> None)

/// Emit the body of a Lyric function into the given ILGenerator. E1
/// supports only `Unit`-returning functions whose body is a block
/// (`func name(): Unit { stmts }`) or an expression body
/// (`func name(): Unit = expr`).
let private emitFunctionBody (il: ILGenerator) (fn: FunctionDecl) : unit =
    match fn.Body with
    | None ->
        // No body — nothing to emit. The caller's `ret` still fires.
        ()
    | Some (FBBlock blk) ->
        Codegen.emitBlock il blk
    | Some (FBExpr ({ Kind = ELambda ([], blk) })) ->
        // `func foo(): T = { ... }` parses as FBExpr containing a
        // zero-argument ELambda; treat the lambda's body as the
        // function's block.
        Codegen.emitBlock il blk
    | Some (FBExpr e) ->
        Codegen.emitExpr il e

/// Define and emit one Lyric `func` as a static method on the
/// `<Program>` type. Returns the resulting MethodBuilder so the
/// host entry point can call it.
let private defineLyricFunction
        (programTy: TypeBuilder)
        (fn: FunctionDecl) : MethodBuilder =
    // E1 hard-codes the return type as void (Unit). Real signature
    // lowering arrives in E4.
    let mb =
        programTy.DefineMethod(
            fn.Name,
            MethodAttributes.Public ||| MethodAttributes.Static,
            typeof<Void>,
            [||])
    let il = mb.GetILGenerator()
    emitFunctionBody il fn
    il.Emit(OpCodes.Ret)
    mb

/// Synthesise a host-runnable `Main(string[]) -> int` that calls the
/// Lyric `main` function and exits with code 0.
let private defineHostEntryPoint
        (programTy: TypeBuilder)
        (lyricMain: MethodBuilder) : MethodBuilder =
    let mb =
        programTy.DefineMethod(
            "Main",
            MethodAttributes.Public ||| MethodAttributes.Static,
            typeof<int>,
            [| typeof<string[]> |])
    let il = mb.GetILGenerator()
    il.Emit(OpCodes.Call, lyricMain)
    il.Emit(OpCodes.Ldc_I4_0)
    il.Emit(OpCodes.Ret)
    mb

/// Emit the assembly. E1 layout: a single `<package-name>.Program`
/// type carrying a `main` method (Lyric body) and a `Main` method
/// (host entry point).
let private emitAssembly
        (sf: SourceFile)
        (req: EmitRequest) : Diagnostic list =
    let funcs = functionItems sf
    match funcs |> List.tryFind (fun f -> f.Name = "main") with
    | None ->
        [ err "E0001"
            "no `func main(): Unit` found — Phase 1 emit needs an entry point"
            sf.Span ]
    | Some _ ->
        let desc =
            { Name        = req.AssemblyName
              Version     = Version(0, 1, 0, 0)
              OutputPath  = req.OutputPath }
        let ctx = Backend.create desc
        let nsName = String.concat "." sf.Package.Path.Segments
        let typeName =
            if String.IsNullOrEmpty nsName then "Program"
            else nsName + ".Program"
        let programTy =
            ctx.Module.DefineType(
                typeName,
                TypeAttributes.Public
                ||| TypeAttributes.Sealed
                ||| TypeAttributes.Abstract,
                typeof<obj>)
        // Pass A: define every Lyric func as a static method.
        let definedFuncs =
            funcs
            |> List.map (fun fn -> fn.Name, defineLyricFunction programTy fn)
            |> Map.ofList
        // Pass B: synthesise the host `Main` entry point.
        let lyricMain = Map.find "main" definedFuncs
        let hostMain  = defineHostEntryPoint programTy lyricMain
        programTy.CreateType() |> ignore
        Backend.save ctx (Some (hostMain :> MethodInfo))
        []

/// Emit a Lyric source string to a persistent assembly.
let emit (req: EmitRequest) : EmitResult =
    let parsed   = parse req.Source
    let _checked = Lyric.TypeChecker.Checker.check parsed.File

    let upstream = parsed.Diagnostics @ _checked.Diagnostics
    // Phase 1 only blocks emit on parser-level diagnostics. The type
    // checker is permissive by design (no stdlib, soft name
    // resolution) so T-errors are surfaced but tolerated; the
    // emitter raises hard if it encounters something it can't
    // generate IL for.
    let parserFatal =
        upstream
        |> List.exists (fun d ->
            d.Severity = DiagError && d.Code.StartsWith "P")

    if parserFatal then
        { OutputPath = None; Diagnostics = upstream }
    else
        let emitDiags = emitAssembly parsed.File req
        let emitFatal =
            emitDiags |> List.exists (fun d -> d.Severity = DiagError)
        let outputPath = if emitFatal then None else Some req.OutputPath
        { OutputPath  = outputPath
          Diagnostics = upstream @ emitDiags }
