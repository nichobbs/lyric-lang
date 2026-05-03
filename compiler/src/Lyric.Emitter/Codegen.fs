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
/// `TryDepthAtFrame` snapshots `FunctionCtx.TryDepth` at the loop
/// header; `break` / `continue` use `leave` instead of `br` when the
/// current depth exceeds this baseline (i.e. the branch crosses a
/// protected region opened inside the loop body).
type LoopFrame =
    { BreakLabel:      Label
      ContinueLabel:   Label
      TryDepthAtFrame: int }

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
      /// Same-package `protected type` definitions (D-progress-079),
      /// keyed by name.  Method-call dispatch on a protected receiver
      /// short-circuits via this table — `getRecvMethods` against an
      /// unsealed TypeBuilder throws, so we route through the
      /// pre-built `ProtectedMethod.Method` MethodBuilder instead.
      ProtectedTypes: Lyric.Emitter.Records.ProtectedTypeTable
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
      /// Lyric extern type names (`extern type Url = "System.Uri"`)
      /// mapped to their CLR types — both same-package decls and
      /// imports.  Drives strict-match auto-FFI for static-method
      /// calls of the form `ExternTypeName.method(args)` (C4 phase 1).
      ExternTypeNames: Dictionary<string, ClrType>
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
      /// Caller-side expected type hint for the next expression to
      /// be emitted.  Used by nullary union-case construction
      /// (`None`, `Empty`, …) when there's no value to infer T from
      /// — the val annotation, function param type, or surrounding
      /// arithmetic context provides one.  Save & restore around
      /// nested emits to avoid leaking across siblings.
      mutable ExpectedType: ClrType option
      /// How many active `try { … } finally { … }` regions wrap the
      /// current emission.  ECMA-335 requires `leave` (not `br`) to
      /// branch out of a protected region; the codegen consults
      /// `TryDepth > 0` whenever it routes a return / break /
      /// continue to a label that may sit outside the current try.
      mutable TryDepth: int
      /// The program TypeBuilder, used to synthesise static
      /// methods for non-capturing lambda expressions.
      ProgramType: TypeBuilder
      /// Resolve a `TypeExpr` from the surface syntax to a CLR type.
      /// Closed over the symbols and type-id lookup from Emitter.fs.
      ResolveType: Lyric.Parser.Ast.TypeExpr -> System.Type
      /// `TypeId -> CLR Type` lookup used by reified-generic codegen
      /// when it needs to compute a substituted CLR type from a Lyric
      /// `TyUser(id, …)` reference.
      Lookup: Lyric.TypeChecker.TypeId -> System.Type option
      /// Codegen-phase diagnostics. Errors recorded here instead of
      /// throwing exceptions allow error recovery and structured reporting.
      Diags: ResizeArray<Lyric.Lexer.Diagnostic>
      /// State-machine parameter map.  When emitting `MoveNext` for
      /// an async-state-machine class, parameters live as fields on
      /// the SM (since `MoveNext`'s only argument is `this`).  For
      /// any name in this map, `EPath`/`SAssign`/`peek` route through
      /// `Ldarg.0; Ldfld <field>` instead of the regular `Params`
      /// lookup.  Empty in non-SM contexts (the common case).
      SmFields: Dictionary<string, FieldInfo>
      /// Pre-allocated IL locals for promoted locals in Phase B
      /// state machines.  Keyed by Lyric local name; consumed by
      /// `defineLocal` so the body's `SLocal name` reuses the
      /// pre-allocated slot (whose value is loaded from the SM
      /// field at MoveNext entry and saved back at every suspend).
      mutable PreAllocatedLocals: Dictionary<string, LocalBuilder>
      /// Phase B suspend/resume context.  When set, `EAwait` emits
      /// the real `AwaitUnsafeOnCompleted` suspend/resume protocol
      /// instead of the M1.4 `GetAwaiter().GetResult()` blocking
      /// shim.
      mutable SmAwaitInfo: Lyric.Emitter.AsyncStateMachine.SmAwaitInfo option }

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
            (protectedTypes: Lyric.Emitter.Records.ProtectedTypeTable)
            (projectables: Lyric.Emitter.Records.ProjectableTable)
            (importedRecords: Lyric.Emitter.Records.ImportedRecordTable)
            (importedUnions: Lyric.Emitter.Records.ImportedUnionTable)
            (importedUnionCases: Lyric.Emitter.Records.ImportedUnionCaseLookup)
            (importedFuncs: Lyric.Emitter.Records.ImportedFuncTable)
            (importedDistinctTypes: Lyric.Emitter.Records.ImportedDistinctTypeTable)
            (externTypeNames: Dictionary<string, ClrType>)
            (isInstance: bool)
            (selfType: ClrType option)
            (programType: TypeBuilder)
            (resolveType: Lyric.Parser.Ast.TypeExpr -> System.Type)
            (lookup: Lyric.TypeChecker.TypeId -> System.Type option)
            (diags: ResizeArray<Lyric.Lexer.Diagnostic>) : FunctionCtx =
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
          ProtectedTypes = protectedTypes
          Projectables = projectables
          ImportedRecords     = importedRecords
          ImportedUnions      = importedUnions
          ImportedUnionCases  = importedUnionCases
          ImportedFuncs       = importedFuncs
          ImportedDistinctTypes = importedDistinctTypes
          ExternTypeNames = externTypeNames
          IsInstance   = isInstance
          SelfType     = selfType
          ReturnLabel  = None
          ResultLocal  = None
          ExpectedType = None
          TryDepth     = 0
          ProgramType  = programType
          ResolveType  = resolveType
          Lookup       = lookup
          Diags        = diags
          SmFields     = Dictionary()
          PreAllocatedLocals = Dictionary()
          SmAwaitInfo  = None }

    let pushScope (ctx: FunctionCtx) : unit =
        ctx.Scopes.Push(Dictionary())

    let popScope (ctx: FunctionCtx) : unit =
        ctx.Scopes.Pop() |> ignore

    let defineLocal (ctx: FunctionCtx) (name: string) (ty: ClrType) : LocalBuilder =
        // Phase B promoted locals: reuse the pre-allocated IL local
        // declared at MoveNext entry (whose value is shadow-copied to
        // an SM field at suspend / restored at resume).  Falls back
        // to a fresh `DeclareLocal` for every other case (regular
        // funcs, Phase A SM bodies, locals not in the promoted set).
        let lb =
            match ctx.PreAllocatedLocals.TryGetValue name with
            | true, pre -> pre
            | _         -> ctx.IL.DeclareLocal(ty)
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
// Codegen error helpers.
//
// Use these instead of `failwithf` for user-visible errors so that
// the emitter can continue, collect all errors, and return them as
// structured Diagnostic values instead of crashing with an exception.
// ---------------------------------------------------------------------------

/// Record a codegen error diagnostic and emit `ldnull` so that the
/// evaluation stack stays balanced.  Returns `typeof<obj>` as the
/// fallback CLR type.  Use in expression-context errors.
let private codegenErr
        (ctx:  FunctionCtx)
        (code: string)
        (msg:  string)
        (span: Lyric.Lexer.Span) : ClrType =
    ctx.Diags.Add(Lyric.Lexer.Diagnostic.error code msg span)
    ctx.IL.Emit(OpCodes.Ldnull)
    typeof<obj>

/// Record a codegen error diagnostic in statement context.
/// Does not emit any IL (the statement is simply dropped).
let private codegenErrStmt
        (ctx:  FunctionCtx)
        (code: string)
        (msg:  string)
        (span: Lyric.Lexer.Span) : unit =
    ctx.Diags.Add(Lyric.Lexer.Diagnostic.error code msg span)

// ---------------------------------------------------------------------------
// Stdlib bindings.
// ---------------------------------------------------------------------------

let private printlnString : Lazy<MethodInfo> =
    lazy (
        // Per `docs/14-native-stdlib-plan.md` §3 (kernel surface):
        // string `println` routes directly to `System.Console.WriteLine`.
        // Non-string arguments still fall back to the F#-side
        // `PrintlnAny`/`ToStr` because of their `null -> "()"` semantics.
        let consoleTy = typeof<System.Console>
        let mi = consoleTy.GetMethod("WriteLine", [| typeof<string> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwith "System.Console::WriteLine(string) not found")

let private printlnAny : Lazy<MethodInfo> =
    lazy (
        let consoleTy = typeof<Lyric.Stdlib.Console>
        let mi = consoleTy.GetMethod("PrintlnAny", [| typeof<obj> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwith "Lyric.Stdlib.Console::PrintlnAny(object) not found")

let private toStr : Lazy<MethodInfo> =
    lazy (
        let consoleTy = typeof<Lyric.Stdlib.Console>
        let mi = consoleTy.GetMethod("ToStr", [| typeof<obj> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwith "Lyric.Stdlib.Console::ToStr(object) not found")

let private formatMethod (arity: int) : Lazy<MethodInfo> =
    lazy (
        let formatTy = typeof<Lyric.Stdlib.Format>
        let methodName = sprintf "Of%d" arity
        let paramTys =
            Array.append [| typeof<string> |]
                         (Array.create arity typeof<obj>)
        let mi = formatTy.GetMethod(methodName, paramTys)
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwithf "Lyric.Stdlib.Format::%s not found" methodName)

let private format1 = formatMethod 1
let private format2 = formatMethod 2
let private format3 = formatMethod 3
let private format4 = formatMethod 4
let private format5 = formatMethod 5
let private format6 = formatMethod 6

/// Lookup a static method on `Lyric.Stdlib.Parse` by name.  Each Lyric
/// builtin (`hostParseIntIsValid`, `hostParseIntValue`, …) routes to
/// the matching CLR static.
let private parseHostMethod (name: string) : Lazy<MethodInfo> =
    lazy (
        let parseTy = typeof<Lyric.Stdlib.Parse>
        let mi = parseTy.GetMethod(name, [| typeof<string> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwithf "Lyric.Stdlib.Parse::%s(string) not found" name)

let private hostParseBuiltins : Map<string, Lazy<MethodInfo>> =
    Map.ofList [
        "hostParseIntIsValid",    parseHostMethod "IntIsValid"
        "hostParseIntValue",      parseHostMethod "IntValue"
        "hostParseLongIsValid",   parseHostMethod "LongIsValid"
        "hostParseLongValue",     parseHostMethod "LongValue"
        "hostParseDoubleIsValid", parseHostMethod "DoubleIsValid"
        "hostParseDoubleValue",   parseHostMethod "DoubleValue"
    ]

/// Lookup a static method on `Lyric.Stdlib.FileHost` by name, with the
/// given parameter types.  Each Lyric `hostFile*` builtin routes here.
let private fileHostMethod (name: string) (paramTys: System.Type array) : Lazy<MethodInfo> =
    lazy (
        let ty = typeof<Lyric.Stdlib.FileHost>
        let mi = ty.GetMethod(name, paramTys)
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwithf "Lyric.Stdlib.FileHost::%s not found" name)

let private hostFileBuiltins : Map<string, Lazy<MethodInfo>> =
    Map.ofList [
        "hostFileExists",
            fileHostMethod "Exists" [| typeof<string> |]
        "hostReadAllTextIsValid",
            fileHostMethod "ReadIsValid" [| typeof<string> |]
        "hostReadAllTextValue",
            fileHostMethod "ReadValue" [| typeof<string> |]
        "hostReadAllTextError",
            fileHostMethod "ReadError" [| typeof<string> |]
        "hostWriteAllTextIsValid",
            fileHostMethod "WriteIsValid" [| typeof<string>; typeof<string> |]
        "hostWriteAllTextError",
            fileHostMethod "WriteError" [| typeof<string>; typeof<string> |]
        "hostDirectoryExists",
            fileHostMethod "DirectoryExists" [| typeof<string> |]
        "hostCreateDirectoryIsValid",
            fileHostMethod "CreateDirectoryIsValid" [| typeof<string> |]
    ]

/// Lookup a static method on `Lyric.Stdlib.Contracts` by name (used
/// for the `panic` / `expect` / `assert` builtins).
let private contractMethod (name: string) (paramTys: System.Type array) : Lazy<MethodInfo> =
    lazy (
        let ty = typeof<Lyric.Stdlib.Contracts>
        let mi = ty.GetMethod(name, paramTys)
        match Option.ofObj mi with
        | Some m -> m
        | None ->
            failwithf "Lyric.Stdlib.Contracts::%s not found" name)

let private panicMethod : Lazy<MethodInfo> =
    contractMethod "Panic" [| typeof<string> |]

let private expectMethod : Lazy<MethodInfo> =
    contractMethod "Expect" [| typeof<bool>; typeof<string> |]

let private assertMethod : Lazy<MethodInfo> =
    contractMethod "Assert" [| typeof<bool> |]

// ---------------------------------------------------------------------------
// CLR-type predicates used by the binop emitter.
// ---------------------------------------------------------------------------

let private isFloatClr (t: ClrType) : bool =
    t = typeof<single> || t = typeof<double>

let private isUnsignedClr (t: ClrType) : bool =
    t = typeof<byte> || t = typeof<uint16>
    || t = typeof<uint32> || t = typeof<uint64>

// ---------------------------------------------------------------------------
// BCL method/property dispatch.
//
// Lyric source uses camelCase (`s.length`, `s.trim()`); the BCL exposes
// the same operations as PascalCase properties/methods (`String.Length`,
// `String.Trim`).  When exact-name lookup fails on a CLR type whose
// namespace lives under `System.*` (or a primitive), fall back to the
// PascalCase name and disambiguate overloads by argument types.
// ---------------------------------------------------------------------------

let private isBclType (t: ClrType) : bool =
    t.IsPrimitive
    || t = typeof<string>
    || (match Option.ofObj t.Namespace with
        | Some ns -> ns.StartsWith("System")
        | None    -> false)
    // TypeBuilderInstantiation hides the namespace; consult the open
    // generic definition so `Dictionary<gtpb_K, gtpb_V>` etc. still
    // route through the BCL fallback dispatch.
    || (t.IsGenericType
        && not t.IsGenericTypeDefinition
        && (let openTy = t.GetGenericTypeDefinition()
            match Option.ofObj openTy.Namespace with
            | Some ns -> ns.StartsWith("System")
            | None    -> false))

let private capitalizeFirst (s: string) : string =
    if String.IsNullOrEmpty s then s
    else string (Char.ToUpperInvariant s.[0]) + s.Substring(1)

/// True if `recvTy` is a generic instantiation that mentions a
/// `GenericTypeParameterBuilder` — i.e. we're inside a Lyric generic
/// function being emitted.  `TypeBuilderInstantiation.GetMethods()`
/// throws `NotSupportedException` for such types, so callers must
/// route through `TypeBuilder.GetMethod` on the open definition.
let private isGenericInstantiationOnGtpb (t: ClrType) : bool =
    t.IsGenericType
    && not t.IsGenericTypeDefinition
    && t.GetGenericArguments() |> Array.exists (fun a ->
        a :? System.Reflection.Emit.GenericTypeParameterBuilder)

/// `recvTy.GetMethods()` that works even when recvTy is a
/// TypeBuilderInstantiation (closed-on-GTPB generic).  For non-GTPB
/// types this is just `recvTy.GetMethods()`; for GTPB instantiations
/// we enumerate the open type's methods and return open handles —
/// callers should pass each candidate through `closeBclMethod` to
/// substitute the GTPBs once a name match is found.
let private getRecvMethods (recvTy: ClrType) : MethodInfo array =
    if isGenericInstantiationOnGtpb recvTy then
        recvTy.GetGenericTypeDefinition().GetMethods()
    else
        recvTy.GetMethods()

/// Close `openMi` against `recvTy` if `recvTy` is a TypeBuilder
/// instantiation; otherwise return it unchanged.  Use after picking a
/// method by name from `getRecvMethods` so the emitted call references
/// the right closed signature.
let private closeBclMethod (recvTy: ClrType) (openMi: MethodInfo) : MethodInfo =
    if isGenericInstantiationOnGtpb recvTy
       && obj.ReferenceEquals(openMi.DeclaringType, recvTy.GetGenericTypeDefinition())
    then
        try System.Reflection.Emit.TypeBuilder.GetMethod(recvTy, openMi)
        with _ -> openMi
    else
        openMi

/// Pick a non-static method on `recvTy` named `name` whose parameter
/// types align with `argTys`.  Prefers exact equality, then assignability.
/// Resolve a BCL instance method by name and (leading) arg types.
/// Returns (method, extra-default-params) where extra-default-params
/// are the parameters beyond those supplied that have CLR default values.
/// First tries exact-arity matches; if none, tries methods where the
/// extra parameters all carry HasDefaultValue so the caller can push them.
let private resolveBclMethod
        (recvTy: ClrType)
        (name: string)
        (argTys: ClrType array)
        : (MethodInfo * System.Reflection.ParameterInfo array) option =
    let matches (m: MethodInfo) (cmp: ClrType -> ClrType -> bool) =
        let pars = m.GetParameters()
        let mutable ok = true
        for i in 0 .. argTys.Length - 1 do
            if ok && not (cmp pars.[i].ParameterType argTys.[i]) then
                ok <- false
        ok
    let tryResolve (candidates: MethodInfo array) =
        let exact =
            candidates
            |> Array.tryFind (fun m -> matches m (fun p a -> p = a))
        match exact with
        | Some m -> Some m
        | None ->
            candidates
            |> Array.tryFind (fun m -> matches m (fun p a -> p.IsAssignableFrom a))
    // For TypeBuilderInstantiation receivers (we're inside a Lyric
    // generic function), `MethodOnTypeBuilderInstantiation` reports
    // its `ParameterType` as the OPEN generic param (`TKey`) rather
    // than the closed substitution (`gtpb_K`), so direct equality
    // matching against `argTys` fails even when the call is well-
    // formed.  In that case fall back to name + arity matching alone
    // and trust the type checker to have ruled out shape mismatches.
    let isTBIRecv = isGenericInstantiationOnGtpb recvTy
    let candidateMethods =
        getRecvMethods recvTy
        |> Array.map (closeBclMethod recvTy)
    // 1) Exact-arity candidates.
    let exactArity =
        candidateMethods
        |> Array.filter (fun m ->
            m.Name = name
            && not m.IsStatic
            && m.GetParameters().Length = argTys.Length)
    let firstByArity () =
        if isTBIRecv then exactArity |> Array.tryHead else None
    match tryResolve exactArity with
    | Some m -> Some (m, [||])
    | None when (firstByArity ()).IsSome ->
        Some ((firstByArity ()).Value, [||])
    | None ->
        // 2) Candidates with extra parameters that all have default values.
        let withDefaults =
            candidateMethods
            |> Array.filter (fun m ->
                m.Name = name
                && not m.IsStatic
                && m.GetParameters().Length > argTys.Length
                && m.GetParameters()
                   |> Array.skip argTys.Length
                   |> Array.forall (fun p -> p.HasDefaultValue))
        match tryResolve withDefaults with
        | Some m -> Some (m, m.GetParameters() |> Array.skip argTys.Length)
        | None -> None

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
// Where-clause bound checking (call-site).
// ---------------------------------------------------------------------------

/// Does `ty` satisfy the given derive marker?  Bootstrap support: CLR
/// primitives (numeric / Bool / Char) and `String` satisfy a fixed
/// table of markers.  Locally-defined distinct types live in
/// `ctx.DistinctTypes` but their `derives` list isn't currently
/// snapshotted on `DistinctTypeInfo`, so for now they only satisfy
/// markers via the primitive fallback (i.e. don't).
let private satisfiesMarker
        (_ctx: FunctionCtx) (ty: ClrType) (marker: string) : bool =
    let isNumeric =
        ty = typeof<sbyte>  || ty = typeof<int16>  || ty = typeof<int32>
        || ty = typeof<int64>  || ty = typeof<byte>   || ty = typeof<uint16>
        || ty = typeof<uint32> || ty = typeof<uint64>
        || ty = typeof<single> || ty = typeof<double>
    let isOrderedPrim =
        isNumeric || ty = typeof<char> || ty = typeof<string>
    let isAnyPrim =
        ty.IsPrimitive || ty = typeof<string>
    match marker with
    | "Add" | "Sub" | "Mul" | "Div" | "Mod" -> isNumeric
    | "Compare" -> isOrderedPrim
    | "Hash" | "Equals" | "Default" -> isAnyPrim
    | _ -> false

/// Validate that each inferred type-arg satisfies its declared
/// `where` markers.  Raises a clear failure when a bound isn't met;
/// the bootstrap doesn't expose a structured diagnostic stream at
/// codegen time, so the build aborts with an explanatory message
/// rather than silently miscompiling.
let private checkBounds
        (ctx: FunctionCtx)
        (callName: string)
        (genericNames: string list)
        (typeArgs: ClrType array)
        (bounds: Lyric.TypeChecker.ResolvedBound list) : unit =
    for b in bounds do
        match List.tryFindIndex ((=) b.Name) genericNames with
        | Some pos when pos < typeArgs.Length ->
            let ty = typeArgs.[pos]
            for m in b.Constraints do
                if not (satisfiesMarker ctx ty m) then
                    failwithf
                        "B0001 generic call '%s': type argument '%s = %s' does not satisfy 'where %s: %s'"
                        callName b.Name ty.Name b.Name m
        | _ -> ()

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
    | ELiteral LUnit              -> typeof<System.ValueTuple>
    | EParen inner                -> peekExprType ctx inner
    | EPath { Segments = [name] } ->
        match FunctionCtx.tryLookup ctx name with
        | Some lb -> lb.LocalType
        | None ->
            match ctx.SmFields.TryGetValue name with
            | true, f -> f.FieldType
            | _ ->
                match ctx.Params.TryGetValue name with
                | true, (_, t) ->
                    // Byref params (out/inout) auto-dereference at the
                    // emit site; peek matches by peeling the `T&`.
                    if t.IsByRef then
                        match Option.ofObj (t.GetElementType()) with
                        | Some et -> et
                        | None    -> t
                    else t
                | _            -> typeof<obj>
    | EBinop (op, l, _) ->
        match op with
        | BAnd | BOr | BXor | BImplies
        | BEq | BNeq | BLt | BLte | BGt | BGte ->
            typeof<bool>
        | BAdd | BSub | BMul | BDiv | BMod ->
            // Arithmetic preserves the operand type.  Falls back to
            // the lhs peek; if peek can't tell, we surface `obj`.
            peekExprType ctx l
        | BCoalesce -> peekExprType ctx l
    | EPrefix (PreNot, _) -> typeof<bool>
    | EPrefix (PreNeg, inner) -> peekExprType ctx inner
    | EIf (_, EOBExpr thenE, _, _) -> peekExprType ctx thenE
    | EList items ->
        // List literal: peek the first element to recover the array
        // shape recursively, e.g. `[[1,2,3],[4,5,6]]` → `int[][]`.
        match items with
        | [] -> typeof<obj[]>
        | first :: _ -> (peekExprType ctx first).MakeArrayType()
    | ECall ({ Kind = EPath { Segments = [name] } }, args) ->
        // Builtins with a known result type (codegen-only, not in
        // ctx.Funcs) take precedence so peek matches the actual emit.
        match name with
        | "toString" -> typeof<string>
        | "format1" | "format2" | "format3" | "format4"
        | "format5" | "format6" -> typeof<string>
        | "default" ->
            match ctx.ExpectedType with
            | Some t -> t
            | None   -> typeof<obj>
        | _ ->
        // Calls to a known func / delegate-typed local return a
        // predictable type that inference upstream needs to see.
        // Prefer arity-qualified key for overloaded functions.
        let arityKey = name + "/" + string args.Length
        let mbOpt =
            match ctx.Funcs.TryGetValue arityKey with
            | true, m -> Some m
            | _ ->
                match ctx.Funcs.TryGetValue name with
                | true, m -> Some m
                | _ -> None
        match mbOpt with
        | Some mb ->
            try mb.ReturnType
            with _ -> typeof<obj>
        | None ->
            let importedInfoOpt =
                match ctx.ImportedFuncs.TryGetValue (name + "/" + string args.Length) with
                | true, info -> Some info
                | _ ->
                    match ctx.ImportedFuncs.TryGetValue name with
                    | true, info -> Some info
                    | _ -> None
            match importedInfoOpt with
            | Some info ->
                try info.Method.ReturnType
                with _ -> typeof<obj>
            | None ->
                // Delegate-typed local / param: invoke returns the
                // last generic arg (Func<…,R>) or void (Action).
                let delTy =
                    match FunctionCtx.tryLookup ctx name with
                    | Some lb -> lb.LocalType
                    | None ->
                        match ctx.Params.TryGetValue name with
                        | true, (_, t) -> t
                        | _ -> typeof<obj>
                if delTy.IsGenericType then
                    try
                        let g = delTy.GetGenericTypeDefinition()
                        let args = delTy.GetGenericArguments()
                        let isAction =
                            g = typedefof<System.Action>
                            || g = typedefof<System.Action<_>>
                            || g = typedefof<System.Action<_,_>>
                            || g = typedefof<System.Action<_,_,_>>
                            || g = typedefof<System.Action<_,_,_,_>>
                        if isAction then typeof<System.Void>
                        elif args.Length > 0 then args.[args.Length - 1]
                        else typeof<obj>
                    with _ -> typeof<obj>
                else typeof<obj>
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
// Catch-type name → CLR System.Type resolver.  Module-level so both
// the statement-form STry handler and the EBlock try-as-expression
// path share the same alias table.
// ---------------------------------------------------------------------------

let resolveCatchTypeName (typeName: string) : System.Type =
    match typeName with
    | "Bug" | "Exception" | "Error" -> typeof<System.Exception>
    | "ArgumentException" | "Argument" -> typeof<System.ArgumentException>
    | "ArgumentNullException" | "NullArgument" -> typeof<System.ArgumentNullException>
    | "InvalidOperationException" | "InvalidOperation" -> typeof<System.InvalidOperationException>
    | "NotSupportedException" | "NotSupported" -> typeof<System.NotSupportedException>
    | "IOException" | "IO" -> typeof<System.IO.IOException>
    | "FileNotFoundException" | "FileNotFound" -> typeof<System.IO.FileNotFoundException>
    | "FormatException" | "Format" -> typeof<System.FormatException>
    | "OverflowException" | "Overflow" -> typeof<System.OverflowException>
    | "DivideByZeroException" | "DivideByZero" -> typeof<System.DivideByZeroException>
    | "TimeoutException" | "Timeout" -> typeof<System.TimeoutException>
    | _ ->
        let asms = System.AppDomain.CurrentDomain.GetAssemblies()
        let found =
            asms
            |> Array.tryPick (fun a ->
                try
                    a.GetTypes()
                    |> Array.tryFind (fun t ->
                        t.Name = typeName
                        || t.FullName = typeName)
                with _ -> None)
        match found with
        | Some t when typeof<System.Exception>.IsAssignableFrom(t) -> t
        | _ -> typeof<System.Exception>

/// Substitute the GTPBs in `openTy` against the closed receiver
/// `closedRecv`'s generic arguments.  Used to recover the substituted
/// CLR return type after `TypeBuilder.GetMethod`, which leaves the
/// open method's `ReturnType` in terms of the original GTPBs.
/// Handles bare GTPBs, generic instantiations, and array types.
let rec substituteGenericArgs (openTy: ClrType) (closedRecv: ClrType) : ClrType =
    if openTy.IsGenericParameter then
        let pos = openTy.GenericParameterPosition
        let closedArgs = closedRecv.GetGenericArguments()
        if pos < closedArgs.Length then closedArgs.[pos]
        else openTy
    elif openTy.IsArray then
        let elem = openTy.GetElementType()
        match Option.ofObj elem with
        | Some e -> (substituteGenericArgs e closedRecv).MakeArrayType()
        | None   -> openTy
    elif openTy.IsGenericType && not openTy.IsGenericTypeDefinition then
        let openArgs = openTy.GetGenericArguments()
        let substArgs =
            openArgs |> Array.map (fun a -> substituteGenericArgs a closedRecv)
        openTy.GetGenericTypeDefinition().MakeGenericType(substArgs)
    else
        openTy

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

    | EInterpolated segments ->
        // Lower to a `String.Concat(obj[])` call so an arbitrary
        // segment count works without the binary-Concat overload
        // ladder.  Build an obj[] of length N, populate each slot,
        // then call.  Empty segment list → "".
        match segments with
        | [] ->
            il.Emit(OpCodes.Ldstr, "")
            typeof<string>
        | _ ->
            let n = List.length segments
            emitLdcI4 il n
            il.Emit(OpCodes.Newarr, typeof<obj>)
            segments
            |> List.iteri (fun i seg ->
                il.Emit(OpCodes.Dup)
                emitLdcI4 il i
                let segTy =
                    match seg with
                    | ISText (s, _) ->
                        il.Emit(OpCodes.Ldstr, s)
                        typeof<string>
                    | ISExpr e ->
                        emitExpr ctx e
                if segTy.IsValueType then il.Emit(OpCodes.Box, segTy)
                il.Emit(OpCodes.Stelem_Ref))
            let concatArr =
                typeof<System.String>
                    .GetMethod("Concat", [| typeof<obj[]> |])
            match Option.ofObj concatArr with
            | Some m ->
                il.Emit(OpCodes.Call, m)
                typeof<string>
            | None ->
                failwith "String.Concat(object[]) not found"

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
        // `()` produces a `ValueTuple` (an empty struct), matching
        // Lyric's `Unit` lowering in TypeMap.  Materialise via
        // `Ldloca + Initobj + Ldloc` on a fresh local — the only way
        // to put a value-typed empty struct on the evaluation stack.
        // Critical when `()` flows into a generic position like
        // `Result_Ok<Unit, E>::.ctor(!0)`; the case ctor expects a
        // `ValueTuple` and rejected the previous `Ldc_I4 0`-based
        // shape with `InvalidProgramException`.
        let unitTy = typeof<System.ValueTuple>
        let lb = il.DeclareLocal(unitTy)
        il.Emit(OpCodes.Ldloca, lb)
        il.Emit(OpCodes.Initobj, unitTy)
        il.Emit(OpCodes.Ldloc, lb)
        unitTy

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
        elif recvTy = typeof<string> then
            // `s[i]` lowers to `String.get_Chars(int)`, returning a
            // `Char` (which Lyric models as `Int` at the codegen
            // layer for primitives — comparisons and equality work
            // against `'c'` literals which are LdcI4 emissions).
            let getChars =
                typeof<string>.GetMethod("get_Chars", [| typeof<int>|])
            match Option.ofObj getChars with
            | Some m ->
                il.Emit(OpCodes.Callvirt, m)
                typeof<char>
            | None ->
                failwith "E7 codegen: String::get_Chars not found"
        else
            // BCL indexer: any class with a `get_Item(<idx>)` method
            // (List<T>, Dictionary<K, V>, etc.) supports `recv[idx]`.
            let getItem =
                recvTy.GetMethods()
                |> Array.tryFind (fun m ->
                    m.Name = "get_Item"
                    && m.GetParameters().Length = 1)
            match getItem with
            | Some m ->
                il.Emit(OpCodes.Callvirt, m)
                m.ReturnType
            | None ->
                failwithf "E7 codegen: indexing on non-array / non-string %s"
                    recvTy.Name

    | EIndex (recv, idxs) when not (List.isEmpty idxs) ->
        // `a[i, j, …]` lowers to a chain of single-index loads:
        // each index applies to the result of the previous load.
        // The array shape is `T[][]…[]` (jagged), not `T[i,j]`
        // (rank-N arrays — a separate IL feature).
        let mutable curTy = emitExpr ctx recv
        for idx in idxs do
            if not curTy.IsArray then
                failwithf "E7 codegen: multi-index expected array-of-array on inner level, got %s"
                    curTy.Name
            let elemTy =
                match Option.ofObj (curTy.GetElementType()) with
                | Some t -> t
                | None   -> typeof<obj>
            let _ = emitExpr ctx idx
            il.Emit(OpCodes.Ldelem, elemTy)
            curTy <- elemTy
        curTy

    | EIndex (_, []) ->
        failwith "E7 codegen: indexing with no indices"

    // ---- tuple literal ------------------------------------------------

    | ETuple [single] -> emitExpr ctx single

    | ETuple items when items.Length >= 2 ->
        // Tuples up to size 7 lower to `ValueTuple<…>` directly.
        // For 8+, the CLR shape is
        //   `ValueTuple<T1..T7, ValueTuple<T8..>>` (TRest carrying
        // the overflow recursively).  Build by emitting the first
        // 7 items, then recurse to build the rest tuple.  The TRest
        // arg must itself be a `struct` ValueTuple, so a single-
        // item tail wraps in `ValueTuple<T>` rather than passing the
        // bare value through.
        let openByArity (n: int) : System.Type =
            match n with
            | 1 -> typedefof<System.ValueTuple<_>>
            | 2 -> typedefof<System.ValueTuple<_, _>>
            | 3 -> typedefof<System.ValueTuple<_, _, _>>
            | 4 -> typedefof<System.ValueTuple<_, _, _, _>>
            | 5 -> typedefof<System.ValueTuple<_, _, _, _, _>>
            | 6 -> typedefof<System.ValueTuple<_, _, _, _, _, _>>
            | 7 -> typedefof<System.ValueTuple<_, _, _, _, _, _, _>>
            | _ -> typedefof<System.ValueTuple<_, _, _, _, _, _, _, _>>
        let rec build (xs: Expr list) : ClrType =
            if xs.Length <= 7 then
                let elemTypes =
                    xs |> List.map (fun e -> emitExpr ctx e) |> List.toArray
                let closedTy = (openByArity xs.Length).MakeGenericType elemTypes
                let ctor = closedTy.GetConstructor elemTypes
                match Option.ofObj ctor with
                | Some c ->
                    il.Emit(OpCodes.Newobj, c)
                    closedTy
                | None ->
                    failwithf "E7 codegen: ValueTuple ctor not found for %d args" xs.Length
            else
                let front = List.take 7 xs
                let rest  = List.skip 7 xs
                let frontTys =
                    front |> List.map (fun e -> emitExpr ctx e) |> List.toArray
                let restTy = build rest
                let allTys = Array.append frontTys [| restTy |]
                let closedTy = (openByArity 8).MakeGenericType allTys
                let ctor = closedTy.GetConstructor allTys
                match Option.ofObj ctor with
                | Some c ->
                    il.Emit(OpCodes.Newobj, c)
                    closedTy
                | None ->
                    failwithf "E7 codegen: ValueTuple-with-rest ctor not found for arity %d"
                        xs.Length
        build items

    | ETuple items ->
        failwithf "E7 codegen: tuple of %d elements not yet supported"
            (List.length items)

    | EParen inner -> emitExpr ctx inner

    // ---- self ---------------------------------------------------------

    // Async state-machine MoveNext: `self` lives in the SM's
    // `self` field rather than at `Ldarg.0` (which is the SM
    // instance, not the record).  Check `SmFields` first so this
    // case wins over the regular impl-method `IsInstance` path.
    | ESelf when ctx.SmFields.ContainsKey "self" ->
        let f = ctx.SmFields.["self"]
        il.Emit(OpCodes.Ldarg_0)
        il.Emit(OpCodes.Ldfld, f)
        f.FieldType

    | ESelf when ctx.IsInstance ->
        il.Emit(OpCodes.Ldarg_0)
        match ctx.SelfType with
        | Some t -> t
        | None   -> typeof<obj>

    | ESelf ->
        // D037: methods declared inline in a record body hoist to
        // top-level UFCS functions whose first parameter is named
        // `self`.  When the body says `self.x`, the parser produces
        // `EMember(ESelf, "x")`; resolve `ESelf` against that
        // parameter so inline methods Just Work without an AST
        // rewrite pass.
        match ctx.Params.TryGetValue "self" with
        | true, (idx, pty) ->
            il.Emit(OpCodes.Ldarg, idx)
            pty
        | _ ->
            failwith "E12 codegen: 'self' used outside of an impl method"

    // ---- await -------------------------------------------------------
    // Two emit modes:
    //   * `ctx.SmAwaitInfo = None` — M1.4 blocking shim.  Emit the
    //     Task[T]-shaped value, call `GetAwaiter().GetResult()`,
    //     propagate the unwrapped type.  Used in `main` and other
    //     non-async call sites, plus async funcs whose body is
    //     ineligible for state-machine lowering.
    //   * `ctx.SmAwaitInfo = Some info` — Phase B suspend/resume
    //     protocol.  Stash the awaiter, branch on `IsCompleted`;
    //     if not completed, save state + awaiter to SM fields,
    //     flush promoted-local IL locals to SM fields, call
    //     `builder.AwaitUnsafeOnCompleted<TAwaiter, TStateMachine>`,
    //     `Leave` to the suspend exit; on resume, reload the
    //     awaiter from its field, clear it, set state back to -1,
    //     fall through to `GetResult`.

    | EAwait inner ->
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
            let openGetAwaiter =
                let mi = typedefof<System.Threading.Tasks.Task<_>>.GetMethod("GetAwaiter")
                match Option.ofObj mi with
                | Some m -> m
                | None -> failwith "E14 codegen: Task<>.GetAwaiter open-generic not found"
            let closedGetAwaiter =
                TypeBuilder.GetMethod(taskTy, openGetAwaiter)
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

        match ctx.SmAwaitInfo with
        | None ->
            // Blocking shim — call GetResult directly.
            il.Emit(OpCodes.Ldloca, awLoc)
            il.Emit(OpCodes.Call, getResult)
            returnedTy
        | Some smAwait ->
            let stateIndex = smAwait.NextAwaitIndex
            smAwait.NextAwaitIndex <- stateIndex + 1
            // Lazily define the awaiter SM field for this site —
            // the awaiter type wasn't known until `emitExpr` on
            // the inner task expression returned its CLR type.
            let awaiterField =
                Lyric.Emitter.AsyncStateMachine.defineAwaiterField
                    smAwait.Sm stateIndex awaiterTy
            smAwait.AwaiterFields.[stateIndex] <- awaiterField
            let resumeLabel = smAwait.ResumeLabels.[stateIndex]
            let afterAwait = il.DefineLabel()

            // Resolve `IsCompleted` on the awaiter.  For
            // `TaskAwaiter<T>` closed over a TypeBuilder (a Lyric
            // record/union still under construction),
            // `Type.GetProperty` raises NotSupportedException; we
            // route through `TypeBuilder.GetMethod` against the
            // open-generic getter on `TaskAwaiter<>`.
            let awaiterClosedOverTb =
                awaiterTy.IsGenericType
                && awaiterTy.GetGenericArguments()
                   |> Array.exists (fun a ->
                       a :? TypeBuilder
                       || (a.IsGenericType && a.GetGenericArguments() |> Array.exists (fun b -> b :? TypeBuilder)))
            let isCompletedGetter =
                if awaiterClosedOverTb && awaiterTy.GetGenericTypeDefinition() = typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>> then
                    let openTaskAwaiter =
                        typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>>
                    let openGetter =
                        openTaskAwaiter.GetMethods()
                        |> Array.tryFind (fun m -> m.Name = "get_IsCompleted")
                    match openGetter with
                    | Some m -> TypeBuilder.GetMethod(awaiterTy, m)
                    | None -> failwithf "BCL: TaskAwaiter<>.get_IsCompleted not found"
                else
                    match Option.ofObj (awaiterTy.GetProperty("IsCompleted")) with
                    | Some p ->
                        match Option.ofObj (p.GetGetMethod()) with
                        | Some g -> g
                        | None   -> failwithf "E14 codegen: %s.get_IsCompleted missing" awaiterTy.Name
                    | None -> failwithf "E14 codegen: %s.IsCompleted property missing" awaiterTy.Name
            il.Emit(OpCodes.Ldloca, awLoc)
            il.Emit(OpCodes.Call, isCompletedGetter)
            il.Emit(OpCodes.Brtrue, afterAwait)

            // ---- suspend path ----
            // this.<>1__state = N
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldc_I4, stateIndex)
            il.Emit(OpCodes.Stfld, smAwait.Sm.State)
            // this.<>u__N = awaiter
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldloc, awLoc)
            il.Emit(OpCodes.Stfld, awaiterField)
            // Flush promoted IL locals back to their SM fields so the
            // values survive the cross-resume gap.
            for (lb, fld) in smAwait.PromotedShadows do
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldloc, lb)
                il.Emit(OpCodes.Stfld, fld)
            // builder.AwaitUnsafeOnCompleted<TAwaiter, TStateMachine>(ref awaiter, ref this)
            // For builders closed over a TypeBuilder (e.g.
            // `AsyncTaskMethodBuilder<MaybeBalance>` where
            // MaybeBalance is a Lyric union under construction),
            // `Type.GetMethods` raises NotSupportedException.
            // Look up the method on the open-generic builder
            // definition instead, then re-resolve via
            // `TypeBuilder.GetMethod` and `MakeGenericMethod`.
            let builderTy = smAwait.Sm.BuilderType
            let builderClosedOverTb =
                builderTy.IsGenericType
                && builderTy.GetGenericArguments()
                   |> Array.exists (fun a ->
                       a :? TypeBuilder
                       || (a.IsGenericType && a.GetGenericArguments() |> Array.exists (fun b -> b :? TypeBuilder)))
            let closedAwaitUnsafe =
                if builderClosedOverTb && builderTy.IsGenericType
                   && builderTy.GetGenericTypeDefinition() = typedefof<System.Runtime.CompilerServices.AsyncTaskMethodBuilder<_>> then
                    let openBuilder = typedefof<System.Runtime.CompilerServices.AsyncTaskMethodBuilder<_>>
                    let openOnDef =
                        openBuilder.GetMethods()
                        |> Array.tryFind (fun m ->
                            m.Name = "AwaitUnsafeOnCompleted"
                            && m.IsGenericMethodDefinition
                            && m.GetGenericArguments().Length = 2)
                    let closedOnBuilder =
                        match openOnDef with
                        | Some m -> TypeBuilder.GetMethod(builderTy, m)
                        | None ->
                            failwithf "BCL: AsyncTaskMethodBuilder<>.AwaitUnsafeOnCompleted<,> not found"
                    closedOnBuilder.MakeGenericMethod([| awaiterTy; (smAwait.Sm.Type :> System.Type) |])
                else
                    let openAwaitUnsafe =
                        builderTy.GetMethods()
                        |> Array.tryFind (fun m ->
                            m.Name = "AwaitUnsafeOnCompleted"
                            && m.IsGenericMethodDefinition
                            && m.GetGenericArguments().Length = 2)
                    match openAwaitUnsafe with
                    | Some m ->
                        m.MakeGenericMethod([| awaiterTy; (smAwait.Sm.Type :> System.Type) |])
                    | None ->
                        failwithf "BCL: %s.AwaitUnsafeOnCompleted<,> not found"
                            builderTy.Name
            // For a class state machine, `ref TStateMachine` must
            // be the address of a *local* holding the SM reference,
            // not `this` directly (`Ldarg_0` is the reference value,
            // not its address).  Roslyn-equivalent pattern:
            //   var sm = this;  builder.AwaitUnsafeOnCompleted(... ref sm);
            let smLocal =
                FunctionCtx.defineLocal ctx "__this_sm" (smAwait.Sm.Type :> System.Type)
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Stloc, smLocal)
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldflda, smAwait.Sm.Builder)
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldflda, awaiterField)
            il.Emit(OpCodes.Ldloca, smLocal)
            il.Emit(OpCodes.Call, closedAwaitUnsafe)
            il.Emit(OpCodes.Leave, smAwait.SuspendLeaveLabel)

            // ---- resume label ----
            il.MarkLabel(resumeLabel)
            // awaiter = this.<>u__N
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldfld, awaiterField)
            il.Emit(OpCodes.Stloc, awLoc)
            // this.<>u__N = default(TAwaiter)
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldflda, awaiterField)
            il.Emit(OpCodes.Initobj, awaiterTy)
            // this.<>1__state = -1
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldc_I4_M1)
            il.Emit(OpCodes.Stfld, smAwait.Sm.State)

            // ---- after-await label (joined fast/slow path) ----
            il.MarkLabel(afterAwait)
            il.Emit(OpCodes.Ldloca, awLoc)
            il.Emit(OpCodes.Call, getResult)
            returnedTy

    // ---- result (in ensures clauses) ----------------------------------
    // `result` is a contextual keyword: inside `ensures:` it names the
    // function's return value (ResultLocal); everywhere else it is an
    // ordinary local/parameter name.  To tell the cases apart, prefer
    // a user-declared local or parameter named "result" — if one is in
    // scope it was explicitly bound and should shadow the magic meaning.
    // Only fall back to ResultLocal when no such binding exists, which
    // in practice means we are in an ensures post-condition.

    | EResult ->
        match FunctionCtx.tryLookup ctx "result" with
        | Some lb ->
            il.Emit(OpCodes.Ldloc, lb)
            lb.LocalType
        | None ->
            match ctx.Params.TryGetValue "result" with
            | true, (idx, pty) ->
                il.Emit(OpCodes.Ldarg, idx)
                pty
            | _ ->
                match ctx.ResultLocal with
                | Some loc ->
                    il.Emit(OpCodes.Ldloc, loc)
                    loc.LocalType
                | None ->
                    failwith "E15 codegen: 'result' used outside an ensures clause and no local/param named 'result'"

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

    // ---- projectable view: v.tryInto() -> Result[<Name>, String] ------

    | ECall ({ Kind = EMember (recv, "tryInto") }, []) ->
        let recvTy = emitExpr ctx recv
        // The receiver is the view type; locate the projectable whose
        // ViewType matches.  Reflection on the TypeBuilder isn't safe
        // until it's sealed, so look up via the projectable table.
        let proj =
            ctx.Projectables.Values
            |> Seq.tryFind (fun p ->
                (p.ViewType.Type :> ClrType) = recvTy)
        match proj with
        | Some p ->
            match p.TryIntoMethod with
            | Some mi ->
                il.Emit(OpCodes.Callvirt, mi)
                mi.ReturnType
            | None ->
                failwithf "M2.2 codegen: '%sView::tryInto' was not synthesised (nested-projectable view or `import Std.Core` missing)"
                    p.OpaqueName
        | None ->
            failwithf "M2.2 codegen: receiver %s is not a known projectable view type"
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

    // ---- UFCS-style static dispatch: `Type.method(args)` lowers to a
    // ---- direct call to a function literally named `Type.method`.
    // ---- The parser tolerates dotted function names today, so unions
    // ---- like `errors.l`'s `IOError.message` end up as functions
    // ---- whose name is the full dotted form.  Match them first so
    // ---- we don't fall through to `EMember` evaluation that would
    // ---- try to read a value off the type name.
    | ECall ({ Kind = EMember ({ Kind = EPath { Segments = [head] } }, methodName) }, args)
        when ctx.Funcs.ContainsKey (head + "." + methodName) ->
        let mb = ctx.Funcs.[head + "." + methodName]
        let paramTypes =
            mb.GetParameters() |> Array.map (fun p -> p.ParameterType)
        args
        |> List.iteri (fun i a ->
            let payload =
                match a with
                | CAPositional ex | CANamed (_, ex, _) -> ex
            let argTy = emitExpr ctx payload
            if i < paramTypes.Length then
                let pty = paramTypes.[i]
                if pty = typeof<obj> && argTy.IsValueType then
                    il.Emit(OpCodes.Box, argTy))
        il.Emit(OpCodes.Call, mb)
        if mb.ReturnType = typeof<System.Void> then typeof<System.Void>
        else mb.ReturnType

    | ECall ({ Kind = EMember ({ Kind = EPath { Segments = [head] } }, methodName) }, args)
        when ctx.ImportedFuncs.ContainsKey (head + "." + methodName) ->
        let info = ctx.ImportedFuncs.[head + "." + methodName]
        let paramTypes =
            info.Method.GetParameters() |> Array.map (fun p -> p.ParameterType)
        args
        |> List.iteri (fun i a ->
            let payload =
                match a with
                | CAPositional ex | CANamed (_, ex, _) -> ex
            let argTy = emitExpr ctx payload
            if i < paramTypes.Length then
                let pty = paramTypes.[i]
                if pty = typeof<obj> && argTy.IsValueType then
                    il.Emit(OpCodes.Box, argTy))
        il.Emit(OpCodes.Call, info.Method)
        if info.Method.ReturnType = typeof<System.Void> then typeof<System.Void>
        else info.Method.ReturnType

    // ---- C4 phase 1+2: score-based auto-FFI on extern-type static methods.
    // ---- For `ExternTypeName.method(args)` where `ExternTypeName` is
    // ---- registered as a Lyric extern type and no explicit
    // ---- `@externTarget` covers it, search the CLR type's static
    // ---- methods.  Each candidate's per-parameter coercion score
    // ---- is summed; the lowest-total-cost candidate wins.  Ties
    // ---- surface as an ambiguity diagnostic.  Phase 2 widens the
    // ---- accepted shapes (Int→Long, Int→Double, boxing/unboxing,
    // ---- assignment compatibility) over Phase 1's exact match.
    | ECall ({ Kind = EMember ({ Kind = EPath { Segments = [head] } }, methodName) }, args)
        when ctx.ExternTypeNames.ContainsKey head ->
        let recvTy = ctx.ExternTypeNames.[head]
        // Emit args first so we know their CLR types for matching.
        let argLocals =
            args
            |> List.map (fun a ->
                let payload =
                    match a with
                    | CAPositional ex | CANamed (_, ex, _) -> ex
                let argTy = emitExpr ctx payload
                let lb = FunctionCtx.defineLocal ctx ("__ext_arg") argTy
                il.Emit(OpCodes.Stloc, lb)
                lb, argTy)
        let argTys = argLocals |> List.map snd |> List.toArray
        let candidatesForName (n: string) =
            recvTy.GetMethods()
            |> Array.filter (fun m ->
                m.Name = n
                && m.IsStatic
                && m.GetParameters().Length = argTys.Length)
        // Per-arg coercion cost.  `None` = incompatible (skip
        // candidate).  Lower numbers = better fit.
        let coercionCost (paramTy: ClrType) (argTy: ClrType) : int option =
            if paramTy = argTy then Some 0
            elif paramTy.IsAssignableFrom(argTy) then Some 1
            elif paramTy = typeof<int64> && argTy = typeof<int> then Some 2
            elif paramTy = typeof<double> && argTy = typeof<int> then Some 3
            elif paramTy = typeof<double> && argTy = typeof<int64> then Some 3
            elif paramTy = typeof<float32> && argTy = typeof<int> then Some 4
            elif paramTy = typeof<float32> && argTy = typeof<double> then Some 4
            elif paramTy = typeof<obj> && argTy.IsValueType then Some 5
            elif paramTy.IsValueType && argTy = typeof<obj> then Some 6
            else None
        let candidateCost (m: System.Reflection.MethodInfo) : int option =
            let pars = m.GetParameters()
            let mutable total = 0
            let mutable ok = true
            for i in 0 .. argTys.Length - 1 do
                if ok then
                    match coercionCost pars.[i].ParameterType argTys.[i] with
                    | Some c -> total <- total + c
                    | None -> ok <- false
            if ok then Some total else None
        // Score-based pick: lowest total cost; tie → ambiguous.
        let pickByScore (cands: System.Reflection.MethodInfo array) =
            let scored =
                cands
                |> Array.choose (fun m ->
                    match candidateCost m with
                    | Some c -> Some (m, c)
                    | None   -> None)
            if Array.isEmpty scored then None
            else
                let minCost = scored |> Array.map snd |> Array.min
                let winners =
                    scored
                    |> Array.filter (fun (_, c) -> c = minCost)
                match winners with
                | [| m, _ |] -> Some m
                | _ -> None  // ambiguous tie
        let pasc = capitalizeFirst methodName
        let resolved =
            match pickByScore (candidatesForName methodName) with
            | Some m -> Some m
            | None when pasc <> methodName ->
                pickByScore (candidatesForName pasc)
            | None -> None
        match resolved with
        | Some mi ->
            // Re-load each arg from its temp local with the right
            // numeric / boxing conversion based on the param type.
            let pars = mi.GetParameters()
            let emitCoercion (paramTy: ClrType) (argTy: ClrType) =
                if paramTy = argTy then ()
                elif paramTy = typeof<int64> && argTy = typeof<int> then
                    il.Emit(OpCodes.Conv_I8)
                elif paramTy = typeof<double> && argTy = typeof<int> then
                    il.Emit(OpCodes.Conv_R8)
                elif paramTy = typeof<double> && argTy = typeof<int64> then
                    il.Emit(OpCodes.Conv_R8)
                elif paramTy = typeof<float32> && argTy = typeof<int> then
                    il.Emit(OpCodes.Conv_R4)
                elif paramTy = typeof<float32> && argTy = typeof<double> then
                    il.Emit(OpCodes.Conv_R4)
                elif paramTy = typeof<obj> && argTy.IsValueType then
                    il.Emit(OpCodes.Box, argTy)
                elif paramTy.IsValueType && argTy = typeof<obj> then
                    il.Emit(OpCodes.Unbox_Any, paramTy)
            argLocals
            |> List.iteri (fun i (lb, argTy) ->
                il.Emit(OpCodes.Ldloc, lb)
                emitCoercion pars.[i].ParameterType argTy)
            il.Emit(OpCodes.Call, mi)
            if mi.ReturnType = typeof<System.Void> then typeof<System.Void>
            else mi.ReturnType
        | None ->
            // Unresolved — surface a structured diagnostic.  Show all
            // viable arity-matched overloads if the failure was a tie,
            // otherwise note "no match".
            let allArityMatches =
                Array.append
                    (candidatesForName methodName)
                    (if pasc <> methodName then candidatesForName pasc else [||])
            let extra =
                if Array.isEmpty allArityMatches then ""
                else
                    let sigs =
                        allArityMatches
                        |> Array.map (fun m ->
                            let ps =
                                m.GetParameters()
                                |> Array.map (fun p -> p.ParameterType.Name)
                                |> String.concat ", "
                            sprintf "  - %s(%s) -> %s"
                                m.Name ps m.ReturnType.Name)
                        |> String.concat "\n"
                    sprintf "; viable overloads:\n%s" sigs
            codegenErr ctx "E0004"
                (sprintf "auto-FFI: no unique static method '%s' on %s matching the supplied arg types%s"
                    methodName recvTy.FullName extra)
                e.Span

    // ---- method-style call (callvirt on interface or class method) ----

    | ECall ({ Kind = EMember (recv, methodName) }, args) ->
        let recvTy = emitExpr ctx recv
        // D-progress-079: protected-type method dispatch.  The
        // receiver is already on the stack; route to the public
        // wrapper MethodBuilder via callvirt so the lock acquire +
        // release happens around the user's body.  Routes here
        // before the record-UFCS short-circuit because protected
        // types ALSO sit in `ctx.Records` (as a stub for ctor
        // dispatch) — without this branch the UFCS path would
        // mis-resolve `c.incr()` against `Counter.incr` UFCS that
        // doesn't exist.
        // Match the receiver's CLR type against a known protected
        // type: for non-generic protected types `recvTy = info.Type`;
        // for generic ones `recvTy` is a closed generic instance and
        // we compare its open definition against `info.Type`.
        let protectedHit
                : (Lyric.Emitter.Records.ProtectedTypeInfo
                   * Lyric.Emitter.Records.ProtectedMethod) option =
            let recvOpenDef =
                if recvTy.IsGenericType && not recvTy.IsGenericTypeDefinition
                then recvTy.GetGenericTypeDefinition()
                else recvTy
            ctx.ProtectedTypes
            |> Seq.tryPick (fun kv ->
                if (kv.Value.Type :> System.Type) = recvOpenDef then
                    kv.Value.Methods
                    |> List.tryFind (fun m -> m.Name = methodName)
                    |> Option.map (fun m -> kv.Value, m)
                else None)
        match protectedHit with
        | Some (info, pm) ->
            // Receiver is already on the stack; emit args next.
            for a in args do
                let payload =
                    match a with
                    | CAPositional ex | CANamed (_, ex, _) -> ex
                let _ = emitExpr ctx payload
                ()
            // Generic protected types: rebind the open MethodBuilder
            // onto the closed receiver type via TypeBuilder.GetMethod
            // so the Callvirt targets `Box<int>::put`, not the open
            // `Box<>::put`.  Non-generic protected types keep the
            // direct `pm.Method` reference.
            let isGenericReceiver =
                not info.Generics.IsEmpty
                && recvTy.IsGenericType
                && not recvTy.IsGenericTypeDefinition
            let methodRef : System.Reflection.MethodInfo =
                if isGenericReceiver then
                    System.Reflection.Emit.TypeBuilder.GetMethod(
                        recvTy, pm.Method)
                else
                    pm.Method :> System.Reflection.MethodInfo
            il.Emit(OpCodes.Callvirt, methodRef)
            // `TypeBuilder.GetMethod`'s `ReturnType` is the open
            // method's return type (still in terms of the GTPBs), so
            // substitute against the closed receiver's generic args
            // for value-type-aware downstream consumers (boxing, etc).
            let returnTy =
                if methodRef.ReturnType = typeof<System.Void> then
                    typeof<System.Void>
                elif isGenericReceiver then
                    substituteGenericArgs methodRef.ReturnType recvTy
                else
                    methodRef.ReturnType
            returnTy
        | None ->
        // D037: methods declared inline in a record / opaque body
        // hoist to top-level UFCS-style `<TypeName>.<methodName>`
        // functions.  When the receiver is a known local record /
        // opaque whose dotted-name function is in scope, dispatch to
        // that static call (passing recv as the first arg) before any
        // reflection-based lookup — `recvTy.GetMethods()` would throw
        // because the TypeBuilder isn't sealed yet.
        let inlineUfcsCall : (MethodBuilder * string) option =
            let typeName =
                ctx.Records
                |> Seq.tryPick (fun kv ->
                    if (kv.Value.Type :> System.Type) = recvTy then Some kv.Key
                    else None)
            match typeName with
            | Some n ->
                let key = n + "." + methodName
                match ctx.Funcs.TryGetValue key with
                | true, mb -> Some (mb, key)
                | _ -> None
            | None -> None
        match inlineUfcsCall with
        | Some (mb, _) ->
            // Receiver is already on the stack; emit args next.
            for a in args do
                let payload =
                    match a with
                    | CAPositional ex | CANamed (_, ex, _) -> ex
                let _ = emitExpr ctx payload
                ()
            il.Emit(OpCodes.Call, mb)
            if mb.ReturnType = typeof<System.Void> then typeof<System.Void>
            else mb.ReturnType
        | None ->

        // Try to find an interface method with this name.
        let ifaceMethod =
            ctx.Interfaces.Values
            |> Seq.collect (fun i -> i.Members |> List.map (fun m -> i, m))
            |> Seq.tryFind (fun (_, m) -> m.Name = methodName)
        // (method, extra-default-params): extra is [] except for BCL calls
        // that match a method with more params than supplied args.
        let miOpt : (MethodInfo * System.Reflection.ParameterInfo array) option =
            match ifaceMethod with
            | Some (_, m) -> Some (m.Method :> MethodInfo, [||])
            | None ->
                // Fall back to a method on the receiver's CLR type
                // by reflection. This catches impl-method calls where
                // we have a concrete target type.
                // `TypeBuilderInstantiation.GetMethods` isn't supported,
                // so when recvTy is a closed-on-GTPB generic (we're
                // inside a Lyric generic function), enumerate methods
                // on the open definition and substitute via
                // `TypeBuilder.GetMethod` once we pick the right one.
                let exact =
                    getRecvMethods recvTy
                    |> Array.tryFind (fun m ->
                        m.Name = methodName && not m.IsStatic)
                    |> Option.map (closeBclMethod recvTy)
                match exact with
                | Some m -> Some (m, [||])
                | None when isBclType recvTy ->
                    // BCL fallback: lyric `s.trim()` -> CLR `String.Trim()`.
                    // Peek arg types so overloads can be resolved by shape.
                    // resolveBclMethod also tries methods with extra HasDefaultValue
                    // params, returning those extras so we can push their defaults.
                    let argTys =
                        args
                        |> List.map (fun a ->
                            let payload =
                                match a with
                                | CAPositional ex | CANamed (_, ex, _) -> ex
                            peekExprType ctx payload)
                        |> Array.ofList
                    resolveBclMethod recvTy (capitalizeFirst methodName) argTys
                | None -> None
        match miOpt with
        | Some (method, extraParams) ->
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
            // Push CLR default values for any extra parameters not supplied by the caller.
            for p in extraParams do
                match p.DefaultValue with
                | null -> il.Emit(OpCodes.Ldnull)
                | dv when p.ParameterType = typeof<bool> ->
                    il.Emit(OpCodes.Ldc_I4, if unbox<bool> dv then 1 else 0)
                | dv when p.ParameterType.IsEnum || p.ParameterType = typeof<int> ->
                    il.Emit(OpCodes.Ldc_I4, unbox<int> dv)
                | dv when p.ParameterType = typeof<string> ->
                    il.Emit(OpCodes.Ldstr, unbox<string> dv)
                | _ ->
                    // Value-type default: zero-init via a temp local.
                    let tmp = FunctionCtx.defineLocal ctx "__default" p.ParameterType
                    il.Emit(OpCodes.Ldloca, tmp)
                    il.Emit(OpCodes.Initobj, p.ParameterType)
                    il.Emit(OpCodes.Ldloc, tmp)
            if useCallNotCallvirt then
                il.Emit(OpCodes.Call, method)
            else
                il.Emit(OpCodes.Callvirt, method)
            if method.ReturnType = typeof<System.Void> then
                typeof<System.Void>
            else
                method.ReturnType
        | None ->
            codegenErr ctx "E0012"
                (sprintf "no method '%s' on type %s" methodName recvTy.Name) e.Span

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
                // CLR receiver type.  For a constructed generic record
                // (`Box<int>`), the lookup compares against the open
                // generic definition (`Box<>`) since `r.Type` is the
                // open TypeBuilder.
                let recvOpenTy =
                    if recvTy.IsGenericType && not recvTy.IsGenericTypeDefinition
                    then recvTy.GetGenericTypeDefinition()
                    else recvTy
                let info =
                    ctx.Records.Values
                    |> Seq.tryFind (fun r ->
                        (r.Type :> ClrType) = recvTy
                        || (r.Type :> ClrType) = recvOpenTy)
                match info with
                | Some r ->
                    match r.Fields |> List.tryFind (fun f -> f.Name = fieldName) with
                    | Some f ->
                        // Generic record on a constructed instantiation:
                        // close the FieldBuilder via TypeBuilder.GetField
                        // and project f.Type's CLR type through the
                        // generic substitution so the result type carries
                        // the closed generic args.
                        let isConstructed =
                            r.Generics.Length > 0
                            && recvTy.IsGenericType
                            && not recvTy.IsGenericTypeDefinition
                        if isConstructed then
                            let closedField =
                                System.Reflection.Emit.TypeBuilder.GetField(recvTy, f.Field)
                            il.Emit(OpCodes.Ldfld, closedField)
                            // Substitute generic args from recvTy into
                            // f.LyricType to compute the field's closed
                            // CLR type.
                            let cargs = recvTy.GetGenericArguments()
                            let substMap =
                                List.zip r.Generics (List.ofArray cargs)
                                |> Map.ofList
                            Lyric.Emitter.TypeMap.toClrTypeWithGenerics
                                ctx.Lookup substMap f.LyricType
                        else
                            il.Emit(OpCodes.Ldfld, f.Field)
                            f.Type
                    | None ->
                        failwithf "E5/E7 codegen: record '%s' has no field '%s'"
                            r.Name fieldName
                | None when isBclType recvTy ->
                    // BCL property fallback: lyric `s.length` -> `String.Length`.
                    let propName = capitalizeFirst fieldName
                    let prop = recvTy.GetProperty(propName)
                    let getter =
                        match Option.ofObj prop with
                        | Some p when p.CanRead ->
                            Option.ofObj (p.GetGetMethod())
                            |> Option.map (fun g -> g, p.PropertyType)
                        | _ -> None
                    match getter with
                    | Some (g, ty) ->
                        if recvTy.IsValueType then
                            let recvLoc = FunctionCtx.defineLocal ctx "__bcl_recv" recvTy
                            il.Emit(OpCodes.Stloc, recvLoc)
                            il.Emit(OpCodes.Ldloca, recvLoc)
                            il.Emit(OpCodes.Call, g)
                        else
                            il.Emit(OpCodes.Callvirt, g)
                        ty
                    | None ->
                        failwithf "E5/E7 codegen: receiver type %s has no readable property '%s'"
                            recvTy.Name fieldName
                | None ->
                    failwithf "E5/E7 codegen: receiver type %s is not a known record or distinct type"
                        recvTy.Name

    // ---- variable read ------------------------------------------------

    | EPath { Segments = [name] } ->
        // Order: local → SM field (async state-machine MoveNext) →
        // parameter slot → enum case → nullary union case → fallthrough.
        match FunctionCtx.tryLookup ctx name with
        | Some lb ->
            il.Emit(OpCodes.Ldloc, lb)
            lb.LocalType
        | None ->
            match ctx.SmFields.TryGetValue name with
            | true, f ->
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldfld, f)
                f.FieldType
            | _ ->
            match ctx.Params.TryGetValue name with
            | true, (idx, pty) ->
                il.Emit(OpCodes.Ldarg, idx)
                if pty.IsByRef then
                    let elem =
                        match Option.ofObj (pty.GetElementType()) with
                        | Some t -> t
                        | None   -> typeof<obj>
                    // Unboxed read of `T&`: `Ldobj` for value-typed
                    // structs / enums, `Ldind.Ref` for reference types.
                    if elem.IsValueType then il.Emit(OpCodes.Ldobj, elem)
                    else il.Emit(OpCodes.Ldind_Ref)
                    elem
                else
                    pty
            | _ ->
                match ctx.EnumCases.TryGetValue name with
                | true, (info, c) ->
                    emitLdcI4 il c.Ordinal
                    info.Type
                | _ ->
                    // Nullary case context-driven inference: prefer
                    // `ctx.ExpectedType` (set by val annotations / call
                    // arg positions / etc.), then fall back to
                    // `ctx.ReturnType` (the enclosing function's
                    // result), defaulting to obj only when neither
                    // shape matches the union's type-param count.
                    let inferTypeArgsFromReturn (genericCount: int) : ClrType array =
                        let tryFrom (t: ClrType) : ClrType array option =
                            if t.IsGenericType then
                                let gargs = t.GetGenericArguments()
                                if gargs.Length = genericCount then Some gargs
                                else None
                            else None
                        let fromExpected =
                            ctx.ExpectedType |> Option.bind tryFrom
                        match fromExpected with
                        | Some ts -> ts
                        | None ->
                            match tryFrom ctx.ReturnType with
                            | Some ts -> ts
                            | None    -> Array.create genericCount typeof<obj>
                    match ctx.UnionCases.TryGetValue name with
                    | true, (info, caseInfo) when caseInfo.Fields.IsEmpty ->
                        // Nullary case literal — `None` / `Leaf` etc.
                        if List.isEmpty info.Generics then
                            il.Emit(OpCodes.Newobj, caseInfo.Ctor)
                            info.Type :> ClrType
                        else
                            let typeArgs =
                                inferTypeArgsFromReturn info.Generics.Length
                            let constructedCase =
                                (caseInfo.Type :> System.Type).MakeGenericType typeArgs
                            let constructedCtor =
                                TypeBuilder.GetConstructor(constructedCase, caseInfo.Ctor)
                            let constructedParent =
                                (info.Type :> System.Type).MakeGenericType typeArgs
                            il.Emit(OpCodes.Newobj, constructedCtor)
                            constructedParent
                    | _ ->
                        // Imported nullary case (cross-assembly).
                        match ctx.ImportedUnionCases.TryGetValue name with
                        | true, (info, caseInfo) when caseInfo.Fields.IsEmpty ->
                            if List.isEmpty info.Generics then
                                il.Emit(OpCodes.Newobj, caseInfo.Ctor)
                                info.Type
                            else
                                let typeArgs =
                                    inferTypeArgsFromReturn info.Generics.Length
                                let constructedCase =
                                    caseInfo.Type.MakeGenericType typeArgs
                                let openCtor = caseInfo.Ctor
                                let constructedCtor =
                                    if typeArgs |> Array.exists (fun t ->
                                          t :? System.Reflection.Emit.GenericTypeParameterBuilder)
                                    then
                                        System.Reflection.Emit.TypeBuilder.GetConstructor(constructedCase, openCtor)
                                    else
                                        constructedCase.GetConstructors() |> Array.head
                                il.Emit(OpCodes.Newobj, constructedCtor)
                                info.Type.MakeGenericType typeArgs
                        | _ ->
                            codegenErr ctx "E0004"
                                (sprintf "unknown name '%s'" name) e.Span

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
        | BEq when lt = typeof<string> && rt = typeof<string> ->
            // String equality: `Ceq` would compare by reference.  Route
            // through `String.op_Equality(string, string)` so the
            // common path matches user expectation.
            let opEq =
                typeof<System.String>
                    .GetMethod("op_Equality", [| typeof<string>; typeof<string> |])
            match Option.ofObj opEq with
            | Some m ->
                il.Emit(OpCodes.Call, m)
                typeof<bool>
            | None ->
                il.Emit(OpCodes.Ceq)
                typeof<bool>
        | BNeq when lt = typeof<string> && rt = typeof<string> ->
            let opNeq =
                typeof<System.String>
                    .GetMethod("op_Inequality", [| typeof<string>; typeof<string> |])
            match Option.ofObj opNeq with
            | Some m ->
                il.Emit(OpCodes.Call, m)
                typeof<bool>
            | None ->
                il.Emit(OpCodes.Ceq); emitLdcI4 il 0; il.Emit(OpCodes.Ceq)
                typeof<bool>
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
        // Resolve each field's value-expression up front, in order, so
        // we can inspect arg CLR types before deciding how to bind any
        // generic parameters of the union.
        let mutable posIdx = 0
        let argExprs =
            caseInfo.Fields
            |> List.map (fun f ->
                match Map.tryFind f.Name namedMap with
                | Some ex -> ex
                | None ->
                    if posIdx < List.length positional then
                        let ex = List.item posIdx positional
                        posIdx <- posIdx + 1
                        ex
                    else
                        failwithf "E11 codegen: union case '%s' missing field '%s'"
                            name f.Name)
        if List.isEmpty info.Generics then
            // Non-generic union: emit args directly, box value types into
            // erased `obj` payload slots, then `Newobj` the case ctor.
            for (f, argExpr) in List.zip caseInfo.Fields argExprs do
                let argTy = emitExpr ctx argExpr
                if f.Type = typeof<obj> && argTy.IsValueType then
                    il.Emit(OpCodes.Box, argTy)
            il.Emit(OpCodes.Newobj, caseInfo.Ctor)
            info.Type :> ClrType
        else
            // Generic union: peek each arg's CLR type without emitting
            // first so we can bind the union's generic parameters.
            let bindings = Dictionary<string, ClrType>()
            let rec bind (lyricTy: Lyric.TypeChecker.Type) (argTy: ClrType) =
                match lyricTy with
                | Lyric.TypeChecker.TyVar n ->
                    if not (bindings.ContainsKey n) then bindings.[n] <- argTy
                | _ -> ()
            for (f, argExpr) in List.zip caseInfo.Fields argExprs do
                bind f.LyricType (peekExprType ctx argExpr)
            // Default any unbound to `obj`.
            let typeArgs =
                info.Generics
                |> List.map (fun n ->
                    match bindings.TryGetValue n with
                    | true, t  -> t
                    | false, _ -> typeof<obj>)
                |> List.toArray
            // Build the constructed parent + case + ctor refs.
            let constructedParent =
                (info.Type :> System.Type).MakeGenericType typeArgs
            let constructedCase =
                (caseInfo.Type :> System.Type).MakeGenericType typeArgs
            let constructedCtor =
                TypeBuilder.GetConstructor(constructedCase, caseInfo.Ctor)
            // Now emit each arg, then `Newobj` the constructed ctor.
            for argExpr in argExprs do
                let _ = emitExpr ctx argExpr
                ()
            il.Emit(OpCodes.Newobj, constructedCtor)
            constructedParent

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
        let argExprs =
            caseInfo.Fields
            |> List.map (fun f ->
                match Map.tryFind f.Name namedMap with
                | Some ex -> ex
                | None ->
                    if posIdx < List.length positional then
                        let ex = List.item posIdx positional
                        posIdx <- posIdx + 1
                        ex
                    else
                        failwithf "imported union case '%s' missing field '%s'"
                            name f.Name)
        if List.isEmpty info.Generics then
            // Non-generic imported union — emit args, Newobj.
            for (f, argExpr) in List.zip caseInfo.Fields argExprs do
                let argTy = emitExpr ctx argExpr
                if f.Type = typeof<obj> && argTy.IsValueType then
                    il.Emit(OpCodes.Box, argTy)
            il.Emit(OpCodes.Newobj, caseInfo.Ctor)
            info.Type
        else
            // Generic imported union: peek args to bind T's, then
            // MakeGenericType the case (already a runtime type from
            // the loaded assembly, so plain `MakeGenericType` works),
            // GetConstructor on the constructed instance, Newobj.
            let bindings = Dictionary<string, ClrType>()
            let rec bind (lyricTy: Lyric.TypeChecker.Type) (argTy: ClrType) =
                match lyricTy with
                | Lyric.TypeChecker.TyVar n ->
                    if not (bindings.ContainsKey n) then bindings.[n] <- argTy
                | _ -> ()
            for (f, argExpr) in List.zip caseInfo.Fields argExprs do
                bind f.LyricType (peekExprType ctx argExpr)
            // Resolve type-args against `ctx.ExpectedType` /
            // `ctx.ReturnType` first — any time the surrounding
            // context already pins the union's full shape, prefer
            // that over per-field peek (which can degrade to `obj`
            // for builtins or imported funcs that `peekExprType`
            // doesn't recognise).  Per-field bindings from
            // `peekExprType` are the fallback when neither shape
            // matches.
            let tryArgFromShape (idx: int) (shape: ClrType) =
                if shape.IsGenericType then
                    let gargs = shape.GetGenericArguments()
                    let shapeDef = shape.GetGenericTypeDefinition()
                    if shapeDef = info.Type
                       && idx < gargs.Length then
                        Some gargs.[idx]
                    else None
                else None
            let typeArgs =
                info.Generics
                |> List.mapi (fun i n ->
                    let fromExpected =
                        ctx.ExpectedType |> Option.bind (tryArgFromShape i)
                    match fromExpected with
                    | Some t -> t
                    | None ->
                        match tryArgFromShape i ctx.ReturnType with
                        | Some t -> t
                        | None ->
                            match bindings.TryGetValue n with
                            | true, t  -> t
                            | false, _ -> typeof<obj>)
                |> List.toArray
            let constructedCase = caseInfo.Type.MakeGenericType typeArgs
            // Find the matching ctor on the constructed type.  When any
            // typeArg is itself a TypeBuilder GTPB (we're inside a Lyric
            // generic function being emitted), `constructedCase` is a
            // `TypeBuilderInstantiation` whose `GetConstructors()` is
            // not implemented — go through `TypeBuilder.GetConstructor`
            // instead, which substitutes the open ctor handle.
            let openCtor = caseInfo.Ctor
            // Extend the GTPB-check to also catch TypeBuilder typeArgs:
            // when constructing e.g. `Some(value = userRec)` where
            // `userRec` is itself a Lyric record under construction in
            // this assembly, `MakeGenericType([| userRec |])` produces
            // a TypeBuilderInstantiation whose `GetConstructors` is
            // also unsupported (D-progress-050).
            let isTypeBuilderArg (t: ClrType) : bool =
                t :? System.Reflection.Emit.TypeBuilder
                || t :? System.Reflection.Emit.GenericTypeParameterBuilder
                || (t.IsGenericType && not t.IsGenericTypeDefinition
                    && t.GetGenericArguments() |> Array.exists (fun ga ->
                        ga :? System.Reflection.Emit.TypeBuilder
                        || ga :? System.Reflection.Emit.GenericTypeParameterBuilder))
            let constructedCtor =
                if typeArgs |> Array.exists isTypeBuilderArg
                then
                    System.Reflection.Emit.TypeBuilder.GetConstructor(constructedCase, openCtor)
                else
                    constructedCase.GetConstructors()
                    |> Array.find (fun c ->
                        c.GetParameters().Length = caseInfo.Fields.Length)
            for argExpr in argExprs do
                let _ = emitExpr ctx argExpr
                ()
            il.Emit(OpCodes.Newobj, constructedCtor)
            info.Type.MakeGenericType typeArgs

    // ---- record construction ------------------------------------------

    // Protected-type construction (D-progress-079) routes through
    // the no-arg synthesised default ctor before the regular all-
    // fields record ctor path runs (which would expect one arg per
    // field).  `Counter()` ⇒ `Newobj Counter::.ctor()`.
    //
    // Generic protected types (D-progress-079 follow-up) close via
    // LHS-driven inference: `val b: Box[Int] = Box()` reads the
    // expected CLR type from `ctx.ExpectedType`.  When the expected
    // type is a closed generic of the same open def, `MakeGenericType`
    // + `TypeBuilder.GetConstructor` produce the constructed ctor
    // ref; otherwise the args fall back to `obj` per the existing
    // erasure path (M1.4 monomorphisation parity with records).
    //
    // `Box[Int]()` (D-progress-088): explicit type-arg syntax parses
    // as `ECall(EIndex(EPath{Box}, [EPath{Int}]), [])`.  The
    // EIndex-as-type-app dispatch resolves each index expression as
    // a type and closes the generic ctor.
    | ECall ({ Kind = EIndex ({ Kind = EPath { Segments = [name] } }, idxs) }, [])
        when ctx.ProtectedTypes.ContainsKey name
             && not (List.isEmpty idxs)
             && not (List.isEmpty ctx.ProtectedTypes.[name].Generics) ->
        let info = ctx.ProtectedTypes.[name]
        // Resolve each index Expr as a CLR type.  The common form
        // `Box[Int]` parses each arg as `EPath { name }`, so we
        // build a synthetic `TypeExpr.TRef` and route it through
        // the regular `ctx.ResolveType` pipeline; that handles
        // primitives, user types, and qualified paths uniformly.
        let resolveIdxAsType (idx: Expr) : ClrType =
            match idx.Kind with
            | EPath path ->
                let teKind = TRef path
                let te : TypeExpr = { Kind = teKind; Span = idx.Span }
                ctx.ResolveType te
            | _ ->
                failwithf
                    "E5 codegen: %s[%A] — only bare type names \
                     are supported in generic-protected-type \
                     construction (no nested expressions)" name idx
        let typeArgs =
            idxs |> List.map resolveIdxAsType |> List.toArray
        if typeArgs.Length <> info.Generics.Length then
            failwithf
                "E5 codegen: %s[…] expects %d type argument(s), got %d"
                name info.Generics.Length typeArgs.Length
        let openDef = info.Type :> System.Type
        let constructed = openDef.MakeGenericType typeArgs
        let constructedCtor =
            System.Reflection.Emit.TypeBuilder.GetConstructor(
                constructed, info.Ctor)
        il.Emit(OpCodes.Newobj, constructedCtor)
        constructed

    | ECall ({ Kind = EPath { Segments = [name] } }, [])
        when ctx.ProtectedTypes.ContainsKey name ->
        let info = ctx.ProtectedTypes.[name]
        if List.isEmpty info.Generics then
            il.Emit(OpCodes.Newobj, info.Ctor)
            info.Type :> ClrType
        else
            let openDef = info.Type :> System.Type
            let typeArgs : System.Type[] =
                match ctx.ExpectedType with
                | Some t when t.IsGenericType
                              && t.GetGenericTypeDefinition() = openDef ->
                    t.GetGenericArguments()
                | _ ->
                    // No usable LHS hint — close to `obj` per the
                    // M1.4 erasure fallback so `Box()` without a
                    // typed binding still produces a runnable
                    // (if untyped) instance.
                    Array.create info.Generics.Length typeof<obj>
            let constructed = openDef.MakeGenericType typeArgs
            let constructedCtor =
                System.Reflection.Emit.TypeBuilder.GetConstructor(
                    constructed, info.Ctor)
            il.Emit(OpCodes.Newobj, constructedCtor)
            constructed

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
        let isGeneric = not info.Generics.IsEmpty
        // For generic records we need to know each arg's CLR type
        // BEFORE emitting the Newobj so we can MakeGenericType the
        // closing instantiation.  Stash each arg's value in a temp
        // local so we can re-load them after type-arg inference.
        let argLocals =
            ResizeArray<LocalBuilder option * Expr * ClrType>()
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
            if isGeneric then
                let argTy = emitExpr ctx argExpr
                let lb = FunctionCtx.defineLocal ctx ("__rec_arg_" + f.Name) argTy
                il.Emit(OpCodes.Stloc, lb)
                argLocals.Add(Some lb, argExpr, argTy)
            else
                // Set ExpectedType to the field's CLR type so nullary
                // union-case construction (`None` for `Option[String]`,
                // `Empty` for `List[Int]`, etc.) closes its type
                // parameters correctly per D-progress-045.  Without
                // this hint, `inferTypeArgsFromReturn` defaults to
                // `obj`, which produces a None<obj> instance that
                // fails the closed-generic pattern test downstream.
                let saved = ctx.ExpectedType
                ctx.ExpectedType <- Some f.Type
                let _ = emitExpr ctx argExpr
                ctx.ExpectedType <- saved
                argLocals.Add(None, argExpr, typeof<obj>)
        if not isGeneric then
            il.Emit(OpCodes.Newobj, info.Ctor)
            info.Type :> ClrType
        else
            // Reified generic record: bind each generic param from the
            // arg CLR types (`bindLyricToClr`-style for compound shapes),
            // close the type, look up the constructed ctor via
            // TypeBuilder.GetConstructor, re-load the args, Newobj.
            let bindings : ClrType option array =
                Array.create info.Generics.Length None
            let bindByName (n: string) (ty: ClrType) =
                match List.tryFindIndex ((=) n) info.Generics with
                | Some pos when bindings.[pos].IsNone ->
                    bindings.[pos] <- Some ty
                | _ -> ()
            let rec bindLyricToClr (lty: Lyric.TypeChecker.Type) (argTy: ClrType) =
                match lty with
                | Lyric.TypeChecker.TyVar n -> bindByName n argTy
                | Lyric.TypeChecker.TySlice elem
                | Lyric.TypeChecker.TyArray (_, elem) when argTy.IsArray ->
                    let et = argTy.GetElementType()
                    match Option.ofObj et with
                    | Some t -> bindLyricToClr elem t
                    | None   -> ()
                | Lyric.TypeChecker.TyUser (_, lyricArgs)
                    when not lyricArgs.IsEmpty
                         && argTy.IsGenericType
                         && not argTy.IsGenericTypeDefinition ->
                    let cargs = argTy.GetGenericArguments()
                    if cargs.Length = lyricArgs.Length then
                        List.iteri
                            (fun i la -> bindLyricToClr la cargs.[i])
                            lyricArgs
                | _ -> ()
            let lyricFieldTypes =
                info.Fields |> List.map (fun f -> f.LyricType)
            argLocals
            |> Seq.iteri (fun i (_, _, argTy) ->
                if i < lyricFieldTypes.Length then
                    bindLyricToClr (List.item i lyricFieldTypes) argTy)
            let resolved =
                bindings
                |> Array.map (function
                    | Some t -> t
                    | None   -> typeof<obj>)
            let constructed =
                (info.Type :> System.Type).MakeGenericType(resolved)
            let constructedCtor =
                System.Reflection.Emit.TypeBuilder.GetConstructor(constructed, info.Ctor)
            // Re-load each arg from its temp local in field-declaration order.
            for (lbOpt, _, _) in argLocals do
                match lbOpt with
                | Some lb -> il.Emit(OpCodes.Ldloc, lb)
                | None    -> ()
            il.Emit(OpCodes.Newobj, constructedCtor)
            constructed

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

    // ---- std.parse host builtins --------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, [arg])
        when Map.containsKey name hostParseBuiltins ->
        let payload =
            match arg with
            | CAPositional ex | CANamed (_, ex, _) -> ex
        let argTy = emitExpr ctx payload
        if argTy <> typeof<string> then
            failwithf "host parse builtin '%s' requires String arg, got %s"
                name argTy.Name
        let mi = (Map.find name hostParseBuiltins).Value
        il.Emit(OpCodes.Call, mi)
        mi.ReturnType

    // ---- std.file host builtins ---------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when Map.containsKey name hostFileBuiltins ->
        for a in args do
            let payload =
                match a with
                | CAPositional ex | CANamed (_, ex, _) -> ex
            let _ = emitExpr ctx payload
            ()
        let mi = (Map.find name hostFileBuiltins).Value
        il.Emit(OpCodes.Call, mi)
        mi.ReturnType

    // ---- panic / expect / assert builtins ------------------------------

    | ECall ({ Kind = EPath { Segments = ["panic"] } }, [arg]) ->
        let payload =
            match arg with
            | CAPositional ex | CANamed (_, ex, _) -> ex
        let _ = emitExpr ctx payload
        il.Emit(OpCodes.Call, panicMethod.Value)
        // Panic returns Never; the IL stack ends here, but the codegen
        // needs *some* CLR type for downstream chaining.  Use Void.
        typeof<System.Void>

    | ECall ({ Kind = EPath { Segments = ["expect"] } }, [a1; a2]) ->
        let payload1 =
            match a1 with CAPositional ex | CANamed (_, ex, _) -> ex
        let payload2 =
            match a2 with CAPositional ex | CANamed (_, ex, _) -> ex
        let _ = emitExpr ctx payload1
        let _ = emitExpr ctx payload2
        il.Emit(OpCodes.Call, expectMethod.Value)
        typeof<System.Void>

    | ECall ({ Kind = EPath { Segments = ["assert"] } }, [arg]) ->
        let payload =
            match arg with CAPositional ex | CANamed (_, ex, _) -> ex
        let _ = emitExpr ctx payload
        il.Emit(OpCodes.Call, assertMethod.Value)
        typeof<System.Void>

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

    // ---- format1..4 builtins ------------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when (name = "format1" || name = "format2"
              || name = "format3" || name = "format4"
              || name = "format5" || name = "format6")
          && args.Length = (int (name.[name.Length - 1]) - int '0') + 1 ->
        let arity = args.Length - 1
        let payloads =
            args |> List.map (fun a ->
                match a with
                | CAPositional ex | CANamed (_, ex, _) -> ex)
        // Template (first arg) — must be String; emitter trusts the
        // type checker.
        let _ = emitExpr ctx (List.head payloads)
        // Each remaining arg is boxed to obj for String.Format.
        for p in List.tail payloads do
            let argTy = emitExpr ctx p
            boxIfValue il argTy
        let mi =
            match arity with
            | 1 -> format1.Value
            | 2 -> format2.Value
            | 3 -> format3.Value
            | 4 -> format4.Value
            | 5 -> format5.Value
            | 6 -> format6.Value
            | n -> failwithf "format arity %d not supported" n
        il.Emit(OpCodes.Call, mi)
        typeof<string>

    // ---- default[T]() builtin -----------------------------------------

    | ECall ({ Kind = EPath { Segments = ["default"] } }, []) ->
        // Picks its CLR type from the surrounding `ExpectedType` hint
        // (set by val ascription, byref pre-fill, etc.).  Without a
        // hint we fall back to `obj` and `Ldnull`; the user typically
        // adds a `var v: T = default()` ascription in that case.
        let ty =
            match ctx.ExpectedType with
            | Some t when not (t = typeof<obj>) -> t
            | _ -> typeof<obj>
        if ty.IsValueType then
            let tmp = FunctionCtx.defineLocal ctx "__default" ty
            il.Emit(OpCodes.Ldloca, tmp)
            il.Emit(OpCodes.Initobj, ty)
            il.Emit(OpCodes.Ldloc, tmp)
        else
            il.Emit(OpCodes.Ldnull)
        ty

    // ---- toString builtin ---------------------------------------------

    | ECall ({ Kind = EPath { Segments = ["toString"] } }, [arg]) ->
        let payload =
            match arg with
            | CAPositional ex | CANamed (_, ex, _) -> ex
        let argTy = emitExpr ctx payload
        if argTy = typeof<string> then
            // Already a string — no boxing or call needed.
            ()
        else
            boxIfValue il argTy
            il.Emit(OpCodes.Call, toStr.Value)
        typeof<string>

    // ---- user-defined call --------------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when ctx.Funcs.ContainsKey name
          || ctx.Funcs.ContainsKey (name + "/" + string args.Length) ->
        // Prefer the arity-qualified key so overloaded functions resolve
        // to the right overload; fall back to bare name for single-def
        // functions registered without the arity suffix.
        let arityKey = name + "/" + string args.Length
        let mb =
            match ctx.Funcs.TryGetValue arityKey with
            | true, m -> m
            | _       -> ctx.Funcs.[name]
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
                let isByRef =
                    i < paramTypes.Length && paramTypes.[i].IsByRef
                match payload.Kind, expectedDelegateTy with
                | _ when isByRef ->
                    // Byref param (out / inout) — push the address of
                    // the argument's storage instead of its value.
                    emitAddressOf ctx payload paramTypes.[i]
                | ELambda (lps, body), Some dt ->
                    emitLambdaWith ctx lps body (Some dt) |> ignore
                | ELambda (lps, body), None ->
                    emitLambdaWith ctx lps body None |> ignore
                | _ ->
                    // Push the param's CLR type as the expected-type
                    // hint while emitting the arg, so nullary case
                    // construction (e.g. `describe(None)` where
                    // describe takes `Option[Int]`) infers T from
                    // the param.
                    let saved = ctx.ExpectedType
                    if i < paramTypes.Length then
                        ctx.ExpectedType <- Some paramTypes.[i]
                    let argTy = emitExpr ctx payload
                    ctx.ExpectedType <- saved
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
            let sgKey =
                match ctx.FuncSigs.TryGetValue(name + "/" + string args.Length) with
                | true, _ -> name + "/" + string args.Length
                | _ -> name
            let sg = ctx.FuncSigs.[sgKey]
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
                | Lyric.TypeChecker.TyUser (_, lyricArgs) when not lyricArgs.IsEmpty
                                                            && argTy.IsGenericType
                                                            && not argTy.IsGenericTypeDefinition ->
                    // Lyric `Foo[A, B]` paired with CLR `Foo<X, Y>` —
                    // walk position-wise so a TyVar buried inside a
                    // generic param slot still picks up its binding.
                    // Crucial for FFI receivers like `m: GMap[K, V]`
                    // where K / V never appear as standalone args.
                    let clrGenArgs = argTy.GetGenericArguments()
                    if clrGenArgs.Length = lyricArgs.Length then
                        List.iteri
                            (fun i la -> bindLyricToClr la clrGenArgs.[i])
                            lyricArgs
                | Lyric.TypeChecker.TySlice elem
                | Lyric.TypeChecker.TyArray (_, elem)
                    when argTy.IsArray ->
                    let elemClr = argTy.GetElementType()
                    match Option.ofObj elemClr with
                    | Some et -> bindLyricToClr elem et
                    | None    -> ()
                | Lyric.TypeChecker.TyNullable inner ->
                    if argTy.IsGenericType
                       && argTy.GetGenericTypeDefinition() = typedefof<System.Nullable<_>>
                    then bindLyricToClr inner (argTy.GetGenericArguments().[0])
                    else bindLyricToClr inner argTy
                | Lyric.TypeChecker.TyTuple lyricElems
                    when argTy.IsGenericType ->
                    let clrArgs = argTy.GetGenericArguments()
                    if clrArgs.Length = lyricElems.Length then
                        List.iteri
                            (fun i le -> bindLyricToClr le clrArgs.[i])
                            lyricElems
                | Lyric.TypeChecker.TyFunction (lyricPs, lyricR, _) ->
                    // `(T) -> U` paired with `Func<X, ..., Y>` — a HOF
                    // call site like `mapInts(xs, { n -> ... })` binds
                    // U from the lambda's return-type slot.  Without
                    // this branch U would default to `obj` and the
                    // call's reified instantiation would mismatch the
                    // delegate's actual element type.
                    if argTy.IsGenericType then
                        let clrArgs = argTy.GetGenericArguments()
                        let n = lyricPs.Length
                        if clrArgs.Length = n then
                            List.iteri
                                (fun i lp -> bindLyricToClr lp clrArgs.[i])
                                lyricPs
                        elif clrArgs.Length = n + 1 then
                            List.iteri
                                (fun i lp -> bindLyricToClr lp clrArgs.[i])
                                lyricPs
                            bindLyricToClr lyricR clrArgs.[n]
                | _ -> ()  // other compound shapes still deferred
            // Pair-wise emission with type-arg propagation.
            let lyricParamTypes =
                sg.Params |> List.map (fun p -> p.Type) |> List.toArray
            // Bind generic params from surrounding context first — see
            // imported-generic path for rationale.  Restricted to
            // compound return shapes so we don't bind a bare `TyVar`
            // to whatever ExpectedType happens to be.
            let isCompoundReturn =
                match sg.Return with
                | Lyric.TypeChecker.TyVar _ -> false
                | _ -> true
            if isCompoundReturn then
                match ctx.ExpectedType with
                | Some et -> bindLyricToClr sg.Return et
                | None    -> ()
                if ctx.ReturnType <> typeof<System.Void> then
                    bindLyricToClr sg.Return ctx.ReturnType
            // Emit each arg into a temp local so we can issue boxing
            // AFTER inference resolves which generic parameter slots
            // end up as `obj` (where value-typed args need a `box`
            // instruction inserted between the arg and the call).
            let lyricParamModes =
                sg.Params |> List.map (fun p -> p.Mode) |> List.toArray
            let argLocals =
                args
                |> List.mapi (fun i a ->
                    let payload =
                        match a with
                        | CAPositional ex | CANamed (_, ex, _) -> ex
                    let isByRef =
                        i < lyricParamModes.Length
                        && (lyricParamModes.[i] = PMOut
                            || lyricParamModes.[i] = PMInout)
                    if isByRef then
                        // Don't emit a value here — we'll take the
                        // address at the load step.  Bind T from the
                        // arg's `peek` so inference still resolves V.
                        if i < lyricParamTypes.Length then
                            bindLyricToClr lyricParamTypes.[i] (peekExprType ctx payload)
                        // Stash the original payload so the load step
                        // can dispatch through `emitAddressOf`.
                        None, payload, typeof<obj>
                    else
                        let argTy = emitExpr ctx payload
                        if i < lyricParamTypes.Length then
                            bindLyricToClr lyricParamTypes.[i] argTy
                        let lb = FunctionCtx.defineLocal ctx ("__gen_arg_" + string i) argTy
                        il.Emit(OpCodes.Stloc, lb)
                        Some lb, payload, argTy)
            // Default any unbound generic params to `obj` so we still
            // produce well-formed IL even when inference can't see far
            // enough into a body to fix T.
            let resolvedBindings =
                bindings
                |> Array.map (function
                    | Some t -> t
                    | None   -> typeof<obj>)
            checkBounds ctx name genericNames resolvedBindings sg.Bounds
            let constructed = mb.MakeGenericMethod resolvedBindings
            // `constructed.ReturnType` is unreliable until the host
            // type is sealed (Reflection.Emit limitation), so substitute
            // the resolved bindings into Lyric's `sg.Return` ourselves
            // to surface the right CLR type to the caller.
            let substMap =
                List.zip genericNames (List.ofArray resolvedBindings)
                |> Map.ofList
            let substParamTypes =
                sg.Params
                |> List.map (fun p ->
                    let bare =
                        Lyric.Emitter.TypeMap.toClrTypeWithGenerics
                            ctx.Lookup substMap p.Type
                    match p.Mode with
                    | PMOut | PMInout -> bare.MakeByRefType()
                    | PMIn            -> bare)
                |> List.toArray
            argLocals
            |> List.iteri (fun i (lbOpt, payload, argTy) ->
                if i < substParamTypes.Length && substParamTypes.[i].IsByRef then
                    // Byref arg — take the address of the original
                    // payload directly (no temp).  `lbOpt` is `None`
                    // for these args.
                    emitAddressOf ctx payload substParamTypes.[i]
                else
                    match lbOpt with
                    | Some lb -> il.Emit(OpCodes.Ldloc, lb)
                    | None    -> ()
                    if i < substParamTypes.Length then
                        let pt = substParamTypes.[i]
                        if not pt.IsValueType && argTy.IsValueType then
                            il.Emit(OpCodes.Box, argTy)
                        elif pt.IsValueType && (argTy = typeof<obj>) then
                            il.Emit(OpCodes.Unbox_Any, pt))
            il.Emit(OpCodes.Call, constructed)
            let returnedTy =
                Lyric.Emitter.TypeMap.toClrReturnTypeWithGenerics
                    ctx.Lookup substMap sg.Return
            let actualTy =
                if sg.IsAsync then
                    // The MethodBuilder's return type is `Task[<T>]`
                    // even though `sg.Return` is the bare `T`.  The
                    // IL stack carries the wrapped Task — surface
                    // that to the caller (especially `EAwait`, which
                    // expects to call `GetAwaiter` on a Task).  This
                    // matches the non-generic async-call path where
                    // `mb.ReturnType` already includes the wrap.
                    if returnedTy = typeof<System.Void> then
                        typeof<System.Threading.Tasks.Task>
                    else
                        typedefof<System.Threading.Tasks.Task<_>>.MakeGenericType([| returnedTy |])
                else
                    returnedTy
            if actualTy = typeof<System.Void> then typeof<System.Void>
            else actualTy

    // ---- delegate / higher-order call ---------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args) ->
        // Name not in Funcs — check if it is a delegate-typed local or
        // parameter. If so, emit `callvirt Invoke`.  `IsSubclassOf` is
        // unsupported on `TypeBuilderInstantiation` (the runtime type
        // returned by `MakeGenericType` on an unsealed `TypeBuilder`),
        // so we guard with a try/catch fallback to false: such types
        // are never delegate types in practice.
        let safeIsDelegate (t: ClrType) : bool =
            try t.IsSubclassOf typeof<System.Delegate>
            with :? System.NotSupportedException ->
                // `MakeGenericType` on a `TypeBuilder`-resident generic
                // arg surfaces a `TypeBuilderInstantiation`, on which
                // `IsSubclassOf` is unsupported.  Fall back to a
                // structural check: is this a Func<…> / Action<…>
                // instantiation?
                if not t.IsGenericType then false
                else
                    try
                        let g = t.GetGenericTypeDefinition()
                        g = typedefof<System.Action>
                        || g = typedefof<System.Action<_>>
                        || g = typedefof<System.Action<_,_>>
                        || g = typedefof<System.Action<_,_,_>>
                        || g = typedefof<System.Action<_,_,_,_>>
                        || g = typedefof<System.Func<_>>
                        || g = typedefof<System.Func<_,_>>
                        || g = typedefof<System.Func<_,_,_>>
                        || g = typedefof<System.Func<_,_,_,_>>
                        || g = typedefof<System.Func<_,_,_,_,_>>
                    with _ -> false
        let delegateLoad () =
            match FunctionCtx.tryLookup ctx name with
            | Some lb when safeIsDelegate lb.LocalType ->
                il.Emit(OpCodes.Ldloc, lb)
                Some lb.LocalType
            | _ ->
                match ctx.Params.TryGetValue name with
                | true, (idx, ty) when safeIsDelegate ty ->
                    il.Emit(OpCodes.Ldarg, idx)
                    Some ty
                | _ -> None
        match delegateLoad () with
        | Some delegateTy ->
            // `GetMethod "Invoke"` is unsupported on a
            // `TypeBuilderInstantiation` (a `Func<…>` / `Action<…>`
            // closed over a `GenericTypeParameterBuilder`).  Recover
            // the open-generic Invoke and use `TypeBuilder.GetMethod`
            // to construct a usable `MethodInfo` on the instantiation.
            let openDef =
                if delegateTy.IsGenericType
                then Some (delegateTy.GetGenericTypeDefinition())
                else None
            let invoke =
                try Option.ofObj (delegateTy.GetMethod "Invoke")
                with :? System.NotSupportedException ->
                    match openDef with
                    | Some d ->
                        let m = d.GetMethod "Invoke"
                        match Option.ofObj m with
                        | Some mi ->
                            Some (TypeBuilder.GetMethod(delegateTy, mi))
                        | None -> None
                    | None -> None
            match invoke with
            | Some mi ->
                let openParams =
                    match openDef with
                    | Some d ->
                        let m = d.GetMethod "Invoke"
                        match Option.ofObj m with
                        | Some om -> om.GetParameters() |> Array.map (fun p -> p.ParameterType)
                        | None -> [||]
                    | None ->
                        try mi.GetParameters() |> Array.map (fun p -> p.ParameterType)
                        with _ -> [||]
                args |> List.iteri (fun i a ->
                    let payload = match a with | CAPositional ex | CANamed (_, ex, _) -> ex
                    let argTy = emitExpr ctx payload
                    if i < openParams.Length then
                        let pt = openParams.[i]
                        if pt = typeof<obj> && argTy.IsValueType then
                            il.Emit(OpCodes.Box, argTy)
                        elif pt.IsValueType && (argTy = typeof<obj>) then
                            il.Emit(OpCodes.Unbox_Any, pt))
                il.Emit(OpCodes.Callvirt, mi)
                // Recover the substituted return type from the
                // delegate type's generic args (last position for
                // `Func<…,R>`; void for `Action<…>`).
                if delegateTy.IsGenericType then
                    let gargs = delegateTy.GetGenericArguments()
                    let g = openDef
                    let isAction =
                        match g with
                        | Some d ->
                            d = typedefof<System.Action>
                            || d = typedefof<System.Action<_>>
                            || d = typedefof<System.Action<_,_>>
                            || d = typedefof<System.Action<_,_,_>>
                            || d = typedefof<System.Action<_,_,_,_>>
                        | None -> false
                    if isAction then typeof<System.Void>
                    else gargs.[gargs.Length - 1]
                else
                    try mi.ReturnType with _ -> typeof<obj>
            | None ->
                failwithf "Delegate lowering: no Invoke on %s" delegateTy.Name
        | None ->
            // Last fallback: imported function from a precompiled
            // package (e.g. Std.Core).  Cross-assembly call dispatches
            // through the runtime MethodInfo we recovered via reflection.
            // Generic imported methods follow the same shape as local
            // generic methods: walk the Lyric signature, observe arg
            // CLR types, then `MakeGenericMethod`.
            // Prefer arity-qualified key so overloaded imports resolve correctly.
            let importedInfoOpt =
                match ctx.ImportedFuncs.TryGetValue (name + "/" + string args.Length) with
                | true, info -> Some info
                | _ ->
                    match ctx.ImportedFuncs.TryGetValue name with
                    | true, info -> Some info
                    | _ -> None
            match importedInfoOpt with
            | Some info ->
                let mi = info.Method
                let sg = info.Sig
                if sg.Generics.IsEmpty then
                    let paramTypes =
                        mi.GetParameters()
                        |> Array.map (fun p -> p.ParameterType)
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
                        if i < paramTypes.Length && paramTypes.[i].IsByRef then
                            emitAddressOf ctx payload paramTypes.[i]
                        else
                            match payload.Kind, expectedDelegateTy with
                            | ELambda (lps, body), Some dt ->
                                emitLambdaWith ctx lps body (Some dt) |> ignore
                            | _ ->
                                let saved = ctx.ExpectedType
                                if i < paramTypes.Length then
                                    ctx.ExpectedType <- Some paramTypes.[i]
                                let argTy = emitExpr ctx payload
                                ctx.ExpectedType <- saved
                                if i < paramTypes.Length then
                                    let pt = paramTypes.[i]
                                    if pt = typeof<obj> && argTy.IsValueType then
                                        il.Emit(OpCodes.Box, argTy)
                                    elif pt.IsValueType && (argTy = typeof<obj>) then
                                        il.Emit(OpCodes.Unbox_Any, pt))
                    il.Emit(OpCodes.Call, mi)
                    if mi.ReturnType = typeof<System.Void> then typeof<System.Void>
                    else mi.ReturnType
                else
                    // Generic imported method: drive type-arg inference
                    // against the Lyric param types just like the local
                    // generic-call path.
                    let genericNames = sg.Generics
                    let bindings : ClrType option array =
                        Array.create genericNames.Length None
                    let bindByName (n: string) (argTy: ClrType) =
                        match List.tryFindIndex ((=) n) genericNames with
                        | Some pos when bindings.[pos].IsNone ->
                            bindings.[pos] <- Some argTy
                        | _ -> ()
                    let rec bindLyricToClr
                            (lyricTy: Lyric.TypeChecker.Type) (argTy: ClrType) =
                        match lyricTy with
                        | Lyric.TypeChecker.TyVar n -> bindByName n argTy
                        | Lyric.TypeChecker.TyUser (_, lyricArgs)
                            when not lyricArgs.IsEmpty
                                 && argTy.IsGenericType ->
                            let clrArgs = argTy.GetGenericArguments()
                            if clrArgs.Length = lyricArgs.Length then
                                List.iteri
                                    (fun i la -> bindLyricToClr la clrArgs.[i])
                                    lyricArgs
                        | Lyric.TypeChecker.TySlice elem
                        | Lyric.TypeChecker.TyArray (_, elem)
                            when argTy.IsArray ->
                            let elemTy = argTy.GetElementType()
                            match Option.ofObj elemTy with
                            | Some t -> bindLyricToClr elem t
                            | None   -> ()
                        | Lyric.TypeChecker.TyNullable inner ->
                            if argTy.IsGenericType
                               && argTy.GetGenericTypeDefinition() = typedefof<System.Nullable<_>>
                            then bindLyricToClr inner (argTy.GetGenericArguments().[0])
                            else bindLyricToClr inner argTy
                        | Lyric.TypeChecker.TyTuple lyricElems
                            when argTy.IsGenericType ->
                            let clrArgs = argTy.GetGenericArguments()
                            if clrArgs.Length = lyricElems.Length then
                                List.iteri
                                    (fun i le -> bindLyricToClr le clrArgs.[i])
                                    lyricElems
                        | Lyric.TypeChecker.TyFunction (lyricPs, lyricR, _) ->
                            if argTy.IsGenericType then
                                let clrArgs = argTy.GetGenericArguments()
                                let n = lyricPs.Length
                                if clrArgs.Length = n then
                                    List.iteri
                                        (fun i lp -> bindLyricToClr lp clrArgs.[i])
                                        lyricPs
                                elif clrArgs.Length = n + 1 then
                                    List.iteri
                                        (fun i lp -> bindLyricToClr lp clrArgs.[i])
                                        lyricPs
                                    bindLyricToClr lyricR clrArgs.[n]
                        | _ -> ()
                    let lyricParamTypes =
                        sg.Params |> List.map (fun p -> p.Type) |> List.toArray
                    // Bind generic params from the surrounding context
                    // before processing args.  Restricted to compound
                    // return shapes — `Foo[T]` paired with `Foo<int>`
                    // safely binds `T = int`, but a bare `TyVar T`
                    // would naively bind `T = ExpectedType` (which is
                    // wrong when `Some(value = mapGetOrDefault(...))`
                    // sets ExpectedType to `Option<int>` while the
                    // inner call's return is just `V`).
                    let isCompoundReturn =
                        match sg.Return with
                        | Lyric.TypeChecker.TyVar _ -> false
                        | _ -> true
                    if isCompoundReturn then
                        match ctx.ExpectedType with
                        | Some et -> bindLyricToClr sg.Return et
                        | None    -> ()
                        if ctx.ReturnType <> typeof<System.Void> then
                            bindLyricToClr sg.Return ctx.ReturnType
                    let lyricParamModes =
                        sg.Params |> List.map (fun p -> p.Mode) |> List.toArray
                    let argLocals =
                        args
                        |> List.mapi (fun i a ->
                            let payload =
                                match a with
                                | CAPositional ex | CANamed (_, ex, _) -> ex
                            let isByRef =
                                i < lyricParamModes.Length
                                && (lyricParamModes.[i] = PMOut
                                    || lyricParamModes.[i] = PMInout)
                            if isByRef then
                                if i < lyricParamTypes.Length then
                                    bindLyricToClr lyricParamTypes.[i] (peekExprType ctx payload)
                                None, payload, typeof<obj>
                            else
                                let argTy = emitExpr ctx payload
                                if i < lyricParamTypes.Length then
                                    bindLyricToClr lyricParamTypes.[i] argTy
                                let lb = FunctionCtx.defineLocal ctx ("__imp_arg_" + string i) argTy
                                il.Emit(OpCodes.Stloc, lb)
                                Some lb, payload, argTy)
                    let resolvedBindings =
                        bindings
                        |> Array.map (function
                            | Some t -> t
                            | None   -> typeof<obj>)
                    checkBounds ctx name genericNames resolvedBindings sg.Bounds
                    let constructed = mi.MakeGenericMethod resolvedBindings
                    let substMap =
                        List.zip genericNames (List.ofArray resolvedBindings)
                        |> Map.ofList
                    // Substituted CLR param types — guides boxing AND
                    // the byref dispatch (out/inout become `T&`).
                    let substParamTypes =
                        sg.Params
                        |> List.map (fun p ->
                            let bare =
                                Lyric.Emitter.TypeMap.toClrTypeWithGenerics
                                    ctx.Lookup substMap p.Type
                            match p.Mode with
                            | PMOut | PMInout -> bare.MakeByRefType()
                            | PMIn            -> bare)
                        |> List.toArray
                    argLocals
                    |> List.iteri (fun i (lbOpt, payload, argTy) ->
                        if i < substParamTypes.Length && substParamTypes.[i].IsByRef then
                            emitAddressOf ctx payload substParamTypes.[i]
                        else
                            match lbOpt with
                            | Some lb -> il.Emit(OpCodes.Ldloc, lb)
                            | None    -> ()
                            if i < substParamTypes.Length then
                                let pt = substParamTypes.[i]
                                if not pt.IsValueType && argTy.IsValueType then
                                    il.Emit(OpCodes.Box, argTy)
                                elif pt.IsValueType && (argTy = typeof<obj>) then
                                    il.Emit(OpCodes.Unbox_Any, pt))
                    il.Emit(OpCodes.Call, constructed)
                    Lyric.Emitter.TypeMap.toClrReturnTypeWithGenerics
                        ctx.Lookup substMap sg.Return
            | _ ->
                codegenErr ctx "E0004"
                    (sprintf "unknown name '%s'" name) e.Span

    // ---- lambda expression --------------------------------------------

    | ELambda (params', body) ->
        emitLambdaWith ctx params' body None

    // ---- block expression (D-progress-049) ----------------------------
    //
    // Diverging-statement wrappers like `return …` / `throw …` /
    // `break` / `continue` and `try { … } catch …` parse as
    // single-statement EBlock when the user wrote them in expression
    // position.  Most of them produce no value (type Never); `try`
    // is the exception — its body's last expr OR catch's last expr
    // becomes the block's value.

    | EBlock blk ->
        let stmts = blk.Statements
        match stmts with
        | [{ Kind = STry (body, catches) }] ->
            // Emit a try-as-expression: stash the body's tail value
            // (and each catch's tail value) into a single result
            // local; load it after the protected region closes.
            // The result type peeks from the body's last SExpr.
            let resultTy =
                match List.tryLast body.Statements with
                | Some { Kind = SExpr last } -> peekExprType ctx last
                | _ -> typeof<obj>
            let resultLoc =
                FunctionCtx.defineLocal ctx "__try_expr_result" resultTy
            let il = ctx.IL
            let endLabel = il.BeginExceptionBlock()
            ctx.TryDepth <- ctx.TryDepth + 1
            FunctionCtx.pushScope ctx
            // Body: emit statements, last SExpr leaves value on stack.
            let lastIdx = List.length body.Statements - 1
            body.Statements
            |> List.iteri (fun i stmt ->
                if i = lastIdx then
                    match stmt.Kind with
                    | SExpr ex ->
                        let _ = emitExpr ctx ex
                        il.Emit(OpCodes.Stloc, resultLoc)
                    | _ -> emitStatement ctx stmt
                else emitStatement ctx stmt)
            FunctionCtx.popScope ctx
            ctx.TryDepth <- ctx.TryDepth - 1
            // Catch handlers: same shape — last SExpr → result local.
            for c in catches do
                let exTy =
                    match c.Type with
                    | "Bug" | "Exception" | "Error" -> typeof<System.Exception>
                    | _ -> typeof<System.Exception>
                il.BeginCatchBlock(exTy)
                FunctionCtx.pushScope ctx
                match c.Bind with
                | Some name ->
                    let lb = FunctionCtx.defineLocal ctx name exTy
                    il.Emit(OpCodes.Stloc, lb)
                | None -> il.Emit(OpCodes.Pop)
                let cLastIdx = List.length c.Body.Statements - 1
                c.Body.Statements
                |> List.iteri (fun i stmt ->
                    if i = cLastIdx then
                        match stmt.Kind with
                        | SExpr ex ->
                            let _ = emitExpr ctx ex
                            il.Emit(OpCodes.Stloc, resultLoc)
                        | _ -> emitStatement ctx stmt
                    else emitStatement ctx stmt)
                FunctionCtx.popScope ctx
            il.EndExceptionBlock()
            ignore endLabel
            il.Emit(OpCodes.Ldloc, resultLoc)
            resultTy
        | _ ->
            // Multi-stmt or non-try EBlock: emit statements, last
            // SExpr's value on the stack (else void).  Diverging
            // statements (return/throw/break/continue) push a fallback
            // null/zero so the surrounding expression's stack stays
            // balanced — they don't actually return, so the value is
            // never observed at runtime.
            FunctionCtx.pushScope ctx
            let lastIdx = List.length stmts - 1
            let mutable resultTy = typeof<System.Void>
            stmts
            |> List.iteri (fun i stmt ->
                if i = lastIdx then
                    match stmt.Kind with
                    | SExpr ex -> resultTy <- emitExpr ctx ex
                    | SReturn _ | SThrow _ | SBreak _ | SContinue _ ->
                        emitStatement ctx stmt
                        // Stack-balance dummy: unreachable in practice.
                        il.Emit(OpCodes.Ldnull)
                        resultTy <- typeof<obj>
                    | _ -> emitStatement ctx stmt
                else emitStatement ctx stmt)
            FunctionCtx.popScope ctx
            resultTy

    | _ ->
        codegenErr ctx "E0003"
            (sprintf "expression form not yet supported in this version: %A" e.Kind) e.Span

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
                // Temporarily inject the lambda params into ctx.Params
                // so `peekExprType` can resolve `x` etc. when peeking
                // the body's last expression for its return type.
                let injected = ResizeArray<string>()
                paramPairs
                |> List.iteri (fun i (n, cty) ->
                    if not (ctx.Params.ContainsKey n) then
                        ctx.Params.[n] <- (i, cty)
                        injected.Add n)
                let result = peekExprType ctx e2
                for n in injected do ctx.Params.Remove n |> ignore
                result
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
            ctx.ProtectedTypes
            ctx.Projectables
            ctx.ImportedRecords ctx.ImportedUnions ctx.ImportedUnionCases
            ctx.ImportedFuncs ctx.ImportedDistinctTypes ctx.ExternTypeNames
            false None ctx.ProgramType ctx.ResolveType ctx.Lookup ctx.Diags
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
            | true, (info, caseInfo) ->
                // `case Yes` for a nullary union case — type-test.  For
                // generic unions, the case must be instantiated with
                // the scrutinee's type args before we test against it.
                let testTy =
                    if List.isEmpty info.Generics
                       || not slotTy.IsGenericType
                    then caseInfo.Type :> System.Type
                    else
                        (caseInfo.Type :> System.Type).MakeGenericType
                            (slotTy.GetGenericArguments())
                il.Emit(OpCodes.Ldloc, tmp)
                il.Emit(OpCodes.Isinst, testTy)
                il.Emit(OpCodes.Ldnull)
                il.Emit(OpCodes.Cgt_Un)
            | _ ->
                // Imported nullary union case (e.g. None from Std.Core).
                // For generic imported unions, MakeGenericType the case
                // with the scrutinee's type args before the type test.
                match ctx.ImportedUnionCases.TryGetValue name with
                | true, (info, caseInfo) ->
                    let testTy =
                        if List.isEmpty info.Generics
                           || not slotTy.IsGenericType
                        then caseInfo.Type
                        else caseInfo.Type.MakeGenericType
                                (slotTy.GetGenericArguments())
                    il.Emit(OpCodes.Ldloc, tmp)
                    il.Emit(OpCodes.Isinst, testTy)
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
            | true, (info, caseInfo) ->
                // `tmp is CaseSubclass` — `isinst` returns the value
                // typed as the subclass, or `null`. We use the
                // `cgt.un` against ldnull idiom to convert "not null"
                // into the bool 1.  For generic unions, instantiate
                // the case type with the scrutinee's type args first
                // so the test compares apples to apples.
                let testTy =
                    if List.isEmpty info.Generics
                       || not slotTy.IsGenericType
                    then caseInfo.Type :> System.Type
                    else
                        let argTys = slotTy.GetGenericArguments()
                        (caseInfo.Type :> System.Type).MakeGenericType argTys
                il.Emit(OpCodes.Ldloc, tmp)
                il.Emit(OpCodes.Isinst, testTy)
                il.Emit(OpCodes.Ldnull)
                il.Emit(OpCodes.Cgt_Un)
            | _ ->
                // Imported variant-bearing union case.  Same shape as
                // the local generic case: instantiate the case type
                // with the scrutinee's type-arg array before testing.
                match ctx.ImportedUnionCases.TryGetValue key with
                | true, (info, caseInfo) ->
                    let testTy =
                        if List.isEmpty info.Generics
                           || not slotTy.IsGenericType
                        then caseInfo.Type
                        else caseInfo.Type.MakeGenericType
                                (slotTy.GetGenericArguments())
                    il.Emit(OpCodes.Ldloc, tmp)
                    il.Emit(OpCodes.Isinst, testTy)
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
        // For generic local unions we also recover the type-arg array
        // from the scrutinee's CLR type so each field load uses a
        // fully-substituted FieldInfo.
        let scrutTy = tmp.LocalType
        let caseTy, caseFields =
            match ctx.UnionCases.TryGetValue key with
            | true, (info, caseInfo) ->
                if List.isEmpty info.Generics || not scrutTy.IsGenericType then
                    Some (caseInfo.Type :> ClrType),
                    caseInfo.Fields
                    |> List.map (fun f ->
                        f.Name, f.Type, (f.Field :> FieldInfo))
                else
                    let argTys = scrutTy.GetGenericArguments()
                    let constructed =
                        (caseInfo.Type :> System.Type).MakeGenericType argTys
                    let substMap =
                        info.Generics
                        |> List.mapi (fun i n -> n, argTys.[i])
                        |> Map.ofList
                    Some constructed,
                    caseInfo.Fields
                    |> List.map (fun f ->
                        let substTy =
                            Lyric.Emitter.TypeMap.toClrTypeWithGenerics
                                ctx.Lookup substMap f.LyricType
                        let fi = TypeBuilder.GetField(constructed, f.Field)
                        f.Name, substTy, fi)
            | _ ->
                match ctx.ImportedUnionCases.TryGetValue key with
                | true, (info, caseInfo) ->
                    if List.isEmpty info.Generics || not scrutTy.IsGenericType then
                        Some caseInfo.Type,
                        caseInfo.Fields
                        |> List.map (fun f -> f.Name, f.Type, f.Field)
                    else
                        // Generic imported union: instantiate the case
                        // and re-substitute each FieldInfo so payload
                        // loads carry the right CLR type at the IL
                        // boundary.
                        let argTys = scrutTy.GetGenericArguments()
                        let constructed = caseInfo.Type.MakeGenericType argTys
                        let substMap =
                            info.Generics
                            |> List.mapi (fun i n -> n, argTys.[i])
                            |> Map.ofList
                        // For runtime types, locate the matching field
                        // on the constructed instance directly.
                        Some constructed,
                        caseInfo.Fields
                        |> List.map (fun f ->
                            let substTy =
                                Lyric.Emitter.TypeMap.toClrTypeWithGenerics
                                    ctx.Lookup substMap f.LyricType
                            // `GetField` on a TypeBuilderInstantiation
                            // (generic instance closed over a TypeBuilder)
                            // throws NotSupportedException; route through
                            // `TypeBuilder.GetField` in that case.
                            let fi =
                                if constructed :? TypeBuilder
                                   || constructed.GetType().Name = "TypeBuilderInstantiation" then
                                    TypeBuilder.GetField(constructed, f.Field)
                                else
                                    match Option.ofObj (constructed.GetField f.Name) with
                                    | Some x -> x
                                    | None   -> f.Field
                            f.Name, substTy, fi)
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

and emitAddressOf (ctx: FunctionCtx) (e: Expr) (paramTy: ClrType) : unit =
    // Emit `e`'s storage address — used to fulfil a byref (out / inout)
    // parameter slot.  Currently supports:
    //   • named local — `Ldloca`
    //   • named param — if itself byref, `Ldarg` (already an address);
    //                   non-byref params are spilled to a temp and we
    //                   take the temp's address (loses round-trip
    //                   semantics, but the type checker rejects this
    //                   shape elsewhere)
    //   • array element `xs[i]` — `Ldelema <T>`
    //   • record field `r.f`     — `Ldflda <FieldInfo>`
    //   • distinct-type `.value` — `Ldflda` on the backing field
    let il = ctx.IL
    match e.Kind with
    | EPath { Segments = [name] } ->
        match FunctionCtx.tryLookup ctx name with
        | Some lb ->
            il.Emit(OpCodes.Ldloca, lb)
        | None ->
            match ctx.Params.TryGetValue name with
            | true, (idx, pty) when pty.IsByRef ->
                il.Emit(OpCodes.Ldarg, idx)
            | true, (idx, pty) ->
                // Spill a value param to a temp + take its address.
                // The mutation through this address is invisible
                // to the caller — type checker rejects this case.
                let tmp = FunctionCtx.defineLocal ctx ("__byref_" + name) pty
                il.Emit(OpCodes.Ldarg, idx)
                il.Emit(OpCodes.Stloc, tmp)
                il.Emit(OpCodes.Ldloca, tmp)
            | _ ->
                ctx.Diags.Add
                    (Lyric.Lexer.Diagnostic.error "E0085"
                        (sprintf "argument to byref parameter must be a mutable variable, got '%s'" name)
                        e.Span)
                il.Emit(OpCodes.Ldnull)
    | EIndex (recv, [idx]) ->
        // Array element address: push receiver (must be `T[]`), push
        // index (Int32), then `Ldelema <T>`.  Only array receivers
        // are addressable — `Dictionary[K, V]` etc. expose only
        // `set_Item` and aren't supported here.
        let recvTy = emitExpr ctx recv
        if recvTy.IsArray then
            let _ = emitExpr ctx idx
            let elemTy =
                match Option.ofObj (recvTy.GetElementType()) with
                | Some t -> t
                | None   -> typeof<obj>
            il.Emit(OpCodes.Ldelema, elemTy)
        else
            ctx.Diags.Add
                (Lyric.Lexer.Diagnostic.error "E0085"
                    (sprintf "indexed argument to byref parameter requires an array, got %s" recvTy.Name)
                    e.Span)
            il.Emit(OpCodes.Ldnull)
    | EMember (recv, fieldName) ->
        // Record / distinct-type field address.
        let recvTy = emitExpr ctx recv
        let recordHit =
            ctx.Records.Values
            |> Seq.tryFind (fun r -> (r.Type :> ClrType) = recvTy)
            |> Option.bind (fun r ->
                r.Fields |> List.tryFind (fun f -> f.Name = fieldName))
        match recordHit with
        | Some f ->
            il.Emit(OpCodes.Ldflda, f.Field)
        | None ->
            let distinctHit =
                ctx.DistinctTypes.Values
                |> Seq.tryFind (fun d -> (d.Type :> ClrType) = recvTy)
            match distinctHit with
            | Some d when fieldName = "value" ->
                il.Emit(OpCodes.Ldflda, d.ValueField)
            | _ ->
                ctx.Diags.Add
                    (Lyric.Lexer.Diagnostic.error "E0085"
                        (sprintf "field '%s' on %s is not addressable" fieldName recvTy.Name)
                        e.Span)
                il.Emit(OpCodes.Ldnull)
    | _ ->
        ctx.Diags.Add
            (Lyric.Lexer.Diagnostic.error "E0085"
                "argument to byref parameter must be a mutable l-value (variable, array element, or field)"
                e.Span)
        il.Emit(OpCodes.Ldnull)

and emitStatement (ctx: FunctionCtx) (s: Statement) : unit =
    let il = ctx.IL
    match s.Kind with

    | SExpr e ->
        let resultTy = emitExpr ctx e
        if resultTy <> typeof<System.Void> then
            il.Emit(OpCodes.Pop)

    | SLocal (LBVal ({ Kind = PBinding (name, None) }, annot, init))
    | SLocal (LBLet (name, annot, init)) ->
        // If the binding has a type annotation, push it as the
        // ExpectedType hint so nullary case construction (`None`,
        // `Empty`) inside `init` picks the right T.
        let saved = ctx.ExpectedType
        match annot with
        | Some te ->
            try ctx.ExpectedType <- Some (ctx.ResolveType te)
            with _ -> ()
        | None -> ()
        let initTy = emitExpr ctx init
        ctx.ExpectedType <- saved
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
        // Push the type ascription as the ExpectedType hint while
        // emitting the initialiser — same as `val`, so `var v: Int =
        // default()` makes `default()` pick `Int` instead of `obj`.
        let saved = ctx.ExpectedType
        match annot with
        | Some te ->
            try ctx.ExpectedType <- Some (ctx.ResolveType te)
            with _ -> ()
        | None -> ()
        let initTy =
            match initOpt with
            | Some init ->
                let it = emitExpr ctx init
                Some it
            | None -> None
        ctx.ExpectedType <- saved
        // The local's CLR type prefers the annotation when present so
        // out-param call sites can still take the address of an
        // initialiser that happened to peek as `obj` (e.g. a generic
        // `default()`).  Falls back to the initialiser type, then to
        // int32 (legacy default) when neither is available.
        let annotTy =
            match annot with
            | Some te ->
                try Some (ctx.ResolveType te)
                with _ -> None
            | None -> None
        let slotTy =
            match annotTy, initTy with
            | Some t, _      -> t
            | None,   Some t -> t
            | None,   None   -> typeof<int32>
        let lb = FunctionCtx.defineLocal ctx name slotTy
        match initOpt with
        | Some _ -> il.Emit(OpCodes.Stloc, lb)
        | None   -> ()

    | SLocal _ ->
        failwithf "E3 codegen does not yet handle this local pattern: %A" s.Kind

    | SAssign (target, AssEq, value) ->
        // `result` as an assignment target is the contextual keyword for
        // the return value in ensures clauses, but is also a valid local
        // variable name.  Map EResult to "result" so that
        // `var result = …; result = result + x` compiles like any other
        // local-variable assignment.
        let targetName =
            match target.Kind with
            | EPath { Segments = [name] } -> Some name
            | EResult -> Some "result"
            | _ -> None
        match targetName with
        | Some name ->
            match FunctionCtx.tryLookup ctx name with
            | Some lb ->
                let _ = emitExpr ctx value
                il.Emit(OpCodes.Stloc, lb)
            | None ->
                match ctx.SmFields.TryGetValue name with
                | true, f ->
                    // Async state-machine field assignment.
                    il.Emit(OpCodes.Ldarg_0)
                    let _ = emitExpr ctx value
                    il.Emit(OpCodes.Stfld, f)
                | _ ->
                match ctx.Params.TryGetValue name with
                | true, (idx, pty) when pty.IsByRef ->
                    // Write through a byref param (out / inout).
                    let elem =
                        match Option.ofObj (pty.GetElementType()) with
                        | Some t -> t
                        | None   -> typeof<obj>
                    il.Emit(OpCodes.Ldarg, idx)
                    let _ = emitExpr ctx value
                    if elem.IsValueType then il.Emit(OpCodes.Stobj, elem)
                    else il.Emit(OpCodes.Stind_Ref)
                | _ ->
                    codegenErrStmt ctx "E0003"
                        (sprintf "assignment to unknown name '%s'" name) s.Span
        | None ->
            // Indexed assignment `recv[idx] = value`: array → Stelem,
            // BCL container → `set_Item(idx, value)`.
            match target.Kind with
            | EIndex (recv, [idx]) ->
                let recvTy = emitExpr ctx recv
                if recvTy.IsArray then
                    let _ = emitExpr ctx idx
                    let valTy = emitExpr ctx value
                    let elemTy =
                        match Option.ofObj (recvTy.GetElementType()) with
                        | Some t -> t
                        | None   -> typeof<obj>
                    if not elemTy.IsValueType && valTy.IsValueType then
                        il.Emit(OpCodes.Box, valTy)
                    il.Emit(OpCodes.Stelem, elemTy)
                else
                    // Look up `set_Item(idx, value)` on the receiver
                    // type — covers Dictionary, List, etc.
                    let setItem =
                        getRecvMethods recvTy
                        |> Array.tryFind (fun m ->
                            m.Name = "set_Item"
                            && not m.IsStatic
                            && m.GetParameters().Length = 2)
                        |> Option.map (closeBclMethod recvTy)
                    match setItem with
                    | Some m ->
                        let _ = emitExpr ctx idx
                        let _ = emitExpr ctx value
                        il.Emit(OpCodes.Callvirt, m)
                    | None ->
                        codegenErrStmt ctx "E0003"
                            (sprintf "no `set_Item` indexer on %s for indexed assignment"
                                recvTy.Name) s.Span
            // Field-store: `recv.field = value`.  For a reference-type
            // receiver (Lyric records lower to sealed CLR classes),
            // we load the receiver, compute the value, then Stfld.
            // Critical for the `inout c: Record; c.field = ...` shape
            // where the receiver is a byref-of-class — the existing
            // EMember read auto-dereferences via Ldind.Ref so the same
            // `emitExpr ctx recv` lifting works on the write side.
            //
            // Walk `ctx.Records` to find the `FieldBuilder` directly;
            // calling `recvTy.GetField` on a still-under-construction
            // TypeBuilder would throw "The invoked member is not
            // supported before the type is created."
            | EMember (recv, fieldName) ->
                let recvTy = emitExpr ctx recv
                let recordInfo =
                    ctx.Records.Values
                    |> Seq.tryFind (fun r -> (r.Type :> ClrType) = recvTy)
                match recordInfo with
                | Some r ->
                    match r.Fields |> List.tryFind (fun f -> f.Name = fieldName) with
                    | Some f ->
                        let valTy = emitExpr ctx value
                        if not f.Type.IsValueType && valTy.IsValueType then
                            il.Emit(OpCodes.Box, valTy)
                        il.Emit(OpCodes.Stfld, f.Field)
                    | None ->
                        codegenErrStmt ctx "E0003"
                            (sprintf "no field '%s' on record '%s' for assignment"
                                fieldName r.Name) s.Span
                | None ->
                    codegenErrStmt ctx "E0003"
                        (sprintf "field-store target '%s.%s' not yet supported (receiver type %s)"
                            (sprintf "%A" recv.Kind) fieldName recvTy.Name) s.Span
            | _ ->
                codegenErrStmt ctx "E0003"
                    (sprintf "assignment target not yet supported: %A" target.Kind) s.Span

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
            | None ->
                match ctx.Params.TryGetValue name with
                | true, (idx, pty) when pty.IsByRef ->
                    // Compound write through a byref param.  Reuse the
                    // EBinop path: peek the param's value, combine with
                    // `value`, write back through the pointer.
                    let elem =
                        match Option.ofObj (pty.GetElementType()) with
                        | Some t -> t
                        | None   -> typeof<obj>
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
                    il.Emit(OpCodes.Ldarg, idx)
                    let _ = emitExpr ctx synthetic
                    if elem.IsValueType then il.Emit(OpCodes.Stobj, elem)
                    else il.Emit(OpCodes.Stind_Ref)
                | _ ->
                    codegenErrStmt ctx "E0003"
                        (sprintf "compound-assign to unknown name '%s'" name) s.Span
        | _ ->
            codegenErrStmt ctx "E0003"
                (sprintf "compound-assign target not yet supported: %A" target.Kind) s.Span

    | SReturn None ->
        // Branch to the synthesised single exit if one was set up;
        // otherwise emit a bare ret (legacy path for the host's
        // synthetic Main entry point).  Inside a try { … } finally
        // protected region the branch must be a `leave`, not a `br`.
        match ctx.ReturnLabel with
        | Some lbl ->
            if ctx.TryDepth > 0 then il.Emit(OpCodes.Leave, lbl)
            else il.Emit(OpCodes.Br, lbl)
        | None -> il.Emit(OpCodes.Ret)

    | SReturn (Some e) ->
        let _ = emitExpr ctx e
        match ctx.ReturnLabel, ctx.ResultLocal with
        | Some lbl, Some loc ->
            il.Emit(OpCodes.Stloc, loc)
            if ctx.TryDepth > 0 then il.Emit(OpCodes.Leave, lbl)
            else il.Emit(OpCodes.Br, lbl)
        | Some lbl, None ->
            // Non-void value into a void-returning function — drop.
            il.Emit(OpCodes.Pop)
            if ctx.TryDepth > 0 then il.Emit(OpCodes.Leave, lbl)
            else il.Emit(OpCodes.Br, lbl)
        | None, _ ->
            il.Emit(OpCodes.Ret)

    | SWhile (_label, cond, body) ->
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead; TryDepthAtFrame = ctx.TryDepth }
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
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead; TryDepthAtFrame = ctx.TryDepth }
        il.MarkLabel(lblHead)
        emitBlock ctx body
        il.Emit(OpCodes.Br, lblHead)
        il.MarkLabel(lblEnd)
        FunctionCtx.popLoop ctx

    | SBreak _ ->
        match FunctionCtx.currentLoop ctx with
        | Some f ->
            if ctx.TryDepth > f.TryDepthAtFrame then
                il.Emit(OpCodes.Leave, f.BreakLabel)
            else
                il.Emit(OpCodes.Br, f.BreakLabel)
        | None -> failwith "E3 codegen: 'break' outside of a loop"

    | SContinue _ ->
        match FunctionCtx.currentLoop ctx with
        | Some f ->
            if ctx.TryDepth > f.TryDepthAtFrame then
                il.Emit(OpCodes.Leave, f.ContinueLabel)
            else
                il.Emit(OpCodes.Br, f.ContinueLabel)
        | None -> failwith "E3 codegen: 'continue' outside of a loop"

    | SFor (_label, { Kind = PBinding (name, None) }, iter, body) ->
        // `for x in slice { body }` lowers to a counter + ldelem loop.
        // The iter is presumed to be a slice/array (CLR T[]); other
        // iterables land in E7.
        // D-progress-058: when the body contains an `await`, route
        // the iterator slice, the index, and the element through
        // SM fields so their values survive the cross-resume gap.
        // Field-backed access via `SmFields[name]` lets the body
        // emit naturally use `name` without seeing the field shape.
        let iterTy = emitExpr ctx iter
        if not iterTy.IsArray then
            failwithf "E3 codegen: for-in expects an array/slice, got %A" iterTy
        let elemTy =
            match Option.ofObj (iterTy.GetElementType()) with
            | Some t -> t
            | None   -> typeof<obj>
        let bodyHasAwait = Lyric.Emitter.AsyncStateMachine.hasAwaitInBlock body
        let usePhaseBPromotion =
            ctx.SmAwaitInfo.IsSome && bodyHasAwait
        if usePhaseBPromotion then
            let smAwait = ctx.SmAwaitInfo.Value
            let sm = smAwait.Sm
            let arrField =
                sm.Type.DefineField(
                    "<for>__iter_" + name,
                    iterTy,
                    System.Reflection.FieldAttributes.Public)
            let idxField =
                sm.Type.DefineField(
                    "<for>__idx_" + name,
                    typeof<int32>,
                    System.Reflection.FieldAttributes.Public)
            let elemField =
                sm.Type.DefineField(
                    "<for>__elem_" + name,
                    elemTy,
                    System.Reflection.FieldAttributes.Public)
            // Stash iter (currently on stack) into arrField via a temp.
            let tmpIter = il.DeclareLocal(iterTy)
            il.Emit(OpCodes.Stloc, tmpIter)
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldloc, tmpIter)
            il.Emit(OpCodes.Stfld, arrField)
            // idx = 0
            il.Emit(OpCodes.Ldarg_0)
            emitLdcI4 il 0
            il.Emit(OpCodes.Stfld, idxField)
            let lblHead = il.DefineLabel()
            let lblIncr = il.DefineLabel()
            let lblEnd  = il.DefineLabel()
            FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblIncr; TryDepthAtFrame = ctx.TryDepth }
            il.MarkLabel(lblHead)
            // if (idx >= length) goto end
            il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, idxField)
            il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, arrField)
            il.Emit(OpCodes.Ldlen)
            il.Emit(OpCodes.Conv_I4)
            il.Emit(OpCodes.Bge, lblEnd)
            // elem = arr[idx]
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, arrField)
            il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, idxField)
            il.Emit(OpCodes.Ldelem, elemTy)
            il.Emit(OpCodes.Stfld, elemField)
            // Make `name` resolvable as a SM field for body emission;
            // EPath/SAssign route through ctx.SmFields when no IL
            // local of the same name is in scope.
            FunctionCtx.pushScope ctx
            let savedField =
                match ctx.SmFields.TryGetValue name with
                | true, f -> Some f
                | _ -> None
            ctx.SmFields.[name] <- (elemField :> FieldInfo)
            emitBlock ctx body
            (match savedField with
             | Some f -> ctx.SmFields.[name] <- f
             | None -> ctx.SmFields.Remove(name) |> ignore)
            FunctionCtx.popScope ctx
            // idx <- idx + 1
            il.MarkLabel(lblIncr)
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, idxField)
            emitLdcI4 il 1
            il.Emit(OpCodes.Add)
            il.Emit(OpCodes.Stfld, idxField)
            il.Emit(OpCodes.Br, lblHead)
            il.MarkLabel(lblEnd)
            FunctionCtx.popLoop ctx
        else
        let arrLocal = FunctionCtx.defineLocal ctx ("__iter_" + name) iterTy
        il.Emit(OpCodes.Stloc, arrLocal)
        let idxLocal = FunctionCtx.defineLocal ctx ("__idx_" + name) typeof<int32>
        emitLdcI4 il 0
        il.Emit(OpCodes.Stloc, idxLocal)
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead; TryDepthAtFrame = ctx.TryDepth }
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

    | SScope (_, blk) ->
        FunctionCtx.pushScope ctx
        emitBlock ctx blk
        FunctionCtx.popScope ctx

    | SDefer _ ->
        // `defer { ... }` is intercepted at block emission so its body
        // wraps the remainder of the enclosing scope in a try/finally
        // (see `emitStatementsWithDefer`).  Reaching this branch means
        // a defer escaped its surrounding block — treat as a bug.
        failwith "E14 codegen: bare SDefer reached emitStatement (block emit should have hoisted it)"

    | STry (body, catches) ->
        // D-progress-048: statement-form `try { … } catch <Type> [as
        // <bind>] { … }`.  Each catch's `<Type>` resolves via the
        // catch-type map below; unknown types fall back to
        // `System.Exception` so callers can still trap any bug.
        // D-progress-056: when the function is in Phase B SM mode and
        // the body fits the "single trailing await" shape, route to
        // the duplicated-post-await emit so the suspend's `Leave`
        // exits all protected regions cleanly and the resume label
        // sits between two `.try` copies (no branch-into-protected-
        // region IL is required).
        let il = ctx.IL
        let resolveCatchType = resolveCatchTypeName
        let isPhaseBPlusPlusPlusTryAwait =
            ctx.SmAwaitInfo.IsSome
            && Lyric.Emitter.AsyncStateMachine.isTryAwaitBodyShape body catches
        if isPhaseBPlusPlusPlusTryAwait then
            emitTryAwaitDuplicated ctx body catches resolveCatchType
        else
            let endLabel = il.BeginExceptionBlock()
            ctx.TryDepth <- ctx.TryDepth + 1
            FunctionCtx.pushScope ctx
            emitBlock ctx body
            FunctionCtx.popScope ctx
            ctx.TryDepth <- ctx.TryDepth - 1
            for c in catches do
                let exTy = resolveCatchType c.Type
                il.BeginCatchBlock(exTy)
                FunctionCtx.pushScope ctx
                match c.Bind with
                | Some name ->
                    let lb = FunctionCtx.defineLocal ctx name exTy
                    il.Emit(OpCodes.Stloc, lb)
                | None ->
                    // No binding — pop the exception value off the stack.
                    il.Emit(OpCodes.Pop)
                emitBlock ctx c.Body
                FunctionCtx.popScope ctx
            il.EndExceptionBlock()
            ignore endLabel

    | _ ->
        codegenErrStmt ctx "E0003"
            (sprintf "statement form not yet supported in this version: %A" s.Kind) s.Span

and emitBlock (ctx: FunctionCtx) (blk: Block) : unit =
    FunctionCtx.pushScope ctx
    emitStatementsWithDeferTail ctx blk.Statements (fun () -> ())
    FunctionCtx.popScope ctx

/// Emit a list of statements, hoisting `defer { … }` so its body
/// runs on scope exit (success or failure).  Each defer wraps the
/// statements that follow it (and the supplied `tail`) in a CLR
/// `try/finally`; multiple defers in the same block nest LIFO so the
/// most recently registered cleanup runs first.
///
/// `tail` runs after all non-defer statements.  Block emit passes a
/// no-op; function-body emit passes the `routeReturn` handler so the
/// last expression's value flows through the defer-wrapping correctly.
and emitStatementsWithDeferTail
        (ctx: FunctionCtx)
        (stmts: Statement list)
        (tail: unit -> unit) : unit =
    match stmts with
    | [] -> tail ()
    | s :: rest ->
        match s.Kind with
        | SDefer body ->
            let il = ctx.IL
            il.BeginExceptionBlock() |> ignore
            ctx.TryDepth <- ctx.TryDepth + 1
            emitStatementsWithDeferTail ctx rest tail
            ctx.TryDepth <- ctx.TryDepth - 1
            il.BeginFinallyBlock()
            FunctionCtx.pushScope ctx
            emitStatementsWithDeferTail ctx body.Statements (fun () -> ())
            FunctionCtx.popScope ctx
            il.EndExceptionBlock()
        | _ ->
            emitStatement ctx s
            emitStatementsWithDeferTail ctx rest tail

/// Phase B+++ try/catch + await emit (D-progress-056).
///
/// User code: `try { pre...; val r = await foo() } catch (T e) { handler }`
/// (or bare `await foo()` / `let`/`var`-bind variant; pre may be empty).
///
/// IL shape:
///
///     // === First user .try (pre + await suspend-or-inline + bind) ===
///     .try {
///         <pre>
///         <emit inner expr>            // → Task[<T>] on stack
///         callvirt GetAwaiter
///         stloc awaiterLoc
///         ldloca awaiterLoc
///         call IsCompleted
///         brtrue InlineAfterAwait
///         // suspend
///         this.<>1__state = N
///         this.<>u__N = awaiterLoc
///         flush promoted locals
///         smLocal = this
///         this.<>builder.AwaitUnsafeOnCompleted<,>(ref awaiter, ref smLocal)
///         leave afterTryLabel       // exits both the user try and outer auto-try
///       InlineAfterAwait:
///         ldloca awaiterLoc; call GetResult
///         <stloc-or-pop binding>
///         leave AfterFirstUserTry
///     } catch (T) {
///         <emit catch handler>
///         leave AfterFirstUserTry
///     }
///   AfterFirstUserTry:
///     br AfterUserTry            // skip the resume + second try copy
///
///     // === Resume entry (outside both user trys, inside outer auto-try) ===
///   resumeLabel:                  // == smAwait.ResumeLabels[N]
///     awaiterLoc = this.<>u__N
///     this.<>u__N = default
///     this.<>1__state = -1
///
///     // === Second user .try (just GetResult + bind) ===
///     .try {
///         ldloca awaiterLoc; call GetResult
///         <stloc-or-pop binding>
///         leave AfterSecondUserTry
///     } catch (T) {
///         <emit catch handler>     // duplicated body
///         leave AfterSecondUserTry
///     }
///   AfterSecondUserTry:
///   AfterUserTry:
and private emitTryAwaitDuplicated
        (ctx: FunctionCtx)
        (body: Block)
        (catches: CatchClause list)
        (resolveCatchType: string -> System.Type) : unit =
    let il = ctx.IL
    let smAwait =
        match ctx.SmAwaitInfo with
        | Some s -> s
        | None   -> failwith "internal: emitTryAwaitDuplicated requires SmAwaitInfo"

    // Split body into pre-stmts + the trailing await statement.
    let preStmts, awaitStmt =
        match List.tryLast body.Statements with
        | Some last ->
            let preLen = List.length body.Statements - 1
            (List.truncate preLen body.Statements, last)
        | None -> failwith "internal: emitTryAwaitDuplicated: empty try body"

    // Extract the `inner` Task expression from the await statement,
    // peeking through any EParen wrappers.  Also remember the binding
    // shape so we can stloc / pop correctly after GetResult.
    let rec unwrapAwait (e: Expr) : Expr =
        match e.Kind with
        | EAwait inner -> inner
        | EParen p -> unwrapAwait p
        | _ -> failwith "internal: unwrapAwait: not an await expression"
    let bindName : string option =
        match awaitStmt.Kind with
        | SExpr _ -> None
        | SLocal (LBVal ({ Kind = PBinding (n, None) }, _, _))
        | SLocal (LBLet (n, _, _))
        | SLocal (LBVar (n, _, Some _)) -> Some n
        | _ -> failwith "internal: emitTryAwaitDuplicated: unexpected await stmt shape"
    let innerExpr : Expr =
        match awaitStmt.Kind with
        | SExpr e -> unwrapAwait e
        | SLocal (LBVal (_, _, init))
        | SLocal (LBLet (_, _, init))
        | SLocal (LBVar (_, _, Some init)) -> unwrapAwait init
        | _ -> failwith "internal: emitTryAwaitDuplicated: unexpected await stmt shape"
    let bindAnnot : TypeExpr option =
        match awaitStmt.Kind with
        | SLocal (LBVal (_, ann, _))
        | SLocal (LBLet (_, ann, _))
        | SLocal (LBVar (_, ann, Some _)) -> ann
        | _ -> None

    // Allocate the await's state index up front; the resume label
    // is the same one the global Switch dispatch was wired to.
    let stateIndex = smAwait.NextAwaitIndex
    smAwait.NextAwaitIndex <- stateIndex + 1
    let resumeLabel = smAwait.ResumeLabels.[stateIndex]

    // Emit the inner-expression once (as part of the first .try
    // body) to discover the awaiter / GetResult / returned types.
    // We capture them by allocating a side-channel: emit the inner
    // expression in a helper that returns the resolved methods.

    // Forward labels.
    let afterFirstUserTry = il.DefineLabel()
    let afterSecondUserTry = il.DefineLabel()
    let afterUserTry = il.DefineLabel()
    let inlineAfterAwait = il.DefineLabel()

    // Awaiter local — allocated at function scope so both .try
    // copies can address it.
    let awaiterLocalRef : LocalBuilder ref = ref (Unchecked.defaultof<LocalBuilder>)
    let awaiterTyRef    : System.Type ref = ref typeof<obj>
    let getResultRef    : MethodInfo ref  = ref (Unchecked.defaultof<MethodInfo>)
    let returnedTyRef   : System.Type ref = ref typeof<System.Void>
    let awaiterFieldRef : FieldBuilder ref = ref (Unchecked.defaultof<FieldBuilder>)

    // ---- First user try: pre + compute-awaiter + suspend-or-inline-bind ----
    il.BeginExceptionBlock() |> ignore
    ctx.TryDepth <- ctx.TryDepth + 1
    FunctionCtx.pushScope ctx

    // Pre stmts.
    for s in preStmts do
        emitStatement ctx s

    // Push the inner Task expression.
    let savedExpected = ctx.ExpectedType
    match bindAnnot with
    | Some te ->
        try ctx.ExpectedType <- Some (ctx.ResolveType te)
        with _ -> ()
    | None -> ()
    let taskTy = emitExpr ctx innerExpr
    ctx.ExpectedType <- savedExpected

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
        let openGetAwaiter =
            let mi = typedefof<System.Threading.Tasks.Task<_>>.GetMethod("GetAwaiter")
            match Option.ofObj mi with
            | Some m -> m
            | None -> failwith "E14 codegen: Task<>.GetAwaiter open-generic not found"
        let closedGetAwaiter = TypeBuilder.GetMethod(taskTy, openGetAwaiter)
        let openAwaiterTy = typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>>
        let closedAwaiterTy = openAwaiterTy.MakeGenericType([| elemTy |])
        let openGetResult =
            let mi = openAwaiterTy.GetMethod("GetResult")
            match Option.ofObj mi with
            | Some m -> m
            | None -> failwith "E14 codegen: TaskAwaiter<>.GetResult not found"
        let closedGetResult = TypeBuilder.GetMethod(closedAwaiterTy, openGetResult)
        closedGetAwaiter, closedAwaiterTy, closedGetResult, elemTy
    let getAwaiter, awaiterTy, getResult, returnedTy =
        if isClosedGenericOnTaskBuilder then resolveGenericTask ()
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
    let awaiterLocal = FunctionCtx.defineLocal ctx "__awaiter_try" awaiterTy
    il.Emit(OpCodes.Stloc, awaiterLocal)
    awaiterLocalRef := awaiterLocal
    awaiterTyRef    := awaiterTy
    getResultRef    := getResult
    returnedTyRef   := returnedTy

    // Define the awaiter SM field for this state index.
    let awaiterField =
        Lyric.Emitter.AsyncStateMachine.defineAwaiterField
            smAwait.Sm stateIndex awaiterTy
    smAwait.AwaiterFields.[stateIndex] <- awaiterField
    awaiterFieldRef := awaiterField

    // IsCompleted check.
    let awaiterClosedOverTb =
        awaiterTy.IsGenericType
        && awaiterTy.GetGenericArguments()
           |> Array.exists (fun a ->
               a :? TypeBuilder
               || (a.IsGenericType && a.GetGenericArguments() |> Array.exists (fun b -> b :? TypeBuilder)))
    let isCompletedGetter =
        if awaiterClosedOverTb
           && awaiterTy.GetGenericTypeDefinition()
              = typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>> then
            let openTaskAwaiter = typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>>
            let openGetter =
                openTaskAwaiter.GetMethods()
                |> Array.tryFind (fun m -> m.Name = "get_IsCompleted")
            match openGetter with
            | Some m -> TypeBuilder.GetMethod(awaiterTy, m)
            | None -> failwith "BCL: TaskAwaiter<>.get_IsCompleted not found"
        else
            match Option.ofObj (awaiterTy.GetProperty("IsCompleted")) with
            | Some p ->
                match Option.ofObj (p.GetGetMethod()) with
                | Some g -> g
                | None -> failwithf "E14 codegen: %s.get_IsCompleted missing" awaiterTy.Name
            | None -> failwithf "E14 codegen: %s.IsCompleted property missing" awaiterTy.Name

    il.Emit(OpCodes.Ldloca, awaiterLocal)
    il.Emit(OpCodes.Call, isCompletedGetter)
    il.Emit(OpCodes.Brtrue, inlineAfterAwait)

    // ---- suspend path ----
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldc_I4, stateIndex)
    il.Emit(OpCodes.Stfld, smAwait.Sm.State)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldloc, awaiterLocal)
    il.Emit(OpCodes.Stfld, awaiterField)
    for (lb, fld) in smAwait.PromotedShadows do
        il.Emit(OpCodes.Ldarg_0)
        il.Emit(OpCodes.Ldloc, lb)
        il.Emit(OpCodes.Stfld, fld)
    let builderTy = smAwait.Sm.BuilderType
    let builderClosedOverTb =
        builderTy.IsGenericType
        && builderTy.GetGenericArguments()
           |> Array.exists (fun a ->
               a :? TypeBuilder
               || (a.IsGenericType && a.GetGenericArguments() |> Array.exists (fun b -> b :? TypeBuilder)))
    let closedAwaitUnsafe =
        if builderClosedOverTb && builderTy.IsGenericType
           && builderTy.GetGenericTypeDefinition()
              = typedefof<System.Runtime.CompilerServices.AsyncTaskMethodBuilder<_>> then
            let openBuilder = typedefof<System.Runtime.CompilerServices.AsyncTaskMethodBuilder<_>>
            let openOnDef =
                openBuilder.GetMethods()
                |> Array.tryFind (fun m ->
                    m.Name = "AwaitUnsafeOnCompleted"
                    && m.IsGenericMethodDefinition
                    && m.GetGenericArguments().Length = 2)
            let closedOnBuilder =
                match openOnDef with
                | Some m -> TypeBuilder.GetMethod(builderTy, m)
                | None ->
                    failwith "BCL: AsyncTaskMethodBuilder<>.AwaitUnsafeOnCompleted<,> not found"
            closedOnBuilder.MakeGenericMethod([| awaiterTy; (smAwait.Sm.Type :> System.Type) |])
        else
            let openAwaitUnsafe =
                builderTy.GetMethods()
                |> Array.tryFind (fun m ->
                    m.Name = "AwaitUnsafeOnCompleted"
                    && m.IsGenericMethodDefinition
                    && m.GetGenericArguments().Length = 2)
            match openAwaitUnsafe with
            | Some m -> m.MakeGenericMethod([| awaiterTy; (smAwait.Sm.Type :> System.Type) |])
            | None -> failwithf "BCL: %s.AwaitUnsafeOnCompleted<,> not found" builderTy.Name
    let smLocal =
        FunctionCtx.defineLocal ctx "__this_sm_try" (smAwait.Sm.Type :> System.Type)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Stloc, smLocal)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, smAwait.Sm.Builder)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, awaiterField)
    il.Emit(OpCodes.Ldloca, smLocal)
    il.Emit(OpCodes.Call, closedAwaitUnsafe)
    il.Emit(OpCodes.Leave, smAwait.SuspendLeaveLabel)

    // ---- inline-after-await (awaiter was already complete) ----
    il.MarkLabel(inlineAfterAwait)
    il.Emit(OpCodes.Ldloca, awaiterLocal)
    il.Emit(OpCodes.Call, getResult)
    // Bind into the local (or pop for bare-await).
    match bindName, returnedTy = typeof<System.Void> with
    | Some name, false ->
        let lb = FunctionCtx.defineLocal ctx name returnedTy
        il.Emit(OpCodes.Stloc, lb)
    | None, true -> ()         // bare await on a Task (Unit)
    | None, false ->
        il.Emit(OpCodes.Pop)   // bare await of Task<T>: discard
    | Some _, true ->
        // val r = await sayHi() — Lyric type-checker disallows
        // this normally, but be defensive.
        ()
    il.Emit(OpCodes.Leave, afterFirstUserTry)

    FunctionCtx.popScope ctx
    ctx.TryDepth <- ctx.TryDepth - 1

    // ---- Catches for first user try ----
    for c in catches do
        let exTy = resolveCatchType c.Type
        il.BeginCatchBlock(exTy)
        FunctionCtx.pushScope ctx
        match c.Bind with
        | Some name ->
            let lb = FunctionCtx.defineLocal ctx name exTy
            il.Emit(OpCodes.Stloc, lb)
        | None -> il.Emit(OpCodes.Pop)
        emitBlock ctx c.Body
        FunctionCtx.popScope ctx
        il.Emit(OpCodes.Leave, afterFirstUserTry)
    il.EndExceptionBlock()

    il.MarkLabel(afterFirstUserTry)
    il.Emit(OpCodes.Br, afterUserTry)

    // ---- Resume entry (outside both user trys) ----
    il.MarkLabel(resumeLabel)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldfld, awaiterField)
    il.Emit(OpCodes.Stloc, awaiterLocal)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, awaiterField)
    il.Emit(OpCodes.Initobj, awaiterTy)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldc_I4_M1)
    il.Emit(OpCodes.Stfld, smAwait.Sm.State)

    // ---- Second user try (just GetResult + bind) ----
    il.BeginExceptionBlock() |> ignore
    ctx.TryDepth <- ctx.TryDepth + 1
    FunctionCtx.pushScope ctx

    il.Emit(OpCodes.Ldloca, awaiterLocal)
    il.Emit(OpCodes.Call, getResult)
    match bindName, returnedTy = typeof<System.Void> with
    | Some name, false ->
        let lb = FunctionCtx.defineLocal ctx name returnedTy
        il.Emit(OpCodes.Stloc, lb)
    | None, true -> ()
    | None, false -> il.Emit(OpCodes.Pop)
    | Some _, true -> ()
    il.Emit(OpCodes.Leave, afterSecondUserTry)

    FunctionCtx.popScope ctx
    ctx.TryDepth <- ctx.TryDepth - 1

    // Catches duplicated for the second user try.
    for c in catches do
        let exTy = resolveCatchType c.Type
        il.BeginCatchBlock(exTy)
        FunctionCtx.pushScope ctx
        match c.Bind with
        | Some name ->
            let lb = FunctionCtx.defineLocal ctx name exTy
            il.Emit(OpCodes.Stloc, lb)
        | None -> il.Emit(OpCodes.Pop)
        emitBlock ctx c.Body
        FunctionCtx.popScope ctx
        il.Emit(OpCodes.Leave, afterSecondUserTry)
    il.EndExceptionBlock()

    il.MarkLabel(afterSecondUserTry)
    il.MarkLabel(afterUserTry)

/// Phase B+++ defer + await emit (D-progress-057).
///
/// User code:
///     [pre-defer stmts (await-free)]
///     defer { cleanup-body (await-free) }
///     [between stmts (await-free)]
///     trailing-top-level-await
///
/// Lowered to a duplicated-post-await pattern with manual cleanup
/// (no IL `.finally` — we can't run cleanup on suspend, only on
/// real scope exits):
///
///     <pre-defer stmts>            // unprotected, before defer "registers"
///     .try {
///         <between stmts>
///         <compute awaiter>
///         if !IsCompleted: suspend; Leave SuspendLeaveLabel
///         GetResult; bind; Leave AfterFirstUserTry
///     } catch (Exception e) {
///         <cleanup-body>
///         rethrow
///     }
///   AfterFirstUserTry:
///     <cleanup-body>            // first-time normal exit
///     Br AfterScope
///
///   ResumeLabel:
///     awaiter = field; clear field; state = -1
///     .try {
///         GetResult; bind; Leave AfterSecondUserTry
///     } catch (Exception e) {
///         <cleanup-body>          // duplicated
///         rethrow
///     }
///   AfterSecondUserTry:
///     <cleanup-body>              // resume normal exit
///   AfterScope:
and emitDeferAwaitDuplicated
        (ctx: FunctionCtx)
        (deferBody: Block)
        (between: Statement list)
        (awaitStmt: Statement) : unit =
    let il = ctx.IL
    let smAwait =
        match ctx.SmAwaitInfo with
        | Some s -> s
        | None   -> failwith "internal: emitDeferAwaitDuplicated requires SmAwaitInfo"

    let rec unwrapAwait (e: Expr) : Expr =
        match e.Kind with
        | EAwait inner -> inner
        | EParen p -> unwrapAwait p
        | _ -> failwith "internal: unwrapAwait: not an await expression"
    let bindName : string option =
        match awaitStmt.Kind with
        | SExpr _ -> None
        | SLocal (LBVal ({ Kind = PBinding (n, None) }, _, _))
        | SLocal (LBLet (n, _, _))
        | SLocal (LBVar (n, _, Some _)) -> Some n
        | _ -> failwith "internal: emitDeferAwaitDuplicated: unexpected await stmt shape"
    let innerExpr : Expr =
        match awaitStmt.Kind with
        | SExpr e -> unwrapAwait e
        | SLocal (LBVal (_, _, init))
        | SLocal (LBLet (_, _, init))
        | SLocal (LBVar (_, _, Some init)) -> unwrapAwait init
        | _ -> failwith "internal: emitDeferAwaitDuplicated: unexpected await stmt shape"
    let bindAnnot : TypeExpr option =
        match awaitStmt.Kind with
        | SLocal (LBVal (_, ann, _))
        | SLocal (LBLet (_, ann, _))
        | SLocal (LBVar (_, ann, Some _)) -> ann
        | _ -> None

    let stateIndex = smAwait.NextAwaitIndex
    smAwait.NextAwaitIndex <- stateIndex + 1
    let resumeLabel = smAwait.ResumeLabels.[stateIndex]

    let afterFirstUserTry = il.DefineLabel()
    let afterSecondUserTry = il.DefineLabel()
    let afterScope = il.DefineLabel()
    let inlineAfterAwait = il.DefineLabel()

    let emitCleanup () =
        // Defer body runs; the body may declare locals — push a fresh
        // scope so they don't leak.
        emitBlock ctx deferBody

    // ---- First user .try ----
    il.BeginExceptionBlock() |> ignore
    ctx.TryDepth <- ctx.TryDepth + 1
    FunctionCtx.pushScope ctx

    // Between-defer-and-await stmts run inside the protected region.
    for s in between do
        emitStatement ctx s

    // Push the inner Task expression.
    let savedExpected = ctx.ExpectedType
    match bindAnnot with
    | Some te ->
        try ctx.ExpectedType <- Some (ctx.ResolveType te)
        with _ -> ()
    | None -> ()
    let taskTy = emitExpr ctx innerExpr
    ctx.ExpectedType <- savedExpected

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
        let openGetAwaiter =
            let mi = typedefof<System.Threading.Tasks.Task<_>>.GetMethod("GetAwaiter")
            match Option.ofObj mi with
            | Some m -> m
            | None -> failwith "E14 codegen: Task<>.GetAwaiter open-generic not found"
        let closedGetAwaiter = TypeBuilder.GetMethod(taskTy, openGetAwaiter)
        let openAwaiterTy = typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>>
        let closedAwaiterTy = openAwaiterTy.MakeGenericType([| elemTy |])
        let openGetResult =
            let mi = openAwaiterTy.GetMethod("GetResult")
            match Option.ofObj mi with
            | Some m -> m
            | None -> failwith "E14 codegen: TaskAwaiter<>.GetResult not found"
        let closedGetResult = TypeBuilder.GetMethod(closedAwaiterTy, openGetResult)
        closedGetAwaiter, closedAwaiterTy, closedGetResult, elemTy
    let getAwaiter, awaiterTy, getResult, returnedTy =
        if isClosedGenericOnTaskBuilder then resolveGenericTask ()
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
    let awaiterLocal = FunctionCtx.defineLocal ctx "__awaiter_defer" awaiterTy
    il.Emit(OpCodes.Stloc, awaiterLocal)

    let awaiterField =
        Lyric.Emitter.AsyncStateMachine.defineAwaiterField
            smAwait.Sm stateIndex awaiterTy
    smAwait.AwaiterFields.[stateIndex] <- awaiterField

    // IsCompleted check.
    let awaiterClosedOverTb =
        awaiterTy.IsGenericType
        && awaiterTy.GetGenericArguments()
           |> Array.exists (fun a ->
               a :? TypeBuilder
               || (a.IsGenericType && a.GetGenericArguments() |> Array.exists (fun b -> b :? TypeBuilder)))
    let isCompletedGetter =
        if awaiterClosedOverTb
           && awaiterTy.GetGenericTypeDefinition()
              = typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>> then
            let openTaskAwaiter = typedefof<System.Runtime.CompilerServices.TaskAwaiter<_>>
            let openGetter =
                openTaskAwaiter.GetMethods()
                |> Array.tryFind (fun m -> m.Name = "get_IsCompleted")
            match openGetter with
            | Some m -> TypeBuilder.GetMethod(awaiterTy, m)
            | None -> failwith "BCL: TaskAwaiter<>.get_IsCompleted not found"
        else
            match Option.ofObj (awaiterTy.GetProperty("IsCompleted")) with
            | Some p ->
                match Option.ofObj (p.GetGetMethod()) with
                | Some g -> g
                | None -> failwithf "E14 codegen: %s.get_IsCompleted missing" awaiterTy.Name
            | None -> failwithf "E14 codegen: %s.IsCompleted property missing" awaiterTy.Name

    il.Emit(OpCodes.Ldloca, awaiterLocal)
    il.Emit(OpCodes.Call, isCompletedGetter)
    il.Emit(OpCodes.Brtrue, inlineAfterAwait)

    // Suspend.
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldc_I4, stateIndex)
    il.Emit(OpCodes.Stfld, smAwait.Sm.State)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldloc, awaiterLocal)
    il.Emit(OpCodes.Stfld, awaiterField)
    for (lb, fld) in smAwait.PromotedShadows do
        il.Emit(OpCodes.Ldarg_0)
        il.Emit(OpCodes.Ldloc, lb)
        il.Emit(OpCodes.Stfld, fld)
    let builderTy = smAwait.Sm.BuilderType
    let builderClosedOverTb =
        builderTy.IsGenericType
        && builderTy.GetGenericArguments()
           |> Array.exists (fun a ->
               a :? TypeBuilder
               || (a.IsGenericType && a.GetGenericArguments() |> Array.exists (fun b -> b :? TypeBuilder)))
    let closedAwaitUnsafe =
        if builderClosedOverTb && builderTy.IsGenericType
           && builderTy.GetGenericTypeDefinition()
              = typedefof<System.Runtime.CompilerServices.AsyncTaskMethodBuilder<_>> then
            let openBuilder = typedefof<System.Runtime.CompilerServices.AsyncTaskMethodBuilder<_>>
            let openOnDef =
                openBuilder.GetMethods()
                |> Array.tryFind (fun m ->
                    m.Name = "AwaitUnsafeOnCompleted"
                    && m.IsGenericMethodDefinition
                    && m.GetGenericArguments().Length = 2)
            let closedOnBuilder =
                match openOnDef with
                | Some m -> TypeBuilder.GetMethod(builderTy, m)
                | None ->
                    failwith "BCL: AsyncTaskMethodBuilder<>.AwaitUnsafeOnCompleted<,> not found"
            closedOnBuilder.MakeGenericMethod([| awaiterTy; (smAwait.Sm.Type :> System.Type) |])
        else
            let openAwaitUnsafe =
                builderTy.GetMethods()
                |> Array.tryFind (fun m ->
                    m.Name = "AwaitUnsafeOnCompleted"
                    && m.IsGenericMethodDefinition
                    && m.GetGenericArguments().Length = 2)
            match openAwaitUnsafe with
            | Some m -> m.MakeGenericMethod([| awaiterTy; (smAwait.Sm.Type :> System.Type) |])
            | None -> failwithf "BCL: %s.AwaitUnsafeOnCompleted<,> not found" builderTy.Name
    let smLocal =
        FunctionCtx.defineLocal ctx "__this_sm_defer" (smAwait.Sm.Type :> System.Type)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Stloc, smLocal)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, smAwait.Sm.Builder)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, awaiterField)
    il.Emit(OpCodes.Ldloca, smLocal)
    il.Emit(OpCodes.Call, closedAwaitUnsafe)
    il.Emit(OpCodes.Leave, smAwait.SuspendLeaveLabel)

    // Inline-after-await: awaiter was already complete.
    il.MarkLabel(inlineAfterAwait)
    il.Emit(OpCodes.Ldloca, awaiterLocal)
    il.Emit(OpCodes.Call, getResult)
    match bindName, returnedTy = typeof<System.Void> with
    | Some name, false ->
        let lb = FunctionCtx.defineLocal ctx name returnedTy
        il.Emit(OpCodes.Stloc, lb)
    | None, true -> ()
    | None, false -> il.Emit(OpCodes.Pop)
    | Some _, true -> ()
    il.Emit(OpCodes.Leave, afterFirstUserTry)

    FunctionCtx.popScope ctx
    ctx.TryDepth <- ctx.TryDepth - 1

    // Synthetic catch: cleanup + rethrow.
    il.BeginCatchBlock(typeof<System.Exception>)
    FunctionCtx.pushScope ctx
    il.Emit(OpCodes.Pop)  // discard exception value (Rethrow uses CLR's currentException)
    emitCleanup ()
    il.Emit(OpCodes.Rethrow)
    FunctionCtx.popScope ctx
    il.EndExceptionBlock()

    il.MarkLabel(afterFirstUserTry)
    // First-time normal exit: cleanup runs then jump past the resume copy.
    emitCleanup ()
    il.Emit(OpCodes.Br, afterScope)

    // Resume entry (outside both .try blocks).
    il.MarkLabel(resumeLabel)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldfld, awaiterField)
    il.Emit(OpCodes.Stloc, awaiterLocal)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, awaiterField)
    il.Emit(OpCodes.Initobj, awaiterTy)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldc_I4_M1)
    il.Emit(OpCodes.Stfld, smAwait.Sm.State)

    // Second user .try: just GetResult + bind.
    il.BeginExceptionBlock() |> ignore
    ctx.TryDepth <- ctx.TryDepth + 1
    FunctionCtx.pushScope ctx

    il.Emit(OpCodes.Ldloca, awaiterLocal)
    il.Emit(OpCodes.Call, getResult)
    match bindName, returnedTy = typeof<System.Void> with
    | Some name, false ->
        let lb = FunctionCtx.defineLocal ctx name returnedTy
        il.Emit(OpCodes.Stloc, lb)
    | None, true -> ()
    | None, false -> il.Emit(OpCodes.Pop)
    | Some _, true -> ()
    il.Emit(OpCodes.Leave, afterSecondUserTry)

    FunctionCtx.popScope ctx
    ctx.TryDepth <- ctx.TryDepth - 1

    il.BeginCatchBlock(typeof<System.Exception>)
    FunctionCtx.pushScope ctx
    il.Emit(OpCodes.Pop)
    emitCleanup ()
    il.Emit(OpCodes.Rethrow)
    FunctionCtx.popScope ctx
    il.EndExceptionBlock()

    il.MarkLabel(afterSecondUserTry)
    emitCleanup ()
    il.MarkLabel(afterScope)
