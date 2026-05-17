/// Async generator synthesis for Lyric `async func` bodies that contain
/// `yield` (D-progress-260, Gap-4 / Gap-4a).
///
/// Two synthesis strategies:
///
/// **Eager-producer** (Gap-4 / `defineGeneratorClass`): the body has
/// `yield` but no `await`.  `RunBody()` is called synchronously by
/// `GetAsyncEnumerator`; all yielded values land in `_values : List<T>`
/// and are served one-at-a-time by `MoveNextAsync`.
///
/// **Async iterator** (Gap-4a / `defineAsyncIteratorGeneratorClass`):
/// the body has both `yield` and `await`.  The synthesised class
/// implements `IAsyncStateMachine` alongside `IAsyncEnumerable<T>`,
/// `IAsyncEnumerator<T>`, and `IAsyncDisposable`.  `MoveNextAsync`
/// creates a fresh `TaskCompletionSource<bool>`, drives the state
/// machine one step, and returns `ValueTask<bool>(_tcs.Task)`.  Each
/// `yield x` stores `x` in `<>2__current`, sets the resume state,
/// calls `_tcs.SetResult(true)`, and leaves; `await` points use the
/// standard `AsyncTaskMethodBuilder.AwaitUnsafeOnCompleted` protocol
/// so the machine suspends until the awaited task completes.
module Lyric.Emitter.AsyncGenerator

open System
open System.Collections.Generic
open System.Reflection
open System.Reflection.Emit
open System.Runtime.CompilerServices

/// Generator-body context threaded into `Codegen.FunctionCtx` so the
/// `EYield` handler can emit `_values.Add(inner)` instead of returning.
type GenCtxInfo =
    { /// The `_values` field on the generator class.
      ValuesField: FieldBuilder
      /// The `List<T>.Add` method (closed over the element type).
      AddMethod:   MethodInfo
      /// The element CLR type (T in `IAsyncEnumerable<T>`).
      ElemType:    Type }

/// Open definitions for the generic async enumeration interfaces.
let private iaeOpenDef  : Type = typedefof<IAsyncEnumerable<_>>
let private iaetOpenDef : Type = typedefof<IAsyncEnumerator<_>>
let private listOpenDef : Type = typedefof<List<_>>
let private iAsyncDisposable : Type = typeof<IAsyncDisposable>

/// Metadata for a synthesized async generator class.  The caller emits
/// the body of `RunBody` and then calls `Type.CreateType()` via the
/// normal finalizer path.
type GeneratorInfo =
    { /// The TypeBuilder for the generator class.
      Type:        TypeBuilder
      /// The no-arg ConstructorBuilder (from DefineDefaultConstructor).
      /// Using this in Newobj avoids calling GetConstructor on an unbaked
      /// TypeBuilder (which raises NotSupportedException).
      Ctor:        ConstructorBuilder
      /// The `RunBody` method — callers emit the generator body into this.
      /// `EYield inner` → `this._values.Add(inner_result)`.
      RunBody:     MethodBuilder
      /// The `_values : List<T>` field.
      Values:      FieldBuilder
      /// `List<T>.Add` method, resolved against the concrete List type.
      AddMethod:   MethodInfo
      /// The element CLR type.
      ElemType:    Type
      /// Parameter fields: (Lyric param name, FieldBuilder) in order.
      ParamFields: (string * FieldBuilder) list }

/// Synthesize the generator class for an `async func` with `yield`.
///
/// Emits:
///   sealed class <funcName>__Gen_<uniq> :
///       IAsyncEnumerable<T>, IAsyncEnumerator<T>, IAsyncDisposable
///
/// with these members:
///   - `RunBody()` (void, called by GetAsyncEnumerator to fill _values)
///   - `GetAsyncEnumerator(CancellationToken)` → IAsyncEnumerator<T>
///   - `MoveNextAsync()` → ValueTask<bool>
///   - `Current` → T
///   - `DisposeAsync()` → ValueTask  (always returns default)
let defineGeneratorClass
        (md:         ModuleBuilder)
        (nsName:     string)
        (funcName:   string)
        (uniq:       int)
        (elemType:   Type)
        (paramSpecs: (string * Type) list) : GeneratorInfo =
    // Closed generic interface + helper types.
    let iaeT   = iaeOpenDef.MakeGenericType([| elemType |])
    let iaetT  = iaetOpenDef.MakeGenericType([| elemType |])
    let listT  = listOpenDef.MakeGenericType([| elemType |])
    let vtBool = typeof<System.Threading.Tasks.ValueTask<bool>>
    let vtVoid = typeof<System.Threading.Tasks.ValueTask>
    let ctTy   = typeof<System.Threading.CancellationToken>

    // Resolve List<T> methods.
    // `TypeBuilder.GetMethod(listT, openMethod)` is required only when elemType
    // is a TypeBuilder or GenericTypeParameterBuilder (an in-progress or open
    // type).  For concrete BCL element types (int, string, …) listT is a fully
    // closed generic type; direct reflection on listT works and
    // TypeBuilder.GetMethod raises ArgumentException.
    let listElemIsUnbaked =
        elemType :? TypeBuilder || elemType :? GenericTypeParameterBuilder
    let getListMethod (openName: string) (openMethod: MethodInfo) : MethodInfo =
        if listElemIsUnbaked then
            TypeBuilder.GetMethod(listT, openMethod)
        else
            match listT.GetMethod(openName) |> Option.ofObj with
            | Some m -> m
            | None -> failwithf "List<%s>.%s not found" elemType.Name openName
    let listCtor : ConstructorInfo =
        if listElemIsUnbaked then
            let openCtor =
                match listOpenDef.GetConstructor([||]) |> Option.ofObj with
                | Some c -> c | None -> failwith "List<T>() open ctor not found"
            TypeBuilder.GetConstructor(listT, openCtor)
        else
            match listT.GetConstructor([||]) |> Option.ofObj with
            | Some c -> c | None -> failwith "List<T>() ctor not found"
    let listAddOpen =
        match listOpenDef.GetMethod("Add") |> Option.ofObj with
        | Some m -> m | None -> failwith "List<T>.Add not found"
    let listAdd  = getListMethod "Add" listAddOpen
    let listCountOpen =
        match listOpenDef.GetProperty("Count") |> Option.ofObj with
        | Some p ->
            match p.GetGetMethod() |> Option.ofObj with
            | Some g -> g | None -> failwith "List<T>.Count getter not found"
        | None -> failwith "List<T>.Count not found"
    let listCount = getListMethod "get_Count" listCountOpen
    let listGetOpen =
        match listOpenDef.GetMethod("get_Item") |> Option.ofObj with
        | Some m -> m | None -> failwith "List<T>.get_Item not found"
    let listGet = getListMethod "get_Item" listGetOpen

    // Resolve ValueTask<bool>(bool) ctor.
    let vtBoolCtor =
        match vtBool.GetConstructor([| typeof<bool> |]) |> Option.ofObj with
        | Some c -> c | None -> failwith "ValueTask<bool>(bool) ctor not found"

    // Define the generator class.
    let typeName =
        let base' = sprintf "<%s>__Gen_%d" funcName uniq
        if String.IsNullOrEmpty nsName then base' else nsName + "." + base'
    let tb =
        md.DefineType(
            typeName,
            TypeAttributes.Public ||| TypeAttributes.Sealed ||| TypeAttributes.BeforeFieldInit,
            typeof<obj>,
            [| iaeT; iaetT; iAsyncDisposable |])

    // Parameter fields (populated by the kickoff stub).
    let paramFields =
        paramSpecs
        |> List.map (fun (name, ty) ->
            let f = tb.DefineField(name, ty, FieldAttributes.Public)
            name, f)

    // State fields.
    let valuesField  = tb.DefineField("_values",  listT,       FieldAttributes.Private)
    let posField     = tb.DefineField("_pos",     typeof<int>, FieldAttributes.Private)
    let currentField = tb.DefineField("_current", elemType,    FieldAttributes.Private)

    // Default ctor — capture the ConstructorBuilder so the kickoff stub can
    // emit `newobj` without calling GetConstructor on the still-unbaked TypeBuilder.
    let defaultCtor = tb.DefineDefaultConstructor(MethodAttributes.Public)

    // -----------------------------------------------------------------------
    // `RunBody()` — body is emitted by the caller.
    // -----------------------------------------------------------------------
    let runBody =
        tb.DefineMethod(
            "RunBody",
            MethodAttributes.Public ||| MethodAttributes.HideBySig,
            typeof<Void>,
            [||])

    // -----------------------------------------------------------------------
    // `GetAsyncEnumerator(CancellationToken) : IAsyncEnumerator<T>`
    // -----------------------------------------------------------------------
    let getAsyncEnumMb =
        tb.DefineMethod(
            "GetAsyncEnumerator",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.Virtual,
            iaetT,
            [| ctTy |])
    getAsyncEnumMb.DefineParameter(1, ParameterAttributes.None, "cancellationToken") |> ignore
    let iaeGetEnum =
        match iaeT.GetMethod("GetAsyncEnumerator") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncEnumerable<T>.GetAsyncEnumerator not found"
    tb.DefineMethodOverride(getAsyncEnumMb, iaeGetEnum)
    let gaeIl = getAsyncEnumMb.GetILGenerator()
    // _values = new List<T>()
    gaeIl.Emit(OpCodes.Ldarg_0)
    gaeIl.Emit(OpCodes.Newobj, listCtor)
    gaeIl.Emit(OpCodes.Stfld, valuesField)
    // _pos = -1
    gaeIl.Emit(OpCodes.Ldarg_0)
    gaeIl.Emit(OpCodes.Ldc_I4_M1)
    gaeIl.Emit(OpCodes.Stfld, posField)
    // RunBody()
    gaeIl.Emit(OpCodes.Ldarg_0)
    gaeIl.Emit(OpCodes.Call, runBody)
    // return this
    gaeIl.Emit(OpCodes.Ldarg_0)
    gaeIl.Emit(OpCodes.Ret)

    // -----------------------------------------------------------------------
    // `MoveNextAsync() : ValueTask<bool>`
    // -----------------------------------------------------------------------
    let moveNextMb =
        tb.DefineMethod(
            "MoveNextAsync",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.Virtual,
            vtBool,
            [||])
    let iaetMoveNext =
        match iaetT.GetMethod("MoveNextAsync") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncEnumerator<T>.MoveNextAsync not found"
    tb.DefineMethodOverride(moveNextMb, iaetMoveNext)
    let mnIl = moveNextMb.GetILGenerator()
    let lblTrue = mnIl.DefineLabel()
    let lblRet  = mnIl.DefineLabel()
    // ++_pos
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldfld, posField)
    mnIl.Emit(OpCodes.Ldc_I4_1)
    mnIl.Emit(OpCodes.Add)
    mnIl.Emit(OpCodes.Stfld, posField)
    // if (_pos < _values.Count)
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldfld, posField)
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldfld, valuesField)
    mnIl.Emit(OpCodes.Callvirt, listCount)
    mnIl.Emit(OpCodes.Blt, lblTrue)
    // false → new ValueTask<bool>(false)
    mnIl.Emit(OpCodes.Ldc_I4_0)
    mnIl.Emit(OpCodes.Newobj, vtBoolCtor)
    mnIl.Emit(OpCodes.Br, lblRet)
    // true → _current = _values[_pos]; new ValueTask<bool>(true)
    mnIl.MarkLabel(lblTrue)
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldfld, valuesField)
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldfld, posField)
    mnIl.Emit(OpCodes.Callvirt, listGet)
    // `Unbox_Any` / `Castclass` is only needed when the value on the
    // stack is an `object` reference (i.e. listGet returns `object`).
    // For concrete specialisations like List<int>.get_Item, the return
    // type IS `int` — emitting Unbox_Any on an already-unboxed int
    // would interpret the value as an object pointer and crash.
    let listGetReturnIsObj =
        listGet.ReturnType = typeof<obj>
        || listGet.ReturnType = typeof<System.ValueType>
    if listGetReturnIsObj then
        if elemType.IsValueType || elemType.IsGenericParameter then
            mnIl.Emit(OpCodes.Unbox_Any, elemType)
        elif elemType <> typeof<obj> then
            mnIl.Emit(OpCodes.Castclass, elemType)
    mnIl.Emit(OpCodes.Stfld, currentField)
    mnIl.Emit(OpCodes.Ldc_I4_1)
    mnIl.Emit(OpCodes.Newobj, vtBoolCtor)
    mnIl.MarkLabel(lblRet)
    mnIl.Emit(OpCodes.Ret)

    // -----------------------------------------------------------------------
    // `Current : T`
    // -----------------------------------------------------------------------
    let currProp   = tb.DefineProperty("Current", PropertyAttributes.None, elemType, [||])
    let currGetter =
        tb.DefineMethod(
            "get_Current",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.SpecialName
            ||| MethodAttributes.Virtual,
            elemType,
            [||])
    let iaetCurrentProp =
        match iaetT.GetProperty("Current") |> Option.ofObj with
        | Some p -> p | None -> failwith "IAsyncEnumerator<T>.Current not found"
    let iaetCurrentGetter =
        match iaetCurrentProp.GetGetMethod() |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncEnumerator<T>.Current getter not found"
    tb.DefineMethodOverride(currGetter, iaetCurrentGetter)
    currProp.SetGetMethod(currGetter)
    let cgIl = currGetter.GetILGenerator()
    cgIl.Emit(OpCodes.Ldarg_0)
    cgIl.Emit(OpCodes.Ldfld, currentField)
    cgIl.Emit(OpCodes.Ret)

    // -----------------------------------------------------------------------
    // `DisposeAsync() : ValueTask`
    // -----------------------------------------------------------------------
    let dispMb =
        tb.DefineMethod(
            "DisposeAsync",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.Virtual,
            vtVoid,
            [||])
    let iDisposeAsync =
        match iAsyncDisposable.GetMethod("DisposeAsync") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncDisposable.DisposeAsync not found"
    tb.DefineMethodOverride(dispMb, iDisposeAsync)
    let daIl = dispMb.GetILGenerator()
    let vtLoc = daIl.DeclareLocal(vtVoid)
    daIl.Emit(OpCodes.Ldloca, vtLoc)
    daIl.Emit(OpCodes.Initobj, vtVoid)
    daIl.Emit(OpCodes.Ldloc, vtLoc)
    daIl.Emit(OpCodes.Ret)

    { Type        = tb
      Ctor        = defaultCtor
      RunBody     = runBody
      Values      = valuesField
      AddMethod   = listAdd
      ElemType    = elemType
      ParamFields = paramFields }

/// Emit the kickoff stub into the user's `MethodBuilder`:
///     var gen = new <Gen>()
///     gen.p0 = arg0; gen.p1 = arg1; ...
///     return gen   ← IAsyncEnumerable<T> via interface
let emitGeneratorKickoff
        (kickoffMb:        MethodBuilder)
        (gi:               GeneratorInfo)
        (paramArgIndices:  int list) : unit =
    let il = kickoffMb.GetILGenerator()
    // Use the ConstructorBuilder captured at define-time rather than
    // calling GetConstructor on the TypeBuilder — the latter raises
    // NotSupportedException before CreateType() has been called.
    let genLocal = il.DeclareLocal(gi.Type :> Type)
    il.Emit(OpCodes.Newobj, gi.Ctor :> ConstructorInfo)
    il.Emit(OpCodes.Stloc, genLocal)
    List.zip gi.ParamFields paramArgIndices
    |> List.iter (fun ((_, f), argIdx) ->
        il.Emit(OpCodes.Ldloc, genLocal)
        il.Emit(OpCodes.Ldarg, argIdx)
        il.Emit(OpCodes.Stfld, f :> FieldInfo))
    il.Emit(OpCodes.Ldloc, genLocal)
    il.Emit(OpCodes.Ret)

// ============================================================================
// Gap-4a: Async generators with internal `await`.
// ============================================================================

/// Context threaded into `Codegen.FunctionCtx` so `EYield` emits the
/// async-iterator suspend protocol instead of `_values.Add(...)`.
///
/// Each `yield x` in the body:
///   1. Stores `x` to `<>2__current`.
///   2. Sets `<>1__state = yieldStateBase + N`.
///   3. Calls `_tcs.SetResult(true)` to resolve the pending MoveNextAsync.
///   4. `Leave`s to the suspend point (past try/catch + ret).
/// The matching resume label (after the Leave) resets state to -1 and
/// continues the body.
type AsyncIterYieldCtx =
    { /// `<>2__current` field — stores the value passed to `yield`.
      CurrentField:      FieldBuilder
      /// `<>1__state` field — shared with the await state machine.
      StateField:        FieldBuilder
      /// `_tcs : TaskCompletionSource<bool>` field.
      TcsField:          FieldBuilder
      /// `TaskCompletionSource<bool>.SetResult(bool)`.
      TcsSetResult:      MethodInfo
      /// Element CLR type (T in `IAsyncEnumerable<T>`).
      ElemType:          Type
      /// Counter incremented as each yield is emitted (source order).
      mutable NextYieldIndex: int
      /// Per-yield resume labels.  Label `i` is marked immediately
      /// after the yield's Leave; it resets state to -1 and continues.
      YieldResumeLabels: Label[]
      /// State index of the first yield resume.  = number of awaits.
      YieldStateBase:    int
      /// The leave target past the try/catch block.
      SuspendLeaveLabel: Label
      /// Promoted IL-local ↔ SM-field pairs.  Before every `Leave`
      /// (both yield and await suspend points), each IL local is
      /// flushed back to its field so the value survives the cross-
      /// resume gap.  Shared with `SmAwaitInfo.PromotedShadows`.
      PromotedShadows:   ResizeArray<LocalBuilder * FieldBuilder> }

/// A local whose lifetime straddles an `await` in an async-iterator
/// body.  Parallel to `AsyncStateMachine.SmPromotedLocal`; duplicated
/// here to avoid a forward reference (AsyncGenerator.fs is compiled
/// before AsyncStateMachine.fs is visible to callers of this module).
type AsyncIterPromotedLocal =
    { LocalName:  string
      LocalField: FieldBuilder
      LocalType:  Type }

/// Everything `Emitter.fs` needs to wire the async-iterator MoveNext body.
type AsyncIteratorGeneratorInfo =
    { /// The synthesised class (implements IAsyncStateMachine +
      /// IAsyncEnumerable<T> + IAsyncEnumerator<T> + IAsyncDisposable).
      Type:          TypeBuilder
      /// Default ctor captured before CreateType().
      Ctor:          ConstructorBuilder
      /// `<>1__state : int` field.
      State:         FieldBuilder
      /// `<>t__builder : AsyncTaskMethodBuilder` field (used only for
      /// `AwaitUnsafeOnCompleted` — never for SetResult/SetException).
      Builder:       FieldBuilder
      /// `<>2__current : T` field.
      Current:       FieldBuilder
      /// `_tcs : TaskCompletionSource<bool>` field.
      TcsField:      FieldBuilder
      /// `TaskCompletionSource<bool>.SetResult(bool)`.
      TcsSetResult:  MethodInfo
      /// `TaskCompletionSource<bool>.SetException(Exception)`.
      TcsSetException: MethodInfo
      /// `IAsyncStateMachine.MoveNext()` — body filled by Emitter.fs.
      MoveNext:      MethodBuilder
      /// `IAsyncStateMachine.SetStateMachine(IAsyncStateMachine)`.
      SetSM:         MethodBuilder
      /// One entry per user parameter, in order.
      ParamFields:   (string * FieldBuilder) list
      /// Locals whose lifetimes straddle an `await`.
      PromotedLocals: AsyncIterPromotedLocal list
      /// Element CLR type.
      ElemType:      Type }

/// Synthesise the combined IAsyncStateMachine + IAsyncEnumerable<T>
/// class for an `async func` whose body contains both `yield` and `await`.
///
///   sealed class <funcName>__AsyncIter_<uniq>
///       : IAsyncStateMachine, IAsyncEnumerable<T>, IAsyncEnumerator<T>,
///         IAsyncDisposable
///
/// Fields defined here:
///   <>1__state, <>t__builder, <>2__current, _tcs, <param fields>,
///   <promoted-local fields>.
///
/// Methods with complete bodies defined here:
///   SetStateMachine, GetAsyncEnumerator, MoveNextAsync, get_Current,
///   DisposeAsync.
///
/// `MoveNext` is left empty — Emitter.fs fills it with the state-
/// machine body (Phase B + yield protocol).
let defineAsyncIteratorGeneratorClass
        (md:          ModuleBuilder)
        (nsName:      string)
        (funcName:    string)
        (uniq:        int)
        (elemType:    Type)
        (paramSpecs:  (string * Type) list)
        (localSpecs:  (string * Type) list) : AsyncIteratorGeneratorInfo =

    let iaeT   = iaeOpenDef.MakeGenericType([| elemType |])
    let iaetT  = iaetOpenDef.MakeGenericType([| elemType |])
    let vtBool = typeof<System.Threading.Tasks.ValueTask<bool>>
    let vtVoid = typeof<System.Threading.Tasks.ValueTask>
    let ctTy   = typeof<System.Threading.CancellationToken>
    let iAsmTy = typeof<IAsyncStateMachine>
    let builderTy = typeof<System.Runtime.CompilerServices.AsyncTaskMethodBuilder>
    let tcsBoolTy = typedefof<System.Threading.Tasks.TaskCompletionSource<_>>.MakeGenericType([| typeof<bool> |])
    let taskBoolTy = typedefof<System.Threading.Tasks.Task<_>>.MakeGenericType([| typeof<bool> |])

    // Resolve TaskCompletionSource<bool> members.
    let tcsCtor =
        match tcsBoolTy.GetConstructor([||]) |> Option.ofObj with
        | Some c -> c | None -> failwith "TaskCompletionSource<bool>() ctor not found"
    let tcsSetResult =
        match tcsBoolTy.GetMethod("SetResult") |> Option.ofObj with
        | Some m -> m | None -> failwith "TaskCompletionSource<bool>.SetResult not found"
    let tcsSetException =
        match tcsBoolTy.GetMethod("SetException", [| typeof<System.Exception> |]) |> Option.ofObj with
        | Some m -> m | None -> failwith "TaskCompletionSource<bool>.SetException not found"
    let tcsTaskGetter =
        match tcsBoolTy.GetProperty("Task") |> Option.ofObj with
        | Some p ->
            match p.GetGetMethod() |> Option.ofObj with
            | Some g -> g | None -> failwith "TaskCompletionSource<bool>.Task getter not found"
        | None -> failwith "TaskCompletionSource<bool>.Task not found"

    // Resolve ValueTask<bool>(Task<bool>) ctor.
    let vtBoolFromTaskCtor =
        match vtBool.GetConstructor([| taskBoolTy |]) |> Option.ofObj with
        | Some c -> c | None -> failwith "ValueTask<bool>(Task<bool>) ctor not found"

    // Resolve ValueTask (default) for DisposeAsync.
    let vtVoidLocaCtor =
        match vtVoid.GetConstructor([||]) |> Option.ofObj with
        | Some _ -> None  // no no-arg ctor; use Initobj
        | None   -> None  // Initobj path below

    // AsyncTaskMethodBuilder.Create() (static).
    let builderCreate =
        match builderTy.GetMethod("Create", BindingFlags.Public ||| BindingFlags.Static) |> Option.ofObj with
        | Some m -> m | None -> failwith "AsyncTaskMethodBuilder.Create not found"

    // AsyncTaskMethodBuilder.SetStateMachine(IAsyncStateMachine).
    let builderSetSm =
        match builderTy.GetMethod("SetStateMachine") |> Option.ofObj with
        | Some m -> m | None -> failwith "AsyncTaskMethodBuilder.SetStateMachine not found"

    // Define the class.
    let typeName =
        let base' = sprintf "<%s>__AsyncIter_%d" funcName uniq
        if String.IsNullOrEmpty nsName then base' else nsName + "." + base'
    let tb =
        md.DefineType(
            typeName,
            TypeAttributes.Public ||| TypeAttributes.Sealed ||| TypeAttributes.BeforeFieldInit,
            typeof<obj>,
            [| iAsmTy; iaeT; iaetT; iAsyncDisposable |])

    // ---- Fields ----
    let stateField   = tb.DefineField("<>1__state",   typeof<int>,    FieldAttributes.Public)
    let builderField = tb.DefineField("<>t__builder", builderTy,      FieldAttributes.Public)
    let currentField = tb.DefineField("<>2__current", elemType,       FieldAttributes.Public)
    let tcsField     = tb.DefineField("_tcs",         tcsBoolTy,      FieldAttributes.Private)

    let paramFields =
        paramSpecs
        |> List.map (fun (name, ty) ->
            let storeTy = if ty.IsByRef then (ty.GetElementType() |> Option.ofObj |> Option.defaultValue ty) else ty
            name, tb.DefineField(name, storeTy, FieldAttributes.Public))

    let promotedLocals =
        localSpecs
        |> List.map (fun (name, ty) ->
            let storeTy = if ty.IsByRef then (ty.GetElementType() |> Option.ofObj |> Option.defaultValue ty) else ty
            { LocalName  = name
              LocalField = tb.DefineField("<l>__" + name, storeTy, FieldAttributes.Public)
              LocalType  = storeTy })

    // Default ctor.
    let defaultCtor = tb.DefineDefaultConstructor(MethodAttributes.Public)

    // ---- MoveNext() — body filled by Emitter.fs ----
    let iasMove =
        match iAsmTy.GetMethod("MoveNext") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncStateMachine.MoveNext not found"
    let iasSet =
        match iAsmTy.GetMethod("SetStateMachine") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncStateMachine.SetStateMachine not found"
    let moveNext =
        tb.DefineMethod(
            "MoveNext",
            MethodAttributes.Public ||| MethodAttributes.HideBySig
            ||| MethodAttributes.Virtual ||| MethodAttributes.Final ||| MethodAttributes.NewSlot,
            typeof<Void>, [||])
    tb.DefineMethodOverride(moveNext, iasMove)

    // ---- SetStateMachine — forwards to builder ----
    let setSm =
        tb.DefineMethod(
            "SetStateMachine",
            MethodAttributes.Public ||| MethodAttributes.HideBySig
            ||| MethodAttributes.Virtual ||| MethodAttributes.Final ||| MethodAttributes.NewSlot,
            typeof<Void>, [| iAsmTy |])
    setSm.DefineParameter(1, ParameterAttributes.None, "stateMachine") |> ignore
    tb.DefineMethodOverride(setSm, iasSet)
    let smIl = setSm.GetILGenerator()
    smIl.Emit(OpCodes.Ldarg_0)
    smIl.Emit(OpCodes.Ldflda, builderField)
    smIl.Emit(OpCodes.Ldarg_1)
    smIl.Emit(OpCodes.Call, builderSetSm)
    smIl.Emit(OpCodes.Ret)

    // ---- GetAsyncEnumerator(CancellationToken) ----
    let getAsyncEnumMb =
        tb.DefineMethod(
            "GetAsyncEnumerator",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.Virtual,
            iaetT, [| ctTy |])
    getAsyncEnumMb.DefineParameter(1, ParameterAttributes.None, "cancellationToken") |> ignore
    let iaeGetEnum =
        match iaeT.GetMethod("GetAsyncEnumerator") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncEnumerable<T>.GetAsyncEnumerator not found"
    tb.DefineMethodOverride(getAsyncEnumMb, iaeGetEnum)
    let gaeIl = getAsyncEnumMb.GetILGenerator()
    // <>1__state = -1
    gaeIl.Emit(OpCodes.Ldarg_0)
    gaeIl.Emit(OpCodes.Ldc_I4_M1)
    gaeIl.Emit(OpCodes.Stfld, stateField)
    // <>t__builder = AsyncTaskMethodBuilder.Create()
    gaeIl.Emit(OpCodes.Ldarg_0)
    gaeIl.Emit(OpCodes.Call, builderCreate)
    gaeIl.Emit(OpCodes.Stfld, builderField)
    // return this (as IAsyncEnumerator<T>)
    gaeIl.Emit(OpCodes.Ldarg_0)
    gaeIl.Emit(OpCodes.Ret)

    // ---- MoveNextAsync() : ValueTask<bool> ----
    let moveNextMb =
        tb.DefineMethod(
            "MoveNextAsync",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.Virtual,
            vtBool, [||])
    let iaetMoveNext =
        match iaetT.GetMethod("MoveNextAsync") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncEnumerator<T>.MoveNextAsync not found"
    tb.DefineMethodOverride(moveNextMb, iaetMoveNext)
    let mnIl = moveNextMb.GetILGenerator()
    // _tcs = new TaskCompletionSource<bool>()
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Newobj, tcsCtor)
    mnIl.Emit(OpCodes.Stfld, tcsField)
    // this.MoveNext()  — drive the state machine one step
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Call, moveNext)    // non-virtual: we know the concrete type
    // return new ValueTask<bool>(_tcs.Task)
    mnIl.Emit(OpCodes.Ldarg_0)
    mnIl.Emit(OpCodes.Ldfld, tcsField)
    mnIl.Emit(OpCodes.Callvirt, tcsTaskGetter)
    mnIl.Emit(OpCodes.Newobj, vtBoolFromTaskCtor)
    mnIl.Emit(OpCodes.Ret)

    // ---- get_Current : T ----
    let currProp   = tb.DefineProperty("Current", PropertyAttributes.None, elemType, [||])
    let currGetter =
        tb.DefineMethod(
            "get_Current",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.SpecialName
            ||| MethodAttributes.Virtual,
            elemType, [||])
    let iaetCurrentProp =
        match iaetT.GetProperty("Current") |> Option.ofObj with
        | Some p -> p | None -> failwith "IAsyncEnumerator<T>.Current not found"
    let iaetCurrentGetter =
        match iaetCurrentProp.GetGetMethod() |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncEnumerator<T>.Current getter not found"
    tb.DefineMethodOverride(currGetter, iaetCurrentGetter)
    currProp.SetGetMethod(currGetter)
    let cgIl = currGetter.GetILGenerator()
    cgIl.Emit(OpCodes.Ldarg_0)
    cgIl.Emit(OpCodes.Ldfld, currentField)
    cgIl.Emit(OpCodes.Ret)

    // ---- DisposeAsync() : ValueTask ----
    let dispMb =
        tb.DefineMethod(
            "DisposeAsync",
            MethodAttributes.Public ||| MethodAttributes.HideBySig ||| MethodAttributes.Virtual,
            vtVoid, [||])
    let iDisposeAsyncM =
        match iAsyncDisposable.GetMethod("DisposeAsync") |> Option.ofObj with
        | Some m -> m | None -> failwith "IAsyncDisposable.DisposeAsync not found"
    tb.DefineMethodOverride(dispMb, iDisposeAsyncM)
    let daIl = dispMb.GetILGenerator()
    let vtLoc = daIl.DeclareLocal(vtVoid)
    daIl.Emit(OpCodes.Ldloca, vtLoc)
    daIl.Emit(OpCodes.Initobj, vtVoid)
    daIl.Emit(OpCodes.Ldloc, vtLoc)
    daIl.Emit(OpCodes.Ret)

    ignore vtVoidLocaCtor

    { Type          = tb
      Ctor          = defaultCtor
      State         = stateField
      Builder       = builderField
      Current       = currentField
      TcsField      = tcsField
      TcsSetResult  = tcsSetResult
      TcsSetException = tcsSetException
      MoveNext      = moveNext
      SetSM         = setSm
      ParamFields   = paramFields
      PromotedLocals = promotedLocals
      ElemType      = elemType }

/// Emit the kickoff stub for an async-iterator generator:
///     var aig = new <AsyncIter>()
///     aig.p0 = arg0; aig.p1 = arg1; ...
///     return aig   ← IAsyncEnumerable<T> via interface
let emitAsyncIteratorKickoff
        (kickoffMb:       MethodBuilder)
        (aig:             AsyncIteratorGeneratorInfo)
        (paramArgIndices: int list) : unit =
    let il = kickoffMb.GetILGenerator()
    let genLocal = il.DeclareLocal(aig.Type :> Type)
    il.Emit(OpCodes.Newobj, aig.Ctor :> ConstructorInfo)
    il.Emit(OpCodes.Stloc, genLocal)
    List.zip aig.ParamFields paramArgIndices
    |> List.iter (fun ((_, f), argIdx) ->
        il.Emit(OpCodes.Ldloc, genLocal)
        il.Emit(OpCodes.Ldarg, argIdx)
        il.Emit(OpCodes.Stfld, f :> FieldInfo))
    il.Emit(OpCodes.Ldloc, genLocal)
    il.Emit(OpCodes.Ret)
