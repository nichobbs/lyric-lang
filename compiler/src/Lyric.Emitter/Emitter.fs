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

/// Pull every top-level `IRecord` / `IExposedRec` out of a parsed
/// source file.
let private recordItems (sf: SourceFile) : RecordDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IRecord r | IExposedRec r -> Some r
        | _ -> None)

/// Pull every top-level `IEnum` out of a parsed source file.
let private enumItems (sf: SourceFile) : EnumDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IEnum e -> Some e
        | _ -> None)

/// Define a CLR enum type backing one Lyric enum. Each case becomes
/// a `Public Static Literal` field with a sequential ordinal value,
/// matching the strategy doc's §8.2 "variant-free unions" lowering.
let private defineEnum
        (md: ModuleBuilder)
        (nsName: string)
        (ed: EnumDecl) : Records.EnumInfo =
    let fullName =
        if String.IsNullOrEmpty nsName then ed.Name
        else nsName + "." + ed.Name
    let eb = md.DefineEnum(fullName, TypeAttributes.Public, typeof<int32>)
    let cases =
        ed.Cases
        |> List.mapi (fun i c ->
            eb.DefineLiteral(c.Name, box i) |> ignore
            { Records.EnumCase.Name = c.Name; Records.EnumCase.Ordinal = i })
    let ty = eb.CreateType()
    { Records.EnumInfo.Name  = ed.Name
      Records.EnumInfo.Type  = ty
      Records.EnumInfo.Cases = cases }

/// Define the CLR class + fields + ctor for one Lyric record. The
/// resulting `RecordInfo` goes into the per-emit `RecordTable` so
/// codegen can resolve constructors and field reads.
let private defineRecord
        (md: ModuleBuilder)
        (nsName: string)
        (symbols: SymbolTable)
        (rd: RecordDecl) : Records.RecordInfo =
    let fullName =
        if String.IsNullOrEmpty nsName then rd.Name
        else nsName + "." + rd.Name
    let tb =
        md.DefineType(
            fullName,
            TypeAttributes.Public ||| TypeAttributes.Sealed,
            typeof<obj>)
    // Resolve each field's type via the typechecker's resolver. This
    // gives us a `Lyric.TypeChecker.Type` that TypeMap projects onto
    // a CLR System.Type.
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    let fieldDecls =
        rd.Members
        |> List.choose (fun m ->
            match m with
            | RMField fd -> Some fd
            | _          -> None)
    let fields =
        fieldDecls
        |> List.map (fun fd ->
            let lty =
                Resolver.resolveType symbols resolveCtx scratchDiags fd.Type
            let cty = TypeMap.toClrType lty
            let fb =
                tb.DefineField(
                    fd.Name,
                    cty,
                    FieldAttributes.Public ||| FieldAttributes.InitOnly)
            { Records.RecordField.Name  = fd.Name
              Records.RecordField.Type  = cty
              Records.RecordField.Field = fb })
    // Constructor: takes every field in declaration order, stores
    // them onto `this`.
    let ctorParamTypes =
        fields
        |> List.map (fun f -> f.Type)
        |> List.toArray
    let ctor =
        tb.DefineConstructor(
            MethodAttributes.Public,
            CallingConventions.Standard,
            ctorParamTypes)
    let cil = ctor.GetILGenerator()
    // base ctor (System.Object::.ctor)
    cil.Emit(OpCodes.Ldarg_0)
    let objCtor = typeof<obj>.GetConstructor([||])
    match Option.ofObj objCtor with
    | Some c -> cil.Emit(OpCodes.Call, c)
    | None   -> failwith "object's no-arg ctor not found"
    // store each arg onto `this`
    fields
    |> List.iteri (fun i f ->
        cil.Emit(OpCodes.Ldarg_0)
        cil.Emit(OpCodes.Ldarg, i + 1)
        cil.Emit(OpCodes.Stfld, f.Field))
    cil.Emit(OpCodes.Ret)
    { Records.RecordInfo.Name   = rd.Name
      Records.RecordInfo.Type   = tb
      Records.RecordInfo.Fields = fields
      Records.RecordInfo.Ctor   = ctor }

/// Define a static method header on `programTy` matching the resolved
/// signature. Body is filled in by `emitFunctionBody` afterwards.
let private defineMethodHeader
        (programTy: TypeBuilder)
        (lookup: TypeId -> System.Type option)
        (fn: FunctionDecl)
        (sg: ResolvedSignature) : MethodBuilder =
    let paramTypes =
        sg.Params
        |> List.map (fun p -> TypeMap.toClrTypeWith lookup p.Type)
        |> List.toArray
    let returnType = TypeMap.toClrReturnTypeWith lookup sg.Return
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
        (lookup: TypeId -> System.Type option)
        (funcs: Dictionary<string, MethodBuilder>)
        (records: Records.RecordTable)
        (enums: Records.EnumTable)
        (enumCases: Records.EnumCaseLookup) : unit =
    let il = mb.GetILGenerator()
    let returnTy = TypeMap.toClrReturnTypeWith lookup sg.Return
    let paramList =
        sg.Params
        |> List.map (fun p -> p.Name, TypeMap.toClrTypeWith lookup p.Type)
    let ctx =
        Codegen.FunctionCtx.make
            il returnTy paramList funcs records enums enumCases

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
/// `Main` entry point that delegates to Lyric's `main`. Each Lyric
/// record becomes its own sealed CLR class.
let private emitAssembly
        (sf: SourceFile)
        (sigs: Map<string, ResolvedSignature>)
        (symbols: SymbolTable)
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

        // Pass 0 — record + enum types. Defined before functions so
        // signatures can mention them, and the runtime sees them
        // ready when the host calls newobj / loads case constants.
        let recordTable = Records.RecordTable()
        let enumTable   = Records.EnumTable()
        let enumCases   = Records.EnumCaseLookup()
        let typeIdToClr = Dictionary<TypeId, System.Type>()
        for rd in recordItems sf do
            let info = defineRecord ctx.Module nsName symbols rd
            recordTable.[rd.Name] <- info
            symbols.TryFind rd.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- info.Type :> System.Type)
        for ed in enumItems sf do
            let info = defineEnum ctx.Module nsName ed
            enumTable.[ed.Name] <- info
            for c in info.Cases do
                // Bare `Red` and qualified `Color.Red` both resolve.
                enumCases.[c.Name] <- (info, c)
                enumCases.[ed.Name + "." + c.Name] <- (info, c)
            symbols.TryFind ed.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- info.Type)
        let lookup =
            fun (id: TypeId) ->
                match typeIdToClr.TryGetValue id with
                | true, t  -> Some t
                | false, _ -> None

        let programTy =
            ctx.Module.DefineType(
                typeName,
                TypeAttributes.Public
                ||| TypeAttributes.Sealed
                ||| TypeAttributes.Abstract,
                typeof<obj>)

        // Pass A — define every header.
        let methodTable = Dictionary<string, MethodBuilder>()
        for fn in funcs do
            match Map.tryFind fn.Name sigs with
            | Some sg ->
                let mb = defineMethodHeader programTy lookup fn sg
                methodTable.[fn.Name] <- mb
            | None ->
                let synthSig : ResolvedSignature =
                    { Generics = []; Params = []; Return = TyPrim PtUnit
                      IsAsync = false; Span = fn.Span }
                let mb = defineMethodHeader programTy lookup fn synthSig
                methodTable.[fn.Name] <- mb

        // Pass B — emit bodies.
        for fn in funcs do
            let sg =
                match Map.tryFind fn.Name sigs with
                | Some s -> s
                | None ->
                    { Generics = []; Params = []; Return = TyPrim PtUnit
                      IsAsync = false; Span = fn.Span }
            emitFunctionBody
                methodTable.[fn.Name] fn sg lookup
                methodTable recordTable enumTable enumCases

        let lyricMain = methodTable.["main"]
        let hostMain  = defineHostEntryPoint programTy lyricMain

        // Finalise every type so the persisted PE captures their
        // metadata. Records are sealed first so their TypeBuilders
        // are valid types when programTy.CreateType references them.
        for kv in recordTable do
            kv.Value.Type.CreateType() |> ignore
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
        let emitDiags =
            emitAssembly
                parsed.File
                checked'.Signatures
                checked'.Symbols
                req
        let emitFatal =
            emitDiags |> List.exists (fun d -> d.Severity = DiagError)
        let outputPath = if emitFatal then None else Some req.OutputPath
        { OutputPath  = outputPath
          Diagnostics = upstream @ emitDiags }
