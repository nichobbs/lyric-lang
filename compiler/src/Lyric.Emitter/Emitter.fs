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

/// Selects which kernel directory (`_kernel/` vs `_kernel_jvm/`) the
/// emitter uses for builtin `Std.*` packages.  `Dotnet` is the default;
/// `Jvm` is activated by `--target=jvm` (D041).
type CompileTarget = Dotnet | Jvm

type EmitRequest =
    { Source:       string
      AssemblyName: string
      OutputPath:   string
      /// Restored Lyric packages this build can resolve non-`Std.*`
      /// imports against (D-progress-077 follow-up).  The CLI
      /// populates this list from `lyric.toml`'s `[dependencies]`
      /// after running `lyric restore`.  Defaults to empty so
      /// existing call sites keep compiling.
      RestoredPackages: RestoredPackages.RestoredPackageRef list
      /// Absolute paths to NuGet DLLs the build should load into the
      /// AppDomain before resolving extern types (Phase 5 §M5.1
      /// stage 2d.v).  `lyric build` populates this from the
      /// `[nuget]` graph as walked from `project.assets.json`.
      NugetAssemblyPaths: string list
      /// Directory holding auto-generated `_extern/<lower-pkg>.l`
      /// shim sources (Phase 5 §M5.1 stage 2d.v).  When `Some`, the
      /// import resolver falls back to walking this directory for
      /// any `import <Pkg>` that didn't match a builtin head, a
      /// restored Lyric package, or an in-project package.  `None`
      /// preserves the legacy (no-NuGet) behaviour.
      ExternShimRoot: string option
      /// Compilation target platform.  Controls which `_kernel*`
      /// directory is used for builtin `Std.*` package resolution.
      Target: CompileTarget
      /// Active build-feature set per `docs/24-build-features.md`
      /// (D045).  Items annotated `@cfg(feature = "X")` are erased
      /// from the parse tree when `X` is not in this set.  Empty
      /// set means "no features active" — items with `@cfg`
      /// referencing any feature are erased.
      ActiveFeatures: Set<string>
      /// Features the manifest declares.  Used only for diagnostics
      /// — an `@cfg(feature = "Y")` with `Y` outside this set
      /// produces an `F0013` warning so typos are visible.  Empty
      /// when the manifest has no `[features]` section, in which
      /// case `F0013` is suppressed.
      DeclaredFeatures: Set<string> }

/// Backwards-compat constructor for callers that don't carry a
/// manifest — synonymous with `{ Source = ...; ...; RestoredPackages = []; Target = Dotnet }`.
let mkEmitRequest (source: string) (assemblyName: string) (outputPath: string) : EmitRequest =
    { Source = source
      AssemblyName = assemblyName
      OutputPath = outputPath
      RestoredPackages = []
      NugetAssemblyPaths = []
      ExternShimRoot = None
      Target = Dotnet
      ActiveFeatures = Set.empty
      DeclaredFeatures = Set.empty }

let private err (code: string) (msg: string) (span: Span) : Diagnostic =
    Diagnostic.error code msg span

/// Wrap `t` in `Task<t>`, or return `Task` for void. Used by the
/// async lowering: `async func` returns `Task[T]` even though the
/// E14 blocking shim runs the body synchronously.
let private toTaskType (t: System.Type) : System.Type =
    if t = typeof<System.Void> then
        typeof<System.Threading.Tasks.Task>
    else
        typedefof<System.Threading.Tasks.Task<_>>.MakeGenericType([| t |])

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

/// Pull every top-level `IProtected` out of a parsed source file
/// (D-progress-079).
let private protectedItems (sf: SourceFile) : ProtectedTypeDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IProtected p -> Some p
        | _ -> None)

/// Pull every top-level `IUnion` out of a parsed source file.
let private unionItems (sf: SourceFile) : UnionDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IUnion u -> Some u
        | _ -> None)

/// Pull every top-level `IInterface` out of a parsed source file.
let private interfaceItems (sf: SourceFile) : InterfaceDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IInterface i -> Some i
        | _ -> None)

/// Pull every top-level `IImpl` out of a parsed source file.
let private implItems (sf: SourceFile) : ImplDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IImpl i -> Some i
        | _ -> None)

/// Pull every top-level `IDistinctType` out of a parsed source file.
let private distinctTypeItems (sf: SourceFile) : DistinctTypeDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IDistinctType d -> Some d
        | _ -> None)

/// Pull every top-level `IExternType` out of a parsed source file.
let private externTypeItems (sf: SourceFile) : ExternTypeDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IExternType e -> Some e
        | _ -> None)

/// Pull every top-level `IOpaque` (with a body) out of a parsed source file.
/// Bodyless opaque declarations (`opaque type AccountId`) are name-only;
/// they don't lower to anything until cross-package linking arrives.
let private opaqueItems (sf: SourceFile) : OpaqueTypeDecl list =
    sf.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IOpaque o when o.HasBody -> Some o
        | _ -> None)

/// Map a top-level item's name to its declared visibility (`Item.Visibility`).
/// `defineMethodHeader` and the various `DefineType` sites consult this
/// to set CLR access flags so emitted PE metadata mirrors the Lyric
/// `pub` / `internal` / package-private boundary (M5.1 stage 2c.2.ii.c).
/// Items without a name (impls, wires, scope kinds, errors) are absent
/// from the map.
let private visibilityByName (sf: SourceFile) : Map<string, Visibility option> =
    sf.Items
    |> List.choose (fun it ->
        let nameOpt =
            match it.Kind with
            | IFunc fn          -> Some fn.Name
            | IRecord r
            | IExposedRec r     -> Some r.Name
            | IUnion u          -> Some u.Name
            | IEnum e           -> Some e.Name
            | IInterface i      -> Some i.Name
            | IDistinctType d   -> Some d.Name
            | IOpaque o         -> Some o.Name
            | IProtected p      -> Some p.Name
            | ITypeAlias a      -> Some a.Name
            | _                 -> None
        nameOpt |> Option.map (fun n -> n, it.Visibility))
    |> Map.ofList

/// CLR `TypeAttributes` for a declared visibility.  `internal` items
/// become `TypeAttributes.NotPublic` (assembly-private); everything
/// else (`pub` and unmarked package-private) becomes
/// `TypeAttributes.Public`.  Package-private retains `Public` for
/// bootstrap compatibility — the legacy per-package stdlib relies on
/// cross-DLL access to unmarked items, and the type checker doesn't
/// yet enforce a package-private boundary at call sites.  External
/// Lyric consumers see only `pub` items via the package's
/// `Lyric.Contract` resource regardless of CLR access flags.
let private typeAttrsForVis (vis: Visibility option) (extra: TypeAttributes) : TypeAttributes =
    match vis with
    | Some (Internal _) -> TypeAttributes.NotPublic ||| extra
    | _                 -> TypeAttributes.Public ||| extra

/// CLR `MethodAttributes` for a declared visibility.  `internal`
/// becomes `Assembly`; `pub` and unmarked stay `Public` for the same
/// reason as `typeAttrsForVis`.
let private methodAttrsForVis (vis: Visibility option) : MethodAttributes =
    match vis with
    | Some (Internal _) -> MethodAttributes.Assembly
    | _                 -> MethodAttributes.Public

/// CLR `TypeAttributes` for a nested type whose containing parent has
/// the given visibility.  Mirrors `typeAttrsForVis` but uses the
/// `Nested*` flags.
let private nestedTypeAttrsForVis (vis: Visibility option) (extra: TypeAttributes) : TypeAttributes =
    match vis with
    | Some (Internal _) -> TypeAttributes.NestedAssembly ||| extra
    | _                 -> TypeAttributes.NestedPublic ||| extra

/// Convert an `OpaqueTypeDecl` body into a synthetic `RecordDecl` for
/// reuse of the record-emission pipeline.  The CLR shape is identical
/// (sealed class with public fields and an all-fields ctor); the M2.2
/// bootstrap deliberately ignores the package-visibility boundary, which
/// arrives once cross-package compilation can enforce it.
let private opaqueAsRecord (o: OpaqueTypeDecl) : RecordDecl =
    let members =
        o.Members
        |> List.map (fun m ->
            match m with
            | OMField fd      -> RMField fd
            | OMInvariant inv -> RMInvariant inv)
    { Name     = o.Name
      Generics = o.Generics
      Where    = o.Where
      Members  = members
      Span     = o.Span }

/// True if any annotation on `o` has `projectable` as its head segment.
let private isProjectable (o: OpaqueTypeDecl) : bool =
    o.Annotations
    |> List.exists (fun a ->
        match a.Name.Segments with
        | "projectable" :: _ -> true
        | _ -> false)

/// True if a field's annotation list contains `@projectionBoundary`.
/// Per the language reference §2.9, this annotation breaks
/// recursive view projection on a field of `@projectable` type.
/// The bootstrap implementation simply leaves the field's view-side
/// type as the source opaque (cycle-safe) rather than projecting as
/// the source's id (the `asId` mode in the spec).  Either way the
/// cycle is broken; the bootstrap chooses the option that doesn't
/// require a runtime id-lookup.
let private isProjectionBoundaryField (fd: FieldDecl) : bool =
    fd.Annotations
    |> List.exists (fun a ->
        match a.Name.Segments with
        | "projectionBoundary" :: _ -> true
        | _ -> false)

/// True if a field's annotation list contains `@hidden`.
let private isHiddenField (fd: FieldDecl) : bool =
    fd.Annotations
    |> List.exists (fun a ->
        match a.Name.Segments with
        | "hidden" :: _ -> true
        | _ -> false)

/// Define a CLR interface for one Lyric interface declaration. Each
/// `IMSig` member becomes an abstract interface method; default
/// methods (`IMFunc`) and associated types are accepted by the
/// parser but their lowering is deferred per D035.
let private defineInterface
        (md: ModuleBuilder)
        (nsName: string)
        (symbols: SymbolTable)
        (lookup: TypeId -> System.Type option)
        (vis: Visibility option)
        (id: InterfaceDecl) : Records.InterfaceInfo =
    let fullName =
        if String.IsNullOrEmpty nsName then id.Name
        else nsName + "." + id.Name
    let tb =
        md.DefineType(
            fullName,
            typeAttrsForVis vis (TypeAttributes.Interface ||| TypeAttributes.Abstract),
            null)
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    let resolveTy (te: TypeExpr) : System.Type =
        let lty = Resolver.resolveType symbols resolveCtx scratchDiags te
        TypeMap.toClrTypeWith lookup lty
    let resolveRet (te: TypeExpr option) : System.Type =
        match te with
        | Some t ->
            let lty = Resolver.resolveType symbols resolveCtx scratchDiags t
            TypeMap.toClrReturnTypeWith lookup lty
        | None -> typeof<System.Void>

    let members =
        id.Members
        |> List.choose (fun m ->
            match m with
            | IMSig fs ->
                // Method-level generic params on interface signatures.
                let methGenericNames : string list =
                    match fs.Generics with
                    | Some gs ->
                        gs.Params
                        |> List.map (function GPType(n, _) | GPValue(n, _, _) -> n)
                    | None -> []
                if not methGenericNames.IsEmpty then resolveCtx.Push methGenericNames
                let methodAttrs =
                    MethodAttributes.Public
                    ||| MethodAttributes.Abstract
                    ||| MethodAttributes.Virtual
                    ||| MethodAttributes.HideBySig
                    ||| MethodAttributes.NewSlot
                let mb, pTys, rTy =
                    if methGenericNames.IsEmpty then
                        let pts =
                            fs.Params
                            |> List.map (fun p -> resolveTy p.Type)
                            |> List.toArray
                        let bareRet = resolveRet fs.Return
                        let rt = if fs.IsAsync then toTaskType bareRet else bareRet
                        let m = tb.DefineMethod(fs.Name, methodAttrs, rt, pts)
                        m, pts, rt
                    else
                        let m = tb.DefineMethod(fs.Name, methodAttrs)
                        let gtpbs =
                            m.DefineGenericParameters(methGenericNames |> List.toArray)
                            |> Array.map (fun g -> g :> System.Type)
                        let gsubst =
                            methGenericNames
                            |> List.mapi (fun i name -> name, gtpbs.[i])
                            |> Map.ofList
                        let pts =
                            fs.Params
                            |> List.map (fun p ->
                                let lty =
                                    Resolver.resolveType symbols resolveCtx scratchDiags p.Type
                                TypeMap.toClrTypeWithGenerics lookup gsubst lty)
                            |> List.toArray
                        let bareRet =
                            match fs.Return with
                            | Some t ->
                                let lty =
                                    Resolver.resolveType symbols resolveCtx scratchDiags t
                                TypeMap.toClrReturnTypeWithGenerics lookup gsubst lty
                            | None -> typeof<System.Void>
                        let rt = if fs.IsAsync then toTaskType bareRet else bareRet
                        m.SetParameters pts
                        m.SetReturnType rt
                        m, pts, rt
                fs.Params
                |> List.iteri (fun i p ->
                    mb.DefineParameter(i + 1, ParameterAttributes.None, p.Name)
                    |> ignore)
                if not methGenericNames.IsEmpty then resolveCtx.Pop()
                Some
                    { Records.InterfaceMember.Name   = fs.Name
                      Records.InterfaceMember.Method = mb
                      Records.InterfaceMember.Params = pTys |> List.ofArray
                      Records.InterfaceMember.Return = rTy }
            | IMFunc _ | IMAssoc _ -> None)
    { Records.InterfaceInfo.Name    = id.Name
      Records.InterfaceInfo.Type    = tb
      Records.InterfaceInfo.Members = members }

/// Define a CLR struct backing one Lyric distinct type (or range subtype).
///
/// The struct has a single public `Value` field of the underlying primitive
/// type and a static `From(x)` factory.  For range subtypes (`Range` is
/// `Some`), `From` performs a bounds check that panics on violation, and
/// — when `Std.Core.Result` is in the imported-union table — a static
/// `TryFrom(x): Result[Self, String]` is synthesised that performs the
/// same bounds check but returns `Err(error = msg)` on violation instead
/// of throwing.
let private defineDistinctType
        (md: ModuleBuilder)
        (nsName: string)
        (lookup: TypeId -> System.Type option)
        (symbols: SymbolTable)
        (importedUnions: Records.ImportedUnionTable)
        (vis: Visibility option)
        (dt: DistinctTypeDecl) : Records.DistinctTypeInfo =
    let fullName =
        if String.IsNullOrEmpty nsName then dt.Name
        else nsName + "." + dt.Name
    // Resolve the underlying CLR type for the primitive.
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    let underlyingLy =
        Resolver.resolveType symbols resolveCtx scratchDiags dt.Underlying
    let underlyingClr = TypeMap.toClrTypeWith lookup underlyingLy

    // A struct (value type) with explicit layout.
    let tb =
        md.DefineType(
            fullName,
            typeAttrsForVis vis
                (TypeAttributes.Sealed
                 ||| TypeAttributes.SequentialLayout
                 ||| TypeAttributes.BeforeFieldInit),
            typeof<System.ValueType>)
    let valueField =
        tb.DefineField("Value", underlyingClr, FieldAttributes.Public)

    // Range-bound evaluation.  Defers to `ConstFold.tryFoldInt` so
    // symbolic bounds (named consts, `MIN ..= cap - 1`, etc.) get
    // folded the same way the well-formedness checker folds them.
    // Bounds that the folder can't evaluate fall through to "no
    // compile-time bound" — the type checker has already emitted
    // T0093 for the user.  `upperExclusive` is true for `a ..< b`
    // half-open ranges.
    let evalConst (e: Expr) : int64 option =
        match ConstFold.tryFoldInt symbols e with
        | Ok v    -> Some v
        | Error _ -> None
    let literalBounds : (int64 * int64 * bool) option =
        match dt.Range with
        | Some (RBClosed(loExpr, hiExpr)) ->
            match evalConst loExpr, evalConst hiExpr with
            | Some lo, Some hi -> Some (lo, hi, false)
            | _ -> None
        | Some (RBHalfOpen(loExpr, hiExpr)) ->
            match evalConst loExpr, evalConst hiExpr with
            | Some lo, Some hi -> Some (lo, hi, true)
            | _ -> None
        | _ -> None

    // Emit `if x < lo || x op_hi hi goto failLbl`, where op_hi is `>`
    // for closed ranges and `>=` for half-open ranges.
    let emitBoundsCheck (il: ILGenerator) (failLbl: Label)
            (lo: int64) (hi: int64) (upperExclusive: bool) : unit =
        let emitConst (n: int64) =
            if underlyingClr = typeof<int64> then
                il.Emit(OpCodes.Ldc_I8, n)
            else
                il.Emit(OpCodes.Ldc_I4, int n)
        il.Emit(OpCodes.Ldarg_0)
        emitConst lo
        il.Emit(OpCodes.Blt, failLbl)
        il.Emit(OpCodes.Ldarg_0)
        emitConst hi
        if upperExclusive then il.Emit(OpCodes.Bge, failLbl)
        else il.Emit(OpCodes.Bgt, failLbl)

    let bracket (upperExclusive: bool) =
        if upperExclusive then ")" else "]"

    // Static `From(x)` factory.
    let fromMb =
        tb.DefineMethod(
            "From",
            MethodAttributes.Public ||| MethodAttributes.Static,
            tb,
            [| underlyingClr |])
    fromMb.DefineParameter(1, ParameterAttributes.None, "x") |> ignore
    let fromIl = fromMb.GetILGenerator()

    // Optional range check in `From` (panic on violation).
    match literalBounds with
    | Some (lo, hi, upperExclusive) ->
        let okLbl = fromIl.DefineLabel()
        let failLbl = fromIl.DefineLabel()
        emitBoundsCheck fromIl failLbl lo hi upperExclusive
        fromIl.Emit(OpCodes.Br, okLbl)
        fromIl.MarkLabel(failLbl)
        let msg =
            sprintf "%s.from: value out of range [%d, %d%s"
                dt.Name lo hi (bracket upperExclusive)
        fromIl.Emit(OpCodes.Ldstr, msg)
        let ioe = typeof<System.InvalidOperationException>
        let ioCtor = ioe.GetConstructor([| typeof<string> |])
        match Option.ofObj ioCtor with
        | Some c -> fromIl.Emit(OpCodes.Newobj, c)
        | None -> failwith "InvalidOperationException(string) ctor not found"
        fromIl.Emit(OpCodes.Throw)
        fromIl.MarkLabel(okLbl)
    | None -> ()  // no range constraint or non-literal bounds

    // Create and return the struct.
    let localVar = fromIl.DeclareLocal(tb)
    fromIl.Emit(OpCodes.Ldloca, localVar)
    fromIl.Emit(OpCodes.Initobj, tb)
    fromIl.Emit(OpCodes.Ldloca, localVar)
    fromIl.Emit(OpCodes.Ldarg_0)
    fromIl.Emit(OpCodes.Stfld, valueField)
    fromIl.Emit(OpCodes.Ldloc, localVar)
    fromIl.Emit(OpCodes.Ret)

    // Optional `TryFrom(x)` factory returning `Result[Self, String]`.
    // Synthesised iff (a) bounds are literal and (b) `Std.Core.Result`
    // is imported — otherwise `info.TryFromMethod` stays `None` and the
    // call site surfaces a diagnostic.
    let tryFromMethod : MethodBuilder option =
        match literalBounds, importedUnions.TryGetValue "Result" with
        | Some (lo, hi, upperExclusive), (true, resultInfo) ->
            let okCase  = resultInfo.Cases |> List.tryFind (fun c -> c.Name = "Ok")
            let errCase = resultInfo.Cases |> List.tryFind (fun c -> c.Name = "Err")
            match okCase, errCase with
            | Some okCase, Some errCase ->
                let typeArgs = [| (tb :> System.Type); typeof<string> |]
                let resultClosed = resultInfo.Type.MakeGenericType typeArgs
                let okClosed     = okCase.Type.MakeGenericType typeArgs
                let errClosed    = errCase.Type.MakeGenericType typeArgs
                // `TypeBuilder.GetConstructor` produces a runtime ctor
                // reference for a generic instance closed over a
                // TypeBuilder; the bare `GetConstructors` route fails
                // with NotSupportedException on TypeBuilderInstantiation.
                let okCtor  = TypeBuilder.GetConstructor(okClosed, okCase.Ctor)
                let errCtor = TypeBuilder.GetConstructor(errClosed, errCase.Ctor)
                let mb =
                    tb.DefineMethod(
                        "TryFrom",
                        MethodAttributes.Public ||| MethodAttributes.Static,
                        resultClosed,
                        [| underlyingClr |])
                mb.DefineParameter(1, ParameterAttributes.None, "x") |> ignore
                let il = mb.GetILGenerator()
                let failLbl = il.DefineLabel()
                emitBoundsCheck il failLbl lo hi upperExclusive
                // OK branch — build self struct, wrap in Ok(value = self).
                let selfLocal = il.DeclareLocal(tb)
                il.Emit(OpCodes.Ldloca, selfLocal)
                il.Emit(OpCodes.Initobj, tb)
                il.Emit(OpCodes.Ldloca, selfLocal)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Stfld, valueField)
                il.Emit(OpCodes.Ldloc, selfLocal)
                il.Emit(OpCodes.Newobj, okCtor)
                il.Emit(OpCodes.Ret)
                // Err branch — wrap a static error message in Err.
                il.MarkLabel(failLbl)
                let msg =
                    sprintf "%s.tryFrom: value out of range [%d, %d%s"
                        dt.Name lo hi (bracket upperExclusive)
                il.Emit(OpCodes.Ldstr, msg)
                il.Emit(OpCodes.Newobj, errCtor)
                il.Emit(OpCodes.Ret)
                Some mb
            | _ -> None
        | _ -> None

    // ---- derives Equals ----------------------------------------------
    // `equals(other: <Self>): Bool` — compare backing `Value` fields.
    if List.contains "Equals" dt.Derives then
        let mb =
            tb.DefineMethod(
                "equals",
                MethodAttributes.Public ||| MethodAttributes.HideBySig,
                typeof<bool>,
                [| tb :> System.Type |])
        mb.DefineParameter(1, ParameterAttributes.None, "other") |> ignore
        let il = mb.GetILGenerator()
        il.Emit(OpCodes.Ldarg_0)
        il.Emit(OpCodes.Ldfld, valueField)
        il.Emit(OpCodes.Ldarg_1)
        il.Emit(OpCodes.Ldfld, valueField)
        il.Emit(OpCodes.Ceq)
        il.Emit(OpCodes.Ret)

    // ---- derives Hash ------------------------------------------------
    // `hash(): UInt` — box the underlying primitive and call GetHashCode.
    if List.contains "Hash" dt.Derives then
        let mb =
            tb.DefineMethod(
                "hash",
                MethodAttributes.Public ||| MethodAttributes.HideBySig,
                typeof<uint32>,
                [||])
        let il = mb.GetILGenerator()
        il.Emit(OpCodes.Ldarg_0)
        il.Emit(OpCodes.Ldfld, valueField)
        il.Emit(OpCodes.Box, underlyingClr)
        let getHash =
            match Option.ofObj (typeof<obj>.GetMethod("GetHashCode")) with
            | Some m -> m
            | None   -> failwith "Object::GetHashCode not found"
        il.Emit(OpCodes.Callvirt, getHash)
        il.Emit(OpCodes.Ret)

    // ---- inherent `to<Underlying>()` conversion ---------------------
    // Always present: `type UserId = Int` gets `toInt(): Int`.  Per the
    // spec the reverse `Long.toUserId(x)` is opt-in (user-declared);
    // only the projection direction is automatic.
    let underlyingMethodName =
        if   underlyingClr = typeof<int32>  then Some "toInt"
        elif underlyingClr = typeof<int64>  then Some "toLong"
        elif underlyingClr = typeof<uint32> then Some "toUInt"
        elif underlyingClr = typeof<uint64> then Some "toULong"
        elif underlyingClr = typeof<byte>   then Some "toByte"
        elif underlyingClr = typeof<single> then Some "toFloat"
        elif underlyingClr = typeof<double> then Some "toDouble"
        else None
    match underlyingMethodName with
    | Some name ->
        let mb =
            tb.DefineMethod(
                name,
                MethodAttributes.Public ||| MethodAttributes.HideBySig,
                underlyingClr,
                [||])
        let il = mb.GetILGenerator()
        il.Emit(OpCodes.Ldarg_0)
        il.Emit(OpCodes.Ldfld, valueField)
        il.Emit(OpCodes.Ret)
    | None -> ()

    // ---- derives Default ---------------------------------------------
    // `default(): <Self>` static — wrap the underlying type's zero.
    // Range-constrained types reject this at definition time when their
    // zero falls outside the range; the bootstrap accepts both because
    // the M2.1 range bounds we honour are int literals.
    if List.contains "Default" dt.Derives then
        let mb =
            tb.DefineMethod(
                "default",
                MethodAttributes.Public ||| MethodAttributes.Static
                ||| MethodAttributes.HideBySig,
                tb,
                [||])
        let il = mb.GetILGenerator()
        if underlyingClr = typeof<int64> then il.Emit(OpCodes.Ldc_I8, 0L)
        elif underlyingClr = typeof<float> then il.Emit(OpCodes.Ldc_R4, 0.0f)
        elif underlyingClr = typeof<double> then il.Emit(OpCodes.Ldc_R8, 0.0)
        else il.Emit(OpCodes.Ldc_I4_0)
        il.Emit(OpCodes.Call, fromMb)
        il.Emit(OpCodes.Ret)

    { Records.DistinctTypeInfo.Name       = dt.Name
      Records.DistinctTypeInfo.Type       = tb
      Records.DistinctTypeInfo.ValueField = valueField
      Records.DistinctTypeInfo.FromMethod = fromMb
      Records.DistinctTypeInfo.TryFromMethod = tryFromMethod
      Records.DistinctTypeInfo.Derives    = dt.Derives }

/// Define a CLR enum type backing one Lyric enum. Each case becomes
/// a `Public Static Literal` field with a sequential ordinal value,
/// matching the strategy doc's §8.2 "variant-free unions" lowering.
let private defineEnum
        (md: ModuleBuilder)
        (nsName: string)
        (vis: Visibility option)
        (ed: EnumDecl) : Records.EnumInfo =
    let fullName =
        if String.IsNullOrEmpty nsName then ed.Name
        else nsName + "." + ed.Name
    let eb =
        md.DefineEnum(
            fullName,
            typeAttrsForVis vis (enum<TypeAttributes> 0),
            typeof<int32>)
    let cases =
        ed.Cases
        |> List.mapi (fun i c ->
            eb.DefineLiteral(c.Name, box i) |> ignore
            { Records.EnumCase.Name = c.Name; Records.EnumCase.Ordinal = i })
    let ty = eb.CreateType()
    { Records.EnumInfo.Name  = ed.Name
      Records.EnumInfo.Type  = ty
      Records.EnumInfo.Cases = cases }

/// Intermediate state between union pass 1 (TypeBuilder stub creation)
/// and union pass 2 (field + ctor population with the full type lookup).
/// Carrying this between the two passes avoids the D035 erasure of
/// non-generic union case fields to `obj`.
type private UnionBase =
    { Decl:           UnionDecl
      FullName:       string
      BaseTy:         TypeBuilder
      BaseCtor:       ConstructorBuilder
      TypeParamNames: string list
      IsGeneric:      bool
      /// (case-decl, case-TypeBuilder, type-param-subst,
      ///  parent-ctor-receiver for generic cases: Some parentOnCaseTps)
      CaseStubs:      (UnionCase * TypeBuilder * Map<string, System.Type> * System.Type option) list }

/// Phase-1: create the abstract base + sealed case TypeBuilders and emit
/// the base protected ctor.  Field and constructor definition is deferred
/// to `defineUnionPopulate` so the full type-lookup is available.
///
/// Non-generic unions use proper CLR nested types for case classes (keeps
/// cross-assembly TypeRef metadata clean).  Generic unions emit each case
/// as its own top-level generic class whose type params shadow the
/// parent's, inheriting from the constructed parent.
let private defineUnionBase
        (md: ModuleBuilder)
        (nsName: string)
        (vis: Visibility option)
        (ud: UnionDecl) : UnionBase =
    let fullName =
        if String.IsNullOrEmpty nsName then ud.Name
        else nsName + "." + ud.Name
    let typeParamNames =
        match ud.Generics with
        | Some gs ->
            gs.Params
            |> List.map (function
                | GPType(name, _) | GPValue(name, _, _) -> name)
        | None -> []
    let isGeneric = not typeParamNames.IsEmpty

    let baseTy =
        md.DefineType(
            fullName,
            typeAttrsForVis vis TypeAttributes.Abstract,
            typeof<obj>)
    // Side-effect: marks baseTy as a generic type definition.
    if isGeneric then
        baseTy.DefineGenericParameters(typeParamNames |> List.toArray) |> ignore

    // Protected default ctor on the base so subclass ctors can chain.
    let baseCtor =
        baseTy.DefineConstructor(
            MethodAttributes.Family ||| MethodAttributes.HideBySig,
            CallingConventions.Standard,
            [||])
    let baseCtorIl = baseCtor.GetILGenerator()
    baseCtorIl.Emit(OpCodes.Ldarg_0)
    let objCtor = typeof<obj>.GetConstructor([||])
    match Option.ofObj objCtor with
    | Some c -> baseCtorIl.Emit(OpCodes.Call, c)
    | None   -> failwith "object's no-arg ctor not found"
    baseCtorIl.Emit(OpCodes.Ret)

    let caseStubs =
        ud.Cases
        |> List.map (fun c ->
            let caseTy, caseSubst, caseParentForCtor =
                if isGeneric then
                    let caseFull = fullName + "_" + c.Name
                    let tb =
                        md.DefineType(
                            caseFull,
                            typeAttrsForVis vis TypeAttributes.Sealed,
                            typeof<obj>)
                    let tps = tb.DefineGenericParameters(typeParamNames |> List.toArray)
                    let parentOnCaseTps =
                        baseTy.MakeGenericType(tps |> Array.map (fun t -> t :> System.Type))
                    tb.SetParent(parentOnCaseTps)
                    let subst =
                        typeParamNames
                        |> List.mapi (fun i name -> name, tps.[i] :> System.Type)
                        |> Map.ofList
                    tb, subst, Some parentOnCaseTps
                else
                    // Top-level type with `_` separator (same convention as
                    // generic unions) avoids PersistedAssemblyBuilder bugs
                    // with nested-type field / method references in external
                    // assemblies (ldsfld / callvirt on nested-type members
                    // produces invalid MemberRef signatures).
                    let caseFull = fullName + "_" + c.Name
                    let tb =
                        md.DefineType(
                            caseFull,
                            typeAttrsForVis vis TypeAttributes.Sealed,
                            baseTy :> System.Type)
                    tb, Map.empty, None
            (c, caseTy, caseSubst, caseParentForCtor))

    { Decl           = ud
      FullName       = fullName
      BaseTy         = baseTy
      BaseCtor       = baseCtor
      TypeParamNames = typeParamNames
      IsGeneric      = isGeneric
      CaseStubs      = caseStubs }

/// Phase-2: populate union case fields and emit their constructors using
/// the full `lookup` (which now has every record/union TypeBuilder stub
/// registered).  For non-generic unions this resolves field types to
/// their proper CLR TypeBuilders instead of erasing them to `obj`.
let private defineUnionPopulate
        (symbols: SymbolTable)
        (lookup: TypeId -> System.Type option)
        (ub: UnionBase) : Records.UnionInfo =
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    if ub.IsGeneric then resolveCtx.Push(ub.TypeParamNames)

    let cases =
        ub.CaseStubs
        |> List.map (fun (c, caseTy, caseSubst, caseParentForCtor) ->
            let payload =
                c.Fields
                |> List.mapi (fun i f ->
                    let lty, fname =
                        match f with
                        | UFNamed (n, te, _) ->
                            Resolver.resolveType symbols resolveCtx scratchDiags te, n
                        | UFPos (te, _) ->
                            Resolver.resolveType symbols resolveCtx scratchDiags te,
                            sprintf "Item%d" (i + 1)
                    let cty =
                        if ub.IsGeneric then
                            // Generic unions: substitute TyVar via the case's
                            // GTPBs; leave TyUser unresolved — type application
                            // happens at call sites.
                            TypeMap.toClrTypeWithGenerics
                                (fun _ -> None) caseSubst lty
                        else
                            // Non-generic unions: use the full lookup so
                            // user-defined field types (records, unions, etc.)
                            // get their proper CLR TypeBuilders rather than
                            // being erased to `obj`.
                            TypeMap.toClrTypeWithGenerics lookup Map.empty lty
                    let fb =
                        caseTy.DefineField(
                            fname,
                            cty,
                            FieldAttributes.Public ||| FieldAttributes.InitOnly)
                    { Records.UnionPayloadField.Name      = fname
                      Records.UnionPayloadField.Type      = cty
                      Records.UnionPayloadField.LyricType = lty
                      Records.UnionPayloadField.Field     = fb })
            let paramTypes =
                payload |> List.map (fun f -> f.Type) |> List.toArray
            let ctor =
                caseTy.DefineConstructor(
                    MethodAttributes.Public,
                    CallingConventions.Standard,
                    paramTypes)
            let cil = ctor.GetILGenerator()
            cil.Emit(OpCodes.Ldarg_0)
            // Reference parent ctor: for generic unions the call must go
            // through `TypeBuilder.GetConstructor` on the parent
            // instantiated to the case's GTPBs.
            match caseParentForCtor with
            | Some parent ->
                let parentCtorRef = TypeBuilder.GetConstructor(parent, ub.BaseCtor)
                cil.Emit(OpCodes.Call, parentCtorRef)
            | None ->
                cil.Emit(OpCodes.Call, ub.BaseCtor)
            payload
            |> List.iteri (fun i f ->
                cil.Emit(OpCodes.Ldarg_0)
                cil.Emit(OpCodes.Ldarg, i + 1)
                cil.Emit(OpCodes.Stfld, f.Field))
            cil.Emit(OpCodes.Ret)
            // For non-generic nullary cases: emit a singleton `Instance`
            // static field so local references within the same assembly all
            // point to the same object.  Generic cases are skipped.
            let instanceField =
                if payload.IsEmpty && not ub.IsGeneric then
                    let fb =
                        caseTy.DefineField(
                            "Instance",
                            caseTy :> System.Type,
                            FieldAttributes.Public
                            ||| FieldAttributes.Static
                            ||| FieldAttributes.InitOnly)
                    let cctor = caseTy.DefineTypeInitializer()
                    let ccil = cctor.GetILGenerator()
                    ccil.Emit(OpCodes.Newobj, ctor)
                    ccil.Emit(OpCodes.Stsfld, fb)
                    ccil.Emit(OpCodes.Ret)
                    Some fb
                else
                    None
            // For non-generic nullary cases: define a static `Get<Name>()`
            // method on the BASE type that does `ldsfld Instance; ret`.
            // External assemblies call this (cross-assembly method call works in
            // PersistedAssemblyBuilder) instead of emitting `ldsfld Instance`
            // directly (cross-assembly field references crash the IL writer).
            let getterMethod =
                match instanceField with
                | Some instField ->
                    let mb =
                        ub.BaseTy.DefineMethod(
                            "Get" + c.Name,
                            MethodAttributes.Public
                            ||| MethodAttributes.Static
                            ||| MethodAttributes.HideBySig,
                            ub.BaseTy :> System.Type,
                            [||])
                    let gil = mb.GetILGenerator()
                    gil.Emit(OpCodes.Ldsfld, instField)
                    gil.Emit(OpCodes.Ret)
                    Some mb
                | None -> None
            { Records.UnionCaseInfo.Name         = c.Name
              Records.UnionCaseInfo.Type         = caseTy
              Records.UnionCaseInfo.Fields       = payload
              Records.UnionCaseInfo.Ctor         = ctor
              Records.UnionCaseInfo.Instance     = instanceField
              Records.UnionCaseInfo.GetterMethod = getterMethod })

    { Records.UnionInfo.Name     = ub.Decl.Name
      Records.UnionInfo.Type     = ub.BaseTy
      Records.UnionInfo.Cases    = cases
      Records.UnionInfo.Generics = ub.TypeParamNames }

/// Define the CLR class + fields + ctor for one Lyric record. The
/// resulting `RecordInfo` goes into the per-emit `RecordTable` so
/// codegen can resolve constructors and field reads.
let private defineRecordOnto
        (tb: TypeBuilder)
        (typeParamNames: string list)
        (typeParamSubst: Map<string, System.Type>)
        (symbols: SymbolTable)
        (lookup: TypeId -> System.Type option)
        (rd: RecordDecl) : Records.RecordInfo =
    // Resolve each field's type via the typechecker's resolver, then
    // project to a CLR `System.Type` through the typeIdToClr lookup so
    // records that reference other user records pick up the matching
    // TypeBuilder rather than falling back to `obj`.  For generic
    // records, `typeParamSubst` substitutes Lyric `TyVar T` for the
    // record's GTPBs so a field declared `value: T` lowers to a CLR
    // field of type `!0` (the GTPB).
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    if not typeParamNames.IsEmpty then resolveCtx.Push(typeParamNames)
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
            let cty = TypeMap.toClrTypeWithGenerics lookup typeParamSubst lty
            let fb =
                tb.DefineField(
                    fd.Name,
                    cty,
                    FieldAttributes.Public ||| FieldAttributes.InitOnly)
            { Records.RecordField.Name      = fd.Name
              Records.RecordField.Type      = cty
              Records.RecordField.LyricType = lty
              Records.RecordField.Field     = fb })
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
    { Records.RecordInfo.Name     = rd.Name
      Records.RecordInfo.Type     = tb
      Records.RecordInfo.Fields   = fields
      Records.RecordInfo.Ctor     = ctor
      Records.RecordInfo.Generics = typeParamNames }

// ---------------------------------------------------------------------------
// Protected types (D-progress-079).
//
// Bootstrap-grade lowering: synthesise a sealed CLR class wrapping
// the protected state with a `Monitor`-based lock.  Every entry /
// func is emitted as a public instance method whose body runs
// inside `Monitor.Enter(lock); try { … } finally { Monitor.Exit(lock) }`.
// `when:` barriers throw `LyricAssertionException` on false (Ada-
// style condition-variable waiting is gated on Phase C scope
// plumbing — see D-progress-067).  `invariant:` clauses re-evaluate
// after each entry/func body returns its value.
// ---------------------------------------------------------------------------

/// Rewrite a protected-type entry/func body so bare references to
/// the protected type's own fields desugar into `self.<field>`
/// member accesses.  Per `docs/01-language-reference.md` §7.4, code
/// inside a `protected type` body treats its fields as implicitly
/// in-scope; the bootstrap codegen has no implicit-self lookup, so
/// we lower at the AST level before handing the body to
/// `emitFunctionBody`.  The rewrite skips bindings that the user's
/// scope shadows (parameter names, local `val`/`var` declarations).
let rec private desugarSelfFields
        (fieldNames: Set<string>)
        (shadowed: Set<string>)
        (e: Expr) : Expr =
    let recur = desugarSelfFields fieldNames shadowed
    let recurBlock blk : Block =
        let newStmts = desugarStmts fieldNames shadowed blk.Statements
        { blk with Statements = newStmts }
    let recurBranch (b: ExprOrBlock) : ExprOrBlock =
        match b with
        | EOBExpr  e -> EOBExpr  (recur e)
        | EOBBlock b -> EOBBlock (recurBlock b)
    match e.Kind with
    | EPath { Segments = [name] } when fieldNames.Contains name
                                       && not (shadowed.Contains name) ->
        let selfExpr : Expr = { Kind = ESelf; Span = e.Span }
        { e with Kind = EMember (selfExpr, name) }
    | EPath _ | ELiteral _ | ESelf | EResult | EError -> e
    | EInterpolated segs ->
        let segs' =
            segs
            |> List.map (function
                | ISText _ as t -> t
                | ISExpr e -> ISExpr (recur e))
        { e with Kind = EInterpolated segs' }
    | EParen inner -> { e with Kind = EParen (recur inner) }
    | ESpawn inner -> { e with Kind = ESpawn (recur inner) }
    | EOld inner -> { e with Kind = EOld (recur inner) }
    | EAwait inner -> { e with Kind = EAwait (recur inner) }
    | EPropagate inner -> { e with Kind = EPropagate (recur inner) }
    | ETry inner -> { e with Kind = ETry (recur inner) }
    | ETuple es -> { e with Kind = ETuple (es |> List.map recur) }
    | EList es -> { e with Kind = EList (es |> List.map recur) }
    | EIf (c, t, eOpt, tf) ->
        let c' = recur c
        let t' = recurBranch t
        let e' =
            match eOpt with
            | Some b -> Some (recurBranch b)
            | None -> None
        { e with Kind = EIf (c', t', e', tf) }
    | EMatch (s, arms) ->
        let s' = recur s
        let arms' =
            arms
            |> List.map (fun a ->
                let g' = a.Guard |> Option.map recur
                let body' = recurBranch a.Body
                { a with Guard = g'; Body = body' })
        { e with Kind = EMatch (s', arms') }
    | EForall (b, w, body) ->
        let w' = w |> Option.map recur
        { e with Kind = EForall (b, w', recur body) }
    | EExists (b, w, body) ->
        let w' = w |> Option.map recur
        { e with Kind = EExists (b, w', recur body) }
    | ELambda (ps, blk) ->
        let lambdaParamNames =
            ps
            |> List.map (fun p -> p.Name)
            |> Set.ofList
        let inner = Set.union shadowed lambdaParamNames
        { e with Kind = ELambda (ps, desugarBlock fieldNames inner blk) }
    | ECall (fnE, args) ->
        let fnE' = recur fnE
        let args' =
            args
            |> List.map (function
                | CAPositional v -> CAPositional (recur v)
                | CANamed (n, v, sp) -> CANamed (n, recur v, sp))
        { e with Kind = ECall (fnE', args') }
    | ETypeApp (fnE, ts) -> { e with Kind = ETypeApp (recur fnE, ts) }
    | EIndex (recv, idxs) ->
        { e with Kind = EIndex (recur recv, idxs |> List.map recur) }
    | EMember (recv, name) ->
        { e with Kind = EMember (recur recv, name) }
    | EPrefix (op, inner) ->
        { e with Kind = EPrefix (op, recur inner) }
    | EBinop (op, l, r) ->
        { e with Kind = EBinop (op, recur l, recur r) }
    | ERange rb ->
        let rb' =
            match rb with
            | RBClosed   (a, b) -> RBClosed   (recur a, recur b)
            | RBHalfOpen (a, b) -> RBHalfOpen (recur a, recur b)
            | RBLowerOpen a     -> RBLowerOpen (recur a)
            | RBUpperOpen a     -> RBUpperOpen (recur a)
        { e with Kind = ERange rb' }
    | EAssign (t, op, v) ->
        { e with Kind = EAssign (recur t, op, recur v) }
    | EBlock b ->
        { e with Kind = EBlock (desugarBlock fieldNames shadowed b) }
    | EUnsafe b ->
        { e with Kind = EUnsafe (desugarBlock fieldNames shadowed b) }

and private desugarBlock
        (fieldNames: Set<string>)
        (shadowed: Set<string>)
        (b: Block) : Block =
    { b with Statements = desugarStmts fieldNames shadowed b.Statements }

and private desugarStmts
        (fieldNames: Set<string>)
        (shadowed: Set<string>)
        (stmts: Statement list) : Statement list =
    let mutable currentShadow = shadowed
    [ for s in stmts ->
        let recurExpr = desugarSelfFields fieldNames currentShadow
        let recurBlk b = desugarBlock fieldNames currentShadow b
        let kind' =
            match s.Kind with
            | SExpr e -> SExpr (recurExpr e)
            | SThrow e -> SThrow (recurExpr e)
            | SReturn (Some e) -> SReturn (Some (recurExpr e))
            | SReturn None -> SReturn None
            | SAssign (t, op, v) ->
                SAssign (recurExpr t, op, recurExpr v)
            | SLocal (LBVal (p, ann, init)) ->
                let init' = recurExpr init
                // After the local binds, shadow any introduced names
                // for subsequent stmts in the same block.
                match p.Kind with
                | PBinding (n, _) -> currentShadow <- Set.add n currentShadow
                | _ -> ()
                SLocal (LBVal (p, ann, init'))
            | SLocal (LBLet (n, ann, init)) ->
                let init' = recurExpr init
                currentShadow <- Set.add n currentShadow
                SLocal (LBLet (n, ann, init'))
            | SLocal (LBVar (n, ann, Some init)) ->
                let init' = recurExpr init
                currentShadow <- Set.add n currentShadow
                SLocal (LBVar (n, ann, Some init'))
            | SLocal (LBVar (n, ann, None)) ->
                currentShadow <- Set.add n currentShadow
                SLocal (LBVar (n, ann, None))
            | SBreak _ | SContinue _ | SItem _ -> s.Kind
            | SInvariant e -> SInvariant (recurExpr e)
            | SRule (lhs, rhs) ->
                SRule (recurExpr lhs, recurExpr rhs)
            | STry (body, catches) ->
                let body' = recurBlk body
                let catches' =
                    catches
                    |> List.map (fun c -> { c with Body = recurBlk c.Body })
                STry (body', catches')
            | SDefer body -> SDefer (recurBlk body)
            | SScope (b, body) -> SScope (b, recurBlk body)
            | SFor (lbl, pat, iter, body) ->
                SFor (lbl, pat, recurExpr iter, recurBlk body)
            | SWhile (lbl, cond, body) ->
                SWhile (lbl, recurExpr cond, recurBlk body)
            | SLoop (lbl, body) ->
                SLoop (lbl, recurBlk body)
        { s with Kind = kind' } ]

let private desugarFunctionBody
        (fieldNames: Set<string>)
        (paramNames: Set<string>)
        (body: FunctionBody) : FunctionBody =
    match body with
    | FBExpr e -> FBExpr (desugarSelfFields fieldNames paramNames e)
    | FBBlock b -> FBBlock (desugarBlock fieldNames paramNames b)

/// Static cache of `System.Threading.ReaderWriterLockSlim` lookups
/// — protected-type wrappers acquire write mode for entries and
/// read mode for funcs (D-progress-081 / Q008).
let private rwLockTy : System.Type = typeof<System.Threading.ReaderWriterLockSlim>

let private rwLockCtor : Lazy<ConstructorInfo> =
    lazy (
        match Option.ofObj (rwLockTy.GetConstructor([||])) with
        | Some c -> c
        | None -> failwith "BCL: ReaderWriterLockSlim() ctor not found")

let private rwLockMethod (name: string) : Lazy<MethodInfo> =
    lazy (
        match Option.ofObj (rwLockTy.GetMethod(name, [||])) with
        | Some m -> m
        | None ->
            failwithf "BCL: ReaderWriterLockSlim.%s() not found" name)

let private rwEnterReadMI    = rwLockMethod "EnterReadLock"
let private rwExitReadMI     = rwLockMethod "ExitReadLock"
let private rwEnterWriteMI   = rwLockMethod "EnterWriteLock"
let private rwExitWriteMI    = rwLockMethod "ExitWriteLock"

/// Static cache of `System.Threading.SemaphoreSlim` lookups.  Used
/// for the entry-only branch of Q008's lock-flavour decision: a
/// protected type that declares no `func` members never benefits
/// from concurrent reads, so the wrapper drops the
/// reader-writer-lock cost in favour of a binary
/// `SemaphoreSlim(1, 1)` (D-progress-083).
let private semaphoreTy : System.Type = typeof<System.Threading.SemaphoreSlim>

let private semaphoreCtor : Lazy<ConstructorInfo> =
    lazy (
        match Option.ofObj (semaphoreTy.GetConstructor([| typeof<int>; typeof<int> |])) with
        | Some c -> c
        | None -> failwith "BCL: SemaphoreSlim(int, int) ctor not found")

let private semaphoreWaitMI : Lazy<MethodInfo> =
    lazy (
        // SemaphoreSlim has multiple `Wait` overloads — pick the
        // parameterless one which blocks until the slot is free.
        match Option.ofObj (semaphoreTy.GetMethod("Wait", [||])) with
        | Some m -> m
        | None -> failwith "BCL: SemaphoreSlim.Wait() not found")

let private semaphoreReleaseMI : Lazy<MethodInfo> =
    lazy (
        match Option.ofObj (semaphoreTy.GetMethod("Release", [||])) with
        | Some m -> m
        | None -> failwith "BCL: SemaphoreSlim.Release() not found")

/// Static cache of `System.Threading.Monitor` lookups — used as the
/// single-lock primitive for protected types that declare `when:`
/// barriers (D-progress-087).  The barrier wrapper threads through
/// `Monitor.Enter` / `Monitor.Wait(obj)` / `Monitor.PulseAll` /
/// `Monitor.Exit` so blocked callers wake on state change and re-
/// evaluate their barriers.
let private monitorTy : System.Type = typeof<System.Threading.Monitor>

let private monitorEnterMI : Lazy<MethodInfo> =
    lazy (
        match Option.ofObj (monitorTy.GetMethod("Enter", [| typeof<obj> |])) with
        | Some m -> m
        | None -> failwith "BCL: Monitor.Enter(object) not found")

let private monitorExitMI : Lazy<MethodInfo> =
    lazy (
        match Option.ofObj (monitorTy.GetMethod("Exit", [| typeof<obj> |])) with
        | Some m -> m
        | None -> failwith "BCL: Monitor.Exit(object) not found")

let private monitorPulseAllMI : Lazy<MethodInfo> =
    lazy (
        match Option.ofObj (monitorTy.GetMethod("PulseAll", [| typeof<obj> |])) with
        | Some m -> m
        | None -> failwith "BCL: Monitor.PulseAll(object) not found")

/// `Monitor.Wait(object)` — blocks the caller (releasing the lock)
/// until another thread calls `Monitor.Pulse`/`PulseAll` on the same
/// object, then re-acquires the lock and returns `true`.  The bool
/// return value is discarded at each call site; we always re-evaluate
/// the barrier after waking (spurious wakeups are safe).  Ada
/// specifies infinite waits for `entry … when …` barriers; the
/// caller is responsible for ensuring progress (D-progress-092).
let private monitorWaitMI : Lazy<MethodInfo> =
    lazy (
        match Option.ofObj
                (monitorTy.GetMethod("Wait", [| typeof<obj> |])) with
        | Some m -> m
        | None -> failwith "BCL: Monitor.Wait(object) not found")

/// Stash collected during Pass A so Pass B can emit each entry/func's
/// body wrapped in the lock + barrier + invariant scaffolding.
///
/// Two methods are defined per entry/func:
///   * `PublicMb` — the user-callable method (`incr` / `take` / etc.).
///     Pass B emits its body as a thin wrapper that acquires
///     `<>__lock` via `Monitor.Enter`, calls into the private
///     `UnsafeMb`, and releases the lock in a finally.
///   * `UnsafeMb` — the private `<unsafe>__<name>` method holding
///     the user's actual body.  Emitted via the regular
///     `emitFunctionBody` pipeline so contracts / control flow /
///     async / FFI all work uniformly.
///
/// Barrier (`when:`) and invariant checks live on the wrapper —
/// barriers run before delegating to the unsafe inner; invariants
/// run after the inner returns its value (still inside the lock,
/// inside the try/finally, before the `leave`).
type private ProtectedMethodPending =
    { PublicMb:     MethodBuilder
      UnsafeMb:     MethodBuilder
      Fn:           FunctionDecl
      Sg:           ResolvedSignature
      IsEntry:      bool
      /// Desugared `when: <expr>` barrier conditions — evaluated
      /// before the unsafe inner runs.  False throws
      /// `LyricAssertionException` so the bootstrap surfaces a
      /// "barrier not met" runtime error (Ada-style condition-
      /// variable waiting is gated on Phase C scope plumbing —
      /// see `06-open-questions.md` Q008).
      Barriers:     Expr list
      /// Desugared `invariant: <expr>` clauses — evaluated after
      /// the unsafe inner returns, still inside the lock and the
      /// outer try.  False throws `LyricAssertionException`.
      Invariants:   Expr list
      Owner:        Records.ProtectedTypeInfo
      LockField:    FieldBuilder
      ParamTypes:   System.Type[]
      ReturnType:   System.Type }

/// Pending ctor IL for a protected type — field initializers are
/// user-written Lyric expressions that need `Codegen.emitExpr`'s
/// FunctionCtx, which only becomes available in Pass B.  Pass A
/// stops the ctor IL after the lock allocation; Pass B picks up
/// the open ILGenerator, emits each `Stfld` against the field's
/// init expression, then writes `Ret`.
type private ProtectedCtorPending =
    { Owner:        Records.ProtectedTypeInfo
      Ctor:         ConstructorBuilder
      Initializers: (string * FieldBuilder * Expr) list }

/// Synthesise the CLR class scaffolding for a `protected type`:
/// fields per `var`/`let`/immutable, a private `<>__lock : object`
/// field, a default no-arg constructor that allocates the lock and
/// runs each field's initializer (or default-zero-initialises),
/// and one public method header per entry/func member.  Returns the
/// `ProtectedTypeInfo` plus the list of pending method bodies.
let private defineProtectedTypeOnto
        (md: ModuleBuilder)
        (nsName: string)
        (symbols: SymbolTable)
        (lookup: TypeId -> System.Type option)
        (codegenDiags: ResizeArray<Diagnostic>)
        (vis: Visibility option)
        (pd: ProtectedTypeDecl)
        : Records.ProtectedTypeInfo
          * ProtectedMethodPending list
          * ProtectedCtorPending =
    let fullName =
        if String.IsNullOrEmpty nsName then pd.Name
        else nsName + "." + pd.Name
    let tb =
        md.DefineType(
            fullName,
            typeAttrsForVis vis TypeAttributes.Sealed,
            typeof<obj>)
    // Generic protected types (`protected type Foo[T]`) define their
    // CLR generic parameters here.  Construction goes through the
    // LHS-driven inference path: `val b: Box[Int] = Box()` reads the
    // expected CLR type from `ctx.ExpectedType` and closes via
    // `MakeGenericType` at the call site.  Method dispatch on a
    // closed receiver routes via `TypeBuilder.GetMethod` so the
    // `Callvirt` instruction targets the constructed method ref.
    let typeParamNames : string list =
        match pd.Generics with
        | Some gs -> gs.Params |> List.map (function
                                            | GPType(name, _)
                                            | GPValue(name, _, _) -> name)
        | None    -> []
    let isGeneric = not typeParamNames.IsEmpty
    let typeGtpbs : System.Type[] =
        if isGeneric then
            tb.DefineGenericParameters(typeParamNames |> List.toArray)
            |> Array.map (fun g -> g :> System.Type)
        else [||]
    let typeParamSubst : Map<string, System.Type> =
        if isGeneric then
            typeParamNames
            |> List.mapi (fun i n -> n, typeGtpbs.[i])
            |> Map.ofList
        else Map.empty
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    if isGeneric then resolveCtx.Push(typeParamNames)

    // Fields — every PFVar/PFLet/PFImmutable becomes a public field.
    let fieldDecls =
        pd.Members
        |> List.choose (fun m ->
            match m with
            | PMField pf -> Some pf
            | _ -> None)
    let fieldEntries =
        fieldDecls
        |> List.map (fun pf ->
            let name, ty, init =
                match pf with
                | PFVar (n, t, init, _)
                | PFLet (n, t, init, _) -> n, t, init
                | PFImmutable fd -> fd.Name, fd.Type, None
            let lty =
                Resolver.resolveType symbols resolveCtx scratchDiags ty
            let cty =
                TypeMap.toClrTypeWithGenerics lookup typeParamSubst lty
            let fb = tb.DefineField(name, cty, FieldAttributes.Public)
            name, fb, init)
    let fieldNames =
        fieldEntries
        |> List.map (fun (n, _, _) -> n)
        |> Set.ofList

    // Lock field — private object, allocated in the ctor.
    // Lock field — Q008 tri-modal lock-flavour split:
    //   * `PLMonitor` (D-progress-087) — any `when:` barrier on any
    //     entry / func.  Single `obj` lock; barrier wrapper uses
    //     `Monitor.Wait` / `Monitor.PulseAll` for Ada-style
    //     condition-variable waiting.  Funcs lose concurrent reads
    //     since `Monitor` is the only BCL primitive with Wait/Pulse.
    //   * `PLRwLock` (D-progress-081) — declares at least one `func`
    //     AND no barriers.  Funcs take the read lock; entries take
    //     the write lock.
    //   * `PLSemaphore` (D-progress-083) — entry-only AND no
    //     barriers.  Binary `SemaphoreSlim(1, 1)`.
    let hasBarriers =
        pd.Members
        |> List.exists (fun m ->
            let contracts =
                match m with
                | PMEntry ed -> ed.Contracts
                | PMFunc fn  -> fn.Contracts
                | _ -> []
            contracts |> List.exists (function CCWhen _ -> true | _ -> false))
    let hasFuncs =
        pd.Members
        |> List.exists (fun m ->
            match m with
            | PMFunc _ -> true
            | _ -> false)
    let lockFlavour =
        if hasBarriers then Records.PLMonitor
        elif hasFuncs then Records.PLRwLock
        else Records.PLSemaphore
    let lockFieldType =
        match lockFlavour with
        | Records.PLMonitor   -> typeof<obj>
        | Records.PLRwLock    -> rwLockTy
        | Records.PLSemaphore -> semaphoreTy
    let lockField =
        tb.DefineField(
            "<>__lock",
            lockFieldType,
            FieldAttributes.Private ||| FieldAttributes.InitOnly)

    // Default no-arg ctor.  Initializes lock, then every field's
    // initializer (when present); fields without an initializer keep
    // CLR's default zero-init.
    let ctor =
        tb.DefineConstructor(
            MethodAttributes.Public,
            CallingConventions.Standard,
            [||])
    let cil = ctor.GetILGenerator()
    cil.Emit(OpCodes.Ldarg_0)
    let objCtor = typeof<obj>.GetConstructor([||])
    match Option.ofObj objCtor with
    | Some c -> cil.Emit(OpCodes.Call, c)
    | None   -> failwith "object's no-arg ctor not found"
    let objCtorNonNull =
        match Option.ofObj objCtor with
        | Some c -> c
        | None   -> failwith "object's no-arg ctor not found"
    cil.Emit(OpCodes.Ldarg_0)
    match lockFlavour with
    | Records.PLMonitor ->
        // Plain `new object()` — Monitor methods take any reference.
        cil.Emit(OpCodes.Newobj, objCtorNonNull)
    | Records.PLRwLock ->
        cil.Emit(OpCodes.Newobj, rwLockCtor.Value)
    | Records.PLSemaphore ->
        // SemaphoreSlim(initialCount = 1, maxCount = 1) is the
        // binary-lock shape — Wait blocks until the single slot is
        // free; Release returns it.
        cil.Emit(OpCodes.Ldc_I4_1)
        cil.Emit(OpCodes.Ldc_I4_1)
        cil.Emit(OpCodes.Newobj, semaphoreCtor.Value)
    cil.Emit(OpCodes.Stfld, lockField)
    // Field initializers + Ret are emitted in Pass B (the
    // user-written init expressions need a FunctionCtx, which only
    // becomes available after the function tables are populated).
    // Pass A leaves the IL generator open here.

    // Method headers — one per PMEntry / PMFunc.  Bodies emit in
    // Pass B once the FunctionCtx wiring is available.
    let mutable pending : ProtectedMethodPending list = []
    let mutable methods : Records.ProtectedMethod list = []

    let invariantClauses =
        pd.Members
        |> List.choose (fun m ->
            match m with
            | PMInvariant inv -> Some inv
            | _ -> None)
    // Invariants reference fields with bare names (`count <= 100`),
    // so desugar each clause expression once with the protected
    // type's field names + an empty shadow set (no params in
    // scope when an invariant evaluates).
    let desugaredInvariants =
        invariantClauses
        |> List.map (fun inv ->
            desugarSelfFields fieldNames Set.empty inv.Expr)

    // We need to construct the Records.ProtectedTypeInfo first so the
    // pending records can carry an `Owner` reference, but ctor + lock
    // depend on values defined above.  Build a forward `info` and let
    // the F# closure capture work it out.
    let protectedFields : Records.ProtectedField list =
        fieldEntries
        |> List.map (fun (n, fb, _) ->
            { Records.ProtectedField.Name  = n
              Records.ProtectedField.Type  = fb.FieldType
              Records.ProtectedField.Field = fb })
    let info : Records.ProtectedTypeInfo =
        { Name        = pd.Name
          Type        = tb
          Ctor        = ctor
          LockField   = lockField
          LockFlavour = lockFlavour
          Fields      = protectedFields
          Methods     = [] // methods filled below; pending records the live mb list
          Generics    = typeParamNames }

    let defineMethodPair (name: string) (paramList: Param list)
                          (returnTy: TypeExpr option) : MethodBuilder * MethodBuilder * System.Type[] * System.Type =
        let pTys =
            paramList
            |> List.map (fun p ->
                let lty = Resolver.resolveType symbols resolveCtx scratchDiags p.Type
                let bare =
                    TypeMap.toClrTypeWithGenerics lookup typeParamSubst lty
                match p.Mode with
                | PMOut | PMInout -> bare.MakeByRefType()
                | PMIn            -> bare)
            |> List.toArray
        let bareRet =
            match returnTy with
            | Some t ->
                let lty = Resolver.resolveType symbols resolveCtx scratchDiags t
                TypeMap.toClrReturnTypeWithGenerics lookup typeParamSubst lty
            | None -> typeof<System.Void>
        let publicMb =
            tb.DefineMethod(
                name,
                MethodAttributes.Public ||| MethodAttributes.HideBySig,
                bareRet,
                pTys)
        let unsafeMb =
            tb.DefineMethod(
                "<unsafe>__" + name,
                MethodAttributes.Private ||| MethodAttributes.HideBySig,
                bareRet,
                pTys)
        paramList
        |> List.iteri (fun i p ->
            publicMb.DefineParameter(i + 1, ParameterAttributes.None, p.Name) |> ignore
            unsafeMb.DefineParameter(i + 1, ParameterAttributes.None, p.Name) |> ignore)
        publicMb, unsafeMb, pTys, bareRet

    let synthSigOf (paramList: Param list) (returnTy: TypeExpr option) (isAsync: bool)
                   (span: Span) : ResolvedSignature =
        // For methods on a generic protected type, expose the class's
        // type-parameter names as `sg.Generics` so `emitFunctionBody`
        // can resolve `T` references in param / return / body
        // positions to the GTPBs (recovered from `selfType` since the
        // synthesised method itself isn't generic).
        { Generics = typeParamNames
          Bounds   = []
          Params   =
            paramList
            |> List.map (fun p ->
                let lty =
                    Resolver.resolveType
                        symbols resolveCtx scratchDiags p.Type
                { Name    = p.Name
                  Type    = lty
                  Mode    = p.Mode
                  Default = p.Default.IsSome
                  Span    = p.Span })
          Return =
            match returnTy with
            | Some t ->
                Resolver.resolveType
                    symbols resolveCtx scratchDiags t
            | None -> Lyric.TypeChecker.TyPrim Lyric.TypeChecker.PtUnit
          IsAsync = isAsync
          Span    = span }

    let paramNamesOf (ps: Param list) : Set<string> =
        ps |> List.map (fun p -> p.Name) |> Set.ofList

    let extractBarriers (paramNames: Set<string>) (contracts: ContractClause list) : Expr list =
        contracts
        |> List.choose (fun c ->
            match c with
            | CCWhen (cond, _) ->
                Some (desugarSelfFields fieldNames paramNames cond)
            | _ -> None)

    for m in pd.Members do
        match m with
        | PMEntry ed ->
            let publicMb, unsafeMb, pTys, bareRet =
                defineMethodPair ed.Name ed.Params ed.Return
            let pNames = paramNamesOf ed.Params
            let desugaredBody =
                desugarFunctionBody fieldNames pNames ed.Body
            let entryBarriers = extractBarriers pNames ed.Contracts
            let synthFn : FunctionDecl =
                { DocComments = []; Annotations = []
                  Visibility  = ed.Visibility
                  IsAsync     = false
                  Name        = ed.Name
                  Generics    = None
                  Params      = ed.Params
                  Return      = ed.Return
                  Where       = None
                  Contracts   = ed.Contracts
                  Body        = Some desugaredBody
                  Span        = ed.Span }
            let synthSig = synthSigOf ed.Params ed.Return false ed.Span
            methods <-
                methods
                @ [ { Records.ProtectedMethod.Name    = ed.Name
                      Records.ProtectedMethod.Method  = publicMb
                      Records.ProtectedMethod.IsEntry = true } ]
            pending <-
                pending
                @ [ { PublicMb   = publicMb
                      UnsafeMb   = unsafeMb
                      Fn         = synthFn
                      Sg         = synthSig
                      IsEntry    = true
                      Barriers   = entryBarriers
                      Invariants = desugaredInvariants
                      Owner      = info
                      LockField  = lockField
                      ParamTypes = pTys
                      ReturnType = bareRet } ]
        | PMFunc fn ->
            let publicMb, unsafeMb, pTys, bareRet =
                defineMethodPair fn.Name fn.Params fn.Return
            let synthSig = synthSigOf fn.Params fn.Return fn.IsAsync fn.Span
            let pNames = paramNamesOf fn.Params
            let desugaredFn =
                match fn.Body with
                | Some body ->
                    { fn with
                        Body = Some (desugarFunctionBody fieldNames pNames body) }
                | None -> fn
            let funcBarriers = extractBarriers pNames fn.Contracts
            methods <-
                methods
                @ [ { Records.ProtectedMethod.Name    = fn.Name
                      Records.ProtectedMethod.Method  = publicMb
                      Records.ProtectedMethod.IsEntry = false } ]
            pending <-
                pending
                @ [ { PublicMb   = publicMb
                      UnsafeMb   = unsafeMb
                      Fn         = desugaredFn
                      Sg         = synthSig
                      IsEntry    = false
                      Barriers   = funcBarriers
                      Invariants = desugaredInvariants
                      Owner      = info
                      LockField  = lockField
                      ParamTypes = pTys
                      ReturnType = bareRet } ]
        | _ -> ()

    let infoFinal = { info with Methods = methods }
    let initializers =
        fieldEntries
        |> List.choose (fun (n, fb, init) ->
            init |> Option.map (fun e -> n, fb, e))
    let ctorPending : ProtectedCtorPending =
        { Owner = infoFinal
          Ctor  = ctor
          Initializers = initializers }
    infoFinal, pending, ctorPending

/// Generate the sibling exposed record for a `@projectable` opaque type.
/// The view contains every non-`@hidden` field of the opaque type and
/// is itself a sealed CLR class with public fields and an all-fields
/// constructor — the same shape as a normal record.
/// Per-projectable scratch state collected across the staged view
/// derivation passes — so cross-referencing projectables can each
/// see the other's view TypeBuilder + toView method handle before
/// any IL is emitted.
type private ProjectableStub =
    { OpaqueDecl:    OpaqueTypeDecl
      OpaqueInfo:    Records.RecordInfo
      ViewBuilder:   TypeBuilder
      ViewName:      string
      VisibleFields: FieldDecl list
      mutable ToView: MethodBuilder option }

/// Pass A: define a stub `<Name>View` TypeBuilder (no fields, no ctor).
let private defineProjectableViewStub
        (md: ModuleBuilder)
        (nsName: string)
        (opaqueInfo: Records.RecordInfo)
        (vis: Visibility option)
        (od: OpaqueTypeDecl) : ProjectableStub =
    let viewName = od.Name + "View"
    let fullName =
        if String.IsNullOrEmpty nsName then viewName
        else nsName + "." + viewName
    let tb =
        md.DefineType(
            fullName,
            typeAttrsForVis vis TypeAttributes.Sealed,
            typeof<obj>)
    let visible =
        od.Members
        |> List.choose (function
            | OMField fd when not (isHiddenField fd) -> Some fd
            | _ -> None)
    { OpaqueDecl    = od
      OpaqueInfo    = opaqueInfo
      ViewBuilder   = tb
      ViewName      = viewName
      VisibleFields = visible
      ToView        = None }

/// Pass B: populate the view's fields + constructor.  When a field's
/// CLR type matches a known projectable opaque's CLR type, the view
/// substitutes the corresponding view type — that's how nested
/// projection is derived from the AST.
let private populateProjectableView
        (symbols: SymbolTable)
        (lookup: TypeId -> System.Type option)
        (stubByOpaqueClr: Dictionary<System.Type, ProjectableStub>)
        (stub: ProjectableStub) : Records.RecordInfo =
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    let fields =
        stub.VisibleFields
        |> List.map (fun fd ->
            let lty =
                Resolver.resolveType symbols resolveCtx scratchDiags fd.Type
            let sourceClr = TypeMap.toClrTypeWith lookup lty
            // Recursively substitute the field's source type with the
            // matching `<Source>View` *unless* the field is annotated
            // `@projectionBoundary`, in which case the view exposes
            // the source opaque type as-is (breaking recursive
            // projection cycles).
            let viewClr : System.Type =
                if isProjectionBoundaryField fd then sourceClr
                else
                    match stubByOpaqueClr.TryGetValue sourceClr with
                    | true, target -> target.ViewBuilder :> System.Type
                    | _ -> sourceClr
            let fb =
                stub.ViewBuilder.DefineField(
                    fd.Name,
                    viewClr,
                    FieldAttributes.Public ||| FieldAttributes.InitOnly)
            { Records.RecordField.Name      = fd.Name
              Records.RecordField.Type      = viewClr
              Records.RecordField.LyricType = lty
              Records.RecordField.Field     = fb })
    let ctorParamTypes =
        fields |> List.map (fun f -> f.Type) |> List.toArray
    let ctor =
        stub.ViewBuilder.DefineConstructor(
            MethodAttributes.Public,
            CallingConventions.Standard,
            ctorParamTypes)
    let cil = ctor.GetILGenerator()
    cil.Emit(OpCodes.Ldarg_0)
    let objCtor = typeof<obj>.GetConstructor([||])
    match Option.ofObj objCtor with
    | Some c -> cil.Emit(OpCodes.Call, c)
    | None   -> failwith "object's no-arg ctor not found"
    fields
    |> List.iteri (fun i f ->
        cil.Emit(OpCodes.Ldarg_0)
        cil.Emit(OpCodes.Ldarg, i + 1)
        cil.Emit(OpCodes.Stfld, f.Field))
    cil.Emit(OpCodes.Ret)
    { Records.RecordInfo.Name     = stub.ViewName
      Records.RecordInfo.Type     = stub.ViewBuilder
      Records.RecordInfo.Fields   = fields
      Records.RecordInfo.Ctor     = ctor
      Records.RecordInfo.Generics = [] }

/// Pass C: attach `toView(): <Name>View` on the opaque.  Each visible
/// field is read off `this`; if the source field is a projectable
/// opaque, its `toView()` is invoked so the nested value projects
/// recursively.
let private populateToViewMethod
        (stubByOpaqueClr: Dictionary<System.Type, ProjectableStub>)
        (stub: ProjectableStub)
        (viewInfo: Records.RecordInfo) : MethodBuilder =
    let opaqueInfo = stub.OpaqueInfo
    let mb =
        opaqueInfo.Type.DefineMethod(
            "toView",
            MethodAttributes.Public ||| MethodAttributes.HideBySig,
            viewInfo.Type :> System.Type,
            [||])
    let il = mb.GetILGenerator()
    for vf in viewInfo.Fields do
        match opaqueInfo.Fields |> List.tryFind (fun f -> f.Name = vf.Name) with
        | Some sourceField ->
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldfld, sourceField.Field)
            // Recursive projection only when the *view* field's type
            // is the source opaque's view builder.  Fields annotated
            // `@projectionBoundary` had their view-side type left as
            // the source opaque, so the value carries through without
            // a `toView()` call.
            match stubByOpaqueClr.TryGetValue sourceField.Type with
            | true, nestedStub
                when vf.Type = (nestedStub.ViewBuilder :> System.Type) ->
                match nestedStub.ToView with
                | Some toViewMb ->
                    il.Emit(OpCodes.Callvirt, toViewMb)
                | None ->
                    failwithf "M2.2: nested toView for '%s' not yet defined when emitting '%s'"
                        nestedStub.ViewName opaqueInfo.Name
            | _ -> ()
        | None ->
            failwithf "M2.2: projectable view field '%s' not on opaque '%s'"
                vf.Name opaqueInfo.Name
    il.Emit(OpCodes.Newobj, viewInfo.Ctor)
    il.Emit(OpCodes.Ret)
    mb

/// Optional Pass D: synthesise `<Name>View::tryInto(): Result[<Name>, String]`.
///
/// Bootstrap-grade: invariants don't run yet, so the reverse
/// projection always succeeds.  The IL just copies each field from
/// the view back to the opaque ctor and wraps the result in `Ok`.
///
/// Returns `None` (skip generation) if any of:
///   - `Std.Core.Result` is not in the imported-union table.
///   - The projectable has any nested-projectable field whose view
///     type is one of the other stubs in this batch — handling those
///     needs a recursive `tryInto` variant that monad-binds through
///     each nested call.  Tracked as a follow-up.
let private populateTryIntoMethod
        (importedUnions: Records.ImportedUnionTable)
        (stubByOpaqueClr: Dictionary<System.Type, ProjectableStub>)
        (stub: ProjectableStub)
        (viewInfo: Records.RecordInfo) : MethodBuilder option =
    let viewBuilderList =
        stubByOpaqueClr.Values
        |> Seq.map (fun s -> s.ViewBuilder :> System.Type)
        |> Seq.toList
    let hasNestedProjectableField =
        viewInfo.Fields
        |> List.exists (fun f -> List.exists ((=) f.Type) viewBuilderList)
    if hasNestedProjectableField then None
    else
        match importedUnions.TryGetValue "Result" with
        | true, resultInfo ->
            let okCase =
                resultInfo.Cases |> List.tryFind (fun c -> c.Name = "Ok")
            match okCase with
            | Some okCase ->
                let opaqueClr = stub.OpaqueInfo.Type :> System.Type
                let typeArgs = [| opaqueClr; typeof<string> |]
                let resultClosed = resultInfo.Type.MakeGenericType typeArgs
                let okClosed = okCase.Type.MakeGenericType typeArgs
                let okCtor =
                    TypeBuilder.GetConstructor(okClosed, okCase.Ctor)
                let mb =
                    viewInfo.Type.DefineMethod(
                        "tryInto",
                        MethodAttributes.Public ||| MethodAttributes.HideBySig,
                        resultClosed,
                        [||])
                let il = mb.GetILGenerator()
                // Push every visible field from the view in opaque-
                // ctor parameter order, then call the opaque's ctor.
                let opaqueInfo = stub.OpaqueInfo
                for of_ in opaqueInfo.Fields do
                    match viewInfo.Fields |> List.tryFind (fun vf -> vf.Name = of_.Name) with
                    | Some vf ->
                        il.Emit(OpCodes.Ldarg_0)
                        il.Emit(OpCodes.Ldfld, vf.Field)
                    | None ->
                        // `@hidden` field excluded from the view —
                        // bootstrap can't reverse-project it, so push
                        // a default value of the opaque field's type.
                        if of_.Type.IsValueType then
                            let loc = il.DeclareLocal(of_.Type)
                            il.Emit(OpCodes.Ldloca, loc)
                            il.Emit(OpCodes.Initobj, of_.Type)
                            il.Emit(OpCodes.Ldloc, loc)
                        else
                            il.Emit(OpCodes.Ldnull)
                il.Emit(OpCodes.Newobj, opaqueInfo.Ctor)
                il.Emit(OpCodes.Newobj, okCtor)
                il.Emit(OpCodes.Ret)
                Some mb
            | None -> None
        | _ -> None

/// Lower a Lyric param's CLR shape, accounting for `out` / `inout`:
/// both lower to `T&` (managed pointer); `out` additionally gets an
/// `[Out]` ParameterAttributes flag in metadata so .NET-side callers
/// see it as a C#-style `out` parameter.
let internal paramClrType
        (lookup: TypeId -> System.Type option)
        (genericSubst: Map<string, System.Type>)
        (p: ResolvedParam) : System.Type =
    let bare = TypeMap.toClrTypeWithGenerics lookup genericSubst p.Type
    match p.Mode with
    | PMOut | PMInout -> bare.MakeByRefType()
    | PMIn            -> bare

let internal paramAttrs (p: ResolvedParam) : ParameterAttributes =
    match p.Mode with
    | PMOut   -> ParameterAttributes.Out
    | PMInout -> ParameterAttributes.None
    | PMIn    -> ParameterAttributes.None

/// Define a static method header on `programTy` matching the resolved
/// signature. Body is filled in by `emitFunctionBody` afterwards.
let private defineMethodHeader
        (programTy: TypeBuilder)
        (lookup: TypeId -> System.Type option)
        (fn: FunctionDecl)
        (sg: ResolvedSignature) : MethodBuilder =
    // `main` is the program entry point.  The host `Main` wrapper is
    // public; the Lyric `main` it calls must also stay reachable from
    // an external runtime when the assembly is consumed via
    // `dotnet exec`.  Force `Public` regardless of declared
    // visibility so the entry-point lookup works.
    let methodVis =
        if fn.Name = "main" then MethodAttributes.Public
        else methodAttrsForVis fn.Visibility
    if sg.Generics.IsEmpty then
        // Non-generic fast path — single-call signature.
        let paramTypes =
            sg.Params
            |> List.map (paramClrType lookup Map.empty)
            |> List.toArray
        let bareReturn = TypeMap.toClrReturnTypeWith lookup sg.Return
        let returnType =
            if sg.IsAsync then toTaskType bareReturn else bareReturn
        let mb =
            programTy.DefineMethod(
                fn.Name,
                methodVis ||| MethodAttributes.Static,
                returnType,
                paramTypes)
        sg.Params
        |> List.iteri (fun i p ->
            mb.DefineParameter(i + 1, paramAttrs p, p.Name) |> ignore)
        mb
    else
        // Generic method — reify type parameters as proper .NET generic
        // method parameters.  The Reflection.Emit pattern requires three
        // calls: DefineMethod (no signature), DefineGenericParameters,
        // then SetParameters / SetReturnType once the GTPBs exist.
        let mb =
            programTy.DefineMethod(
                fn.Name,
                methodVis ||| MethodAttributes.Static)
        let typeParams =
            mb.DefineGenericParameters(sg.Generics |> List.toArray)
        let genericSubst =
            sg.Generics
            |> List.mapi (fun i name -> name, typeParams.[i] :> System.Type)
            |> Map.ofList
        let paramTypes =
            sg.Params
            |> List.map (paramClrType lookup genericSubst)
            |> List.toArray
        let bareReturn =
            TypeMap.toClrReturnTypeWithGenerics lookup genericSubst sg.Return
        let returnType =
            if sg.IsAsync then toTaskType bareReturn else bareReturn
        mb.SetParameters paramTypes
        mb.SetReturnType returnType
        sg.Params
        |> List.iteri (fun i p ->
            mb.DefineParameter(i + 1, paramAttrs p, p.Name) |> ignore)
        mb

/// Emit a function body. Handles three shapes: an explicit block, an
/// expression-bodied function, and the `= { ... }` lambda quirk
/// where the parser wraps a block inside a zero-arg ELambda.
///
/// For non-Unit functions whose body is a block, the trailing SExpr
/// (if any) is treated as the implicit return value — matching
/// Lyric's "last expression is the value" rule for block bodies.
/// G9 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-110):
/// runtime contract failures used to throw the F#-side
/// `Lyric.Stdlib.LyricAssertionException` (a thin
/// `System.Exception` subclass).  Throwing the BCL `System.Exception`
/// directly keeps the user-visible catch shape identical (`catch Bug
/// as b { … }` already resolves `Bug` to `System.Exception`) and
/// retires the F# wrapper class.
let private contractExceptionCtor : Lazy<ConstructorInfo> =
    lazy (
        let exTy = typeof<System.Exception>
        match Option.ofObj (exTy.GetConstructor([| typeof<string> |])) with
        | Some c -> c
        | None   -> failwith "System.Exception(String) ctor not found")

/// Emit a runtime contract check: evaluate `cond`; on false, throw
/// `System.Exception(message)`.
let private emitContractCheck
        (ctx: Codegen.FunctionCtx)
        (cond: Expr)
        (label: string) : unit =
    let il = ctx.IL
    let _ = Codegen.emitExpr ctx cond
    let okLbl = il.DefineLabel()
    il.Emit(OpCodes.Brtrue, okLbl)
    il.Emit(OpCodes.Ldstr, label)
    il.Emit(OpCodes.Newobj, contractExceptionCtor.Value)
    il.Emit(OpCodes.Throw)
    il.MarkLabel(okLbl)

// ---------------------------------------------------------------------------
// FFI: `@externTarget("Fully.Qualified.Member")` resolution.
//
// `findClrType` walks every loaded assembly looking for a type whose
// `FullName` matches; `resolveExternTarget` then matches a method
// (preferred) or a property accessor.  The Lyric function's
// parameter arity is used as the disambiguator across BCL overloads.
// ---------------------------------------------------------------------------

let private findClrType (qualifiedName: string) : System.Type option =
    // Force-touch a few well-known assemblies so they're loaded into
    // the AppDomain before we walk it.  `Lyric.Stdlib` no longer
    // hosts any types worth pinning (every shim retired into
    // `_kernel/*` Lyric code), but the BCL assemblies referenced by
    // common stdlib modules (`Std.Json`, `Std.Regex`, `Std.Time`,
    // `Std.Http`) aren't auto-loaded on demand and need a touch.
    // Pin `JvmByteHost` to force-load `Lyric.Jvm.Hosts` — the JVM emitter's
    // `compiler/lyric/jvm/_kernel/kernel.l` `@externTarget`s these.
    let _ = typeof<Lyric.Jvm.Hosts.JvmByteHost>
    let _ = typeof<System.Text.Json.JsonDocument>
    let _ = typeof<System.Text.RegularExpressions.Regex>
    let _ = typeof<System.Net.HttpListener>
    let direct = System.Type.GetType qualifiedName
    match Option.ofObj direct with
    | Some t -> Some t
    | None ->
        System.AppDomain.CurrentDomain.GetAssemblies()
        |> Array.tryPick (fun asm ->
            try
                Option.ofObj (asm.GetType qualifiedName)
            with _ -> None)

/// Phase 5 §M5.1 stage 2d.v: pre-load the user's NuGet DLLs into
/// the current AppDomain so `findClrType` finds extern types declared
/// against those packages.  Failures (assembly already loaded, file
/// missing, bad image) are non-fatal — the worst case is that a
/// later `extern type` resolution fails with the existing FFI error,
/// which is the right diagnostic anyway.
let private preloadNugetAssemblies (paths: string list) : unit =
    let loaded =
        System.AppDomain.CurrentDomain.GetAssemblies()
        |> Array.choose (fun a ->
            try
                let loc = a.Location
                if System.String.IsNullOrEmpty loc then None
                else Some loc
            with _ -> None)
        |> Set.ofArray
    for p in paths do
        if System.IO.File.Exists p && not (loaded.Contains p) then
            try System.Reflection.Assembly.LoadFrom p |> ignore
            with _ -> ()

/// Pick the BCL method (or property accessor) referenced by `target`.
/// `target` is `<Fully.Qualified.Type>.<Member>`.  `paramArity` is
/// the Lyric function's parameter count — used to disambiguate
/// overloads; for an instance method the receiver counts as the
/// first parameter.
/// Match a candidate method's parameter types against the Lyric
/// function's param CLR types.  Exact equality is required — no
/// implicit boxing or reference-conversion is performed at the FFI
/// boundary.  Used to disambiguate BCL overloads (e.g. the four
/// `op_Subtraction` methods on `System.DateTime`).
let private paramsExactMatch
        (m: MethodInfo) (expected: System.Type array) : bool =
    let p = m.GetParameters()
    if p.Length <> expected.Length then false
    else
        let mutable ok = true
        for i in 0 .. p.Length - 1 do
            if ok && p.[i].ParameterType <> expected.[i] then
                ok <- false
        ok

/// Result of `@externTarget` lookup.  Constructors and static fields
/// live on different reflection APIs (`ConstructorInfo`, `FieldInfo`)
/// from regular methods, so we can't fold them into a single
/// `MethodInfo`-shaped return.
type private ExternBclMember =
    | EBMMethod of MethodInfo
    | EBMCtor   of ConstructorInfo
    | EBMField  of FieldInfo

let private resolveExternTarget
        (target: string)
        (paramTypes: System.Type array) : ExternBclMember option =
    // `Type.Method` — the dot before the last segment marks the type/
    // member boundary.  `Type..ctor` (two consecutive dots) names a
    // constructor: split before `..ctor` so the member name is `.ctor`.
    let ctorMarker = "..ctor"
    if target.EndsWith ctorMarker then
        let typeName = target.Substring(0, target.Length - ctorMarker.Length)
        match findClrType typeName with
        | None -> None
        | Some t ->
            // Lyric's "newXyz" extern is conventionally `func() : Xyz`,
            // so the receiver isn't a Lyric param and we use raw paramArity.
            let arity = paramTypes.Length
            let ctors = t.GetConstructors()
            let exact =
                ctors |> Array.tryFind (fun c ->
                    let p = c.GetParameters()
                    p.Length = arity
                    && Array.forall2 (fun (pi: ParameterInfo) ex -> pi.ParameterType = ex)
                                     p paramTypes)
            match exact with
            | Some c -> Some (EBMCtor c)
            | None ->
                ctors
                |> Array.tryFind (fun c -> c.GetParameters().Length = arity)
                |> Option.map EBMCtor
    else
    let lastDot = target.LastIndexOf '.'
    if lastDot <= 0 then None
    else
    let typeName = target.Substring(0, lastDot)
    let memberName = target.Substring(lastDot + 1)
    match findClrType typeName with
    | None -> None
    | Some t ->
        let methods = t.GetMethods()
        let arity = paramTypes.Length
        // Try, in order:
        //  (a) static method exact-typed against every Lyric param
        //  (b) static method matching by arity only (fallback when
        //      a Lyric primitive doesn't perfectly equal the BCL
        //      param type — should be rare with extern types)
        //  (c) instance method exact-typed (receiver = first Lyric
        //      param, remaining Lyric params = method args)
        //  (d) instance method by arity
        //  (e) property getter `get_<MemberName>`
        let isStatic = (fun (m: MethodInfo) -> m.IsStatic)
        let isInstance = (fun (m: MethodInfo) -> not m.IsStatic)
        let candidates name pred =
            methods
            |> Array.filter (fun m -> m.Name = name && pred m)
        // Order matters: an exact instance-method match must beat the
        // arity-only static fallback.  Otherwise a Lyric extern like
        // `func isMatch(r: in Regex, input: in String): Bool` (arity
        // 2, types `[Regex, string]`) would resolve to the static
        // `Regex.IsMatch(string, string)` because both are arity 2,
        // and pass `r` as a string — silently returning the wrong
        // boolean.
        let staticTyped =
            candidates memberName isStatic
            |> Array.tryFind (fun m -> paramsExactMatch m paramTypes)
        let instanceTyped () =
            if arity >= 1 then
                candidates memberName isInstance
                |> Array.tryFind (fun m ->
                    paramsExactMatch m (Array.skip 1 paramTypes))
            else None
        let staticArity () =
            candidates memberName isStatic
            |> Array.tryFind (fun m -> m.GetParameters().Length = arity)
        let instanceArity () =
            if arity >= 1 then
                candidates memberName isInstance
                |> Array.tryFind (fun m -> m.GetParameters().Length = arity - 1)
            else None
        // BCL methods often surface optional trailing params via
        // `HasDefaultValue`; e.g. `JsonDocument.Parse(string, opts =
        // default)` is reachable as 1-arg from C#.  Match those when
        // an exact-arity hit is missing.
        //
        // Two passes per candidate: first prefer methods whose leading
        // parameters exactly match the Lyric `paramTypes`, falling
        // back to a name+arity match if no exact-typed match exists.
        // The exact-typed pass is what disambiguates between
        // `JsonDocument.Parse(string, opts=default)` and
        // `JsonDocument.Parse(ReadOnlyMemory<char>, opts=default)`
        // when the Lyric extern declares `String` only.
        let leadingExact (m: MethodInfo) (skipReceiver: int) (lyricArgs: System.Type array) =
            let ps = m.GetParameters()
            let mutable ok = ps.Length >= lyricArgs.Length + skipReceiver
            let mutable i = 0
            while ok && i < lyricArgs.Length do
                if ps.[i].ParameterType <> lyricArgs.[i] then ok <- false
                i <- i + 1
            ok
        let trailingHasDefaults (m: MethodInfo) (lyricSupplied: int) =
            let ps = m.GetParameters()
            ps.Length > lyricSupplied
            && ps |> Array.skip lyricSupplied
                  |> Array.forall (fun p -> p.HasDefaultValue)
        let staticArityWithDefaults () =
            let cands = candidates memberName isStatic
            let typed =
                cands
                |> Array.tryFind (fun m ->
                    trailingHasDefaults m arity
                    && leadingExact m 0 paramTypes)
            match typed with
            | Some m -> Some m
            | None ->
                cands
                |> Array.tryFind (fun m -> trailingHasDefaults m arity)
        let instanceArityWithDefaults () =
            if arity >= 1 then
                let cands = candidates memberName isInstance
                let recvSupplied = arity - 1
                let typed =
                    cands
                    |> Array.tryFind (fun m ->
                        trailingHasDefaults m recvSupplied
                        && leadingExact m 0 (Array.skip 1 paramTypes))
                match typed with
                | Some m -> Some m
                | None ->
                    cands
                    |> Array.tryFind (fun m -> trailingHasDefaults m recvSupplied)
            else None
        let propGetter () =
            let prop = t.GetProperty memberName
            match Option.ofObj prop with
            | Some p when p.CanRead -> Option.ofObj (p.GetGetMethod())
            | _ -> None
        let mi =
            match staticTyped with
            | Some m -> Some m
            | None ->
                match instanceTyped () with
                | Some m -> Some m
                | None ->
                    match staticArity () with
                    | Some m -> Some m
                    | None ->
                        match instanceArity () with
                        | Some m -> Some m
                        | None ->
                            match staticArityWithDefaults () with
                            | Some m -> Some m
                            | None ->
                                match instanceArityWithDefaults () with
                                | Some m -> Some m
                                | None   -> propGetter ()
        match mi with
        | Some m -> Some (EBMMethod m)
        | None ->
            // Static field fallback: `System.TimeSpan.Zero`,
            // `System.String.Empty` etc.  Used when neither a method
            // nor a property accessor with the given name exists.
            let f =
                t.GetField(memberName,
                    System.Reflection.BindingFlags.Public
                    ||| System.Reflection.BindingFlags.Static)
            match Option.ofObj f with
            | Some f -> Some (EBMField f)
            | None   -> None

let private emitExternCall
        (il: ILGenerator)
        (fn: FunctionDecl)
        (paramList: (string * System.Type) list)
        (returnTy: System.Type)
        (genericGtpbs: System.Type array)
        (resultLocal: LocalBuilder option)
        (exitLabel: Label)
        (target: string) : unit =
    let paramTypes =
        paramList |> List.map snd |> List.toArray
    let resolved =
        match resolveExternTarget target paramTypes with
        | Some m -> m
        | None ->
            failwithf "FFI: cannot resolve `@externTarget(\"%s\")` for `%s` (arity %d)"
                target fn.Name paramTypes.Length
    // For an extern targeting a method/ctor on a generic type, the
    // resolver returned the OPEN definition (e.g. `List<T>::Add`).  At
    // emission time we need to close the declaring type with the actual
    // type args so the IL references `List<int>::Add` (or whatever the
    // method's GTPB substitution produces).  The closed type lives in:
    //   • paramTypes.[0] for instance members (the receiver param type
    //     was already substituted by `TypeMap.toClrTypeWithGenerics`),
    //   • returnTy for constructors (`new List<T>()` returns `List<T>`),
    //   • paramTypes.[0] or returnTy for static methods on a generic
    //     type — try receiver first, fall back to return.
    let openClosedClr (openDeclaring: System.Type) : System.Type =
        let pickFromParams () =
            paramTypes
            |> Array.tryFind (fun pt ->
                pt.IsGenericType
                && not pt.IsGenericTypeDefinition
                && pt.GetGenericTypeDefinition() = openDeclaring)
        let pickFromReturn () =
            if returnTy.IsGenericType
               && not returnTy.IsGenericTypeDefinition
               && returnTy.GetGenericTypeDefinition() = openDeclaring
            then Some returnTy else None
        // Fallback: close the open declaring type with the user
        // function's own GTPBs in declaration order.  Used for static
        // helpers like `Lyric.Stdlib.MapHelpers`2.Has` whose declaring
        // type doesn't appear in any Lyric param/return — the user-side
        // function's `[K, V]` becomes the helper's `<K, V>`.
        let pickFromGtpbs () =
            let needed = openDeclaring.GetGenericArguments().Length
            if genericGtpbs.Length = needed && needed > 0 then
                try Some (openDeclaring.MakeGenericType genericGtpbs)
                with _ -> None
            else None
        match pickFromParams () with
        | Some t -> t
        | None ->
            match pickFromReturn () with
            | Some t -> t
            | None ->
                match pickFromGtpbs () with
                | Some t -> t
                | None ->
                    failwithf
                        "FFI: cannot infer closed generic type for `@externTarget(\"%s\")` on `%s` — receiver / return type does not mention `%s`"
                        target fn.Name openDeclaring.FullName
    // `TypeBuilder.GetMethod` / `TypeBuilder.GetConstructor` are the
    // Reflection.Emit-safe way to substitute when the closed type
    // contains GenericTypeParameterBuilder instances (the typical
    // path for generic Lyric functions like `newList[T]`).  But the
    // BCL static throws `'type' must be or must contain a TypeBuilder
    // as a generic argument` when the closed type is fully resolved
    // (no TypeBuilders), e.g. `AsyncLocal<CancellationToken>` from a
    // non-generic Lyric function.  In that case we look the member up
    // directly on the closed Type via regular reflection.
    let isOpenGenericDeclaring (declaring: System.Type | null) : bool =
        match Option.ofObj declaring with
        | Some d -> d.IsGenericTypeDefinition
        | None   -> false
    let unwrapDeclaring (declaring: System.Type | null) : System.Type =
        match Option.ofObj declaring with
        | Some d -> d
        | None   -> failwithf "FFI: declaring type missing on extern target `%s`" target
    let rec containsBuilder (t: System.Type) : bool =
        if t :? System.Reflection.Emit.TypeBuilder
           || t :? System.Reflection.Emit.GenericTypeParameterBuilder then true
        elif t.IsGenericType then
            t.GetGenericArguments() |> Array.exists containsBuilder
        elif t.HasElementType then
            match Option.ofObj (t.GetElementType()) with
            | Some elem -> containsBuilder elem
            | None      -> false
        else false
    let resolveMethodOnClosed
            (closedTy: System.Type) (openMethod: MethodInfo) : MethodInfo =
        let openParams = openMethod.GetParameters()
        let flags =
            BindingFlags.Public ||| BindingFlags.NonPublic |||
            (if openMethod.IsStatic then BindingFlags.Static else BindingFlags.Instance)
        let cand =
            closedTy.GetMethods(flags)
            |> Array.tryFind (fun m ->
                m.Name = openMethod.Name
                && m.GetParameters().Length = openParams.Length)
        match cand with
        | Some m -> m
        | None   ->
            failwithf
                "FFI: cannot find `%s` (arity %d) on closed type `%s`"
                openMethod.Name openParams.Length closedTy.FullName
    let resolveCtorOnClosed
            (closedTy: System.Type) (openCtor: ConstructorInfo) : ConstructorInfo =
        let openParams = openCtor.GetParameters()
        let cand =
            closedTy.GetConstructors(
                BindingFlags.Public ||| BindingFlags.NonPublic ||| BindingFlags.Instance)
            |> Array.tryFind (fun c -> c.GetParameters().Length = openParams.Length)
        match cand with
        | Some c -> c
        | None   ->
            failwithf
                "FFI: cannot find ctor (arity %d) on closed type `%s`"
                openParams.Length closedTy.FullName
    let closedResolved =
        match resolved with
        | EBMMethod m when isOpenGenericDeclaring m.DeclaringType ->
            let closedTy = openClosedClr (unwrapDeclaring m.DeclaringType)
            let closedMethod =
                if containsBuilder closedTy then
                    System.Reflection.Emit.TypeBuilder.GetMethod(closedTy, m)
                else
                    resolveMethodOnClosed closedTy m
            EBMMethod closedMethod
        | EBMCtor c when isOpenGenericDeclaring c.DeclaringType ->
            let closedTy = openClosedClr (unwrapDeclaring c.DeclaringType)
            let closedCtor =
                if containsBuilder closedTy then
                    System.Reflection.Emit.TypeBuilder.GetConstructor(closedTy, c)
                else
                    resolveCtorOnClosed closedTy c
            EBMCtor closedCtor
        | other -> other
    // Static-field externs don't take any params — skip the arg
    // push so we don't blow the stack discipline.
    let isFieldExtern =
        match closedResolved with
        | EBMField _ -> true
        | _          -> false
    if not isFieldExtern then
        // For instance methods on value-type receivers, the CLR needs
        // a managed pointer (`T&`) for the `this` slot.  Use `Ldarga`
        // for arg 0 in that case (later `call` instead of `callvirt`
        // is selected below) — but only when Lyric's arg 0 is the
        // value itself (`in T`); if Lyric declared it `inout T` the
        // arg slot already holds the managed pointer, so a plain
        // `Ldarg` is what loads the receiver pointer.
        let isValueRecv =
            match closedResolved with
            | EBMMethod m when not m.IsStatic ->
                let dt = m.DeclaringType
                match Option.ofObj dt with
                | Some d -> d.IsValueType
                | None   -> false
            | _ -> false
        let arg0AlreadyByRef =
            match paramList with
            | (_, t) :: _ -> t.IsByRef
            | _           -> false
        paramList
        |> List.iteri (fun i _ ->
            if i = 0 && isValueRecv && not arg0AlreadyByRef then
                il.Emit(OpCodes.Ldarga, i)
            else il.Emit(OpCodes.Ldarg, i))
    // Push default values for any trailing BCL params that the user
    // didn't supply.  Used when the resolver matched a method whose
    // declared arity exceeds Lyric's call-site arity but the extras
    // have `HasDefaultValue` (e.g. `JsonDocument.Parse(string, opts =
    // default)`).
    let emitDefault (pt: System.Type) (rawDefault: obj | null) : unit =
        match Option.ofObj rawDefault with
        | None when pt.IsValueType ->
            let tmp = il.DeclareLocal(pt)
            il.Emit(OpCodes.Ldloca, tmp)
            il.Emit(OpCodes.Initobj, pt)
            il.Emit(OpCodes.Ldloc, tmp)
        | None ->
            il.Emit(OpCodes.Ldnull)
        | Some _ when pt = typeof<bool> ->
            let v : bool = unbox rawDefault
            il.Emit(OpCodes.Ldc_I4, if v then 1 else 0)
        | Some _ when pt.IsEnum || pt = typeof<int> ->
            il.Emit(OpCodes.Ldc_I4, unbox<int> rawDefault)
        | Some _ when pt = typeof<string> ->
            il.Emit(OpCodes.Ldstr, unbox<string> rawDefault)
        | Some _ ->
            // Unknown literal default — fall back to default(T).
            if pt.IsValueType then
                let tmp = il.DeclareLocal(pt)
                il.Emit(OpCodes.Ldloca, tmp)
                il.Emit(OpCodes.Initobj, pt)
                il.Emit(OpCodes.Ldloc, tmp)
            else il.Emit(OpCodes.Ldnull)
    let pushTrailingDefaults (declaredArity: int) (params': ParameterInfo array) (suppliedSoFar: int) =
        if declaredArity > suppliedSoFar then
            for i in suppliedSoFar .. declaredArity - 1 do
                let p = params'.[i]
                if not p.HasDefaultValue then
                    failwithf "FFI: parameter '%s' on `@externTarget(\"%s\")` has no default value" p.Name target
                emitDefault p.ParameterType p.DefaultValue
    let lyricArity = paramList.Length
    match closedResolved with
    | EBMMethod m ->
        let declared = m.GetParameters()
        let supplied = if m.IsStatic then lyricArity else lyricArity - 1
        pushTrailingDefaults declared.Length declared supplied
    | EBMCtor c ->
        let declared = c.GetParameters()
        pushTrailingDefaults declared.Length declared lyricArity
    | EBMField _ -> ()
    // Constructors get `newobj`; static methods + property getters use
    // `call`; non-static instance methods use `callvirt`; static fields
    // emit `Ldsfld`.
    let pushedTy =
        match closedResolved with
        | EBMCtor c ->
            il.Emit(OpCodes.Newobj, c)
            c.DeclaringType
        | EBMMethod m ->
            // If the resolved method is still an open generic (i.e., a
            // generic method on a non-generic declaring type, like
            // `SetHost.SetToArray<T>`), infer type arguments from the
            // resolved parameter CLR types and close it now.
            let m =
                if not m.IsGenericMethodDefinition then m
                else
                    let gtpbs   = m.GetGenericArguments()
                    let mParams = m.GetParameters()
                    let bindings = Array.create gtpbs.Length typeof<obj>
                    let rec matchTy (methTy: System.Type) (actualTy: System.Type) =
                        if methTy.IsGenericParameter then
                            match Array.tryFindIndex
                                      (fun (tp: System.Type) -> tp.Name = methTy.Name)
                                      gtpbs with
                            | Some pos -> bindings.[pos] <- actualTy
                            | None     -> ()
                        elif methTy.IsGenericType && actualTy.IsGenericType then
                            try
                                if methTy.GetGenericTypeDefinition()
                                   = actualTy.GetGenericTypeDefinition() then
                                    Array.iter2 matchTy
                                        (methTy.GetGenericArguments())
                                        (actualTy.GetGenericArguments())
                            with _ -> ()
                        elif methTy.IsArray && actualTy.IsArray then
                            match Option.ofObj (methTy.GetElementType()),
                                  Option.ofObj (actualTy.GetElementType()) with
                            | Some mt, Some at -> matchTy mt at
                            | _                -> ()
                    for i in 0 .. mParams.Length - 1 do
                        if i < paramTypes.Length then
                            matchTy (mParams.[i].ParameterType) paramTypes.[i]
                    m.MakeGenericMethod bindings
            if m.IsStatic then il.Emit(OpCodes.Call, m)
            else
                // Value-type instance methods — `Call` against a
                // managed pointer (`Ldarga` was emitted above).
                // Reference-type instance methods — `Callvirt`.
                let recvIsValueType =
                    match Option.ofObj m.DeclaringType with
                    | Some d -> d.IsValueType
                    | None   -> false
                if recvIsValueType then il.Emit(OpCodes.Call, m)
                else il.Emit(OpCodes.Callvirt, m)
            m.ReturnType
        | EBMField f ->
            // .NET 10's `PersistedAssemblyBuilder` calls
            // `FieldInfo.GetModifiedFieldType()` while emitting an
            // `Ldsfld` token, which throws `NotSupportedException` on
            // BCL-loaded `RuntimeFieldInfo` instances.  For literal
            // (`const`) fields — `Math.PI`, `Math.E`, `Math.Tau`,
            // primitives' min/max — there's no reason to emit a
            // field reference at all: read the constant value at
            // codegen time and bake it in via the appropriate `Ldc.*`.
            if f.IsLiteral then
                let raw = f.GetRawConstantValue()
                match raw with
                | :? double as v -> il.Emit(OpCodes.Ldc_R8, v)
                | :? single as v -> il.Emit(OpCodes.Ldc_R4, v)
                | :? int64  as v -> il.Emit(OpCodes.Ldc_I8, v)
                | :? int32  as v -> il.Emit(OpCodes.Ldc_I4, v)
                | :? int16  as v -> il.Emit(OpCodes.Ldc_I4, int v)
                | :? sbyte  as v -> il.Emit(OpCodes.Ldc_I4, int v)
                | :? uint64 as v -> il.Emit(OpCodes.Ldc_I8, int64 v)
                | :? uint32 as v -> il.Emit(OpCodes.Ldc_I4, int v)
                | :? uint16 as v -> il.Emit(OpCodes.Ldc_I4, int v)
                | :? byte   as v -> il.Emit(OpCodes.Ldc_I4, int v)
                | :? bool   as v -> il.Emit(OpCodes.Ldc_I4, if v then 1 else 0)
                | :? string as v -> il.Emit(OpCodes.Ldstr, v)
                | _ ->
                    // Unsupported literal shape — fall back to the
                    // direct field reference and let the runtime
                    // surface the exception with full context.
                    il.Emit(OpCodes.Ldsfld, f)
            else
                il.Emit(OpCodes.Ldsfld, f)
            f.FieldType
    // Stash the result + branch to exit, mirroring routeReturn's
    // shape but specialised so we don't need to thread that helper
    // through.
    if pushedTy = typeof<System.Void> then
        match resultLocal with
        | Some _ ->
            // Lyric declared a non-Unit return but the CLR method
            // returns void.  Push default(T) so the function body
            // produces *something* compatible with the declared
            // return type — surfaces a typing mismatch as a runtime
            // value rather than malformed IL.
            ()
        | None -> ()
    else
        match resultLocal with
        | Some loc -> il.Emit(OpCodes.Stloc, loc)
        | None     -> il.Emit(OpCodes.Pop)
    il.Emit(OpCodes.Br, exitLabel)

/// Phase B exit context.  When set, `emitFunctionBody` skips
/// the M1.4 `Task.FromResult` / Phase A `SetResult` epilogues and
/// instead routes the body's exit through `Leave NormalDone` so
/// the surrounding structural code (state dispatch, try/catch,
/// SetResult, ret) can take over.  The body's `EAwait` handlers
/// consume `SmAwaitInfo` to emit the suspend/resume protocol.
type private PhaseBExit =
    { NormalDone:  Label
      AwaitInfo:   AsyncStateMachine.SmAwaitInfo
      /// Pre-allocated IL locals for promoted locals; consumed by
      /// `defineLocal` (via `ctx.PreAllocatedLocals`).
      PreLocals:   Dictionary<string, LocalBuilder>
      /// Pre-allocated result local for non-void async funcs.  The
      /// body's exit-label code stores into this slot before
      /// `Leave NormalDone`; the surrounding `SetResult` block
      /// loads from it.  `None` for Unit-returning funcs.
      ResultLocal: LocalBuilder option }

let private emitFunctionBody
        (mb: MethodBuilder)
        (smInfo: AsyncStateMachine.StateMachineInfo option)
        (phaseBExit: PhaseBExit option)
        (fn: FunctionDecl)
        (sg: ResolvedSignature)
        (lookup: TypeId -> System.Type option)
        (funcs: Dictionary<string, MethodBuilder>)
        (funcSigs: Dictionary<string, ResolvedSignature>)
        (records: Records.RecordTable)
        (enums: Records.EnumTable)
        (enumCases: Records.EnumCaseLookup)
        (unions: Records.UnionTable)
        (unionCases: Records.UnionCaseLookup)
        (interfaces: Records.InterfaceTable)
        (impls: Records.ImplsTable)
        (distinctTypes: Records.DistinctTypeTable)
        (protectedTypes: Records.ProtectedTypeTable)
        (projectables: Records.ProjectableTable)
        (importedRecords: Records.ImportedRecordTable)
        (importedUnions: Records.ImportedUnionTable)
        (importedUnionCases: Records.ImportedUnionCaseLookup)
        (importedFuncs: Records.ImportedFuncTable)
        (importedDistinctTypes: Records.ImportedDistinctTypeTable)
        (externTypeNames: Dictionary<string, System.Type>)
        (isInstance: bool)
        (selfType: System.Type option)
        (programType: TypeBuilder)
        (symbols: SymbolTable)
        (consts: Dictionary<string, int64>)
        (asyncLocals: Dictionary<string, System.Reflection.FieldInfo>)
        (diags: ResizeArray<Diagnostic>) : unit =
    let il = mb.GetILGenerator()
    // For an async function the *body* still computes a value of
    // the bare return type; the wrapping into `Task<T>` only kicks
    // in at the exit point. Carrying both keeps the body codegen
    // ignorant of the lowering strategy.
    //
    // Recover the per-method generic substitution from the MethodBuilder
    // so `TyVar T` references in param/return positions resolve to the
    // GenericTypeParameterBuilder we stamped down in `defineMethodHeader`.
    //
    // SM mode: `mb` is `sm.MoveNext` (a non-generic instance method on
    // the SM type), so `mb.GetGenericArguments()` is `[||]`.  For generic
    // async, the user-method generics map to the SM's own GTPBs (the
    // ones the JIT closes at runtime against whatever the kickoff site
    // passed to `MakeGenericType`).
    let genericSubst : Map<string, System.Type> =
        if sg.Generics.IsEmpty then Map.empty
        else
            let gtpbs : System.Type[] =
                match smInfo with
                | Some sm when sm.GenericParams.Length > 0 ->
                    sm.GenericParams |> Array.map (fun g -> g :> System.Type)
                | _ ->
                    let methodGtpbs = mb.GetGenericArguments()
                    if methodGtpbs.Length = sg.Generics.Length then
                        methodGtpbs
                    else
                        // Methods on a generic class that aren't
                        // themselves generic (e.g. protected-type
                        // entries / funcs synthesised in
                        // `defineProtectedTypeOnto`) carry the class
                        // generics in `sg.Generics`.  Recover the
                        // GTPBs from the enclosing class via
                        // `selfType.GetGenericArguments()`.
                        //
                        // Impl-block + method-level generics: sg.Generics
                        // is ordered [implNames...; methodNames...].  The
                        // combined array is class GTPBs ++ method GTPBs.
                        match selfType with
                        | Some st when st.IsGenericType
                                       && st.GetGenericArguments().Length
                                          = sg.Generics.Length ->
                            st.GetGenericArguments()
                        | Some st when st.IsGenericType ->
                            let clsGtpbs = st.GetGenericArguments()
                            if clsGtpbs.Length + methodGtpbs.Length
                               = sg.Generics.Length then
                                Array.append clsGtpbs methodGtpbs
                            else methodGtpbs
                        | _ -> methodGtpbs
            sg.Generics
            |> List.mapi (fun i name -> name, gtpbs.[i])
            |> Map.ofList
    let bareReturnTy =
        TypeMap.toClrReturnTypeWithGenerics lookup genericSubst sg.Return
    let methodReturnTy =
        if sg.IsAsync && smInfo.IsNone then toTaskType bareReturnTy else bareReturnTy
    let returnTy = bareReturnTy
    // In SM mode `MoveNext` has no params (only `this`); the user
    // params live on the SM as fields and resolve via SmFields below.
    let paramList =
        match smInfo with
        | Some _ -> []
        | None ->
            sg.Params
            |> List.map (fun p ->
                // Stored type matches the CLR slot (byref for out/inout).
                // EPath access auto-dereferences via `loadParamValue`; call
                // sites passing to byref params take addresses directly.
                p.Name, paramClrType lookup genericSubst p)
    // Type-resolution closure used by lambda synthesis + val/var
    // ascription inside the body.  Seeded with the function's
    // generic-parameter names so `var v: V = ...` resolves V to the
    // method's GTPB instead of falling through to TyError / obj.
    let resolveCtxInner = GenericContext()
    if not sg.Generics.IsEmpty then
        resolveCtxInner.Push sg.Generics
    let scratchDiagsInner = ResizeArray<Diagnostic>()
    let resolveTypeForCtx (te: TypeExpr) : System.Type =
        let lty = Resolver.resolveType symbols resolveCtxInner scratchDiagsInner te
        TypeMap.toClrTypeWithGenerics lookup genericSubst lty
    // In SM mode, MoveNext is an instance method whose `this` is the
    // SM instance; selfType becomes the SM type, isInstance is true.
    let effectiveIsInstance, effectiveSelfType =
        match smInfo with
        | Some sm -> true, Some (sm.Type :> System.Type)
        | None    -> isInstance, selfType
    let ctx =
        Codegen.FunctionCtx.make
            il returnTy paramList
            funcs funcSigs records enums enumCases unions unionCases
            interfaces impls distinctTypes protectedTypes projectables
            importedRecords importedUnions importedUnionCases
            importedFuncs importedDistinctTypes externTypeNames
            effectiveIsInstance effectiveSelfType programType resolveTypeForCtx lookup consts asyncLocals diags
    // Populate SmFields from the SM's parameter fields so EPath
    // reads / SAssign writes route through `Ldarg.0; Ldfld <field>`
    // instead of the regular `Ldarg N` parameter slot path.
    match smInfo with
    | Some sm ->
        for pf in sm.ParamFields do
            ctx.SmFields.[pf.Name] <- (pf.Field :> System.Reflection.FieldInfo)
    | None -> ()
    // Phase B: thread the suspend/resume context + pre-allocated
    // local shadow IL slots so the body's `EAwait` handlers and
    // `defineLocal` calls hit the right code paths.
    match phaseBExit with
    | Some pb ->
        ctx.SmAwaitInfo <- Some pb.AwaitInfo
        for KeyValue(name, lb) in pb.PreLocals do
            ctx.PreAllocatedLocals.[name] <- lb
    | None -> ()
    ignore methodReturnTy

    // Single exit point: every return path stores the value (if any)
    // and branches here. The label site emits `ensures:` checks and
    // the actual `ret`. Empty body / value-less paths still flow
    // through this exit.
    let exitLabel = il.DefineLabel()
    let isVoidReturn = returnTy = typeof<System.Void>
    // FFI bug fix (D-progress-070 follow-up): when the function is
    // `async` AND has an `@externTarget`, the host method already
    // returns a `Task[<T>]`.  Wrapping the body's value in
    // `Task.FromResult<T>` at exit would double-wrap, producing
    // `Task<Task<T>>` and silently dropping cancellation /
    // exception semantics.  Track this and skip the wrap when
    // it applies.
    let isExternAsync =
        sg.IsAsync
        && fn.Annotations
           |> List.exists (fun a ->
               match a.Name.Segments with
               | ["externTarget"] -> true
               | _ -> false)
    // Phase B passes its own pre-allocated result local so the
    // surrounding SetResult block can load from it after the body
    // `Leave`s NormalDone.
    let resultLocal =
        match phaseBExit with
        | Some pb -> pb.ResultLocal
        | None    ->
            if isVoidReturn && not isExternAsync then None
            else
                // For `isExternAsync`, allocate the local as
                // `Task[<T>]` (the host method's actual return type)
                // so the Stloc is well-typed and the exit code can
                // return it directly without wrapping.
                let slotTy =
                    if isExternAsync then
                        if isVoidReturn then
                            typeof<System.Threading.Tasks.Task>
                        else
                            typedefof<System.Threading.Tasks.Task<_>>.MakeGenericType([| returnTy |])
                    else returnTy
                Some (il.DeclareLocal(slotTy))
    ctx.ReturnLabel <- Some exitLabel
    ctx.ResultLocal <- resultLocal

    // Helper: store a return value (already on the stack) into the
    // result slot and branch to the exit. `pushedTy` tells us
    // whether the source actually pushed something.  Inside a
    // `try { … } finally` protected region (any active defer), the
    // branch must be a `leave`, not a `br` — ECMA-335 III.3.55.
    let routeReturn (pushedTy: System.Type) =
        match resultLocal with
        | Some loc when pushedTy <> typeof<System.Void> ->
            il.Emit(OpCodes.Stloc, loc)
        | None when pushedTy <> typeof<System.Void> ->
            il.Emit(OpCodes.Pop)
        | _ -> ()
        if ctx.TryDepth > 0 then il.Emit(OpCodes.Leave, exitLabel)
        else il.Emit(OpCodes.Br, exitLabel)

    // Pre-condition checks fire before any body code.
    for c in fn.Contracts do
        match c with
        | CCRequires (cond, _) ->
            emitContractCheck ctx cond (sprintf "%s: requires failed" fn.Name)
        | _ -> ()

    let emitBodyBlock (blk: Block) =
        let stmts = blk.Statements
        Codegen.FunctionCtx.pushScope ctx
        // Phase B+++ defer-await trailing pattern (D-progress-057):
        // when the body matches `[pre-defer]; defer { cleanup };
        // [between]; trailing-await`, route to the duplicated-emit
        // path so cleanup runs once on scope exit (not on suspend).
        // Restricted to Unit-returning async funcs: the trailing
        // await's value isn't routed through `routeReturn`.
        let phaseBPlusPlusPlusDefer =
            if not isVoidReturn then None
            elif ctx.SmAwaitInfo.IsNone then None
            else AsyncStateMachine.tryMatchDeferAwaitTrailingShape stmts
        match phaseBPlusPlusPlusDefer with
        | Some (preDefer, deferBody, between, awaitStmt) ->
            for s in preDefer do
                Codegen.emitStatement ctx s
            Codegen.emitDeferAwaitDuplicated ctx deferBody between awaitStmt
            Codegen.FunctionCtx.popScope ctx
            il.Emit(OpCodes.Br, exitLabel)
        | None ->
            // Split out the last statement so the value-producing case can
            // route through `routeReturn`.  Defers in the prefix wrap both
            // the prefix tail and the last-statement handler in try/finally
            // via `emitStatementsWithDefer`.
            let prefix, lastOpt =
                match List.tryLast stmts with
                | None      -> [], None
                | Some last -> List.take (List.length stmts - 1) stmts, Some last
            let emitLast () =
                match lastOpt with
                | None -> ()
                | Some last ->
                    if not isVoidReturn then
                        match last.Kind with
                        | SExpr e ->
                            let t = Codegen.emitExpr ctx e
                            routeReturn t
                        | STry _ ->
                            // A bare `try { … } catch … { … }` as the last statement
                            // in a non-void function body is value-producing.  Wrap in
                            // EBlock so the try-as-expression handler fires and the
                            // result is routed back through the single-exit discipline.
                            let wrappedBlk : Lyric.Parser.Ast.Block = { Statements = [last]; Span = last.Span }
                            let wrappedExpr : Lyric.Parser.Ast.Expr = { Kind = EBlock wrappedBlk; Span = last.Span }
                            let t = Codegen.emitExpr ctx wrappedExpr
                            routeReturn t
                        | _ -> Codegen.emitStatement ctx last
                    else
                        Codegen.emitStatement ctx last
            Codegen.emitStatementsWithDeferTail ctx prefix emitLast
            Codegen.FunctionCtx.popScope ctx
            if isVoidReturn then
                il.Emit(OpCodes.Br, exitLabel)

    match fn.Body with
    | _ when fn.Annotations
             |> List.exists (fun a ->
                match a.Name.Segments with
                | ["externTarget"] -> true
                | _ -> false) ->
        // FFI: function has `@externTarget("Fully.Qualified.Member")`.
        // Resolve the target via reflection against the loaded
        // AppDomain (which already has every BCL assembly), pick a
        // method or property accessor that matches the Lyric param
        // arity, and emit a direct call.  The user's body — if any —
        // is intentionally ignored.
        let targetStr =
            fn.Annotations
            |> List.pick (fun a ->
                match a.Name.Segments with
                | ["externTarget"] ->
                    a.Args
                    |> List.tryPick (function
                        | ALiteral (AVString (s, _), _)        -> Some s
                        | AAName (_, AVString (s, _), _)       -> Some s
                        | _ -> None)
                | _ -> None)
        let genericGtpbs =
            if sg.Generics.IsEmpty then [||]
            else mb.GetGenericArguments()
        emitExternCall il fn paramList returnTy genericGtpbs resultLocal exitLabel targetStr
    | None ->
        if isVoidReturn then
            il.Emit(OpCodes.Br, exitLabel)
        else
            // Defaulted return for an empty body. Phase 1 punt:
            // emit `default(T)` via initobj for value types or
            // `ldnull` for ref types.
            match resultLocal with
            | Some loc when loc.LocalType.IsValueType ->
                il.Emit(OpCodes.Ldloca, loc)
                il.Emit(OpCodes.Initobj, loc.LocalType)
            | _ ->
                il.Emit(OpCodes.Ldnull)
                routeReturn typeof<obj>
            il.Emit(OpCodes.Br, exitLabel)
    | Some (FBBlock blk) ->
        emitBodyBlock blk
    | Some (FBExpr ({ Kind = ELambda ([], blk) })) ->
        emitBodyBlock blk
    | Some (FBExpr e) ->
        let resultTy = Codegen.emitExpr ctx e
        if isVoidReturn then
            if resultTy <> typeof<System.Void> then il.Emit(OpCodes.Pop)
            il.Emit(OpCodes.Br, exitLabel)
        else
            routeReturn resultTy

    // Exit-point block: ensures checks (if any) then the ret. Async
    // bodies wrap the produced value into `Task.FromResult<T>(value)`
    // before returning; void async bodies load `Task.CompletedTask`.
    il.MarkLabel(exitLabel)
    for c in fn.Contracts do
        match c with
        | CCEnsures (cond, _) ->
            emitContractCheck ctx cond (sprintf "%s: ensures failed" fn.Name)
        | _ -> ()
    match phaseBExit with
    | Some pb ->
        // Phase B: route exit through Leave NormalDone so the
        // outer structural code (catch handler + SetResult + ret)
        // can take over.  resultLocal carries the bare-typed
        // value (kept by the body emit pipeline via ctx.ResultLocal).
        // No ret here — the caller ends MoveNext with `Ret`.
        il.Emit(OpCodes.Leave, pb.NormalDone)
    | None ->
    match smInfo with
    | Some sm ->
        // SM Phase A: emit the SetResult/Ret epilogue.  The user
        // body produced its bare-typed value into `resultLocal`
        // (or none, for void); the epilogue helper consumes it.
        AsyncStateMachine.emitMoveNextEpilogue il sm resultLocal
    | None ->
        match resultLocal with
        | Some loc -> il.Emit(OpCodes.Ldloc, loc)
        | None     -> ()
        if sg.IsAsync then
            if isExternAsync then
                // Body already produced a `Task[<T>]` via the host
                // call; loading the result local from above is
                // sufficient.  Skip the FromResult wrap so we don't
                // double-wrap into `Task<Task<T>>`.
                ()
            elif isVoidReturn then
                // Drop nothing; load Task.CompletedTask.
                let taskTy = typeof<System.Threading.Tasks.Task>
                let prop = taskTy.GetProperty("CompletedTask")
                match Option.ofObj prop with
                | Some p ->
                    let getter = p.GetGetMethod()
                    match Option.ofObj getter with
                    | Some g -> il.Emit(OpCodes.Call, g)
                    | None   -> failwith "Task.CompletedTask getter not found"
                | None -> failwith "Task.CompletedTask property not found"
            else
                // `Task.FromResult<T>` lives on the non-generic Task
                // class. Look up the open-generic method directly so
                // we don't trip over TypeBuilder limitations when
                // bareReturnTy is still under construction.
                let fromResultGeneric =
                    let mi =
                        typeof<System.Threading.Tasks.Task>
                            .GetMethod("FromResult")
                    match Option.ofObj mi with
                    | Some m -> m.MakeGenericMethod([| bareReturnTy |])
                    | None   -> failwith "Task.FromResult<T> not found"
                il.Emit(OpCodes.Call, fromResultGeneric)
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

/// Result of pre-compiling `core.l` to a standalone library DLL.
/// User emissions that import `Std.Core` consult this artifact to
/// resolve types/methods to their precompiled CLR equivalents.
///
/// The artifact is also the surface used by `emitProject` to wire
/// intra-project cross-package imports: package N's emit captures
/// itself as an artifact (whose `Lookup` resolves names against the
/// shared `ModuleBuilder`) and feeds it into package N+1's emit.
/// `Assembly` is `None` for those in-project artifacts because the
/// bundled DLL hasn't been written yet — `Lookup` reads sealed
/// `TypeBuilder`s out of the live module instead.
type private StdlibArtifact =
    { /// Absolute path to the compiled `Lyric.Stdlib.Core.dll`.
      /// Empty string for in-project artifacts (no on-disk DLL yet).
      AssemblyPath: string
      /// Loaded into the current process via `Assembly.LoadFrom`.
      /// `None` for in-project artifacts (see type doc).
      Assembly:     Assembly option
      /// Parsed AST of `core.l`.
      Source:       SourceFile
      /// The stdlib's symbol table (typeids are stdlib-local).
      Symbols:      SymbolTable
      /// Resolved signatures for every stdlib function.
      Signatures:   Map<string, ResolvedSignature>
      /// Type lookup: fully-qualified CLR name → `System.Type`.
      /// Backed by `Assembly.GetType` for stdlib + restored
      /// packages and by `ModuleBuilder.GetType` for in-project
      /// artifacts (see `emitProject` plumbing).
      Lookup:       string -> System.Type option }

let private emitAssembly
        (sf: SourceFile)
        (sigs: Map<string, ResolvedSignature>)
        (symbols: SymbolTable)
        (req: EmitRequest)
        (isLibrary: bool)
        (stdlibArtifacts: StdlibArtifact list)
        (stdImports: ImportDecl list)
        // M5.1 stage 2c.2.ii — when `Some ctx`, `emitAssembly`
        // emits into the caller-owned context and skips the save +
        // contract/proof embed steps.  Caller drives the final save
        // and resource embeds for project-as-DLL bundling.  When
        // `None`, behaviour is unchanged: own the backend, save,
        // and embed a single-package contract.
        (sharedCtx: Backend.EmitContext option)
        // M5.1 stage 2c.2.ii.b — when `Some d`, `emitAssembly`
        // populates `d` with `qualifiedName -> System.Type` entries
        // as each `TypeBuilder` is sealed via `CreateType()`.  The
        // `emitProject` driver shares one dictionary across every
        // package's emit so downstream packages can resolve
        // intra-project type names without going through the
        // PersistedAssemblyBuilder's `ModuleBuilder.GetType`, which
        // is not implemented for that backend.
        (typesOut: Dictionary<string, System.Type> option)
        // M5.1 stage 2c.2.iv — when `Some r` and the source declares
        // `func main`, `emitAssembly` writes the host-wrapper
        // `MethodInfo` into `r` so an `emitProject` driver can pass
        // it to `Backend.save` as the bundled DLL's entry point.
        // Single-package callers ignore this (they save themselves).
        (mainOut: MethodInfo option ref option) : Diagnostic list =
    // Weave aspect advice before any pass sees the item list.
    let sf = { sf with Items = Weaver.weaveItems sf.Items }
    let funcs = functionItems sf
    // Augment the type-checker's signature map with entries for weaved target
    // functions (e.g. `greet__aspect_target`).  The type checker ran on the
    // pre-weave source so these names are absent; without augmentation the
    // emitter falls back to the zero-param default sig, which drops all
    // parameters and causes E0004 "unknown name" errors in Pass B.
    let sigs =
        funcs |> List.fold (fun acc fn ->
            let suffix = "__aspect_target"
            if fn.Name.EndsWith suffix then
                let origName = fn.Name.[.. fn.Name.Length - suffix.Length - 1]
                let arityKey = origName + "/" + string fn.Params.Length
                let sgOpt =
                    match Map.tryFind arityKey sigs with
                    | Some s -> Some s
                    | None   -> Map.tryFind origName sigs
                match sgOpt with
                | Some s ->
                    acc
                    |> Map.add fn.Name s
                    |> Map.add (fn.Name + "/" + string fn.Params.Length) s
                | None -> acc
            else acc) sigs
    // Library packages don't need a `main`; executable packages do.
    let mainFn =
        if isLibrary then None
        else
            match funcs |> List.tryFind (fun f -> f.Name = "main") with
            | Some f -> Some f
            | None -> None
    if (not isLibrary) && mainFn.IsNone then
        [ err "E0001"
            "no `func main(): Unit` found — Phase 1 emit needs an entry point"
            sf.Span ]
    else
        let desc =
            { Name        = req.AssemblyName
              Version     = Version(0, 1, 0, 0)
              OutputPath  = req.OutputPath }
        let ctx, ownsCtx =
            match sharedCtx with
            | Some c -> c, false
            | None   -> Backend.create desc, true
        let codegenDiags = ResizeArray<Diagnostic>()
        let nsName = String.concat "." sf.Package.Path.Segments
        let typeName =
            if String.IsNullOrEmpty nsName then "Program"
            else nsName + ".Program"

        // M5.1 stage 2c.2.ii.c — visibility lookup keyed by item name.
        // Each top-level `DefineType` consults this to choose
        // `Public` vs `NotPublic` based on the declared visibility.
        let visByName = visibilityByName sf
        let visOf (name: string) : Visibility option =
            match Map.tryFind name visByName with
            | Some v -> v
            | None   -> None

        // Pass 0 — record + enum types. Defined before functions so
        // signatures can mention them, and the runtime sees them
        // ready when the host calls newobj / loads case constants.
        let recordTable = Records.RecordTable()
        let enumTable   = Records.EnumTable()
        let enumCases   = Records.EnumCaseLookup()
        let typeIdToClr = Dictionary<TypeId, System.Type>()

        // ---- FFI: register extern types so any reference resolves
        // ---- to the CLR type at typeIdToClr lookup time.  Failure
        // ---- to resolve surfaces as a build error rather than a
        // ---- silent fallback to obj.
        //
        // Generic externs (`extern type List[T] = "...List`1"`) bind
        // the open generic definition.  `TypeMap.toClrTypeWith` then
        // closes it via `MakeGenericType` whenever the user mentions
        // `List[Int]`, etc.  We validate arity here so a mismatched
        // declaration fails at compile time rather than as a confusing
        // ArgumentException deep in `MakeGenericType`.
        // Lyric extern type names (`extern type Url = "System.Uri"`)
        // mapped to their CLR types.  Drives the C4-phase-1 strict-
        // match auto-FFI dispatch in codegen — a `Url.method(args)`
        // call falls back to a static method on the underlying CLR
        // type when no explicit `@externTarget` is registered.
        let externTypeNames = Dictionary<string, System.Type>()
        // Local extern types declared in this source file.
        for et in externTypeItems sf do
            match findClrType et.ClrName with
            | Some clr ->
                let lyricArity =
                    match et.Generics with
                    | Some gp -> gp.Params.Length
                    | None    -> 0
                let clrArity =
                    if clr.IsGenericTypeDefinition then
                        clr.GetGenericArguments().Length
                    else 0
                if lyricArity <> clrArity then
                    failwithf
                        "FFI: extern type '%s' has %d type parameter(s) but \"%s\" has %d"
                        et.Name lyricArity et.ClrName clrArity
                externTypeNames.[et.Name] <- clr
                symbols.TryFind et.Name
                |> Seq.tryHead
                |> Option.bind Symbol.typeIdOpt
                |> Option.iter (fun id -> typeIdToClr.[id] <- clr)
            | None ->
                failwithf "FFI: cannot resolve extern type '%s' = \"%s\" against the loaded AppDomain"
                    et.Name et.ClrName

        // Extern types coming in via stdlib imports.  The user's
        // symbol table has the imported `extern type` registered (so
        // `List` etc. resolve as user-side names), but the local
        // typeIdToClr map only knows about types declared in *this*
        // source file.  Mirror each imported extern's CLR mapping so
        // `TypeMap.toClrTypeWithGenerics` can close `List[Int]` /
        // `Map[K, V]` etc.
        for art in stdlibArtifacts do
            for et in externTypeItems art.Source do
                match findClrType et.ClrName with
                | Some clr ->
                    if not (externTypeNames.ContainsKey et.Name) then
                        externTypeNames.[et.Name] <- clr
                    symbols.TryFind et.Name
                    |> Seq.tryHead
                    |> Option.bind Symbol.typeIdOpt
                    |> Option.iter (fun id ->
                        if not (typeIdToClr.ContainsKey id) then
                            typeIdToClr.[id] <- clr)
                | None -> ()

        // ---- imported tables — populated from `stdlibArtifact` ----
        let importedRecordTable     = Records.ImportedRecordTable()
        let importedUnionTable      = Records.ImportedUnionTable()
        let importedUnionCaseLookup = Records.ImportedUnionCaseLookup()
        let importedFuncTable       = Records.ImportedFuncTable()
        let importedDistinctTypeTable = Records.ImportedDistinctTypeTable()
        // Map a package's segments to the user-stated `ImportDecl`, if
        // any.  The user might have written `import Std.Iter as IT` or
        // `import Std.Collections.{newList as mkList}` — both forms
        // need to register additional alias keys against the existing
        // imported-func / union / record tables.  Transitive
        // dependencies (artifacts pulled in via `Std.Iter`'s own
        // imports rather than stated by the user) are unaliased.
        let importByPath =
            stdImports
            |> List.map (fun i -> i.Path.Segments, i)
            |> Map.ofList
        // Selector-level aliases: `import Std.X.{foo as bar}` registers
        // `bar` (and `bar/N`) as additional keys for `foo` in the
        // imported-func table.  Returns the alias-name for a given
        // imported function name, or `None` if the user didn't ask
        // for one.
        let selectorAliasFor (imp: ImportDecl) (origName: string) : string option =
            match imp.Selector with
            | Some (ISSingle item) when item.Name = origName -> item.Alias
            | Some (ISGroup items) ->
                items
                |> List.tryFind (fun it -> it.Name = origName)
                |> Option.bind (fun it -> it.Alias)
            | _ -> None
        // Cross-artifact selector aliases: when the user writes
        // `import Std.Collections.{newList as mkList}` and `newList`
        // actually lives in a transitively-imported package
        // (e.g., `Std.CollectionsHost`), the alias should still
        // resolve.  Collect every (origName, aliasName) pair across
        // user imports so the artifact-processing loop below can
        // apply it to whichever artifact actually owns `origName`.
        let crossAliasFor (origName: string) : string option =
            stdImports
            |> List.tryPick (fun imp -> selectorAliasFor imp origName)
        for artifact in stdlibArtifacts do
            let stdNs = String.concat "." artifact.Source.Package.Path.Segments
            let qualify name =
                if String.IsNullOrEmpty stdNs then name
                else stdNs + "." + name
            let getType (n: string) : System.Type option =
                artifact.Lookup n
            let userImport =
                Map.tryFind artifact.Source.Package.Path.Segments importByPath
            // Resolver context against the artifact's symbol table —
            // used to resolve each declared field/parameter type to a
            // Lyric `Type`, which is what call-site type-arg inference
            // walks (reflection on an open generic case type would
            // surface a bare `T` and lose the structural shape).
            let importResolveCtx = GenericContext()
            let importDiags = ResizeArray<Diagnostic>()
            let importLyric (typeParamNames: string list) (te: TypeExpr) : Lyric.TypeChecker.Type =
                if not typeParamNames.IsEmpty then importResolveCtx.Push(typeParamNames)
                let result =
                    Resolver.resolveType artifact.Symbols importResolveCtx importDiags te
                if not typeParamNames.IsEmpty then importResolveCtx.Pop() |> ignore
                result
            // Unions
            for it in artifact.Source.Items do
                match it.Kind with
                | IUnion ud ->
                    let typeParamNames =
                        match ud.Generics with
                        | Some gs ->
                            gs.Params
                            |> List.map (function
                                | GPType(name, _) | GPValue(name, _, _) -> name)
                        | None -> []
                    let isGeneric = not typeParamNames.IsEmpty
                    match getType (qualify ud.Name) with
                    | None -> ()
                    | Some baseTy ->
                        let cases =
                            ud.Cases
                            |> List.choose (fun c ->
                                // Both generic and non-generic unions now
                                // emit case classes as top-level types with
                                // `_` separator (non-generic unions were
                                // switched from DefineNestedType to top-level
                                // to fix ldsfld MemberRef encoding in
                                // PersistedAssemblyBuilder).
                                let caseFullName =
                                    qualify ud.Name + "_" + c.Name
                                match getType caseFullName with
                                | None -> None
                                | Some caseTy ->
                                    // `BindingFlags.DeclaredOnly` is required for
                                    // in-project artifacts (D-progress-099): a
                                    // generic union case's parent is a
                                    // `TypeBuilderInstantiation` (`Option`Some`
                                    // declares parent `Option<T>`), and the
                                    // default `GetFields` traverses parents,
                                    // which throws `NotSupportedException` on
                                    // a builder instantiation.  Declared-only
                                    // skips the parent walk; case fields are
                                    // never inherited anyway.
                                    let declaredFlags =
                                        BindingFlags.Instance
                                        ||| BindingFlags.Public
                                        ||| BindingFlags.DeclaredOnly
                                    let ctorOpt =
                                        caseTy.GetConstructors declaredFlags
                                        |> Array.tryHead
                                    // Walk the parsed case fields to
                                    // resolve each LyricType against
                                    // the artifact symbols, then pair
                                    // it with the matching CLR FieldInfo
                                    // looked up by name.
                                    let parsedFields =
                                        c.Fields
                                        |> List.mapi (fun i f ->
                                            let fname, te =
                                                match f with
                                                | UFNamed (n, te, _) -> n, te
                                                | UFPos (te, _) -> sprintf "Item%d" (i + 1), te
                                            let lty = importLyric typeParamNames te
                                            fname, lty)
                                    let clrFields =
                                        caseTy.GetFields declaredFlags
                                        |> Array.filter (fun f -> f.IsPublic && not f.IsStatic)
                                        |> Array.map (fun f -> f.Name, f)
                                        |> Map.ofArray
                                    let fields =
                                        parsedFields
                                        |> List.choose (fun (fname, lty) ->
                                            match Map.tryFind fname clrFields with
                                            | Some fi ->
                                                Some
                                                    { Records.ImportedField.Name      = fname
                                                      Records.ImportedField.Type      = fi.FieldType
                                                      Records.ImportedField.LyricType = lty
                                                      Records.ImportedField.Field     = fi }
                                            | None -> None)
                                    // For nullary cases: look up the static
                                    // Instance singleton field (informational)
                                    // and the Get<Name>() accessor on baseTy
                                    // (used by Codegen for cross-assembly calls).
                                    // Only safe on real CLR types — TypeBuilder
                                    // reflection methods throw NotSupportedException.
                                    let isRealClr (t: System.Type) =
                                        not (t :? System.Reflection.Emit.TypeBuilder)
                                    let instanceFieldOpt =
                                        if fields.IsEmpty && isRealClr caseTy then
                                            let sf =
                                                BindingFlags.Public
                                                ||| BindingFlags.Static
                                                ||| BindingFlags.DeclaredOnly
                                            caseTy.GetField("Instance", sf)
                                            |> Option.ofObj
                                        else None
                                    // Get<Name>() is defined on baseTy; look it
                                    // up only when both types are real CLR types.
                                    let getterMethodOpt =
                                        if fields.IsEmpty && isRealClr caseTy && isRealClr baseTy then
                                            let sf =
                                                BindingFlags.Public
                                                ||| BindingFlags.Static
                                                ||| BindingFlags.DeclaredOnly
                                            baseTy.GetMethod("Get" + c.Name, sf)
                                            |> Option.ofObj
                                        else None
                                    match ctorOpt with
                                    | None -> None
                                    | Some ctor ->
                                        Some
                                            { Records.ImportedUnionCaseInfo.Name         = c.Name
                                              Records.ImportedUnionCaseInfo.Type         = caseTy
                                              Records.ImportedUnionCaseInfo.Fields       = fields
                                              Records.ImportedUnionCaseInfo.Ctor         = ctor
                                              Records.ImportedUnionCaseInfo.Instance     = instanceFieldOpt
                                              Records.ImportedUnionCaseInfo.GetterMethod = getterMethodOpt })
                        let info =
                            { Records.ImportedUnionInfo.Name     = ud.Name
                              Records.ImportedUnionInfo.Type     = baseTy
                              Records.ImportedUnionInfo.Cases    = cases
                              Records.ImportedUnionInfo.Generics = typeParamNames }
                        importedUnionTable.[ud.Name] <- info
                        for c in info.Cases do
                            importedUnionCaseLookup.[c.Name] <- (info, c)
                            importedUnionCaseLookup.[ud.Name + "." + c.Name] <- (info, c)
                        symbols.TryFind ud.Name
                        |> Seq.tryHead
                        |> Option.bind Symbol.typeIdOpt
                        |> Option.iter (fun tid -> typeIdToClr.[tid] <- baseTy)
                | _ -> ()
            // Records — populate importedRecordTable so cross-package
            // record construction (e.g. `LFunc(...)`) works in consumers.
            for it in artifact.Source.Items do
                match it.Kind with
                | IRecord rd | IExposedRec rd ->
                    let typeParamNames =
                        match rd.Generics with
                        | Some gs ->
                            gs.Params
                            |> List.map (function
                                | GPType (n, _) | GPValue (n, _, _) -> n)
                        | None -> []
                    match getType (qualify rd.Name) with
                    | None -> ()
                    | Some ty ->
                        let parsedFields =
                            rd.Members
                            |> List.choose (function
                                | RMField fd -> Some (fd.Name, fd.Type)
                                | _ -> None)
                            |> List.map (fun (fname, te) ->
                                fname, importLyric typeParamNames te)
                        // See the union-case path above for why
                        // `DeclaredOnly` is required to support in-project
                        // artifacts whose generic record's parent is a
                        // `TypeBuilderInstantiation`.
                        let declaredFlags =
                            BindingFlags.Instance
                            ||| BindingFlags.Public
                            ||| BindingFlags.DeclaredOnly
                        let clrFieldMap =
                            ty.GetFields declaredFlags
                            |> Array.filter (fun f -> f.IsPublic && not f.IsStatic)
                            |> Array.map (fun f -> f.Name, f)
                            |> Map.ofArray
                        let fields =
                            parsedFields
                            |> List.choose (fun (fname, lty) ->
                                match Map.tryFind fname clrFieldMap with
                                | Some fi ->
                                    Some
                                        { Records.ImportedField.Name      = fname
                                          Records.ImportedField.Type      = fi.FieldType
                                          Records.ImportedField.LyricType = lty
                                          Records.ImportedField.Field     = fi }
                                | None -> None)
                        match ty.GetConstructors declaredFlags |> Array.tryHead with
                        | None -> ()
                        | Some ctor ->
                            importedRecordTable.[rd.Name] <-
                                { Records.ImportedRecordInfo.Name     = rd.Name
                                  Records.ImportedRecordInfo.Type     = ty
                                  Records.ImportedRecordInfo.Fields   = fields
                                  Records.ImportedRecordInfo.Ctor     = ctor
                                  Records.ImportedRecordInfo.Generics = typeParamNames }
                            symbols.TryFind rd.Name
                            |> Seq.tryHead
                            |> Option.bind Symbol.typeIdOpt
                            |> Option.iter (fun tid -> typeIdToClr.[tid] <- ty)
                | _ -> ()
            // Protected types — populate typeIdToClr so cross-package
            // references to a `protected type` (e.g. `StubCounter` from
            // `Std.Testing.Mocking`) resolve to the correct CLR type.
            // No method table is needed: callers go through wrapper
            // functions in the same package, not direct method dispatch.
            for it in artifact.Source.Items do
                match it.Kind with
                | IProtected pd ->
                    match getType (qualify pd.Name) with
                    | None -> ()
                    | Some ty ->
                        symbols.TryFind pd.Name
                        |> Seq.tryHead
                        |> Option.bind Symbol.typeIdOpt
                        |> Option.iter (fun tid ->
                            if not (typeIdToClr.ContainsKey tid) then
                                typeIdToClr.[tid] <- ty)
                | _ -> ()
            // Functions — every IFunc lives as a static method on the
            // stdlib's `<Pkg>.Program` type.  We pair the MethodInfo
            // with the artifact's resolved signature so call-site
            // type-arg inference can run against Lyric param shapes.
            match getType (qualify "Program") with
            | None -> ()
            | Some progTy ->
                for it in artifact.Source.Items do
                    match it.Kind with
                    | IFunc fn ->
                        // Use GetMethods + filter by name and param count so that
                        // same-name overloads don't cause AmbiguousMatchException.
                        let arity = fn.Params.Length
                        let miOpt =
                            progTy.GetMethods()
                            |> Array.tryFind (fun m ->
                                m.Name = fn.Name
                                && m.GetParameters().Length = arity)
                        let arityKey = fn.Name + "/" + string arity
                        let registerInfo (info: Records.ImportedFuncInfo) =
                            importedFuncTable.[fn.Name]  <- info
                            importedFuncTable.[arityKey] <- info
                            // Bootstrap-grade alias semantics (D-progress-018):
                            // selector alias `import X.{foo as bar}` adds
                            // `bar` and `bar/N` keys for `foo`.  Package
                            // aliases (`import X as A`) are handled at the
                            // AST level by `AliasRewriter` before the type
                            // checker runs, so no extra keys are needed
                            // here.  `crossAliasFor` lets the alias
                            // resolve even when `foo` lives in a
                            // transitively-imported kernel package the
                            // user didn't directly state — e.g.
                            // `import Std.Collections.{newList as mkList}`
                            // when `newList` was relocated to
                            // `Std.CollectionsHost`.
                            match crossAliasFor fn.Name with
                            | Some sa ->
                                importedFuncTable.[sa] <- info
                                importedFuncTable.[sa + "/" + string arity] <- info
                            | None -> ()
                        match miOpt, Map.tryFind arityKey artifact.Signatures with
                        | Some mi, Some sg ->
                            registerInfo
                                { Records.ImportedFuncInfo.Method = mi
                                  Records.ImportedFuncInfo.Sig    = sg }
                        | _ ->
                            match miOpt, Map.tryFind fn.Name artifact.Signatures with
                            | Some mi, Some sg ->
                                registerInfo
                                    { Records.ImportedFuncInfo.Method = mi
                                      Records.ImportedFuncInfo.Sig    = sg }
                            | _ -> ()
                    | _ -> ()

        // Two passes for records / opaques so a field whose type is
        // another user record (`record Outer { i: Inner }`) sees
        // Inner's TypeBuilder rather than falling back to `obj`.  The
        // first pass just defines the empty TypeBuilder (with generic
        // params if declared) and registers it in `typeIdToClr`; the
        // second populates fields + ctor.  Generic records (`record
        // Box[T] { value: T }`) get the open generic type definition
        // registered so other records / functions referencing
        // `Box[Int]` can close it via `MakeGenericType`.
        let recordStubs =
            ResizeArray<RecordDecl * TypeBuilder * string list * Map<string, System.Type>>()
        for rd in recordItems sf do
            let fullName =
                if String.IsNullOrEmpty nsName then rd.Name
                else nsName + "." + rd.Name
            let tb =
                ctx.Module.DefineType(
                    fullName,
                    typeAttrsForVis (visOf rd.Name) TypeAttributes.Sealed,
                    typeof<obj>)
            let typeParamNames =
                match rd.Generics with
                | Some gs ->
                    gs.Params
                    |> List.map (function
                        | GPType (n, _) | GPValue (n, _, _) -> n)
                | None -> []
            let typeParamSubst =
                if typeParamNames.IsEmpty then Map.empty
                else
                    let gtps =
                        tb.DefineGenericParameters(typeParamNames |> List.toArray)
                    typeParamNames
                    |> List.mapi (fun i name -> name, gtps.[i] :> System.Type)
                    |> Map.ofList
            symbols.TryFind rd.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- tb :> System.Type)
            recordStubs.Add(rd, tb, typeParamNames, typeParamSubst)

        // Opaque types — bootstrap-grade: lower as records.  Visibility
        // is unenforced because we still compile a single package.
        let opaqueStubs =
            ResizeArray<OpaqueTypeDecl * TypeBuilder * string list * Map<string, System.Type>>()
        let projectableOpaques = ResizeArray<OpaqueTypeDecl * Records.RecordInfo>()
        for od in opaqueItems sf do
            let fullName =
                if String.IsNullOrEmpty nsName then od.Name
                else nsName + "." + od.Name
            let tb =
                ctx.Module.DefineType(
                    fullName,
                    typeAttrsForVis (visOf od.Name) TypeAttributes.Sealed,
                    typeof<obj>)
            let typeParamNames =
                match od.Generics with
                | Some gs ->
                    gs.Params
                    |> List.map (function
                        | GPType (n, _) | GPValue (n, _, _) -> n)
                | None -> []
            let typeParamSubst =
                if typeParamNames.IsEmpty then Map.empty
                else
                    let gtps =
                        tb.DefineGenericParameters(typeParamNames |> List.toArray)
                    typeParamNames
                    |> List.mapi (fun i name -> name, gtps.[i] :> System.Type)
                    |> Map.ofList
            symbols.TryFind od.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- tb :> System.Type)
            opaqueStubs.Add(od, tb, typeParamNames, typeParamSubst)
        for ed in enumItems sf do
            let info = defineEnum ctx.Module nsName (visOf ed.Name) ed
            enumTable.[ed.Name] <- info
            for c in info.Cases do
                // Bare `Red` and qualified `Color.Red` both resolve.
                enumCases.[c.Name] <- (info, c)
                enumCases.[ed.Name + "." + c.Name] <- (info, c)
            symbols.TryFind ed.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- info.Type)

        let unionTable = Records.UnionTable()
        let unionCaseLookup = Records.UnionCaseLookup()
        // Union pass 1: create TypeBuilder stubs (base + case classes) and
        // register the base in typeIdToClr.  Field + ctor definition is
        // deferred to pass 2 so the full lookup is available.
        let unionBases = ResizeArray<UnionBase>()
        for ud in unionItems sf do
            let ub = defineUnionBase ctx.Module nsName (visOf ud.Name) ud
            unionBases.Add(ub)
            symbols.TryFind ud.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- ub.BaseTy :> System.Type)

        let lookup =
            fun (id: TypeId) ->
                match typeIdToClr.TryGetValue id with
                | true, t  -> Some t
                | false, _ -> None

        // Second pass for records / opaques — populate fields + ctor
        // onto the existing TypeBuilder stubs now that every record's
        // TypeBuilder is registered in typeIdToClr.  This is what
        // makes `record Outer { i: Inner }` work — Inner's stub is
        // resolvable by the time Outer's field-type lookup runs.
        for (rd, stubTb, typeParams, subst) in recordStubs do
            let info =
                defineRecordOnto stubTb typeParams subst symbols lookup rd
            recordTable.[rd.Name] <- info
        for (od, stubTb, typeParams, subst) in opaqueStubs do
            let info =
                defineRecordOnto
                    stubTb typeParams subst symbols lookup
                    (opaqueAsRecord od)
            recordTable.[od.Name] <- info
            if isProjectable od then projectableOpaques.Add(od, info)

        // Union pass 2: populate case fields + ctors using the full lookup
        // (all record/union TypeBuilder stubs are now registered).  For
        // non-generic unions this resolves field types to their proper CLR
        // TypeBuilders rather than erasing them to `obj`.
        for ub in unionBases do
            let info = defineUnionPopulate symbols lookup ub
            unionTable.[ub.Decl.Name] <- info
            for c in info.Cases do
                unionCaseLookup.[c.Name] <- (info, c)
                unionCaseLookup.[ub.Decl.Name + "." + c.Name] <- (info, c)

        // Pass A.4 — synthesise CLR class scaffolding for every
        // `protected type` (D-progress-079).  Returns a list of
        // pending method bodies that Pass B emits inside the
        // Monitor.Enter / try / finally / Monitor.Exit wrap.
        let protectedTable = Records.ProtectedTypeTable()
        let protectedPending = ResizeArray<ProtectedMethodPending>()
        let protectedCtorsPending = ResizeArray<ProtectedCtorPending>()
        for pd in protectedItems sf do
            let info, pending, ctorPending =
                defineProtectedTypeOnto ctx.Module nsName symbols lookup codegenDiags (visOf pd.Name) pd
            protectedTable.[pd.Name] <- info
            for p in pending do protectedPending.Add p
            protectedCtorsPending.Add ctorPending
            // Register a stub `RecordInfo` so the existing record-call
            // dispatch at `Codegen.fs` line ~2401 picks up `Counter()`
            // construction without needing a separate dispatch arm.
            // `Fields = []` makes the call expect zero args; the
            // synthesised default ctor matches that.
            // Populate the stub RecordInfo with the protected type's
            // field metadata so `self.count` member-access dispatch
            // (which looks up `RecordInfo.Fields`) finds the right
            // FieldBuilder.  `Fields = []` would still let
            // `Counter()` construction work but would crash on any
            // implicit-self field reference inside an entry/func body
            // after the AST desugar.
            let stubFields =
                info.Fields
                |> List.map (fun pf ->
                    { Records.RecordField.Name      = pf.Name
                      Records.RecordField.Type      = pf.Type
                      Records.RecordField.LyricType = Lyric.TypeChecker.TyError
                      Records.RecordField.Field     = pf.Field })
            recordTable.[pd.Name] <-
                { Records.RecordInfo.Name     = info.Name
                  Records.RecordInfo.Type     = info.Type
                  Records.RecordInfo.Fields   = stubFields
                  Records.RecordInfo.Ctor     = info.Ctor
                  Records.RecordInfo.Generics = [] }
            symbols.TryFind pd.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- info.Type)

        let interfaceTable = Records.InterfaceTable()
        // Tracks `impl Foo for Bar` blocks so codegen can resolve
        // `where T: Foo` bounds (Q021 sub-question #5) without
        // calling `TypeBuilder.GetInterfaces()` on a still-unsealed
        // record. Populated in Pass A.5 alongside
        // `AddInterfaceImplementation`.
        let implsTable = Records.ImplsTable()
        for id in interfaceItems sf do
            let info = defineInterface ctx.Module nsName symbols lookup (visOf id.Name) id
            interfaceTable.[id.Name] <- info
            symbols.TryFind id.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun tid -> typeIdToClr.[tid] <- info.Type :> System.Type)

        // Projectable cycle detection (D026).  Build a directed graph
        // of projectable opaque types, where an edge `A -> B` means
        // "type A has a non-`@projectionBoundary` field referencing
        // projectable B".  Cycles in that graph would cause infinite
        // recursive view projection, so the language reference
        // requires the user to mark at least one edge of every cycle
        // with `@projectionBoundary`.  We DFS the graph and report a
        // structured error pointing at the cycle.
        let projectableNames =
            projectableOpaques
            |> Seq.map (fun (od, _) -> od.Name)
            |> Set.ofSeq
        let rec mentionedProjectables (te: TypeExpr) : string list =
            match te.Kind with
            | TRef p ->
                match p.Segments with
                | [name] when Set.contains name projectableNames -> [name]
                | _ -> []
            | TGenericApp (head, args) ->
                let headHits =
                    match head.Segments with
                    | [name] when Set.contains name projectableNames -> [name]
                    | _ -> []
                let argHits =
                    args
                    |> List.collect (fun a ->
                        match a with
                        | TAType t -> mentionedProjectables t
                        | TAValue _ -> [])
                headHits @ argHits
            | TArray (_, elem)
            | TSlice elem
            | TNullable elem
            | TParen elem -> mentionedProjectables elem
            | TTuple ts -> ts |> List.collect mentionedProjectables
            | TFunction (ps, r) ->
                (ps |> List.collect mentionedProjectables)
                @ mentionedProjectables r
            | _ -> []
        let projectableEdges =
            projectableOpaques
            |> Seq.map (fun (od, _) ->
                let outgoing =
                    od.Members
                    |> List.collect (fun m ->
                        match m with
                        | OMField fd when not (isProjectionBoundaryField fd) ->
                            mentionedProjectables fd.Type
                            |> List.map (fun target -> target, fd)
                        | _ -> [])
                od.Name, outgoing)
            |> Map.ofSeq
        let mutable projectableCycleErr : Diagnostic option = None
        let visiting = HashSet<string>()
        let visited  = HashSet<string>()
        let rec dfs (path: string list) (node: string) =
            if projectableCycleErr.IsSome then ()
            elif visiting.Contains node then
                // Found a cycle.  Pick the offending field span on
                // the back-edge (the field that points from `path
                // head` to `node`, closing the cycle).
                let cycleSpan =
                    match Map.tryFind (List.head path) projectableEdges with
                    | Some edges ->
                        edges
                        |> List.tryFind (fun (target, _) -> target = node)
                        |> Option.map (fun (_, fd) -> fd.Span)
                        |> Option.defaultValue (List.head path |> fun _ -> Span.make Position.initial Position.initial)
                    | None -> Span.make Position.initial Position.initial
                let cyclePath =
                    let prefix = List.rev path |> List.skipWhile ((<>) node)
                    String.concat " -> " (prefix @ [node])
                projectableCycleErr <-
                    Some (err "T0092"
                            (sprintf
                                "projectable cycle detected (%s); mark at least one field with `@projectionBoundary` to break the cycle"
                                cyclePath)
                            cycleSpan)
            elif visited.Contains node then ()
            else
                visiting.Add node |> ignore
                match Map.tryFind node projectableEdges with
                | Some edges ->
                    for (target, _) in edges do
                        dfs (node :: path) target
                | None -> ()
                visiting.Remove node |> ignore
                visited.Add node |> ignore
        for (od, _) in projectableOpaques do
            dfs [] od.Name
        match projectableCycleErr with
        | Some d -> codegenDiags.Add d
        | None -> ()

        // Projectable opaque types — synthesise `<Name>View` exposed
        // record + a `toView()` instance method.  Three staged passes
        // so cross-referencing projectables can each see the other's
        // view TypeBuilder + `toView` MethodBuilder before any field
        // or IL is emitted.  Recursive projection: a field whose
        // source CLR type is itself a projectable opaque substitutes
        // the corresponding view type, and `toView()` calls the
        // nested `toView()` to project the value.
        //
        // When a projectable cycle was detected (`projectableCycleErr`
        // populated above), the view derivation is skipped — the
        // recursive `toView` lowering would otherwise diverge with
        // "nested toView for X not yet defined" since no `@projectionBoundary`
        // breaks the recursion.
        let projectableTable = Records.ProjectableTable()
        let stubByOpaqueClr = Dictionary<System.Type, ProjectableStub>()
        let projectablesToDerive =
            if projectableCycleErr.IsSome then []
            else projectableOpaques |> Seq.toList
        let stubs =
            projectablesToDerive
            |> List.map (fun (od, opaqueInfo) ->
                let stub = defineProjectableViewStub ctx.Module nsName opaqueInfo (visOf od.Name) od
                stubByOpaqueClr.[opaqueInfo.Type :> System.Type] <- stub
                stub)
        // Pass B: populate fields + ctors on every view stub (now all
        // stubs are visible so cross-referencing fields can land).
        let viewInfos =
            stubs
            |> List.map (fun stub ->
                let viewInfo =
                    populateProjectableView symbols lookup stubByOpaqueClr stub
                recordTable.[viewInfo.Name] <- viewInfo
                stub, viewInfo)
        // Pass C: define `toView()` IL on every opaque.  This needs
        // every view's ctor (built in Pass B) and every other
        // opaque's `toView` MethodBuilder — define-then-fill on the
        // method handles inside this loop because each method's IL
        // body only references the others' MethodBuilders, not their
        // bodies.
        for (stub, viewInfo) in viewInfos do
            let toViewMb = populateToViewMethod stubByOpaqueClr stub viewInfo
            stub.ToView <- Some toViewMb
            // Pass D: optional reverse `<Name>View::tryInto`.  Skipped
            // for projectables with nested-projectable fields (needs
            // monadic bind through each nested tryInto) and when
            // `Std.Core.Result` isn't imported.
            let tryIntoMb =
                populateTryIntoMethod importedUnionTable stubByOpaqueClr stub viewInfo
            projectableTable.[stub.OpaqueDecl.Name] <-
                { Records.ProjectableInfo.OpaqueName    = stub.OpaqueDecl.Name
                  Records.ProjectableInfo.ToViewMethod  = toViewMb
                  Records.ProjectableInfo.ViewType      = viewInfo
                  Records.ProjectableInfo.TryIntoMethod = tryIntoMb }

        // Pass 0.5 — distinct types and range subtypes.
        let distinctTable = Records.DistinctTypeTable()
        for dt in distinctTypeItems sf do
            let info =
                defineDistinctType
                    ctx.Module nsName lookup symbols importedUnionTable (visOf dt.Name) dt
            distinctTable.[dt.Name] <- info
            symbols.TryFind dt.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun tid -> typeIdToClr.[tid] <- info.Type :> System.Type)
        // Seal distinct type structs so CLR metadata is finalised before
        // any function body tries to reference them.
        for kv in distinctTable do
            kv.Value.Type.CreateType() |> ignore

        let programTy =
            ctx.Module.DefineType(
                typeName,
                TypeAttributes.Public
                ||| TypeAttributes.Sealed
                ||| TypeAttributes.Abstract,
                typeof<obj>)

        // Pass A — define every header.
        // Keys: bare `name` (last-wins, for backward-compat call-site
        // lookup without arity info) AND `name/N` (arity-qualified, so
        // Pass B always finds the right MethodBuilder when two functions
        // share a name but differ in parameter count).
        let methodTable = Dictionary<string, MethodBuilder>()
        let funcSigsTable = Dictionary<string, ResolvedSignature>()

        // Synthetic helper for cross-assembly union case equality.
        // Comparing nullary union case instances across assemblies with Ceq
        // fails (different objects); calling GetType on both sides and Ceq-ing
        // the Type objects works. We define the helper in the compiled assembly
        // itself so the Call is intra-assembly (no cross-assembly FieldInfo /
        // DeclareLocal ordering issues that crash PersistedAssemblyBuilder).
        // Body: ldarg.0 callvirt GetType ldarg.1 callvirt GetType ceq ret
        let sameTypeHelper =
            let smb =
                programTy.DefineMethod(
                    "__SameType",
                    MethodAttributes.Public ||| MethodAttributes.Static ||| MethodAttributes.HideBySig,
                    typeof<bool>,
                    [| typeof<obj>; typeof<obj> |])
            let ilh = smb.GetILGenerator()
            let getTypeM =
                typeof<obj>.GetMethod("GetType")
                |> Option.ofObj
                |> Option.defaultWith (fun () ->
                    failwith "object.GetType() not found")
            ilh.Emit(OpCodes.Ldarg_0)
            ilh.Emit(OpCodes.Callvirt, getTypeM)
            ilh.Emit(OpCodes.Ldarg_1)
            ilh.Emit(OpCodes.Callvirt, getTypeM)
            ilh.Emit(OpCodes.Ceq)
            ilh.Emit(OpCodes.Ret)
            smb
        methodTable.["__SameType"] <- sameTypeHelper

        for fn in funcs do
            // Prefer arity-qualified key so overloaded functions each get
            // the right resolved signature; fall back to bare name for
            // modules that don't have overloads.
            let arityKey = fn.Name + "/" + string fn.Params.Length
            let sg =
                match Map.tryFind arityKey sigs with
                | Some s -> s
                | None ->
                    match Map.tryFind fn.Name sigs with
                    | Some s -> s
                    | None ->
                        { Generics = []; Bounds = []; Params = []; Return = TyPrim PtUnit
                          IsAsync = false; Span = fn.Span }
            let mb = defineMethodHeader programTy lookup fn sg
            methodTable.[fn.Name]  <- mb
            methodTable.[arityKey] <- mb
            funcSigsTable.[fn.Name]  <- sg
            funcSigsTable.[arityKey] <- sg

        // Fold `pub val` / `pub const` integer constants so they can
        // be referenced by name inside function bodies (e.g. ACC_PUBLIC).
        // Stdlib-artifact constants are folded first so user-side
        // bindings with the same name win on collision.
        let constsTable = Dictionary<string, int64>()
        let foldConstsFrom (items: Item list) (syms: SymbolTable) =
            for it in items do
                match it.Kind with
                | IVal v ->
                    match v.Pattern.Kind with
                    | PBinding (name, _) ->
                        match Lyric.TypeChecker.ConstFold.tryFoldInt syms v.Init with
                        | Ok n  -> constsTable.[name] <- n
                        | Error _ -> ()
                    | _ -> ()
                | IConst c ->
                    match Lyric.TypeChecker.ConstFold.tryFoldInt syms c.Init with
                    | Ok n  -> constsTable.[c.Name] <- n
                    | Error _ -> ()
                | _ -> ()
        for artifact in stdlibArtifacts do
            foldConstsFrom artifact.Source.Items artifact.Symbols
        foldConstsFrom sf.Items symbols

        // Pass A.4b — `@asyncLocal val name: AsyncLocal[T] = ()` declarations.
        //
        // For each `IVal` annotated with `@asyncLocal`, emit a static
        // readonly field of type `AsyncLocal<T>` on `programTy` and
        // initialise it in a type initializer (`.cctor`).  Reading `name`
        // in function bodies then emits `ldsfld <field>` which pushes the
        // `AsyncLocal<T>` singleton.
        //
        // The annotation is purely a hint to the emitter; the `= ()` init
        // expression in the source is ignored — the emitter always calls
        // `new AsyncLocal<T>()` so there is exactly one slot per package.
        //
        // D-progress-stdlib-expand (Group D1, 2026-05): used by
        // `_kernel/task.l` to replace the F# `AmbientSlot.Slot` static.
        let asyncLocalTable = Dictionary<string, System.Reflection.FieldInfo>()
        let asyncLocalVals =
            sf.Items
            |> List.choose (fun it ->
                match it.Kind with
                | IVal v
                    when it.Annotations |> List.exists (fun a ->
                             match a.Name.Segments with
                             | ["asyncLocal"] -> true
                             | _ -> false) ->
                    match v.Pattern.Kind with
                    | PBinding (name, None) ->
                        match v.Type with
                        | Some te -> Some (name, te)
                        | None    -> None
                    | _ -> None
                | _ -> None)
        if not asyncLocalVals.IsEmpty then
            let resolveCtxAl = GenericContext()
            let scratchAl    = ResizeArray<Diagnostic>()
            let cctor = programTy.DefineTypeInitializer()
            let ccil  = cctor.GetILGenerator()
            for (name, te) in asyncLocalVals do
                let lty = Resolver.resolveType symbols resolveCtxAl scratchAl te
                let valueTy = TypeMap.toClrTypeWith lookup lty
                let asyncLocalOpenTy = typedefof<System.Threading.AsyncLocal<_>>
                let asyncLocalTy = asyncLocalOpenTy.MakeGenericType(valueTy)
                let fieldName = "__asynclocal_" + name
                let fb =
                    programTy.DefineField(
                        fieldName,
                        asyncLocalTy,
                        FieldAttributes.Private
                        ||| FieldAttributes.Static
                        ||| FieldAttributes.InitOnly)
                asyncLocalTable.[name] <- fb :> System.Reflection.FieldInfo
                let asyncLocalCtor =
                    match Option.ofObj (asyncLocalTy.GetConstructor([||])) with
                    | Some c -> c
                    | None ->
                        failwithf "AsyncLocal<%s> no-arg ctor not found" valueTy.FullName
                ccil.Emit(OpCodes.Newobj, asyncLocalCtor)
                ccil.Emit(OpCodes.Stsfld, fb)
            ccil.Emit(OpCodes.Ret)

        // Pass A.5 — process impl blocks. For each `impl Foo for Bar`,
        // attach interface methods to Bar's TypeBuilder, both as
        // method headers and as interface implementations via
        // DefineMethodOverride. Bodies emit in Pass B alongside the
        // free-standing funcs.
        let implMethods =
            ResizeArray<FunctionDecl * MethodBuilder * ResolvedSignature>()
        for impl in implItems sf do
            // Resolve the impl's target. M1.4 only handles record
            // targets; impls on opaque/distinct/extern types are
            // tracked into Phase 2.
            // Extract the base name of the target type.  `impl Foo for Bar`
            // has a plain TRef; `impl[T] Foo for Bar[T]` has a TGenericApp
            // with the same base name.
            let targetName =
                match impl.Target.Kind with
                | TRef p ->
                    match p.Segments with
                    | [n] -> Some n
                    | xs  -> Some (List.last xs)
                | TGenericApp (head, _) ->
                    match head.Segments with
                    | [n] -> Some n
                    | xs  -> Some (List.last xs)
                | _ -> None
            let targetRecord =
                match targetName with
                | Some n ->
                    match recordTable.TryGetValue n with
                    | true, r -> Some r
                    | _ -> None
                | None -> None
            let ifaceName =
                match impl.Interface.Head.Segments with
                | [n] -> Some n
                | xs  -> Some (List.last xs)
            let ifaceInfo =
                match ifaceName with
                | Some n ->
                    match interfaceTable.TryGetValue n with
                    | true, i -> Some i
                    | _ -> None
                | None -> None
            match targetRecord, ifaceInfo with
            | Some recInfo, Some iface ->
                recInfo.Type.AddInterfaceImplementation(iface.Type)
                let key : System.Type = recInfo.Type :> _
                let ifaces =
                    match implsTable.TryGetValue key with
                    | true, s -> s
                    | _ ->
                        let s = HashSet<string>()
                        implsTable.[key] <- s
                        s
                ifaces.Add(iface.Name) |> ignore
                let resolveCtx = GenericContext()
                let scratchDiags = ResizeArray<Diagnostic>()
                // Impl-level type parameter names (e.g. T in `impl[T] Foo for Bar[T]`).
                // Push them into resolveCtx so Resolver.resolveType recognises them.
                let implGenericNames : string list =
                    match impl.Generics with
                    | Some gs ->
                        gs.Params
                        |> List.map (function GPType(n, _) | GPValue(n, _, _) -> n)
                    | None -> []
                if not implGenericNames.IsEmpty then resolveCtx.Push implGenericNames
                for m in impl.Members do
                    match m with
                    | IMplFunc fd ->
                        // Method-level type parameter names (e.g. U in `func[U] foo(): U`).
                        let methodGenericNames : string list =
                            match fd.Generics with
                            | Some gs ->
                                gs.Params
                                |> List.map (function GPType(n, _) | GPValue(n, _, _) -> n)
                            | None -> []
                        if not methodGenericNames.IsEmpty then
                            resolveCtx.Push methodGenericNames
                        // synthSig.Generics is ordered [implNames...; methodNames...].
                        // emitFunctionBody's genericSubst rebuilds the substitution using
                        // class GTPBs (impl-level) ++ method GTPBs (method-level) in the
                        // same order.
                        let allGenericNames = implGenericNames @ methodGenericNames
                        // Class-level GTPBs backing the impl generic params.
                        let clsGtpbs : System.Type[] =
                            if implGenericNames.IsEmpty then [||]
                            else recInfo.Type.GetGenericArguments()
                        // Define the method builder.  Generic methods require the
                        // three-step Reflection.Emit pattern: DefineMethod (no sig),
                        // DefineGenericParameters, then SetParameters / SetReturnType.
                        // Non-generic methods can be defined with the full signature
                        // in one call.
                        let mbAndMethGtpbs : (MethodBuilder * System.Type[]) option =
                            if methodGenericNames.IsEmpty then None
                            else
                                let m =
                                    recInfo.Type.DefineMethod(
                                        fd.Name,
                                        MethodAttributes.Public
                                        ||| MethodAttributes.Virtual
                                        ||| MethodAttributes.HideBySig
                                        ||| MethodAttributes.Final)
                                let gtpbs =
                                    m.DefineGenericParameters(
                                        methodGenericNames |> List.toArray)
                                    |> Array.map (fun g -> g :> System.Type)
                                Some (m, gtpbs)
                        let methGtpbs =
                            match mbAndMethGtpbs with
                            | Some (_, gs) -> gs
                            | None         -> [||]
                        // Combined substitution: impl GTPBs first, then method GTPBs.
                        let allGtpbs = Array.append clsGtpbs methGtpbs
                        let genericSubst : Map<string, System.Type> =
                            if allGenericNames.IsEmpty then Map.empty
                            elif allGtpbs.Length >= allGenericNames.Length then
                                allGenericNames
                                |> List.mapi (fun i name -> name, allGtpbs.[i])
                                |> Map.ofList
                            else Map.empty
                        // Impl-method signatures aren't in the type checker's
                        // top-level signature map; resolve each parameter and
                        // the return type directly using the generic subst above.
                        let pTys =
                            fd.Params
                            |> List.map (fun p ->
                                let lty =
                                    Resolver.resolveType
                                        symbols resolveCtx scratchDiags p.Type
                                TypeMap.toClrTypeWithGenerics lookup genericSubst lty)
                            |> List.toArray
                        let bareRet =
                            match fd.Return with
                            | Some t ->
                                let lty =
                                    Resolver.resolveType
                                        symbols resolveCtx scratchDiags t
                                TypeMap.toClrReturnTypeWithGenerics lookup genericSubst lty
                            | None -> typeof<System.Void>
                        let rTy =
                            if fd.IsAsync then toTaskType bareRet else bareRet
                        let mb =
                            match mbAndMethGtpbs with
                            | Some (m, _) ->
                                m.SetParameters pTys
                                m.SetReturnType rTy
                                m
                            | None ->
                                recInfo.Type.DefineMethod(
                                    fd.Name,
                                    MethodAttributes.Public
                                    ||| MethodAttributes.Virtual
                                    ||| MethodAttributes.HideBySig
                                    ||| MethodAttributes.Final,
                                    rTy,
                                    pTys)
                        fd.Params
                        |> List.iteri (fun i p ->
                            mb.DefineParameter(i + 1, ParameterAttributes.None, p.Name)
                            |> ignore)
                        match iface.Members |> List.tryFind (fun im -> im.Name = fd.Name) with
                        | Some im ->
                            recInfo.Type.DefineMethodOverride(mb, im.Method)
                        | None -> ()
                        // Synthesise a ResolvedSignature so the body emitter can use
                        // the same code path.  Generics carries allGenericNames so that
                        // emitFunctionBody rebuilds the correct substitution for the body.
                        let synthSig : ResolvedSignature =
                            { Generics = allGenericNames
                              Bounds   = []
                              Params =
                                fd.Params
                                |> List.map (fun p ->
                                    let lty =
                                        Resolver.resolveType
                                            symbols resolveCtx scratchDiags p.Type
                                    { Name    = p.Name
                                      Type    = lty
                                      Mode    = p.Mode
                                      Default = p.Default.IsSome
                                      Span    = p.Span })
                              Return =
                                match fd.Return with
                                | Some t ->
                                    Resolver.resolveType
                                        symbols resolveCtx scratchDiags t
                                | None -> TyPrim PtUnit
                              IsAsync = fd.IsAsync
                              Span    = fd.Span }
                        implMethods.Add(fd, mb, synthSig)
                        if not methodGenericNames.IsEmpty then resolveCtx.Pop()
                    | IMplAssoc _ -> ()
            | _ ->
                // Target type or interface not in scope — skipped.
                // The type checker has already surfaced a diagnostic.
                ()

        // Pass B — emit bodies (free-standing funcs). Look up the body
        // target by arity-qualified key first so overloaded functions
        // each get their own MethodBuilder body.
        //
        // Async functions that are eligible for Phase A state-machine
        // lowering route through `AsyncStateMachine.defineStateMachine`
        // → kickoff stub on the user's MethodBuilder + a sibling SM
        // class whose MoveNext carries the user's body.  Other async
        // funcs (those with internal `await` or generics) keep the
        // M1.4 `Task.FromResult` path until Phase B lands real
        // suspend/resume.
        let smTypesToFinalize = ResizeArray<TypeBuilder>()
        let mutable smCounter = 0
        for fn in funcs do
            let arityKey = fn.Name + "/" + string fn.Params.Length
            let sg =
                match Map.tryFind arityKey sigs with
                | Some s -> s
                | None ->
                    match Map.tryFind fn.Name sigs with
                    | Some s -> s
                    | None ->
                        { Generics = []; Bounds = []; Params = []; Return = TyPrim PtUnit
                          IsAsync = false; Span = fn.Span }
            let mb =
                match methodTable.TryGetValue arityKey with
                | true, m -> m
                | _       -> methodTable.[fn.Name]
            // Phase A: async funcs whose body has no internal `await`.
            let usePhaseA =
                sg.IsAsync && AsyncStateMachine.isPhaseAEligible fn
            // Stack-spilling rewrite (D-progress-074): when an async
            // body has awaits in non-safe sub-expression positions
            // (`f(await g())`, `1 + await foo()`, …), try to hoist
            // each into a preceding `val __spill_N = await …` binding
            // so the existing Phase B safe-position machinery applies
            // unchanged.  Returns the rewritten function plus a map of
            // spill-local names → inferred Lyric types.
            let sigOfForSpill (name: string) =
                match funcSigsTable.TryGetValue name with
                | true, s -> Some s
                | _ ->
                    match importedFuncTable.TryGetValue name with
                    | true, info -> Some info.Sig
                    | _ -> None
            let stackSpillResult =
                if sg.IsAsync
                   && (not usePhaseA)
                   && fn.Generics.IsNone
                   && (not (fn.Annotations
                           |> List.exists (fun a ->
                               match a.Name.Segments with
                               | ["externTarget"] -> true
                               | _ -> false)))
                   && (not (AsyncStateMachine.isPhaseB fn)) then
                    AsyncStateMachine.tryStackSpill sigOfForSpill fn
                else None
            let fnForPhaseB =
                match stackSpillResult with
                | Some (fn', _) -> fn'
                | None -> fn
            let spillLocalTypes : Map<string, Lyric.TypeChecker.Type> =
                match stackSpillResult with
                | Some (_, tm) -> tm
                | None -> Map.empty
            // Phase B: async funcs with awaits at safe top-level
            // statement positions, whose locals (if any) are simple-
            // name bindings with type annotations we can resolve.
            let phaseBSpecOpt =
                if sg.IsAsync
                   && (not usePhaseA)
                   && AsyncStateMachine.isAsyncSmEligible fnForPhaseB
                   && AsyncStateMachine.isPhaseB fnForPhaseB then
                    match AsyncStateMachine.collectPromotableLocals fnForPhaseB with
                    | None -> None
                    | Some locals ->
                        // Locals must have annotations Phase B can
                        // resolve; without them we don't know the
                        // CLR field type.  Fall back to M1.4 if any
                        // local is unannotated — except for the
                        // synthesised `__spill_*` locals introduced by
                        // the stack-spilling rewrite, whose types come
                        // from `spillLocalTypes`.
                        let resolveCtx = GenericContext()
                        let scratchDiags = ResizeArray<Diagnostic>()
                        let resolved =
                            locals
                            |> List.choose (fun l ->
                                match l.Annotation with
                                | Some te ->
                                    let lty =
                                        Resolver.resolveType
                                            symbols resolveCtx scratchDiags te
                                    Some (l.Name, TypeMap.toClrTypeWith lookup lty)
                                | None ->
                                    match Map.tryFind l.Name spillLocalTypes with
                                    | Some lty ->
                                        Some (l.Name, TypeMap.toClrTypeWith lookup lty)
                                    | None -> None)
                        if List.length resolved = List.length locals then
                            Some resolved
                        else None
                else None

            // For generic async funcs, resolve the user-method GTPBs
            // and build two parallel `name -> Type` substitutions:
            //   * `userGenericSubst` — name → user method's GTPB.
            //     Used to compute the kickoff-context bare return,
            //     param types, and local types (these reference the
            //     user method's own generic params).
            //   * `smGenericSubst` — name → SM's GTPB.  Used to
            //     compute the SM-context types stored on the SM
            //     fields and consumed inside MoveNext.
            // Each substitution is fed through TypeMap with the
            // existing `lookup`.
            let isGenericAsync =
                sg.IsAsync && (not (List.isEmpty sg.Generics))
            let userTypeParamArgs : System.Type[] =
                if isGenericAsync then mb.GetGenericArguments() else [||]
            let userGenericSubst : Map<string, System.Type> =
                if isGenericAsync then
                    sg.Generics
                    |> List.mapi (fun i name ->
                        name, userTypeParamArgs.[i])
                    |> Map.ofList
                else Map.empty
            if usePhaseA then
                smCounter <- smCounter + 1
                let header =
                    AsyncStateMachine.defineStateMachineHeader
                        ctx.Module nsName fn.Name smCounter sg.Generics
                let smGenericSubst : Map<string, System.Type> =
                    if isGenericAsync then
                        sg.Generics
                        |> List.mapi (fun i name ->
                            name, header.GenericParams.[i] :> System.Type)
                        |> Map.ofList
                    else Map.empty
                // SM-side types: fields + bare return reference SM's
                // own generic params (so MoveNext IL writes the open
                // tokens that the JIT closes at runtime).
                let smBareReturn =
                    TypeMap.toClrReturnTypeWithGenerics lookup smGenericSubst sg.Return
                let smParamSpecs =
                    sg.Params
                    |> List.map (fun p ->
                        p.Name, paramClrType lookup smGenericSubst p)
                let sm =
                    AsyncStateMachine.defineStateMachineBody
                        header smBareReturn smParamSpecs []
                // Kickoff-side bare return: substitutes against
                // `userGenericSubst` so the closed builder type's R
                // matches the user method's own GTPB.
                let kickoffBareReturn =
                    TypeMap.toClrReturnTypeWithGenerics lookup userGenericSubst sg.Return
                let argIndices =
                    sg.Params |> List.mapi (fun i _ -> i)
                AsyncStateMachine.emitKickoff mb sm userTypeParamArgs kickoffBareReturn argIndices
                AsyncStateMachine.emitSetStateMachine sm
                emitFunctionBody
                    sm.MoveNext (Some sm) None fn sg lookup
                    methodTable funcSigsTable recordTable enumTable enumCases
                    unionTable unionCaseLookup interfaceTable implsTable distinctTable protectedTable projectableTable
                    importedRecordTable importedUnionTable importedUnionCaseLookup
                    importedFuncTable importedDistinctTypeTable externTypeNames
                    false None
                    programTy symbols constsTable asyncLocalTable codegenDiags
                smTypesToFinalize.Add sm.Type
            elif phaseBSpecOpt.IsSome then
                // Phase B: real `AwaitUnsafeOnCompleted` suspend/resume
                // protocol with state dispatch, exception flow through
                // `SetException`, and locals promoted to fields so
                // values survive cross-resume gaps.
                let localSpecs = phaseBSpecOpt.Value
                smCounter <- smCounter + 1
                let header =
                    AsyncStateMachine.defineStateMachineHeader
                        ctx.Module nsName fn.Name smCounter sg.Generics
                let smGenericSubst : Map<string, System.Type> =
                    if isGenericAsync then
                        sg.Generics
                        |> List.mapi (fun i name ->
                            name, header.GenericParams.[i] :> System.Type)
                        |> Map.ofList
                    else Map.empty
                let smBareReturn =
                    TypeMap.toClrReturnTypeWithGenerics lookup smGenericSubst sg.Return
                let smParamSpecs =
                    sg.Params
                    |> List.map (fun p ->
                        p.Name, paramClrType lookup smGenericSubst p)
                let sm =
                    AsyncStateMachine.defineStateMachineBody
                        header smBareReturn smParamSpecs localSpecs
                let kickoffBareReturn =
                    TypeMap.toClrReturnTypeWithGenerics lookup userGenericSubst sg.Return
                let argIndices =
                    sg.Params |> List.mapi (fun i _ -> i)
                AsyncStateMachine.emitKickoff mb sm userTypeParamArgs kickoffBareReturn argIndices
                AsyncStateMachine.emitSetStateMachine sm
                // MoveNext — emit structural code (promote-load,
                // dispatch, try/catch, SetResult) around the body.
                let il = sm.MoveNext.GetILGenerator()
                // Pre-allocate IL locals for promoted locals.  The
                // body emit's `defineLocal` consumes these so the
                // user's `val name : T = expr` reuses the same slot
                // every MoveNext invocation.
                let promotedShadows = ResizeArray<LocalBuilder * FieldBuilder>()
                let preLocals = Dictionary<string, LocalBuilder>()
                for pl in sm.PromotedLocals do
                    let lb = il.DeclareLocal(pl.LocalType)
                    promotedShadows.Add(lb, pl.LocalField)
                    preLocals.[pl.LocalName] <- lb
                // Define labels.
                let awaitCount =
                    AsyncStateMachine.collectAwaitInners fnForPhaseB |> List.length
                let resumeLabels =
                    Array.init awaitCount (fun _ -> il.DefineLabel())
                let bodyStartLabel = il.DefineLabel()
                let dispatchLabel = il.DefineLabel()
                let normalDoneLabel = il.DefineLabel()
                let afterTryLabel = il.DefineLabel()
                // Pre-allocate result local for non-void returns.
                let phaseBResultLocal =
                    if sm.IsVoid then None
                    else Some (il.DeclareLocal(smBareReturn))
                // Promote-load: SM fields → IL locals.
                for (lb, fld) in promotedShadows do
                    il.Emit(OpCodes.Ldarg_0)
                    il.Emit(OpCodes.Ldfld, fld)
                    il.Emit(OpCodes.Stloc, lb)
                // Open try.
                il.BeginExceptionBlock() |> ignore
                // Br dispatch — defers state-dispatch emit until
                // after the body so we can emit resume labels into
                // the body inline.
                il.Emit(OpCodes.Br, dispatchLabel)
                // Body start.
                il.MarkLabel(bodyStartLabel)
                // SmAwaitInfo for the body.
                let smAwaitInfo : AsyncStateMachine.SmAwaitInfo =
                    { Sm                = sm
                      NextAwaitIndex    = 0
                      AwaiterFields     = Dictionary()
                      ResumeLabels      = resumeLabels
                      SuspendLeaveLabel = afterTryLabel
                      PromotedShadows   = promotedShadows }
                let phaseBExit : PhaseBExit =
                    { NormalDone  = normalDoneLabel
                      AwaitInfo   = smAwaitInfo
                      PreLocals   = preLocals
                      ResultLocal = phaseBResultLocal }
                emitFunctionBody
                    sm.MoveNext (Some sm) (Some phaseBExit) fnForPhaseB sg lookup
                    methodTable funcSigsTable recordTable enumTable enumCases
                    unionTable unionCaseLookup interfaceTable implsTable distinctTable protectedTable projectableTable
                    importedRecordTable importedUnionTable importedUnionCaseLookup
                    importedFuncTable importedDistinctTypeTable externTypeNames
                    false None
                    programTy symbols constsTable asyncLocalTable codegenDiags
                // Dispatch.
                il.MarkLabel(dispatchLabel)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldfld, sm.State)
                il.Emit(OpCodes.Switch, resumeLabels)
                il.Emit(OpCodes.Br, bodyStartLabel)
                // Catch.
                il.BeginCatchBlock(typeof<System.Exception>)
                let exLocal = il.DeclareLocal(typeof<System.Exception>)
                il.Emit(OpCodes.Stloc, exLocal)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldc_I4, -2)
                il.Emit(OpCodes.Stfld, sm.State)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldflda, sm.Builder)
                il.Emit(OpCodes.Ldloc, exLocal)
                let setException = AsyncStateMachine.builderMember sm "SetException"
                il.Emit(OpCodes.Call, setException)
                il.Emit(OpCodes.Leave, afterTryLabel)
                il.EndExceptionBlock()
                // Normal done: SetResult.
                il.MarkLabel(normalDoneLabel)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldc_I4, -2)
                il.Emit(OpCodes.Stfld, sm.State)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldflda, sm.Builder)
                match phaseBResultLocal with
                | Some loc -> il.Emit(OpCodes.Ldloc, loc)
                | None     -> ()
                let setResult = AsyncStateMachine.builderMember sm "SetResult"
                il.Emit(OpCodes.Call, setResult)
                il.Emit(OpCodes.Br, afterTryLabel)
                // After try.
                il.MarkLabel(afterTryLabel)
                il.Emit(OpCodes.Ret)
                smTypesToFinalize.Add sm.Type
            else
                emitFunctionBody
                    mb None None fn sg lookup
                    methodTable funcSigsTable recordTable enumTable enumCases
                    unionTable unionCaseLookup interfaceTable implsTable distinctTable protectedTable projectableTable
                    importedRecordTable importedUnionTable importedUnionCaseLookup
                    importedFuncTable importedDistinctTypeTable externTypeNames
                    false None
                    programTy symbols constsTable asyncLocalTable codegenDiags

        // Pass B.5 — emit impl-method bodies as instance methods.
        // Async impl methods route through the SM path the same way
        // free-standing async funcs do (D-progress-038), with one
        // adjustment: `self` becomes the SM's first param-field, and
        // the kickoff (which runs as the user's impl method) copies
        // `Ldarg.0` (this = the record) into `sm.self` before
        // calling `builder.Start`.  Inside MoveNext, `ESelf` resolves
        // via `SmFields["self"]` → `Ldarg.0; Ldfld <self>`.
        for (fd, mb, sg) in implMethods do
            let selfTy = mb.DeclaringType
            let selfTyNonNull : System.Type =
                match Option.ofObj selfTy with
                | Some t -> t
                | None   -> typeof<obj>
            // Rebuild the generic substitution used in body emission.
            // sg.Generics is ordered [implNames...; methodNames...] per Pass A.5.
            // Class GTPBs cover the impl-level names; method GTPBs cover the
            // method-level names.
            let implMethodGenericSubst : Map<string, System.Type> =
                if sg.Generics.IsEmpty then Map.empty
                else
                    let methGtpbs = mb.GetGenericArguments()
                    let clsGtpbs =
                        if selfTyNonNull.IsGenericType then
                            selfTyNonNull.GetGenericArguments()
                        else [||]
                    let allGtpbs = Array.append clsGtpbs methGtpbs
                    if allGtpbs.Length >= sg.Generics.Length then
                        sg.Generics
                        |> List.mapi (fun i name -> name, allGtpbs.[i])
                        |> Map.ofList
                    else Map.empty
            let asyncSmEligible =
                sg.IsAsync
                && AsyncStateMachine.isAsyncSmEligible fd
                && sg.Generics.IsEmpty   // SM path deferred for generic impl methods
                && (not (isNull selfTy))
            // Phase A — impl method, await-free body.
            let usePhaseA =
                asyncSmEligible
                && AsyncStateMachine.isPhaseAEligible fd
            // Phase B — impl method, awaits at safe positions.
            let phaseBSpecOpt =
                if asyncSmEligible
                   && (not usePhaseA)
                   && AsyncStateMachine.isPhaseB fd then
                    match AsyncStateMachine.collectPromotableLocals fd with
                    | None -> None
                    | Some locals ->
                        let resolveCtx = GenericContext()
                        let scratchDiags = ResizeArray<Diagnostic>()
                        let resolved =
                            locals
                            |> List.choose (fun l ->
                                match l.Annotation with
                                | Some te ->
                                    let lty =
                                        Resolver.resolveType
                                            symbols resolveCtx scratchDiags te
                                    Some (l.Name, TypeMap.toClrTypeWith lookup lty)
                                | None -> None)
                        if List.length resolved = List.length locals then
                            Some resolved
                        else None
                else None
            // Common: build the prepended-self paramSpecs using the
            // generic substitution so T / U in param types resolve to
            // the right GTPBs.
            let buildParamSpecs () =
                ("self", selfTyNonNull)
                :: (sg.Params
                    |> List.map (fun p ->
                        p.Name, paramClrType lookup implMethodGenericSubst p))

            if usePhaseA then
                let bareReturn = TypeMap.toClrReturnTypeWith lookup sg.Return
                let paramSpecs = buildParamSpecs()
                smCounter <- smCounter + 1
                let sm =
                    AsyncStateMachine.defineStateMachine
                        ctx.Module nsName ("self_" + fd.Name) smCounter
                        bareReturn paramSpecs []
                let argIndices = paramSpecs |> List.mapi (fun i _ -> i)
                AsyncStateMachine.emitKickoff mb sm [||] sm.BareReturn argIndices
                AsyncStateMachine.emitSetStateMachine sm
                emitFunctionBody
                    sm.MoveNext (Some sm) None fd sg lookup
                    methodTable funcSigsTable recordTable enumTable enumCases
                    unionTable unionCaseLookup interfaceTable implsTable distinctTable protectedTable projectableTable
                    importedRecordTable importedUnionTable importedUnionCaseLookup
                    importedFuncTable importedDistinctTypeTable externTypeNames
                    false None
                    programTy symbols constsTable asyncLocalTable codegenDiags
                smTypesToFinalize.Add sm.Type
            elif phaseBSpecOpt.IsSome then
                // Phase B for impl methods — same shape as the
                // free-standing Phase B path with `("self", recordTy)`
                // prepended to paramSpecs so the kickoff populates
                // sm.self from `Ldarg.0` (this).
                let localSpecs = phaseBSpecOpt.Value
                let bareReturn = TypeMap.toClrReturnTypeWith lookup sg.Return
                let paramSpecs = buildParamSpecs()
                smCounter <- smCounter + 1
                let sm =
                    AsyncStateMachine.defineStateMachine
                        ctx.Module nsName ("self_" + fd.Name) smCounter
                        bareReturn paramSpecs localSpecs
                let argIndices = paramSpecs |> List.mapi (fun i _ -> i)
                AsyncStateMachine.emitKickoff mb sm [||] sm.BareReturn argIndices
                AsyncStateMachine.emitSetStateMachine sm
                let il = sm.MoveNext.GetILGenerator()
                let promotedShadows = ResizeArray<LocalBuilder * FieldBuilder>()
                let preLocals = Dictionary<string, LocalBuilder>()
                for pl in sm.PromotedLocals do
                    let lb = il.DeclareLocal(pl.LocalType)
                    promotedShadows.Add(lb, pl.LocalField)
                    preLocals.[pl.LocalName] <- lb
                let awaitCount =
                    AsyncStateMachine.collectAwaitInners fd |> List.length
                let resumeLabels =
                    Array.init awaitCount (fun _ -> il.DefineLabel())
                let bodyStartLabel = il.DefineLabel()
                let dispatchLabel = il.DefineLabel()
                let normalDoneLabel = il.DefineLabel()
                let afterTryLabel = il.DefineLabel()
                let phaseBResultLocal =
                    if sm.IsVoid then None
                    else Some (il.DeclareLocal(bareReturn))
                for (lb, fld) in promotedShadows do
                    il.Emit(OpCodes.Ldarg_0)
                    il.Emit(OpCodes.Ldfld, fld)
                    il.Emit(OpCodes.Stloc, lb)
                il.BeginExceptionBlock() |> ignore
                il.Emit(OpCodes.Br, dispatchLabel)
                il.MarkLabel(bodyStartLabel)
                let smAwaitInfo : AsyncStateMachine.SmAwaitInfo =
                    { Sm                = sm
                      NextAwaitIndex    = 0
                      AwaiterFields     = Dictionary()
                      ResumeLabels      = resumeLabels
                      SuspendLeaveLabel = afterTryLabel
                      PromotedShadows   = promotedShadows }
                let phaseBExit : PhaseBExit =
                    { NormalDone  = normalDoneLabel
                      AwaitInfo   = smAwaitInfo
                      PreLocals   = preLocals
                      ResultLocal = phaseBResultLocal }
                emitFunctionBody
                    sm.MoveNext (Some sm) (Some phaseBExit) fd sg lookup
                    methodTable funcSigsTable recordTable enumTable enumCases
                    unionTable unionCaseLookup interfaceTable implsTable distinctTable protectedTable projectableTable
                    importedRecordTable importedUnionTable importedUnionCaseLookup
                    importedFuncTable importedDistinctTypeTable externTypeNames
                    false None
                    programTy symbols constsTable asyncLocalTable codegenDiags
                il.MarkLabel(dispatchLabel)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldfld, sm.State)
                il.Emit(OpCodes.Switch, resumeLabels)
                il.Emit(OpCodes.Br, bodyStartLabel)
                il.BeginCatchBlock(typeof<System.Exception>)
                let exLocal = il.DeclareLocal(typeof<System.Exception>)
                il.Emit(OpCodes.Stloc, exLocal)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldc_I4, -2)
                il.Emit(OpCodes.Stfld, sm.State)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldflda, sm.Builder)
                il.Emit(OpCodes.Ldloc, exLocal)
                let setException = AsyncStateMachine.builderMember sm "SetException"
                il.Emit(OpCodes.Call, setException)
                il.Emit(OpCodes.Leave, afterTryLabel)
                il.EndExceptionBlock()
                il.MarkLabel(normalDoneLabel)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldc_I4, -2)
                il.Emit(OpCodes.Stfld, sm.State)
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldflda, sm.Builder)
                match phaseBResultLocal with
                | Some loc -> il.Emit(OpCodes.Ldloc, loc)
                | None     -> ()
                let setResult = AsyncStateMachine.builderMember sm "SetResult"
                il.Emit(OpCodes.Call, setResult)
                il.Emit(OpCodes.Br, afterTryLabel)
                il.MarkLabel(afterTryLabel)
                il.Emit(OpCodes.Ret)
                smTypesToFinalize.Add sm.Type
            else
                emitFunctionBody
                    mb None None fd sg lookup
                    methodTable funcSigsTable recordTable enumTable enumCases
                    unionTable unionCaseLookup interfaceTable implsTable distinctTable protectedTable projectableTable
                    importedRecordTable importedUnionTable importedUnionCaseLookup
                    importedFuncTable importedDistinctTypeTable externTypeNames
                    true
                    (Option.ofObj selfTy) programTy symbols constsTable asyncLocalTable codegenDiags

        // Pass B.6 — emit protected-type method bodies (D-progress-079).
        //
        // Two methods per entry/func:
        //   * `<unsafe>__<name>`: emitted via `emitFunctionBody` so
        //     contracts / control flow / async / FFI all behave
        //     uniformly with regular impl-method bodies.  Runs WITH
        //     the lock held — its caller (the public wrapper) handles
        //     the Monitor.Enter/Exit pair.
        //   * Public `<name>` wrapper: hand-emitted IL that loads
        //     `this.<>__lock`, calls Monitor.Enter, opens a try, calls
        //     the unsafe inner with the user's args, stashes the
        //     return value (if any) in a local, leaves to an exit
        //     label, and releases the lock in a finally.  The
        //     `leave`-out-of-try shape sidesteps the CLR rule that
        //     forbids `ret` inside a protected region.
        for p in protectedPending do
            // Emit the unsafe inner via the regular function-body
            // pipeline.  `isInstance = true`, `selfType` = the
            // protected type.
            emitFunctionBody
                p.UnsafeMb None None p.Fn p.Sg lookup
                methodTable funcSigsTable recordTable enumTable enumCases
                unionTable unionCaseLookup interfaceTable implsTable distinctTable protectedTable projectableTable
                importedRecordTable importedUnionTable importedUnionCaseLookup
                importedFuncTable importedDistinctTypeTable externTypeNames
                true
                (Some (p.Owner.Type :> System.Type)) programTy symbols constsTable asyncLocalTable codegenDiags

            // Emit the public wrapper.  Pattern (with barriers +
            // invariants from D-progress-079 follow-ups):
            //
            //     Monitor.Enter(this.<>__lock)
            //     .try {
            //       <when: barrier checks — throw if false>
            //       result = <unsafe>__name(this, args...)
            //       <invariant: checks — throw if false>
            //       leave end
            //     } finally {
            //       Monitor.Exit(this.<>__lock)
            //     }
            //   end:
            //     [ldloc result]
            //     ret
            let il = p.PublicMb.GetILGenerator()
            let returnsValue = p.ReturnType <> typeof<System.Void>
            let resultLocal =
                if returnsValue then Some (il.DeclareLocal(p.ReturnType))
                else None
            let endLabel = il.DefineLabel()

            // Build a FunctionCtx for the wrapper so the barrier /
            // invariant expressions (which reference `self.<field>`
            // after desugaring) lower correctly.  Param names map
            // 1:1 to CLR arg slots — `argShift = 1` for `this`.
            let wrapResolveCtx = GenericContext()
            let wrapScratchDiags = ResizeArray<Diagnostic>()
            let wrapResolveType (te: TypeExpr) : System.Type =
                let lty =
                    Resolver.resolveType
                        symbols wrapResolveCtx wrapScratchDiags te
                TypeMap.toClrTypeWith lookup lty
            let wrapParams =
                List.zip p.Fn.Params (List.ofArray p.ParamTypes)
                |> List.map (fun (par, ty) -> par.Name, ty)
            let wrapCtx =
                Codegen.FunctionCtx.make
                    il p.ReturnType wrapParams
                    methodTable funcSigsTable recordTable
                    enumTable enumCases
                    unionTable unionCaseLookup
                    interfaceTable implsTable distinctTable protectedTable
                    projectableTable
                    importedRecordTable importedUnionTable
                    importedUnionCaseLookup
                    importedFuncTable importedDistinctTypeTable
                    externTypeNames
                    true (Some (p.Owner.Type :> System.Type))
                    programTy wrapResolveType lookup constsTable asyncLocalTable codegenDiags

            // Generic-type self-references: when emitting IL inside a
            // generic class, member references (Ldfld <>__lock,
            // Call <unsafe>__name) must target the type instantiated
            // on its own GTPBs — not the open generic definition.
            // `TypeBuilder.GetField` / `GetMethod` rebind the open
            // FieldBuilder / MethodBuilder onto the constructed-on-own-
            // GTPBs type so the JIT closes them correctly when called
            // on an actual closed instance.
            let lockFieldRef : System.Reflection.FieldInfo =
                if p.Owner.Generics.IsEmpty then
                    p.LockField :> System.Reflection.FieldInfo
                else
                    let openDef = p.Owner.Type :> System.Type
                    let selfClosed =
                        openDef.MakeGenericType(openDef.GetGenericArguments())
                    System.Reflection.Emit.TypeBuilder.GetField(
                        selfClosed, p.LockField)
            let unsafeMethodRef : System.Reflection.MethodInfo =
                if p.Owner.Generics.IsEmpty then
                    p.UnsafeMb :> System.Reflection.MethodInfo
                else
                    let openDef = p.Owner.Type :> System.Type
                    let selfClosed =
                        openDef.MakeGenericType(openDef.GetGenericArguments())
                    System.Reflection.Emit.TypeBuilder.GetMethod(
                        selfClosed, p.UnsafeMb)

            // Acquire lock per Q008's tri-modal split:
            //   * `PLMonitor` (D-progress-087): `Monitor.Enter`.
            //   * `PLRwLock` (D-progress-081): `EnterWriteLock` for
            //     entries, `EnterReadLock` for funcs.
            //   * `PLSemaphore` (D-progress-083): `Wait()`.
            let acquireMI, releaseMI =
                match p.Owner.LockFlavour with
                | Records.PLMonitor ->
                    monitorEnterMI.Value, monitorExitMI.Value
                | Records.PLRwLock ->
                    let acq =
                        if p.IsEntry then rwEnterWriteMI.Value
                        else rwEnterReadMI.Value
                    let rel =
                        if p.IsEntry then rwExitWriteMI.Value
                        else rwExitReadMI.Value
                    acq, rel
                | Records.PLSemaphore ->
                    semaphoreWaitMI.Value, semaphoreReleaseMI.Value
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldfld, lockFieldRef)
            il.Emit(OpCodes.Call, acquireMI)

            // Open try.
            il.BeginExceptionBlock() |> ignore

            // Barriers (`when: <cond>` clauses):
            //   * `PLMonitor`: emit a wait-loop that re-evaluates each
            //     barrier under the held Monitor; on false, calls
            //     `Monitor.Wait(lock)` (infinite — Ada semantics) and
            //     re-checks when signalled via PulseAll.
            //     D-progress-087, D-progress-092.
            //   * Other flavours: barriers can't appear (lock-flavour
            //     selection routes any barrier-bearing type to
            //     `PLMonitor`), so the loop is unused.
            if p.Owner.LockFlavour = Records.PLMonitor
               && not (List.isEmpty p.Barriers) then
                let checkLabel = il.DefineLabel()
                let bodyLabel  = il.DefineLabel()
                let waitLabel  = il.DefineLabel()
                il.MarkLabel checkLabel
                // Evaluate every barrier; on the first false, branch
                // to the wait sub-block.  All-true falls through to
                // bodyLabel.
                for barrier in p.Barriers do
                    let _ = Codegen.emitExpr wrapCtx barrier
                    il.Emit(OpCodes.Brfalse, waitLabel)
                il.Emit(OpCodes.Br, bodyLabel)
                // Wait sub-block: Monitor.Wait(lock) suspends the
                // caller (releasing the lock) until another thread
                // calls PulseAll, then re-acquires the lock and
                // returns true.  We discard the return value and
                // always loop back — spurious wakeups are safe
                // because the barrier is re-evaluated each time.
                // Ada specifies infinite waits; the caller is
                // responsible for progress (D-progress-092).
                il.MarkLabel waitLabel
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldfld, lockFieldRef)
                il.Emit(OpCodes.Call, monitorWaitMI.Value)
                il.Emit(OpCodes.Pop)   // discard bool return value
                il.Emit(OpCodes.Br, checkLabel)
                il.MarkLabel bodyLabel
            else
                for barrier in p.Barriers do
                    emitContractCheck wrapCtx barrier
                        (sprintf "%s: barrier failed" p.Fn.Name)

            // Forward `this` + each arg to the unsafe inner.
            il.Emit(OpCodes.Ldarg_0)
            for i in 0 .. p.ParamTypes.Length - 1 do
                il.Emit(OpCodes.Ldarg, i + 1)
            il.Emit(OpCodes.Call, unsafeMethodRef)

            // Stash the return value (if any) so finally can run
            // before we propagate it.
            match resultLocal with
            | Some loc -> il.Emit(OpCodes.Stloc, loc)
            | None     -> ()

            // Invariant checks — every protected-type-level
            // `invariant: <cond>` is re-evaluated after the entry/
            // func body returns (still inside the lock).  Per
            // §7.4 of the language reference, an invariant
            // violation is an unrecoverable bug.
            for inv in p.Invariants do
                emitContractCheck wrapCtx inv
                    (sprintf "%s: invariant failed" p.Owner.Name)

            // PLMonitor entries call `Monitor.PulseAll` after the body
            // so any callers blocked on a barrier wake and re-check
            // their conditions.  Funcs don't pulse — they don't mutate
            // state, so no barrier could newly become true.
            if p.Owner.LockFlavour = Records.PLMonitor && p.IsEntry then
                il.Emit(OpCodes.Ldarg_0)
                il.Emit(OpCodes.Ldfld, lockFieldRef)
                il.Emit(OpCodes.Call, monitorPulseAllMI.Value)

            // Leave to the post-try region.
            il.Emit(OpCodes.Leave, endLabel)

            // Finally: release the lock in matching mode.
            il.BeginFinallyBlock()
            il.Emit(OpCodes.Ldarg_0)
            il.Emit(OpCodes.Ldfld, lockFieldRef)
            match p.Owner.LockFlavour with
            | Records.PLMonitor   -> il.Emit(OpCodes.Call, releaseMI)
            | _                   -> il.Emit(OpCodes.Callvirt, releaseMI)
            il.EndExceptionBlock()

            // End label, then load result + ret.
            il.MarkLabel endLabel
            match resultLocal with
            | Some loc -> il.Emit(OpCodes.Ldloc, loc)
            | None     -> ()
            il.Emit(OpCodes.Ret)

        // Pass B.7 — finish protected-type ctors with field
        // initializers + Ret (D-progress-079 follow-up).  Pass A
        // emitted the ctor prologue (`base ctor` call + lock alloc)
        // but left the IL generator open so the user-written field
        // init expressions can be lowered with a real FunctionCtx
        // in scope.  Each `var x: T = expr` initialiser becomes
        // `Ldarg.0; <emit expr>; Stfld x` here.
        for cp in protectedCtorsPending do
            let cil = cp.Ctor.GetILGenerator()
            if not (List.isEmpty cp.Initializers) then
                let resolveCtxCtor = GenericContext()
                let scratchDiagsCtor = ResizeArray<Diagnostic>()
                let resolveTypeForCtorCtx (te: TypeExpr) : System.Type =
                    let lty =
                        Resolver.resolveType
                            symbols resolveCtxCtor scratchDiagsCtor te
                    TypeMap.toClrTypeWith lookup lty
                let ctorCtx =
                    Codegen.FunctionCtx.make
                        cil typeof<System.Void> []
                        methodTable funcSigsTable recordTable
                        enumTable enumCases
                        unionTable unionCaseLookup
                        interfaceTable implsTable distinctTable protectedTable
                        projectableTable
                        importedRecordTable importedUnionTable
                        importedUnionCaseLookup
                        importedFuncTable importedDistinctTypeTable
                        externTypeNames
                        true (Some (cp.Owner.Type :> System.Type))
                        programTy resolveTypeForCtorCtx lookup constsTable asyncLocalTable codegenDiags
                for (name, fb, expr) in cp.Initializers do
                    // Set the field's CLR type as the ExpectedType hint
                    // so generic constructors like `newList()` in
                    // `var tasks: List[Task] = newList()` infer `T =
                    // Task` from the declared field type.
                    let savedExpected = ctorCtx.ExpectedType
                    ctorCtx.ExpectedType <- Some fb.FieldType
                    cil.Emit(OpCodes.Ldarg_0)
                    let _ = Codegen.emitExpr ctorCtx expr
                    ctorCtx.ExpectedType <- savedExpected
                    cil.Emit(OpCodes.Stfld, fb)
            cil.Emit(OpCodes.Ret)

        let lyricMainOpt =
            if isLibrary then None
            else
                match methodTable.TryGetValue "main" with
                | true, m -> Some m
                | _       -> None
        let hostMainOpt =
            lyricMainOpt
            |> Option.map (fun m -> defineHostEntryPoint programTy m)
        // Project-as-DLL: hand the host-main wrapper back to the
        // caller so `emitProject` can wire it through `Backend.save`
        // as the bundled assembly's entry point.  No-op for the
        // single-package flow (`mainOut = None`), and harmless when
        // `hostMainOpt = None` (library-shaped emit).
        match mainOut with
        | Some r ->
            match hostMainOpt with
            | Some hm -> r.Value <- Some (hm :> MethodInfo)
            | None    -> ()
        | None -> ()

        // Finalise every type so the persisted PE captures their
        // metadata. Interfaces seal first so records can claim them;
        // unions seal the abstract base before subclasses so that
        // recursive case fields (e.g. JArray.elem: JvmType) resolve
        // to a completed parent MethodTable.
        let recordSealed (ty: System.Type) =
            // Project-as-DLL: feed each sealed type into the
            // caller-supplied lookup table so cross-package emit can
            // resolve names against this package's surface.  Builder
            // types may have a null `FullName` mid-construction; skip
            // those — they're internal helpers (e.g. nested closure
            // classes) that downstream packages don't reference.
            match typesOut with
            | None -> ()
            | Some d ->
                match Option.ofObj ty.FullName with
                | Some fn when not (d.ContainsKey fn) -> d.[fn] <- ty
                | _ -> ()
        for kv in interfaceTable do
            recordSealed (kv.Value.Type.CreateType())
        for kv in recordTable do
            recordSealed (kv.Value.Type.CreateType())
        for kv in unionTable do
            recordSealed (kv.Value.Type.CreateType())
            for c in kv.Value.Cases do
                recordSealed (c.Type.CreateType())
        // Async state-machine types — created before programTy so the
        // kickoff stubs in programTy can resolve their references at
        // runtime.
        for smTy in smTypesToFinalize do
            recordSealed (smTy.CreateType())
        recordSealed (programTy.CreateType())
        if ownsCtx then
            // Sole owner of the backend — drive save + per-package
            // contract embedding here.  Project-as-DLL callers
            // (`emitProject`) own the backend, supply
            // `sharedCtx = Some _`, and run save + N contract embeds
            // themselves once every package's emit has completed.
            Backend.save ctx (hostMainOpt |> Option.map (fun m -> m :> MethodInfo))
            // Embed the `Lyric.Contract` managed resource describing this
            // assembly's `pub` surface.  Cross-package consumption + the
            // future `lyric public-api-diff` / `lyric search` tooling
            // reads it via `ContractMeta.readFromAssembly`.  Best-effort:
            // a Cecil failure shouldn't fail the build (the IL is
            // already on disk); surface as a non-fatal warning if it
            // happens.
            try
                let contract = ContractMeta.buildContract sf "0.1.0"
                ContractMeta.embedIntoAssembly req.OutputPath (ContractMeta.toJson contract)
            with e ->
                codegenDiags.Add
                    { Severity = DiagWarning
                      Code     = "E0900"
                      Message  =
                        sprintf "could not embed Lyric.Contract resource: %s" e.Message
                      Span     = sf.Span }
            // Also embed the proof-only `Lyric.Proof` binary resource
            // (D-progress-086).  Same best-effort guard as above; the
            // resource is verifier-internal and a missing one only
            // degrades cross-package proofs.
            try
                let proofMeta = ProofMeta.buildProofMeta sf "0.1.0"
                ProofMeta.embedIntoAssembly req.OutputPath (ProofMeta.toBytes proofMeta)
            with e ->
                codegenDiags.Add
                    { Severity = DiagWarning
                      Code     = "E0901"
                      Message  =
                        sprintf "could not embed Lyric.Proof resource: %s" e.Message
                      Span     = sf.Span }
        List.ofSeq codegenDiags

// ---------------------------------------------------------------------------
// Stdlib precompilation.
//
// Each `Std.X` module compiles once per process into its own DLL
// (`Lyric.Stdlib.<X>.dll`) and is cached in memory.  When a stdlib
// module imports another stdlib module, the importer's emit gets the
// importee as a previously-compiled artifact so cross-assembly
// references resolve.  User-side `import Std.X` walks the closure of
// stdlib deps and hands all visited artifacts to the emitter.
// ---------------------------------------------------------------------------

/// Cache: package key (e.g. `"Std.Core"`) → compiled artifact.
let private stdlibArtifactCache : Dictionary<string, StdlibArtifact> = Dictionary()
let private stdlibLock : obj = obj()

/// Convert a `RestoredPackages.RestoredArtifact` to the internal
/// `StdlibArtifact` shape so a pre-built binary `Lyric.Stdlib.dll`
/// can be consumed by the same import pipeline as source-compiled artifacts.
let private restoredToStdlib (ra: RestoredPackages.RestoredArtifact) : StdlibArtifact =
    let asm = ra.Assembly
    { AssemblyPath = ra.AssemblyPath
      Assembly     = Some asm
      Source       = ra.Source
      Symbols      = ra.Symbols
      Signatures   = ra.Signatures
      Lookup       = fun n -> Option.ofObj (asm.GetType n) }

/// The shared cache directory for compiled stdlib artifacts.  Per-
/// process so concurrent test runs don't trample each other.
let private stdlibCacheDir : string =
    let pid = System.Diagnostics.Process.GetCurrentProcess().Id
    let dir = Path.Combine(Path.GetTempPath(), sprintf "lyric-stdlib-%d" pid)
    Directory.CreateDirectory dir |> ignore
    dir

let private packageKey (segments: string list) : string =
    String.concat "." segments

/// Map a Lyric package segment like `EnvironmentHost` to its `.l`
/// file basename `environment_host` (camel → snake_case lowercase).
let private segmentToFileBase (seg: string) : string =
    let sb = System.Text.StringBuilder()
    seg
    |> Seq.iteri (fun i c ->
        if i > 0 && System.Char.IsUpper c then sb.Append('_') |> ignore
        sb.Append(System.Char.ToLowerInvariant c) |> ignore)
    sb.ToString()

/// True for any top-level package whose source lives under `lyric/<head.lower>/`
/// in the source tree.  Add new built-in top-level packages here.
/// `Testpkg` is reserved for `Lyric.Emitter.Tests.MultiFilePackageTests`,
/// which uses the `LYRIC_TESTPKG_PATH` env-var override to point at a
/// synthetic temp-directory package — there is no real `Testpkg`
/// directory shipped with the compiler.
let private isBuiltinHead (head: string) : bool =
    head = "Std" || head = "Jvm" || head = "Lyric" || head = "Testpkg" || head = "Msil"

/// Locate the `.l` source files for any built-in package.  Two
/// shapes are accepted (per `docs/19-multi-file-packages.md`):
///
///   * Single-file: `<root>/<basename>.l` — the legacy form.
///   * Multi-file: `<root>/<basename>/*.l` — every `.l` file in the
///     directory belongs to the same package; the emitter merges
///     their declarations into one symbol table at compile time.
///
/// Search order:
///   1. Package-specific env-var override: `LYRIC_STD_PATH` for `Std`,
///      `LYRIC_JVM_PATH` for `Jvm`, `LYRIC_<HEAD>_PATH` for others.
///   2. Walk up the directory tree from `startDir` (the CLI binary's
///      base directory).  For `Std.*` look for `stdlib/std/`; for
///      other builtins look for `lyric/<head.lower>/`.
///
/// Variant of `locateBuiltinFiles` that also reports a layout-conflict
/// diagnostic (B0010) when both the single-file and multi-file forms
/// of the package exist in the same root.  In that case the
/// single-file form's path list still returns (so the build keeps
/// progressing in case the diagnostic gets demoted), and the caller
/// is responsible for surfacing the diagnostic to the user.
let private locateBuiltinFilesWithLayout
        (startDir: string)
        (target: CompileTarget)
        (segments: string list) : string list * Diagnostic option =
    let firstHit (probes: (unit -> string list) list) : string list =
        let rec go xs =
            match xs with
            | [] -> []
            | f :: rest ->
                let hits = f ()
                if List.isEmpty hits then go rest else hits
        go probes
    let listLyricFiles (dir: string) : string list =
        if Directory.Exists dir then
            Directory.GetFiles(dir, "*.l")
            |> Array.sort
            |> Array.toList
        else []
    match segments with
    | head :: rest when not (List.isEmpty rest) ->
        let dirName = head.ToLower()
        let baseName =
            rest
            |> List.map segmentToFileBase
            |> String.concat "_"
        let fileName = baseName + ".l"
        let pkgKey = String.concat "." segments
        // Detect layout conflict (B0010) in a given root: both
        // `<root>/<base>.l` and `<root>/<base>/*.l` exist.  Same
        // check is run against the active kernel sub-root too.
        let kernelDir = if target = Jvm then "_kernel_jvm" else "_kernel"
        let layoutConflict (root: string) : Diagnostic option =
            let single = Path.Combine(root, fileName)
            let multi  = Path.Combine(root, baseName)
            let kernelSingle = Path.Combine(root, kernelDir, fileName)
            let kernelMulti  = Path.Combine(root, kernelDir, baseName)
            let confl =
                if File.Exists single
                   && Directory.Exists multi
                   && not (Array.isEmpty (Directory.GetFiles(multi, "*.l"))) then
                    Some "top-level"
                elif File.Exists kernelSingle
                     && Directory.Exists kernelMulti
                     && not (Array.isEmpty (Directory.GetFiles(kernelMulti, "*.l"))) then
                    Some kernelDir
                else None
            match confl with
            | Some loc ->
                Some
                    { Severity = DiagError
                      Code     = "B0010"
                      Message  =
                        sprintf
                            "package '%s' matches both single-file and multi-file %s layout in '%s'; use one"
                            pkgKey loc root
                      Span     = Span.make Position.initial Position.initial }
            | None -> None
        let probesIn (root: string) : (unit -> string list) list =
            // Order: top-level single-file, top-level multi-file directory,
            // then platform kernel (JVM prefers _kernel_jvm with _kernel
            // fallback; .NET uses _kernel only).
            let kernelProbes =
                match target with
                | Jvm ->
                    [ (fun () ->
                        let p = Path.Combine(root, "_kernel_jvm", fileName)
                        if File.Exists p then [p] else [])
                      (fun () -> listLyricFiles (Path.Combine(root, "_kernel_jvm", baseName)))
                      (fun () ->
                        let p = Path.Combine(root, "_kernel", fileName)
                        if File.Exists p then [p] else [])
                      (fun () -> listLyricFiles (Path.Combine(root, "_kernel", baseName))) ]
                | Dotnet ->
                    [ (fun () ->
                        let p = Path.Combine(root, "_kernel", fileName)
                        if File.Exists p then [p] else [])
                      (fun () -> listLyricFiles (Path.Combine(root, "_kernel", baseName))) ]
            [ (fun () ->
                let p = Path.Combine(root, fileName)
                if File.Exists p then [p] else [])
              (fun () -> listLyricFiles (Path.Combine(root, baseName))) ]
            @ kernelProbes
        let envVar =
            match head with
            | "Std" -> "LYRIC_STD_PATH"
            | h     -> sprintf "LYRIC_%s_PATH" (h.ToUpper())
        let envRootOpt =
            Option.ofObj (System.Environment.GetEnvironmentVariable envVar)
        let envHit =
            match envRootOpt with
            | Some p -> firstHit (probesIn p)
            | None   -> []
        if not (List.isEmpty envHit) then
            let layout =
                envRootOpt |> Option.bind layoutConflict
            envHit, layout
        else
            let mutable dir = Some (DirectoryInfo(startDir))
            let mutable found : string list = []
            let mutable layout : Diagnostic option = None
            while List.isEmpty found && dir.IsSome do
                let d = dir.Value
                let pkgRoot =
                    if head = "Std" then
                        Path.Combine(d.FullName, "stdlib", "std")
                    else
                        Path.Combine(d.FullName, "lyric", dirName)
                if Directory.Exists pkgRoot then
                    found <- firstHit (probesIn pkgRoot)
                    if not (List.isEmpty found) then
                        layout <- layoutConflict pkgRoot
                dir <- d.Parent |> Option.ofObj
            found, layout
    | _ -> [], None

/// Convenience wrapper for callers that don't need the layout diagnostic.
let private locateBuiltinFiles
        (startDir: string)
        (target: CompileTarget)
        (segments: string list) : string list =
    let paths, _ = locateBuiltinFilesWithLayout startDir target segments
    paths

/// Backwards-compatible single-file lookup: returns the first matched
/// path (or None).  Multi-file packages return the first file in
/// alphabetical order; callers that need the full list should use
/// `locateBuiltinFiles`.
let private locateBuiltinFile
        (startDir: string)
        (target: CompileTarget)
        (segments: string list) : string option =
    match locateBuiltinFiles startDir target segments with
    | []      -> None
    | p :: _  -> Some p

/// Best-effort name extraction for a top-level `Item` — used by the
/// multi-file conflict detector to flag duplicate declarations
/// (B0011).  Returns `None` for items that don't have a stable
/// global name (impl blocks, error nodes, doc-comment-only items).
/// For functions the key includes arity so overloads-by-arity stay
/// legal across files (matches D-progress / function-overloading).
let private itemConflictKey (item: Item) : string option =
    match item.Kind with
    | IConst c        -> Some ("const:" + c.Name)
    | IFunc f         -> Some (sprintf "func:%s/%d" f.Name (List.length f.Params))
    | ITypeAlias t    -> Some ("alias:" + t.Name)
    | IDistinctType t -> Some ("distinct:" + t.Name)
    | IRecord r       -> Some ("record:" + r.Name)
    | IExposedRec r   -> Some ("exposed:" + r.Name)
    | IUnion u        -> Some ("union:" + u.Name)
    | IEnum e         -> Some ("enum:" + e.Name)
    | IOpaque o       -> Some ("opaque:" + o.Name)
    | IProtected p    -> Some ("protected:" + p.Name)
    | IInterface i    -> Some ("interface:" + i.Name)
    | IWire w         -> Some ("wire:" + w.Name)
    | IScopeKind s    -> Some ("scope_kind:" + s.Name)
    | IExternType t   -> Some ("extern_type:" + t.Name)
    | IConfig c       -> Some ("config:" + c.Name)
    | IAspect a       -> Some ("aspect:" + a.Name)
    | IVal v          ->
        match v.Pattern.Kind with
        | PBinding (n, None) -> Some ("val:" + n)
        | _                  -> None
    // Tests / properties / fixtures are addressed by string title and
    // can legitimately repeat in different files; impls + extern
    // packages have no global identifier of their own.
    | ITest _ | IProperty _ | IFixture _ | IImpl _ | IExtern _ | IError -> None

/// Parse and merge a set of `.l` files belonging to one package.
/// Single-file path returns the parse result unchanged; multi-file
/// path concatenates `Items`, `Imports`, `ModuleDoc`, and
/// `FileLevelAnnotations` from every file, using the first file's
/// `Package` declaration as canonical.
///
/// Surfaces three multi-file diagnostic codes per
/// `docs/19-multi-file-packages.md` §9:
///   * `B0011`: duplicate declaration across files in the same
///     package.  Functions key on `name + arity` so overloads-by-
///     arity remain legal; everything else keys on bare name.
///     The duplicate item is dropped from the merged list so
///     downstream type-checking sees a clean symbol table.
///   * `B0012`: conflicting import alias (`import X as A` in one
///     file, `import Y as A` in another).  The duplicate import is
///     dropped.  Same path with same alias in two files is fine
///     (silently deduped); same path WITHOUT alias is also fine.
let private parseAndMergeBuiltinFiles
        (paths: string list) : Lyric.Parser.Parser.ParseResult option =
    match paths with
    | []     -> None
    | [path] ->
        Some (Lyric.Parser.Parser.parse (File.ReadAllText path))
    | _ ->
        let parsedWithPaths =
            paths
            |> List.map (fun p ->
                let src = File.ReadAllText p
                p, Lyric.Parser.Parser.parse src)
        let parsed = parsedWithPaths |> List.map snd
        let firstFile = parsed.[0].File
        let pkgKey =
            firstFile.Package.Path.Segments |> String.concat "."
        // Conflict scan + merged item list (B0011).
        let conflictDiags = ResizeArray<Diagnostic>()
        let seenItem = Dictionary<string, string>()  // key -> first-file-path
        let mergedItems = ResizeArray<Item>()
        for (path, pr) in parsedWithPaths do
            for item in pr.File.Items do
                match itemConflictKey item with
                | Some key ->
                    match seenItem.TryGetValue key with
                    | true, prevPath ->
                        let firstName =
                            // Strip the "kind:" prefix for the message.
                            let i = key.IndexOf ':'
                            if i >= 0 then key.Substring(i + 1) else key
                        conflictDiags.Add
                            { Severity = DiagError
                              Code     = "B0011"
                              Message  =
                                sprintf
                                    "duplicate declaration '%s' in package %s; first defined in %s, also in %s"
                                    firstName pkgKey
                                    (Path.GetFileName prevPath)
                                    (Path.GetFileName path)
                              Span     = item.Span }
                        // Drop the dupe from the merged list.
                    | false, _ ->
                        seenItem.[key] <- path
                        mergedItems.Add item
                | None ->
                    // Anonymous shapes (impl, test, fixture, etc.)
                    // pass through unchanged.
                    mergedItems.Add item
        // Conflict scan + merged import list (B0012).
        let seenAlias = Dictionary<string, struct (string * string)>()
            // alias -> (path-of-first-import, target-package-key)
        let mergedImports = ResizeArray<ImportDecl>()
        for (path, pr) in parsedWithPaths do
            for imp in pr.File.Imports do
                let target = imp.Path.Segments |> String.concat "."
                match imp.Alias with
                | Some alias ->
                    match seenAlias.TryGetValue alias with
                    | true, struct (prevPath, prevTarget) when prevTarget <> target ->
                        conflictDiags.Add
                            { Severity = DiagError
                              Code     = "B0012"
                              Message  =
                                sprintf
                                    "conflicting import alias '%s' in package %s: maps to %s in %s but to %s in %s"
                                    alias pkgKey
                                    prevTarget
                                    (Path.GetFileName prevPath)
                                    target
                                    (Path.GetFileName path)
                              Span     = imp.Span }
                    | true, _ ->
                        // Same alias same target — silently dedup.
                        ()
                    | false, _ ->
                        seenAlias.[alias] <- struct (path, target)
                        mergedImports.Add imp
                | None ->
                    // Unaliased imports: just dedupe by target so
                    // every package picks up one copy.
                    mergedImports.Add imp
        let merged : SourceFile =
            { ModuleDoc =
                parsed |> List.collect (fun pr -> pr.File.ModuleDoc)
              FileLevelAnnotations =
                parsed |> List.collect (fun pr -> pr.File.FileLevelAnnotations)
              Package = firstFile.Package
              Imports = List.ofSeq mergedImports
              Items   = List.ofSeq mergedItems
              Span    = firstFile.Span }
        let allDiags =
            (parsed |> List.collect (fun pr -> pr.Diagnostics))
            @ List.ofSeq conflictDiags
        Some { File = merged; Diagnostics = allDiags }

/// Recursively ensure that the given `Std.X[.Y…]` package is compiled,
/// returning its artifact and any diagnostics raised during the
/// compile chain.  Cached per-process; re-entrant calls hit the
/// cache.  `target` controls which `_kernel*` directory is probed
/// (D041).
let rec private ensureStdlibArtifact
        (target: CompileTarget)
        (segments: string list) : Result<StdlibArtifact, Diagnostic list> =
    let key = sprintf "%A:%s" target (packageKey segments)
    lock stdlibLock (fun () ->
        match stdlibArtifactCache.TryGetValue key with
        | true, a -> Ok a
        | _ ->
            // Fast path: try a pre-built binary stdlib DLL (docs/22 §3)
            // before recompiling from source.  Checks SdkRoot for
            // `lib/Lyric.Stdlib.dll`; if found and it carries the package
            // we need as a `Lyric.Contract.<Pkg>` resource, uses that
            // artifact directly.  Falls through to source on any failure.
            let binaryArtifact =
                let sdkInfo = SdkRoot.locate AppContext.BaseDirectory
                match sdkInfo.StdlibDll with
                | None -> None
                | Some dllPath ->
                    let pkgName = packageKey segments
                    let ref' =
                        { RestoredPackages.Name    = pkgName
                          RestoredPackages.Version = "0.1.0"
                          RestoredPackages.DllPath = dllPath }
                    match RestoredPackages.loadRestoredPackage ref' with
                    | Error _ -> None
                    | Ok arts ->
                        arts
                        |> List.tryFind (fun a -> a.Contract.PackageName = pkgName)
                        |> Option.map restoredToStdlib
            match binaryArtifact with
            | Some artifact ->
                stdlibArtifactCache.[key] <- artifact
                Ok artifact
            | None ->
            // Source fallback: walk stdlib/ tree and compile from .l files.
            let foundPaths, layoutDiag =
                locateBuiltinFilesWithLayout AppContext.BaseDirectory target segments
            match parseAndMergeBuiltinFiles foundPaths with
            | None ->
                let zeroSpan = Span.make Position.initial Position.initial
                Error [ err "E900"
                            (sprintf "cannot locate lyric source for stdlib module '%s'" key)
                            zeroSpan ]
            | Some parsed when layoutDiag.IsSome ->
                // B0010: package matches both layouts in same root.
                // Refuse the build outright so the user picks one.
                Error [ layoutDiag.Value ]
            | Some parsed ->
                // For multi-file packages, `req.Source` is best-effort
                // — used downstream only for diagnostics that don't
                // hit the precompile path.  Concatenate so any rare
                // re-parse round-trips through valid lex input.
                let src =
                    foundPaths
                    |> List.map File.ReadAllText
                    |> String.concat "\n"
                // Recursively compile every builtin import the source
                // declares, so they're cached before this module emits.
                // Std.Core is auto-included even when not declared so
                // every stdlib module can rely on `Result` / `Option`.
                let stdImports =
                    parsed.File.Imports
                    |> List.choose (fun i ->
                        match i.Path.Segments with
                        | head :: _ when isBuiltinHead head && i.Path.Segments <> segments ->
                            Some i.Path.Segments
                        | _ -> None)
                let allDeps =
                    let needsCore =
                        segments <> ["Std"; "Core"]
                        && not (List.exists ((=) ["Std"; "Core"]) stdImports)
                    if needsCore then ["Std"; "Core"] :: stdImports
                    else stdImports
                let mutable depDiags : Diagnostic list = []
                // Transitive closure: when iter.l imports Std.Collections
                // and Std.Collections imports Std.CollectionsHost, the
                // typechecker for iter.l needs items from BOTH levels —
                // otherwise extern types declared only in the kernel
                // (e.g., `List[T]` in `Std.CollectionsHost`) aren't in
                // scope for iter.l.  Walks each artifact's own stdlib
                // imports recursively, deduping by package path.
                let depArtifacts =
                    let visited = HashSet<string>()
                    let ordered = ResizeArray<StdlibArtifact>()
                    let rec walk (segs: string list) : unit =
                        let key = packageKey segs
                        if visited.Add key then
                            match ensureStdlibArtifact target segs with
                            | Ok a ->
                                let nestedDeps =
                                    a.Source.Imports
                                    |> List.choose (fun i ->
                                        match i.Path.Segments with
                                        | head :: _ when isBuiltinHead head && i.Path.Segments <> segments ->
                                            Some i.Path.Segments
                                        | _ -> None)
                                for d in nestedDeps do walk d
                                ordered.Add a
                            | Error ds ->
                                depDiags <- depDiags @ ds
                    for d in allDeps do walk d
                    List.ofSeq ordered
                if not depDiags.IsEmpty then Error depDiags
                else
                    // Strip all builtin imports — they're handled by the
                    // artifact list, not the user-side `Item list`
                    // re-registration.  Non-builtin imports (e.g. axiom
                    // externs to System.*) flow through.
                    let stripped =
                        let sf = parsed.File
                        { sf with
                            Imports =
                                sf.Imports
                                |> List.filter (fun i ->
                                    match i.Path.Segments with
                                    | head :: _ when isBuiltinHead head -> false
                                    | _ -> true) }
                    let importedItems =
                        depArtifacts |> List.collect (fun a -> a.Source.Items)
                    let checked' =
                        Lyric.TypeChecker.Checker.checkWithImports stripped importedItems
                    // The `Lyric.<head>.<rest>.dll` shape is intentional —
                    // dropping the per-head prefix would let the self-hosted
                    // `Lyric.Lexer` / `Lyric.Parser` / `Lyric.TypeChecker`
                    // assemblies collide with the F# bootstrap's same-named
                    // DLLs in the AppDomain (both export type names under the
                    // `Lyric.Lexer.*` CLR namespace, but the F# records have
                    // PascalCase fields like `Token`/`Span` while the self-
                    // hosted records are lower-case `token`/`span`).  The
                    // assembly-qualified type-ref in the self-hosted DLL keeps
                    // them disambiguated as long as the assembly names differ.
                    let assemblyName =
                        match segments with
                        | "Std" :: rest -> "Lyric.Stdlib." + String.concat "" rest
                        | head :: rest  -> sprintf "Lyric.%s.%s" head (String.concat "" rest)
                        | []            -> "Lyric.Unknown"
                    let outPath = Path.Combine(stdlibCacheDir, assemblyName + ".dll")
                    let req =
                        { Source             = src
                          AssemblyName       = assemblyName
                          OutputPath         = outPath
                          RestoredPackages   = []
                          NugetAssemblyPaths = []
                          ExternShimRoot     = None
                          Target             = target
                          ActiveFeatures     = Set.empty
                          DeclaredFeatures   = Set.empty }
                    let stdImportsHere =
                        parsed.File.Imports
                        |> List.filter (fun i ->
                            match i.Path.Segments with
                            | head :: _ when isBuiltinHead head -> true
                            | _ -> false)
                    let emitDiags =
                        emitAssembly
                            stripped checked'.Signatures checked'.Symbols
                            req true depArtifacts stdImportsHere None None None
                    // Surface every error-level diagnostic from any
                    // stage of the stdlib precompile.  Earlier
                    // bootstrap state ignored these so user emits
                    // wouldn't trip on pre-existing stdlib issues
                    // (T0040 on `slice[T].length`, etc.); those have
                    // since been fixed (PR #26 taught the type
                    // checker about BCL members), so the resolver
                    // can now be strict.  Each error is prefixed so
                    // a user can tell their program from the
                    // stdlib's contribution.
                    let allDiags =
                        parsed.Diagnostics
                        @ checked'.Diagnostics
                        @ emitDiags
                    let stdErrors =
                        allDiags
                        |> List.filter (fun d -> d.Severity = DiagError)
                        |> List.map (fun d ->
                            { d with
                                Message =
                                    sprintf "[stdlib %s] %s" key d.Message })
                    if not (List.isEmpty stdErrors) then
                        Error stdErrors
                    elif not (File.Exists outPath) then
                        let parserErrs =
                            parsed.Diagnostics
                            |> List.filter (fun d -> d.Severity = DiagError)
                        Error parserErrs
                    else
                        let assembly = Assembly.LoadFrom outPath
                        let artifact =
                            { AssemblyPath = outPath
                              Assembly     = Some assembly
                              // Keep the original (unstripped) parse so
                              // the user-side visit can walk transitive
                              // `Std.X` deps.  The type-checker /
                              // emitter calls used `stripped`.
                              Source       = parsed.File
                              Symbols      = checked'.Symbols
                              Signatures   = checked'.Signatures
                              Lookup       =
                                fun n -> Option.ofObj (assembly.GetType n) }
                        stdlibArtifactCache.[key] <- artifact
                        Ok artifact)

/// Public accessor: returns the absolute paths to every compiled
/// stdlib DLL that has run so far.  The test harness uses this to
/// copy DLLs alongside each user output.
let stdlibAssemblyPath () : string option =
    lock stdlibLock (fun () ->
        // Key format is "<Target>:<package>" (e.g. "Dotnet:Std.Core").
        // Scan for any target variant that compiled Std.Core.
        stdlibArtifactCache
        |> Seq.tryFind (fun kv -> kv.Key.EndsWith ":Std.Core")
        |> Option.map (fun kv -> kv.Value.AssemblyPath))

/// Every compiled stdlib DLL path that has been produced this
/// process.  Newer code (the test kit) copies all of them so user
/// programs that import multiple `Std.X` modules can resolve every
/// reference at runtime.
let stdlibAssemblyPaths () : string list =
    lock stdlibLock (fun () ->
        stdlibArtifactCache.Values
        |> Seq.map (fun a -> a.AssemblyPath)
        |> List.ofSeq)

/// Public SDK-info accessor for `lyric --sdk-info`.  Returns the located SDK
/// root (or NotFound) based on the same search order used by the stdlib loader.
let getSdkInfo () : SdkRoot.SdkInfo =
    SdkRoot.locate AppContext.BaseDirectory

/// Resolve `import Std.X` / `import Jvm.X` (and any other built-in package)
/// declarations: walk the dependency closure, compile what's missing, and hand
/// the artifact list + their parsed items to the type checker / emitter.  The
/// user's `SourceFile.Items` is left unchanged; only builtin imports are
/// stripped.
let private resolveStdlibImports
        (target: CompileTarget)
        (sf: SourceFile)
        : SourceFile * Item list * StdlibArtifact list * ImportDecl list * Diagnostic list =
    let stdImports, otherImps =
        sf.Imports
        |> List.partition (fun i ->
            match i.Path.Segments with
            | head :: _ when isBuiltinHead head -> true
            | _ -> false)
    if stdImports.IsEmpty then sf, [], [], [], []
    else
        let visited = HashSet<string>()
        let ordered = ResizeArray<StdlibArtifact>()
        let diags = ResizeArray<Diagnostic>()
        let rec visit segments =
            let key = packageKey segments
            if visited.Add key then
                match ensureStdlibArtifact target segments with
                | Ok a ->
                    // Visit deps first so they appear before in the
                    // ordered list — type-checker import processing
                    // expects topo order.
                    let deps =
                        a.Source.Imports
                        |> List.choose (fun i ->
                            match i.Path.Segments with
                            | head :: _ when isBuiltinHead head -> Some i.Path.Segments
                            | _ -> None)
                    // Auto-add Std.Core since `ensureStdlibArtifact`
                    // does — the user-visible item list needs it too.
                    let withCore =
                        if segments <> ["Std"; "Core"]
                           && not (List.exists ((=) ["Std"; "Core"]) deps) then
                            ["Std"; "Core"] :: deps
                        else deps
                    for d in withCore do visit d
                    ordered.Add a
                | Error ds ->
                    for d in ds do diags.Add d
        for imp in stdImports do
            visit imp.Path.Segments
        let artifacts = List.ofSeq ordered
        let items = artifacts |> List.collect (fun a -> a.Source.Items)
        // Selector aliases (`import X.{foo as bar}`) get cloned IFunc
        // items so the type checker's signature map and symbol table
        // recognise the alias name in expression position.  Package
        // aliases (`import X as A`) are handled by `AliasRewriter`
        // earlier in the pipeline (rewriting `A.foo` to `foo` etc.),
        // so no synthesised items are needed for them.
        let aliasItems = ResizeArray<Item>()
        let mkAliasIFunc (origFn: FunctionDecl) (newName: string) : Item =
            let cloned : FunctionDecl = { origFn with Name = newName; Body = None }
            { DocComments = []
              Annotations = []
              Visibility  = origFn.Visibility
              Kind        = IFunc cloned
              Span        = origFn.Span }
        let artifactByPath =
            artifacts
            |> List.map (fun a -> a.Source.Package.Path.Segments, a)
            |> Map.ofList
        // Selector-alias lookup looks across all transitively-loaded
        // artifacts, not just the user-imported one.  This lets
        // `import Std.Collections.{newList as mkList}` resolve even
        // when `newList` lives in the kernel (`Std.CollectionsHost`)
        // that `Std.Collections` re-exposes via its own import.
        let allFuncs =
            artifacts
            |> List.collect (fun a ->
                a.Source.Items
                |> List.choose (fun it ->
                    match it.Kind with
                    | IFunc fn -> Some fn
                    | _ -> None))
        for imp in stdImports do
            let aliasPairs =
                match imp.Selector with
                | Some (ISSingle item) ->
                    match item.Alias with
                    | Some a -> [ item.Name, a ]
                    | None   -> []
                | Some (ISGroup items) ->
                    items
                    |> List.choose (fun it ->
                        it.Alias |> Option.map (fun a -> it.Name, a))
                | None -> []
            for (origName, aliasName) in aliasPairs do
                allFuncs
                |> List.tryFind (fun fn -> fn.Name = origName)
                |> Option.iter (fun fn ->
                    aliasItems.Add(mkAliasIFunc fn aliasName))
        let extendedItems = items @ List.ofSeq aliasItems
        { sf with Imports = otherImps }, extendedItems, artifacts, stdImports, List.ofSeq diags

/// Resolve `import <Pkg>` declarations against the restored Lyric
/// packages declared in the user's `lyric.toml`.  Mirrors
/// `resolveStdlibImports` but for non-`Std.*` imports: each user
/// import whose first segment matches a restored package name pulls
/// that package's RestoredArtifact + items into the artifact list,
/// then strips the matching imports from the SourceFile.
///
/// Restored packages whose loading fails surface as fatal `E901`
/// diagnostics that abort the emit (same shape as a failing
/// `ensureStdlibArtifact`).
///
/// The restored-package artifact is converted to the same internal
/// `StdlibArtifact` record the rest of the emitter consumes, so the
/// downstream import-table population in `emitAssembly` works
/// unchanged.
let private resolveRestoredImports
        (sf: SourceFile)
        (refs: RestoredPackages.RestoredPackageRef list)
        : SourceFile * Item list * StdlibArtifact list * Diagnostic list =
    if List.isEmpty refs then sf, [], [], []
    else
        // Pre-load every ref's contracts up front.  M5.1 stage
        // 2c.2.iii: a single `RestoredPackageRef` (one entry in
        // `lyric.toml`'s `[dependencies]`) may now expose multiple
        // packages when the DLL was published as a bundled
        // `output = "single"` project.  Each package becomes its own
        // `RestoredPackages.RestoredArtifact` keyed on the package
        // path it declares — so an import `MyApp.Core` matches the
        // contract that synthesised `package MyApp.Core` items, and
        // an import `MyApp.Util` matches the sibling contract.
        let diags = ResizeArray<Diagnostic>()
        let allArtifacts = ResizeArray<RestoredPackages.RestoredArtifact>()
        let visited = HashSet<string>()
        for r in refs do
            if visited.Add r.Name then
                match RestoredPackages.loadRestoredPackage r with
                | Error e -> diags.Add (RestoredPackages.toDiagnostic e)
                | Ok ras  ->
                    for ra in ras do allArtifacts.Add ra
        // Index by the package path declared in each artifact's
        // synthesised source.  Multiple artifacts under the same
        // ref yield distinct keys (each contract carries its own
        // `package <X>` line).
        let byPackage =
            allArtifacts
            |> Seq.map (fun a ->
                String.concat "." a.Source.Package.Path.Segments, a)
            |> Map.ofSeq
        let importMatches (segments: string list) : RestoredPackages.RestoredArtifact option =
            let key = String.concat "." segments
            Map.tryFind key byPackage
        let nonStdImports, otherImps =
            sf.Imports
            |> List.partition (fun i ->
                match i.Path.Segments with
                | "Std" :: _ -> false
                | segs -> Option.isSome (importMatches segs))
        if List.isEmpty nonStdImports then
            // Imports unmatched but refs may have surfaced load
            // diagnostics — propagate them so the user sees the
            // failure rather than silently missing the import.
            sf, [], [], List.ofSeq diags
        else
            let artifacts = ResizeArray<StdlibArtifact>()
            let importedItems = ResizeArray<Item>()
            let usedPackages = HashSet<string>()
            for imp in nonStdImports do
                match importMatches imp.Path.Segments with
                | None -> ()  // shouldn't happen — partition checked
                | Some ra ->
                    let key = String.concat "." ra.Source.Package.Path.Segments
                    if usedPackages.Add key then
                        let asArtifact : StdlibArtifact =
                            { AssemblyPath = ra.AssemblyPath
                              Assembly     = Some ra.Assembly
                              Source       = ra.Source
                              Symbols      = ra.Symbols
                              Signatures   = ra.Signatures
                              Lookup       =
                                let asm = ra.Assembly
                                fun n -> Option.ofObj (asm.GetType n) }
                        artifacts.Add asArtifact
                        for it in ra.Source.Items do importedItems.Add it
            { sf with Imports = otherImps },
            List.ofSeq importedItems,
            List.ofSeq artifacts,
            List.ofSeq diags

/// Phase 5 §M5.1 stage 2d.v: compile each `_extern/<Head>.l` shim to
/// a cached DLL and build a `StdlibArtifact` from the result.  The
/// shim contents are `pub func` declarations with `@externTarget`
/// annotations targeting the user's NuGet packages — emitting them
/// produces a `<Head>.Program` class with static-method trampolines
/// that the existing imported-func resolver looks up.  Without the
/// emit step the user's call site fires `E0004 unknown name` because
/// no real `<Head>.Program.<func>` method exists.
///
/// The compile is done via a recursive `emit` call.  We carry through
/// the NuGet DLL paths so `preloadNugetAssemblies` populates the
/// AppDomain before the shim's `@externTarget` resolution runs;
/// `ExternShimRoot` is forced to `None` on the inner request so the
/// recursion bottoms out at the shim itself (shims are leaves).
let private resolveExternShimImports
        (sf: SourceFile)
        (shimRoot: string option)
        (nugetPaths: string list)
        : SourceFile * Item list * StdlibArtifact list * Diagnostic list =
    match shimRoot with
    | None -> sf, [], [], []
    | Some root ->
    if not (Directory.Exists root) then sf, [], [], []
    else
    let zeroSpan = Span.make Position.initial Position.initial
    let candidates =
        sf.Imports
        |> List.choose (fun i ->
            match i.Path.Segments with
            | head :: _ when not (isBuiltinHead head) ->
                let path = Path.Combine(root, head + ".l")
                if File.Exists path then Some (head, path, i)
                else None
            | _ -> None)
    if List.isEmpty candidates then sf, [], [], []
    else
    let diags = ResizeArray<Diagnostic>()
    let artifacts = ResizeArray<StdlibArtifact>()
    let importedItems = ResizeArray<Item>()
    let visited = HashSet<string>()
    let strippedImports = HashSet<string>()
    // Cache compiled shim DLLs alongside the manifest's `.lyric/`
    // scratch directory so re-runs hit the cache instead of
    // recompiling.  `<root>/../.lyric/extern-cache/<head>.dll`.
    let cacheDir =
        let parent =
            try Path.GetDirectoryName(Path.GetFullPath root)
            with _ -> null
        match Option.ofObj parent with
        | Some p -> Path.Combine(p, ".lyric", "extern-cache")
        | None   -> Path.Combine(Path.GetTempPath(), "lyric-extern-cache")
    Directory.CreateDirectory cacheDir |> ignore
    // Pre-load NuGet assemblies before parsing any shim — the
    // shim's `@externTarget` resolution walks the AppDomain.
    preloadNugetAssemblies nugetPaths
    for (head, shimPath, _) in candidates do
        if visited.Add head then
            let src =
                try Some (File.ReadAllText shimPath)
                with ex ->
                    diags.Add (
                        err "E901"
                            (sprintf "extern shim '%s' unreadable: %s" shimPath ex.Message)
                            zeroSpan)
                    None
            match src with
            | None -> ()
            | Some text ->
                let parsed = Lyric.Parser.Parser.parse text
                let parseErrs =
                    parsed.Diagnostics
                    |> List.filter (fun d -> d.Severity = DiagError)
                if not (List.isEmpty parseErrs) then
                    for d in parseErrs do diags.Add d
                else
                    let checked' =
                        Lyric.TypeChecker.Checker.check parsed.File
                    let checkErrs =
                        checked'.Diagnostics
                        |> List.filter (fun d -> d.Severity = DiagError)
                    if not (List.isEmpty checkErrs) then
                        for d in checkErrs do diags.Add d
                    else
                        let dllPath = Path.Combine(cacheDir, head + ".dll")
                        let innerReq : EmitRequest =
                            { Source             = text
                              AssemblyName       = head
                              OutputPath         = dllPath
                              RestoredPackages   = []
                              NugetAssemblyPaths = nugetPaths
                              ExternShimRoot     = None
                              Target             = Dotnet
                              ActiveFeatures     = Set.empty
                              DeclaredFeatures   = Set.empty }
                        // `emitAssembly` with `isLibrary = true`
                        // skips the main-function requirement that
                        // `emit` enforces for executables.  Same
                        // pattern used by `ensureStdlibArtifact`.
                        let emitDiags =
                            emitAssembly
                                parsed.File checked'.Signatures
                                checked'.Symbols
                                innerReq true [] [] None None None
                        let emitErrs =
                            emitDiags
                            |> List.filter (fun d -> d.Severity = DiagError)
                        if not (List.isEmpty emitErrs) then
                            for d in emitErrs do diags.Add d
                        elif not (File.Exists dllPath) then
                            diags.Add (
                                err "E901"
                                    (sprintf "extern shim '%s' did not produce '%s'"
                                            shimPath dllPath)
                                    zeroSpan)
                        else
                            let asm = Assembly.LoadFrom dllPath
                            let artifact : StdlibArtifact =
                                { AssemblyPath = dllPath
                                  Assembly     = Some asm
                                  Source       = parsed.File
                                  Symbols      = checked'.Symbols
                                  Signatures   = checked'.Signatures
                                  Lookup       =
                                    fun n -> Option.ofObj (asm.GetType n) }
                            artifacts.Add artifact
                            for it in parsed.File.Items do importedItems.Add it
                            strippedImports.Add head |> ignore
    let remainingImports =
        sf.Imports
        |> List.filter (fun i ->
            match i.Path.Segments with
            | head :: _ -> not (strippedImports.Contains head)
            | _        -> true)
    { sf with Imports = remainingImports },
    List.ofSeq importedItems,
    List.ofSeq artifacts,
    List.ofSeq diags

/// Emit a Lyric source string to a persistent assembly.
let emit (req: EmitRequest) : EmitResult =
    // Phase 5 §M5.1 stage 2d.v: pre-load NuGet DLLs into the
    // AppDomain so `findClrType` resolves extern types declared in
    // auto-generated `_extern/<pkg>.l` shims.  No-op when the
    // request carries no NuGet refs (legacy single-source builds).
    preloadNugetAssemblies req.NugetAssemblyPaths
    let parsed   = parse req.Source
    // D045: erase items annotated with `@cfg(feature = "X")` whose
    // predicate is false against the active feature set.  Runs
    // before import resolution so erased imports (gated alongside
    // their definitions in future) cleanly disappear.
    let cfgFiltered, cfgDiags =
        Lyric.Emitter.Cfg.applyCfgErasure
            req.ActiveFeatures req.DeclaredFeatures parsed.File
    // Restored Lyric packages (D-progress-077 follow-up) resolve
    // first so the `Std.*` resolver below sees a SourceFile with
    // the matching non-`Std` imports already stripped.
    let afterRestored, restoredImportedItems, restoredArtifacts, restoredDiags =
        resolveRestoredImports cfgFiltered req.RestoredPackages
    // Phase 5 §M5.1 stage 2d.v: NuGet shim imports.
    let afterExtern, externImportedItems, externArtifacts, externDiags =
        resolveExternShimImports afterRestored req.ExternShimRoot
            req.NugetAssemblyPaths
    let resolved, importedItems, stdlibArtifacts, stdImports, importDiags =
        resolveStdlibImports req.Target afterExtern
    let mergedImportedItems =
        restoredImportedItems @ externImportedItems @ importedItems
    let mergedArtifacts =
        restoredArtifacts @ externArtifacts @ stdlibArtifacts
    let checked' =
        Lyric.TypeChecker.Checker.checkWithImports resolved mergedImportedItems

    let upstream =
        parsed.Diagnostics @ cfgDiags @ restoredDiags @ externDiags
        @ importDiags @ checked'.Diagnostics
    let parserFatal =
        upstream
        |> List.exists (fun d ->
            d.Severity = DiagError && d.Code.StartsWith "P")
    // If any stdlib / restored precompile failed, skip user-side
    // emit — running the emitter without populated import tables
    // would crash with "unknown name" exceptions that mask the
    // real diagnostic.
    let importFatal =
        (restoredDiags @ importDiags)
        |> List.exists (fun d -> d.Severity = DiagError)

    if parserFatal || importFatal then
        { OutputPath = None; Diagnostics = upstream }
    else
        let emitDiags =
            emitAssembly
                resolved
                checked'.Signatures
                checked'.Symbols
                req
                false
                mergedArtifacts
                stdImports
                None
                None
                None
        let emitFatal =
            emitDiags |> List.exists (fun d -> d.Severity = DiagError)
        let outputPath = if emitFatal then None else Some req.OutputPath
        { OutputPath  = outputPath
          Diagnostics = upstream @ emitDiags }

// ---------------------------------------------------------------------------
// Project-as-DLL emit driver (M5.1 stage 2c.2.ii).
//
// `emitProject` takes a `[project]`-shaped manifest section plus the
// per-package source (after multi-file merge per `docs/19`) and emits
// every package into ONE persistent assembly.  Per-package contract
// metadata lands as `Lyric.Contract.<Pkg>` resources in the bundled
// DLL; downstream `lyric restore` and contract walkers learn to enumerate
// them via `ContractMeta.readAllContractsFromAssembly`.
//
// Stage 2c.2.ii.b additions over the MVP:
//
//   * Topological sort over packages by intra-project import edges
//     so package A emits before package B when `B imports A`.
//   * Cycle detection: a strongly-connected component of size > 1 (or
//     a self-loop) surfaces as `B0020`.
//   * Intra-project artifacts: after package A's emit, its TypeBuilders
//     have all been sealed via `CreateType()` and live inside the
//     shared `ModuleBuilder`.  We capture A as a `StdlibArtifact`
//     whose `Lookup` resolves names against `ctx.Module.GetType` and
//     thread it into B's emit so B's `ImportedRecordTable` /
//     `ImportedFuncTable` register A's surface.
//
// Stage 2c.2.iv additions:
//
//   * Pre-scan packages for `func main`; emit the main-bearing
//     package as non-library and capture its host-wrapper
//     `MethodInfo` via the new `mainOut` parameter on
//     `emitAssembly`.  Pass that MethodInfo through `Backend.save`
//     so the bundled DLL is `dotnet exec`-runnable.  Bundles
//     without a `main` save library-shaped (no entry point).
//
// Stage 2c.2.iii (D-progress-101): `lyric restore` walks every
// `Lyric.Contract.<Pkg>` resource via `loadRestoredPackage`'s
// list-returning shape so a single bundled-DLL `[dependencies]`
// entry surfaces N consumer-side imports.
// ---------------------------------------------------------------------------

/// Per-package source feed for `emitProject`.  Each package's
/// `Sources` list is the `.l` file contents in deterministic
/// order; multi-file packages should already have been resolved
/// + merged by the caller via the `docs/19` machinery.
type ProjectPackageInput =
    { PackageName: string
      Sources:     string list }

/// Top-level request for project-as-DLL emit.  The output mode is
/// captured separately from `EmitRequest`: `EmitRequest.Source` /
/// `AssemblyName` / `OutputPath` describe the BUNDLED DLL.
type ProjectEmitRequest =
    { Packages:     ProjectPackageInput list
      AssemblyName: string
      OutputPath:   string
      /// Restored Lyric packages this build can resolve non-`Std.*`
      /// imports against.  Same shape as the single-package
      /// `EmitRequest.RestoredPackages`.
      RestoredPackages: RestoredPackages.RestoredPackageRef list
      /// NuGet DLLs to pre-load into the AppDomain (Phase 5 §M5.1
      /// stage 2d.v).  Mirrors `EmitRequest.NugetAssemblyPaths`.
      NugetAssemblyPaths: string list
      /// `_extern/` shim directory for NuGet imports.  Mirrors
      /// `EmitRequest.ExternShimRoot`.
      ExternShimRoot: string option
      /// `true` for `output = "single"`; `false` falls back to a
      /// per-package emit producing one DLL per package alongside
      /// the bundled output.  M5.1 stage 2c.2.ii ships only the
      /// `Single = true` path; per-package mode keeps the legacy
      /// per-package emit flow intact via `emit`.
      Single:       bool
      /// Compilation target platform.  Controls which `_kernel*`
      /// directory is used for builtin `Std.*` package resolution.
      Target:       CompileTarget
      /// Active build-feature set (D045) shared across every package
      /// in the project.  Mirrors `EmitRequest.ActiveFeatures`.
      ActiveFeatures:   Set<string>
      /// Declared feature set (D045) for diagnostic-only typo guards.
      DeclaredFeatures: Set<string> }

/// Result of a project emit.  Mirrors `EmitResult` but tracks a
/// list of per-package emit diagnostics so the caller can render
/// each package's failures with attribution.
type ProjectEmitResult =
    { OutputPath:  string option
      Diagnostics: Diagnostic list }

/// Concatenate a package's source files into one synthetic source
/// string.  Each file declares the same `package <X>`; the resulting
/// concatenation re-declares the package once at the top by stripping
/// subsequent `package` lines.  This is a simplification for the MVP;
/// the proper multi-file merger lives at `parseAndMergeBuiltinFiles`
/// and lifts here when the project-discovery flow lands in
/// `Lyric.Cli.Pack`.
let private joinPackageSources (sources: string list) : string =
    match sources with
    | []      -> ""
    | [only]  -> only
    | _       -> String.concat "\n" sources

/// Emit every package in the project into a single bundled DLL.
let emitProject (req: ProjectEmitRequest) : ProjectEmitResult =
    if not req.Single then
        // Per-package mode is the legacy flow — caller should drive
        // this via repeated `emit` calls itself.  Until project-mode
        // CLI integration lands we surface a clear diagnostic so the
        // accidental single=false call doesn't silently produce
        // nothing.
        let zeroSpan = Span.make Position.initial Position.initial
        { OutputPath  = None
          Diagnostics =
            [ { Severity = DiagError
                Code     = "B0099"
                Message  =
                    "emitProject with Single=false is not implemented; \
                     drive per-package mode via repeated emit() calls"
                Span     = zeroSpan } ] }
    elif List.isEmpty req.Packages then
        let zeroSpan = Span.make Position.initial Position.initial
        { OutputPath  = None
          Diagnostics =
            [ { Severity = DiagError
                Code     = "B0023"
                Message  =
                    "project declared `output = \"single\"` but discovered \
                     zero packages"
                Span     = zeroSpan } ] }
    else
        // Open one shared backend for the whole project.
        let desc =
            { Backend.Name        = req.AssemblyName
              Backend.Version     = Version(0, 1, 0, 0)
              Backend.OutputPath  = req.OutputPath }
        let ctx = Backend.create desc
        let allDiags = ResizeArray<Diagnostic>()
        let perPackageContracts = ResizeArray<string * SourceFile * Map<string, Lyric.TypeChecker.ResolvedSignature>>()
        let mutable mainCount = 0

        // ---- Phase A0: parse every package once so we can topo-sort
        // ---- by intra-project import edges before emit.
        let parsedByName = Dictionary<string, ParseResult * string>()
        let projectPackageSet = HashSet<string>(req.Packages |> List.map (fun p -> p.PackageName))
        for pkg in req.Packages do
            let combinedSrc = joinPackageSources pkg.Sources
            let parsed = parse combinedSrc
            allDiags.AddRange parsed.Diagnostics
            parsedByName.[pkg.PackageName] <- (parsed, combinedSrc)

        /// Imports that point at another package in the same project.
        /// Returned as the in-project package name (the `import`
        /// path's segments joined by `.`).  Imports that don't match
        /// a project package fall through to the existing stdlib +
        /// restored resolvers.
        let intraImportsOf (sf: SourceFile) : string list =
            sf.Imports
            |> List.choose (fun i ->
                let key = String.concat "." i.Path.Segments
                if projectPackageSet.Contains key then Some key else None)
            |> List.distinct

        // ---- Phase A1: topo-sort by intra-project edges + B0020
        // ---- on cycles.  Edges: A -> B when "B imports A" (so A
        // ---- emits first).  The classic Kahn's algorithm gives
        // ---- both an order and a cycle-detection result for free.
        let edges =
            req.Packages
            |> List.map (fun p ->
                let parsed, _ = parsedByName.[p.PackageName]
                p.PackageName, intraImportsOf parsed.File)
        let inDegree = Dictionary<string, int>()
        for p in req.Packages do inDegree.[p.PackageName] <- 0
        for (name, deps) in edges do
            for d in deps do
                if projectPackageSet.Contains d then
                    inDegree.[name] <- inDegree.[name] + 1
        let revAdj = Dictionary<string, ResizeArray<string>>()
        for p in req.Packages do revAdj.[p.PackageName] <- ResizeArray<string>()
        for (name, deps) in edges do
            for d in deps do
                if projectPackageSet.Contains d then
                    revAdj.[d].Add name
        let order = ResizeArray<string>()
        let queue = System.Collections.Generic.Queue<string>()
        for kv in inDegree do
            if kv.Value = 0 then queue.Enqueue kv.Key
        while queue.Count > 0 do
            let n = queue.Dequeue()
            order.Add n
            for m in revAdj.[n] do
                inDegree.[m] <- inDegree.[m] - 1
                if inDegree.[m] = 0 then queue.Enqueue m
        let cycleNames =
            inDegree
            |> Seq.filter (fun kv -> kv.Value > 0)
            |> Seq.map (fun kv -> kv.Key)
            |> Seq.toList
        if not (List.isEmpty cycleNames) then
            let zeroSpan = Span.make Position.initial Position.initial
            allDiags.Add
                { Severity = DiagError
                  Code     = "B0020"
                  Message  =
                    sprintf
                        "intra-project import cycle detected; packages involved: %s"
                        (String.concat ", " cycleNames)
                  Span     = zeroSpan }

        // Map from package name → its in-project artifact, populated
        // as we iterate in topo order.  Each downstream package's
        // intra-project import resolution consults this map.
        let intraArtifacts = Dictionary<string, StdlibArtifact>()
        // Map from package name → the stdlib (kernel/builtin) artifacts
        // that were in scope when that package was emitted.  Used by
        // resolveIntraImports to propagate transitive stdlib items to
        // downstream in-project importers (e.g. so Std.Iter can see
        // Std.CollectionsHost items via its import of Std.Collections).
        let intraStdlibDeps = Dictionary<string, StdlibArtifact list>()
        // Shared `qualifiedName -> System.Type` lookup table populated
        // by every package's `emitAssembly` call as its `TypeBuilder`s
        // get sealed.  We can't use `ModuleBuilder.GetType` for this
        // because `PersistedAssemblyBuilder`'s `ModuleBuilder` doesn't
        // implement `GetType` / `GetTypes`.
        let typesByName = Dictionary<string, System.Type>()
        // Build a `StdlibArtifact` view of an already-emitted
        // in-project package.  `Lookup` walks the shared
        // `typesByName` table rather than a real `Assembly` (the
        // bundled DLL hasn't been written yet).
        let buildIntraArtifact (resolved: SourceFile)
                               (symbols: SymbolTable)
                               (sigs: Map<string, ResolvedSignature>) : StdlibArtifact =
            { AssemblyPath = ""
              Assembly     = None
              Source       = resolved
              Symbols      = symbols
              Signatures   = sigs
              Lookup       =
                fun n ->
                    match typesByName.TryGetValue n with
                    | true, t -> Some t
                    | _       -> None }

        /// Strip intra-project imports from a parsed source so the
        /// downstream `resolveStdlibImports` / type checker stops
        /// flagging them as unknown.  Returns the stripped source +
        /// the matched in-project artifacts (plus their transitive stdlib
        /// deps) so `emitAssembly` sees all necessary items.
        let resolveIntraImports (sf: SourceFile)
                                : SourceFile * Item list * StdlibArtifact list =
            let intraImps, otherImps =
                sf.Imports
                |> List.partition (fun i ->
                    let key = String.concat "." i.Path.Segments
                    projectPackageSet.Contains key)
            if List.isEmpty intraImps then sf, [], []
            else
                // Packages already present in the remaining (non-intra) imports
                // will be resolved by resolveStdlibImports; skip them when
                // propagating transitive deps to avoid duplicate items.
                let remainingKeys =
                    otherImps
                    |> List.map (fun i -> String.concat "." i.Path.Segments)
                    |> HashSet<string>
                let arts = ResizeArray<StdlibArtifact>()
                let items = ResizeArray<Item>()
                let visited = HashSet<string>()
                for imp in intraImps do
                    let key = String.concat "." imp.Path.Segments
                    match intraArtifacts.TryGetValue key with
                    | true, a when visited.Add key ->
                        arts.Add a
                        for it in a.Source.Items do items.Add it
                        // Propagate transitive stdlib (kernel/builtin) deps
                        // so downstream type-checks see their items.
                        // Example: Std.Iter imports Std.Collections (in-
                        // project); Std.Collections needed Std.CollectionsHost
                        // for List[T] / newList.  Without this, Std.Iter
                        // would not see those names.
                        // Skip any dep whose package key is already in the
                        // remaining import set (resolveStdlibImports will
                        // handle those, avoiding duplicates).
                        match intraStdlibDeps.TryGetValue key with
                        | true, sdeps ->
                            for sdep in sdeps do
                                let sdepPkgKey =
                                    String.concat "." sdep.Source.Package.Path.Segments
                                if not (remainingKeys.Contains sdepPkgKey) then
                                    let visitKey = "stdlib:" + sdepPkgKey
                                    if visited.Add visitKey then
                                        arts.Add sdep
                                        for it in sdep.Source.Items do items.Add it
                        | _ -> ()
                    | _ -> ()
                { sf with Imports = otherImps },
                List.ofSeq items,
                List.ofSeq arts

        // ---- Phase A2: emit each package in topo order.  Each
        // ---- package's import surface combines stdlib + restored +
        // ---- in-project artifacts.
        let emitOrder =
            // On cycle, fall back to the user-declared order so we
            // still surface as much downstream emit as possible.
            // The B0020 above will be the dominant diagnostic.
            if List.isEmpty cycleNames then
                order |> Seq.toList
            else
                req.Packages |> List.map (fun p -> p.PackageName)
        // Pre-scan: only the (single) package containing `func main`
        // emits as an executable; the rest emit library-shaped so
        // their `Program` types don't claim a duplicate entry point.
        // The host MethodInfo from that package's emit is captured
        // and used as `Backend.save`'s entry point so the bundled DLL
        // is `dotnet exec`-runnable.
        let packageHasMain (pkgName: string) : bool =
            let parsed, _ = parsedByName.[pkgName]
            parsed.File.Items
            |> List.exists (fun it ->
                match it.Kind with
                | IFunc fn -> fn.Name = "main"
                | _ -> false)
        let mainPackage =
            emitOrder |> List.tryFind packageHasMain
        let bundleMain : MethodInfo option ref = ref None
        for pkgName in emitOrder do
            let parsed, combinedSrc = parsedByName.[pkgName]
            let afterIntra, intraItems, intraArts = resolveIntraImports parsed.File
            let afterRestored, restoredItems, restoredArtifacts, restoredDiags =
                resolveRestoredImports afterIntra req.RestoredPackages
            let resolved, importedItems, stdlibArtifacts, stdImports, importDiags =
                resolveStdlibImports req.Target afterRestored
            let mergedImportedItems =
                let seen = System.Collections.Generic.HashSet<string>()
                (intraItems @ restoredItems @ importedItems)
                |> List.filter (fun it ->
                    match itemConflictKey it with
                    | None     -> true
                    | Some key -> seen.Add key)
            let mergedArtifacts = intraArts @ restoredArtifacts @ stdlibArtifacts
            let checked' =
                Lyric.TypeChecker.Checker.checkWithImports resolved mergedImportedItems
            allDiags.AddRange restoredDiags
            allDiags.AddRange importDiags
            allDiags.AddRange checked'.Diagnostics
            // Track main-fn count for B0021 (multiple `pub func main`
            // in single-output project).
            for it in resolved.Items do
                match it.Kind with
                | IFunc fn when fn.Name = "main" -> mainCount <- mainCount + 1
                | _ -> ()
            let perPkgReq : EmitRequest =
                { Source             = combinedSrc
                  AssemblyName       = req.AssemblyName
                  OutputPath         = req.OutputPath
                  RestoredPackages   = req.RestoredPackages
                  NugetAssemblyPaths = req.NugetAssemblyPaths
                  ExternShimRoot     = req.ExternShimRoot
                  Target             = req.Target
                  ActiveFeatures     = req.ActiveFeatures
                  DeclaredFeatures   = req.DeclaredFeatures }
            let isMainPkg = (Some pkgName = mainPackage)
            let mainOutForCall =
                if isMainPkg then Some bundleMain else None
            let pkgEmitDiags =
                emitAssembly
                    resolved
                    checked'.Signatures
                    checked'.Symbols
                    perPkgReq
                    (not isMainPkg)          // main-bearing pkg emits exec; others library
                    mergedArtifacts
                    stdImports
                    (Some ctx)
                    (Some typesByName)
                    mainOutForCall
            allDiags.AddRange pkgEmitDiags
            perPackageContracts.Add(pkgName, resolved, checked'.Signatures)
            // Capture this package as an in-project artifact for
            // downstream packages.  Skip on emit failure — the
            // backend's reflection state for this package may be
            // half-finalised and feeding it to a downstream emit
            // would risk surfacing TypeBuilder-instantiation errors
            // that obscure the real cause.
            let pkgFatal =
                pkgEmitDiags |> List.exists (fun d -> d.Severity = DiagError)
            if not pkgFatal then
                intraArtifacts.[pkgName] <-
                    buildIntraArtifact resolved checked'.Symbols checked'.Signatures
                intraStdlibDeps.[pkgName] <- stdlibArtifacts
        // B0021 — multiple `pub func main` across packages in the
        // single-output project.  Surface once after the full pass
        // so a downstream test can ASSERT the diagnostic regardless
        // of which package emitted main first.
        if mainCount > 1 then
            let zeroSpan = Span.make Position.initial Position.initial
            allDiags.Add
                { Severity = DiagError
                  Code     = "B0021"
                  Message  =
                    sprintf
                        "project `%s` declares %d `pub func main` decls; expected at most 1"
                        req.AssemblyName mainCount
                  Span     = zeroSpan }
        let fatal =
            allDiags |> Seq.exists (fun d -> d.Severity = DiagError)
        if fatal then
            // Don't save partially-emitted IL on a fatal diagnostic —
            // the Backend's reflection-emit state is unsealed and the
            // PE would be corrupt.
            { OutputPath  = None
              Diagnostics = List.ofSeq allDiags }
        else
            // Phase B — save the bundled assembly to disk.  When the
            // project contains a `func main` in any of its packages,
            // that package's host wrapper becomes the bundled DLL's
            // entry point (M5.1 stage 2c.2.iv).  Bundles without
            // `main` save as library-shaped (no entry point).
            try
                Backend.save ctx bundleMain.Value
            with e ->
                allDiags.Add
                    { Severity = DiagError
                      Code     = "B0098"
                      Message  =
                        sprintf "Backend.save failed: %s" e.Message
                      Span     = Span.make Position.initial Position.initial }
            // Phase C — embed one `Lyric.Contract.<Pkg>` per package.
            for (pkgName, resolved, _sigs) in perPackageContracts do
                try
                    let contract = ContractMeta.buildContract resolved "0.1.0"
                    let json = ContractMeta.toJson contract
                    ContractMeta.embedIntoAssemblyAs
                        req.OutputPath
                        ("Lyric.Contract." + pkgName)
                        json
                with e ->
                    allDiags.Add
                        { Severity = DiagWarning
                          Code     = "E0900"
                          Message  =
                            sprintf
                                "could not embed Lyric.Contract.%s resource: %s"
                                pkgName e.Message
                          Span     = Span.make Position.initial Position.initial }
            // Phase D — embed `Lyric.SdkVersion` resource (docs/22 §5).
            // Present on every project DLL so installed builds can verify
            // language / stdlib / compiler version at compile time.
            try
                let now = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                let json =
                    sprintf
                        "{ \"language_version\": \"0.1\", \"stdlib_version\": \"0.1.0\", \"compiler_version\": \"0.1.0-bootstrap\", \"build_date\": \"%s\" }"
                        now
                ContractMeta.embedIntoAssemblyAs req.OutputPath "Lyric.SdkVersion" json
            with e ->
                allDiags.Add
                    { Severity = DiagWarning
                      Code     = "B0042"
                      Message  =
                        sprintf "could not embed Lyric.SdkVersion resource: %s" e.Message
                      Span     = Span.make Position.initial Position.initial }
            { OutputPath  = Some req.OutputPath
              Diagnostics = List.ofSeq allDiags }
