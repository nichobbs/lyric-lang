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
