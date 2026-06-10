/// Helper for Std.Http: process-wide HttpClient singleton.
///
/// Issue #333: `System.Net.Http.HttpClient` must be reused across
/// requests.  Creating a new HttpClient per call is the canonical
/// .NET anti-pattern — under load the per-call clients exhaust the
/// TCP socket pool because sockets stay in TIME_WAIT for two MSL
/// after the client is GC'd.
///
/// Exposed as `Lyric.Emitter.HttpClientHost.defaultClient` so the
/// stdlib kernel (`lyric-stdlib/std/_kernel/http_host.l`) can target
/// it via `@externTarget` and get the same instance on every call.
///
/// The Lyric language does not yet support non-constant package-level
/// `val` declarations, so the singleton lives here as a `Lazy<T>`
/// inside an F# helper module.  Once wire-emitter support for
/// non-constant module vals lands (M5.2 stage 3+), the host shim can
/// retire in favour of a pure-Lyric `pub val` in `Std.Http`.
/// Tracked in #3027.
module Lyric.Emitter.HttpClientHost

open System
open System.Net.Http

/// Lazy is thread-safe by default (LazyThreadSafetyMode.ExecutionAndPublication),
/// so the underlying HttpClient is created exactly once per process even under
/// concurrent first access.
let private lazyClient : Lazy<HttpClient> =
    Lazy<HttpClient>(fun () -> new HttpClient())

/// Return the process-wide HttpClient singleton.  Safe to call from
/// multiple threads; the underlying client is created lazily on first
/// access and reused for every subsequent call.
let defaultClient () : HttpClient =
    lazyClient.Value
