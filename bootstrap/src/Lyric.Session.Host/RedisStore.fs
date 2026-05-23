/// Lyric.Session.RedisStore — .NET host shim that bridges the
/// `Session.Kernel.Net` Lyric kernel boundary to StackExchange.Redis.
///
/// The Lyric kernel file `lyric-session/src/_kernel/net/session_kernel.l`
/// declares each entry point with
/// `@externTarget("Lyric.Session.RedisStore.<method>")`; the emitter
/// resolves those references to the static methods below at codegen
/// time, so user code calling `Session.Kernel.Net.connect(...)` produces
/// an IL `call` straight into these methods.
///
/// Result-shape contract:
///   - All methods translate StackExchange.Redis exceptions into
///     `Result<T, string> = Error(msg)` so they never escape the Lyric
///     `Result[T, String]` boundary.
///   - The `int` storeHandle is an opaque key into the in-process
///     `connections` ConcurrentDictionary; user code treats it as
///     opaque.
///   - `connect` always returns a fresh handle even when called with
///     the same URL twice — handles are cheap; multiplexing the
///     underlying `IConnectionMultiplexer` is the StackExchange.Redis
///     library's job (it pools per-host internally).
///
/// Phase-1 scope (#733): single Redis backend, no cluster mode.  TLS,
/// SCAN-based listing, and Sentinel/cluster mode are tracked for
/// follow-up under #777's umbrella.

namespace Lyric.Session

open System
open System.Collections.Concurrent
open System.Threading
open StackExchange.Redis

/// Internal handle entry kept inside the connection dictionary.
type private RedisHandle =
    { Multiplexer: IConnectionMultiplexer
      Database:   IDatabase
      KeyPrefix:  string }

/// Static-method host shim referenced by the kernel's
/// `@externTarget("Lyric.Session.RedisStore.<method>")` declarations.
[<Sealed; AbstractClass>]
type RedisStore private () =

    static let connections : ConcurrentDictionary<int, RedisHandle> =
        ConcurrentDictionary<int, RedisHandle>()

    static let nextHandle : int ref = ref 0

    /// Encode "session:" prefix + UUID into the Redis key.
    static let toKey (h: RedisHandle) (sessionId: string) =
        h.KeyPrefix + sessionId

    /// Wrap a Func into our Result/Error string contract.
    static let safeCall (op: unit -> 'T) : Result<'T, string> =
        try Ok (op())
        with ex -> Error (sprintf "%s: %s" (ex.GetType().Name) ex.Message)

    /// Open a connection pool to Redis at `url` and register the
    /// returned handle.  `keyPrefix` is prepended to every session key.
    static member connect(url: string, keyPrefix: string) : Result<int, string> =
        if String.IsNullOrEmpty(url) then
            Error "Lyric.Session.RedisStore.connect: url must be non-empty"
        else
            safeCall (fun () ->
                let mux = ConnectionMultiplexer.Connect(url)
                let db  = mux.GetDatabase()
                let h   = Interlocked.Increment(nextHandle)
                let entry = { Multiplexer = mux; Database = db; KeyPrefix = keyPrefix }
                connections.[h] <- entry
                h)

    /// Allocate a fresh session ID, persist an empty JSON object under
    /// it with the supplied TTL, and return the ID.
    static member create(storeHandle: int, ttlSeconds: int) : Result<string, string> =
        if ttlSeconds < 0 then
            Error "Lyric.Session.RedisStore.create: ttlSeconds must be >= 0"
        else
            match connections.TryGetValue(storeHandle) with
            | true, h ->
                safeCall (fun () ->
                    let sessionId = Guid.NewGuid().ToString("N")
                    let key = toKey h sessionId
                    let ttl =
                        if ttlSeconds = 0 then Nullable<TimeSpan>()
                        else Nullable(TimeSpan.FromSeconds(float ttlSeconds))
                    h.Database.StringSet(RedisKey.op_Implicit(key),
                                         RedisValue.op_Implicit("{}"),
                                         ttl) |> ignore
                    sessionId)
            | false, _ ->
                Error (sprintf "Lyric.Session.RedisStore.create: unknown storeHandle %d" storeHandle)

    /// Read the JSON-encoded session value.  Returns an empty string
    /// when the key is missing or expired (matches the JVM kernel's
    /// "empty string = not found" convention).
    static member load(storeHandle: int, sessionId: string) : Result<string, string> =
        if String.IsNullOrEmpty(sessionId) then
            Error "Lyric.Session.RedisStore.load: sessionId must be non-empty"
        else
            match connections.TryGetValue(storeHandle) with
            | true, h ->
                safeCall (fun () ->
                    let key = toKey h sessionId
                    let value = h.Database.StringGet(RedisKey.op_Implicit(key))
                    if value.IsNullOrEmpty then ""
                    else value.ToString())
            | false, _ ->
                Error (sprintf "Lyric.Session.RedisStore.load: unknown storeHandle %d" storeHandle)

    /// Persist the JSON-encoded session value at its existing key,
    /// preserving the original TTL.  `sessionId` identifies the Redis key
    /// directly — no JSON parsing required.
    static member save(storeHandle: int, sessionId: string, sessionJson: string) : Result<unit, string> =
        if String.IsNullOrEmpty(sessionId) then
            Error "Lyric.Session.RedisStore.save: sessionId must be non-empty"
        elif String.IsNullOrEmpty(sessionJson) then
            Error "Lyric.Session.RedisStore.save: sessionJson must be non-empty"
        else
            match connections.TryGetValue(storeHandle) with
            | true, h ->
                safeCall (fun () ->
                    let key = toKey h sessionId
                    // KeepTtl preserves the TTL that `create` set;
                    // explicit re-set without TTL would otherwise erase it.
                    h.Database.StringSet(
                        RedisKey.op_Implicit(key),
                        RedisValue.op_Implicit(sessionJson),
                        Nullable<TimeSpan>(),
                        keepTtl = true) |> ignore)
            | false, _ ->
                Error (sprintf "Lyric.Session.RedisStore.save: unknown storeHandle %d" storeHandle)

    /// Permanently delete the session row; no-op if absent.
    static member destroy(storeHandle: int, sessionId: string) : Result<unit, string> =
        if String.IsNullOrEmpty(sessionId) then
            Error "Lyric.Session.RedisStore.destroy: sessionId must be non-empty"
        else
            match connections.TryGetValue(storeHandle) with
            | true, h ->
                safeCall (fun () ->
                    let key = toKey h sessionId
                    h.Database.KeyDelete(RedisKey.op_Implicit(key)) |> ignore)
            | false, _ ->
                Error (sprintf "Lyric.Session.RedisStore.destroy: unknown storeHandle %d" storeHandle)

    /// Refresh the session's TTL without changing its contents.
    /// `ttlSeconds = 0` leaves the existing TTL unchanged.
    static member touch(storeHandle: int, sessionId: string, ttlSeconds: int) : Result<unit, string> =
        if String.IsNullOrEmpty(sessionId) then
            Error "Lyric.Session.RedisStore.touch: sessionId must be non-empty"
        elif ttlSeconds < 0 then
            Error "Lyric.Session.RedisStore.touch: ttlSeconds must be >= 0"
        else
            match connections.TryGetValue(storeHandle) with
            | true, h ->
                if ttlSeconds = 0 then
                    Ok ()
                else
                    safeCall (fun () ->
                        let key = toKey h sessionId
                        let ttl = TimeSpan.FromSeconds(float ttlSeconds)
                        h.Database.KeyExpire(RedisKey.op_Implicit(key),
                                             Nullable(ttl)) |> ignore)
            | false, _ ->
                Error (sprintf "Lyric.Session.RedisStore.touch: unknown storeHandle %d" storeHandle)

