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
/// `Some`), `From` performs a bounds check (panics on violation) and an
/// additional `TryFrom(x)` method is synthesised that returns the Lyric
/// `Result` union type — but since the `Result` union type is not yet built
/// at this point in the emitter, `TryFrom` is wired up only when the union
/// table is available (Phase 2.1+). For now the bounds check is in `From`.
let private defineDistinctType
        (md: ModuleBuilder)
        (nsName: string)
        (lookup: TypeId -> System.Type option)
        (symbols: SymbolTable)
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

    // Static `From(x)` factory.
    let fromMb =
        tb.DefineMethod(
            "From",
            MethodAttributes.Public ||| MethodAttributes.Static,
            tb,
            [| underlyingClr |])
    fromMb.DefineParameter(1, ParameterAttributes.None, "x") |> ignore
    let fromIl = fromMb.GetILGenerator()

    // Optional range check in `From`.
    match dt.Range with
    | Some (RBClosed(loExpr, hiExpr)) ->
        // Evaluate lo and hi as constant int32 expressions (literals only
        // for the bootstrap; full expression evaluation deferred to Phase 3).
        let evalLiteral (e: Expr) : uint64 option =
            match e.Kind with
            | ELiteral (LInt (n, _)) -> Some n
            | _ -> None
        match evalLiteral loExpr, evalLiteral hiExpr with
        | Some lo, Some hi ->
            // if x < lo || x > hi, throw InvalidOperationException
            let okLbl = fromIl.DefineLabel()
            let failLbl = fromIl.DefineLabel()
            fromIl.Emit(OpCodes.Ldarg_0)
            // Widen to int64 for comparison generality.
            if underlyingClr = typeof<int64> then
                fromIl.Emit(OpCodes.Ldc_I8, int64 lo)
            else
                fromIl.Emit(OpCodes.Ldc_I4, int lo)
            fromIl.Emit(OpCodes.Blt, failLbl)
            fromIl.Emit(OpCodes.Ldarg_0)
            if underlyingClr = typeof<int64> then
                fromIl.Emit(OpCodes.Ldc_I8, int64 hi)
            else
                fromIl.Emit(OpCodes.Ldc_I4, int hi)
            fromIl.Emit(OpCodes.Bgt, failLbl)
            fromIl.Emit(OpCodes.Br, okLbl)
            fromIl.MarkLabel(failLbl)
            let msg = sprintf "%s.from: value out of range [%d, %d]" dt.Name lo hi
            fromIl.Emit(OpCodes.Ldstr, msg)
            let ioe = typeof<System.InvalidOperationException>
            let ioCtor = ioe.GetConstructor([| typeof<string> |])
            match Option.ofObj ioCtor with
            | Some c -> fromIl.Emit(OpCodes.Newobj, c)
            | None -> failwith "InvalidOperationException(string) ctor not found"
            fromIl.Emit(OpCodes.Throw)
            fromIl.MarkLabel(okLbl)
        | _ -> ()  // non-literal bounds — skip check in bootstrap
    | _ -> ()  // no range constraint

    // Create and return the struct.
    let localVar = fromIl.DeclareLocal(tb)
    fromIl.Emit(OpCodes.Ldloca, localVar)
    fromIl.Emit(OpCodes.Initobj, tb)
    fromIl.Emit(OpCodes.Ldloca, localVar)
    fromIl.Emit(OpCodes.Ldarg_0)
    fromIl.Emit(OpCodes.Stfld, valueField)
    fromIl.Emit(OpCodes.Ldloc, localVar)
    fromIl.Emit(OpCodes.Ret)

    { Records.DistinctTypeInfo.Name       = dt.Name
      Records.DistinctTypeInfo.Type       = tb
      Records.DistinctTypeInfo.ValueField = valueField
      Records.DistinctTypeInfo.FromMethod = fromMb
      Records.DistinctTypeInfo.TryFromMethod = None }

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
/// union. Per D035, payload-field types are erased to `obj` in M1.4;
/// reified generics is a Phase 2 follow-up.
let private defineUnion
        (md: ModuleBuilder)
        (nsName: string)
        (symbols: SymbolTable)
        (ud: UnionDecl) : Records.UnionInfo =
    let fullName =
        if String.IsNullOrEmpty nsName then ud.Name
        else nsName + "." + ud.Name
    // Abstract base — no fields, no public ctor; cases extend it.
    let baseTy =
        md.DefineType(
            fullName,
            TypeAttributes.Public ||| TypeAttributes.Abstract,
            typeof<obj>)
    // Define a protected default ctor on the base so subclass ctors
    // can chain to it.
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

    // Resolve each case's payload field types via the type checker's
    // resolver. Erasure: TyVar / TyUser → obj.
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    let cases =
        ud.Cases
        |> List.map (fun c ->
            let caseFullName = fullName + "+" + c.Name
            let caseTy =
                md.DefineType(
                    caseFullName,
                    TypeAttributes.Public ||| TypeAttributes.Sealed,
                    baseTy :> System.Type)
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
                    // Erasure: anything that isn't already a CLR
                    // primitive lowers to obj. Reified generics
                    // upgrade this in Phase 2.
                    let cty =
                        match lty with
                        | TyPrim _ | TySlice _ | TyArray _ | TyTuple _ ->
                            TypeMap.toClrType lty
                        | _ -> typeof<obj>
                    let fb =
                        caseTy.DefineField(
                            fname,
                            cty,
                            FieldAttributes.Public ||| FieldAttributes.InitOnly)
                    { Records.UnionPayloadField.Name  = fname
                      Records.UnionPayloadField.Type  = cty
                      Records.UnionPayloadField.Field = fb })
            // Constructor: takes every payload field in order.
            let paramTypes =
                payload |> List.map (fun f -> f.Type) |> List.toArray
            let ctor =
                caseTy.DefineConstructor(
                    MethodAttributes.Public,
                    CallingConventions.Standard,
                    paramTypes)
            let cil = ctor.GetILGenerator()
            cil.Emit(OpCodes.Ldarg_0)
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
    { Records.UnionInfo.Name  = ud.Name
      Records.UnionInfo.Type  = baseTy
      Records.UnionInfo.Cases = cases }

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
let private defineProjectableView
        (md: ModuleBuilder)
        (nsName: string)
        (symbols: SymbolTable)
        (lookup: TypeId -> System.Type option)
        (opaque: OpaqueTypeDecl) : Records.RecordInfo =
    let viewName = opaque.Name + "View"
    let fullName =
        if String.IsNullOrEmpty nsName then viewName
        else nsName + "." + viewName
    let tb =
        md.DefineType(
            fullName,
            TypeAttributes.Public ||| TypeAttributes.Sealed,
            typeof<obj>)
    let resolveCtx = GenericContext()
    let scratchDiags = ResizeArray<Diagnostic>()
    let visibleFields =
        opaque.Members
        |> List.choose (function
            | OMField fd when not (isHiddenField fd) -> Some fd
            | _ -> None)
    let fields =
        visibleFields
        |> List.map (fun fd ->
            let lty =
                Resolver.resolveType symbols resolveCtx scratchDiags fd.Type
            let cty = TypeMap.toClrTypeWith lookup lty
            let fb =
                tb.DefineField(
                    fd.Name,
                    cty,
                    FieldAttributes.Public ||| FieldAttributes.InitOnly)
            { Records.RecordField.Name  = fd.Name
              Records.RecordField.Type  = cty
              Records.RecordField.Field = fb })
    let ctorParamTypes =
        fields |> List.map (fun f -> f.Type) |> List.toArray
    let ctor =
        tb.DefineConstructor(
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
    { Records.RecordInfo.Name   = viewName
      Records.RecordInfo.Type   = tb
      Records.RecordInfo.Fields = fields
      Records.RecordInfo.Ctor   = ctor }

/// Attach an instance method `toView(): <Name>View` to an opaque type.
/// Each non-`@hidden` field is read off `this` and passed to the view's
/// all-fields constructor.
let private defineToViewMethod
        (opaqueInfo: Records.RecordInfo)
        (viewInfo: Records.RecordInfo) : MethodBuilder =
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
        | None ->
            failwithf "M2.2: projectable view field '%s' not on opaque '%s'"
                vf.Name opaqueInfo.Name
    il.Emit(OpCodes.Newobj, viewInfo.Ctor)
    il.Emit(OpCodes.Ret)
    mb

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
    let bareReturn = TypeMap.toClrReturnTypeWith lookup sg.Return
    let returnType =
        if sg.IsAsync then toTaskType bareReturn else bareReturn
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

let private emitFunctionBody
        (mb: MethodBuilder)
        (fn: FunctionDecl)
        (sg: ResolvedSignature)
        (lookup: TypeId -> System.Type option)
        (funcs: Dictionary<string, MethodBuilder>)
        (records: Records.RecordTable)
        (enums: Records.EnumTable)
        (enumCases: Records.EnumCaseLookup)
        (unions: Records.UnionTable)
        (unionCases: Records.UnionCaseLookup)
        (interfaces: Records.InterfaceTable)
        (distinctTypes: Records.DistinctTypeTable)
        (projectables: Records.ProjectableTable)
        (isInstance: bool)
        (selfType: System.Type option)
        (programType: TypeBuilder)
        (symbols: SymbolTable) : unit =
    let il = mb.GetILGenerator()
    // For an async function the *body* still computes a value of
    // the bare return type; the wrapping into `Task<T>` only kicks
    // in at the exit point. Carrying both keeps the body codegen
    // ignorant of the lowering strategy.
    let bareReturnTy = TypeMap.toClrReturnTypeWith lookup sg.Return
    let methodReturnTy =
        if sg.IsAsync then toTaskType bareReturnTy else bareReturnTy
    let returnTy = bareReturnTy
    let paramList =
        sg.Params
        |> List.map (fun p -> p.Name, TypeMap.toClrTypeWith lookup p.Type)
    // Type-resolution closure used by lambda synthesis inside the body.
    let resolveCtxInner = GenericContext()
    let scratchDiagsInner = ResizeArray<Diagnostic>()
    let resolveTypeForCtx (te: TypeExpr) : System.Type =
        let lty = Resolver.resolveType symbols resolveCtxInner scratchDiagsInner te
        TypeMap.toClrTypeWith lookup lty
    let ctx =
        Codegen.FunctionCtx.make
            il returnTy paramList
            funcs records enums enumCases unions unionCases
            interfaces distinctTypes projectables isInstance selfType programType resolveTypeForCtx
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
    // whether the source actually pushed something.
    let routeReturn (pushedTy: System.Type) =
        match resultLocal with
        | Some loc when pushedTy <> typeof<System.Void> ->
            il.Emit(OpCodes.Stloc, loc)
        | None when pushedTy <> typeof<System.Void> ->
            il.Emit(OpCodes.Pop)
        | _ -> ()
        il.Emit(OpCodes.Br, exitLabel)

    // Pre-condition checks fire before any body code.
    for c in fn.Contracts do
        match c with
        | CCRequires (cond, _) ->
            emitContractCheck ctx cond (sprintf "%s: requires failed" fn.Name)
        | _ -> ()

    let emitBodyBlock (blk: Block) =
        let lastIdx = List.length blk.Statements - 1
        Codegen.FunctionCtx.pushScope ctx
        blk.Statements
        |> List.iteri (fun i stmt ->
            if not isVoidReturn && i = lastIdx then
                match stmt.Kind with
                | SExpr e ->
                    let t = Codegen.emitExpr ctx e
                    routeReturn t
                | _ ->
                    Codegen.emitStatement ctx stmt
            else
                Codegen.emitStatement ctx stmt)
        Codegen.FunctionCtx.popScope ctx
        if isVoidReturn then
            il.Emit(OpCodes.Br, exitLabel)

    match fn.Body with
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
        // record + a `toView()` instance method on the opaque type.
        // Bootstrap-grade: skip recursive view projection and `tryInto`
        // (the latter needs a generic `Result` to land first).
        let projectableTable = Records.ProjectableTable()
        for (od, opaqueInfo) in projectableOpaques do
            let viewInfo = defineProjectableView ctx.Module nsName symbols lookup od
            recordTable.[viewInfo.Name] <- viewInfo
            let toViewMb = defineToViewMethod opaqueInfo viewInfo
            projectableTable.[od.Name] <-
                { Records.ProjectableInfo.OpaqueName   = od.Name
                  Records.ProjectableInfo.ToViewMethod = toViewMb
                  Records.ProjectableInfo.ViewType    = viewInfo }

        // Pass 0.5 — distinct types and range subtypes.
        let distinctTable = Records.DistinctTypeTable()
        for dt in distinctTypeItems sf do
            let info = defineDistinctType ctx.Module nsName lookup symbols dt
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

        // Pass B — emit bodies (free-standing funcs).
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
                unionTable unionCaseLookup interfaceTable distinctTable projectableTable false None
                programTy symbols

        // Pass B.5 — emit impl-method bodies as instance methods.
        for (fd, mb, sg) in implMethods do
            // The self-type is whatever record this method was
            // attached to; recover it via the method's declaring
            // type (which we just set in Pass A.5).
            let selfTy = mb.DeclaringType
            emitFunctionBody
                mb fd sg lookup
                methodTable recordTable enumTable enumCases
                unionTable unionCaseLookup interfaceTable distinctTable projectableTable true
                (Option.ofObj selfTy) programTy symbols

        let lyricMain = methodTable.["main"]
        let hostMain  = defineHostEntryPoint programTy lyricMain

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
        Backend.save ctx (Some (hostMain :> MethodInfo))
        []

/// Walk up the directory tree from `startDir` until `lyric/std/core.l`
/// is found, returning its absolute path or `None`.
let private locateCoreL (startDir: string) : string option =
    let mutable dir = Some (DirectoryInfo(startDir))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "lyric", "std", "core.l")
        if File.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj
    found

/// Resolve `import Std.Core` declarations by locating `core.l`,
/// parsing it, and prepending its items into the user file.  The
/// Std.Core import entries are stripped from `Imports` so downstream
/// passes don't encounter an unknown package reference.
let private resolveStdlibImports (sf: SourceFile) : SourceFile * Diagnostic list =
    let stdCoreImps, otherImps =
        sf.Imports |> List.partition (fun i -> i.Path.Segments = ["Std"; "Core"])
    if stdCoreImps.IsEmpty then sf, []
    else
        match locateCoreL AppContext.BaseDirectory with
        | None ->
            let sp = (List.head stdCoreImps).Span
            sf, [ err "E900" "cannot locate lyric/std/core.l for 'import Std.Core'" sp ]
        | Some path ->
            let stdParsed = parse (File.ReadAllText path)
            let mergedItems = stdParsed.File.Items @ sf.Items
            { sf with Imports = otherImps; Items = mergedItems },
            stdParsed.Diagnostics

/// Emit a Lyric source string to a persistent assembly.
let emit (req: EmitRequest) : EmitResult =
    let parsed   = parse req.Source
    let resolved, importDiags = resolveStdlibImports parsed.File
    let checked' = Lyric.TypeChecker.Checker.check resolved

    let upstream = parsed.Diagnostics @ importDiags @ checked'.Diagnostics
    let parserFatal =
        upstream
        |> List.exists (fun d ->
            d.Severity = DiagError && d.Code.StartsWith "P")

    if parserFatal then
        { OutputPath = None; Diagnostics = upstream }
    else
        let emitDiags =
            emitAssembly
                resolved
                checked'.Signatures
                checked'.Symbols
                req
        let emitFatal =
            emitDiags |> List.exists (fun d -> d.Severity = DiagError)
        let outputPath = if emitFatal then None else Some req.OutputPath
        { OutputPath  = outputPath
          Diagnostics = upstream @ emitDiags }
