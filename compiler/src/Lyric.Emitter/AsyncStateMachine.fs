/// Hand-rolled async state machine synthesis (C2 / D-progress-024,
/// Phase A).
///
/// For each `async func` whose body contains no `await` expressions,
/// the emitter synthesises a sibling class implementing
/// `IAsyncStateMachine` and rewrites the user's function into a
/// kickoff stub that creates the SM, calls
/// `AsyncTaskMethodBuilder<T>.Start`, and returns the builder's task.
///
/// Phase A scope (this file):
///   * Top-level non-generic non-instance async functions.
///   * Bodies that contain no internal `await` (i.e. the user code
///     never suspends).  This covers the four cases in
///     `AsyncTests.fs` plus any other async function whose value is
///     produced synchronously.  Even though these bodies don't
///     suspend, routing them through the real builder/Start/SetResult
///     plumbing exercises the whole structural shape we'll need for
///     Phase B and replaces the M1.4 `Task.FromResult` shim with
///     spec-correct codegen.
///
/// Phase B (follow-up): `await` inside an async body — real
/// `AwaitUnsafeOnCompleted` suspend/resume protocol with state
/// dispatch, locals promoted to fields.  Async funcs whose bodies
/// contain `await` keep the M1.4 `Task.FromResult` path until Phase
/// B lands.
module Lyric.Emitter.AsyncStateMachine

open System
open System.Collections.Generic
open System.Reflection
open System.Reflection.Emit
open System.Runtime.CompilerServices
open Lyric.Parser.Ast

/// Walk a function body looking for any `EAwait` expression.  An
/// `EAwait` anywhere — in a sub-expression, match arm, defer, etc. —
/// disqualifies the function from Phase A SM lowering.
let rec private exprHasAwait (e: Expr) : bool =
    match e.Kind with
    | EAwait _ -> true
    | ELiteral _ | EPath _ | ESelf | EResult | EError -> false
    | EInterpolated segs ->
        segs |> List.exists (function
            | ISText _ -> false
            | ISExpr e -> exprHasAwait e)
    | EParen e | ESpawn e | EOld e | EPropagate e | ETry e -> exprHasAwait e
    | ETuple es | EList es -> es |> List.exists exprHasAwait
    | EIf (c, t, eOpt, _) ->
        exprHasAwait c
        || branchHasAwait t
        || (match eOpt with Some b -> branchHasAwait b | None -> false)
    | EMatch (s, arms) ->
        exprHasAwait s
        || arms |> List.exists (fun a ->
            (match a.Guard with Some g -> exprHasAwait g | None -> false)
            || branchHasAwait a.Body)
    | EForall (_, where, body)
    | EExists (_, where, body) ->
        (match where with Some w -> exprHasAwait w | None -> false)
        || exprHasAwait body
    | ELambda (_, blk) -> blockHasAwait blk
    | ECall (f, args) ->
        exprHasAwait f
        || args |> List.exists (function
            | CANamed (_, v, _) -> exprHasAwait v
            | CAPositional v    -> exprHasAwait v)
    | ETypeApp (f, _) -> exprHasAwait f
    | EIndex (r, idxs) -> exprHasAwait r || idxs |> List.exists exprHasAwait
    | EMember (r, _) -> exprHasAwait r
    | EPrefix (_, op) -> exprHasAwait op
    | EBinop (_, l, r) -> exprHasAwait l || exprHasAwait r
    | ERange rb ->
        match rb with
        | RBClosed (a, b) | RBHalfOpen (a, b) -> exprHasAwait a || exprHasAwait b
        | RBLowerOpen a | RBUpperOpen a       -> exprHasAwait a
    | EAssign (t, _, v) -> exprHasAwait t || exprHasAwait v
    | EBlock b -> blockHasAwait b

and private branchHasAwait (eob: ExprOrBlock) : bool =
    match eob with
    | EOBExpr e  -> exprHasAwait e
    | EOBBlock b -> blockHasAwait b

and private blockHasAwait (b: Block) : bool =
    b.Statements |> List.exists stmtHasAwait

and private stmtHasAwait (s: Statement) : bool =
    match s.Kind with
    | SExpr e | SThrow e -> exprHasAwait e
    | SReturn (Some e) -> exprHasAwait e
    | SReturn None | SBreak _ | SContinue _ -> false
    | SAssign (t, _, v) -> exprHasAwait t || exprHasAwait v
    | SLocal (LBVal (_, _, e)) | SLocal (LBLet (_, _, e)) -> exprHasAwait e
    | SLocal (LBVar (_, _, Some e)) -> exprHasAwait e
    | SLocal (LBVar (_, _, None)) -> false
    | STry (body, catches) ->
        blockHasAwait body
        || catches |> List.exists (fun c -> blockHasAwait c.Body)
    | SDefer b | SScope (_, b) | SLoop (_, b) -> blockHasAwait b
    | SFor (_, _, iter, body) -> exprHasAwait iter || blockHasAwait body
    | SWhile (_, cond, body) -> exprHasAwait cond || blockHasAwait body
    | SRule (lhs, rhs) -> exprHasAwait lhs || exprHasAwait rhs
    | SItem _ -> false

/// Top-level entry: does this function's body contain any `await`?
let bodyContainsAwait (fn: FunctionDecl) : bool =
    match fn.Body with
    | None -> false
    | Some (FBExpr e) -> exprHasAwait e
    | Some (FBBlock b) -> blockHasAwait b

/// Returns true when this async function is eligible for Phase A
/// state-machine lowering.  Currently:
///   * top-level (handled at call site — caller passes only top-level fns)
///   * non-generic (Reflection.Emit closed-generic Start/SetResult plumbing
///     is Phase B work)
///   * non-instance (caller responsibility)
///   * no internal `await`
///   * no `@externTarget` annotation (FFI bypasses the body entirely)
let isPhaseAEligible (fn: FunctionDecl) : bool =
    fn.Generics.IsNone
    && not (bodyContainsAwait fn)
    && not (fn.Annotations
            |> List.exists (fun a ->
                match a.Name.Segments with
                | ["externTarget"] -> true
                | _ -> false))

// ---------------------------------------------------------------------------
// State-machine info shared across the three emit phases.
// ---------------------------------------------------------------------------

/// One field on the SM corresponding to a Lyric parameter.  Per
/// Phase A, parameters are stored by value (no byref-on-field
/// support); the M1.4 stdlib + tests don't pass `out`/`inout`
/// parameters to async funcs, and Reflection.Emit doesn't allow
/// FieldBuilder field types to be `T&`.  An async func using a
/// byref param falls back to the M1.4 path via
/// `isPhaseAEligible = false` if/when needed.
type SmParamField =
    { Name:  string
      Field: FieldBuilder
      /// CLR storage type (the "stripped" type — non-byref).
      Type:  Type }

/// Everything codegen needs to wire a state machine.
type StateMachineInfo =
    { /// The synthesised SM type.
      Type: TypeBuilder
      /// Default no-arg constructor on the SM (used by the kickoff).
      Ctor: ConstructorBuilder
      /// `<>state : int` field.
      State: FieldBuilder
      /// `<>builder : AsyncTaskMethodBuilder` (or `<R>`).
      Builder: FieldBuilder
      /// The closed builder type (`AsyncTaskMethodBuilder` for void,
      /// `AsyncTaskMethodBuilder<R>` for value-returning funcs).
      BuilderType: Type
      /// The bare return type (e.g. `int`); `typeof<Void>` for unit.
      BareReturn: Type
      /// True when the function returns `Unit` and the builder is
      /// non-generic.
      IsVoid: bool
      /// One field per parameter, in order.
      ParamFields: SmParamField list
      /// `MoveNext` method header.
      MoveNext: MethodBuilder
      /// `IAsyncStateMachine.SetStateMachine` method header.
      SetStateMachine: MethodBuilder }

let private iAsmType : Type = typeof<IAsyncStateMachine>

let private builderTypeFor (bareReturn: Type) (isVoid: bool) : Type =
    if isVoid then typeof<AsyncTaskMethodBuilder>
    else typedefof<AsyncTaskMethodBuilder<_>>.MakeGenericType([| bareReturn |])

/// Build the SM class for a single async function.  The class is
/// added as a top-level type on the module (distinct from the
/// `<Program>` class) so it can be sealed independently.  Naming:
/// `<funcName>__SM` plus a uniqueness suffix when overloads collide.
let defineStateMachine
        (md: ModuleBuilder)
        (nsName: string)
        (funcName: string)
        (uniq: int)
        (bareReturn: Type)
        (paramSpecs: (string * Type) list) : StateMachineInfo =
    let isVoid = bareReturn = typeof<Void>
    let builderTy = builderTypeFor bareReturn isVoid
    let typeName =
        let baseName = sprintf "<%s>__SM_%d" funcName uniq
        if String.IsNullOrEmpty nsName then baseName
        else nsName + "." + baseName
    let tb =
        md.DefineType(
            typeName,
            TypeAttributes.Public
            ||| TypeAttributes.Sealed
            ||| TypeAttributes.BeforeFieldInit,
            typeof<obj>,
            [| iAsmType |])
    let stateField =
        tb.DefineField("<>1__state", typeof<int>, FieldAttributes.Public)
    let builderField =
        tb.DefineField("<>t__builder", builderTy, FieldAttributes.Public)
    let defaultCtor =
        tb.DefineDefaultConstructor(MethodAttributes.Public)
    let paramFields =
        paramSpecs
        |> List.map (fun (name, ty) ->
            // Async funcs with byref params route to the M1.4 path
            // via `isPhaseAEligible` — defensive check here keeps
            // `DefineField` from throwing if a future caller misroutes.
            let storeTy : Type =
                if ty.IsByRef then
                    match Option.ofObj (ty.GetElementType()) with
                    | Some t -> t
                    | None   -> ty
                else ty
            let f = tb.DefineField(name, storeTy, FieldAttributes.Public)
            { Name = name; Field = f; Type = storeTy })

    let moveNext =
        tb.DefineMethod(
            "MoveNext",
            MethodAttributes.Public
            ||| MethodAttributes.HideBySig
            ||| MethodAttributes.Virtual
            ||| MethodAttributes.Final
            ||| MethodAttributes.NewSlot,
            typeof<Void>,
            [||])

    let setSm =
        tb.DefineMethod(
            "SetStateMachine",
            MethodAttributes.Public
            ||| MethodAttributes.HideBySig
            ||| MethodAttributes.Virtual
            ||| MethodAttributes.Final
            ||| MethodAttributes.NewSlot,
            typeof<Void>,
            [| iAsmType |])
    setSm.DefineParameter(1, ParameterAttributes.None, "stateMachine") |> ignore

    // Hook IAsyncStateMachine.MoveNext + SetStateMachine.
    let iasMove =
        match Option.ofObj (iAsmType.GetMethod("MoveNext")) with
        | Some m -> m
        | None   -> failwith "BCL: IAsyncStateMachine.MoveNext not found"
    let iasSet =
        match Option.ofObj (iAsmType.GetMethod("SetStateMachine")) with
        | Some m -> m
        | None   -> failwith "BCL: IAsyncStateMachine.SetStateMachine not found"
    tb.DefineMethodOverride(moveNext, iasMove)
    tb.DefineMethodOverride(setSm, iasSet)

    { Type            = tb
      Ctor            = defaultCtor
      State           = stateField
      Builder         = builderField
      BuilderType     = builderTy
      BareReturn      = bareReturn
      IsVoid          = isVoid
      ParamFields     = paramFields
      MoveNext        = moveNext
      SetStateMachine = setSm }

// ---------------------------------------------------------------------------
// IL helpers.
// ---------------------------------------------------------------------------

/// Resolve `AsyncTaskMethodBuilder[<T>].<Member>` against the closed
/// builder type.  Methods on closed-generic BCL types resolve via
/// `GetMethod` / `GetProperty` directly — no TypeBuilder shim needed
/// because the builder type is BCL, not user-emitted.
let private builderMember
        (sm: StateMachineInfo)
        (name: string) : MethodInfo =
    match Option.ofObj (sm.BuilderType.GetMethod(name)) with
    | Some m -> m
    | None ->
        // Properties (e.g. `Task` getter) come back via `get_<Name>`.
        match Option.ofObj (sm.BuilderType.GetMethod("get_" + name)) with
        | Some m -> m
        | None -> failwithf "BCL: %s.%s not found" sm.BuilderType.Name name

/// `AsyncTaskMethodBuilder[<T>]::Create()` (static).
let private builderCreate (sm: StateMachineInfo) : MethodInfo =
    match Option.ofObj (sm.BuilderType.GetMethod("Create", BindingFlags.Public ||| BindingFlags.Static)) with
    | Some m -> m
    | None   -> failwithf "BCL: %s.Create not found" sm.BuilderType.Name

/// Closed `Start<TStateMachine>(ref TStateMachine)` for our SM type.
let private builderStart (sm: StateMachineInfo) : MethodInfo =
    let openStart =
        match Option.ofObj
                  (sm.BuilderType.GetMethod("Start", BindingFlags.Public ||| BindingFlags.Instance)) with
        | Some m -> m
        | None   -> failwithf "BCL: %s.Start not found" sm.BuilderType.Name
    openStart.MakeGenericMethod([| sm.Type :> Type |])

// ---------------------------------------------------------------------------
// Kickoff body.
// ---------------------------------------------------------------------------

/// Emit the user's async function body — now a kickoff stub.  Layout:
///
///     var sm    = new <SM>()
///     sm.<>p0   = arg0
///     sm.<>p1   = arg1   ...
///     sm.<>builder = AsyncTaskMethodBuilder.Create()
///     sm.<>state   = -1
///     sm.<>builder.Start<<SM>>(ref sm)
///     return sm.<>builder.Task
///
/// The `builder.Task` lookup is special-cased: when `BuilderType` is
/// non-generic the property is `Task` (returns `Task`); when generic
/// it's `Task` (returns `Task<R>`).  Both resolve via `get_Task`.
let emitKickoff
        (kickoffMb: MethodBuilder)
        (sm: StateMachineInfo)
        (paramArgIndices: int list) : unit =
    let il = kickoffMb.GetILGenerator()
    let smLocal = il.DeclareLocal(sm.Type)

    // Phase A keeps the SM as a class (sealed reference type), so
    // `newobj` on its default ctor matches C# class-mode (debug-build)
    // emission.  Struct-mode (`initobj` on a value-typed slot) is the
    // C# release-build shape; we'll switch when locals start needing
    // promotion to fields and we want to avoid the heap allocation.
    il.Emit(OpCodes.Newobj, sm.Ctor)
    il.Emit(OpCodes.Stloc, smLocal)

    // sm.<>builder = AsyncTaskMethodBuilder.Create()
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Call, builderCreate sm)
    il.Emit(OpCodes.Stfld, sm.Builder)

    // sm.<>state = -1
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Ldc_I4_M1)
    il.Emit(OpCodes.Stfld, sm.State)

    // Copy each parameter into its SM field.  `paramArgIndices` matches
    // `sm.ParamFields` element-for-element; the caller is responsible
    // for the alignment (instance methods shift by 1, etc.).
    List.zip sm.ParamFields paramArgIndices
    |> List.iter (fun (pf, argIdx) ->
        il.Emit(OpCodes.Ldloc, smLocal)
        il.Emit(OpCodes.Ldarg, argIdx)
        il.Emit(OpCodes.Stfld, pf.Field))

    // sm.<>builder.Start<SM>(ref sm)
    // `Start` is an instance method on a struct builder — ldflda
    // gives us `&sm.<>builder` as a managed pointer.
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Ldflda, sm.Builder)
    il.Emit(OpCodes.Ldloca, smLocal)
    il.Emit(OpCodes.Call, builderStart sm)

    // return sm.<>builder.Task
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Ldflda, sm.Builder)
    let taskGetter =
        match Option.ofObj (sm.BuilderType.GetProperty("Task")) with
        | Some p ->
            match Option.ofObj (p.GetGetMethod()) with
            | Some g -> g
            | None   -> failwithf "BCL: %s.get_Task missing" sm.BuilderType.Name
        | None -> failwithf "BCL: %s.Task property missing" sm.BuilderType.Name
    il.Emit(OpCodes.Call, taskGetter)
    il.Emit(OpCodes.Ret)

// ---------------------------------------------------------------------------
// MoveNext body — finished by the caller.
//
// The SM exposes its IL generator via `MoveNext`.  The Emitter sets up
// a FunctionCtx pointing at this generator and runs the regular
// emit-body pipeline against the user's body, with `SmFields`
// populated so parameter access goes through `Ldarg.0; Ldfld <field>`
// instead of `Ldarg N`.  The exit-point block (after the user body
// produces the return value) runs the SetResult/SetException
// finaliser — emitted by `emitMoveNextEpilogue` below.
// ---------------------------------------------------------------------------

/// Emit the SetResult / SetException epilogue at the end of MoveNext.
/// Layout (no real exception handling in Phase A — the user body
/// runs entirely synchronously without any await suspension; a
/// thrown exception bubbles out of MoveNext naturally and is captured
/// by `Start`'s outer try/catch on our behalf):
///
///     this.<>state = -2     // -2 = completed
///     this.<>builder.SetResult(<resultLocal-or-nothing>)
///     ret
///
/// `resultLocal` carries the bare return value (Phase A bodies
/// always run to completion) or `None` for void.
let emitMoveNextEpilogue
        (il: ILGenerator)
        (sm: StateMachineInfo)
        (resultLocal: LocalBuilder option) : unit =
    // this.<>state = -2
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldc_I4, -2)
    il.Emit(OpCodes.Stfld, sm.State)

    // this.<>builder.SetResult(...)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, sm.Builder)
    match resultLocal with
    | Some loc -> il.Emit(OpCodes.Ldloc, loc)
    | None     -> ()
    let setResult = builderMember sm "SetResult"
    il.Emit(OpCodes.Call, setResult)
    il.Emit(OpCodes.Ret)

/// Emit `SetStateMachine`'s body: just forward to the builder.
let emitSetStateMachine (sm: StateMachineInfo) : unit =
    let il = sm.SetStateMachine.GetILGenerator()
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, sm.Builder)
    il.Emit(OpCodes.Ldarg_1)
    let setSm = builderMember sm "SetStateMachine"
    il.Emit(OpCodes.Call, setSm)
    il.Emit(OpCodes.Ret)
