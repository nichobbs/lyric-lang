/// Phase 1 minimal standard library, exposed as a small set of static
/// methods that the emitter can target. Each method's CLR signature
/// matches the Lyric-side declaration that the emitter will eventually
/// inject into the symbol table:
///
///   func println(s: in String): Unit
///   func print  (s: in String): Unit
///   func expect (cond: in Bool, msg: in String): Unit
///   func assert (cond: in Bool): Unit
///   func panic  (msg: in String): Never
///
/// The emitter calls these by emitting `call void
/// [Lyric.Stdlib]Lyric.Stdlib.Console::Println(string)` etc. They are
/// deliberately thin wrappers over the BCL: the goal is to give the
/// emitter a stable, predictable target it can resolve at codegen
/// time, not to ship a real stdlib.
namespace Lyric.Stdlib

open System

/// Console output. The two methods correspond to Lyric's
/// `std.io.println` / `std.io.print`.
[<Sealed; AbstractClass>]
type Console private () =

    static member Println (s: string) : unit =
        System.Console.WriteLine(s)

    static member Print (s: string) : unit =
        System.Console.Write(s)

    /// `println` overload for non-string values — emits `ToString()`.
    /// Used when the emitter needs to format an integer, bool, etc.
    static member PrintlnAny (value: obj | null) : unit =
        match value with
        | null    -> System.Console.WriteLine("()")
        | nonNull -> System.Console.WriteLine(nonNull.ToString())

    /// Convert any value to its string representation.  Routes through
    /// `Object.ToString()`; nulls map to `"()"` for symmetry with
    /// `PrintlnAny`.  The emitter emits this when the user calls the
    /// Lyric-side `toString(x)` builtin.
    static member ToStr (value: obj | null) : string =
        match value with
        | null    -> "()"
        | nonNull ->
            match nonNull.ToString() with
            | null -> ""
            | s    -> s

/// Contract / test-harness intrinsics. Lyric's `expect` / `assert`
/// raise on failure; in Phase 1 we wire both to a single
/// `LyricAssertionException` so callers can catch via the FFI.
///
/// Defined as a plain CLR class (not an F# `exception` declaration)
/// so the emitted PE can `newobj` it directly and so the runtime's
/// `ToString` produces a clean message — F#'s synthesised exception
/// types have a `Data0` representation that the persisted-assembly
/// metadata round-trip stumbles on.
type LyricAssertionException(message: string) =
    inherit System.Exception(message)

[<Sealed; AbstractClass>]
type Contracts private () =

    static member Expect (cond: bool, msg: string) : unit =
        if not cond then
            raise (LyricAssertionException(msg))

    static member Assert (cond: bool) : unit =
        if not cond then
            raise (LyricAssertionException("assertion failed"))

    /// `panic` returns `Never` in Lyric. From the CLR's perspective
    /// this is a throw-only method whose return type is `void` (the
    /// emitter will mark its Lyric type as Never).
    static member Panic (msg: string) : unit =
        raise (LyricAssertionException("panic: " + msg))

/// String formatting backed by `System.String.Format`.  Supports
/// .NET-style `{0}`, `{1}`, … placeholders.  Up to four args today;
/// add more overloads if/when programs need them.  Lyric has no
/// varargs syntax, so each arity is a separate static member.
[<Sealed; AbstractClass>]
type Format private () =

    static member Of1 (template: string, a0: obj | null) : string =
        System.String.Format(template, a0)

    static member Of2 (template: string,
                       a0: obj | null,
                       a1: obj | null) : string =
        System.String.Format(template, a0, a1)

    static member Of3 (template: string,
                       a0: obj | null,
                       a1: obj | null,
                       a2: obj | null) : string =
        System.String.Format(template, a0, a1, a2)

    static member Of4 (template: string,
                       a0: obj | null,
                       a1: obj | null,
                       a2: obj | null,
                       a3: obj | null) : string =
        System.String.Format(template, [| a0; a1; a2; a3 |])

    static member Of5 (template: string,
                       a0: obj | null,
                       a1: obj | null,
                       a2: obj | null,
                       a3: obj | null,
                       a4: obj | null) : string =
        System.String.Format(template, [| a0; a1; a2; a3; a4 |])

    static member Of6 (template: string,
                       a0: obj | null,
                       a1: obj | null,
                       a2: obj | null,
                       a3: obj | null,
                       a4: obj | null,
                       a5: obj | null) : string =
        System.String.Format(template, [| a0; a1; a2; a3; a4; a5 |])

/// Generic helper for `Dictionary<K, V>` operations that don't fit
/// directly into the FFI without out-parameters or rich Lyric
/// inference.  All members are static and routed through Lyric's
/// `extern type` + `@externTarget` machinery.
[<Sealed; AbstractClass>]
type MapHelpers<'K, 'V when 'K: not null> private () =

    /// True if `m` contains `key`.  A drop-in replacement for the
    /// open-generic `Dictionary`2.ContainsKey` once a Lyric program
    /// has the required generic externs.
    static member Has (m: System.Collections.Generic.Dictionary<'K, 'V>,
                       key: 'K) : bool =
        m.ContainsKey key

    /// Return `m[key]` if present, otherwise the default value of `V`.
    /// Pair with `Has` to build a `Result` / `Option` on the Lyric side
    /// without out-params.  Avoids the JIT verifier issue that hits
    /// when chaining ContainsKey + the indexer through `extern type`.
    static member GetOrDefault (m: System.Collections.Generic.Dictionary<'K, 'V>,
                                key: 'K) : 'V =
        match m.TryGetValue key with
        | true, v -> v
        | _       -> Unchecked.defaultof<'V>

    /// Set `m[key] = value` (insert or overwrite).
    static member Put (m: System.Collections.Generic.Dictionary<'K, 'V>,
                       key: 'K, value: 'V) : unit =
        m.[key] <- value

/// Generic exception-to-result helper.  The Lyric side calls
/// `tryRunValue(() => bclThing(args))` to invoke an arbitrary
/// throw-prone BCL operation; the F# wrapper catches and surfaces a
/// Async primitives.  `Std.Task.delay` lowers to `TaskHost.Delay`
/// via `@externTarget`, returning a real `Task` that suspends the
/// caller's state machine until the timer fires.  This is the
/// canonical Phase B suspension trigger used by `AsyncTests`.
[<Sealed; AbstractClass>]
type TaskHost private () =

    /// `Task.Delay(ms)` wrapped so consumers can declare the Lyric
    /// target as `async func delay(ms: in Int): Unit` without
    /// reaching for a non-Lyric `Task` type at the source level.
    static member Delay (ms: int) : System.Threading.Tasks.Task =
        System.Threading.Tasks.Task.Delay(ms)

    /// `Task.Delay(ms, token)` — same as `Delay` but cooperatively
    /// cancellable via the supplied token.  Throws
    /// `OperationCanceledException` (caught as `Exception` on the
    /// Lyric side) when the token is cancelled before the timer
    /// fires.  Phase C / D-progress-068.
    static member DelayWithCancel
            (ms: int,
             token: System.Threading.CancellationToken)
            : System.Threading.Tasks.Task =
        System.Threading.Tasks.Task.Delay(ms, token)

/// Cancellation primitives wrapping `System.Threading.Cancellation*`.
/// Each helper is a thin static so the Lyric-side `Std.Task` can
/// route `@externTarget` annotations to deterministic targets
/// without exposing struct details (`CancellationToken` is a struct
/// in the BCL; we surface it as an opaque object via a
/// `CancellationToken | null` boundary the FFI handles).
[<Sealed; AbstractClass>]
type CancelHost private () =

    /// Construct a fresh `CancellationTokenSource`.
    static member MakeSource () : System.Threading.CancellationTokenSource =
        new System.Threading.CancellationTokenSource()

    /// Construct a `CancellationTokenSource` that auto-cancels after
    /// `ms` milliseconds.  Used by `withTimeout` for deadline-shaped
    /// scopes.
    static member MakeSourceTimeout (ms: int) : System.Threading.CancellationTokenSource =
        new System.Threading.CancellationTokenSource(ms)

    /// Project a token from a source.  The token is a value type
    /// in the BCL but boxes through the FFI cleanly.
    static member SourceToken
            (src: System.Threading.CancellationTokenSource)
            : System.Threading.CancellationToken =
        src.Token

    /// Request cancellation.  Idempotent: subsequent calls are
    /// no-ops.
    static member Cancel (src: System.Threading.CancellationTokenSource) : unit =
        src.Cancel()

    /// Returns true once the token's source has been cancelled.
    static member IsCancellationRequested
            (token: System.Threading.CancellationToken) : bool =
        token.IsCancellationRequested

    /// Cooperative throw point.  Async loops can call this between
    /// iterations to honour cancellation without an outright suspend.
    static member ThrowIfCancellationRequested
            (token: System.Threading.CancellationToken) : unit =
        token.ThrowIfCancellationRequested()

    /// A token that is never cancelled — equivalent to
    /// `CancellationToken.None`.  Used by call sites that don't
    /// have a real token to pass.
    static member None () : System.Threading.CancellationToken =
        System.Threading.CancellationToken.None

    /// Dispose the source, releasing any unmanaged resources.
    /// Safe to call from `defer { dispose(src) }` blocks.
    static member Dispose (src: System.Threading.CancellationTokenSource) : unit =
        src.Dispose()

/// A structured-concurrency scope.  Holds a `CancellationTokenSource`
/// (for cancelling spawned children when the scope exits abnormally)
/// and a list of registered child tasks.  When any single child
/// faults or is cancelled, the scope's source is cancelled so
/// siblings observe the request and bail.
///
/// Phase C / D-progress-069 — pairs with `TaskScopeHost` below.
type LyricTaskScope() =
    let source = new System.Threading.CancellationTokenSource()
    let tasks  = System.Collections.Generic.List<System.Threading.Tasks.Task>()
    let lockObj = obj ()
    let mutable disposed = false

    member _.Source = source
    member _.Token  = source.Token

    /// Register `task` as a child of this scope.  Attaches a
    /// continuation that cancels the source on first failure so
    /// siblings observe and bail.  Idempotent on disposed scopes —
    /// disposed scopes silently swallow new spawns (the scope's
    /// `awaitAll` has already returned).
    member this.Add (task: System.Threading.Tasks.Task) : unit =
        lock lockObj (fun () ->
            if not disposed then tasks.Add(task))
        // Continuation runs OUT of band; we attach unconditionally
        // so even tasks added post-dispose still cancel the (already
        // cancelled) source if they happen to fault.
        task.ContinueWith(
            System.Action<System.Threading.Tasks.Task>(fun t ->
                if t.IsFaulted || t.IsCanceled then
                    try source.Cancel() with _ -> ()),
            System.Threading.Tasks.TaskContinuationOptions.NotOnRanToCompletion)
        |> ignore

    /// Cancel every spawned child.  Idempotent.
    member _.Cancel () : unit =
        try source.Cancel() with _ -> ()

    /// Snapshot the current task list — used by AwaitAll to take a
    /// stable view that won't see post-snapshot spawns.
    member _.Snapshot () : System.Threading.Tasks.Task array =
        lock lockObj (fun () -> tasks.ToArray())

    /// Dispose the underlying source.  Subsequent `Add`s are
    /// silently dropped.
    member _.Dispose () : unit =
        lock lockObj (fun () -> disposed <- true)
        try source.Dispose() with _ -> ()

/// `Std.Task.Scope` operations.  Lyric's `extern type Scope =
/// "Lyric.Stdlib.LyricTaskScope"` plus `@externTarget` annotations
/// route to these statics.  See `lyric/std/task.l` for the surface
/// API.
[<Sealed; AbstractClass>]
type TaskScopeHost private () =

    /// Construct a fresh scope with its own token source and an
    /// empty task list.
    static member MakeScope () : LyricTaskScope =
        new LyricTaskScope()

    /// The scope's cancellation token.  Pass to spawned children
    /// so they observe scope-level cancellation requests.
    static member ScopeToken (scope: LyricTaskScope) : System.Threading.CancellationToken =
        scope.Token

    /// Register `task` as a child of `scope`.  Failure of any
    /// registered task cancels the scope's source automatically.
    static member Add (scope: LyricTaskScope, task: System.Threading.Tasks.Task) : unit =
        scope.Add(task)

    /// Spawn an `Action` (zero-arg `() -> unit` closure) as a
    /// thread-pool task scoped to `scope`.  Lyric's `() -> Unit`
    /// closures lower to `System.Action`, so user code passes a
    /// bare lambda.  Useful when the work is CPU-bound or
    /// honours cancellation by polling `throwIfCancelled(token)`
    /// manually.
    static member SpawnAction (scope: LyricTaskScope, action: System.Action) : unit =
        let token = scope.Token
        let task = System.Threading.Tasks.Task.Run((fun () -> action.Invoke()), token)
        scope.Add(task)

    /// Variant for closures that Lyric's typechecker lowers to
    /// `Func<unit>` (zero-arg, Unit-returning) instead of `Action`.
    /// The lambda emitter peeks the body's last expression's type;
    /// when that's `Unit` (i.e. `System.ValueTuple`) the resulting
    /// delegate is `Func<ValueTuple>` rather than `Action`, so we
    /// expose a parallel host method to receive it.
    static member SpawnFunc (scope: LyricTaskScope, fn: System.Func<System.ValueTuple>) : unit =
        let token = scope.Token
        let task = System.Threading.Tasks.Task.Run((fun () -> fn.Invoke() |> ignore), token)
        scope.Add(task)

    /// Wait for every registered child to complete.  When any
    /// child fails (`Task.WhenAll` re-raises the AggregateException),
    /// the scope's source has already been cancelled by the
    /// per-child continuation; surrogates that honoured the token
    /// will have started winding down.  This call still throws the
    /// underlying exception so the user's `try { ... } catch ...`
    /// surfaces it.
    static member AwaitAll (scope: LyricTaskScope) : System.Threading.Tasks.Task =
        let snapshot = scope.Snapshot()
        if snapshot.Length = 0 then
            System.Threading.Tasks.Task.CompletedTask
        else
            System.Threading.Tasks.Task.WhenAll(snapshot)

    /// Cancel the scope's source — every child task observing the
    /// token sees `IsCancellationRequested = true`.
    static member Cancel (scope: LyricTaskScope) : unit =
        scope.Cancel()

    /// Dispose the scope.  Safe to call from `defer { ... }`.
    static member Dispose (scope: LyricTaskScope) : unit =
        scope.Dispose()

/// `(IsValid, Value, Error)` triple.  Same shape as `Std.Parse` /
/// `Std.File` but factored out so future stdlib modules don't each
/// hand-roll their own try/catch wrappers in F#.
[<Sealed; AbstractClass>]
type TryHost<'T> private () =

    /// True if invoking `action` returns without throwing.
    static member RunIsValid (action: System.Func<'T>) : bool =
        try
            let _ = action.Invoke()
            true
        with _ -> false

    /// Invoke `action` and return its result.  Returns
    /// `default(T)` when the call throws — gate on `RunIsValid` first.
    static member RunValue (action: System.Func<'T>) : 'T =
        try action.Invoke()
        with _ -> Unchecked.defaultof<'T>

    /// Diagnostic message for the most recent failure observed by
    /// `RunIsValid`.  Like `FileHost.ReadError`, invokes `action` again
    /// to recover the message; pair with `RunIsValid` so the success
    /// path doesn't pay this cost.
    static member RunError (action: System.Func<'T>) : string =
        try
            let _ = action.Invoke()
            ""
        with e -> e.GetType().Name + ": " + e.Message

/// Bootstrap-grade growable list of `int`.  Wraps `List<int>` so it
/// can be exposed as a Lyric `extern type` — generics aren't visible
/// across the FFI boundary today, so each element type gets its own
/// concrete CLR class.
[<Sealed>]
type IntList() =
    let backing = System.Collections.Generic.List<int>()
    static member New () : IntList = IntList()
    member _.Add (x: int) : unit = backing.Add x
    member _.Get (i: int) : int = backing.[i]
    member _.Set (i: int, x: int) : unit = backing.[i] <- x
    member _.Length () : int = backing.Count
    member _.HasItem (x: int) : bool = backing.Contains x
    member _.RemoveAt (i: int) : unit = backing.RemoveAt i
    member _.Clear () : unit = backing.Clear ()
    member _.ToArr () : int[] = backing.ToArray ()

/// Bootstrap-grade growable list of `string`.  See `IntList`.
[<Sealed>]
type StringList() =
    let backing = System.Collections.Generic.List<string>()
    static member New () : StringList = StringList()
    member _.Add (x: string) : unit = backing.Add x
    member _.Get (i: int) : string = backing.[i]
    member _.Set (i: int, x: string) : unit = backing.[i] <- x
    member _.Length () : int = backing.Count
    member _.HasItem (x: string) : bool = backing.Contains x
    member _.RemoveAt (i: int) : unit = backing.RemoveAt i
    member _.Clear () : unit = backing.Clear ()
    member _.ToArr () : string[] = backing.ToArray ()

/// Bootstrap-grade growable list of `int64` (Lyric `Long`).
[<Sealed>]
type LongList() =
    let backing = System.Collections.Generic.List<int64>()
    static member New () : LongList = LongList()
    member _.Add (x: int64) : unit = backing.Add x
    member _.Get (i: int) : int64 = backing.[i]
    member _.Set (i: int, x: int64) : unit = backing.[i] <- x
    member _.Length () : int = backing.Count
    member _.HasItem (x: int64) : bool = backing.Contains x
    member _.RemoveAt (i: int) : unit = backing.RemoveAt i
    member _.Clear () : unit = backing.Clear ()
    member _.ToArr () : int64[] = backing.ToArray ()

/// Bootstrap-grade hash map keyed on `string` with `int` values.
/// Wraps `Dictionary<string, int>`.  Lookup returns a paired
/// `Has` / `Get` shape so callers can gate on existence; Lyric has no
/// out-params and the safe wrapper builds an `Option[Int]` from the
/// pair.  See `Std.Collections` for the Lyric-side surface.
[<Sealed>]
type StringIntMap() =
    let backing = System.Collections.Generic.Dictionary<string, int>()
    static member New () : StringIntMap = StringIntMap()
    member _.Put (key: string, value: int) : unit = backing.[key] <- value
    member _.Has (key: string) : bool = backing.ContainsKey key
    /// Returns `0` when `Has(key)` is false; callers must gate.
    member _.Get (key: string) : int =
        match backing.TryGetValue key with
        | true, v -> v
        | _       -> 0
    member _.RemoveKey (key: string) : bool = backing.Remove key
    member _.Length () : int = backing.Count
    member _.Clear () : unit = backing.Clear ()
    member _.Keys () : string[] =
        let arr : string[] = Array.zeroCreate backing.Count
        backing.Keys.CopyTo(arr, 0)
        arr

/// Bootstrap-grade hash map keyed on `string` with `string` values.
/// See `StringIntMap`.
[<Sealed>]
type StringStringMap() =
    let backing = System.Collections.Generic.Dictionary<string, string>()
    static member New () : StringStringMap = StringStringMap()
    member _.Put (key: string, value: string) : unit = backing.[key] <- value
    member _.Has (key: string) : bool = backing.ContainsKey key
    member _.Get (key: string) : string =
        match backing.TryGetValue key with
        | true, v -> v
        | _       -> ""
    member _.RemoveKey (key: string) : bool = backing.Remove key
    member _.Length () : int = backing.Count
    member _.Clear () : unit = backing.Clear ()
    member _.Keys () : string[] =
        let arr : string[] = Array.zeroCreate backing.Count
        backing.Keys.CopyTo(arr, 0)
        arr

/// File I/O host shim.  Each operation catches host exceptions and
/// returns a tuple-shaped pair (`IsValid` flag + value/message) so the
/// Lyric-side caller can decide whether to wrap `Ok` or `Err`.  The
/// pair-of-statics shape is deliberate: Lyric has no out-params and we
/// don't want host exceptions to escape across the FFI boundary.
///
/// The error message is normalised to `<exception type>: <message>` so
/// callers can include it in `IoError(path, message)` without needing
/// the exception object itself.
/// Thin host helpers that dodge the `default-parameter` shape on a
/// few BCL APIs whose canonical overloads only ship as
/// `Method(input, options = default)`.  Lyric's FFI default-arg
/// emit works for primitives but not always for unmanaged structs
/// like `JsonDocumentOptions`; this layer is a stable workaround.
[<Sealed; AbstractClass>]
type JsonHost private () =

    /// Parse a JSON document from a UTF-16 string with default
    /// `JsonDocumentOptions`.
    static member Parse (input: string) : System.Text.Json.JsonDocument =
        System.Text.Json.JsonDocument.Parse(input)

    /// Encode `s` as a JSON-string literal (including surrounding
    /// quotes).  Backslashes / quotes / control characters are
    /// escaped via the BCL's `JsonEncodedText`.
    static member EncodeString (s: string) : string =
        let encoded = System.Text.Json.JsonEncodedText.Encode(s)
        "\"" + encoded.ToString() + "\""

    // -------- Slice / array rendering for `@derive(Json)` --------
    //
    // Per-element-type helpers because Lyric's stdlib FFI has no
    // first-class generic delegate dispatch.  Each primitive slice
    // gets its own renderer that emits a comma-separated `[...]`
    // JSON array literal.  Elements that are themselves objects
    // (records / `obj[]` slices via auto-boxing) route through
    // `RenderObjSlice` which calls `EncodeString` on String / falls
    // through to `Convert.ToString` for everything else.

    static member RenderIntSlice (items: int[] | null) : string =
        match Option.ofObj items with
        | None    -> "[]"
        | Some xs ->
            let sb = System.Text.StringBuilder("[")
            for i = 0 to xs.Length - 1 do
                if i > 0 then sb.Append(',') |> ignore
                sb.Append(string xs.[i]) |> ignore
            sb.Append(']').ToString()

    static member RenderLongSlice (items: int64[] | null) : string =
        match Option.ofObj items with
        | None    -> "[]"
        | Some xs ->
            let sb = System.Text.StringBuilder("[")
            for i = 0 to xs.Length - 1 do
                if i > 0 then sb.Append(',') |> ignore
                sb.Append(string xs.[i]) |> ignore
            sb.Append(']').ToString()

    static member RenderDoubleSlice (items: double[] | null) : string =
        match Option.ofObj items with
        | None    -> "[]"
        | Some xs ->
            let sb = System.Text.StringBuilder("[")
            for i = 0 to xs.Length - 1 do
                if i > 0 then sb.Append(',') |> ignore
                // Use round-trip "R" so 1.5 → "1.5" not "1.5000000000000002".
                sb.Append(xs.[i].ToString("R", System.Globalization.CultureInfo.InvariantCulture))
                |> ignore
            sb.Append(']').ToString()

    static member RenderBoolSlice (items: bool[] | null) : string =
        match Option.ofObj items with
        | None    -> "[]"
        | Some xs ->
            let sb = System.Text.StringBuilder("[")
            for i = 0 to xs.Length - 1 do
                if i > 0 then sb.Append(',') |> ignore
                sb.Append(if xs.[i] then "true" else "false") |> ignore
            sb.Append(']').ToString()

    // -------- fromJson primitive field readers --------
    //
    // Per-primitive-type out-param helpers used by the synthesiser
    // (D-progress-046).  Each reader takes a JSON string + property
    // name and writes the parsed value via an `out` parameter,
    // returning `true` on success.  Re-parsing the document per
    // call is wasteful but avoids exposing JsonDocument across
    // the FFI boundary; the synthesiser is bootstrap-grade and a
    // future revision can pass a parsed handle.

    static member GetInt (json: string, name: string, [<System.Runtime.InteropServices.Out>] value: byref<int>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Number then
                e.TryGetInt32(&value)
            else false
        with _ -> false

    static member GetLong (json: string, name: string, [<System.Runtime.InteropServices.Out>] value: byref<int64>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Number then
                e.TryGetInt64(&value)
            else false
        with _ -> false

    static member GetDouble (json: string, name: string, [<System.Runtime.InteropServices.Out>] value: byref<double>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Number then
                e.TryGetDouble(&value)
            else false
        with _ -> false

    static member GetBool (json: string, name: string, [<System.Runtime.InteropServices.Out>] value: byref<bool>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e) then
                match e.ValueKind with
                | System.Text.Json.JsonValueKind.True  -> value <- true ; true
                | System.Text.Json.JsonValueKind.False -> value <- false ; true
                | _ -> false
            else false
        with _ -> false

    static member GetString (json: string, name: string, [<System.Runtime.InteropServices.Out>] value: byref<string>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.String then
                let raw = e.GetString()
                value <-
                    match Option.ofObj raw with
                    | Some s -> s
                    | None   -> ""
                true
            else false
        with _ -> false

    static member RenderStringSlice (items: (string | null)[] | null) : string =
        match Option.ofObj items with
        | None    -> "[]"
        | Some xs ->
            let sb = System.Text.StringBuilder("[")
            for i = 0 to xs.Length - 1 do
                if i > 0 then sb.Append(',') |> ignore
                let raw = xs.[i]
                let s : string =
                    match Option.ofObj raw with
                    | Some v -> v
                    | None   -> ""
                let encoded = System.Text.Json.JsonEncodedText.Encode(s)
                sb.Append('"').Append(encoded.ToString()).Append('"') |> ignore
            sb.Append(']').ToString()

    // -------- fromJson slice / sub-object readers --------
    //
    // Per-element-type slice readers + a generic sub-object reader
    // that returns the matching field as a JSON-encoded string so
    // the synthesised `Inner.fromJson(subStr)` call can recurse.
    // All readers return `false` and leave `value` at `default(T)`
    // when the field is missing or the type doesn't match — the
    // synthesiser ignores the return value (the caller then sees a
    // default-initialised array / empty string and constructs the
    // record with a default field value).

    static member GetIntSlice
            (json: string, name: string,
             [<System.Runtime.InteropServices.Out>] value: byref<int[]>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Array then
                let arr = ResizeArray<int>()
                for el in e.EnumerateArray() do
                    let mutable v = 0
                    if el.TryGetInt32(&v) then arr.Add(v)
                value <- arr.ToArray()
                true
            else
                value <- Array.empty<int>
                false
        with _ ->
            value <- Array.empty<int>
            false

    static member GetLongSlice
            (json: string, name: string,
             [<System.Runtime.InteropServices.Out>] value: byref<int64[]>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Array then
                let arr = ResizeArray<int64>()
                for el in e.EnumerateArray() do
                    let mutable v = 0L
                    if el.TryGetInt64(&v) then arr.Add(v)
                value <- arr.ToArray()
                true
            else
                value <- Array.empty<int64>
                false
        with _ ->
            value <- Array.empty<int64>
            false

    static member GetDoubleSlice
            (json: string, name: string,
             [<System.Runtime.InteropServices.Out>] value: byref<double[]>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Array then
                let arr = ResizeArray<double>()
                for el in e.EnumerateArray() do
                    let mutable v = 0.0
                    if el.TryGetDouble(&v) then arr.Add(v)
                value <- arr.ToArray()
                true
            else
                value <- Array.empty<double>
                false
        with _ ->
            value <- Array.empty<double>
            false

    static member GetBoolSlice
            (json: string, name: string,
             [<System.Runtime.InteropServices.Out>] value: byref<bool[]>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Array then
                let arr = ResizeArray<bool>()
                for el in e.EnumerateArray() do
                    match el.ValueKind with
                    | System.Text.Json.JsonValueKind.True  -> arr.Add(true)
                    | System.Text.Json.JsonValueKind.False -> arr.Add(false)
                    | _ -> ()
                value <- arr.ToArray()
                true
            else
                value <- Array.empty<bool>
                false
        with _ ->
            value <- Array.empty<bool>
            false

    static member GetStringSlice
            (json: string, name: string,
             [<System.Runtime.InteropServices.Out>] value: byref<string[]>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Array then
                let arr = ResizeArray<string>()
                for el in e.EnumerateArray() do
                    if el.ValueKind = System.Text.Json.JsonValueKind.String then
                        let raw = el.GetString()
                        match Option.ofObj raw with
                        | Some s -> arr.Add(s)
                        | None   -> arr.Add("")
                value <- arr.ToArray()
                true
            else
                value <- Array.empty<string>
                false
        with _ ->
            value <- Array.empty<string>
            false

    /// Extract a sub-object field as its raw JSON-text representation.
    /// Used by the synthesiser for nested `@derive(Json)` record
    /// fields: `field: Inner` → call `GetSubObject(s, "field",
    /// subStr)` and recurse on `Inner.fromJson(subStr)`.
    static member GetSubObject
            (json: string, name: string,
             [<System.Runtime.InteropServices.Out>] value: byref<string>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && (e.ValueKind = System.Text.Json.JsonValueKind.Object
                   || e.ValueKind = System.Text.Json.JsonValueKind.Array) then
                value <- e.GetRawText()
                true
            else
                value <- "{}"
                false
        with _ ->
            value <- "{}"
            false

    /// Returns true when `name` is a present, non-null field on the
    /// JSON document.  Used by Option-typed fields to distinguish
    /// `None` (missing/null) from `Some` (present + parseable).
    static member HasField (json: string, name: string) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            doc.RootElement.TryGetProperty(name, &e)
            && e.ValueKind <> System.Text.Json.JsonValueKind.Null

        with _ -> false

    /// Read a sub-array field's elements as raw JSON strings.  Used
    /// by `slice[Inner]` field synthesis where each element needs
    /// to recurse via `Inner.fromJson(elemStr)`.
    static member GetSubArrayElements
            (json: string, name: string,
             [<System.Runtime.InteropServices.Out>] value: byref<string[]>) : bool =
        try
            use doc = System.Text.Json.JsonDocument.Parse(json)
            let mutable e = Unchecked.defaultof<System.Text.Json.JsonElement>
            if doc.RootElement.TryGetProperty(name, &e)
               && e.ValueKind = System.Text.Json.JsonValueKind.Array then
                let arr = ResizeArray<string>()
                for el in e.EnumerateArray() do
                    arr.Add(el.GetRawText())
                value <- arr.ToArray()
                true
            else
                value <- Array.empty<string>
                false
        with _ ->
            value <- Array.empty<string>
            false

/// HTTP client helpers wrapping `System.Net.Http`.  Extern-package
/// declarations in Lyric source can't currently route to BCL
/// methods directly (they parse + type-check but never reach
/// codegen with a target method).  These thin static shims give
/// `Std.HttpHost` something concrete to `@externTarget` against
/// (D-progress-052).
[<Sealed; AbstractClass>]
type HttpClientHost private () =

    static member DefaultClient () : System.Net.Http.HttpClient =
        new System.Net.Http.HttpClient()

    static member MakeRequest (httpMethod: string, url: string) : System.Net.Http.HttpRequestMessage =
        new System.Net.Http.HttpRequestMessage(
            new System.Net.Http.HttpMethod(httpMethod),
            url)

    static member WithHeader (
            request: System.Net.Http.HttpRequestMessage,
            key: string,
            value: string) : System.Net.Http.HttpRequestMessage =
        request.Headers.TryAddWithoutValidation(key, value) |> ignore
        request

    static member WithStringBody (
            request: System.Net.Http.HttpRequestMessage,
            contentType: string,
            body: string) : System.Net.Http.HttpRequestMessage =
        request.Content <- new System.Net.Http.StringContent(
            body,
            System.Text.Encoding.UTF8,
            contentType)
        request

    static member Send (
            client: System.Net.Http.HttpClient,
            request: System.Net.Http.HttpRequestMessage) : System.Threading.Tasks.Task<System.Net.Http.HttpResponseMessage> =
        client.SendAsync(request)

    static member Get (
            client: System.Net.Http.HttpClient,
            url: string) : System.Threading.Tasks.Task<System.Net.Http.HttpResponseMessage> =
        client.GetAsync(url)

    static member PostString (
            client: System.Net.Http.HttpClient,
            url: string,
            body: string,
            contentType: string) : System.Threading.Tasks.Task<System.Net.Http.HttpResponseMessage> =
        let content =
            new System.Net.Http.StringContent(
                body,
                System.Text.Encoding.UTF8,
                contentType)
        client.PostAsync(url, content)

    static member StatusCode (response: System.Net.Http.HttpResponseMessage) : int =
        int response.StatusCode

    static member ReadBodyText (response: System.Net.Http.HttpResponseMessage) : System.Threading.Tasks.Task<string> =
        response.Content.ReadAsStringAsync()

    static member ReadBodyBytes (response: System.Net.Http.HttpResponseMessage) : System.Threading.Tasks.Task<byte[]> =
        response.Content.ReadAsByteArrayAsync()

/// `System.Random` helpers used by `Std.Random`.  `System.Random`
/// has overloaded `Next` methods that auto-FFI's strict-match
/// can resolve, but the seeded constructor and the boolean
/// helper need their own thin wrappers (D-progress-055).
[<Sealed; AbstractClass>]
type RandomHost private () =

    static member Make (seed: int) : System.Random =
        new System.Random(seed)

    static member NextBool (rng: System.Random) : bool =
        // 50/50 split; cheaper than NextDouble + comparison and
        // matches the C# `rng.Next(2) == 1` idiom.
        rng.Next(2) = 1

/// HTTP server helpers wrapping `System.Net.HttpListener`.  The
/// canonical loop is `nextContext` (blocking) → inspect / respond →
/// `respondClose`.  Prefixes follow the HttpListener convention:
/// `http://localhost:8080/api/`.
[<Sealed; AbstractClass>]
type HttpServerHost private () =

    static member StartListener (prefix: string) : System.Net.HttpListener =
        let l = new System.Net.HttpListener()
        l.Prefixes.Add(prefix)
        l.Start()
        l

    static member NextContext (l: System.Net.HttpListener) : System.Net.HttpListenerContext =
        l.GetContext()

    static member StopListener (l: System.Net.HttpListener) : unit =
        l.Stop()

    static member RequestMethod (c: System.Net.HttpListenerContext) : string =
        try c.Request.HttpMethod with _ -> "GET"

    static member RequestPath (c: System.Net.HttpListenerContext) : string =
        try
            match Option.ofObj c.Request.Url with
            | Some uri -> uri.AbsolutePath
            | None     -> "/"
        with _ -> "/"

    /// Read the request body as a UTF-8 string (or `""` if there's no
    /// body / the BCL hands us a null stream).  Wrapped in `try` so a
    /// transport-level error doesn't crash the accept loop.
    static member RequestBody (c: System.Net.HttpListenerContext) : string =
        try
            let req = c.Request
            let s = req.InputStream
            use reader = new System.IO.StreamReader(s, req.ContentEncoding)
            reader.ReadToEnd()
        with _ -> ""

    /// Reply with a status code + plaintext body.  Sets
    /// `Content-Type: text/plain; charset=utf-8` and closes the
    /// response.  Suitable for simple endpoints; a JSON helper sits
    /// next to this with `application/json`.
    static member RespondText
            (c: System.Net.HttpListenerContext, status: int, body: string) : unit =
        let resp = c.Response
        resp.StatusCode <- status
        resp.ContentType <- "text/plain; charset=utf-8"
        let bytes = System.Text.Encoding.UTF8.GetBytes(body)
        resp.ContentLength64 <- int64 bytes.Length
        resp.OutputStream.Write(bytes, 0, bytes.Length)
        resp.OutputStream.Close()
        resp.Close()

    static member RespondJson
            (c: System.Net.HttpListenerContext, status: int, body: string) : unit =
        let resp = c.Response
        resp.StatusCode <- status
        resp.ContentType <- "application/json; charset=utf-8"
        let bytes = System.Text.Encoding.UTF8.GetBytes(body)
        resp.ContentLength64 <- int64 bytes.Length
        resp.OutputStream.Write(bytes, 0, bytes.Length)
        resp.OutputStream.Close()
        resp.Close()

[<Sealed; AbstractClass>]
type FileHost private () =

    /// Probe whether `path` names an existing regular file.  Returns
    /// false for invalid paths (no exception escapes).
    static member Exists (path: string) : bool =
        try System.IO.File.Exists(path)
        with _ -> false

    /// True if `ReadValue(path)` would succeed.  Performs the read and
    /// throws away the result — a bootstrap convenience until Lyric
    /// gets out-parameters.  Callers that gate on this then call
    /// `ReadValue` are paying the IO cost twice.
    static member ReadIsValid (path: string) : bool =
        try
            let _ = System.IO.File.ReadAllText(path)
            true
        with _ -> false

    /// Read the file at `path` as UTF-8 text.  Returns `""` on any
    /// host error; callers should gate on `ReadIsValid`.
    static member ReadValue (path: string) : string =
        try System.IO.File.ReadAllText(path)
        with _ -> ""

    /// Diagnostic message for the most recent failure observed by
    /// `ReadIsValid` — hand-rolled because the F# `try` above swallows
    /// the exception. Calling this when the previous read succeeded
    /// returns `""`.
    static member ReadError (path: string) : string =
        try
            let _ = System.IO.File.ReadAllText(path)
            ""
        with e -> e.GetType().Name + ": " + e.Message

    /// Write `text` to `path` (overwriting if it exists).  Returns
    /// true on success, false if the host call threw.
    static member WriteIsValid (path: string, text: string) : bool =
        try
            System.IO.File.WriteAllText(path, text)
            true
        with _ -> false

    /// Diagnostic message paired with `WriteIsValid`.  Like `ReadError`,
    /// invokes the operation a second time to recover the message.
    /// Use when surfacing a write failure to a `Result.Err` arm.
    static member WriteError (path: string, text: string) : string =
        try
            System.IO.File.WriteAllText(path, text)
            ""
        with e -> e.GetType().Name + ": " + e.Message

    /// Probe whether `path` names an existing directory.
    static member DirectoryExists (path: string) : bool =
        try System.IO.Directory.Exists(path)
        with _ -> false

    /// Create the directory (and any missing parents).  No-op if it
    /// already exists.  Returns true on success.
    static member CreateDirectoryIsValid (path: string) : bool =
        try
            let _ = System.IO.Directory.CreateDirectory(path)
            true
        with _ -> false

/// Numeric / bool parsing routed through `int.TryParse` etc.  The pair
/// `IsValid` / `Value` is a bootstrap-grade workaround for not having
/// out-parameters on the Lyric side: callers gate `Value` behind
/// `IsValid` and accept the cost of parsing twice.  When real out
/// parameters land the pair collapses into a single TryParse method.
[<Sealed; AbstractClass>]
type Parse private () =

    static member IntIsValid (s: string) : bool =
        let mutable v = 0
        System.Int32.TryParse(s, &v)

    static member IntValue (s: string) : int =
        let mutable v = 0
        System.Int32.TryParse(s, &v) |> ignore
        v

    static member LongIsValid (s: string) : bool =
        let mutable v = 0L
        System.Int64.TryParse(s, &v)

    static member LongValue (s: string) : int64 =
        let mutable v = 0L
        System.Int64.TryParse(s, &v) |> ignore
        v

    static member DoubleIsValid (s: string) : bool =
        let mutable v = 0.0
        System.Double.TryParse(
            s,
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture,
            &v)

    static member DoubleValue (s: string) : double =
        let mutable v = 0.0
        System.Double.TryParse(
            s,
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture,
            &v)
        |> ignore
        v
