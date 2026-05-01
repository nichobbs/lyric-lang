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
        (id: InterfaceDecl) : Records.InterfaceInfo =
    let fullName =
        if String.IsNullOrEmpty nsName then id.Name
        else nsName + "." + id.Name
    let tb =
        md.DefineType(
            fullName,
            TypeAttributes.Public
            ||| TypeAttributes.Interface
            ||| TypeAttributes.Abstract,
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
                let pTys =
                    fs.Params
                    |> List.map (fun p -> resolveTy p.Type)
                    |> List.toArray
                let bareRet = resolveRet fs.Return
                let rTy = if fs.IsAsync then toTaskType bareRet else bareRet
                let mb =
                    tb.DefineMethod(
                        fs.Name,
                        MethodAttributes.Public
                        ||| MethodAttributes.Abstract
                        ||| MethodAttributes.Virtual
                        ||| MethodAttributes.HideBySig
                        ||| MethodAttributes.NewSlot,
                        rTy,
                        pTys)
                fs.Params
                |> List.iteri (fun i p ->
                    mb.DefineParameter(i + 1, ParameterAttributes.None, p.Name)
                    |> ignore)
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
            TypeAttributes.Public
            ||| TypeAttributes.Sealed
            ||| TypeAttributes.SequentialLayout
            ||| TypeAttributes.BeforeFieldInit,
            typeof<System.ValueType>)
    let valueField =
        tb.DefineField("Value", underlyingClr, FieldAttributes.Public)

    // Range-bound evaluation.  The bootstrap accepts integer literals
    // only; symbolic bounds fall through to "no compile-time check".
    // `upperExclusive` is true for `a ..< b` / `a .. b` half-open ranges.
    let evalLiteral (e: Expr) : uint64 option =
        match e.Kind with
        | ELiteral (LInt (n, _)) -> Some n
        | _ -> None
    let literalBounds : (uint64 * uint64 * bool) option =
        match dt.Range with
        | Some (RBClosed(loExpr, hiExpr)) ->
            match evalLiteral loExpr, evalLiteral hiExpr with
            | Some lo, Some hi -> Some (lo, hi, false)
            | _ -> None
        | Some (RBHalfOpen(loExpr, hiExpr)) ->
            match evalLiteral loExpr, evalLiteral hiExpr with
            | Some lo, Some hi -> Some (lo, hi, true)
            | _ -> None
        | _ -> None

    // Emit `if x < lo || x op_hi hi goto failLbl`, where op_hi is `>`
    // for closed ranges and `>=` for half-open ranges.
    let emitBoundsCheck (il: ILGenerator) (failLbl: Label)
            (lo: uint64) (hi: uint64) (upperExclusive: bool) : unit =
        let emitConst (n: uint64) =
            if underlyingClr = typeof<int64> then
                il.Emit(OpCodes.Ldc_I8, int64 n)
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
      Records.DistinctTypeInfo.TryFromMethod = tryFromMethod }

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

/// Define the abstract base + sealed per-case subclasses for a Lyric
/// union.  Non-generic unions use proper CLR nested types for the
/// case classes (keeps the PE TypeRef metadata clean for cross-
/// assembly references).  Generic unions emit each case as its own
/// top-level generic class whose type params shadow the parent's,
/// inheriting from the constructed parent — Reflection.Emit's nested-
/// generic-type story has friction the bootstrap sidesteps.
let private defineUnion
        (md: ModuleBuilder)
        (nsName: string)
        (symbols: SymbolTable)
        (ud: UnionDecl) : Records.UnionInfo =
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
            TypeAttributes.Public ||| TypeAttributes.Abstract,
            typeof<obj>)
    let baseTps =
        if isGeneric
        then baseTy.DefineGenericParameters(typeParamNames |> List.toArray)
        else [||]

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

    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    if isGeneric then resolveCtx.Push(typeParamNames)

    let cases =
        ud.Cases
        |> List.map (fun c ->
            // Generic unions emit cases as top-level generic classes
            // (each with its own copy of the parent's type params,
            // inheriting from the constructed parent).  Non-generic
            // unions stay nested so cross-assembly TypeRefs are clean.
            let caseTy, caseTps, caseSubst, caseParentForCtor =
                if isGeneric then
                    let caseFull = fullName + "_" + c.Name
                    let tb =
                        md.DefineType(
                            caseFull,
                            TypeAttributes.Public ||| TypeAttributes.Sealed,
                            typeof<obj>)
                    let tps = tb.DefineGenericParameters(typeParamNames |> List.toArray)
                    let parentOnCaseTps =
                        baseTy.MakeGenericType(tps |> Array.map (fun t -> t :> System.Type))
                    tb.SetParent(parentOnCaseTps)
                    let subst =
                        typeParamNames
                        |> List.mapi (fun i name -> name, tps.[i] :> System.Type)
                        |> Map.ofList
                    tb, tps, subst, Some parentOnCaseTps
                else
                    let tb =
                        baseTy.DefineNestedType(
                            c.Name,
                            TypeAttributes.NestedPublic ||| TypeAttributes.Sealed,
                            baseTy :> System.Type)
                    tb, [||], Map.empty, None
            let payload =
                c.Fields
                |> List.mapi (fun i f ->
                    let lty, fname =
                        match f with
                        | UFNamed (n, te, _) ->
                            Resolver.resolveType symbols resolveCtx scratchDiags te,
                            n
                        | UFPos (te, _) ->
                            Resolver.resolveType symbols resolveCtx scratchDiags te,
                            sprintf "Item%d" (i + 1)
                    let cty =
                        if isGeneric then
                            // Generic unions: substitute TyVar via the
                            // case's GTPBs, leaving everything else to
                            // the regular type lowering.
                            TypeMap.toClrTypeWithGenerics
                                (fun _ -> None) caseSubst lty
                        else
                            // Erasure path (D035) for non-generic
                            // unions: keep TyVar / TyUser as `obj`.
                            match lty with
                            | TyPrim _ | TySlice _ | TyArray _ | TyTuple _ ->
                                TypeMap.toClrType lty
                            | _ -> typeof<obj>
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
            // Reference parent ctor: for generic unions, the call must
            // go through `TypeBuilder.GetConstructor` on the parent
            // instantiated to the case's GTPBs.
            match caseParentForCtor with
            | Some parent ->
                let parentCtorRef = TypeBuilder.GetConstructor(parent, baseCtor)
                cil.Emit(OpCodes.Call, parentCtorRef)
            | None ->
                cil.Emit(OpCodes.Call, baseCtor)
            payload
            |> List.iteri (fun i f ->
                cil.Emit(OpCodes.Ldarg_0)
                cil.Emit(OpCodes.Ldarg, i + 1)
                cil.Emit(OpCodes.Stfld, f.Field))
            cil.Emit(OpCodes.Ret)
            { Records.UnionCaseInfo.Name   = c.Name
              Records.UnionCaseInfo.Type   = caseTy
              Records.UnionCaseInfo.Fields = payload
              Records.UnionCaseInfo.Ctor   = ctor })
    { Records.UnionInfo.Name     = ud.Name
      Records.UnionInfo.Type     = baseTy
      Records.UnionInfo.Cases    = cases
      Records.UnionInfo.Generics = typeParamNames }

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
        (od: OpaqueTypeDecl) : ProjectableStub =
    let viewName = od.Name + "View"
    let fullName =
        if String.IsNullOrEmpty nsName then viewName
        else nsName + "." + viewName
    let tb =
        md.DefineType(
            fullName,
            TypeAttributes.Public ||| TypeAttributes.Sealed,
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
            { Records.RecordField.Name  = fd.Name
              Records.RecordField.Type  = viewClr
              Records.RecordField.Field = fb })
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
    { Records.RecordInfo.Name   = stub.ViewName
      Records.RecordInfo.Type   = stub.ViewBuilder
      Records.RecordInfo.Fields = fields
      Records.RecordInfo.Ctor   = ctor }

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
                MethodAttributes.Public ||| MethodAttributes.Static,
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
                MethodAttributes.Public ||| MethodAttributes.Static)
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
/// MethodInfo for the LyricAssertionException constructor accepting
/// a string message. Resolved once per emit run.
let private lyricAssertCtor : Lazy<ConstructorInfo> =
    lazy (
        let exTy = typeof<Lyric.Stdlib.LyricAssertionException>
        match Option.ofObj (exTy.GetConstructor([| typeof<string> |])) with
        | Some c -> c
        | None   -> failwith "LyricAssertionException(string) ctor not found")

/// Emit a runtime contract check: evaluate `cond`; on false, throw
/// `LyricAssertionException(message)`.
let private emitContractCheck
        (ctx: Codegen.FunctionCtx)
        (cond: Expr)
        (label: string) : unit =
    let il = ctx.IL
    let _ = Codegen.emitExpr ctx cond
    let okLbl = il.DefineLabel()
    il.Emit(OpCodes.Brtrue, okLbl)
    il.Emit(OpCodes.Ldstr, label)
    il.Emit(OpCodes.Newobj, lyricAssertCtor.Value)
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
    // Force-touch one type from `Lyric.Stdlib` so the assembly is in
    // the AppDomain before we walk it — without this, the FFI resolver
    // can't find host-side wrapper types like `Lyric.Stdlib.IntList`
    // until some other code path has already loaded the assembly.
    let _ = typeof<Lyric.Stdlib.Console>
    let direct = System.Type.GetType qualifiedName
    match Option.ofObj direct with
    | Some t -> Some t
    | None ->
        System.AppDomain.CurrentDomain.GetAssemblies()
        |> Array.tryPick (fun asm ->
            try
                Option.ofObj (asm.GetType qualifiedName)
            with _ -> None)

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

/// Result of `@externTarget` lookup.  Constructors live on a separate
/// reflection API (`ConstructorInfo`) from regular methods, so we can't
/// fold them into the same `MethodInfo`-shaped return.
type private ExternBclMember =
    | EBMMethod of MethodInfo
    | EBMCtor   of ConstructorInfo

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
        let staticTyped =
            candidates memberName isStatic
            |> Array.tryFind (fun m -> paramsExactMatch m paramTypes)
        let mi =
            match staticTyped with
            | Some m -> Some m
            | None ->
                let staticArity =
                    candidates memberName isStatic
                    |> Array.tryFind (fun m -> m.GetParameters().Length = arity)
                match staticArity with
                | Some m -> Some m
                | None when arity >= 1 ->
                    let instanceTyped =
                        candidates memberName isInstance
                        |> Array.tryFind (fun m ->
                            paramsExactMatch m (Array.skip 1 paramTypes))
                    match instanceTyped with
                    | Some m -> Some m
                    | None ->
                        let instanceArity =
                            candidates memberName isInstance
                            |> Array.tryFind (fun m -> m.GetParameters().Length = arity - 1)
                        match instanceArity with
                        | Some m -> Some m
                        | None ->
                            let prop = t.GetProperty memberName
                            match Option.ofObj prop with
                            | Some p when p.CanRead ->
                                Option.ofObj (p.GetGetMethod())
                            | _ -> None
                | None ->
                    let prop = t.GetProperty memberName
                    match Option.ofObj prop with
                    | Some p when p.CanRead ->
                        Option.ofObj (p.GetGetMethod())
                    | _ -> None
        mi |> Option.map EBMMethod

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
    // contains GenericTypeParameterBuilder instances.  Both also accept
    // fully-resolved closed types (no TypeBuilder), so we can call them
    // unconditionally.
    let isOpenGenericDeclaring (declaring: System.Type | null) : bool =
        match Option.ofObj declaring with
        | Some d -> d.IsGenericTypeDefinition
        | None   -> false
    let unwrapDeclaring (declaring: System.Type | null) : System.Type =
        match Option.ofObj declaring with
        | Some d -> d
        | None   -> failwithf "FFI: declaring type missing on extern target `%s`" target
    let closedResolved =
        match resolved with
        | EBMMethod m when isOpenGenericDeclaring m.DeclaringType ->
            let closedTy = openClosedClr (unwrapDeclaring m.DeclaringType)
            EBMMethod (System.Reflection.Emit.TypeBuilder.GetMethod(closedTy, m))
        | EBMCtor c when isOpenGenericDeclaring c.DeclaringType ->
            let closedTy = openClosedClr (unwrapDeclaring c.DeclaringType)
            EBMCtor (System.Reflection.Emit.TypeBuilder.GetConstructor(closedTy, c))
        | other -> other
    // Push every Lyric parameter onto the stack in declaration order.
    paramList
    |> List.iteri (fun i _ -> il.Emit(OpCodes.Ldarg, i))
    // Constructors get `newobj`; static methods + property getters use
    // `call`; non-static instance methods use `callvirt`.
    let pushedTy =
        match closedResolved with
        | EBMCtor c ->
            il.Emit(OpCodes.Newobj, c)
            c.DeclaringType
        | EBMMethod m ->
            if m.IsStatic then il.Emit(OpCodes.Call, m)
            else il.Emit(OpCodes.Callvirt, m)
            m.ReturnType
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

let private emitFunctionBody
        (mb: MethodBuilder)
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
        (distinctTypes: Records.DistinctTypeTable)
        (projectables: Records.ProjectableTable)
        (importedRecords: Records.ImportedRecordTable)
        (importedUnions: Records.ImportedUnionTable)
        (importedUnionCases: Records.ImportedUnionCaseLookup)
        (importedFuncs: Records.ImportedFuncTable)
        (importedDistinctTypes: Records.ImportedDistinctTypeTable)
        (isInstance: bool)
        (selfType: System.Type option)
        (programType: TypeBuilder)
        (symbols: SymbolTable)
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
    let genericSubst : Map<string, System.Type> =
        if sg.Generics.IsEmpty then Map.empty
        else
            let gtpbs = mb.GetGenericArguments()
            sg.Generics
            |> List.mapi (fun i name -> name, gtpbs.[i])
            |> Map.ofList
    let bareReturnTy =
        TypeMap.toClrReturnTypeWithGenerics lookup genericSubst sg.Return
    let methodReturnTy =
        if sg.IsAsync then toTaskType bareReturnTy else bareReturnTy
    let returnTy = bareReturnTy
    let paramList =
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
    let ctx =
        Codegen.FunctionCtx.make
            il returnTy paramList
            funcs funcSigs records enums enumCases unions unionCases
            interfaces distinctTypes projectables
            importedRecords importedUnions importedUnionCases
            importedFuncs importedDistinctTypes
            isInstance selfType programType resolveTypeForCtx lookup diags
    ignore methodReturnTy

    // Single exit point: every return path stores the value (if any)
    // and branches here. The label site emits `ensures:` checks and
    // the actual `ret`. Empty body / value-less paths still flow
    // through this exit.
    let exitLabel = il.DefineLabel()
    let isVoidReturn = returnTy = typeof<System.Void>
    let resultLocal =
        if isVoidReturn then None
        else Some (il.DeclareLocal(returnTy))
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
    match resultLocal with
    | Some loc -> il.Emit(OpCodes.Ldloc, loc)
    | None     -> ()
    if sg.IsAsync then
        if isVoidReturn then
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
type private StdlibArtifact =
    { /// Absolute path to the compiled `Lyric.Stdlib.Core.dll`.
      AssemblyPath: string
      /// Loaded into the current process via `Assembly.LoadFrom`.
      Assembly:     Assembly
      /// Parsed AST of `core.l`.
      Source:       SourceFile
      /// The stdlib's symbol table (typeids are stdlib-local).
      Symbols:      SymbolTable
      /// Resolved signatures for every stdlib function.
      Signatures:   Map<string, ResolvedSignature> }

let private emitAssembly
        (sf: SourceFile)
        (sigs: Map<string, ResolvedSignature>)
        (symbols: SymbolTable)
        (req: EmitRequest)
        (isLibrary: bool)
        (stdlibArtifacts: StdlibArtifact list) : Diagnostic list =
    let funcs = functionItems sf
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
        let ctx = Backend.create desc
        let codegenDiags = ResizeArray<Diagnostic>()
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
        for artifact in stdlibArtifacts do
            let asm = artifact.Assembly
            let stdNs = String.concat "." artifact.Source.Package.Path.Segments
            let qualify name =
                if String.IsNullOrEmpty stdNs then name
                else stdNs + "." + name
            let getType (n: string) : System.Type option =
                Option.ofObj (asm.GetType n)
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
                                // Generic unions emit case classes as top-
                                // level types named `<NS>.<Union>_<Case>`
                                // (per `defineUnion`'s generic path).  Non-
                                // generic unions use proper nested CLR
                                // types so `+` is the right separator.
                                let caseFullName =
                                    if isGeneric then
                                        qualify ud.Name + "_" + c.Name
                                    else
                                        qualify ud.Name + "+" + c.Name
                                match getType caseFullName with
                                | None -> None
                                | Some caseTy ->
                                    let ctorOpt =
                                        caseTy.GetConstructors()
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
                                        caseTy.GetFields()
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
                                    match ctorOpt with
                                    | None -> None
                                    | Some ctor ->
                                        Some
                                            { Records.ImportedUnionCaseInfo.Name = c.Name
                                              Records.ImportedUnionCaseInfo.Type = caseTy
                                              Records.ImportedUnionCaseInfo.Fields = fields
                                              Records.ImportedUnionCaseInfo.Ctor = ctor })
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
                        match miOpt, Map.tryFind arityKey artifact.Signatures with
                        | Some mi, Some sg ->
                            let info =
                                { Records.ImportedFuncInfo.Method = mi
                                  Records.ImportedFuncInfo.Sig    = sg }
                            importedFuncTable.[fn.Name]  <- info
                            importedFuncTable.[arityKey] <- info
                        | _ ->
                            match miOpt, Map.tryFind fn.Name artifact.Signatures with
                            | Some mi, Some sg ->
                                let info =
                                    { Records.ImportedFuncInfo.Method = mi
                                      Records.ImportedFuncInfo.Sig    = sg }
                                importedFuncTable.[fn.Name]  <- info
                                importedFuncTable.[arityKey] <- info
                            | _ -> ()
                    | _ -> ()

        for rd in recordItems sf do
            let info = defineRecord ctx.Module nsName symbols rd
            recordTable.[rd.Name] <- info
            symbols.TryFind rd.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- info.Type :> System.Type)

        // Opaque types — bootstrap-grade: lower as records.  Visibility
        // is unenforced because we still compile a single package.
        let projectableOpaques = ResizeArray<OpaqueTypeDecl * Records.RecordInfo>()
        for od in opaqueItems sf do
            let info = defineRecord ctx.Module nsName symbols (opaqueAsRecord od)
            recordTable.[od.Name] <- info
            symbols.TryFind od.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- info.Type :> System.Type)
            if isProjectable od then projectableOpaques.Add(od, info)
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

        let unionTable = Records.UnionTable()
        let unionCaseLookup = Records.UnionCaseLookup()
        for ud in unionItems sf do
            let info = defineUnion ctx.Module nsName symbols ud
            unionTable.[ud.Name] <- info
            for c in info.Cases do
                unionCaseLookup.[c.Name] <- (info, c)
                unionCaseLookup.[ud.Name + "." + c.Name] <- (info, c)
            symbols.TryFind ud.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun id -> typeIdToClr.[id] <- info.Type :> System.Type)

        let lookup =
            fun (id: TypeId) ->
                match typeIdToClr.TryGetValue id with
                | true, t  -> Some t
                | false, _ -> None

        let interfaceTable = Records.InterfaceTable()
        for id in interfaceItems sf do
            let info = defineInterface ctx.Module nsName symbols lookup id
            interfaceTable.[id.Name] <- info
            symbols.TryFind id.Name
            |> Seq.tryHead
            |> Option.bind Symbol.typeIdOpt
            |> Option.iter (fun tid -> typeIdToClr.[tid] <- info.Type :> System.Type)

        // Projectable opaque types — synthesise `<Name>View` exposed
        // record + a `toView()` instance method.  Three staged passes
        // so cross-referencing projectables can each see the other's
        // view TypeBuilder + `toView` MethodBuilder before any field
        // or IL is emitted.  Recursive projection: a field whose
        // source CLR type is itself a projectable opaque substitutes
        // the corresponding view type, and `toView()` calls the
        // nested `toView()` to project the value.
        let projectableTable = Records.ProjectableTable()
        let stubByOpaqueClr = Dictionary<System.Type, ProjectableStub>()
        let stubs =
            projectableOpaques
            |> Seq.toList
            |> List.map (fun (od, opaqueInfo) ->
                let stub = defineProjectableViewStub ctx.Module nsName opaqueInfo od
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
                    ctx.Module nsName lookup symbols importedUnionTable dt
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
            let targetName =
                match impl.Target.Kind with
                | TRef p ->
                    match p.Segments with
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
                let resolveCtx = GenericContext()
                let scratchDiags = ResizeArray<Diagnostic>()
                for m in impl.Members do
                    match m with
                    | IMplFunc fd ->
                        // Impl-method signatures aren't in the type
                        // checker's top-level signature map; resolve
                        // each parameter and the return type directly.
                        let resolveTy (te: TypeExpr) : System.Type =
                            let lty =
                                Resolver.resolveType
                                    symbols resolveCtx scratchDiags te
                            TypeMap.toClrTypeWith lookup lty
                        let pTys =
                            fd.Params
                            |> List.map (fun p -> resolveTy p.Type)
                            |> List.toArray
                        let bareRet =
                            match fd.Return with
                            | Some t ->
                                let lty =
                                    Resolver.resolveType
                                        symbols resolveCtx scratchDiags t
                                TypeMap.toClrReturnTypeWith lookup lty
                            | None -> typeof<System.Void>
                        let rTy =
                            if fd.IsAsync then toTaskType bareRet else bareRet
                        let mb =
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
                        // Synthesise a ResolvedSignature so the body
                        // emitter can use the same code path.
                        let synthSig : ResolvedSignature =
                            { Generics = []
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
                    | IMplAssoc _ -> ()
            | _ ->
                // Target type or interface not in scope — skipped.
                // The type checker has already surfaced a diagnostic.
                ()

        // Pass B — emit bodies (free-standing funcs). Look up the body
        // target by arity-qualified key first so overloaded functions
        // each get their own MethodBuilder body.
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
            emitFunctionBody
                mb fn sg lookup
                methodTable funcSigsTable recordTable enumTable enumCases
                unionTable unionCaseLookup interfaceTable distinctTable projectableTable
                importedRecordTable importedUnionTable importedUnionCaseLookup
                importedFuncTable importedDistinctTypeTable
                false None
                programTy symbols codegenDiags

        // Pass B.5 — emit impl-method bodies as instance methods.
        for (fd, mb, sg) in implMethods do
            // The self-type is whatever record this method was
            // attached to; recover it via the method's declaring
            // type (which we just set in Pass A.5).
            let selfTy = mb.DeclaringType
            emitFunctionBody
                mb fd sg lookup
                methodTable funcSigsTable recordTable enumTable enumCases
                unionTable unionCaseLookup interfaceTable distinctTable projectableTable
                importedRecordTable importedUnionTable importedUnionCaseLookup
                importedFuncTable importedDistinctTypeTable
                true
                (Option.ofObj selfTy) programTy symbols codegenDiags

        let lyricMainOpt =
            if isLibrary then None
            else
                match methodTable.TryGetValue "main" with
                | true, m -> Some m
                | _       -> None
        let hostMainOpt =
            lyricMainOpt
            |> Option.map (fun m -> defineHostEntryPoint programTy m)

        // Finalise every type so the persisted PE captures their
        // metadata. Interfaces seal first so records can claim them;
        // unions seal subclasses before their abstract base.
        for kv in interfaceTable do
            kv.Value.Type.CreateType() |> ignore
        for kv in recordTable do
            kv.Value.Type.CreateType() |> ignore
        for kv in unionTable do
            for c in kv.Value.Cases do
                c.Type.CreateType() |> ignore
            kv.Value.Type.CreateType() |> ignore
        programTy.CreateType() |> ignore
        Backend.save ctx (hostMainOpt |> Option.map (fun m -> m :> MethodInfo))
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

/// Walk up the directory tree from `startDir` looking for the `.l`
/// file backing the given `Std.X[.Y…]` package.
/// Locate the `.l` source for a stdlib package segment list.
/// Search order:
///   1. `LYRIC_STD_PATH` env var, if set — allows installed/out-of-tree setups.
///   2. Walk up the directory tree from `startDir` (the CLI binary's base
///      directory) looking for a `lyric/std/` subdirectory — works when the
///      binary lives inside the source tree.
let private locateStdlibFile
        (startDir: string)
        (segments: string list) : string option =
    match segments with
    | "Std" :: rest when not (List.isEmpty rest) ->
        let baseName =
            rest
            |> List.map segmentToFileBase
            |> String.concat "_"
        let fileName = baseName + ".l"
        // 1) LYRIC_STD_PATH override.
        let envHit =
            match Option.ofObj (System.Environment.GetEnvironmentVariable "LYRIC_STD_PATH") with
            | Some p ->
                let candidate = Path.Combine(p, fileName)
                if File.Exists candidate then Some candidate else None
            | None -> None
        match envHit with
        | Some _ -> envHit
        | None ->
            // 2) Walk up from the binary's base directory.
            let mutable dir = Some (DirectoryInfo(startDir))
            let mutable found : string option = None
            while found.IsNone && dir.IsSome do
                let d = dir.Value
                let candidate = Path.Combine(d.FullName, "lyric", "std", fileName)
                if File.Exists candidate then found <- Some candidate
                dir <- d.Parent |> Option.ofObj
            found
    | _ -> None

/// Recursively ensure that the given `Std.X[.Y…]` package is compiled,
/// returning its artifact and any diagnostics raised during the
/// compile chain.  Cached per-process; re-entrant calls hit the
/// cache.
let rec private ensureStdlibArtifact
        (segments: string list) : Result<StdlibArtifact, Diagnostic list> =
    let key = packageKey segments
    lock stdlibLock (fun () ->
        match stdlibArtifactCache.TryGetValue key with
        | true, a -> Ok a
        | _ ->
            match locateStdlibFile AppContext.BaseDirectory segments with
            | None ->
                let zeroSpan = Span.make Position.initial Position.initial
                Error [ err "E900"
                            (sprintf "cannot locate lyric source for stdlib module '%s'" key)
                            zeroSpan ]
            | Some path ->
                let src = File.ReadAllText path
                let parsed = parse src
                // Recursively compile every `Std.X` import the source
                // declares, so they're cached before this module emits.
                // Std.Core is auto-included even when not declared so
                // every stdlib module can rely on `Result` / `Option`.
                let stdImports =
                    parsed.File.Imports
                    |> List.choose (fun i ->
                        match i.Path.Segments with
                        | "Std" :: _ when i.Path.Segments <> segments ->
                            Some i.Path.Segments
                        | _ -> None)
                let allDeps =
                    let needsCore =
                        segments <> ["Std"; "Core"]
                        && not (List.exists ((=) ["Std"; "Core"]) stdImports)
                    if needsCore then ["Std"; "Core"] :: stdImports
                    else stdImports
                let mutable depDiags : Diagnostic list = []
                let depArtifacts =
                    allDeps
                    |> List.choose (fun s ->
                        match ensureStdlibArtifact s with
                        | Ok a -> Some a
                        | Error ds ->
                            depDiags <- depDiags @ ds
                            None)
                if not depDiags.IsEmpty then Error depDiags
                else
                    // Strip the cross-stdlib imports — they're handled
                    // by the artifact list, not the user-side
                    // `Item list` re-registration.  Non-`Std.*` imports
                    // (e.g. axiom externs to System.*) flow through.
                    let stripped =
                        let sf = parsed.File
                        { sf with
                            Imports =
                                sf.Imports
                                |> List.filter (fun i ->
                                    match i.Path.Segments with
                                    | "Std" :: _ -> false
                                    | _ -> true) }
                    let importedItems =
                        depArtifacts |> List.collect (fun a -> a.Source.Items)
                    let checked' =
                        Lyric.TypeChecker.Checker.checkWithImports stripped importedItems
                    let assemblyName =
                        "Lyric.Stdlib." + (List.tail segments |> String.concat "")
                    let outPath = Path.Combine(stdlibCacheDir, assemblyName + ".dll")
                    let req =
                        { Source       = src
                          AssemblyName = assemblyName
                          OutputPath   = outPath }
                    let emitDiags =
                        emitAssembly
                            stripped checked'.Signatures checked'.Symbols
                            req true depArtifacts
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
                              Assembly     = assembly
                              // Keep the original (unstripped) parse so
                              // the user-side visit can walk transitive
                              // `Std.X` deps.  The type-checker /
                              // emitter calls used `stripped`.
                              Source       = parsed.File
                              Symbols      = checked'.Symbols
                              Signatures   = checked'.Signatures }
                        stdlibArtifactCache.[key] <- artifact
                        Ok artifact)

/// Public accessor: returns the absolute paths to every compiled
/// stdlib DLL that has run so far.  The test harness uses this to
/// copy DLLs alongside each user output.
let stdlibAssemblyPath () : string option =
    lock stdlibLock (fun () ->
        match stdlibArtifactCache.TryGetValue "Std.Core" with
        | true, a -> Some a.AssemblyPath
        | _ -> None)

/// Every compiled stdlib DLL path that has been produced this
/// process.  Newer code (the test kit) copies all of them so user
/// programs that import multiple `Std.X` modules can resolve every
/// reference at runtime.
let stdlibAssemblyPaths () : string list =
    lock stdlibLock (fun () ->
        stdlibArtifactCache.Values
        |> Seq.map (fun a -> a.AssemblyPath)
        |> List.ofSeq)

/// Resolve `import Std.X` declarations: walk the dependency closure,
/// compile what's missing, and hand the artifact list + their parsed
/// items to the type checker / emitter.  The user's `SourceFile.Items`
/// is left unchanged; only `Std.*` imports are stripped.
let private resolveStdlibImports
        (sf: SourceFile)
        : SourceFile * Item list * StdlibArtifact list * Diagnostic list =
    let stdImports, otherImps =
        sf.Imports
        |> List.partition (fun i ->
            match i.Path.Segments with
            | "Std" :: _ -> true
            | _ -> false)
    if stdImports.IsEmpty then sf, [], [], []
    else
        let visited = HashSet<string>()
        let ordered = ResizeArray<StdlibArtifact>()
        let diags = ResizeArray<Diagnostic>()
        let rec visit segments =
            let key = packageKey segments
            if visited.Add key then
                match ensureStdlibArtifact segments with
                | Ok a ->
                    // Visit deps first so they appear before in the
                    // ordered list — type-checker import processing
                    // expects topo order.
                    let deps =
                        a.Source.Imports
                        |> List.choose (fun i ->
                            match i.Path.Segments with
                            | "Std" :: _ -> Some i.Path.Segments
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
        { sf with Imports = otherImps }, items, artifacts, List.ofSeq diags

/// Emit a Lyric source string to a persistent assembly.
let emit (req: EmitRequest) : EmitResult =
    let parsed   = parse req.Source
    let resolved, importedItems, stdlibArtifacts, importDiags =
        resolveStdlibImports parsed.File
    let checked' =
        Lyric.TypeChecker.Checker.checkWithImports resolved importedItems

    let upstream = parsed.Diagnostics @ importDiags @ checked'.Diagnostics
    let parserFatal =
        upstream
        |> List.exists (fun d ->
            d.Severity = DiagError && d.Code.StartsWith "P")
    // If any stdlib precompile failed, skip user-side emit — running
    // the emitter without populated import tables would crash with
    // "unknown name" exceptions that mask the real diagnostic.
    let importFatal =
        importDiags |> List.exists (fun d -> d.Severity = DiagError)

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
                stdlibArtifacts
        let emitFatal =
            emitDiags |> List.exists (fun d -> d.Severity = DiagError)
        let outputPath = if emitFatal then None else Some req.OutputPath
        { OutputPath  = outputPath
          Diagnostics = upstream @ emitDiags }
