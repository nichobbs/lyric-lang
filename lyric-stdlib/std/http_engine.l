//! std/http_engine.l — pure-Lyric, sans-IO HTTP/1.1 protocol engine
//! (docs/61-https-tls-http-versions.md §6.1/§6.4, D128; phase 3.2 of epic
//! #5874, issue #5883).
//!
//! `Std.HttpEngine` is a request parser, response serializer, and
//! per-connection state machine for HTTP/1.1. It never touches a socket:
//! `feed` consumes byte slices handed to it by a transport driver (the
//! `_kernel/tcp_host.l` + `SslStream` assembly landing in #5884) and
//! returns typed events; the serializer functions turn a response head and
//! body into byte slices the driver writes back out. This "sans-IO" split
//! (precedent: `Std.Xml`/`Std.Yaml`, D065) is what makes the engine
//! exhaustively unit-testable with zero network I/O and reusable, unchanged,
//! by the JVM and native transports that land later (docs/61 decision 6/8) —
//! only the transport kernel differs per target, never this file.
//!
//! No `extern type`, no `import extern`, no kernel file: every byte here is
//! plain Lyric computation over `slice[Byte]`/`String`. Only
//! `Std.Core`/`Std.Collections`/`Std.String`/`Std.Char` are imported, all of
//! which are the same zero-new-kernel dependencies `Std.Xml`/`Std.Yaml`
//! already establish as precedent for a pure-Lyric parser.
//!
//! ## Event vocabulary
//!
//! `feed(conn, bytes)` returns a `FeedResult { conn, events }`: a new
//! connection value (old values must not be reused — see "Connection
//! lifecycle" below) plus every event produced by consuming `bytes`. One
//! `feed` call can yield many events (a full bodyless request is
//! `RequestHead` + `RequestComplete` in one call; two fully-buffered
//! pipelined requests yield two of each) or none of substance, in which case
//! the single event `NeedMore` is returned so a caller never has to treat an
//! empty list specially.
//!
//!   - `NeedMore` — no complete event yet; wait for more bytes.
//!   - `RequestHead(method, target, version, headers)` — request line +
//!     headers fully parsed. `target` is passed through **raw** —
//!     percent-decoding is a routing concern, not this engine's (task #5883
//!     point 3).
//!   - `ExpectContinue` — the request carries `Expect: 100-continue`; the
//!     driver should write a `100 Continue` interim response (via
//!     `serializeResponseHead`) before the body events arrive.
//!   - `BodyChunk(bytes)` — a slice of request-body payload (dechunked:
//!     chunk framing is stripped, only payload bytes are ever emitted here).
//!   - `RequestComplete` — the full request (headers + body, trailers
//!     parsed-and-discarded if chunked) has been consumed.
//!   - `ProtocolError(kind, message)` — the input violates HTTP/1.1 framing.
//!     The connection is fatally poisoned from this point on (`isFailed`
//!     becomes true, `shouldClose` becomes true); the driver should send an
//!     error response derived from `protocolErrorStatus(kind)` and close the
//!     transport. Calling `feed` again after this is a contract violation
//!     (`requires: not isFailed(conn)`) — the FSM has no defined next state.
//!
//! ## Strictness decisions (security-critical — RFC 9112 framing)
//!
//! These are deliberate, not oversights; each is exercised by
//! `lyric-stdlib/tests/http_engine_tests.l`:
//!
//!   - **Strict CRLF only.** A bare CR or bare LF where CRLF is required is
//!     rejected (`BareCr`/`BareLf`), never leniently upgraded. This is a
//!     server, and differential CR/LF handling across intermediaries is a
//!     classic request-smuggling vector — RFC 9112 §2.2 permits recipients
//!     to treat a bare LF as a line terminator for compatibility, but does
//!     not require it, and the stricter reading closes the ambiguity
//!     outright rather than trading it for a compatibility shim we don't
//!     need (there is no known client sending bare LF in the wild that this
//!     server must support).
//!   - **`Content-Length` + `Transfer-Encoding` together is always
//!     rejected**, regardless of which framing "would win" — RFC 9112 §6.3:
//!     "If a message is received with both a Transfer-Encoding and a
//!     Content-Length header field, the Transfer-Encoding overrides the
//!     Content-Length. Such a message might indicate an attempt to perform
//!     request smuggling ... and ought to be handled as an error." This
//!     engine takes the "handled as an error" branch unconditionally
//!     (`ContentLengthWithTransferEncoding`) rather than implementing the
//!     "TE wins" fallback, per modern practice and this task's explicit
//!     instruction.
//!   - **`chunked` must be the final transfer-coding.** RFC 9112 §6.1: a
//!     `Transfer-Encoding` whose last coding is not `chunked` leaves the
//!     message length indeterminate for a recipient that does not implement
//!     the other codings (this engine implements none of them, by design —
//!     content-codings are a payload-transform concern above this layer).
//!     `chunked` appearing anywhere but last is `NonFinalChunkedEncoding`;
//!     missing entirely is `InvalidTransferEncoding`.
//!   - **Conflicting `Content-Length` values are rejected**
//!     (`ConflictingContentLength`, RFC 9112 §6.3); identical repeated
//!     values are tolerated (a common, harmless proxy artifact).
//!   - **No whitespace between a header field-name and its colon** (RFC
//!     9112 §5.1: "A server MUST reject ... with a 400 (Bad Request)
//!     response ... to close or refuse to reuse the connection") —
//!     `WhitespaceBeforeColon`.
//!   - **obs-fold (header line continuation) is rejected outright**
//!     (`ObsoleteLineFolding`) — RFC 9112 §5.2 deprecates it and permits
//!     rejection; folding is also a well-known smuggling-adjacent ambiguity
//!     across intermediaries.
//!   - **Header field-values are restricted to `field-vchar` / SP / HTAB**
//!     (RFC 9110 §5.5); `obs-text` (bytes 0x80-0xFF) is refused rather than
//!     accepted-as-opaque, since this stdlib has no Latin-1 helper to
//!     represent it faithfully as a `String` and RFC 9110 itself says a
//!     sender "SHOULD NOT" generate it. Malformed byte -> `MalformedHeaderLine`.
//!   - **Request-target**: origin-form (`/...`) is always accepted;
//!     absolute-form (contains `://`) is accepted per RFC 9112 §3.2.2
//!     ("a server MUST accept the absolute-form... even though...");
//!     asterisk-form (`*`) is accepted only for `OPTIONS`
//!     (`UnsupportedRequestTarget` otherwise) per RFC 9112 §3.2.4.
//!     Authority-form (bare `host:port`, the `CONNECT` form) is not
//!     accepted — this engine does not support `CONNECT` tunneling.
//!   - **Request-line token separators are exactly one SP.** RFC 9112 §3
//!     allows lenient whitespace-delimited parsing but does not require it;
//!     requiring exactly one SP is the strict reading and, again, closes a
//!     differential-parsing gap rather than opening one.
//!
//! ## Limits (`EngineLimits`)
//!
//! `EngineLimits` deliberately declares **no defaulted fields** — every one
//! of its four fields is mandatory at every construction site, in every
//! package. This sidesteps, by construction, the cross-package
//! defaulted-field-omission miscompile that affects records with declared
//! defaults on both backends (#5908 JVM, #5920 MSIL — see
//! `lyric-stdlib/std/tls.l`'s `TlsServerConfig` doc comment for the full
//! writeup): there is no default to omit, so the type checker's ordinary
//! "missing required field" diagnostic (not a runtime miscompile) is the
//! only failure mode for an incomplete construction. Use
//! `EngineLimits.defaults()` for the common case; construct a custom
//! `EngineLimits` value directly (all four fields) to test limit
//! enforcement.
//!
//! ## Connection lifecycle
//!
//! `Connection` is logically a **linear** value: `feed` takes one by `in`
//! and returns a new one inside `FeedResult`. Never reuse the `conn` value
//! passed into `feed` after the call — always rebind to `result.conn`. This
//! mirrors the immutable-value style the rest of the stdlib uses for
//! builders (`HttpClientBuilder`) rather than in-place mutation, so a
//! connection's state can be captured, logged, or handed across a
//! `scope`/`spawn` boundary (D119/D120) without aliasing surprises.
//!
//! `shouldClose(conn)` reports whether the transport should close after the
//! most recently completed (or fatally failed) request: HTTP/1.1 defaults
//! to keep-alive unless the request carries `Connection: close`; HTTP/1.0
//! defaults to close unless it carries `Connection: keep-alive`. Pipelined
//! requests already buffered in one `feed` call are parsed and their events
//! emitted in order in that same call — the engine cannot refuse to look at
//! bytes it has already been handed, since sans-IO means it never controls
//! how many bytes arrive per read. Enforcing "read one request, then don't
//! read ahead until the response is flushed" (the sense in which docs/61
//! §6.1 says the connection FSM performs "pipelining rejection") is a
//! transport-driver policy — the driver simply chooses when to call
//! `read`/`feed` again — and lands with the transport assembly in #5884,
//! not in this sans-IO layer.
//!
//! ## Deviations from the issue's literal API sketch
//!
//! `ProtocolError(code, reason)` became `ProtocolError(kind, message)` plus
//! a pure `protocolErrorStatus(kind): Int` helper: an exhaustive
//! `ProtocolErrorKind` enum lets tests assert the *exact* rejection reason
//! (`case ProtocolError(kind, _) -> match kind { case ConflictingContentLength -> ... }`)
//! instead of string-matching a message, and the status code is derived
//! data (one `kind` always maps to one status) rather than duplicated
//! alongside it on every event.
@runtime_checked
package Std.HttpEngine

import Std.Core
import Std.Collections
import Std.String
import Std.Char as Char

// =============================================================================
// §1. Limits.
// =============================================================================
/// Resource limits enforced while parsing a single connection's requests.
/// Every field is mandatory (no declared defaults) — see the module
/// header's "Limits" section for why.
@experimental
pub record EngineLimits {
  maxRequestLineLength: Int
  maxHeaderCount: Int
  maxHeaderLineLength: Int
  maxTotalHeaderBytes: Int
}

/// Sane production defaults: an 8 KiB request line, at most 100 headers, an
/// 8 KiB single header line, and 64 KiB of total header bytes per request
/// (trailers on a chunked body reuse the same header-count/byte budget,
/// counted independently per request).
@pure
@experimental
pub func EngineLimits.defaults(): EngineLimits {
  EngineLimits(
    maxRequestLineLength = 8192,
    maxHeaderCount = 100,
    maxHeaderLineLength = 8192,
    maxTotalHeaderBytes = 65536
  )
}

// =============================================================================
// §2. Core vocabulary types.
// =============================================================================
/// Cases are `Http1_0`/`Http1_1`, not the more obvious `Http10`/`Http11`:
/// `Std.Http`'s own (client-facing, negotiation-oriented) `HttpVersion`
/// enum already declares a case named `Http11`, and a self-hosted
/// compiler bug (cross-package bare enum-case name resolution — the same
/// bug class as `Std.Tls`'s `CertFileNotFound` rename, #5903/#5984; this
/// specific enum-vs-enum shape filed as #5995) resolves a bare `Http11`
/// construction/match against the *wrong* package's case once both types
/// are compiled into the same program (verified against the real
/// `lyric-stdlib/lyric.full.toml` bundle, on both `--target dotnet` and
/// `--target jvm`), silently corrupting `HttpVersion` values built or
/// matched here. Only the exact string `Http11` collides (verified:
/// `Http10` does not exist elsewhere in the stdlib) — renaming just that
/// one case would be asymmetric, so both are renamed for consistency.
@experimental
pub enum HttpVersion {
  case Http1_0
  case Http1_1
}

/// Render the wire token for a version ("HTTP/1.0" / "HTTP/1.1").
@pure
@experimental
pub func httpVersionToken(v: in HttpVersion): String {
  match v {
    case Http1_0 -> "HTTP/1.0"
    case Http1_1 -> "HTTP/1.1"
  }
}

/// One request or response header field, in wire order. `name` preserves
/// the case the client (or the driver, for a response) supplied.
@experimental
pub record HeaderField {
  name: String
  value: String
}

/// Case-insensitive lookup of the first header named `name`.
@pure
@experimental
pub func headerValue(headers: in List[HeaderField], name: in String): Option[String] {
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if equalsCaseInsensitive(h.name, name) {
      return Some(value = h.value)
    }
    i = i + 1
  }
  None
}

/// Every value of headers named `name`, in wire order (case-insensitive
/// name match). Used for list-valued headers that may legally repeat
/// (`Content-Length`, `Transfer-Encoding`).
@pure
@experimental
pub func headerValues(headers: in List[HeaderField], name: in String): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if equalsCaseInsensitive(h.name, name) {
      acc.add(h.value)
    }
    i = i + 1
  }
  acc
}

/// Exhaustive classification of every way `feed` can reject input. See the
/// module header ("Strictness decisions") for the RFC citation behind each
/// case.
@experimental
pub union ProtocolErrorKind {
  case MalformedRequestLine
  case RequestLineTooLong
  case UnsupportedRequestTarget
  case UnsupportedVersion
  case MalformedHeaderLine
  case WhitespaceBeforeColon
  case ObsoleteLineFolding
  case HeaderLineTooLong
  case TooManyHeaders
  case HeadersTooLarge
  case ConflictingContentLength
  case InvalidContentLength
  case ContentLengthWithTransferEncoding
  case InvalidTransferEncoding
  case NonFinalChunkedEncoding
  case MalformedChunkSize
  case ChunkSizeOverflow
  case BareCr
  case BareLf
}

/// The HTTP status code a driver should respond with for a given rejection
/// kind, before closing the connection.
@pure
@experimental
pub func protocolErrorStatus(kind: in ProtocolErrorKind): Int {
  match kind {
    case MalformedRequestLine -> 400
    case RequestLineTooLong -> 414
    case UnsupportedRequestTarget -> 400
    case UnsupportedVersion -> 505
    case MalformedHeaderLine -> 400
    case WhitespaceBeforeColon -> 400
    case ObsoleteLineFolding -> 400
    case HeaderLineTooLong -> 431
    case TooManyHeaders -> 431
    case HeadersTooLarge -> 431
    case ConflictingContentLength -> 400
    case InvalidContentLength -> 400
    case ContentLengthWithTransferEncoding -> 400
    case InvalidTransferEncoding -> 400
    case NonFinalChunkedEncoding -> 400
    case MalformedChunkSize -> 400
    case ChunkSizeOverflow -> 400
    case BareCr -> 400
    case BareLf -> 400
  }
}

/// Every event `feed` can produce. See the module header's "Event
/// vocabulary" section.
@experimental
pub union HttpEvent {
  case NeedMore
  case RequestHead(method: String, target: String, version: HttpVersion, headers: List[HeaderField])
  case ExpectContinue
  case BodyChunk(bytes: slice[Byte])
  case RequestComplete
  case ProtocolError(kind: ProtocolErrorKind, message: String)
}

// =============================================================================
// §3. Connection state machine.
// =============================================================================
/// Internal per-connection parse phase. Never exposed outside this package
/// — `Connection` is opaque so a driver can only observe it through
/// `shouldClose`/`isFailed` and the events `feed` returns.
union ConnPhase {
  case PhRequestLine
  case PhHeaders(method: String, target: String, version: HttpVersion, headers: List[HeaderField], headerBytes: Int)
  case PhFixedBody(remaining: Int)
  case PhChunkSize
  case PhChunkData(remaining: Int)
  case PhChunkCrlf
  case PhTrailer(count: Int, bytes: Int)
  case PhFatal
}

/// Per-connection engine state: the unconsumed input buffer, the current
/// parse phase, the configured limits, and the keep-alive decision derived
/// from the most recently completed (or failed) request. See the module
/// header's "Connection lifecycle" section for its linear-value contract.
///
/// This is a plain `record`, not `opaque`, even though every field is an
/// internal FSM detail no consumer should read or construct directly:
/// declaring it `opaque` triggers a self-hosted JVM backend codegen bug
/// (filed as #5937, minimally reproduced independent of this file) where a
/// `slice[Byte]`-typed field on an `opaque type`, accessed from an `inout`
/// parameter within the *declaring* package, emits a field descriptor
/// (`Object[]`) that does not match the class's actual compiled field type,
/// producing `NoSuchFieldError` at runtime — plain `record`s with the exact
/// same field shape do not exhibit this bug. Treat `Connection`'s fields as
/// private despite the compiler not enforcing it: construct one only via
/// `newConnection`, and observe it only via `shouldClose`/`isFailed`/`feed`.
@experimental
pub record Connection {
  limits: EngineLimits
  phase: ConnPhase
  buf: slice[Byte]
  keepAlive: Bool
  fatal: Bool
}

/// A fresh connection with no buffered input, ready to parse a request
/// line.
@pure
@experimental
pub func newConnection(limits: in EngineLimits): Connection {
  val emptyBuf: slice[Byte] = []
  Connection(limits = limits, phase = PhRequestLine, buf = emptyBuf, keepAlive = true, fatal = false)
}

/// True once a `ProtocolError` has been emitted for this connection; the
/// FSM has no defined next state, so `feed` refuses to run again
/// (`requires: not isFailed(conn)`).
@pure
@experimental
pub func isFailed(conn: in Connection): Bool {
  conn.fatal
}

/// True if the transport should close after the current exchange: always
/// true once failed, otherwise the keep-alive decision derived from the
/// most recently completed request's version and `Connection` header (see
/// `computeKeepAlive`).
@pure
@experimental
pub func shouldClose(conn: in Connection): Bool {
  conn.fatal or not conn.keepAlive
}

/// What `feed` returns: the connection's next state plus every event
/// produced by the bytes just fed. Always has at least one event — an
/// empty-events call site would erase the distinction between "no bytes
/// yet" and "waiting for more", so an idle call yields exactly `[NeedMore]`.
@experimental
pub record FeedResult {
  conn: Connection
  events: List[HttpEvent]
}

// =============================================================================
// §4. Byte-level scanning primitives.
// =============================================================================
func isCr(b: in Byte): Bool {
  b.toInt() == 13
}

func isLf(b: in Byte): Bool {
  b.toInt() == 10
}

func isSp(b: in Byte): Bool {
  b.toInt() == 32
}

func isHtab(b: in Byte): Bool {
  b.toInt() == 9
}

func isColon(b: in Byte): Bool {
  b.toInt() == 58
}

func isSemicolon(b: in Byte): Bool {
  b.toInt() == 59
}

/// RFC 9110 §5.6.2 `tchar`: the character set legal in a header field-name
/// or an HTTP method token.
func isTchar(b: in Byte): Bool {
  val v = b.toInt();
  (v >= 48 and v <= 57) or (v >= 65 and v <= 90) or (v >= 97 and v <= 122) or v == 33 or v == 35 or v == 36 or v == 37 or
    v == 38 or
    v == 39 or
    v == 42 or
    v == 43 or
    v == 45 or
    v == 46 or
    v == 94 or
    v == 95 or
    v == 96 or
    v == 124 or
    v == 126
}

/// RFC 9110 §5.5 `field-vchar` (visible US-ASCII, excludes `obs-text`).
func isVchar(b: in Byte): Bool {
  val v = b.toInt()
  v >= 33 and v <= 126
}

/// A byte legal inside a trimmed header field-value: `field-vchar`, SP, or
/// HTAB (internal whitespace between vchars is legal; leading/trailing OWS
/// is trimmed before this check runs).
func isFieldValueByte(b: in Byte): Bool {
  isVchar(b) or isSp(b) or isHtab(b)
}

func isHexDigitByte(b: in Byte): Bool {
  val v = b.toInt();
  (v >= 48 and v <= 57) or (v >= 97 and v <= 102) or (v >= 65 and v <= 70)
}

func hexDigitByteValue(b: in Byte): Int {
  val v = b.toInt()
  if v >= 48 and v <= 57 {
    v - 48
  } else if v >= 97 and v <= 102 {
    v - 97 + 10
  } else {
    v - 65 + 10
  }
}

/// Every byte in `bytes` satisfies `pred`. Vacuously true for an empty
/// slice.
func allBytes(bytes: in slice[Byte], pred: in (Byte) -> Bool): Bool {
  var i = 0
  while i < bytes.length {
    // Both explicit type annotations below are load-bearing, not
    // decoration — see the two-part comment on `findByteWhere` just below
    // for the full writeup (MSIL argument-boxing bug #5934, JVM
    // return-value-unboxing bug #5935). Do not "clean up" either local away.
    val b: Byte = bytes[i]
    val ok: Bool = pred(b)
    if not ok {
      return false
    }
    i = i + 1
  }
  true
}

/// The index of the first byte satisfying `pred`, or `None`.
func findByteWhere(bytes: in slice[Byte], pred: in (Byte) -> Bool): Option[Int] {
  var i = 0
  while i < bytes.length {
    // Two independent, minimally-reproduced compiler bugs, both worked
    // around by explicit type annotations on locals rather than inlining
    // the expressions directly:
    //
    //   - MSIL (#5934): passing a `slice[Byte]` index expression straight
    //     into a `(Byte) -> Bool`-typed parameter throws
    //     `InvalidCastException: Unable to cast object of type
    //     'System.Byte' to type 'System.Int32'` at the call site — the
    //     uniform lambda ABI's `Func<object, object>` boxing infers the
    //     wrong static type for an unannotated slice-index expression.
    //     Binding it to an explicitly `: Byte`-typed local first (`b`
    //     below) avoids the bad inference.
    //   - JVM (#5935): using the `Bool` returned by a `(Byte) -> Bool`
    //     call directly as an `if` condition emits invalid bytecode
    //     (`VerifyError: Bad type on operand stack` at the `ifeq`) — the
    //     boxed `Boolean` return value is never unboxed before the branch
    //     instruction. Binding it to an explicitly `: Bool`-typed local
    //     first (`ok` below) forces the unbox to happen at the assignment.
    //
    // Do not "clean up" either local away.
    val b: Byte = bytes[i]
    val ok: Bool = pred(b)
    if ok {
      return Some(value = i)
    }
    i = i + 1
  }
  None
}

/// Trim leading/trailing SP/HTAB bytes (RFC 9110 `OWS`).
func trimOws(bytes: in slice[Byte]): slice[Byte] {
  var start = 0
  var stop = bytes.length
  while start < stop and (isSp(bytes[start]) or isHtab(bytes[start])) {
    start = start + 1
  }
  while stop > start and (isSp(bytes[stop - 1]) or isHtab(bytes[stop - 1])) {
    stop = stop - 1
  }
  bytes.slice(start, stop)
}

/// Every byte here is guaranteed ASCII (< 0x80) by the tchar/vchar checks
/// above at every call site, so this is a total, allocation-simple
/// byte-to-`String` conversion with no UTF-8 multi-byte decoding needed —
/// an ASCII code point IS its own Unicode code point.
func asciiBytesToString(bytes: in slice[Byte]): String {
  var acc = ""
  var i = 0
  while i < bytes.length {
    acc = acc + ("" + Char.fromInt(bytes[i].toInt()))
    i = i + 1
  }
  acc
}

/// Result of scanning for the next CRLF-terminated line within a byte
/// budget of `limit` bytes (used for the request line, each header line,
/// and each chunk-size line — all three share one grammar shape: a run of
/// bytes terminated by a strict CRLF, capped at a caller-supplied length).
union LineScan {
  case LsNeedMore
  case LsTooLong
  case LsBareCr
  case LsBareLf
  case LsFound(contentEnd: Int, consumed: Int)
}

func scanCrlfLine(buf: in slice[Byte], limit: in Int): LineScan {
  val n = buf.length
  val cap = if limit < n { limit } else { n }
  var i = 0
  while i < cap {
    val b = buf[i]
    if isLf(b) {
      if i == 0 or not isCr(buf[i - 1]) {
        return LsBareLf
      }
      return LsFound(contentEnd = i - 1, consumed = i + 1)
    } else if isCr(b) {
      if i + 1 >= n {
        return LsNeedMore
      }
      if isLf(buf[i + 1]) {
        return LsFound(contentEnd = i, consumed = i + 2)
      }
      return LsBareCr
    }
    i = i + 1
  }
  if n < limit {
    LsNeedMore
  } else {
    LsTooLong
  }
}

// =============================================================================
// §5. Request-line parsing.
// =============================================================================
record ProtoErr {
  kind: ProtocolErrorKind
  message: String
}

record ParsedRequestLine {
  method: String
  target: String
  version: HttpVersion
}

func parseHttpVersionToken(bytes: in slice[Byte]): Option[HttpVersion] {
  if bytes.length == 8 and asciiBytesToString(bytes) == "HTTP/1.1" {
    Some(value = Http1_1)
  } else if bytes.length == 8 and asciiBytesToString(bytes) == "HTTP/1.0" {
    Some(value = Http1_0)
  } else {
    None
  }
}

/// RFC 9112 §3.2: origin-form (starts with `/`), absolute-form (contains a
/// `://` scheme separator), or asterisk-form (`*`, `OPTIONS` only).
/// Authority-form (the bare `host:port` `CONNECT` target) is not accepted —
/// this engine does not support `CONNECT` tunneling.
func validateRequestTarget(target: in String, method: in String): Option[ProtoErr] {
  if target == "*" {
    if equalsCaseInsensitive(method, "OPTIONS") {
      None
    } else {
      Some(
        value = ProtoErr(
          kind = UnsupportedRequestTarget,
          message = "asterisk-form request-target is only valid for OPTIONS"
        )
      )
    }
  } else if startsWith(target, "/") {
    None
  } else if contains(target, "://") {
    None
  } else {
    Some(
      value = ProtoErr(
        kind = UnsupportedRequestTarget,
        message = "request-target must be origin-form, absolute-form, or asterisk-form"
      )
    )
  }
}

// The request-line grammar (`method SP request-target SP HTTP-version`) is
// deliberately parsed as a flat chain of single-purpose, non-nested helper
// functions threaded together with `?`, rather than as one deeply nested
// `match`-inside-`match`-arm expression: a self-hosted JVM backend codegen
// bug (filed as #5936) emits bytecode with an inconsistent stack-map frame
// at a branch target for a sufficiently deep nested-match shape here
// (`VerifyError: Inconsistent stackmap frames`), verified with a minimal
// standalone repro independent of this file. Splitting each grammar step
// into its own function with at most one non-nested `match` avoids the
// bad shape entirely and is more readable besides.
record SplitPoint {
  before: slice[Byte]
  after: slice[Byte]
}

func requireSpaceSplit(bytes: in slice[Byte], errMessage: in String): Result[SplitPoint, ProtoErr] {
  match findByteWhere(bytes, { b: Byte -> isSp(b) }) {
    case None -> Err(error = ProtoErr(kind = MalformedRequestLine, message = errMessage))
    case Some(idx) -> Ok(value = SplitPoint(before = bytes.slice(0, idx), after = bytes.slice(idx + 1, bytes.length)))
  }
}

func requireMethodToken(bytes: in slice[Byte]): Result[String, ProtoErr] {
  if bytes.length == 0 or not allBytes(bytes, { b: Byte -> isTchar(b) }) {
    Err(error = ProtoErr(kind = MalformedRequestLine, message = "invalid method token"))
  } else {
    Ok(value = asciiBytesToString(bytes))
  }
}

func requireTargetToken(bytes: in slice[Byte]): Result[String, ProtoErr] {
  if bytes.length == 0 or not allBytes(bytes, { b: Byte -> isVchar(b) }) {
    Err(error = ProtoErr(kind = MalformedRequestLine, message = "invalid request-target bytes"))
  } else {
    Ok(value = asciiBytesToString(bytes))
  }
}

func requireValidTarget(target: in String, method: in String): Result[String, ProtoErr] {
  match validateRequestTarget(target, method) {
    case Some(e) -> Err(error = e)
    case None -> Ok(value = target)
  }
}

func requireVersion(bytes: in slice[Byte]): Result[HttpVersion, ProtoErr] {
  match parseHttpVersionToken(bytes) {
    case None -> Err(error = ProtoErr(kind = UnsupportedVersion, message = "expected HTTP/1.1 or HTTP/1.0"))
    case Some(v) -> Ok(value = v)
  }
}

func parseRequestLine(line: in slice[Byte]): Result[ParsedRequestLine, ProtoErr] {
  val firstSplit = requireSpaceSplit(line, "request line has no spaces")?
  val method = requireMethodToken(firstSplit.before)?
  val secondSplit = requireSpaceSplit(firstSplit.after, "request line missing a second space")?
  val target = requireTargetToken(secondSplit.before)?
  val validTarget = requireValidTarget(target, method)?
  val version = requireVersion(secondSplit.after)?
  Ok(value = ParsedRequestLine(method = method, target = validTarget, version = version))
}

// =============================================================================
// §6. Header-line parsing.
// =============================================================================
record HeaderPair {
  name: String
  value: String
}

func splitHeaderLine(line: in slice[Byte]): Result[HeaderPair, ProtoErr] {
  match findByteWhere(line, { b: Byte -> isColon(b) }) {
    case None -> Err(error = ProtoErr(kind = MalformedHeaderLine, message = "header line missing colon"))
    case Some(idx) -> {
      val nameBytes = line.slice(0, idx)
      if nameBytes.length == 0 {
        return Err(error = ProtoErr(kind = MalformedHeaderLine, message = "empty header field-name"))
      }
      if isSp(nameBytes[nameBytes.length - 1]) or isHtab(nameBytes[nameBytes.length - 1]) {
        return Err(
          error = ProtoErr(
            kind = WhitespaceBeforeColon,
            message = "whitespace between header field-name and colon is rejected (RFC 9112 section 5.1)"
          )
        )
      }
      if not allBytes(nameBytes, { b: Byte -> isTchar(b) }) {
        return Err(error = ProtoErr(kind = MalformedHeaderLine, message = "invalid header field-name token"))
      }
      val rawValue = line.slice(idx + 1, line.length)
      val trimmed = trimOws(rawValue)
      if not allBytes(trimmed, { b: Byte -> isFieldValueByte(b) }) {
        return Err(
          error = ProtoErr(
            kind = MalformedHeaderLine,
            message = "invalid byte in header field-value (RFC 9110 section 5.5)"
          )
        )
      }
      Ok(value = HeaderPair(name = asciiBytesToString(nameBytes), value = asciiBytesToString(trimmed)))
    }
  }
}

union HeaderLineResult {
  case HlrNeedMore
  case HlrBlank(consumed: Int)
  case HlrField(name: String, value: String, consumed: Int)
  case HlrErr(kind: ProtocolErrorKind, message: String)
}

func scanHeaderLine(buf: in slice[Byte], limit: in Int): HeaderLineResult {
  match scanCrlfLine(buf, limit) {
    case LsNeedMore -> HlrNeedMore
    case LsTooLong -> HlrErr(kind = HeaderLineTooLong, message = "header line exceeds configured limit")
    case LsBareCr -> HlrErr(kind = BareCr, message = "bare CR in header section")
    case LsBareLf -> HlrErr(kind = BareLf, message = "bare LF in header section")
    case LsFound(lineEnd, consumed) -> {
      if lineEnd == 0 {
        HlrBlank(consumed = consumed)
      } else {
        val line = buf.slice(0, lineEnd)
        if isSp(line[0]) or isHtab(line[0]) {
          HlrErr(kind = ObsoleteLineFolding, message = "obs-fold header continuation line is rejected (RFC 9112 section 5.2)")
        } else {
          match splitHeaderLine(line) {
            case Err(e) -> HlrErr(kind = e.kind, message = e.message)
            case Ok(pair) -> HlrField(name = pair.name, value = pair.value, consumed = consumed)
          }
        }
      }
    }
  }
}

// =============================================================================
// §7. Framing, keep-alive, and 100-continue analysis.
// =============================================================================
union BodyPlan {
  case BpNone
  case BpFixed(length: Int)
  case BpChunked
}

func parseDigitsToInt(raw: in String): Option[Int] {
  val s = trim(raw)
  if s.length == 0 or s.length > 9 {
    return None
  }
  var n = 0
  var i = 0
  while i < s.length {
    match charAt(s, i) {
      case None -> return None
      case Some(c) -> match digitValue(c) { case None -> return None; case Some(d) -> { n = n * 10 + d } }
    }
    i = i + 1
  }
  Some(value = n)
}

func validateContentLength(values: in List[String]): Result[Int, ProtoErr] {
  val first = trim(values[0])
  match parseDigitsToInt(first) {
    case None -> Err(error = ProtoErr(kind = InvalidContentLength, message = "Content-Length is not a valid non-negative integer"))
    case Some(n) -> {
      var i = 1
      while i < values.count {
        if not equals(trim(values[i]), first) {
          return Err(
            error = ProtoErr(
              kind = ConflictingContentLength,
              message = "multiple Content-Length headers with differing values (RFC 9112 section 6.3)"
            )
          )
        }
        i = i + 1
      }
      Ok(value = n)
    }
  }
}

func splitAndTrimTokens(values: in List[String]): List[String] {
  val tokens: List[String] = newList()
  var i = 0
  while i < values.count {
    val parts = split(values[i], ",")
    var j = 0
    while j < parts.length {
      val t = trim(parts[j])
      if t.length > 0 {
        tokens.add(t)
      }
      j = j + 1
    }
    i = i + 1
  }
  tokens
}

/// RFC 9112 section 6.1: `chunked` must be the final transfer-coding.
func validateChunkedTransferEncoding(values: in List[String]): Result[Unit, ProtoErr] {
  val tokens = splitAndTrimTokens(values)
  if tokens.count == 0 {
    return Err(error = ProtoErr(kind = InvalidTransferEncoding, message = "Transfer-Encoding header present but empty"))
  }
  val lastIdx = tokens.count - 1
  if not equalsCaseInsensitive(tokens[lastIdx], "chunked") {
    return Err(
      error = ProtoErr(
        kind = NonFinalChunkedEncoding,
        message = "chunked must be the final transfer-coding (RFC 9112 section 6.1)"
      )
    )
  }
  var k = 0
  while k < lastIdx {
    if equalsCaseInsensitive(tokens[k], "chunked") {
      return Err(
        error = ProtoErr(
          kind = NonFinalChunkedEncoding,
          message = "chunked transfer-coding must not appear before the final position"
        )
      )
    }
    k = k + 1
  }
  Ok(value = ())
}

/// Decide the request body's framing per RFC 9112 section 6.3: reject
/// outright if both `Content-Length` and `Transfer-Encoding` are present
/// (the request-smuggling defense — see the module header), otherwise
/// `Transfer-Encoding` (validated ending in `chunked`), otherwise
/// `Content-Length` (validated non-conflicting), otherwise no body.
func analyzeFraming(headers: in List[HeaderField]): Result[BodyPlan, ProtoErr] {
  val clValues = headerValues(headers, "Content-Length")
  val teValues = headerValues(headers, "Transfer-Encoding")
  if clValues.count > 0 and teValues.count > 0 {
    return Err(
      error = ProtoErr(
        kind = ContentLengthWithTransferEncoding,
        message = "Content-Length and Transfer-Encoding must not both be present (RFC 9112 section 6.3); rejected as a request-smuggling risk"
      )
    )
  }
  if teValues.count > 0 {
    match validateChunkedTransferEncoding(teValues) {
      case Err(e) -> return Err(error = e)
      case Ok(_) -> return Ok(value = BpChunked)
    }
  }
  if clValues.count > 0 {
    match validateContentLength(clValues) {
      case Err(e) -> return Err(error = e)
      case Ok(n) -> return Ok(value = BpFixed(length = n))
    }
  }
  Ok(value = BpNone)
}

/// HTTP/1.1 defaults to keep-alive unless `Connection: close` is present;
/// HTTP/1.0 defaults to close unless `Connection: keep-alive` is present.
/// A `close` token always wins regardless of version.
func computeKeepAlive(version: in HttpVersion, headers: in List[HeaderField]): Bool {
  val tokens = splitAndTrimTokens(headerValues(headers, "Connection"))
  var hasClose = false
  var hasKeepAlive = false
  var i = 0
  while i < tokens.count {
    if equalsCaseInsensitive(tokens[i], "close") {
      hasClose = true
    }
    if equalsCaseInsensitive(tokens[i], "keep-alive") {
      hasKeepAlive = true
    }
    i = i + 1
  }
  if hasClose {
    false
  } else {
    match version {
      case Http1_1 -> true
      case Http1_0 -> hasKeepAlive
    }
  }
}

func hasExpectContinue(headers: in List[HeaderField]): Bool {
  match headerValue(headers, "Expect") {
    case None -> false
    case Some(v) -> equalsCaseInsensitive(trim(v), "100-continue")
  }
}

// =============================================================================
// §8. Chunk framing.
// =============================================================================
/// Parse a chunk-size line's content (CRLF already stripped): leading hex
/// digits are the size; anything from a `;` onward is a chunk extension,
/// discarded per this engine's parse-and-discard policy (task #5883 point
/// 6). More than 7 hex digits is rejected as `ChunkSizeOverflow` — a
/// generous 256 MiB ceiling per chunk that stays safely inside `Int` range
/// with headroom, rather than relying on precise 32-bit overflow arithmetic.
func parseChunkSizeLine(line: in slice[Byte]): Result[Int, ProtoErr] {
  var i = 0
  while i < line.length and isHexDigitByte(line[i]) {
    i = i + 1
  }
  if i == 0 {
    return Err(error = ProtoErr(kind = MalformedChunkSize, message = "chunk-size line has no hex digits"))
  }
  if i > 7 {
    return Err(
      error = ProtoErr(
        kind = ChunkSizeOverflow,
        message = "chunk size exceeds the supported range (more than 7 hex digits)"
      )
    )
  }
  if i < line.length and not isSemicolon(line[i]) {
    return Err(
      error = ProtoErr(
        kind = MalformedChunkSize,
        message = "malformed byte following chunk size (expected ';' or end of line)"
      )
    )
  }
  var n = 0
  var k = 0
  while k < i {
    n = n * 16 + hexDigitByteValue(line[k])
    k = k + 1
  }
  Ok(value = n)
}

// =============================================================================
// §9. The feed loop.
// =============================================================================
func failWith(state: inout Connection, events: in List[HttpEvent], kind: in ProtocolErrorKind, message: in String): Unit {
  state.fatal = true
  state.phase = PhFatal
  events.add(ProtocolError(kind = kind, message = message))
}

func finishHeaders(
  state: inout Connection,
  events: in List[HttpEvent],
  method: in String,
  target: in String,
  version: in HttpVersion,
  headers: in List[HeaderField],
): Unit {
  match analyzeFraming(headers) {
    case Err(e) -> failWith(state, events, e.kind, e.message)
    case Ok(plan) -> {
      state.keepAlive = computeKeepAlive(version, headers)
      events.add(RequestHead(method = method, target = target, version = version, headers = headers))
      if hasExpectContinue(headers) {
        events.add(ExpectContinue)
      }
      match plan {
        case BpNone -> {
          events.add(RequestComplete)
          state.phase = PhRequestLine
        }
        case BpFixed(length) -> {
          if length == 0 {
            events.add(RequestComplete)
            state.phase = PhRequestLine
          } else {
            state.phase = PhFixedBody(remaining = length)
          }
        }
        case BpChunked -> {
          state.phase = PhChunkSize
        }
      }
    }
  }
}

func enterHeaderPhase(state: inout Connection, parsed: in ParsedRequestLine): Unit {
  state.phase = PhHeaders(
    method = parsed.method,
    target = parsed.target,
    version = parsed.version,
    headers = newList(),
    headerBytes = 0
  )
}

func finishRequestLine(state: inout Connection, events: in List[HttpEvent], lineEnd: in Int, consumed: in Int): Unit {
  val line = state.buf.slice(0, lineEnd)
  // Binding the slice result to `remaining` before assigning it to
  // `state.buf` is load-bearing, not decoration: writing
  // `state.buf = state.buf.slice(...)` directly (self-referential field
  // reassignment via a call on the field's own value) on an `inout` record
  // parameter, followed by more code in the same function, emits invalid
  // JVM bytecode (`VerifyError: Inconsistent stackmap frames`) — a compiler
  // bug filed as #5936 with a minimal standalone repro. Every `state.buf =
  // state.buf.slice(...)`/`.concat(...)` site in this file goes through a
  // local first for the same reason; do not "simplify" any of them back.
  val remaining = state.buf.slice(consumed, state.buf.length)
  state.buf = remaining
  val parseResult = parseRequestLine(line)
  match parseResult {
    case Err(e) -> failWith(state, events, e.kind, e.message)
    case Ok(parsed) -> enterHeaderPhase(state, parsed)
  }
}

func stepRequestLine(state: inout Connection, events: in List[HttpEvent]): Bool {
  match scanCrlfLine(state.buf, state.limits.maxRequestLineLength) {
    case LsNeedMore -> false
    case LsTooLong -> {
      failWith(state, events, RequestLineTooLong, "request line exceeds configured limit")
      true
    }
    case LsBareCr -> {
      failWith(state, events, BareCr, "bare CR in request line")
      true
    }
    case LsBareLf -> {
      failWith(state, events, BareLf, "bare LF in request line")
      true
    }
    case LsFound(lineEnd, consumed) -> {
      finishRequestLine(state, events, lineEnd, consumed)
      true
    }
  }
}

// Each match arm below with more than a one-line body is factored into its
// own named function. This is not just style: a self-hosted JVM backend
// codegen bug (filed as #5936 — see `parseRequestLine`'s "flat chain of
// helpers" comment above for the full writeup and a minimal standalone
// repro) emits an inconsistent stack-map frame (`VerifyError`) for a
// `match` whose arms differ significantly in how many locals they bind
// and how much work they do; keeping every arm here to a single function
// call sidesteps the bad shape.
func onHeaderBlank(
  state: inout Connection,
  events: in List[HttpEvent],
  method: in String,
  target: in String,
  version: in HttpVersion,
  headersSoFar: in List[HeaderField],
  consumed: in Int,
): Unit {
  val remaining = state.buf.slice(consumed, state.buf.length)
  state.buf = remaining
  finishHeaders(state, events, method, target, version, headersSoFar)
}

func onHeaderField(
  state: inout Connection,
  events: in List[HttpEvent],
  method: in String,
  target: in String,
  version: in HttpVersion,
  headersSoFar: in List[HeaderField],
  headerBytes: in Int,
  name: in String,
  value: in String,
  consumed: in Int,
): Unit {
  val remaining = state.buf.slice(consumed, state.buf.length)
  state.buf = remaining
  val newCount = headersSoFar.count + 1
  val newBytes = headerBytes + consumed
  if newCount > state.limits.maxHeaderCount {
    failWith(state, events, TooManyHeaders, "header count exceeds configured limit")
  } else if newBytes > state.limits.maxTotalHeaderBytes {
    failWith(state, events, HeadersTooLarge, "total header bytes exceed configured limit")
  } else {
    headersSoFar.add(HeaderField(name = name, value = value))
    state.phase = PhHeaders(
      method = method,
      target = target,
      version = version,
      headers = headersSoFar,
      headerBytes = newBytes
    )
  }
}

func stepHeaders(
  state: inout Connection,
  events: in List[HttpEvent],
  method: in String,
  target: in String,
  version: in HttpVersion,
  headersSoFar: in List[HeaderField],
  headerBytes: in Int,
): Bool {
  match scanHeaderLine(state.buf, state.limits.maxHeaderLineLength) {
    case HlrNeedMore -> false
    case HlrErr(kind, message) -> {
      failWith(state, events, kind, message)
      true
    }
    case HlrBlank(consumed) -> {
      onHeaderBlank(state, events, method, target, version, headersSoFar, consumed)
      true
    }
    case HlrField(name, value, consumed) -> {
      onHeaderField(state, events, method, target, version, headersSoFar, headerBytes, name, value, consumed)
      true
    }
  }
}

func stepFixedBody(state: inout Connection, events: in List[HttpEvent], remaining: in Int): Bool {
  if remaining == 0 {
    events.add(RequestComplete)
    state.phase = PhRequestLine
    true
  } else if state.buf.length == 0 {
    false
  } else {
    val take = if state.buf.length < remaining { state.buf.length } else { remaining }
    val chunk = state.buf.slice(0, take)
    val remainingBuf = state.buf.slice(take, state.buf.length)
    state.buf = remainingBuf
    events.add(BodyChunk(bytes = chunk))
    state.phase = PhFixedBody(remaining = remaining - take)
    true
  }
}

func stepChunkSize(state: inout Connection, events: in List[HttpEvent]): Bool {
  match scanCrlfLine(state.buf, state.limits.maxHeaderLineLength) {
    case LsNeedMore -> false
    case LsTooLong -> {
      failWith(state, events, MalformedChunkSize, "chunk-size line exceeds configured limit")
      true
    }
    case LsBareCr -> {
      failWith(state, events, BareCr, "bare CR in chunk-size line")
      true
    }
    case LsBareLf -> {
      failWith(state, events, BareLf, "bare LF in chunk-size line")
      true
    }
    case LsFound(lineEnd, consumed) -> {
      val line = state.buf.slice(0, lineEnd)
      val remaining = state.buf.slice(consumed, state.buf.length)
      state.buf = remaining
      match parseChunkSizeLine(line) {
        case Err(e) -> failWith(state, events, e.kind, e.message)
        case Ok(size) -> {
          if size == 0 {
            state.phase = PhTrailer(count = 0, bytes = 0)
          } else {
            state.phase = PhChunkData(remaining = size)
          }
        }
      }
      true
    }
  }
}

func stepChunkData(state: inout Connection, events: in List[HttpEvent], remaining: in Int): Bool {
  if remaining == 0 {
    state.phase = PhChunkCrlf
    true
  } else if state.buf.length == 0 {
    false
  } else {
    val take = if state.buf.length < remaining { state.buf.length } else { remaining }
    val chunk = state.buf.slice(0, take)
    val remainingBuf = state.buf.slice(take, state.buf.length)
    state.buf = remainingBuf
    events.add(BodyChunk(bytes = chunk))
    state.phase = PhChunkData(remaining = remaining - take)
    true
  }
}

func stepChunkCrlf(state: inout Connection, events: in List[HttpEvent]): Bool {
  if state.buf.length < 2 {
    false
  } else if isCr(state.buf[0]) and isLf(state.buf[1]) {
    val remaining = state.buf.slice(2, state.buf.length)
    state.buf = remaining
    state.phase = PhChunkSize
    true
  } else {
    failWith(state, events, MalformedChunkSize, "chunk data not followed by CRLF")
    true
  }
}

func stepTrailer(state: inout Connection, events: in List[HttpEvent], count: in Int, bytes: in Int): Bool {
  match scanHeaderLine(state.buf, state.limits.maxHeaderLineLength) {
    case HlrNeedMore -> false
    case HlrErr(kind, message) -> {
      failWith(state, events, kind, message)
      true
    }
    case HlrBlank(consumed) -> {
      val remaining = state.buf.slice(consumed, state.buf.length)
      state.buf = remaining
      events.add(RequestComplete)
      state.phase = PhRequestLine
      true
    }
    case HlrField(_, _, consumed) -> {
      val remaining = state.buf.slice(consumed, state.buf.length)
      state.buf = remaining
      val newCount = count + 1
      val newBytes = bytes + consumed
      if newCount > state.limits.maxHeaderCount {
        failWith(state, events, TooManyHeaders, "trailer field count exceeds configured limit")
      } else if newBytes > state.limits.maxTotalHeaderBytes {
        failWith(state, events, HeadersTooLarge, "trailer bytes exceed configured limit")
      } else {
        state.phase = PhTrailer(count = newCount, bytes = newBytes)
      }
      true
    }
  }
}

func driveFeed(state: inout Connection, bytes: in slice[Byte]): List[HttpEvent] {
  val combined = state.buf.concat(bytes)
  state.buf = combined
  val events: List[HttpEvent] = newList()
  var progress = true
  while progress {
    match state.phase {
      case PhRequestLine -> {
        progress = stepRequestLine(state, events)
      }
      case PhHeaders(method, target, version, headers, headerBytes) -> {
        progress = stepHeaders(state, events, method, target, version, headers, headerBytes)
      }
      case PhFixedBody(remaining) -> {
        progress = stepFixedBody(state, events, remaining)
      }
      case PhChunkSize -> {
        progress = stepChunkSize(state, events)
      }
      case PhChunkData(remaining) -> {
        progress = stepChunkData(state, events, remaining)
      }
      case PhChunkCrlf -> {
        progress = stepChunkCrlf(state, events)
      }
      case PhTrailer(count, bytes) -> {
        progress = stepTrailer(state, events, count, bytes)
      }
      case PhFatal -> {
        progress = false
      }
    }
  }
  if events.count == 0 {
    events.add(NeedMore)
  }
  events
}

/// Feed newly-received bytes into `conn`, returning the connection's next
/// state plus every event produced. See the module header for the linear-
/// value contract on `conn` and the full event vocabulary.
///
/// # Contract
/// Calling `feed` after `isFailed(conn)` is a programmer error — the FSM
/// has no defined next state past a `ProtocolError` — not a wire-content
/// condition, so it is a `requires:` contract rather than a `ProtocolError`
/// event.
@experimental
pub func feed(conn: in Connection, bytes: in slice[Byte]): FeedResult
  requires: not isFailed(conn)
{
  var state = conn
  val events = driveFeed(state, bytes)
  FeedResult(conn = state, events = events)
}

// =============================================================================
// §10. Response serialization.
// =============================================================================
/// A response header/reason-phrase byte, restricted to visible US-ASCII
/// plus space (RFC 9110 field-value grammar is fundamentally a byte
/// charset, not Unicode text — see the module header's "Deviations"
/// section for why the serializer requires ASCII rather than encoding
/// arbitrary text). Excludes CR/LF, which would otherwise let a caller
/// that reflects unsanitized input into a response header inject
/// additional header lines or a second response ("response splitting").
func isResponseSafeByte(cp: in Int): Bool {
  cp >= 32 and cp <= 126
}

func isResponseSafeString(s: in String): Bool {
  var i = 0
  while i < s.length {
    match charAt(s, i) {
      case None -> return false
      case Some(c) -> if not isResponseSafeByte(toInt(c)) { return false }
    }
    i = i + 1
  }
  true
}

func allHeadersResponseSafe(headers: in List[HeaderField]): Bool {
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if h.name.length == 0 or not isResponseSafeString(h.name) or not isResponseSafeString(h.value) {
      return false
    }
    i = i + 1
  }
  true
}

/// Every char in `s` is ASCII (< 0x80), so a direct code-point-to-byte
/// conversion is exact — no UTF-8 multi-byte encoding is needed. Safe to
/// call only after `isResponseSafeString`/`isResponseSafeByte` have
/// validated every character is in `[32, 126]`.
func asciiStringToBytes(s: in String): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < s.length {
    match charAt(s, i) {
      case None -> ()
      case Some(c) -> acc.add(toInt(c).toByte())
    }
    i = i + 1
  }
  acc.toArray()
}

/// Serialize a response status line + headers + terminating blank line.
/// Does not write a body — for a fixed-length body, write
/// `serializeFixedLengthBody`'s (identity) output after this; for a
/// chunked body, follow with `serializeChunk` calls and a final
/// `serializeLastChunk`. The caller decides whether to add a `Connection`
/// header based on `shouldClose`/its own policy — this function only
/// formats whatever `headers` it is given.
///
/// # Contract
/// `reason` and every header name/value must be free of control characters
/// (`[32, 126]` only) — this is a programmer-facing misuse guard against
/// response splitting (see `isResponseSafeByte`'s doc comment), not a
/// wire-content condition, since this side of the engine is never fed
/// untrusted network bytes directly.
@experimental
pub func serializeResponseHead(
  version: in HttpVersion, status: in Int, reason: in String, headers: in List[HeaderField]
): slice[Byte]
  requires: reason.length > 0
  requires: isResponseSafeString(reason)
  requires: allHeadersResponseSafe(headers)
{
  var acc = httpVersionToken(version) + " " + toString(status) + " " + reason + "\r\n"
  var i = 0
  while i < headers.count {
    val h = headers[i]
    acc = acc + h.name + ": " + h.value + "\r\n"
    i = i + 1
  }
  acc = acc + "\r\n"
  asciiStringToBytes(acc)
}

/// Identity by design: a fixed-length body needs no wire framing beyond the
/// `Content-Length` header already written by `serializeResponseHead` — the
/// bytes are written to the transport exactly as given. Exists so the
/// fixed-length and chunked body-writing APIs are named symmetrically.
@pure
@experimental
pub func serializeFixedLengthBody(bytes: in slice[Byte]): slice[Byte] {
  bytes
}

/// One chunked-transfer-coding chunk: a lowercase-hex size line, CRLF, the
/// payload, CRLF (RFC 9112 section 7.1). Never emit a zero-length chunk
/// through this function — use `serializeLastChunk` to terminate the
/// stream.
///
/// # Contract
/// `bytes` must be non-empty — a zero-length chunk is the stream
/// terminator, produced only by `serializeLastChunk`.
@experimental
pub func serializeChunk(bytes: in slice[Byte]): slice[Byte]
  requires: bytes.length > 0
{
  val sizeLine = toHexAscii(bytes.length)
  val head = asciiStringToBytes(sizeLine + "\r\n")
  val tail = asciiStringToBytes("\r\n")
  head.concat(bytes).concat(tail)
}

/// The terminating zero-length chunk with no trailers: `"0\r\n\r\n"`.
@pure
@experimental
pub func serializeLastChunk(): slice[Byte] {
  asciiStringToBytes("0\r\n\r\n")
}

func hexDigitChar(v: in Int): Char {
  if v < 10 {
    Char.fromInt(48 + v)
  } else {
    Char.fromInt(97 + (v - 10))
  }
}

/// Lowercase hex, no leading zeros (except for `0` itself), no `0x`
/// prefix — the wire form of a chunk-size line.
func toHexAscii(n: in Int): String {
  if n == 0 {
    "0"
  } else {
    var acc = ""
    var v = n
    while v > 0 {
      acc = ("" + hexDigitChar(v % 16)) + acc
      v = v / 16
    }
    acc
  }
}
