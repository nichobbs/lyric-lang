//! Web.Kernel.Net — ASP.NET Core / Kestrel extern boundary.
//!
//! Bridges Lyric's Web.Aspects package to the .NET HTTP stack.
//! The `serve` function lives in `web.l` (declared inline rather than
//! imported here because intra-project import resolution does not yet
//! propagate function signatures to the caller's type-checker; see
//! the comment in web.l for details).
//!
//! This package exposes only what Web.Aspects needs:
//!   checkRateLimit — per-endpoint sliding-window rate limiter,
//!                    reusing the process-global ConcurrentDictionary
//!                    implementation in Lyric.Ws.RateLimitHost (WsHost.fs).
//!
//! All functions are @cfg(feature = "dotnet") so they are erased when
//! the dotnet feature is not active (e.g. during JVM builds — Phase 6).
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Web.Kernel.Net

import Std.Core

// ─── Rate limiting ────────────────────────────────────────────────────────────
/// Check whether a call from this endpoint is within the rate limit.
/// Returns true (allow) or false (deny).  State is per-process and
/// per-endpoint; resets on process restart.
///
/// Backed by `Lyric.Ws.RateLimitHost.checkRateLimit` — the same
/// 60-second sliding-window implementation used by the WebSocket
/// rate limiter (`Ws.Kernel.Net.checkRateLimit`).  Both `lyric-web`
/// and `lyric-ws` share this process-global state, keyed by the
/// supplied `endpoint` / `key` string.
@axiom("Lyric.Ws.RateLimitHost.checkRateLimit — per-key 60s sliding-window + burst budget; state is per-process, shared with Ws.Kernel.Net")
@externTarget("Lyric.Ws.RateLimitHost.checkRateLimit")
pub func checkRateLimit(endpoint: String, requestsPerMinute: Int, burstSize: Int): Bool
  requires: endpoint.length > 0
  requires: requestsPerMinute > 0
  requires: burstSize > 0
  = ()
