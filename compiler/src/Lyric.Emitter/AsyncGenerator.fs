/// Bootstrap async-generator synthesis (D-progress-260, Gap-4).
///
/// For each `async func` whose body contains at least one `yield`
/// expression, the emitter synthesises a sibling class implementing
/// `IAsyncEnumerable<T>`, `IAsyncEnumerator<T>`, and
/// `IAsyncDisposable`, and rewrites the user's function into a kickoff
/// stub that creates the generator instance, copies parameters in, and
/// returns it.
///
/// Bootstrap semantics: `RunBody` is called synchronously by
/// `GetAsyncEnumerator`, so all `yield` expressions execute before the
/// first `MoveNextAsync` returns.  This matches the "eager producer"
/// model and is sufficient for generator comprehensions and async-
/// producer scenarios where the body has no internal `await`.
/// Generators with `await` inside their body will require a
/// channel-backed or true `AsyncIteratorMethodBuilder` approach in a
/// future pass; the bootstrap emitter issues a diagnostic for that
/// case (Gap-4a, deferred).
module Lyric.Emitter.AsyncGenerator

open System
open System.Collections.Generic
open System.Reflection
open System.Reflection.Emit

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
