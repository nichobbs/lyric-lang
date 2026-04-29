/// Public entry point of the Lyric MSIL emitter.
///
/// Up through E4: every top-level `func` lowers to a static method
/// on a synthesised `<Program>` type, with parameter and return
/// types taken from the type checker's `ResolvedSignature`. The
/// host `Main(string[]) -> int` calls Lyric's `main` and returns 0.
module Lyric.Emitter.Emitter

open System
open System.Collections.Generic
open System.IO
open System.Reflection
open System.Reflection.Emit
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Parser.Ast
open Lyric.TypeChecker
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

/// Define a static method header on `programTy` matching the resolved
/// signature. Body is filled in by `emitFunctionBody` afterwards.
let private defineMethodHeader
        (programTy: TypeBuilder)
        (fn: FunctionDecl)
        (sg: ResolvedSignature) : MethodBuilder =
    let paramTypes =
        sg.Params
        |> List.map (fun p -> TypeMap.toClrType p.Type)
        |> List.toArray
    let returnType = TypeMap.toClrReturnType sg.Return
    let mb =
        programTy.DefineMethod(
            fn.Name,
            MethodAttributes.Public ||| MethodAttributes.Static,
            returnType,
            paramTypes)
    // Name each parameter so reflection / debuggers see them. Static
    // method params are 0-indexed; SetParameter uses 1-indexed.
    sg.Params
    |> List.iteri (fun i p ->
        mb.DefineParameter(i + 1, ParameterAttributes.None, p.Name) |> ignore)
    mb

/// Emit a function body. Handles three shapes: an explicit block, an
/// expression-bodied function, and the `= { ... }` lambda quirk
/// where the parser wraps a block inside a zero-arg ELambda.
///
/// For non-Unit functions whose body is a block, the trailing SExpr
/// (if any) is treated as the implicit return value — matching
/// Lyric's "last expression is the value" rule for block bodies.
let private emitFunctionBody
        (mb: MethodBuilder)
        (fn: FunctionDecl)
        (sg: ResolvedSignature)
        (funcs: Dictionary<string, MethodBuilder>) : unit =
    let il = mb.GetILGenerator()
    let returnTy = TypeMap.toClrReturnType sg.Return
    let paramList =
        sg.Params
        |> List.map (fun p -> p.Name, TypeMap.toClrType p.Type)
    let ctx = Codegen.FunctionCtx.make il returnTy paramList funcs

    // Helper: emit a block, treating the trailing SExpr as the
    // function's return value when the function isn't Unit-typed.
    let emitBodyBlock (blk: Block) =
        let isVoidReturn = returnTy = typeof<System.Void>
        let lastIdx = List.length blk.Statements - 1
        Codegen.FunctionCtx.pushScope ctx
        blk.Statements
        |> List.iteri (fun i stmt ->
            if not isVoidReturn && i = lastIdx then
                match stmt.Kind with
                | SExpr e ->
                    let _ = Codegen.emitExpr ctx e
                    il.Emit(OpCodes.Ret)
                | _ ->
                    Codegen.emitStatement ctx stmt
            else
                Codegen.emitStatement ctx stmt)
        Codegen.FunctionCtx.popScope ctx
        // If the block didn't end in a Ret (Unit-returning, or a
        // non-Unit body that ended on a non-expression statement
        // like an explicit `return`), emit the appropriate ret.
        if isVoidReturn then
            il.Emit(OpCodes.Ret)

    match fn.Body with
    | None ->
        if returnTy = typeof<System.Void> then il.Emit(OpCodes.Ret)
        else
            // Defaulted return for an empty body — load `default` of
            // the return type and ret. Phase 1 punt: emit `0`.
            il.Emit(OpCodes.Ldc_I4_0)
            il.Emit(OpCodes.Ret)
    | Some (FBBlock blk) ->
        emitBodyBlock blk
    | Some (FBExpr ({ Kind = ELambda ([], blk) })) ->
        emitBodyBlock blk
    | Some (FBExpr e) ->
        let resultTy = Codegen.emitExpr ctx e
        if returnTy = typeof<System.Void> then
            if resultTy <> typeof<System.Void> then il.Emit(OpCodes.Pop)
            il.Emit(OpCodes.Ret)
        else
            il.Emit(OpCodes.Ret)

/// Synthesise a host-runnable `Main(string[]) -> int` that calls the
/// Lyric `main` function. If `main` returns `Unit`, Main returns 0;
/// if it returns Int, Main returns that value.
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
    if lyricMain.ReturnType = typeof<System.Void> then
        il.Emit(OpCodes.Ldc_I4_0)
    elif lyricMain.ReturnType <> typeof<int> then
        // Drop whatever Lyric main returned and exit 0. Refining
        // this to honour a Lyric-side exit code lands when we wire
        // contracts and Result.
        il.Emit(OpCodes.Pop)
        il.Emit(OpCodes.Ldc_I4_0)
    il.Emit(OpCodes.Ret)
    mb

/// Emit the assembly. Layout: a single `<package-name>.Program` type
/// carrying every Lyric `func` as a static method, plus a host
/// `Main` entry point that delegates to Lyric's `main`.
let private emitAssembly
        (sf: SourceFile)
        (sigs: Map<string, ResolvedSignature>)
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

        // Pass A — define every header. We need them all visible
        // before bodies emit so calls (including recursion and
        // forward references) can resolve.
        let methodTable = Dictionary<string, MethodBuilder>()
        for fn in funcs do
            match Map.tryFind fn.Name sigs with
            | Some sg ->
                let mb = defineMethodHeader programTy fn sg
                methodTable.[fn.Name] <- mb
            | None ->
                // Synthesise a unit signature for functions the type
                // checker didn't resolve (e.g. parser recovery).
                let synthSig : ResolvedSignature =
                    { Generics = []; Params = []; Return = TyPrim PtUnit
                      IsAsync = false; Span = fn.Span }
                let mb = defineMethodHeader programTy fn synthSig
                methodTable.[fn.Name] <- mb

        // Pass B — emit bodies.
        for fn in funcs do
            let sg =
                match Map.tryFind fn.Name sigs with
                | Some s -> s
                | None ->
                    { Generics = []; Params = []; Return = TyPrim PtUnit
                      IsAsync = false; Span = fn.Span }
            emitFunctionBody methodTable.[fn.Name] fn sg methodTable

        let lyricMain = methodTable.["main"]
        let hostMain  = defineHostEntryPoint programTy lyricMain
        programTy.CreateType() |> ignore
        Backend.save ctx (Some (hostMain :> MethodInfo))
        []

/// Emit a Lyric source string to a persistent assembly.
let emit (req: EmitRequest) : EmitResult =
    let parsed   = parse req.Source
    let checked' = Lyric.TypeChecker.Checker.check parsed.File

    let upstream = parsed.Diagnostics @ checked'.Diagnostics
    let parserFatal =
        upstream
        |> List.exists (fun d ->
            d.Severity = DiagError && d.Code.StartsWith "P")

    if parserFatal then
        { OutputPath = None; Diagnostics = upstream }
    else
        let emitDiags = emitAssembly parsed.File checked'.Signatures req
        let emitFatal =
            emitDiags |> List.exists (fun d -> d.Severity = DiagError)
        let outputPath = if emitFatal then None else Some req.OutputPath
        { OutputPath  = outputPath
          Diagnostics = upstream @ emitDiags }
