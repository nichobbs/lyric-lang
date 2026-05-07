/// Host-side stdlib shim — methods the emitter targets directly when
/// a Lyric construct can't be expressed in pure Lyric (or whose
/// pure-Lyric form is bootstrap-grade per D035 / D038). Each entry
/// is justified by something the language can't yet express:
///
///   - Null-aware `obj` formatting (`PrintlnAny`, `ToStr`): no Lyric
///     surface for `obj | null` discrimination.
///   - Slice readers (`JsonHost.Get*Slice`): iteration over
///     `JsonElement.ArrayEnumerator` (a nested CLR type) requires
///     extern-type resolution for `+`-separated names, not yet done.
///   - Try/catch wrappers (`FileHost.*`, `TryHost.*`): no try/catch
///     bridging across the FFI boundary yet.
///   - There are no remaining concurrency shims; `LyricTaskScope`,
///     `TaskScopeHost`, and `AmbientSlot` have all been retired.
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

// `Lyric.Stdlib.LyricTaskScope` and `Lyric.Stdlib.TaskScopeHost` retired
// (D-progress-stdlib-expand Group C, D-progress-069).  `Scope` is now a
// native Lyric `protected type` in `stdlib/std/_kernel/task.l` backed by
// a `CancellationTokenSource` + `List[Task]`.  All scope operations
// (`makeScope`, `scopeSpawn`, `awaitAll`, `cancelScope`, `disposeScope`)
// are pure Lyric on top of direct BCL externs.

// `Lyric.Stdlib.UnionEquality` retired (D-progress-stdlib-expand).
// `SameType(obj, obj)` was referenced via a `sameTypeMethod` lazy in
// Codegen.fs but the call site was never reached; union-case equality
// uses `Ceq` directly.  Both the F# type and the lazy are now deleted.

// G7 (`docs/23-fsharp-shim-elimination.md`; D-progress-123): F#
// `StubCounter` and `StubCounterHost` retired.  `stdlib/std/testing_mocking.l`
// (top-level, shadows `_kernel/testing_mocking.l` on .NET) now declares
// `pub protected type StubCounter { … }` in pure Lyric.  No F# types needed.

// `Lyric.Stdlib.AmbientSlot` retired (D-progress-stdlib-expand Group D1).
// `stdlib/std/_kernel/task.l` now declares the singleton slot with
// `@asyncLocal val __ambientSlot` so the emitter synthesises the
// static `AsyncLocal<CancellationToken>` field directly on the
// package's program type — no F# involved.

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

    // P3-3: `RenderStringSlice` retired; the synthesiser now emits an
    // inline `while`-loop renderer that calls
    // `__lyricJsonEscape(items[i])` per element (which still routes
    // through `JsonHost.EncodeString` — `EncodeString` stays kernel
    // because it depends on `System.Text.Json.JsonEncodedText`).

    // GetInt/Long/Double/Bool/String and GetSubObject retired
    // (D-progress-stdlib-expand).  The `@derive(Json)` synthesiser
    // (`JsonDerive.fs`) now emits Lyric function bodies that call
    // `lyricJsonGet*` in `Std.JsonHost` (`_kernel/json_host.l`),
    // which chains `hostParseJson` → `hostRootElement` →
    // `hostTryGetProperty` → `hostTryGet*` directly on BCL externs.
    // GetSubObject similarly routes through `hostGetRawText`.

    // -------- fromJson slice readers --------
    //
    // Per-element-type slice readers that return the matching field as
    // a primitive array so the synthesised `fromJson` can assign it.
    // These still route through this shim because iterating
    // `JsonElement.ArrayEnumerator` (a nested BCL struct type) requires
    // `System.Text.Json.JsonElement+ArrayEnumerator` in the extern type
    // table, which Lyric doesn't yet resolve for nested CLR types.
    // Deferred to a follow-up once nested-type extern resolution lands.

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

    // GetSubObject retired (D-progress-stdlib-expand): implemented in
    // pure Lyric via `hostTryGetProperty` + `hostGetRawText` in
    // `_kernel/json_host.l`.
    //
    // HasField retired: unused by `@derive(Json)` synthesiser.
    //
    // GetSubArrayElements retired: unused by `@derive(Json)` synthesiser.

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

// ── Stdlib expansion shims retired (D-progress-stdlib-expand-01 → P0/4d) ──────
//
// SetHost, FormatHost, and EncodingHost all eliminated:
//
//   FormatHost   — replaced by direct BCL externs in _kernel/format_host.l.
//   EncodingHost — replaced by direct BCL externs in _kernel/encoding_host.l.
//   SetHost      — setToSlice now uses IEnumerable for-loop in set.l (Group B);
//                  SFor emitter extended to handle IEnumerable<T> in Codegen.fs.

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
