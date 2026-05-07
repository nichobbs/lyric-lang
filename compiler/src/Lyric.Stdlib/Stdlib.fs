/// Host-side stdlib shim — methods the emitter targets directly when
/// a Lyric construct can't be expressed in pure Lyric (or whose
/// pure-Lyric form is bootstrap-grade per D035 / D038). Each entry
/// is justified by something the language can't yet express:
///
///   - Null-aware `obj` formatting (`PrintlnAny`, `ToStr`): no Lyric
///     surface for `obj | null` discrimination.
///   - Out-parameter readers (`JsonHost.Get*`, `Parse.*Value`):
///     Lyric has no out-params.
///   - Try/catch wrappers (`FileHost.*`, `TryHost.*`): no try/catch
///     bridging across the FFI boundary yet.
///   - Concurrency primitives (`LyricTaskScope`, `AmbientHost`):
///     `protected type` deferred to Phase 3.
///
/// Trivial wrappers (`println(string) -> Console.WriteLine(string)`,
/// integer math) have been hoisted out: see
/// `docs/14-native-stdlib-plan.md` §6 P0 for the migration log.
///
/// The kernel target (Decision F) is ≤150 declarations here.
namespace Lyric.Stdlib

open System

// G8 (`docs/23-fsharp-shim-elimination.md` §5): the prior `Console`
// type held `PrintlnAny(obj | null)` and `ToStr(obj | null)` — both
// retired.  Codegen now inlines the `null -> "()" else value.ToString()`
// lowering directly via `emitNullableToStringInline` in
// `compiler/src/Lyric.Emitter/Codegen.fs`.

// G9 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-110): the
// prior `LyricAssertionException` and `Contracts.{Panic, Expect, Assert}`
// were thin wrappers that constructed a custom exception subclass and
// threw it.  Codegen now inlines `newobj System.Exception(string)` +
// `throw` for every `panic` / `expect` / `assert` call site (and for
// `requires:` / `ensures:` runtime checks), so neither type is needed.
// `try { … } catch Bug as b { … }` resolves `Bug` to `System.Exception`
// already, so the user-visible catch behaviour is unchanged.

// `MapHelpers<'K, 'V>` retired (`docs/23-fsharp-shim-elimination.md`).
// All references were superseded when `Std.Collections` migrated to
// `_kernel/collections_host.l` direct externs in `docs/14` P0/4b
// batch 3.  Kept zero live `@externTarget` callers — verified by
// `KernelBoundaryTests.fs`'s outsideCeiling = 0 ratchet plus a
// repo-wide grep.

// `TaskHost` retired (`docs/23-fsharp-shim-elimination.md` G12;
// D-progress-111).  Both members were thin passthroughs to
// `System.Threading.Tasks.Task.Delay(int)` and
// `Task.Delay(int, CancellationToken)`.  `_kernel/task.l` now externs
// those overloads directly; the codegen's arity-based overload
// resolution picks the right one.

// `Lyric.Stdlib.CancelHost` retired (`docs/23-fsharp-shim-elimination.md`
// Phase 1, D-progress-105 follow-up).  Every method was a thin
// passthrough to `System.Threading.Cancellation{Token,TokenSource}`.
// `stdlib/std/_kernel/task.l` now `@externTarget`s those BCL members
// directly — `CancellationToken.None`, `CancellationTokenSource..ctor`,
// `.Token`, `.Cancel`, `.Dispose`, and the matching token methods.

/// Per-stub call counter for `@stubbable` mocking enhancements
/// (D-progress-073).  Each stub method's auto-synthesised body
/// increments its associated counter on entry; tests can read the
/// counter at the end to assert that the dependency was called the
/// expected number of times.  A counter is just a shared mutable
/// `int` cell wrapped in a class so Lyric records can hold a
/// reference and the increments persist across calls.
type StubCounter() =
    let mutable count = 0
    let lockObj = obj ()
    member _.Increment () : unit =
        lock lockObj (fun () -> count <- count + 1)
    member _.Get () : int =
        lock lockObj (fun () -> count)
    member _.Reset () : unit =
        lock lockObj (fun () -> count <- 0)

[<Sealed; AbstractClass>]
type StubCounterHost private () =
    static member Make () : StubCounter = new StubCounter()
    static member Increment (c: StubCounter) : unit = c.Increment()
    static member Get (c: StubCounter) : int = c.Get()
    static member Reset (c: StubCounter) : unit = c.Reset()

/// Holder for the process-shared `AsyncLocal<CancellationToken>` slot
/// backing `Std.Task`'s ambient cancellation primitive (D-progress-071).
/// Owns nothing else — `currentToken` / `installToken` / `restoreToken` /
/// `hasAmbient` are now native Lyric on top of direct BCL externs to
/// `AsyncLocal\`1.Value` and `CancellationToken.CanBeCanceled`
/// (`docs/23-fsharp-shim-elimination.md` G11; D-progress-NNN).
[<Sealed; AbstractClass>]
type AmbientSlot private () =
    static let slot =
        System.Threading.AsyncLocal<System.Threading.CancellationToken>()
    static member Slot = slot

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

// `TryHost<'T>` retired (`docs/23-fsharp-shim-elimination.md`).
// Designed as a generic try/catch wrapper for FFI calls but never
// referenced from any `@externTarget` declaration — `Std.File` /
// `Std.Parse` etc. carry their own per-method shims, and the generic
// closure-based form was superseded before it was used.  G10 (FFI
// try/catch) makes the whole concept moot.

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

    // P3-3 (native-stdlib plan §6): `RenderIntSlice` / `RenderLongSlice` /
    // `RenderBoolSlice` / `RenderStringSlice` were retired; the
    // `@derive(Json)` synthesiser (`Lyric.Parser.JsonDerive.fs`) now
    // emits inline `while`-loop renderers in pure Lyric for those
    // primitives.  `RenderDoubleSlice` stays here because round-trip-
    // faithful `ToString("R", InvariantCulture)` formatting isn't yet
    // covered by Lyric's `toString`.

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

    // P3-3: `RenderStringSlice` retired; the synthesiser now emits an
    // inline `while`-loop renderer that calls
    // `__lyricJsonEscape(items[i])` per element (which still routes
    // through `JsonHost.EncodeString` — `EncodeString` stays kernel
    // because it depends on `System.Text.Json.JsonEncodedText`).

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

// G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
// `Lyric.Stdlib.HttpClientHost` retires entirely.  Every member
// migrated to direct-extern primitives + Lyric-level helpers in
// `stdlib/std/_kernel/http_host.l` across G12 (2/N) (everything
// except `ResponseHeader`) and this slice (G12 (4/N) —
// `ResponseHeader` rebuilt over `HttpHeaders.TryGetValues(name,
// out IEnumerable<string>)` + `Linq.Enumerable.ToArray<string>`
// shuttling into a `slice[String]` the Lyric side indexes for the
// first-value-or-empty fallback).

// `Lyric.Stdlib.RandomHost` retired (`docs/23-fsharp-shim-elimination.md`
// Phase 1, D-progress-105 follow-up).  `Std.Random` now externs the
// seeded `System.Random..ctor` directly, and `nextBool` is a one-line
// native Lyric body (`nextIntBelow(rng, 2) != 0`).

// G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
// the F# `Lyric.Stdlib.HttpServerHost` shim retires entirely.
// `stdlib/std/_kernel/http_server.l` declares direct-extern primitives
// for `HttpListener` / `HttpListenerContext` / `HttpListenerRequest` /
// `HttpListenerResponse` / `Stream` / `StreamReader` / `Encoding` and
// composes the user-facing `startListener` / `nextContext` /
// `requestMethod` / `requestBody` / `respondText` / `respondJson` /
// etc. as native Lyric on top of them.

// G10 (`docs/23-fsharp-shim-elimination.md` §5): the F# `FileHost`
// type retires entirely with G10 (2/2) (D-progress-NNN).  The
// bytes-flavoured methods (`ReadBytes*`, `WriteBytes*`) were the
// last survivors after G10 (1/2); they now route through direct
// `System.IO.File.{ReadAllBytes, WriteAllBytes}` externs in
// `stdlib/std/_kernel/file_host.l`, with the `byte[]`/`slice[Byte]`
// to `List[Byte]` shuttle done in pure Lyric inside `Std.File`.

// ── Stdlib expansion shims (D-progress-stdlib-expand-01) ──────────────────────
//
// Three host classes that support the new stdlib modules added in the
// expand-lyric-stdlib branch: `Std.Set`, `Std.Format`, and `Std.Encoding`.
// Each follows the same pattern as the retired shim classes above: thin
// wrappers around BCL APIs that the emitter cannot target directly via a
// single @externTarget declaration.

/// Host helper for `Std.Set` — converts a `HashSet<T>` to a plain array
/// so the Lyric side can iterate it with `for x in setToSlice(s)`.
/// A direct `Enumerable.ToArray` @externTarget would require a LINQ import
/// that the emitter's extern resolver does not currently handle.
[<Sealed; AbstractClass>]
type SetHost private () =
    static member SetToArray<'T>(s: System.Collections.Generic.HashSet<'T>) : 'T[] =
        System.Linq.Enumerable.ToArray(s)

/// Host helpers for `Std.Format` — format-string overloads of `ToString`
/// and `PadLeft`/`PadRight` that the emitter's arity-based overload
/// resolution cannot distinguish without an explicit shim.
[<Sealed; AbstractClass>]
type FormatHost private () =
    /// `n.ToString("x")` — lowercase hex.
    static member ToHexString(n: int) : string = n.ToString("x")
    /// `n.ToString("X")` — uppercase hex.
    static member ToHexStringUpper(n: int) : string = n.ToString("X")
    /// `x.ToString("F{decimals}", InvariantCulture)` — fixed-point double.
    static member FormatFixed(x: double, decimals: int) : string =
        x.ToString("F" + string decimals,
                    System.Globalization.CultureInfo.InvariantCulture)
    /// `s.PadLeft(width, ch)`.
    static member PadLeft(s: string, width: int, ch: char) : string =
        s.PadLeft(width, ch)
    /// `s.PadRight(width, ch)`.
    static member PadRight(s: string, width: int, ch: char) : string =
        s.PadRight(width, ch)

/// Host helpers for `Std.Encoding` — Base64, hex, and UTF-8 operations
/// that either can throw (and need try/catch wrapping) or go through a
/// non-static class instance (`Encoding.UTF8`).
[<Sealed; AbstractClass>]
type EncodingHost private () =
    /// Decode Base64.  Returns true and writes bytes on success; false on any
    /// format error — `Convert.FromBase64String` throws `FormatException`.
    static member TryFromBase64
            (s: string,
             [<System.Runtime.InteropServices.Out>] value: byref<byte[]>) : bool =
        try
            value <- System.Convert.FromBase64String(s)
            true
        with _ ->
            value <- Array.empty
            false

    /// Decode hex string (upper or lower case).  Returns true on success;
    /// false on any format error — `Convert.FromHexString` throws on bad input.
    static member TryFromHex
            (s: string,
             [<System.Runtime.InteropServices.Out>] value: byref<byte[]>) : bool =
        try
            value <- System.Convert.FromHexString(s)
            true
        with _ ->
            value <- Array.empty
            false

    /// `System.Text.Encoding.UTF8.GetBytes(string)` — never throws for valid
    /// .NET strings (which are always valid Unicode).
    static member EncodeUtf8(s: string) : byte[] =
        System.Text.Encoding.UTF8.GetBytes(s)

    /// `System.Text.Encoding.UTF8.GetString(byte[])` wrapped in try/catch so
    /// invalid UTF-8 sequences return false rather than throwing
    /// `DecoderFallbackException`.
    static member TryDecodeUtf8
            (bytes: byte[],
             [<System.Runtime.InteropServices.Out>] value: byref<string>) : bool =
        try
            value <- System.Text.Encoding.UTF8.GetString(bytes)
            true
        with _ ->
            value <- ""
            false

// ── JVM class-file emission helpers moved out (Phase 1 Bucket D) ─────────────
//
// `JvmByteBuilder`, `JvmByteHost`, `JvmZipHost`, `JvmConstantPool`, and
// `JvmPoolHost` lived here historically because the F# stdlib was the
// only available place to drop F#-side host code.  They are consumed
// only by the JVM emitter's Lyric source under `compiler/lyric/jvm/`,
// not by stdlib users — so the stdlib bundle no longer carries them.
//
// They now live in `compiler/src/Lyric.Jvm.Hosts/JvmHosts.fs` under the
// `Lyric.Jvm.Hosts` namespace.  See `docs/23-fsharp-shim-elimination.md`
// §4.3 (Bucket D) and D-progress-107 for the migration log.
