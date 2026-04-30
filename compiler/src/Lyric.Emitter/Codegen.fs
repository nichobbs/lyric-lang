/// IL generation for expression and statement bodies.
///
/// E3 introduces a `FunctionCtx` that carries the per-function IL
/// state: the scope stack of local variables, the loop-label stack
/// for break/continue, and the enclosing return type so `return` can
/// validate at IL-time. `emitExpr` / `emitStatement` / `emitBlock`
/// all take this context now.
module Lyric.Emitter.Codegen

open System
open System.Collections.Generic
open System.Reflection
open System.Reflection.Emit
open Lyric.Lexer
open Lyric.Parser.Ast

type private ClrType = System.Type

/// A single loop frame — break exits, continue rejoins the head.
type LoopFrame =
    { BreakLabel:    Label
      ContinueLabel: Label }

/// Per-function emit context. Mutable on purpose: F# expression
/// emission threads through a long mutual-recursion graph and a
/// record makes the call sites unreadable.
type FunctionCtx =
    { IL:         ILGenerator
      ReturnType: ClrType
      Scopes:     Stack<Dictionary<string, LocalBuilder>>
      Loops:      Stack<LoopFrame>
      /// Parameters by name → (CLR-arg-index, declared CLR type).
      Params:     Dictionary<string, int * ClrType>
      /// Same-package functions visible at codegen time. E4 only
      /// resolves single-segment calls; cross-package linking is
      /// M1.4 work.
      Funcs:      Dictionary<string, MethodBuilder>
      /// Resolved signatures for `Funcs`, keyed by name.  Used at call
      /// sites that need Lyric-level param/return types — e.g. the
      /// generic-method type-arg inference path which can't trust
      /// `MethodBuilder.GetParameters()` before the host type is sealed.
      FuncSigs:   Dictionary<string, Lyric.TypeChecker.ResolvedSignature>
      /// Same-package records visible at codegen time. E5 supports
      /// constructor calls and field reads; mutation via `with`
      /// lands in E5 polish.
      Records:    Lyric.Emitter.Records.RecordTable
      /// Same-package enums visible at codegen time.
      Enums:      Lyric.Emitter.Records.EnumTable
      /// `Red` / `Color.Red` → (enum info, case info). E6 only
      /// recognises these for variant-free enums; variant-bearing
      /// unions live below.
      EnumCases:  Lyric.Emitter.Records.EnumCaseLookup
      /// Variant-bearing unions visible at codegen time.
      Unions:     Lyric.Emitter.Records.UnionTable
      /// `Some` / `Option.Some` → (union info, case info). Bare and
      /// qualified spellings both resolve.
      UnionCases: Lyric.Emitter.Records.UnionCaseLookup
      /// Lyric interfaces, keyed by name.
      Interfaces: Lyric.Emitter.Records.InterfaceTable
      /// Distinct types and range subtypes, keyed by name.
      DistinctTypes: Lyric.Emitter.Records.DistinctTypeTable
      /// Projectable opaque types, keyed by opaque type name.
      Projectables: Lyric.Emitter.Records.ProjectableTable
      /// Imported records from precompiled packages (e.g. Std.Core).
      ImportedRecords: Lyric.Emitter.Records.ImportedRecordTable
      /// Imported unions from precompiled packages.
      ImportedUnions: Lyric.Emitter.Records.ImportedUnionTable
      /// Imported union case constructors, both bare and qualified spellings.
      ImportedUnionCases: Lyric.Emitter.Records.ImportedUnionCaseLookup
      /// Imported free-standing functions.
      ImportedFuncs: Lyric.Emitter.Records.ImportedFuncTable
      /// Imported distinct types and their static factories.
      ImportedDistinctTypes: Lyric.Emitter.Records.ImportedDistinctTypeTable
      /// `true` when emitting an instance method (impl method) — at
      /// CLR level arg 0 is `self` and named params shift by one.
      IsInstance: bool
      /// The impl target's CLR type when `IsInstance = true`. Drives
      /// the static type returned by `ESelf` so field reads can
      /// resolve.
      SelfType:   ClrType option
      /// Synthesised single exit point. Every `return` (and the
      /// trailing implicit-return expression) stores into
      /// `ResultLocal` (if non-void) and branches to this label;
      /// the label site emits `ensures:` checks and the actual
      /// `ret`. Set by the emitter before any body codegen runs.
      mutable ReturnLabel: Label option
      /// Where the returned value is stashed before the
      /// `ReturnLabel` block runs. `None` for void-returning
      /// methods.
      mutable ResultLocal: LocalBuilder option
      /// The program TypeBuilder, used to synthesise static
      /// methods for non-capturing lambda expressions.
      ProgramType: TypeBuilder
      /// Resolve a `TypeExpr` from the surface syntax to a CLR type.
      /// Closed over the symbols and type-id lookup from Emitter.fs.
      ResolveType: Lyric.Parser.Ast.TypeExpr -> System.Type }

module FunctionCtx =

    let make
            (il: ILGenerator)
            (returnType: ClrType)
            (paramList: (string * ClrType) list)
            (funcs: Dictionary<string, MethodBuilder>)
            (funcSigs: Dictionary<string, Lyric.TypeChecker.ResolvedSignature>)
            (records: Lyric.Emitter.Records.RecordTable)
            (enums: Lyric.Emitter.Records.EnumTable)
            (enumCases: Lyric.Emitter.Records.EnumCaseLookup)
            (unions: Lyric.Emitter.Records.UnionTable)
            (unionCases: Lyric.Emitter.Records.UnionCaseLookup)
            (interfaces: Lyric.Emitter.Records.InterfaceTable)
            (distinctTypes: Lyric.Emitter.Records.DistinctTypeTable)
            (projectables: Lyric.Emitter.Records.ProjectableTable)
            (importedRecords: Lyric.Emitter.Records.ImportedRecordTable)
            (importedUnions: Lyric.Emitter.Records.ImportedUnionTable)
            (importedUnionCases: Lyric.Emitter.Records.ImportedUnionCaseLookup)
            (importedFuncs: Lyric.Emitter.Records.ImportedFuncTable)
            (importedDistinctTypes: Lyric.Emitter.Records.ImportedDistinctTypeTable)
            (isInstance: bool)
            (selfType: ClrType option)
            (programType: TypeBuilder)
            (resolveType: Lyric.Parser.Ast.TypeExpr -> System.Type) : FunctionCtx =
        let s = Stack<Dictionary<string, LocalBuilder>>()
        s.Push(Dictionary())
        let p = Dictionary<string, int * ClrType>()
        let argShift = if isInstance then 1 else 0
        paramList
        |> List.iteri (fun i (name, ty) -> p.[name] <- (i + argShift, ty))
        { IL           = il
          ReturnType   = returnType
          Scopes       = s
          Loops        = Stack()
          Params       = p
          Funcs        = funcs
          FuncSigs     = funcSigs
          Records      = records
          Enums        = enums
          EnumCases    = enumCases
          Unions       = unions
          UnionCases   = unionCases
          Interfaces   = interfaces
          DistinctTypes = distinctTypes
          Projectables = projectables
          ImportedRecords     = importedRecords
          ImportedUnions      = importedUnions
          ImportedUnionCases  = importedUnionCases
          ImportedFuncs       = importedFuncs
          ImportedDistinctTypes = importedDistinctTypes
          IsInstance   = isInstance
          SelfType     = selfType
          ReturnLabel  = None
          ResultLocal  = None
          ProgramType  = programType
          ResolveType  = resolveType }

    let pushScope (ctx: FunctionCtx) : unit =
        ctx.Scopes.Push(Dictionary())

    let popScope (ctx: FunctionCtx) : unit =
        ctx.Scopes.Pop() |> ignore

    let defineLocal (ctx: FunctionCtx) (name: string) (ty: ClrType) : LocalBuilder =
        let lb = ctx.IL.DeclareLocal(ty)
        let frame = ctx.Scopes.Peek()
        frame.[name] <- lb
        lb

    let tryLookup (ctx: FunctionCtx) (name: string) : LocalBuilder option =
        let mutable found : LocalBuilder option = None
        let arr = ctx.Scopes.ToArray()  // top-down
        let mutable i = 0
        while found.IsNone && i < arr.Length do
            match arr.[i].TryGetValue name with
            | true, lb -> found <- Some lb
            | _        -> ()
            i <- i + 1
        found

    let pushLoop (ctx: FunctionCtx) (frame: LoopFrame) : unit =
        ctx.Loops.Push frame

    let popLoop (ctx: FunctionCtx) : unit =
        ctx.Loops.Pop() |> ignore

    let currentLoop (ctx: FunctionCtx) : LoopFrame option =
        if ctx.Loops.Count = 0 then None else Some (ctx.Loops.Peek())

// ---------------------------------------------------------------------------
// Stdlib bindings.
// ---------------------------------------------------------------------------

let private printlnString : Lazy<MethodInfo> =
    lazy (
        let consoleTy = typeof<Lyric.Stdlib.Console>
        let mi = consoleTy.GetMethod("Println", [| typeof<string> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwith "Lyric.Stdlib.Console::Println(string) not found")

let private printlnAny : Lazy<MethodInfo> =
    lazy (
        let consoleTy = typeof<Lyric.Stdlib.Console>
        let mi = consoleTy.GetMethod("PrintlnAny", [| typeof<obj> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwith "Lyric.Stdlib.Console::PrintlnAny(object) not found")

// ---------------------------------------------------------------------------
// CLR-type predicates used by the binop emitter.
// ---------------------------------------------------------------------------

let private isFloatClr (t: ClrType) : bool =
    t = typeof<single> || t = typeof<double>

let private isUnsignedClr (t: ClrType) : bool =
    t = typeof<byte> || t = typeof<uint16>
    || t = typeof<uint32> || t = typeof<uint64>

// ---------------------------------------------------------------------------
// Literal helpers.
// ---------------------------------------------------------------------------

let private emitLdcI4 (il: ILGenerator) (n: int) : unit =
    match n with
    | -1 -> il.Emit(OpCodes.Ldc_I4_M1)
    | 0  -> il.Emit(OpCodes.Ldc_I4_0)
    | 1  -> il.Emit(OpCodes.Ldc_I4_1)
    | 2  -> il.Emit(OpCodes.Ldc_I4_2)
    | 3  -> il.Emit(OpCodes.Ldc_I4_3)
    | 4  -> il.Emit(OpCodes.Ldc_I4_4)
    | 5  -> il.Emit(OpCodes.Ldc_I4_5)
    | 6  -> il.Emit(OpCodes.Ldc_I4_6)
    | 7  -> il.Emit(OpCodes.Ldc_I4_7)
    | 8  -> il.Emit(OpCodes.Ldc_I4_8)
    | n when n >= -128 && n <= 127 -> il.Emit(OpCodes.Ldc_I4_S, sbyte n)
    | _  -> il.Emit(OpCodes.Ldc_I4, n)

let private intLiteralType (suffix: IntSuffix) : ClrType =
    match suffix with
    | NoIntSuffix | I32 | I16 | I8 -> typeof<int32>
    | I64                          -> typeof<int64>
    | U8                           -> typeof<byte>
    | U16                          -> typeof<uint16>
    | U32                          -> typeof<uint32>
    | U64                          -> typeof<uint64>

let private floatLiteralType (suffix: FloatSuffix) : ClrType =
    match suffix with
    | NoFloatSuffix | F64 -> typeof<double>
    | F32                 -> typeof<single>

let private emitIntLiteral (il: ILGenerator) (value: uint64) (suffix: IntSuffix) : ClrType =
    let ty = intLiteralType suffix
    if ty = typeof<int64> then
        il.Emit(OpCodes.Ldc_I8, int64 value)
    elif ty = typeof<uint64> then
        il.Emit(OpCodes.Ldc_I8, int64 value)
        il.Emit(OpCodes.Conv_U8) |> ignore
    elif ty = typeof<uint32> then
        emitLdcI4 il (int (uint32 value))
        il.Emit(OpCodes.Conv_U4) |> ignore
    elif ty = typeof<uint16> then
        emitLdcI4 il (int (uint16 value))
        il.Emit(OpCodes.Conv_U2) |> ignore
    elif ty = typeof<byte> then
        emitLdcI4 il (int (byte value))
        il.Emit(OpCodes.Conv_U1) |> ignore
    else
        emitLdcI4 il (int value)
    ty

let private emitFloatLiteral (il: ILGenerator) (value: double) (suffix: FloatSuffix) : ClrType =
    let ty = floatLiteralType suffix
    if ty = typeof<single> then il.Emit(OpCodes.Ldc_R4, single value)
    else                        il.Emit(OpCodes.Ldc_R8, value)
    ty

let private boxIfValue (il: ILGenerator) (ty: ClrType) : unit =
    if ty.IsValueType then il.Emit(OpCodes.Box, ty)

// ---------------------------------------------------------------------------
// Read-only type probe.
//
// `peekExprType` returns the CLR type that `emitExpr` *would* push,
// without actually emitting any IL. It only covers the shapes E7
// needs (the seed-element type for an EList literal); call sites
// for other kinds fall back to typeof<obj> so the emit can still
// proceed (the actual element types still drive the emit).
// ---------------------------------------------------------------------------

let rec peekExprType (ctx: FunctionCtx) (e: Lyric.Parser.Ast.Expr) : ClrType =
    match e.Kind with
    | ELiteral (LString _)        -> typeof<string>
    | ELiteral (LBool _)          -> typeof<bool>
    | ELiteral (LInt (_, suffix)) -> intLiteralType suffix
    | ELiteral (LFloat (_, s))    -> floatLiteralType s
    | ELiteral (LChar _)          -> typeof<char>
    | ELiteral LUnit              -> typeof<int32>
    | EParen inner                -> peekExprType ctx inner
    | EPath { Segments = [name] } ->
        match FunctionCtx.tryLookup ctx name with
        | Some lb -> lb.LocalType
        | None ->
            match ctx.Params.TryGetValue name with
            | true, (_, t) -> t
            | _            -> typeof<obj>
    | _ -> typeof<obj>

// ---------------------------------------------------------------------------
// Lambda synthesis helpers.
// ---------------------------------------------------------------------------

let private lambdaSeq = ref 0
let private freshLambdaName () =
    let n = System.Threading.Interlocked.Increment(lambdaSeq)
    sprintf "<lambda_%d>" n

/// Given a CLR delegate type (Func<…> or Action<…>), extract
/// `(paramTypes, returnType)` where returnType is `Void` for Action.
let private dissectDelegateTy (delegateTy: ClrType) : (ClrType[] * ClrType) option =
    if not (delegateTy.IsSubclassOf typeof<System.Delegate>) then None
    else
        let invoke = delegateTy.GetMethod "Invoke"
        match Option.ofObj invoke with
        | None -> None
        | Some m ->
            let pts = m.GetParameters() |> Array.map (fun p -> p.ParameterType)
            Some (pts, m.ReturnType)

/// Build a `Func<…>` or `Action<…>` CLR type from component types.
/// `paramTys` are the delegate's CLR input types; `retTy` is the
/// output type (`Void` → Action family).
let private makeDelegateTy (paramTys: ClrType[]) (retTy: ClrType) : ClrType =
    if retTy = typeof<System.Void> then
        match paramTys.Length with
        | 0 -> typeof<System.Action>
        | 1 -> typedefof<System.Action<_>>.MakeGenericType(paramTys)
        | 2 -> typedefof<System.Action<_,_>>.MakeGenericType(paramTys)
        | 3 -> typedefof<System.Action<_,_,_>>.MakeGenericType(paramTys)
        | 4 -> typedefof<System.Action<_,_,_,_>>.MakeGenericType(paramTys)
        | n -> failwithf "Delegate lowering: Action<%d> not supported" n
    else
        let allTys = Array.append paramTys [| retTy |]
        match allTys.Length with
        | 1 -> typedefof<System.Func<_>>.MakeGenericType(allTys)
        | 2 -> typedefof<System.Func<_,_>>.MakeGenericType(allTys)
        | 3 -> typedefof<System.Func<_,_,_>>.MakeGenericType(allTys)
        | 4 -> typedefof<System.Func<_,_,_,_>>.MakeGenericType(allTys)
        | 5 -> typedefof<System.Func<_,_,_,_,_>>.MakeGenericType(allTys)
        | n -> failwithf "Delegate lowering: Func<%d> not supported" n

// ---------------------------------------------------------------------------
// Expression / statement emission.
// ---------------------------------------------------------------------------

let rec emitExpr (ctx: FunctionCtx) (e: Expr) : ClrType =
    let il = ctx.IL
    match e.Kind with

    // ---- literals -----------------------------------------------------

    | ELiteral (LString s) ->
        il.Emit(OpCodes.Ldstr, s)
        typeof<string>

    | ELiteral (LBool b) ->
        emitLdcI4 il (if b then 1 else 0)
        typeof<bool>

    | ELiteral (LInt (value, suffix)) ->
        emitIntLiteral il value suffix

    | ELiteral (LFloat (value, suffix)) ->
        emitFloatLiteral il value suffix

    | ELiteral (LChar c) ->
        emitLdcI4 il c
        typeof<char>

    | ELiteral LUnit ->
        emitLdcI4 il 0
        typeof<int32>

    // ---- list literal -------------------------------------------------

    | EList items ->
        // Element type comes from the first element's read-only
        // probe; empty lists default to obj[].
        let elemTy =
            match items with
            | [] -> typeof<obj>
            | first :: _ -> peekExprType ctx first
        emitLdcI4 il (List.length items)
        il.Emit(OpCodes.Newarr, elemTy)
        items
        |> List.iteri (fun i item ->
            il.Emit(OpCodes.Dup)
            emitLdcI4 il i
            let _ = emitExpr ctx item
            il.Emit(OpCodes.Stelem, elemTy))
        elemTy.MakeArrayType()

    // ---- indexing -----------------------------------------------------

    | EIndex (recv, [idx]) ->
        let recvTy = emitExpr ctx recv
        let _ = emitExpr ctx idx
        if recvTy.IsArray then
            let elemTy =
                match Option.ofObj (recvTy.GetElementType()) with
                | Some t -> t
                | None   -> typeof<obj>
            il.Emit(OpCodes.Ldelem, elemTy)
            elemTy
        else
            failwithf "E7 codegen: indexing on non-array %s" recvTy.Name

    | EIndex (_, idxs) ->
        failwithf "E7 codegen: multi-index access not yet supported (%d indices)"
            (List.length idxs)

    // ---- tuple literal ------------------------------------------------

    | ETuple [single] -> emitExpr ctx single

    | ETuple items when List.length items >= 2 && List.length items <= 7 ->
        let elemTypes = ResizeArray<ClrType>()
        for item in items do
            let t = emitExpr ctx item
            elemTypes.Add t
        let openTy =
            match items.Length with
            | 2 -> typedefof<System.ValueTuple<_, _>>
            | 3 -> typedefof<System.ValueTuple<_, _, _>>
            | 4 -> typedefof<System.ValueTuple<_, _, _, _>>
            | 5 -> typedefof<System.ValueTuple<_, _, _, _, _>>
            | 6 -> typedefof<System.ValueTuple<_, _, _, _, _, _>>
            | _ -> typedefof<System.ValueTuple<_, _, _, _, _, _, _>>
        let argsArr = elemTypes.ToArray()
        let closedTy = openTy.MakeGenericType(argsArr)
        let ctor = closedTy.GetConstructor(argsArr)
        match Option.ofObj ctor with
        | Some c ->
            il.Emit(OpCodes.Newobj, c)
            closedTy
        | None ->
            failwithf "E7 codegen: ValueTuple ctor not found for %d args" items.Length

    | ETuple items ->
        failwithf "E7 codegen: tuple of %d elements not yet supported"
            (List.length items)

    | EParen inner -> emitExpr ctx inner

    // ---- self ---------------------------------------------------------

    | ESelf when ctx.IsInstance ->
        il.Emit(OpCodes.Ldarg_0)
        match ctx.SelfType with
        | Some t -> t
        | None   -> typeof<obj>

    | ESelf ->
        failwith "E12 codegen: 'self' used outside of an impl method"

    // ---- await (blocking shim per D035) -------------------------------

    | EAwait inner ->
        // Per the M1.4 blocking shim: emit the Task[T]-shaped value,
        // call GetAwaiter().GetResult() and propagate the unwrapped
        // type. When the inner expression's static type is a
        // TypeBuilder-instantiated generic Task<T> (because T is a
        // user-defined record/union still under construction), we
        // can't call .GetMethod on it directly — we have to go
        // through `TypeBuilder.GetMethod(constructed, openMethod)`.
        let taskTy = emitExpr ctx inner
        let isClosedGenericOnTaskBuilder =
            taskTy.IsGenericType
            && (taskTy.GetGenericTypeDefinition() = typedefof<System.Threading.Tasks.Task<_>>)
            && (taskTy.GetGenericArguments() |> Array.exists (fun t ->
                    t :? TypeBuilder
                    || (t.IsGenericType && t.GetGenericArguments() |> Array.exists (fun a -> a :? TypeBuilder))))
        let elemTy =
            if taskTy.IsGenericType
               && taskTy.GetGenericTypeDefinition() = typedefof<System.Threading.Tasks.Task<_>>
            then taskTy.GetGenericArguments().[0]
            else typeof<System.Void>
        let resolveGenericTask () =
            // For Task<TypeBuilder...> we need TypeBuilder.GetMethod
            // with the open-generic method.
            let openGetAwaiter =
                let mi = typedefof<System.Threading.Tasks.Task<_>>.GetMethod("GetAwaiter")
                match Option.ofObj mi with
                | Some m -> m
                | None -> failwith "E14 codegen: Task<>.GetAwaiter open-generic not found"
            let closedGetAwaiter =
                TypeBuilder.GetMethod(taskTy, openGetAwaiter)
            // The awaiter type is TaskAwaiter<elemTy>; resolve
            // GetResult on its open generic.
            let openAwaiterTy =
                typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>>
            let closedAwaiterTy = openAwaiterTy.MakeGenericType([| elemTy |])
            let openGetResult =
                let mi = openAwaiterTy.GetMethod("GetResult")
                match Option.ofObj mi with
                | Some m -> m
                | None -> failwith "E14 codegen: TaskAwaiter<>.GetResult not found"
            let closedGetResult =
                TypeBuilder.GetMethod(closedAwaiterTy, openGetResult)
            closedGetAwaiter, closedAwaiterTy, closedGetResult, elemTy

        let getAwaiter, awaiterTy, getResult, returnedTy =
            if isClosedGenericOnTaskBuilder then
                resolveGenericTask ()
            else
                let ga =
                    match Option.ofObj (taskTy.GetMethod("GetAwaiter")) with
                    | Some m -> m
                    | None -> failwithf "E14 codegen: %s.GetAwaiter not found" taskTy.Name
                let aw = ga.ReturnType
                let gr =
                    match Option.ofObj (aw.GetMethod("GetResult")) with
                    | Some m -> m
                    | None -> failwithf "E14 codegen: %s.GetResult not found" aw.Name
                ga, aw, gr, gr.ReturnType
        il.Emit(OpCodes.Callvirt, getAwaiter)
        let awLoc = FunctionCtx.defineLocal ctx "__awaiter" awaiterTy
        il.Emit(OpCodes.Stloc, awLoc)
        il.Emit(OpCodes.Ldloca, awLoc)
        il.Emit(OpCodes.Call, getResult)
        returnedTy

    // ---- result (in ensures clauses) ----------------------------------

    | EResult ->
        match ctx.ResultLocal with
        | Some loc ->
            il.Emit(OpCodes.Ldloc, loc)
            loc.LocalType
        | None ->
            failwith "E15 codegen: 'result' used outside of an ensures clause"

    // ---- old() — Phase 4 work, rejected here --------------------------

    | EOld _ ->
        failwith "E15 codegen: 'old(_)' is a Phase 4 feature (T0080)"

    // ---- projectable opaque: u.toView() -------------------------------

    | ECall ({ Kind = EMember (recv, "toView") }, []) ->
        let recvTy = emitExpr ctx recv
        let proj =
            ctx.Projectables.Values
            |> Seq.tryFind (fun p ->
                match Option.ofObj p.ToViewMethod.DeclaringType with
                | Some dt -> dt = recvTy
                | None    -> false)
        match proj with
        | Some p ->
            il.Emit(OpCodes.Callvirt, p.ToViewMethod)
            p.ViewType.Type :> ClrType
        | None ->
            failwithf "M2.2 codegen: receiver %s is not a @projectable opaque type"
                recvTy.Name

    // ---- distinct type static factory / derive helper -----------------
    //
    // `TypeName.from(x)`, `.tryFrom(x)`, `.default()`, or any other
    // static method on the distinct type's struct (the struct is sealed
    // in Pass 0.5, so reflection works to discover derived statics).
    | ECall ({ Kind = EMember ({ Kind = EPath { Segments = [typeName] } }, methodName) }, args)
        when ctx.DistinctTypes.ContainsKey typeName ->
        let info = ctx.DistinctTypes.[typeName]
        match methodName with
        | "from" ->
            let arg =
                match args with
                | [CAPositional ex] | [CANamed (_, ex, _)] -> ex
                | _ -> failwithf "M2.1 codegen: %s.from expects exactly one argument" typeName
            let _ = emitExpr ctx arg
            il.Emit(OpCodes.Call, info.FromMethod)
            info.Type :> ClrType
        | "tryFrom" ->
            match info.TryFromMethod with
            | Some m ->
                let arg =
                    match args with
                    | [CAPositional ex] | [CANamed (_, ex, _)] -> ex
                    | _ -> failwithf "M2.1 codegen: %s.tryFrom expects exactly one argument" typeName
                let _ = emitExpr ctx arg
                il.Emit(OpCodes.Call, m)
                m.ReturnType
            | None ->
                failwithf "M2.1 codegen: %s.tryFrom not available (no range constraint)" typeName
        | other ->
            // Look up the method by name on the (already sealed) struct.
            let mi = info.Type.GetMethod(other)
            match Option.ofObj mi with
            | Some m when m.IsStatic ->
                for a in args do
                    let payload =
                        match a with
                        | CAPositional ex | CANamed (_, ex, _) -> ex
                    let _ = emitExpr ctx payload
                    ()
                il.Emit(OpCodes.Call, m)
                if m.ReturnType = typeof<System.Void> then typeof<System.Void>
                else m.ReturnType
            | _ ->
                failwithf "M2.1 codegen: distinct type '%s' has no static method '%s'"
                    typeName other

    // ---- method-style call (callvirt on interface or class method) ----

    | ECall ({ Kind = EMember (recv, methodName) }, args) ->
        let recvTy = emitExpr ctx recv
        // Try to find an interface method with this name.
        let ifaceMethod =
            ctx.Interfaces.Values
            |> Seq.collect (fun i -> i.Members |> List.map (fun m -> i, m))
            |> Seq.tryFind (fun (_, m) -> m.Name = methodName)
        let mi : MethodInfo option =
            match ifaceMethod with
            | Some (_, m) -> Some (m.Method :> MethodInfo)
            | None ->
                // Fall back to a method on the receiver's CLR type
                // by reflection. This catches impl-method calls where
                // we have a concrete target type.
                recvTy.GetMethods()
                |> Array.tryFind (fun m ->
                    m.Name = methodName && not m.IsStatic)
        match mi with
        | Some method ->
            // For value-type instance methods the receiver must be a
            // managed pointer, not a value.  Stash the value to a temp
            // and reload its address, then dispatch via `call` (callvirt
            // is illegal on non-virtual struct methods).
            let useCallNotCallvirt =
                recvTy.IsValueType
            if useCallNotCallvirt then
                let recvLoc = FunctionCtx.defineLocal ctx "__recv_val" recvTy
                il.Emit(OpCodes.Stloc, recvLoc)
                il.Emit(OpCodes.Ldloca, recvLoc)
            for a in args do
                let payload =
                    match a with
                    | CAPositional ex | CANamed (_, ex, _) -> ex
                let _ = emitExpr ctx payload
                ()
            if useCallNotCallvirt then
                il.Emit(OpCodes.Call, method)
            else
                il.Emit(OpCodes.Callvirt, method)
            if method.ReturnType = typeof<System.Void> then
                typeof<System.Void>
            else
                method.ReturnType
        | None ->
            failwithf "E12 codegen: no method '%s' on %s"
                methodName recvTy.Name

    // ---- field access -------------------------------------------------

    | EMember ({ Kind = EPath { Segments = [enumName] } }, caseName)
        when ctx.Enums.ContainsKey enumName ->
        // `Color.Green` — qualified enum case literal.
        let info = ctx.Enums.[enumName]
        match info.Cases |> List.tryFind (fun c -> c.Name = caseName) with
        | Some c ->
            emitLdcI4 il c.Ordinal
            info.Type
        | None ->
            failwithf "E6 codegen: enum '%s' has no case '%s'" enumName caseName

    | EMember (recv, fieldName) ->
        let recvTy = emitExpr ctx recv
        // Arrays / slices: `.length` lowers to `ldlen; conv.i4`.
        if recvTy.IsArray && fieldName = "length" then
            il.Emit(OpCodes.Ldlen)
            il.Emit(OpCodes.Conv_I4)
            typeof<int32>
        else
            // Distinct types: `.value` reads the backing Value field.
            let distinctInfo =
                ctx.DistinctTypes.Values
                |> Seq.tryFind (fun d -> (d.Type :> ClrType) = recvTy)
            match distinctInfo with
            | Some d when fieldName = "value" ->
                il.Emit(OpCodes.Ldfld, d.ValueField)
                d.ValueField.FieldType
            | Some d ->
                failwithf "M2.1 codegen: distinct type '%s' has no member '%s' (only '.value')"
                    d.Name fieldName
            | None ->
                // Records: walk the records dict to find a match by
                // CLR receiver type.
                let info =
                    ctx.Records.Values
                    |> Seq.tryFind (fun r -> (r.Type :> ClrType) = recvTy)
                match info with
                | Some r ->
                    match r.Fields |> List.tryFind (fun f -> f.Name = fieldName) with
                    | Some f ->
                        il.Emit(OpCodes.Ldfld, f.Field)
                        f.Type
                    | None ->
                        failwithf "E5/E7 codegen: record '%s' has no field '%s'"
                            r.Name fieldName
                | None ->
                    failwithf "E5/E7 codegen: receiver type %s is not a known record or distinct type"
                        recvTy.Name

    // ---- variable read ------------------------------------------------

    | EPath { Segments = [name] } ->
        // Order: parameter slot → local → enum case → nullary union
        // case → fallthrough.
        match FunctionCtx.tryLookup ctx name with
        | Some lb ->
            il.Emit(OpCodes.Ldloc, lb)
            lb.LocalType
        | None ->
            match ctx.Params.TryGetValue name with
            | true, (idx, pty) ->
                il.Emit(OpCodes.Ldarg, idx)
                pty
            | _ ->
                match ctx.EnumCases.TryGetValue name with
                | true, (info, c) ->
                    emitLdcI4 il c.Ordinal
                    info.Type
                | _ ->
                    match ctx.UnionCases.TryGetValue name with
                    | true, (info, caseInfo) when caseInfo.Fields.IsEmpty ->
                        // Nullary case literal — `None` / `Leaf` etc.
                        il.Emit(OpCodes.Newobj, caseInfo.Ctor)
                        info.Type :> ClrType
                    | _ ->
                        // Imported nullary case (cross-assembly).
                        match ctx.ImportedUnionCases.TryGetValue name with
                        | true, (info, caseInfo) when caseInfo.Fields.IsEmpty ->
                            il.Emit(OpCodes.Newobj, caseInfo.Ctor)
                            info.Type
                        | _ ->
                            failwithf "E4 codegen: unknown name '%s'" name

    | EPath { Segments = [enumName; caseName] }
        when ctx.Enums.ContainsKey enumName ->
        let info = ctx.Enums.[enumName]
        match info.Cases |> List.tryFind (fun c -> c.Name = caseName) with
        | Some c ->
            emitLdcI4 il c.Ordinal
            info.Type
        | None ->
            failwithf "E6 codegen: enum '%s' has no case '%s'" enumName caseName

    // ---- prefix -------------------------------------------------------

    | EPrefix (PreNeg, operand) ->
        let t = emitExpr ctx operand
        il.Emit(OpCodes.Neg)
        t

    | EPrefix (PreNot, operand) ->
        let _ = emitExpr ctx operand
        emitLdcI4 il 0
        il.Emit(OpCodes.Ceq)
        typeof<bool>

    // ---- binary operators ---------------------------------------------

    | EBinop (BAnd, lhs, rhs) ->
        let _ = emitExpr ctx lhs
        let lblFalse = il.DefineLabel()
        let lblEnd   = il.DefineLabel()
        il.Emit(OpCodes.Brfalse_S, lblFalse)
        let _ = emitExpr ctx rhs
        il.Emit(OpCodes.Br_S, lblEnd)
        il.MarkLabel(lblFalse)
        emitLdcI4 il 0
        il.MarkLabel(lblEnd)
        typeof<bool>

    | EBinop (BOr, lhs, rhs) ->
        let _ = emitExpr ctx lhs
        let lblTrue = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        il.Emit(OpCodes.Brtrue_S, lblTrue)
        let _ = emitExpr ctx rhs
        il.Emit(OpCodes.Br_S, lblEnd)
        il.MarkLabel(lblTrue)
        emitLdcI4 il 1
        il.MarkLabel(lblEnd)
        typeof<bool>

    | EBinop (op, lhs, rhs) ->
        let lt = emitExpr ctx lhs
        // Distinct-type binop: if the lhs is a distinct-type struct, the
        // value on the stack is the wrapper.  Stash it to a local, unwrap
        // both operands to their underlying primitive, run the primitive
        // op, and (for arithmetic) re-wrap via `From()`.
        let lhsDistinct =
            ctx.DistinctTypes.Values
            |> Seq.tryFind (fun d -> (d.Type :> ClrType) = lt)
        match lhsDistinct with
        | Some info ->
            let lhsLoc = FunctionCtx.defineLocal ctx "__d_lhs" lt
            il.Emit(OpCodes.Stloc, lhsLoc)
            let rt = emitExpr ctx rhs
            let rhsLoc = FunctionCtx.defineLocal ctx "__d_rhs" rt
            il.Emit(OpCodes.Stloc, rhsLoc)
            il.Emit(OpCodes.Ldloca, lhsLoc)
            il.Emit(OpCodes.Ldfld, info.ValueField)
            il.Emit(OpCodes.Ldloca, rhsLoc)
            il.Emit(OpCodes.Ldfld, info.ValueField)
            let underlyingTy = info.ValueField.FieldType
            match op with
            | BAdd ->
                if isFloatClr underlyingTy then il.Emit(OpCodes.Add)
                elif isUnsignedClr underlyingTy then il.Emit(OpCodes.Add_Ovf_Un)
                else il.Emit(OpCodes.Add_Ovf)
                il.Emit(OpCodes.Call, info.FromMethod)
                info.Type :> ClrType
            | BSub ->
                if isFloatClr underlyingTy then il.Emit(OpCodes.Sub)
                elif isUnsignedClr underlyingTy then il.Emit(OpCodes.Sub_Ovf_Un)
                else il.Emit(OpCodes.Sub_Ovf)
                il.Emit(OpCodes.Call, info.FromMethod)
                info.Type :> ClrType
            | BMul ->
                if isFloatClr underlyingTy then il.Emit(OpCodes.Mul)
                elif isUnsignedClr underlyingTy then il.Emit(OpCodes.Mul_Ovf_Un)
                else il.Emit(OpCodes.Mul_Ovf)
                il.Emit(OpCodes.Call, info.FromMethod)
                info.Type :> ClrType
            | BDiv ->
                if isUnsignedClr underlyingTy then il.Emit(OpCodes.Div_Un)
                else il.Emit(OpCodes.Div)
                il.Emit(OpCodes.Call, info.FromMethod)
                info.Type :> ClrType
            | BMod ->
                if isUnsignedClr underlyingTy then il.Emit(OpCodes.Rem_Un)
                else il.Emit(OpCodes.Rem)
                il.Emit(OpCodes.Call, info.FromMethod)
                info.Type :> ClrType
            | BEq  -> il.Emit(OpCodes.Ceq); typeof<bool>
            | BNeq -> il.Emit(OpCodes.Ceq); emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
            | BLt  ->
                if isUnsignedClr underlyingTy then il.Emit(OpCodes.Clt_Un) else il.Emit(OpCodes.Clt)
                typeof<bool>
            | BGt  ->
                if isUnsignedClr underlyingTy then il.Emit(OpCodes.Cgt_Un) else il.Emit(OpCodes.Cgt)
                typeof<bool>
            | BLte ->
                if isUnsignedClr underlyingTy then il.Emit(OpCodes.Cgt_Un) else il.Emit(OpCodes.Cgt)
                emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
            | BGte ->
                if isUnsignedClr underlyingTy then il.Emit(OpCodes.Clt_Un) else il.Emit(OpCodes.Clt)
                emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
            | _ ->
                failwithf "M2.1 codegen: operator %A not supported on distinct type %s"
                    op info.Name
        | None ->

        let rt = emitExpr ctx rhs
        let opTy = lt
        match op with
        | BAdd when lt = typeof<string> || rt = typeof<string> ->
            // String concatenation: route `+` to
            // `String.Concat(object, object)` so either operand
            // can be a primitive (auto-boxed via the value-type
            // overload). The result is a string.
            if rt.IsValueType then il.Emit(OpCodes.Box, rt)
            // The lhs is already on the stack underneath rhs; we
            // need to reorder so we can box it too. Use locals
            // to swap.
            let rhsLoc = FunctionCtx.defineLocal ctx "__concat_rhs" typeof<obj>
            il.Emit(OpCodes.Stloc, rhsLoc)
            if lt.IsValueType then il.Emit(OpCodes.Box, lt)
            il.Emit(OpCodes.Ldloc, rhsLoc)
            let concat =
                let mi =
                    typeof<System.String>
                        .GetMethod("Concat", [| typeof<obj>; typeof<obj> |])
                match Option.ofObj mi with
                | Some m -> m
                | None   -> failwith "String.Concat(object, object) not found"
            il.Emit(OpCodes.Call, concat)
            typeof<string>
        | BAdd ->
            if isFloatClr opTy then il.Emit(OpCodes.Add)
            elif isUnsignedClr opTy then il.Emit(OpCodes.Add_Ovf_Un)
            else il.Emit(OpCodes.Add_Ovf)
            opTy
        | BSub ->
            if isFloatClr opTy then il.Emit(OpCodes.Sub)
            elif isUnsignedClr opTy then il.Emit(OpCodes.Sub_Ovf_Un)
            else il.Emit(OpCodes.Sub_Ovf)
            opTy
        | BMul ->
            if isFloatClr opTy then il.Emit(OpCodes.Mul)
            elif isUnsignedClr opTy then il.Emit(OpCodes.Mul_Ovf_Un)
            else il.Emit(OpCodes.Mul_Ovf)
            opTy
        | BDiv ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Div_Un)
            else il.Emit(OpCodes.Div)
            opTy
        | BMod ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Rem_Un)
            else il.Emit(OpCodes.Rem)
            opTy
        | BXor ->
            il.Emit(OpCodes.Xor)
            opTy
        | BEq  -> il.Emit(OpCodes.Ceq); typeof<bool>
        | BNeq -> il.Emit(OpCodes.Ceq); emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
        | BLt  ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Clt_Un) else il.Emit(OpCodes.Clt)
            typeof<bool>
        | BGt  ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Cgt_Un) else il.Emit(OpCodes.Cgt)
            typeof<bool>
        | BLte ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Cgt_Un) else il.Emit(OpCodes.Cgt)
            emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
        | BGte ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Clt_Un) else il.Emit(OpCodes.Clt)
            emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
        | BCoalesce -> opTy
        | BImplies  ->
            il.Emit(OpCodes.Pop); il.Emit(OpCodes.Pop); emitLdcI4 il 1; typeof<bool>
        | BAnd | BOr ->
            failwith "logical op fell through to fallback"

    // ---- if-expression ------------------------------------------------

    | EIf (cond, thenBranch, elseBranch, _isThen) ->
        let _ = emitExpr ctx cond
        match elseBranch with
        | None ->
            // Statement-form `if cond { ... }` — no value, no
            // stack effect.
            let lblEnd = il.DefineLabel()
            il.Emit(OpCodes.Brfalse, lblEnd)
            let thenTy = emitBranch ctx thenBranch
            // If the then-branch left a value, drop it so the merge
            // point is balanced.
            if thenTy <> typeof<System.Void> then
                il.Emit(OpCodes.Pop)
            il.MarkLabel(lblEnd)
            typeof<System.Void>
        | Some elseB ->
            let lblElse = il.DefineLabel()
            let lblEnd  = il.DefineLabel()
            il.Emit(OpCodes.Brfalse, lblElse)
            let thenTy = emitBranchValue ctx thenBranch
            il.Emit(OpCodes.Br, lblEnd)
            il.MarkLabel(lblElse)
            let elseTy = emitBranchValue ctx elseB
            il.MarkLabel(lblEnd)
            // Both branches must agree on whether they push a value.
            if thenTy = typeof<System.Void> || elseTy = typeof<System.Void> then
                typeof<System.Void>
            else
                thenTy

    // ---- match (E6: enum-only patterns) -------------------------------

    | EMatch (scrutinee, arms) ->
        emitMatch ctx scrutinee arms

    // ---- union case construction (variant-bearing) -------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when ctx.UnionCases.ContainsKey name ->
        let info, caseInfo = ctx.UnionCases.[name]
        // Cases with payloads accept positional or named args.
        let namedMap =
            args
            |> List.choose (function
                | CANamed (n, ex, _) -> Some (n, ex)
                | _ -> None)
            |> Map.ofList
        let positional =
            args
            |> List.choose (function
                | CAPositional ex -> Some ex
                | _ -> None)
        let mutable posIdx = 0
        for f in caseInfo.Fields do
            let argExpr =
                match Map.tryFind f.Name namedMap with
                | Some ex -> ex
                | None ->
                    if posIdx < List.length positional then
                        let ex = List.item posIdx positional
                        posIdx <- posIdx + 1
                        ex
                    else
                        failwithf "E11 codegen: union case '%s' missing field '%s'"
                            name f.Name
            let argTy = emitExpr ctx argExpr
            // Box value-typed args into the erased `obj` payload slot.
            if f.Type = typeof<obj> && argTy.IsValueType then
                il.Emit(OpCodes.Box, argTy)
        il.Emit(OpCodes.Newobj, caseInfo.Ctor)
        info.Type :> ClrType

    // ---- imported union case construction (e.g. Std.Core's Some) ------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when ctx.ImportedUnionCases.ContainsKey name ->
        let info, caseInfo = ctx.ImportedUnionCases.[name]
        let namedMap =
            args
            |> List.choose (function
                | CANamed (n, ex, _) -> Some (n, ex)
                | _ -> None)
            |> Map.ofList
        let positional =
            args
            |> List.choose (function
                | CAPositional ex -> Some ex
                | _ -> None)
        let mutable posIdx = 0
        for f in caseInfo.Fields do
            let argExpr =
                match Map.tryFind f.Name namedMap with
                | Some ex -> ex
                | None ->
                    if posIdx < List.length positional then
                        let ex = List.item posIdx positional
                        posIdx <- posIdx + 1
                        ex
                    else
                        failwithf "imported union case '%s' missing field '%s'"
                            name f.Name
            let argTy = emitExpr ctx argExpr
            if f.Type = typeof<obj> && argTy.IsValueType then
                il.Emit(OpCodes.Box, argTy)
        il.Emit(OpCodes.Newobj, caseInfo.Ctor)
        info.Type

    // ---- record construction ------------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when ctx.Records.ContainsKey name ->
        let info = ctx.Records.[name]
        // Sort arguments into field-declaration order. Positional
        // and named args may mix; named args win.
        let namedMap =
            args
            |> List.choose (function
                | CANamed (n, ex, _) -> Some (n, ex)
                | _ -> None)
            |> Map.ofList
        let positional =
            args
            |> List.choose (function
                | CAPositional ex -> Some ex
                | _ -> None)
        let mutable posIdx = 0
        for f in info.Fields do
            let argExpr =
                match Map.tryFind f.Name namedMap with
                | Some ex -> ex
                | None ->
                    if posIdx < List.length positional then
                        let ex = List.item posIdx positional
                        posIdx <- posIdx + 1
                        ex
                    else
                        failwithf "E5 codegen: record '%s' missing field '%s'"
                            name f.Name
            let _ = emitExpr ctx argExpr
            ()
        il.Emit(OpCodes.Newobj, info.Ctor)
        info.Type :> ClrType

    // ---- distinct type static factory: TypeName.from(x) ----------------

    | ECall ({ Kind = EPath { Segments = [typeName; methodName] } }, args)
        when ctx.DistinctTypes.ContainsKey typeName
             && (methodName = "from" || methodName = "tryFrom") ->
        let info = ctx.DistinctTypes.[typeName]
        let arg =
            match args with
            | [CAPositional ex] | [CANamed (_, ex, _)] -> ex
            | _ -> failwithf "M2.1 codegen: %s.%s expects exactly one argument" typeName methodName
        let _ = emitExpr ctx arg
        if methodName = "from" then
            il.Emit(OpCodes.Call, info.FromMethod)
            info.Type :> ClrType
        else
            match info.TryFromMethod with
            | Some m ->
                il.Emit(OpCodes.Call, m)
                m.ReturnType
            | None ->
                failwithf "M2.1 codegen: %s.tryFrom not available (no range constraint)" typeName

    // ---- println builtin ----------------------------------------------

    | ECall ({ Kind = EPath { Segments = ["println"] } }, [arg]) ->
        let payload =
            match arg with
            | CAPositional ex | CANamed (_, ex, _) -> ex
        let argTy = emitExpr ctx payload
        if argTy = typeof<string> then
            il.Emit(OpCodes.Call, printlnString.Value)
        else
            boxIfValue il argTy
            il.Emit(OpCodes.Call, printlnAny.Value)
        typeof<System.Void>

    // ---- user-defined call --------------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when ctx.Funcs.ContainsKey name ->
        let mb = ctx.Funcs.[name]
        let paramTypes =
            mb.GetParameters() |> Array.map (fun p -> p.ParameterType)
        let isGeneric = mb.IsGenericMethodDefinition
        if not isGeneric then
            // Non-generic — existing path.  Erased-generic args still
            // box at the boundary when a param slot is `obj`.
            args
            |> List.iteri (fun i a ->
                let payload =
                    match a with
                    | CAPositional ex | CANamed (_, ex, _) -> ex
                let expectedDelegateTy =
                    if i < paramTypes.Length
                       && paramTypes.[i].IsSubclassOf typeof<System.Delegate>
                    then Some paramTypes.[i]
                    else None
                match payload.Kind, expectedDelegateTy with
                | ELambda (lps, body), Some dt ->
                    emitLambdaWith ctx lps body (Some dt) |> ignore
                | ELambda (lps, body), None ->
                    emitLambdaWith ctx lps body None |> ignore
                | _ ->
                    let argTy = emitExpr ctx payload
                    if i < paramTypes.Length
                       && paramTypes.[i] = typeof<obj>
                       && argTy.IsValueType then
                        il.Emit(OpCodes.Box, argTy))
            il.Emit(OpCodes.Call, mb)
            if mb.ReturnType = typeof<System.Void> then
                typeof<System.Void>
            else
                mb.ReturnType
        else
            // Reified generic: walk Lyric param types to find which
            // positional `TyVar` each arg constrains, observe CLR arg
            // types, then `MakeGenericMethod` and `Call`.  We can't
            // trust `MethodBuilder.GetParameters()` before the host
            // type is sealed, so type-arg inference works at the
            // Lyric-signature level instead.
            let sg = ctx.FuncSigs.[name]
            let genericNames = sg.Generics
            let bindings : ClrType option array =
                Array.create genericNames.Length None
            let bindByName (n: string) (argTy: ClrType) =
                match List.tryFindIndex ((=) n) genericNames with
                | Some pos when bindings.[pos].IsNone ->
                    bindings.[pos] <- Some argTy
                | _ -> ()
            let rec bindLyricToClr (lyricTy: Lyric.TypeChecker.Type) (argTy: ClrType) =
                match lyricTy with
                | Lyric.TypeChecker.TyVar n -> bindByName n argTy
                | _ -> ()  // compound-shape inference deferred
            // Pair-wise emission with type-arg propagation.
            let lyricParamTypes =
                sg.Params |> List.map (fun p -> p.Type) |> List.toArray
            args
            |> List.iteri (fun i a ->
                let payload =
                    match a with
                    | CAPositional ex | CANamed (_, ex, _) -> ex
                let argTy = emitExpr ctx payload
                if i < lyricParamTypes.Length then
                    bindLyricToClr lyricParamTypes.[i] argTy)
            // Default any unbound generic params to `obj` so we still
            // produce well-formed IL even when inference can't see far
            // enough into a body to fix T.
            let resolvedBindings =
                bindings
                |> Array.map (function
                    | Some t -> t
                    | None   -> typeof<obj>)
            let constructed = mb.MakeGenericMethod resolvedBindings
            il.Emit(OpCodes.Call, constructed)
            // `constructed.ReturnType` is unreliable until the host
            // type is sealed (Reflection.Emit limitation), so substitute
            // the resolved bindings into Lyric's `sg.Return` ourselves
            // to surface the right CLR type to the caller.
            let substMap =
                List.zip genericNames (List.ofArray resolvedBindings)
                |> Map.ofList
            let returnedTy =
                Lyric.Emitter.TypeMap.toClrReturnTypeWithGenerics
                    (fun _ -> None) substMap sg.Return
            if returnedTy = typeof<System.Void> then typeof<System.Void>
            else returnedTy

    // ---- delegate / higher-order call ---------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args) ->
        // Name not in Funcs — check if it is a delegate-typed local or
        // parameter. If so, emit `callvirt Invoke`.
        let delegateLoad () =
            match FunctionCtx.tryLookup ctx name with
            | Some lb when lb.LocalType.IsSubclassOf typeof<System.Delegate> ->
                il.Emit(OpCodes.Ldloc, lb)
                Some lb.LocalType
            | _ ->
                match ctx.Params.TryGetValue name with
                | true, (idx, ty) when ty.IsSubclassOf typeof<System.Delegate> ->
                    il.Emit(OpCodes.Ldarg, idx)
                    Some ty
                | _ -> None
        match delegateLoad () with
        | Some delegateTy ->
            let invoke = delegateTy.GetMethod "Invoke"
            match Option.ofObj invoke with
            | Some mi ->
                let pts = mi.GetParameters() |> Array.map (fun p -> p.ParameterType)
                args |> List.iteri (fun i a ->
                    let payload = match a with | CAPositional ex | CANamed (_, ex, _) -> ex
                    let argTy = emitExpr ctx payload
                    if i < pts.Length then
                        let pt = pts.[i]
                        if pt = typeof<obj> && argTy.IsValueType then
                            il.Emit(OpCodes.Box, argTy)
                        elif pt.IsValueType && (argTy = typeof<obj>) then
                            il.Emit(OpCodes.Unbox_Any, pt))
                il.Emit(OpCodes.Callvirt, mi)
                if mi.ReturnType = typeof<System.Void> then typeof<System.Void>
                else mi.ReturnType
            | None ->
                failwithf "Delegate lowering: no Invoke on %s" delegateTy.Name
        | None ->
            // Last fallback: imported function from a precompiled
            // package (e.g. Std.Core).  Cross-assembly call dispatches
            // through the runtime MethodInfo we recovered via reflection.
            match ctx.ImportedFuncs.TryGetValue name with
            | true, mi ->
                let paramTypes =
                    mi.GetParameters()
                    |> Array.map (fun p -> p.ParameterType)
                args
                |> List.iteri (fun i a ->
                    let payload =
                        match a with
                        | CAPositional ex | CANamed (_, ex, _) -> ex
                    let argTy = emitExpr ctx payload
                    if i < paramTypes.Length then
                        let pt = paramTypes.[i]
                        if pt = typeof<obj> && argTy.IsValueType then
                            il.Emit(OpCodes.Box, argTy)
                        elif pt.IsValueType && (argTy = typeof<obj>) then
                            il.Emit(OpCodes.Unbox_Any, pt))
                il.Emit(OpCodes.Call, mi)
                if mi.ReturnType = typeof<System.Void> then typeof<System.Void>
                else mi.ReturnType
            | _ ->
                failwithf "E4 codegen: unknown name '%s'" name

    // ---- lambda expression --------------------------------------------

    | ELambda (params', body) ->
        emitLambdaWith ctx params' body None

    | _ ->
        failwithf "E3 codegen does not yet handle expression: %A" e.Kind

/// Synthesise a static lambda method on `ctx.ProgramType` and emit a
/// delegate instance pointing to it. `expectedTy` (when Some) is the
/// target delegate type inferred from the call-site parameter; it
/// drives the return type when the lambda body is hard to peek. When
/// None we peek the body or fall back to `obj`.
and private emitLambdaWith
        (ctx: FunctionCtx)
        (params': LambdaParam list)
        (body: Block)
        (expectedTy: ClrType option) : ClrType =
    let il = ctx.IL
    // Resolve each parameter's CLR type from its annotation.
    let paramPairs =
        params'
        |> List.map (fun lp ->
            let cty =
                match lp.Type with
                | Some te -> ctx.ResolveType te
                | None    -> typeof<obj>
            lp.Name, cty)
    let paramTys = paramPairs |> List.map snd |> List.toArray
    // Determine return type: prefer the expected delegate's result type;
    // fall back to peeking the body's last expression.
    let retTy =
        match expectedTy with
        | Some dt ->
            match dissectDelegateTy dt with
            | Some (_, r) -> r
            | None -> typeof<obj>
        | None ->
            match List.tryLast body.Statements with
            | Some { Kind = SExpr e2 } | Some { Kind = SReturn (Some e2) } ->
                peekExprType ctx e2
            | _ -> typeof<obj>
    let delegateTy = makeDelegateTy paramTys retTy
    // Define a fresh private static method on the program class.
    let mname = freshLambdaName ()
    let lambdaMb =
        ctx.ProgramType.DefineMethod(
            mname,
            MethodAttributes.Private ||| MethodAttributes.Static,
            (if retTy = typeof<System.Void> then typeof<System.Void> else retTy),
            paramTys)
    paramPairs |> List.iteri (fun i (n, _) ->
        lambdaMb.DefineParameter(i + 1, ParameterAttributes.None, n) |> ignore)
    let lambdaIL = lambdaMb.GetILGenerator()
    // Build a child context for the lambda body (non-capturing: no
    // outer locals visible, but outer Funcs/Records/etc. are shared).
    let lambdaCtx =
        FunctionCtx.make
            lambdaIL retTy paramPairs
            ctx.Funcs ctx.FuncSigs ctx.Records ctx.Enums ctx.EnumCases
            ctx.Unions ctx.UnionCases ctx.Interfaces ctx.DistinctTypes
            ctx.Projectables
            ctx.ImportedRecords ctx.ImportedUnions ctx.ImportedUnionCases
            ctx.ImportedFuncs ctx.ImportedDistinctTypes
            false None ctx.ProgramType ctx.ResolveType
    // Emit the body. For non-void lambdas, the last statement must leave
    // its value on the IL stack for `ret` — mirror emitFunctionBody's
    // single-exit discipline.
    if retTy = typeof<System.Void> then
        emitBlock lambdaCtx body
        lambdaIL.Emit(OpCodes.Ret)
    else
        FunctionCtx.pushScope lambdaCtx
        let stmts = body.Statements
        let lastIdx = List.length stmts - 1
        stmts |> List.iteri (fun i stmt ->
            if i = lastIdx then
                match stmt.Kind with
                | SExpr e ->
                    let _ = emitExpr lambdaCtx e
                    ()
                | SReturn (Some e) ->
                    let _ = emitExpr lambdaCtx e
                    ()
                | _ ->
                    emitStatement lambdaCtx stmt
            else
                emitStatement lambdaCtx stmt)
        FunctionCtx.popScope lambdaCtx
        lambdaIL.Emit(OpCodes.Ret)
    // Push the delegate onto the outer caller's IL stack.
    il.Emit(OpCodes.Ldnull)
    il.Emit(OpCodes.Ldftn, lambdaMb)
    let delegateCtor =
        delegateTy.GetConstructor([| typeof<obj>; typeof<System.IntPtr> |])
    match Option.ofObj delegateCtor with
    | Some c -> il.Emit(OpCodes.Newobj, c)
    | None ->
        failwithf "Delegate lowering: ctor not found on %s" delegateTy.FullName
    delegateTy

and private emitBranch (ctx: FunctionCtx) (b: ExprOrBlock) : ClrType =
    match b with
    | EOBExpr e   -> emitExpr ctx e
    | EOBBlock blk ->
        emitBlock ctx blk
        typeof<System.Void>     // a block leaves nothing on the stack

/// Like `emitBranch` but in expression-returning mode: the last
/// statement of a block is kept on the stack rather than popped.
/// Used for `if { … } else { … }` in expression position.
and private emitBranchValue (ctx: FunctionCtx) (b: ExprOrBlock) : ClrType =
    match b with
    | EOBExpr e -> emitExpr ctx e
    | EOBBlock blk ->
        FunctionCtx.pushScope ctx
        let stmts = blk.Statements
        let lastIdx = List.length stmts - 1
        let mutable resultTy = typeof<System.Void>
        stmts |> List.iteri (fun i stmt ->
            if i = lastIdx then
                match stmt.Kind with
                | SExpr e ->
                    resultTy <- emitExpr ctx e
                | _ ->
                    emitStatement ctx stmt
            else
                emitStatement ctx stmt)
        FunctionCtx.popScope ctx
        resultTy

/// Compile-time predicate: does `pat` always match? Identifier
/// patterns are catch-alls *unless* the name names an enum case or
/// a nullary union case — Lyric uses syntactic shape, not
/// capitalisation, to distinguish the two.
and private alwaysMatches (ctx: FunctionCtx) (pat: Pattern) : bool =
    match pat.Kind with
    | PWildcard -> true
    | PBinding ("_", None) -> true
    | PBinding (name, None) ->
        not (ctx.EnumCases.ContainsKey name)
        && not (ctx.UnionCases.ContainsKey name)
        && not (ctx.ImportedUnionCases.ContainsKey name)
    | PParen inner -> alwaysMatches ctx inner
    | _ -> false

/// Emit IL that pushes `1` onto the stack iff `pat` matches the
/// scrutinee value already stored in `tmp`. The slot's CLR type is
/// passed for context (e.g. enum-case ordinals).
and private emitPatternTest
        (ctx: FunctionCtx)
        (tmp: LocalBuilder)
        (slotTy: ClrType)
        (pat: Pattern) : unit =
    let il = ctx.IL
    match pat.Kind with
    | PWildcard | PBinding ("_", None) ->
        emitLdcI4 il 1
    | PBinding (name, None) ->
        match ctx.EnumCases.TryGetValue name with
        | true, (_, c) ->
            // `case Red` — equality test against the case ordinal.
            il.Emit(OpCodes.Ldloc, tmp)
            emitLdcI4 il c.Ordinal
            il.Emit(OpCodes.Ceq)
        | _ ->
            match ctx.UnionCases.TryGetValue name with
            | true, (_, caseInfo) ->
                // `case Yes` for a nullary union case — type-test.
                il.Emit(OpCodes.Ldloc, tmp)
                il.Emit(OpCodes.Isinst, caseInfo.Type)
                il.Emit(OpCodes.Ldnull)
                il.Emit(OpCodes.Cgt_Un)
            | _ ->
                // Imported nullary union case (e.g. None from Std.Core).
                match ctx.ImportedUnionCases.TryGetValue name with
                | true, (_, caseInfo) ->
                    il.Emit(OpCodes.Ldloc, tmp)
                    il.Emit(OpCodes.Isinst, caseInfo.Type)
                    il.Emit(OpCodes.Ldnull)
                    il.Emit(OpCodes.Cgt_Un)
                | _ ->
                    // Plain identifier binding — always matches; the
                    // bind happens in `emitPatternBind`.
                    emitLdcI4 il 1
    | PParen inner ->
        emitPatternTest ctx tmp slotTy inner
    | PLiteral lit ->
        // scrutinee == literal
        il.Emit(OpCodes.Ldloc, tmp)
        let _ =
            match lit with
            | LInt (v, suffix) -> emitIntLiteral il v suffix
            | LBool b          -> emitLdcI4 il (if b then 1 else 0); typeof<bool>
            | LChar c          -> emitLdcI4 il c; typeof<char>
            | LFloat (v, s)    -> emitFloatLiteral il v s
            | LString s        -> il.Emit(OpCodes.Ldstr, s); typeof<string>
            | _ -> emitLdcI4 il 0; typeof<int32>
        il.Emit(OpCodes.Ceq)
    | PConstructor (path, sub) ->
        // Two flavours: enum case (no sub-patterns) and union case
        // (any number of sub-patterns).
        let key =
            match path.Segments with
            | [name] -> name
            | _ -> String.concat "." path.Segments
        match ctx.EnumCases.TryGetValue key with
        | true, (_, c) when sub.IsEmpty ->
            il.Emit(OpCodes.Ldloc, tmp)
            emitLdcI4 il c.Ordinal
            il.Emit(OpCodes.Ceq)
        | _ ->
            match ctx.UnionCases.TryGetValue key with
            | true, (_, caseInfo) ->
                // `tmp is CaseSubclass` — `isinst` returns the value
                // typed as the subclass, or `null`. We use the
                // `cgt.un` against ldnull idiom to convert "not null"
                // into the bool 1.
                il.Emit(OpCodes.Ldloc, tmp)
                il.Emit(OpCodes.Isinst, caseInfo.Type)
                il.Emit(OpCodes.Ldnull)
                il.Emit(OpCodes.Cgt_Un)
            | _ ->
                // Imported variant-bearing union case.
                match ctx.ImportedUnionCases.TryGetValue key with
                | true, (_, caseInfo) ->
                    il.Emit(OpCodes.Ldloc, tmp)
                    il.Emit(OpCodes.Isinst, caseInfo.Type)
                    il.Emit(OpCodes.Ldnull)
                    il.Emit(OpCodes.Cgt_Un)
                | _ ->
                    failwithf "E11 codegen: unknown constructor pattern '%s'"
                        (String.concat "." path.Segments)
    | _ ->
        failwithf "E6 codegen: pattern not yet supported: %A" pat.Kind

/// Bind any identifiers introduced by `pat` into the scope, given
/// the scrutinee already stored in `tmp`. Names that match a known
/// enum or nullary-union case are skipped — they're constructor
/// patterns, not bindings.
and private emitPatternBind
        (ctx: FunctionCtx)
        (tmp: LocalBuilder)
        (pat: Pattern) : unit =
    let il = ctx.IL
    match pat.Kind with
    | PBinding (name, None)
        when name <> "_"
             && not (ctx.EnumCases.ContainsKey name)
             && not (ctx.UnionCases.ContainsKey name)
             && not (ctx.ImportedUnionCases.ContainsKey name) ->
        let lb = FunctionCtx.defineLocal ctx name tmp.LocalType
        il.Emit(OpCodes.Ldloc, tmp)
        il.Emit(OpCodes.Stloc, lb)
    | PParen inner -> emitPatternBind ctx tmp inner
    | PConstructor (path, sub) when not sub.IsEmpty ->
        let key =
            match path.Segments with
            | [name] -> name
            | _ -> String.concat "." path.Segments
        // Resolve the case info from local OR imported union tables.
        let caseTy, caseFields =
            match ctx.UnionCases.TryGetValue key with
            | true, (_, caseInfo) ->
                Some (caseInfo.Type :> ClrType),
                caseInfo.Fields
                |> List.map (fun f ->
                    f.Name, f.Type, (f.Field :> FieldInfo))
            | _ ->
                match ctx.ImportedUnionCases.TryGetValue key with
                | true, (_, caseInfo) ->
                    Some caseInfo.Type,
                    caseInfo.Fields
                    |> List.map (fun f -> f.Name, f.Type, f.Field)
                | _ -> None, []
        match caseTy with
        | Some t ->
            let castedTmp =
                FunctionCtx.defineLocal ctx
                    ("__case_" + key) t
            il.Emit(OpCodes.Ldloc, tmp)
            il.Emit(OpCodes.Castclass, t)
            il.Emit(OpCodes.Stloc, castedTmp)
            let pairs =
                caseFields
                |> List.zip (sub |> List.truncate (List.length caseFields))
            for (sp, (_, fty, fInfo)) in pairs do
                match sp.Kind with
                | PBinding (name, None)
                    when name <> "_"
                         && not (ctx.EnumCases.ContainsKey name)
                         && not (ctx.UnionCases.ContainsKey name)
                         && not (ctx.ImportedUnionCases.ContainsKey name) ->
                    let lb = FunctionCtx.defineLocal ctx name fty
                    il.Emit(OpCodes.Ldloc, castedTmp)
                    il.Emit(OpCodes.Ldfld, fInfo)
                    il.Emit(OpCodes.Stloc, lb)
                | PWildcard | PBinding ("_", None) -> ()
                | _ -> ()
        | None -> ()
    | _ -> ()

and private emitMatch
        (ctx: FunctionCtx)
        (scrutinee: Expr)
        (arms: MatchArm list) : ClrType =
    let il = ctx.IL
    let scrutTy = emitExpr ctx scrutinee
    let tmp = FunctionCtx.defineLocal ctx ("__match_" + string (System.Guid.NewGuid().GetHashCode())) scrutTy
    il.Emit(OpCodes.Stloc, tmp)
    let endLbl = il.DefineLabel()
    let mutable resultTy : ClrType option = None
    arms
    |> List.iteri (fun i arm ->
        let nextArm = il.DefineLabel()
        if not (alwaysMatches ctx arm.Pattern) then
            emitPatternTest ctx tmp scrutTy arm.Pattern
            il.Emit(OpCodes.Brfalse, nextArm)
        FunctionCtx.pushScope ctx
        emitPatternBind ctx tmp arm.Pattern
        let armTy = emitBranch ctx arm.Body
        if resultTy.IsNone then resultTy <- Some armTy
        FunctionCtx.popScope ctx
        il.Emit(OpCodes.Br, endLbl)
        il.MarkLabel(nextArm)
        ignore i)
    // Fall-through (no arm matched): push a dummy default so the
    // stack stays balanced. Phase 1 punt: emit the result type's
    // zero. M1.4 will replace this with a `MatchFailure` throw.
    match resultTy with
    | Some t when t = typeof<System.Void> -> ()
    | Some t when t.IsValueType ->
        let dummy = FunctionCtx.defineLocal ctx ("__match_default") t
        il.Emit(OpCodes.Ldloca, dummy)
        il.Emit(OpCodes.Initobj, t)
        il.Emit(OpCodes.Ldloc, dummy)
    | Some _ ->
        il.Emit(OpCodes.Ldnull)
    | None ->
        emitLdcI4 il 0
    il.MarkLabel(endLbl)
    defaultArg resultTy typeof<int32>

and emitStatement (ctx: FunctionCtx) (s: Statement) : unit =
    let il = ctx.IL
    match s.Kind with

    | SExpr e ->
        let resultTy = emitExpr ctx e
        if resultTy <> typeof<System.Void> then
            il.Emit(OpCodes.Pop)

    | SLocal (LBVal ({ Kind = PBinding (name, None) }, _annot, init))
    | SLocal (LBLet (name, _annot, init)) ->
        let initTy = emitExpr ctx init
        let lb = FunctionCtx.defineLocal ctx name initTy
        il.Emit(OpCodes.Stloc, lb)

    | SLocal (LBVal ({ Kind = PWildcard }, _annot, init))
    | SLocal (LBVal ({ Kind = PBinding ("_", None) }, _annot, init)) ->
        // `val _ = expr` — evaluate for side effects, drop the
        // result if any.
        let initTy = emitExpr ctx init
        if initTy <> typeof<System.Void> then
            il.Emit(OpCodes.Pop)

    | SLocal (LBVar (name, annot, initOpt)) ->
        let initTy =
            match initOpt with
            | Some init ->
                let it = emitExpr ctx init
                Some it
            | None -> None
        // Without inference, default-typed `var` falls back to int32
        // so the slot has *some* CLR type. Annotation handling lands
        // when TypeMap can consult the type checker.
        let slotTy = defaultArg initTy typeof<int32>
        ignore annot
        let lb = FunctionCtx.defineLocal ctx name slotTy
        match initOpt with
        | Some _ -> il.Emit(OpCodes.Stloc, lb)
        | None   -> ()

    | SLocal _ ->
        failwithf "E3 codegen does not yet handle this local pattern: %A" s.Kind

    | SAssign (target, AssEq, value) ->
        match target.Kind with
        | EPath { Segments = [name] } ->
            match FunctionCtx.tryLookup ctx name with
            | Some lb ->
                let _ = emitExpr ctx value
                il.Emit(OpCodes.Stloc, lb)
            | None -> failwithf "E3 codegen: assignment to unknown name '%s'" name
        | _ ->
            failwithf "E3 codegen: assignment target not yet supported: %A" target.Kind

    | SAssign (target, op, value) ->
        // Compound assignment: lower to `target = target <op> value`.
        match target.Kind with
        | EPath { Segments = [name] } ->
            match FunctionCtx.tryLookup ctx name with
            | Some lb ->
                let bop =
                    match op with
                    | AssPlus    -> BAdd
                    | AssMinus   -> BSub
                    | AssStar    -> BMul
                    | AssSlash   -> BDiv
                    | AssPercent -> BMod
                    | AssEq      -> BAdd  // already handled
                let synthetic : Expr =
                    { Kind = EBinop (bop, target, value); Span = s.Span }
                let _ = emitExpr ctx synthetic
                il.Emit(OpCodes.Stloc, lb)
            | None -> failwithf "E3 codegen: compound-assign to unknown name '%s'" name
        | _ ->
            failwithf "E3 codegen: compound-assign target not yet supported: %A" target.Kind

    | SReturn None ->
        // Branch to the synthesised single exit if one was set up;
        // otherwise emit a bare ret (legacy path for the host's
        // synthetic Main entry point).
        match ctx.ReturnLabel with
        | Some lbl -> il.Emit(OpCodes.Br, lbl)
        | None     -> il.Emit(OpCodes.Ret)

    | SReturn (Some e) ->
        let _ = emitExpr ctx e
        match ctx.ReturnLabel, ctx.ResultLocal with
        | Some lbl, Some loc ->
            il.Emit(OpCodes.Stloc, loc)
            il.Emit(OpCodes.Br, lbl)
        | Some lbl, None ->
            // Non-void value into a void-returning function — drop.
            il.Emit(OpCodes.Pop)
            il.Emit(OpCodes.Br, lbl)
        | None, _ ->
            il.Emit(OpCodes.Ret)

    | SWhile (_label, cond, body) ->
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead }
        il.MarkLabel(lblHead)
        let _ = emitExpr ctx cond
        il.Emit(OpCodes.Brfalse, lblEnd)
        emitBlock ctx body
        il.Emit(OpCodes.Br, lblHead)
        il.MarkLabel(lblEnd)
        FunctionCtx.popLoop ctx

    | SLoop (_label, body) ->
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead }
        il.MarkLabel(lblHead)
        emitBlock ctx body
        il.Emit(OpCodes.Br, lblHead)
        il.MarkLabel(lblEnd)
        FunctionCtx.popLoop ctx

    | SBreak _ ->
        match FunctionCtx.currentLoop ctx with
        | Some f -> il.Emit(OpCodes.Br, f.BreakLabel)
        | None   -> failwith "E3 codegen: 'break' outside of a loop"

    | SContinue _ ->
        match FunctionCtx.currentLoop ctx with
        | Some f -> il.Emit(OpCodes.Br, f.ContinueLabel)
        | None   -> failwith "E3 codegen: 'continue' outside of a loop"

    | SFor (_label, { Kind = PBinding (name, None) }, iter, body) ->
        // `for x in slice { body }` lowers to a counter + ldelem loop.
        // The iter is presumed to be a slice/array (CLR T[]); other
        // iterables land in E7.
        let iterTy = emitExpr ctx iter
        if not iterTy.IsArray then
            failwithf "E3 codegen: for-in expects an array/slice, got %A" iterTy
        let elemTy =
            match Option.ofObj (iterTy.GetElementType()) with
            | Some t -> t
            | None   -> typeof<obj>
        let arrLocal = FunctionCtx.defineLocal ctx ("__iter_" + name) iterTy
        il.Emit(OpCodes.Stloc, arrLocal)
        let idxLocal = FunctionCtx.defineLocal ctx ("__idx_" + name) typeof<int32>
        emitLdcI4 il 0
        il.Emit(OpCodes.Stloc, idxLocal)
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead }
        il.MarkLabel(lblHead)
        // if (idx >= length) goto end
        il.Emit(OpCodes.Ldloc, idxLocal)
        il.Emit(OpCodes.Ldloc, arrLocal)
        il.Emit(OpCodes.Ldlen)
        il.Emit(OpCodes.Conv_I4)
        il.Emit(OpCodes.Bge, lblEnd)
        // load element into the loop variable
        FunctionCtx.pushScope ctx
        let elemLocal = FunctionCtx.defineLocal ctx name elemTy
        il.Emit(OpCodes.Ldloc, arrLocal)
        il.Emit(OpCodes.Ldloc, idxLocal)
        il.Emit(OpCodes.Ldelem, elemLocal.LocalType)
        il.Emit(OpCodes.Stloc, elemLocal)
        emitBlock ctx body
        FunctionCtx.popScope ctx
        // idx <- idx + 1
        il.Emit(OpCodes.Ldloc, idxLocal)
        emitLdcI4 il 1
        il.Emit(OpCodes.Add)
        il.Emit(OpCodes.Stloc, idxLocal)
        il.Emit(OpCodes.Br, lblHead)
        il.MarkLabel(lblEnd)
        FunctionCtx.popLoop ctx

    | SFor _ ->
        failwithf "E3 codegen: only single-name for-in patterns are supported: %A" s.Kind

    | SScope (_, blk) | SDefer blk ->
        FunctionCtx.pushScope ctx
        emitBlock ctx blk
        FunctionCtx.popScope ctx

    | _ ->
        failwithf "E3 codegen does not yet handle statement: %A" s.Kind

and emitBlock (ctx: FunctionCtx) (blk: Block) : unit =
    FunctionCtx.pushScope ctx
    for stmt in blk.Statements do
        emitStatement ctx stmt
    FunctionCtx.popScope ctx
