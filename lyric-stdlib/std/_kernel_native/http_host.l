//! std/_kernel_native/http_host.l — native-target HTTP client kernel for
//! `Std.Http` (docs/61 §3-4/§7, D128; N9.4 of epic #5874 phase 5, issue
//! #6105). Gated on `Std.TcpHost`'s N9.2 transport + N9.4's client-TLS
//! addition to it (`hostConnectTls`/`hostUpgradeClientTls`,
//! `_kernel_native/tcp_host.l`).
//!
//! Mirrors the dotnet (`_kernel/http_host.l`) / JVM (`_kernel_jvm/
//! http_host.l`) public surface: client construction (including
//! `hostClientWithTls`'s CA/insecure/min-version/client-identity options),
//! request building, the `*Safe`/`*WithCancelSafe` send family, and
//! response accessors — so `Std.Http`'s shared `http.l` compiles and
//! resolves identically once this file is the one the native source loader
//! picks up (`Lyric.Emitter.findStdlibSourcesNative`, basename-wins over
//! `_kernel/http_host.l`).
//!
//! ## Why this is a genuine reimplementation, not a port
//!
//! Both other kernels delegate the entire HTTP/1.1 (and h2) wire protocol
//! to a platform HTTP client (`System.Net.Http.HttpClient` /
//! `java.net.http.HttpClient`) — verified by reading both files in full
//! before writing this one. Native has no such platform client, so this
//! file drives the wire protocol itself over `Std.TcpHost`'s
//! `hostConnect`/`hostConnectTls`/`hostRead`/`hostWrite`/`hostClose`.
//!
//! The issue text (and `native/plan/08-work-items.md`'s N9.4 entry, and
//! docs/61 §7's "feeding the same engine and client core") anticipated
//! reusing "the sans-IO engine's client connection FSM" from
//! `Std.HttpEngine`. Reading that file in full (before writing anything
//! here) found this does not exist: `Std.HttpEngine` is a REQUEST parser +
//! RESPONSE serializer — the SERVER's half of HTTP/1.1 (docs/61 §6.1: "HTTP
//! request parser, response serializer, connection state machine" — its own
//! header is explicit that this is the server side; consumed today only by
//! `_kernel/http_server.l` and this same file's sibling
//! `_kernel_native/tcp_host.l`'s doc comments, never a client). A CLIENT
//! needs the opposite pair — REQUEST serialization + RESPONSE parsing — and
//! no such engine exists on any target; `_kernel/http_host.l` /
//! `_kernel_jvm/http_host.l` both get it for free from their platform
//! client instead of a shared Lyric engine. Building a genuine client-side
//! sans-IO engine (and retrofitting the other two kernels onto it) is a
//! much larger, separate, cross-target refactor of two already-shipped,
//! already-tested kernels — squarely out of scope for "N9.4: the native
//! client twin." This file's request/response wire handling below is
//! therefore a self-contained reimplementation, scoped to what a CLIENT
//! needs (serialize one request, parse one response), not a fork of the
//! server engine's request-parsing code.
//!
//! ## Deliberate scope decisions (real, disclosed divergences — not silent gaps)
//!
//! 1. **HTTP/1.1 only, never h2.** ALPN advertises only `"http/1.1"` (never
//!    `"h2,http/1.1"`). This is within `Std.Http.HttpVersion.Http2`'s own
//!    documented contract ("falls back to HTTP/1.1 automatically" when the
//!    peer doesn't negotiate h2 — see `std/http.l`'s `HttpVersion` doc
//!    comment) — a peer this client talks to simply never gets offered h2,
//!    which is a subset of already-documented behaviour, not new undefined
//!    behaviour. `hostResponseVersionMajor` always returns `1`.
//! 2. **One TCP/TLS connection per request; always `Connection: close`.**
//!    No keep-alive/connection-pooling in this slice (the dotnet/JVM
//!    kernels get pooling for free from their platform `HttpClient`).
//!    Correctness is unaffected; only per-request connection-setup latency
//!    is worse than the other two targets. A pooling follow-up is tracked
//!    alongside N9.5.
//! 3. **Unix domain sockets are unsupported** (`panic`, matching the JVM
//!    kernel's own unconditional-panic shape for ITS unrelated reason): the
//!    N9.1 `lyric_sock_*` seam has no Unix-socket transport yet. A future
//!    seam addition would let this file drop the panic with no `Std.Http`-
//!    level changes.
//! 4. **No `Std.String`/`Std.Char` helper calls.** `Lyric.LlvmCodegen`'s
//!    String-receiver method lowering supports ONLY `.toString()` and
//!    `.substring(start, count)` for `--target native` today (verified
//!    directly: `.startsWith`/`.indexOf`/`.trim`/`.split`/`.toUpper` all
//!    panic "method '.X' on this receiver is not yet supported for
//!    --target native" when actually called) — the same gap `Std.Tls`'s
//!    `containsMarker` helper already works around for the identical
//!    reason (see that function's doc comment in `std/tls.l`). Likewise
//!    `slice[Byte]`/`List[Byte]` have no `.slice()`/`.concat()` native
//!    lowering (`Lyric.LlvmCodegen.lowerCollectionMethodCall` implements
//!    only add/set/removeAt/clear/count/length/toArray/toList) and
//!    `Std.Char`/`Std.Parse` have no `_kernel_native/` twin at all
//!    (`Char.toInt`/`fromInt`/`digitValue` route through `Std.CharHost`,
//!    which falls back to the BCL-backed dotnet kernel — unusable on this
//!    target the moment a reachable call site invokes it). Every string/
//!    byte scanning primitive below (`findSubstring`/`splitOn`/
//!    `trimSpaces`/`parseNonNegativeInt`/`parseHexInt`/`findPattern`/
//!    `copyRange`) is therefore hand-rolled from `.substring(start,
//!    count)`, `.length`, indexing, and `+`/`==` alone — the exact
//!    primitive set verified to have native codegen support (and no more).
//! 5. **`*WithCancel*` accept a `CancellationToken` but never consult it.**
//!    `Std.Task` (which owns `CancellationToken`) has no
//!    `_kernel_native/task.l` twin — a separate, pre-existing gap, not
//!    introduced here — so cooperative cancellation genuinely cannot be
//!    implemented on this target yet. These functions still MUST be
//!    declared with the exact signature `Std.Http`'s `sendWithCancelAsync`/
//!    `getWithCancelAsync`/`postWithCancelAsync`/`bodyTextWithCancel`
//!    call, or `std/http.l` itself fails to TYPE-CHECK on native (a missing
//!    symbol in an unconditionally-referenced call, independent of whether
//!    any USER program ever calls the `*WithCancel*` wrapper) — verified
//!    directly (`import Std.Http` alone, never calling anything, already
//!    compiles clean on native today via the `_kernel/http_host.l`
//!    fallback, confirming native codegen is per-reachability lazy: a
//!    declared-but-uncalled function, however broken its body would be if
//!    reached, never gets lowered). So these are declared, accept the
//!    token for signature parity, and silently do not honour it — clearly
//!    worse than the other two targets, not a silent behavioural claim
//!    (nothing here claims cancellation works).
//!
//! ## The `HttpClient` interface itself does not work on native today (pre-existing, general compiler gap — not fixed here)
//!
//! This is the one item genuinely out of this file's power to complete,
//! discovered by direct compilation, not assumed:
//!
//! ```text
//! $ lyric build --target native repro.l   # `val c = defaultClient()`
//! Unhandled exception. System.Exception: Lyric.LlvmCodegen: type
//! 'HttpClient' is not yet supported for --target native (Phase N1 lowers
//! scalars and String only)
//!   at Lyric.LlvmCodegen.Program.typeExprToNType(TypeExpr)
//!   ...
//! ```
//!
//! and, isolating further with a same-shape single-file interface (proving
//! this is a general async-interface-dispatch gap, not anything
//! `HttpClient`- or bundled-stdlib-specific):
//!
//! ```text
//! interface Greeter { async func greet(): Int }
//! ...
//! async func run(): Int { await makeGreeter().greet() }
//! ```
//! ```text
//! Unhandled exception. System.Exception: Lyric.LlvmCodegen: interface
//! method '.greet' on 'T.Greeter' is not yet lowerable for --target native
//! — only non-generic abstract interface methods dispatch through the
//! vtable; default, generic, async, and Self-returning interface methods
//! are deferred (N3.2).
//! ```
//!
//! `Std.Http.HttpClient` declares SEVEN methods, every one `async func`
//! (`send`/`sendWithCancel`/`get`/`post`/`put`/`delete`/`patch`) — exactly
//! the deferred shape the compiler's own error names. This blocks, on
//! `--target native` only, EVERY `Std.Http` entry point that returns or
//! dispatches through the `HttpClient` interface: `defaultClient()`,
//! `clientWithRedirects`/`clientNoRedirects`/`clientWithUnixSocket*`, and
//! — the headline casualty for this issue — `HttpClientBuilder.build()`,
//! which means `withCaCertificate`/`withExclusiveCaCertificate`/
//! `withClientIdentity`/`withMinTlsVersion`/`withInsecureSkipVerify` have
//! NO reachable call path into this kernel's `hostClientWithTls` through
//! `Std.Http`'s public surface today, on this target only.
//!
//! This is a general, pre-existing `Lyric.LlvmCodegen` limitation (N3.2,
//! already tracked in the compiler's own source comments) affecting ANY
//! async-method interface, not an HTTP-specific gap and not something a
//! `_kernel_native/` file can work around — the fix belongs in
//! `Lyric.LlvmCodegen`'s interface-dispatch lowering, a compiler change far
//! outside this issue's kernel-boundary scope. Per this repository's
//! standard (no stub, no fake pass), this kernel ships the REAL,
//! substantive, working functionality that IS reachable today:
//!
//!   - Every function below (`hostDefaultClient`, `hostClientWithTls` and
//!     the whole TLS-option surface, `hostMakeRequest`/`hostWithHeader`/
//!     `hostWithStringBody`, every `*Safe` send function, every response
//!     accessor) is fully implemented and directly callable — verified end
//!     to end by this file's self-test, `llvm_http_client_self_test.l`,
//!     which drives `Std.HttpHost` DIRECTLY (the same way that test drives
//!     `Std.TcpHost` for N9.2, rather than through the blocked
//!     `Std.Http`/`HttpClient` layer) for a real loopback HTTPS round trip,
//!     including `hostClientWithTls`'s CA-pinning path.
//!   - `Std.Http`'s FREE functions that never touch the `HttpClient`
//!     interface type — `sendAsync`/`getAsync`/`postAsync` (and their
//!     `*WithCancelAsync` siblings, modulo item 5 above) — call
//!     `HostHttp.hostDefaultClient()` directly (a plain record, not the
//!     interface) and so already work end to end through `Std.Http`'s
//!     public surface on native, verified directly.
//!   - The moment N3.2 ships vtable dispatch for async interface methods,
//!     `HttpClientBuilder.build()`/`defaultClient()`/the `HttpClient`
//!     interface start working with ZERO changes needed in this file —
//!     this kernel is not blocked on anything of its own; it is fully
//!     ready and waiting behind a compiler capability it does not own.
//!
//! ## `withCaCertificate`'s ADDITIVE semantics needed a small, genuine seam extension
//!
//! The shipped N9.1 seam's `lyric_tls_client_new` only ever does ONE of
//! "trust the system default store" (empty `ca_pem`) OR "trust ONLY
//! `ca_pem`" (non-empty `ca_pem`) — there was no way to combine both into
//! one `SSL_CTX`, which is exactly what `withCaCertificate`'s documented
//! ADDITIVE contract (docs/61 §3.2: "adds a trust root alongside the
//! platform store") requires. Rather than fake additive semantics as
//! exclusive (silently narrowing trust — a real behavioural regression a
//! caller could not detect), `lyric-rt/src/lyric_tls.c` gained a small,
//! genuinely new, backward-compatible constructor,
//! `lyric_tls_client_new_additive` (loads
//! `SSL_CTX_set_default_verify_paths` UNCONDITIONALLY, then adds the extra
//! CA on top of the same store — a chain valid against either set
//! verifies), factored out of `lyric_tls_client_new`'s existing body via a
//! shared `client_new_impl` helper so `lyric_tls_client_new`'s own,
//! already-shipped, already-tested behaviour is untouched (verified: `make
//! -C lyric-rt test` and `test-asan` both still pass, plus new C-level
//! coverage — `test_tls_client_additive_ca`/`test_tls_client_additive_requires_ca`
//! — for the new function). `Std.TcpHost.hostConnectTls`/
//! `hostUpgradeClientTls` (added alongside this file, same issue) expose it
//! via `TlsClientTrust.TlsTrustAdditive`.
//!
//! ## Redirects are hand-rolled (native has no `HttpClientHandler`/`Redirect` to delegate to)
//!
//! `HttpClientBuilder`'s `withRedirects(n)`/`withNoRedirects()` map onto a
//! real client-side redirect loop here: 301/302/303/307/308 with a
//! `Location` header are followed, up to `maxRedirects` hops. 303 always
//! downgrades to GET (dropping any body); 301/302 downgrade to GET only
//! when the original method was not GET/HEAD (matching the long-standing
//! "legacy user-agent" behaviour most HTTP clients converged on); 307/308
//! always preserve the original method and body (RFC 9110 §15.4.8-9). A
//! relative `Location` is resolved against the CURRENT request's own
//! scheme/host/port (absolute-path form only — no `../`-relative
//! resolution, not needed for any tested case).
@axiom("lyric_sock_*/lyric_tls_* (lyric-rt/src/lyric_tls.c) conform to their documented contracts")
package Std.HttpHost

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Task
import Std.Tls as Tls
import Std.TcpHost as Tcp

// =====================================================================
// Public types.
// =====================================================================
/// A configured client. Plain record (module header item 6's blocker is
/// about `Std.Http`'s `HttpClient` INTERFACE, not this kernel-private
/// handle type, which every `Std.Http` free function already passes
/// around successfully). `maxRedirects` is a hop CAP, meaningful only when
/// `followRedirects` is true.
pub record HttpClientHandle {
  followRedirects: Bool
  maxRedirects: Int
  trust: Tcp.TlsClientTrust
  clientIdentity: Option[Tls.Identity]
  minVersion: Tls.TlsVersion
}

/// Request under construction (module header: no shared client engine, so
/// this file owns request serialization). `timeoutNanos` is accepted for
/// signature parity with the other two kernels' `HttpRequestMessage` but
/// unused on this target (module header item 5's cancellation gap covers
/// deadlines too — there is no `Std.Task` timer primitive to drive one).
pub record HttpRequestMessage {
  method: String
  url: String
  headerNames: List[String]
  headerValues: List[String]
  contentType: String
  body: String
  hasBody: Bool
  timeoutNanos: Long
}

/// Response, fully buffered at send time (matches both other kernels'
/// buffering contract). No `version` field: `hostResponseVersionMajor`
/// always answers `1` (module header item 1), so there is nothing to
/// store per-response.
pub record HttpResponseMessage {
  status: Int
  headerNames: List[String]
  headerValues: List[String]
  bodyBytes: slice[Byte]
}

// =====================================================================
// String/byte scanning primitives (module header item 4).
// =====================================================================
/// The index of the first occurrence of `needle` in `s` at or after
/// `from`, or -1. Built from `.substring`/`.length`/`==` alone — see
/// module header item 4 for why `.indexOf` cannot be used here.
func findSubstring(s: in String, needle: in String, from: in Int): Int {
  val nLen = needle.length
  if nLen == 0 {
    return from
  }
  var i = from
  while i + nLen <= s.length {
    if s.substring(i, nLen) == needle {
      return i
    }
    i = i + 1
  }
  -1
}

/// Split `s` on every occurrence of `sep`, keeping empty parts (matches
/// `Std.String.split`'s documented semantics) — the hand-rolled substitute
/// for `.split`, which has no native codegen (module header item 4).
func splitOn(s: in String, sep: in String): List[String] {
  val result: List[String] = newList()
  var start = 0
  var idx = findSubstring(s, sep, start)
  while idx >= 0 {
    result.add(s.substring(start, idx - start))
    start = idx + sep.length
    idx = findSubstring(s, sep, start)
  }
  result.add(s.substring(start, s.length - start))
  result
}

/// Strip leading/trailing ASCII spaces — the hand-rolled substitute for
/// `.trim` (module header item 4). HTTP header values only ever carry OWS
/// (space/htab) around the value; this handles the overwhelmingly common
/// space case, which is all real servers emit.
func trimSpaces(s: in String): String {
  var start = 0
  var stop = s.length
  while start < stop and s.substring(start, 1) == " " {
    start = start + 1
  }
  while stop > start and s.substring(stop - 1, 1) == " " {
    stop = stop - 1
  }
  s.substring(start, stop - start)
}

func digitOf(c: in String): Option[Int] {
  if c == "0" {
    Some(value = 0)
  } else if c == "1" {
    Some(value = 1)
  } else if c == "2" {
    Some(value = 2)
  } else if c == "3" {
    Some(value = 3)
  } else if c == "4" {
    Some(value = 4)
  } else if c == "5" {
    Some(value = 5)
  } else if c == "6" {
    Some(value = 6)
  } else if c == "7" {
    Some(value = 7)
  } else if c == "8" {
    Some(value = 8)
  } else if c == "9" {
    Some(value = 9)
  } else {
    None
  }
}

/// Parse a non-negative decimal integer (status codes, `Content-Length`,
/// URL ports) — the hand-rolled substitute for `Std.Parse` (no
/// `_kernel_native/parse_host.l` twin exists at all; module header item 4).
func parseNonNegativeInt(s: in String): Option[Int] {
  if s.length == 0 {
    return None
  }
  var n = 0
  var i = 0
  while i < s.length {
    match digitOf(s.substring(i, 1)) {
      case None -> return None
      case Some(d) -> {
        // Reject rather than silently wrap past Int32 (#6636: an
        // attacker-supplied Content-Length/chunk-size digit string long
        // enough to overflow could otherwise wrap to a small or negative
        // value and bypass the size caps this parses into). The guard
        // trips well before the real Int32 boundary (2_147_483_647) —
        // no legitimate status code, port, or Content-Length this client
        // needs to parse is anywhere near it.
        if n > 200000000 {
          return None
        }
        n = n * 10 + d
      }
    }
    i = i + 1
  }
  Some(value = n)
}

func hexDigitOf(c: in String): Option[Int] {
  if c == "0" {
    Some(value = 0)
  } else if c == "1" {
    Some(value = 1)
  } else if c == "2" {
    Some(value = 2)
  } else if c == "3" {
    Some(value = 3)
  } else if c == "4" {
    Some(value = 4)
  } else if c == "5" {
    Some(value = 5)
  } else if c == "6" {
    Some(value = 6)
  } else if c == "7" {
    Some(value = 7)
  } else if c == "8" {
    Some(value = 8)
  } else if c == "9" {
    Some(value = 9)
  } else if c == "a" or c == "A" {
    Some(value = 10)
  } else if c == "b" or c == "B" {
    Some(value = 11)
  } else if c == "c" or c == "C" {
    Some(value = 12)
  } else if c == "d" or c == "D" {
    Some(value = 13)
  } else if c == "e" or c == "E" {
    Some(value = 14)
  } else if c == "f" or c == "F" {
    Some(value = 15)
  } else {
    None
  }
}

/// Parse a chunk-size line's hex digits (chunked transfer-encoding).
func parseHexInt(s: in String): Option[Int] {
  if s.length == 0 {
    return None
  }
  var n = 0
  var i = 0
  while i < s.length {
    match hexDigitOf(s.substring(i, 1)) {
      case None -> return None
      case Some(d) -> {
        // Overflow guard for the same reason as `parseNonNegativeInt`
        // (#6636), but with the correct threshold for BASE 16 (×16 per
        // digit, not ×10) — #6647: the earlier version reused
        // `parseNonNegativeInt`'s base-10 threshold (200000000) here,
        // which does not prevent `n * 16 + d` from overflowing `Int32` on
        // the final fold (e.g. an 8-hex-digit chunk-size line like
        // "8000000F" passes every intermediate check and then wraps to a
        // large NEGATIVE `size`, bypassing `readChunkedBody`'s cumulative
        // `maxResponseBodyBytes` cap entirely and driving `dataStart`/`pos`
        // negative — an out-of-bounds buffer index on the very next read,
        // a remote memory-safety bug, not just a cap bypass). 134217727 is
        // the largest `n` for which `n * 16 + 15` cannot exceed
        // `Int32.MaxValue` (2147483647): `134217727 * 16 + 15 ==
        // 2147483647` exactly.
        if n > 134217727 {
          return None
        }
        n = n * 16 + d
      }
    }
    i = i + 1
  }
  Some(value = n)
}

/// Chunk-size lines may carry `;extension` (RFC 9112 §7.1.1); this engine
/// parses-and-discards extensions, matching `Std.HttpEngine`'s own policy
/// for the same grammar on the server side.
func trimChunkExt(s: in String): String {
  val idx = findSubstring(s, ";", 0)
  val core = if idx < 0 { s } else { s.substring(0, idx) }
  trimSpaces(core)
}

func toLowerAsciiChar(c: in String): String {
  if c == "A" {
    "a"
  } else if c == "B" {
    "b"
  } else if c == "C" {
    "c"
  } else if c == "D" {
    "d"
  } else if c == "E" {
    "e"
  } else if c == "F" {
    "f"
  } else if c == "G" {
    "g"
  } else if c == "H" {
    "h"
  } else if c == "I" {
    "i"
  } else if c == "J" {
    "j"
  } else if c == "K" {
    "k"
  } else if c == "L" {
    "l"
  } else if c == "M" {
    "m"
  } else if c == "N" {
    "n"
  } else if c == "O" {
    "o"
  } else if c == "P" {
    "p"
  } else if c == "Q" {
    "q"
  } else if c == "R" {
    "r"
  } else if c == "S" {
    "s"
  } else if c == "T" {
    "t"
  } else if c == "U" {
    "u"
  } else if c == "V" {
    "v"
  } else if c == "W" {
    "w"
  } else if c == "X" {
    "x"
  } else if c == "Y" {
    "y"
  } else if c == "Z" {
    "z"
  } else {
    c
  }
}

/// ASCII case-insensitive equality — the hand-rolled substitute for
/// `Std.String.equalsCaseInsensitive` (which itself routes through
/// `.toUpper()`/`.toLower()`, both unsupported on native; module header
/// item 4). Used for HTTP header-name matching (`Content-Length` vs
/// `content-length`).
func asciiEqualsCaseInsensitive(a: in String, b: in String): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if toLowerAsciiChar(a.substring(i, 1)) != toLowerAsciiChar(b.substring(i, 1)) {
      return false
    }
    i = i + 1
  }
  true
}

/// Case-insensitive first-match lookup over parallel name/value lists (the
/// shape both `ParsedHeaders` and `HttpResponseMessage` store headers in).
func findHeaderValue(names: in List[String], values: in List[String], name: in String): Option[String] {
  var i = 0
  while i < names.count {
    if asciiEqualsCaseInsensitive(names[i], name) {
      return Some(value = values[i])
    }
    i = i + 1
  }
  None
}

// =====================================================================
// Byte-level buffer scanning (module header item 4: no `.slice()`).
// =====================================================================
/// Response size limits (#6636: a malicious/compromised server this
/// client connects to must not be able to force unbounded client-process
/// memory growth via an oversized or never-terminated header block, a
/// huge declared `Content-Length`, or an unbounded run of chunked-body
/// data). Mirrors `Std.HttpEngine`'s server-side `EngineLimits` defaults
/// (`maxHeaderCount = 100` * `maxHeaderLineLength = 8192` for the header
/// total; `maxBodyBytes = 10485760` for the body) so client and server
/// share the same resource-exhaustion budget, even though this kernel has
/// no `EngineLimits`-shaped config surface of its own to thread through
/// yet (a v1 hardcoded default, not a configurable option).
val maxResponseHeaderBytes: Int = 819200

val maxResponseBodyBytes: Int = 10485760

/// A single chunk-size or trailer line (chunked transfer-encoding) is
/// bounded independently of the overall body cap — reuses
/// `Std.HttpEngine`'s own per-line `maxHeaderLineLength` budget, since a
/// chunk-size/trailer line is grammatically a header-shaped line.
val maxChunkLineBytes: Int = 8192

/// Caps the number of chunked-transfer trailer lines: each line is
/// individually bounded by `maxChunkLineBytes` but discarded rather than
/// accumulated, so an unbounded COUNT of small lines is the residual
/// memory-growth vector `maxChunkLineBytes` alone doesn't close. Mirrors
/// `Std.HttpEngine`'s own `maxHeaderCount` default (100), which its trailer
/// path reuses for the identical reason.
val maxTrailerLines: Int = 100

/// Caps the number of `1xx` interim responses `readResponse` will discard
/// while waiting for the real final response (#6704). Each interim
/// response's own header block is bounded by `maxResponseHeaderBytes`, but
/// nothing capped how many of them a server could send in a row — a
/// malicious/compromised peer could stream an endless run of minimal `100
/// Continue` responses to grow `buf` without bound, the exact "byte cap
/// doesn't bound an unbounded COUNT of messages" gap `maxTrailerLines`
/// closes on the chunked-trailer path, left open here. Real interim
/// responses (100 Continue, 103 Early Hints) are sent at most once or
/// twice per request in practice; this leaves generous headroom while
/// still bounding worst-case memory to `maxInterimResponses *
/// maxResponseHeaderBytes` instead of unbounded.
val maxInterimResponses: Int = 20

func crlfBytes(): slice[Byte] {
  [13u8, 10u8]
}

func crlfcrlfBytes(): slice[Byte] {
  [13u8, 10u8, 13u8, 10u8]
}

func bytesEqualAt(buf: in List[Byte], pos: in Int, pattern: in slice[Byte]): Bool {
  var j = 0
  while j < pattern.length {
    if buf[pos + j] != pattern[j] {
      return false
    }
    j = j + 1
  }
  true
}

/// The index of the first occurrence of `pattern` in `buf` at or after
/// `from`, or -1.
func findPattern(buf: in List[Byte], from: in Int, pattern: in slice[Byte]): Int {
  val n = pattern.length
  var i = from
  while i + n <= buf.count {
    if bytesEqualAt(buf, i, pattern) {
      return i
    }
    i = i + 1
  }
  -1
}

/// Copy `count` bytes starting at `start` out of `buf` into a fresh
/// `slice[Byte]` — the hand-rolled substitute for `.slice()` (module
/// header item 4).
func copyRange(buf: in List[Byte], start: in Int, count: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < count {
    acc.add(buf[start + i])
    i = i + 1
  }
  acc.toArray()
}

/// Append every byte read from `conn` to `buf` until `pattern` is found at
/// or after `from`, or the connection closes first (`Err`). Returns the
/// index where `pattern` starts. Rescans only from just before the
/// previous read's end (`pattern.length - 1` bytes of backtrack) rather
/// than from 0 every time, since a match cannot start any earlier than
/// that in newly-arrived bytes. Fails with `Err` once more than
/// `maxBytes` bytes have accumulated since `from` without finding
/// `pattern` (#6636: bounds a header block, or a single chunk-size/
/// trailer line, that never terminates).
func readUntilPatternFrom(
  conn: in Tcp.Conn, buf: in List[Byte], from: in Int, pattern: in slice[Byte], maxBytes: in Int
): Result[Int, String] {
  var searchFrom = from
  var found = findPattern(buf, searchFrom, pattern)
  while found < 0 {
    if buf.count - from > maxBytes {
      return Err(error = "response exceeds the maximum allowed size while searching for expected data")
    }
    val priorCount = buf.count
    match Tcp.hostRead(conn, 8192) {
      case Err(e) -> return Err(error = Tcp.TcpError.message(e))
      case Ok(chunk) -> {
        if chunk.length == 0 {
          return Err(error = "connection closed before expected data arrived")
        }
        var i = 0
        while i < chunk.length {
          buf.add(chunk[i])
          i = i + 1
        }
      }
    }
    val backtrack = pattern.length - 1
    val candidate = priorCount - backtrack
    searchFrom = if candidate > from { candidate } else { from }
    found = findPattern(buf, searchFrom, pattern)
  }
  Ok(value = found)
}

/// Read from `conn` into `buf` until it holds at least `total` bytes.
func readAtLeast(conn: in Tcp.Conn, buf: in List[Byte], total: in Int): Result[Unit, String] {
  while buf.count < total {
    match Tcp.hostRead(conn, 8192) {
      case Err(e) -> return Err(error = Tcp.TcpError.message(e))
      case Ok(chunk) -> {
        if chunk.length == 0 {
          return Err(error = "connection closed before response body was fully received")
        }
        var i = 0
        while i < chunk.length {
          buf.add(chunk[i])
          i = i + 1
        }
      }
    }
  }
  Ok(value = ())
}

/// Read from `conn` into `buf` until the peer closes (EOF) — the
/// close-delimited body framing for a response with neither
/// `Content-Length` nor `Transfer-Encoding: chunked` (RFC 9112 §6.3).
/// Fails with `Err` once the body (from `bodyStart` on) exceeds
/// `maxResponseBodyBytes` rather than reading an unbounded close-delimited
/// stream to completion (#6636).
func readUntilEof(conn: in Tcp.Conn, buf: in List[Byte], bodyStart: in Int): Result[Unit, String] {
  var reading = true
  while reading {
    if buf.count - bodyStart > maxResponseBodyBytes {
      return Err(error = "response body exceeds the maximum allowed size")
    }
    match Tcp.hostRead(conn, 8192) {
      case Err(e) -> return Err(error = Tcp.TcpError.message(e))
      case Ok(chunk) -> {
        if chunk.length == 0 {
          reading = false
        } else {
          var i = 0
          while i < chunk.length {
            buf.add(chunk[i])
            i = i + 1
          }
        }
      }
    }
  }
  Ok(value = ())
}

func decodeRange(buf: in List[Byte], start: in Int, count: in Int): Option[String] {
  tryDecodeUtf8(copyRange(buf, start, count))
}

/// Decode and dechunk a `Transfer-Encoding: chunked` body (RFC 9112 §7.1)
/// starting at `startPos` in `buf`. Trailers are read and discarded (parsed
/// only far enough to find the terminating blank line), matching
/// `Std.HttpEngine`'s own "parse trailers, discard them" policy on the
/// server side.
func readChunkedBody(conn: in Tcp.Conn, buf: in List[Byte], startPos: in Int): Result[slice[Byte], String] {
  val acc: List[Byte] = newList()
  var pos = startPos
  var done = false
  while not done {
    // #6693: `readUntilPatternFrom`'s `maxChunkLineBytes` cap bounds only a
    // SINGLE chunk-size/trailer line, and the `acc`-based check above bounds
    // only the DECODED body — neither bounds the raw wire bytes `buf` grows
    // by every iteration. RFC 9112 section 7.1.1 chunk extensions let a
    // malicious server pad each chunk-size line with up to ~8180 bytes of
    // junk after the hex size, so a chunk declaring size 1 can still grow
    // `buf` by ~8195 bytes while growing `acc` by only 1 byte — the `acc`
    // cap wouldn't trip until `buf` (accumulated raw bytes since `startPos`)
    // reached tens of gigabytes. Bound the raw buffer directly, independent
    // of how the attacker splits bytes between padding and real chunk data.
    if buf.count - startPos > maxResponseBodyBytes {
      return Err(error = "chunked response exceeds the maximum allowed raw size")
    }
    val lineEnd = match readUntilPatternFrom(conn, buf, pos, crlfBytes(), maxChunkLineBytes) {
      case Ok(idx) -> idx
      case Err(e) -> return Err(error = e)
    }
    val sizeLine = match decodeRange(buf, pos, lineEnd - pos) {
      case Some(t) -> t
      case None -> return Err(error = "malformed chunk-size line (not valid UTF-8)")
    }
    val size = match parseHexInt(trimChunkExt(sizeLine)) {
      case Some(n) -> n
      case None -> return Err(error = "malformed chunk size: " + sizeLine)
    }
    // NOT `acc.count + size > maxResponseBodyBytes` (#6656): `size` can be
    // as large as `Int32.MaxValue` (parseHexInt's own #6647 overflow guard
    // only bounds a SINGLE chunk-size line's value, not the running sum),
    // and once a prior chunk has left `acc.count > 0`, adding it to a
    // near-`Int32.MaxValue` `size` overflows `Int32` and wraps NEGATIVE —
    // silently passing this check and letting `size` (and the `dataEnd =
    // dataStart + size` computed from it, below) drive `pos` negative,
    // an out-of-bounds buffer index on the next read. Comparing via
    // subtraction instead never overflows: `acc.count` is always in
    // `[0, maxResponseBodyBytes]` here (this check runs before every
    // addition to `acc`, so it can never have grown past the cap already),
    // so `maxResponseBodyBytes - acc.count` is always a small non-negative
    // number, and `size < 0` cannot pass a `>` comparison against it either
    // way (defense in depth against a hypothetical future regression in
    // `parseHexInt`'s own guard, not reachable today).
    if size < 0 or size > maxResponseBodyBytes - acc.count {
      return Err(error = "chunked response body exceeds the maximum allowed size")
    }
    val dataStart = lineEnd + 2
    if size == 0 {
      // Zero-size chunk: what follows is the trailer section (RFC 9112
      // §7.1.2), zero or more CRLF-terminated field lines, ending at a
      // blank line — the SAME shape header parsing uses, NOT a single
      // CRLFCRLF search: the last-chunk's own terminating CRLF (already
      // consumed into `dataStart` above) is not itself half of that blank
      // line, so the zero-trailers case is exactly ONE more CRLF, not two
      // in a row. Read (and discard) every trailer line up through the
      // blank line that ends the section.
      var trailerPos = dataStart
      var trailerDone = false
      var trailerCount = 0
      while not trailerDone {
        if trailerCount > maxTrailerLines {
          return Err(error = "chunked response trailer section exceeds the maximum allowed number of lines")
        }
        val trailerLineEnd = match readUntilPatternFrom(conn, buf, trailerPos, crlfBytes(), maxChunkLineBytes) {
          case Ok(idx) -> idx
          case Err(e) -> return Err(error = e)
        }
        if trailerLineEnd == trailerPos {
          trailerDone = true
        } else {
          trailerPos = trailerLineEnd + 2
          trailerCount = trailerCount + 1
        }
      }
      done = true
    } else {
      val dataEnd = dataStart + size
      match readAtLeast(conn, buf, dataEnd + 2) {
        case Ok(_) -> {
        }
        case Err(e) -> return Err(error = e)
      }
      var i = dataStart
      while i < dataEnd {
        acc.add(buf[i])
        i = i + 1
      }
      pos = dataEnd + 2
    }
  }
  Ok(value = acc.toArray())
}

// =====================================================================
// URL parsing (no platform `Uri` type on this target).
// =====================================================================
record ParsedUrl {
  isHttps: Bool
  host: String
  port: Int
  target: String
}

/// Parse an already-`Url.tryFrom`-validated `http(s)://` URL into its
/// scheme/host/port/target parts. Userinfo (`user:pass@host`) and IPv6
/// literal hosts (`[::1]`) are not handled — out of scope for this first
/// slice (neither is exercised by any tested case); every other URL shape
/// `Url.tryFrom` accepts parses correctly.
func parseUrl(url: in String): Result[ParsedUrl, String] {
  val isHttps = url.length >= 8 and url.substring(0, 8) == "https://"
  val isHttp = not isHttps and url.length >= 7 and url.substring(0, 7) == "http://"
  if not isHttps and not isHttp {
    return Err(error = "unsupported URL scheme (expected http:// or https://): " + url)
  }
  val schemeLen = if isHttps { 8 } else { 7 }
  val defaultPort = if isHttps { 443 } else { 80 }
  val rest = url.substring(schemeLen, url.length - schemeLen)
  val slashIdx = findSubstring(rest, "/", 0)
  val authority = if slashIdx < 0 { rest } else { rest.substring(0, slashIdx) }
  val target = if slashIdx < 0 { "/" } else { rest.substring(slashIdx, rest.length - slashIdx) }
  if authority.length == 0 {
    return Err(error = "URL has no host: " + url)
  }
  val colonIdx = findSubstring(authority, ":", 0)
  if colonIdx < 0 {
    return Ok(value = ParsedUrl(isHttps = isHttps, host = authority, port = defaultPort, target = target))
  }
  val host = authority.substring(0, colonIdx)
  val portStr = authority.substring(colonIdx + 1, authority.length - colonIdx - 1)
  match parseNonNegativeInt(portStr) {
    case None -> Err(error = "invalid port in URL: " + url)
    case Some(p) -> Ok(value = ParsedUrl(isHttps = isHttps, host = host, port = p, target = target))
  }
}

func hostHeaderValue(parsed: in ParsedUrl): String {
  val isDefaultPort = (parsed.isHttps and parsed.port == 443) or (not parsed.isHttps and parsed.port == 80)
  if isDefaultPort {
    parsed.host
  } else {
    parsed.host + ":" + parsed.port.toString()
  }
}

// =====================================================================
// Client construction.
// =====================================================================
/// Whether this target's kernel can honour `HttpClientBuilder`'s TLS
/// options. `true`: `hostClientWithTls` below is fully implemented — see
/// the module header for why `Std.Http.HttpClientBuilder.build()` itself
/// cannot reach it on native today regardless (the `HttpClient` interface
/// gap), which is a DIFFERENT, unrelated question from whether this
/// kernel's own TLS wiring works (it does).
pub func hostSupportsTlsConfig(): Bool {
  true
}

func defaultClientHandle(trust: in Tcp.TlsClientTrust): HttpClientHandle {
  HttpClientHandle(
    followRedirects = true,
    maxRedirects = 20,
    trust = trust,
    clientIdentity = None,
    minVersion = Tls.TlsVersion.Tls12
  )
}

pub func hostDefaultClient(): HttpClientHandle {
  defaultClientHandle(TlsTrustSystemDefault)
}

pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle {
  HttpClientHandle(
    followRedirects = maxRedirects > 0,
    maxRedirects = maxRedirects,
    trust = TlsTrustSystemDefault,
    clientIdentity = None,
    minVersion = Tls.TlsVersion.Tls12
  )
}

pub func hostClientNoRedirects(): HttpClientHandle {
  HttpClientHandle(
    followRedirects = false,
    maxRedirects = 0,
    trust = TlsTrustSystemDefault,
    clientIdentity = None,
    minVersion = Tls.TlsVersion.Tls12
  )
}

// ---------------------------------------------------------------------------
// HTTP/1.1 exact-pin variants: identical to their non-`Http11` siblings
// (module header item 1 — this target never speaks anything else).
// ---------------------------------------------------------------------------
pub func hostClientHttp11(): HttpClientHandle {
  hostDefaultClient()
}

pub func hostClientWithRedirectsHttp11(maxRedirects: in Int): HttpClientHandle {
  hostClientWithRedirects(maxRedirects)
}

pub func hostClientNoRedirectsHttp11(): HttpClientHandle {
  hostClientNoRedirects()
}

// ---------------------------------------------------------------------------
// Unix domain socket support: not available on this target yet (module
// header item 3) — the N9.1 `lyric_sock_*` seam has no Unix-socket
// transport. Fails loudly rather than silently dialing TCP, matching the
// JVM kernel's own unconditional-panic shape for its own, unrelated reason.
// ---------------------------------------------------------------------------
func unixSocketUnsupported(): HttpClientHandle {
  panic(
    "Std.Http: Unix domain socket clients are not supported on --target native yet " +
      "(the lyric_sock_*/lyric_tls_* seam has no Unix-socket transport; N9.4/#6105)"
  )
}

pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketHttp11(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketAndRedirectsHttp11(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketNoRedirectsHttp11(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

// ---------------------------------------------------------------------------
// TLS client configuration (docs/61 §3.2; module header's "additive CA"
// section). Mirrors `_kernel/http_host.l`'s `hostClientWithTls` signature
// exactly — `Std.Http` calls whichever kernel's copy the active `--target`
// resolves to.
// ---------------------------------------------------------------------------
/// Resolve the CA precedence rule (docs/61 §3.2 / #5975: exclusive always
/// wins over additive when both are configured) into one fully-decided
/// `TlsClientTrust` the seam executes. `insecureSkipVerify` wins over both
/// (the docs/61 §4 dual-key policy — already resolved to a plain `Bool` by
/// the time `Std.Http.HttpClientBuilder.build()` calls this function).
func resolveTrust(
  caCertificate: in Option[Tls.Certificate],
  exclusiveCaCertificate: in Option[Tls.Certificate],
  insecureSkipVerify: in Bool,
): Tcp.TlsClientTrust {
  if insecureSkipVerify {
    TlsTrustInsecure
  } else {
    match exclusiveCaCertificate {
      // Explicit static-call form (`Tls.Certificate.rawHandle(cert)`), not
      // UFCS (`cert.rawHandle()`) — see `_kernel_native/tcp_host.l`'s
      // `buildServerCtx` for the direct-repro writeup of why the UFCS
      // spelling does not resolve an `internal` cross-package function in
      // native's bundled import closure.
      case Some(cert) -> TlsTrustExclusive(caPem = Tls.Certificate.rawHandle(cert).certPem)
      case None -> match caCertificate { case Some(cert2) -> TlsTrustAdditive(caPem = Tls.Certificate.rawHandle(cert2).certPem); case None -> TlsTrustSystemDefault }
    }
  }
}

/// `pinHttp11` is accepted for signature parity with the other kernels but
/// has no effect (module header item 1).
pub func hostClientWithTls(
  maxRedirects: in Option[Int],
  noRedirects: in Bool,
  pinHttp11: in Bool,
  caCertificate: in Option[Tls.Certificate],
  exclusiveCaCertificate: in Option[Tls.Certificate],
  clientIdentity: in Option[Tls.Identity],
  minTlsVersion: in Option[Tls.TlsVersion],
  insecureSkipVerify: in Bool,
): HttpClientHandle {
  val trust = resolveTrust(caCertificate, exclusiveCaCertificate, insecureSkipVerify)
  val minVersion = match minTlsVersion { case Some(v) -> v; case None -> Tls.TlsVersion.Tls12 }
  val followRedirects = if noRedirects {
    false
  } else {
    match maxRedirects {
      case Some(n) -> n > 0
      case None -> true
    }
  }
  val maxRedirectsResolved = match maxRedirects { case Some(n) -> n; case None -> 20 }
  HttpClientHandle(
    followRedirects = followRedirects,
    maxRedirects = maxRedirectsResolved,
    trust = trust,
    clientIdentity = clientIdentity,
    minVersion = minVersion
  )
}

// =====================================================================
// Request construction.
// =====================================================================
pub func hostMakeRequest(httpMethod: in String, url: in String): HttpRequestMessage {
  val names: List[String] = newList()
  val values: List[String] = newList()
  HttpRequestMessage(
    method = httpMethod,
    url = url,
    headerNames = names,
    headerValues = values,
    contentType = "",
    body = "",
    hasBody = false,
    timeoutNanos = 0i64
  )
}

pub func hostWithHeader(request: in HttpRequestMessage, key: in String, value: in String): HttpRequestMessage {
  request.headerNames.add(key)
  request.headerValues.add(value)
  request
}

pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage {
  HttpRequestMessage(
    method = request.method,
    url = request.url,
    headerNames = request.headerNames,
    headerValues = request.headerValues,
    contentType = contentType,
    body = body,
    hasBody = true,
    timeoutNanos = request.timeoutNanos
  )
}

// =====================================================================
// Send path (internal).
// =====================================================================
/// `true` if `s` contains an embedded CR or LF — the guard against HTTP
/// request splitting/smuggling (#6635) via a value spliced verbatim into
/// the request text below by plain `+` concatenation. The dotnet/JVM
/// kernels this file mirrors get this rejection for free from their
/// platform HTTP stack (`SocketsHttpHandler`/`java.net.http.HttpClient`
/// both reject an embedded CR/LF in a header value, method, or target at
/// send time); this hand-rolled wire protocol has no platform stack to
/// inherit it from, so `buildRequestBytes` checks explicitly before
/// writing anything to the wire.
func hasForbiddenWireChar(s: in String): Bool {
  findSubstring(s, "\r", 0) >= 0 or findSubstring(s, "\n", 0) >= 0
}

/// Validate every caller-controlled value `buildRequestBytes` splices into
/// the request text (method, target, host, header names/values, and
/// `Content-Type` when a body is present) for an embedded CR/LF before any
/// of it reaches the socket (#6635).
func validateRequestForWire(request: in HttpRequestMessage, parsed: in ParsedUrl): Result[Unit, String] {
  var err = ""
  if hasForbiddenWireChar(request.method) {
    err = "invalid request method: contains CR or LF"
  } else if hasForbiddenWireChar(parsed.target) {
    err = "invalid request target: contains CR or LF"
  } else if hasForbiddenWireChar(parsed.host) {
    err = "invalid request host: contains CR or LF"
  } else if request.hasBody and hasForbiddenWireChar(request.contentType) {
    err = "invalid Content-Type: contains CR or LF"
  } else {
    var i = 0
    while i < request.headerNames.count and err == "" {
      if hasForbiddenWireChar(request.headerNames[i]) {
        err = "invalid header name: contains CR or LF"
      } else if hasForbiddenWireChar(request.headerValues[i]) {
        err = "invalid header value: contains CR or LF"
      }
      i = i + 1
    }
  }
  if err == "" {
    Ok(value = ())
  } else {
    Err(error = err)
  }
}

/// `buildRequestBytes`'s return value: NOT `Result[slice[Byte], String]` —
/// a genuine, narrowly-isolated native-codegen bug (found while writing
/// this fix, #6637). Changing `buildRequestBytes`'s signature from
/// returning `slice[Byte]` directly to `Result[slice[Byte], String]`
/// (with its one call site in `doSendOnce` reading it via a `match` whose
/// `Err` arm runs `Tcp.hostClose(conn)` before `return Err(...)`) corrupts
/// the heap in a way that only surfaces later, as a SEGV inside
/// `lyric_release` on an unrelated `String` release deep inside a LATER,
/// otherwise-unrelated `parseUrl` call. Confirmed by bisection down to
/// exactly this one signature change (reverting only the `Result`-wrapping
/// — even leaving `validateRequestForWire` itself defined-but-uncalled —
/// makes the crash disappear). This is NOT a blanket "`Result[slice[Byte],
/// E]` is broken" bug: `readChunkedBody` below has that exact return type
/// and works correctly, so whatever triggers this is specific to this
/// particular call site/shape, not the type alone — see #6637 for the
/// open question of the precise minimal trigger. This record sidesteps it
/// by using a plain record instead, mirroring the same "wrap the
/// problematic shape in a plain record" idiom module header item 4
/// already documents for `slice[Byte]`'s missing `.slice()`/`.concat()`.
record BuiltRequestBytes {
  ok: Bool
  bytes: slice[Byte]
  errorMessage: String
}

/// Serialize `request` into wire bytes against the already-parsed target
/// URL. Builds the head as one `String` (`+`-concatenated — cheap and
/// simple; header counts are small) and encodes it once via `encodeUtf8`,
/// then appends the (already-UTF-8) body bytes one at a time — `+`
/// concatenation only ever applies to the text head, never to raw bytes,
/// so a binary body is never subjected to UTF-8 (re-)encoding here (module
/// header item 4: no `slice[Byte].concat`).
func buildRequestBytes(request: in HttpRequestMessage, parsed: in ParsedUrl): BuiltRequestBytes {
  match validateRequestForWire(request, parsed) {
    case Err(e) -> return BuiltRequestBytes(ok = false, bytes = [], errorMessage = e)
    case Ok(_) -> {
    }
  }
  var text = request.method + " " + parsed.target + " HTTP/1.1\r\n"
  text = text + "Host: " + hostHeaderValue(parsed) + "\r\n"
  text = text + "Connection: close\r\n"
  var i = 0
  while i < request.headerNames.count {
    text = text + request.headerNames[i] + ": " + request.headerValues[i] + "\r\n"
    i = i + 1
  }
  var bodyBytes: slice[Byte] = []
  if request.hasBody {
    bodyBytes = encodeUtf8(request.body)
    text = text + "Content-Type: " + request.contentType + "\r\n"
    text = text + "Content-Length: " + bodyBytes.length.toString() + "\r\n"
  }
  text = text + "\r\n"
  val headBytes = encodeUtf8(text)
  val acc: List[Byte] = newList()
  var hi = 0
  while hi < headBytes.length {
    acc.add(headBytes[hi])
    hi = hi + 1
  }
  var bi = 0
  while bi < bodyBytes.length {
    acc.add(bodyBytes[bi])
    bi = bi + 1
  }
  BuiltRequestBytes(ok = true, bytes = acc.toArray(), errorMessage = "")
}

func connectForUrl(client: in HttpClientHandle, parsed: in ParsedUrl): Result[Tcp.Conn, String] {
  if parsed.isHttps {
    match Tcp.hostConnectTls(parsed.host, parsed.port, client.trust, client.clientIdentity, client.minVersion, "http/1.1") {
      case Err(e) -> Err(error = Tcp.TcpError.message(e))
      case Ok(conn) -> Ok(value = conn)
    }
  } else {
    match Tcp.hostConnect(parsed.host, parsed.port) {
      case Err(e) -> Err(error = Tcp.TcpError.message(e))
      case Ok(conn) -> Ok(value = conn)
    }
  }
}

record ParsedHeaders {
  status: Int
  names: List[String]
  values: List[String]
}

func parseStatusLine(line: in String): Result[Int, String] {
  val sp1 = findSubstring(line, " ", 0)
  if sp1 < 0 {
    return Err(error = "malformed status line: " + line)
  }
  val rest = line.substring(sp1 + 1, line.length - sp1 - 1)
  val sp2 = findSubstring(rest, " ", 0)
  val codeStr = if sp2 < 0 { rest } else { rest.substring(0, sp2) }
  match parseNonNegativeInt(codeStr) {
    case None -> Err(error = "malformed status code: " + line)
    case Some(code) -> Ok(value = code)
  }
}

func parseHeadersText(text: in String): Result[ParsedHeaders, String] {
  val lines = splitOn(text, "\r\n")
  if lines.count == 0 {
    return Err(error = "empty response headers")
  }
  val status = match parseStatusLine(lines[0]) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  val names: List[String] = newList()
  val values: List[String] = newList()
  var i = 1
  while i < lines.count {
    val line = lines[i]
    if line.length > 0 {
      val colonIdx = findSubstring(line, ":", 0)
      if colonIdx >= 0 {
        val name = line.substring(0, colonIdx)
        val rawValue = line.substring(colonIdx + 1, line.length - colonIdx - 1)
        names.add(name)
        values.add(trimSpaces(rawValue))
      }
    }
    i = i + 1
  }
  Ok(value = ParsedHeaders(status = status, names = names, values = values))
}

/// RFC 9112 section 6.3 rule 1: a response to a `HEAD` request, and any
/// `1xx` (informational)/`204`/`304` response, is always terminated by the
/// header block's blank line regardless of `Content-Length`/
/// `Transfer-Encoding` — such a response's `Content-Length` (if present)
/// describes the body the equivalent `GET` would have had and MUST NOT be
/// read from the wire.
func isBodylessResponse(method: in String, status: in Int): Bool {
  asciiEqualsCaseInsensitive(method, "HEAD") or status < 200 or status == 204 or status == 304
}

/// Decide and read the response body per RFC 9112 §6.3's precedence
/// (`Transfer-Encoding: chunked` first, then `Content-Length`, then
/// close-delimited) — the client-side counterpart of
/// `Std.HttpEngine.analyzeFraming`'s server-side framing decision. Callers
/// must check `isBodylessResponse` first (#6692): this function always
/// tries to read a body per the framing headers.
func readBody(
  conn: in Tcp.Conn, buf: in List[Byte], bodyStart: in Int, headers: in ParsedHeaders
): Result[slice[Byte], String] {
  match findHeaderValue(headers.names, headers.values, "Transfer-Encoding") {
    case Some(te) -> {
      if asciiEqualsCaseInsensitive(trimSpaces(te), "chunked") {
        readChunkedBody(conn, buf, bodyStart)
      } else {
        Err(error = "unsupported Transfer-Encoding: " + te)
      }
    }
    case None -> match findHeaderValue(headers.names, headers.values, "Content-Length") { case Some(clStr) -> match parseNonNegativeInt(trimSpaces(clStr)) { case None -> Err(error = "invalid Content-Length: " + clStr); case Some(len) -> { if len > maxResponseBodyBytes { Err(error = "response Content-Length exceeds the maximum allowed size") } else { val total = bodyStart + len; match readAtLeast(conn, buf, total) { case Ok(_) -> Ok(value = copyRange(buf, bodyStart, len)); case Err(e) -> Err(error = e) } } } }; case None -> match readUntilEof(conn, buf, bodyStart) { case Ok(_) -> Ok(value = copyRange(buf, bodyStart, buf.count - bodyStart)); case Err(e) -> Err(error = e) } }
  }
}

/// Reads one final (non-`1xx`) response, discarding any interim `1xx`
/// responses along the way (RFC 9112 section 6.3 rule 1 / RFC 9110 section
/// 15.2: an interim response is always bodyless and must be followed by
/// re-reading a response). `searchFrom` re-uses `buf` across iterations
/// rather than restarting it, since bytes already read for a discarded
/// interim response's header block may already include the start of the
/// next response. `interimCount` bounds how many such responses are
/// discarded before giving up (#6704): each one's header block is
/// individually bounded by `maxResponseHeaderBytes`, but nothing else
/// bounded how many a server could stream in a row.
func readResponse(conn: in Tcp.Conn, method: in String): Result[HttpResponseMessage, String] {
  val buf: List[Byte] = newList()
  var searchFrom = 0
  var interimCount = 0
  while true {
    if interimCount >= maxInterimResponses {
      return Err(error = "response exceeds the maximum allowed number of interim (1xx) responses")
    }
    val headerEndIdx = match readUntilPatternFrom(conn, buf, searchFrom, crlfcrlfBytes(), maxResponseHeaderBytes) {
      case Ok(idx) -> idx
      case Err(e) -> return Err(error = e)
    }
    val headerText = match decodeRange(buf, searchFrom, headerEndIdx - searchFrom) {
      case Some(t) -> t
      case None -> return Err(error = "response headers are not valid UTF-8")
    }
    val headers = match parseHeadersText(headerText) { case Ok(h) -> h; case Err(e) -> return Err(error = e) }
    val bodyStart = headerEndIdx + 4
    if headers.status < 100 or headers.status >= 200 {
      val bodyBytes: slice[Byte] = if isBodylessResponse(method, headers.status) {
        []
      } else {
        match readBody(conn, buf, bodyStart, headers) {
          case Ok(b) -> b
          case Err(e) -> return Err(error = e)
        }
      }
      return Ok(
        value = HttpResponseMessage(
          status = headers.status,
          headerNames = headers.names,
          headerValues = headers.values,
          bodyBytes = bodyBytes
        )
      )
    }
    interimCount = interimCount + 1
    searchFrom = bodyStart
  }
}

func doSendOnce(client: in HttpClientHandle, request: in HttpRequestMessage): Result[HttpResponseMessage, String] {
  val parsed = match parseUrl(request.url) { case Ok(p) -> p; case Err(e) -> return Err(error = e) }
  val conn = match connectForUrl(client, parsed) { case Ok(c) -> c; case Err(e) -> return Err(error = e) }
  val built = buildRequestBytes(request, parsed)
  if not built.ok {
    Tcp.hostClose(conn)
    return Err(error = built.errorMessage)
  }
  val bytes = built.bytes
  match Tcp.hostWrite(conn, bytes) {
    case Err(e) -> {
      Tcp.hostClose(conn)
      return Err(error = Tcp.TcpError.message(e))
    }
    case Ok(_) -> {
    }
  }
  val result = readResponse(conn, request.method)
  Tcp.hostClose(conn)
  result
}

func locationOf(response: in HttpResponseMessage): Option[String] {
  findHeaderValue(response.headerNames, response.headerValues, "Location")
}

func isRedirectStatus(status: in Int): Bool {
  status == 301 or status == 302 or status == 303 or status == 307 or status == 308
}

/// Resolve a `Location` header value against the request it was received
/// for. Absolute (`http://`/`https://`) locations pass through unchanged;
/// anything else is treated as an absolute-path on the SAME scheme/host/
/// port (module header: no `../`-relative resolution).
func resolveRedirectUrl(base: in ParsedUrl, location: in String): String {
  val isAbsolute = (location.length >= 7 and location.substring(0, 7) == "http://") or
    (location.length >= 8 and location.substring(0, 8) == "https://")
  if isAbsolute {
    location
  } else {
    val scheme = if base.isHttps { "https://" } else { "http://" }
    val isDefaultPort = (base.isHttps and base.port == 443) or (not base.isHttps and base.port == 80)
    val portPart = if isDefaultPort { "" } else { ":" + base.port.toString() }
    val path = if location.length > 0 and location.substring(0, 1) == "/" { location } else { "/" + location }
    scheme + base.host + portPart + path
  }
}

/// Two parallel header-name/value lists, returned together so a filter can
/// hand back both sides of the pair in one value (Lyric has no tuple sugar
/// for this shape).
record FilteredHeaders {
  names: List[String]
  values: List[String]
}

/// `true` when a redirect from `from` to `to` stays on the same host/port
/// without downgrading scheme from https to http — the same "same
/// authority" test .NET's `SocketsHttpHandler` and the JDK's
/// `java.net.http.HttpClient` (JDK-8217264) use to decide whether to keep
/// carrying credential-bearing headers across a redirect.
func isSameRedirectAuthority(from: in ParsedUrl, to: in ParsedUrl): Bool {
  from.host == to.host and from.port == to.port and (not from.isHttps or to.isHttps)
}

/// Drop headers that leak credentials if forwarded to a different origin:
/// `Authorization`/`Proxy-Authorization` (bearer/basic credentials) and
/// `Cookie` (session credentials a caller set manually via
/// `hostWithHeader` — this kernel has no automatic cookie jar). Every other
/// header (including a custom auth scheme's own header name) passes
/// through unchanged, matching this file's "no header allowlisting beyond
/// what's needed for the leak this fixes" scope.
func stripSensitiveRedirectHeaders(names: in List[String], values: in List[String]): FilteredHeaders {
  val outNames: List[String] = newList()
  val outValues: List[String] = newList()
  var i = 0
  while i < names.count {
    val n = names[i]
    if not asciiEqualsCaseInsensitive(n, "Authorization") and not asciiEqualsCaseInsensitive(n, "Proxy-Authorization") and not asciiEqualsCaseInsensitive(n, "Cookie") {
      outNames.add(n)
      outValues.add(values[i])
    }
    i = i + 1
  }
  FilteredHeaders(names = outNames, values = outValues)
}

/// 303 always downgrades to a bodyless GET; 301/302 downgrade to GET only
/// when the original method wasn't GET/HEAD (the long-standing "legacy
/// user-agent" convention most HTTP clients converged on); 307/308 always
/// preserve method and body (RFC 9110 §15.4.8-9). A redirect that changes
/// host/port or downgrades https to http strips credential-bearing headers
/// (see `stripSensitiveRedirectHeaders`) — a URL that fails to (re-)parse
/// here is treated as cross-origin (strip), never as same-origin.
func nextRequestForRedirect(request: in HttpRequestMessage, status: in Int, newUrl: in String): HttpRequestMessage {
  val downgradeToGet = status == 303 or
    ((status == 301 or status == 302) and request.method != "GET" and request.method != "HEAD")
  if downgradeToGet {
    hostMakeRequest("GET", newUrl)
  } else {
    val sameAuthority = match parseUrl(request.url) {
      case Err(_) -> false
      case Ok(fromParsed) -> match parseUrl(newUrl) { case Err(_) -> false; case Ok(toParsed) -> isSameRedirectAuthority(fromParsed, toParsed) }
    }
    val filtered = if sameAuthority {
      FilteredHeaders(names = request.headerNames, values = request.headerValues)
    } else {
      stripSensitiveRedirectHeaders(request.headerNames, request.headerValues)
    }
    HttpRequestMessage(
      method = request.method,
      url = newUrl,
      headerNames = filtered.names,
      headerValues = filtered.values,
      contentType = request.contentType,
      body = request.body,
      hasBody = request.hasBody,
      timeoutNanos = request.timeoutNanos
    )
  }
}

/// Send `request`, following redirects per `client`'s configuration
/// (module header: hand-rolled, since native has no
/// `HttpClientHandler`/`Redirect` to delegate to).
func doSend(client: in HttpClientHandle, request: in HttpRequestMessage): Result[HttpResponseMessage, String] {
  var current = request
  var attempts = 0
  var result = doSendOnce(client, current)
  var redirecting = true
  while redirecting and client.followRedirects and attempts < client.maxRedirects {
    match result {
      case Err(_) -> {
        redirecting = false
      }
      case Ok(response) -> {
        if isRedirectStatus(response.status) {
          match locationOf(response) {
            case None -> {
              redirecting = false
            }
            case Some(loc) -> match parseUrl(current.url) { case Err(_) -> { redirecting = false }; case Ok(parsedCurrent) -> { val newUrl = resolveRedirectUrl(parsedCurrent, loc); current = nextRequestForRedirect(current, response.status, newUrl); attempts = attempts + 1; result = doSendOnce(client, current) } }
          }
        } else {
          redirecting = false
        }
      }
    }
  }
  result
}

// =====================================================================
// Response accessors.
// =====================================================================
pub func hostStatusCode(response: in HttpResponseMessage): Int {
  response.status
}

pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  match findHeaderValue(response.headerNames, response.headerValues, name) {
    case Some(v) -> v
    case None -> ""
  }
}

/// Always `1` on this target (module header item 1 — HTTP/1.1 only, no h2
/// client).
pub func hostResponseVersionMajor(response: in HttpResponseMessage): Int {
  1
}

func readBodyTextOf(response: in HttpResponseMessage): Result[String, String] {
  match tryDecodeUtf8(response.bodyBytes) {
    case Some(t) -> Ok(value = t)
    case None -> Err(error = "response body is not valid UTF-8")
  }
}

// ---------------------------------------------------------------------------
// Public send/read surface — mirrors `_kernel/http_host.l`/`_kernel_jvm/
// http_host.l`. Result-native throughout (D-N-003: no try/catch on
// native) — every internal helper above already returns `Result`, so
// these are thin wrappers, not an exception-to-Result boundary like the
// other two kernels'.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage
): Result[HttpResponseMessage, String] {
  doSend(client, request)
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  doSend(client, hostMakeRequest("GET", url))
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  doSend(client, hostWithStringBody(hostMakeRequest("POST", url), contentType, body))
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  readBodyTextOf(response)
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  Ok(value = response.bodyBytes)
}

// ---------------------------------------------------------------------------
// `*WithCancel*` family (module header item 5): declared for
// `std/http.l`'s type-checking needs, `token` accepted but never
// consulted — no native `Std.Task` cancellation kernel exists yet.
// ---------------------------------------------------------------------------
pub async func hostSendWithCancelSafe(
  client: in HttpClientHandle,
  request: in HttpRequestMessage,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  doSend(client, request)
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  doSend(client, hostMakeRequest("GET", url))
}

pub async func hostPostStringWithCancelSafe(
  client: in HttpClientHandle,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  doSend(client, hostWithStringBody(hostMakeRequest("POST", url), contentType, body))
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  readBodyTextOf(response)
}
