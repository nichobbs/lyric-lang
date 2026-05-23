/// Lyric.Ws.Host — .NET host shim for the lyric-ws kernel.
///
/// Phase 6 of #733: in-process connection registry + sliding-window
/// rate limiter.  Real ASP.NET Core WebSocket integration (HTTP
/// upgrade, MessageReceived loop, Kestrel binding) is tracked under
/// #778 as a separate phase — that path needs the lyric-web Kestrel
/// shim to land first (Phase 8), and Testcontainers infrastructure
/// for the WebSocket handshake regression.
///
/// The kernel file `lyric-ws/src/_kernel/net/ws_kernel.l` declares
/// each entry point with `@externTarget("Lyric.Ws.RegistryHost.<method>")`
/// or `@externTarget("Lyric.Ws.RateLimitHost.<method>")`; the emitter
/// resolves those references to the static methods below at codegen
/// time.
///
/// Path-finder scope: the registry tracks connection IDs (opaque
/// strings issued by the caller — typically GUID per handshake) and
/// supports `send` / `broadcast` / `close` / `connectionCount` /
/// `isConnected` at the bookkeeping level.  The send / broadcast
/// operations record the frame in a per-connection buffer that callers
/// can inspect via future test hooks; they do not push bytes over a
/// real socket yet.  This is sufficient to validate the Lyric-side
/// `Ws.*` API surface and for downstream test programs that don't
/// need real network I/O.

namespace Lyric.Ws

open System
open System.Collections.Concurrent
open System.Threading

/// Per-connection state tracked by the in-process registry.
type private Connection =
    { Id:           string
      mutable Open: bool
      /// Buffered outgoing frames — useful for test inspection.
      OutBuf:       ConcurrentQueue<string * string> }

/// Per-registry state.  `connections` is keyed by the caller-supplied
/// connection ID (typically a GUID from the HTTP upgrade response).
type private Registry =
    { MaxMessageSizeBytes: int
      PingIntervalMs:      int
      Connections:         ConcurrentDictionary<string, Connection> }

module private RegistryStore =
    let registries : ConcurrentDictionary<int, Registry> =
        ConcurrentDictionary<int, Registry>()
    let nextHandle : int ref = ref 0

    let register (r: Registry) : int =
        let h = Interlocked.Increment(nextHandle)
        registries.[h] <- r
        h

    let lookup (h: int) : Result<Registry, string> =
        match registries.TryGetValue(h) with
        | true, r -> Ok r
        | false, _ -> Error (sprintf "unknown registry handle %d" h)

    let safeCall (op: unit -> 'T) : Result<'T, string> =
        try Ok (op())
        with ex -> Error (sprintf "%s: %s" (ex.GetType().Name) ex.Message)

    /// Internal helper for tests / future Kestrel integration: register
    /// a new connection under the supplied ID.  Returns true if added,
    /// false if the ID was already registered.
    let addConnection (registryHandle: int) (connectionId: string) : bool =
        match registries.TryGetValue(registryHandle) with
        | true, r ->
            let conn = { Id = connectionId; Open = true; OutBuf = ConcurrentQueue<string * string>() }
            r.Connections.TryAdd(connectionId, conn)
        | false, _ -> false

/// `Lyric.Ws.RegistryHost` — the static class the kernel's
/// `@externTarget("Lyric.Ws.RegistryHost.<method>")` references resolve
/// to at codegen time.
[<Sealed; AbstractClass>]
type RegistryHost private () =

    /// Allocate a registry.  Returns an opaque integer handle.
    static member createRegistry(maxMessageSizeBytes: int, pingIntervalMs: int) : Result<int, string> =
        if maxMessageSizeBytes < 1024 then
            Error "Lyric.Ws.RegistryHost.createRegistry: maxMessageSizeBytes must be >= 1024"
        elif pingIntervalMs < 0 then
            Error "Lyric.Ws.RegistryHost.createRegistry: pingIntervalMs must be >= 0"
        else
            RegistryStore.safeCall (fun () ->
                let r = {
                    MaxMessageSizeBytes = maxMessageSizeBytes
                    PingIntervalMs = pingIntervalMs
                    Connections = ConcurrentDictionary<string, Connection>()
                }
                RegistryStore.register r)

    /// Send a frame to a specific connection.  In the path-finder
    /// scope, this buffers the frame in the connection's OutBuf
    /// (test-inspectable) and validates the connection is registered
    /// and open.
    static member send(registryHandle: int, connectionId: string,
                        messageType: string, data: string) : Result<unit, string> =
        if String.IsNullOrEmpty(connectionId) then
            Error "Lyric.Ws.RegistryHost.send: connectionId must be non-empty"
        elif String.IsNullOrEmpty(messageType) then
            Error "Lyric.Ws.RegistryHost.send: messageType must be non-empty"
        else
            match RegistryStore.lookup registryHandle with
            | Error e -> Error e
            | Ok r ->
                match r.Connections.TryGetValue(connectionId) with
                | true, conn when conn.Open ->
                    conn.OutBuf.Enqueue((messageType, data))
                    Ok ()
                | true, _  -> Error (sprintf "connection '%s' is closed" connectionId)
                | false, _ -> Error (sprintf "unknown connection '%s'" connectionId)

    /// Broadcast a frame to every open connection in the registry.
    static member broadcast(registryHandle: int, messageType: string,
                             data: string) : Result<unit, string> =
        if String.IsNullOrEmpty(messageType) then
            Error "Lyric.Ws.RegistryHost.broadcast: messageType must be non-empty"
        else
            match RegistryStore.lookup registryHandle with
            | Error e -> Error e
            | Ok r ->
                RegistryStore.safeCall (fun () ->
                    for KeyValue(_, conn) in r.Connections do
                        if conn.Open then
                            conn.OutBuf.Enqueue((messageType, data)))

    /// Close a connection with an RFC 6455 numeric code + reason.
    static member close(registryHandle: int, connectionId: string,
                         code: int, reason: string) : Result<unit, string> =
        if String.IsNullOrEmpty(connectionId) then
            Error "Lyric.Ws.RegistryHost.close: connectionId must be non-empty"
        else
            match RegistryStore.lookup registryHandle with
            | Error e -> Error e
            | Ok r ->
                match r.Connections.TryGetValue(connectionId) with
                | true, conn ->
                    conn.Open <- false
                    conn.OutBuf.Enqueue(("close", sprintf "%d:%s" code reason))
                    Ok ()
                | false, _ -> Ok ()  // idempotent for unknown IDs

    /// Number of currently-open connections.
    static member connectionCount(registryHandle: int) : int =
        match RegistryStore.lookup registryHandle with
        | Ok r ->
            let mutable count = 0
            for KeyValue(_, c) in r.Connections do
                if c.Open then count <- count + 1
            count
        | Error _ -> 0

    /// Is the given connection currently open?
    static member isConnected(registryHandle: int, connectionId: string) : bool =
        if String.IsNullOrEmpty(connectionId) then false
        else
            match RegistryStore.lookup registryHandle with
            | Ok r ->
                match r.Connections.TryGetValue(connectionId) with
                | true, c -> c.Open
                | false, _ -> false
            | Error _ -> false

    /// Test hook: register a connection under the supplied ID.
    /// Real ASP.NET Core integration would call this from the HTTP
    /// upgrade handler.  Marked `static member` so test code can call
    /// it through reflection without an explicit dependency.
    static member registerConnection(registryHandle: int, connectionId: string) : Result<unit, string> =
        if String.IsNullOrEmpty(connectionId) then
            Error "Lyric.Ws.RegistryHost.registerConnection: connectionId must be non-empty"
        elif RegistryStore.addConnection registryHandle connectionId then
            Ok ()
        else
            Error (sprintf "connection '%s' is already registered (or registry handle unknown)" connectionId)

// ─── Sliding-window rate limiter ────────────────────────────────────────────

/// Internal rate-limiter state.  Per-key sliding window: stores the
/// epoch-ms timestamp of each request in the last 60s, plus a burst
/// budget for short-term spikes.
type private RateState =
    { mutable Timestamps:    ResizeArray<int64>
      mutable BurstAvailable: int }

[<Sealed; AbstractClass>]
type RateLimitHost private () =

    static let limiters : ConcurrentDictionary<string, RateState> =
        ConcurrentDictionary<string, RateState>()
    static let limiterLock = obj()

    /// Sliding-window rate limit.  Returns true to allow, false to deny.
    /// State is per-process and per-key; resets on process restart.
    static member checkRateLimit(key: string, messagesPerMinute: int, burstSize: int) : bool =
        if String.IsNullOrEmpty(key) || messagesPerMinute <= 0 || burstSize <= 0 then
            false
        else
            let nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
            let windowStart = nowMs - 60_000L
            lock limiterLock (fun () ->
                let state =
                    limiters.GetOrAdd(key, fun _ ->
                        { Timestamps = ResizeArray<int64>(); BurstAvailable = burstSize })
                // Drop timestamps older than the 60s window.
                let kept = state.Timestamps |> Seq.filter (fun t -> t >= windowStart) |> ResizeArray
                state.Timestamps <- kept
                if kept.Count < messagesPerMinute then
                    state.Timestamps.Add(nowMs)
                    true
                elif state.BurstAvailable > 0 then
                    state.BurstAvailable <- state.BurstAvailable - 1
                    state.Timestamps.Add(nowMs)
                    true
                else
                    false)
