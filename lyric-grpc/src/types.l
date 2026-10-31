//! Platform-neutral gRPC client types.
//!
//! Consumers open a GrpcChannel to a server address, make RPC calls passing
//! raw slice[Byte] payloads, and receive raw slice[Byte] responses.
//! The gRPC status code and message are surfaced via GrpcStatus on error.
@pure
package Grpc.Types

import Std.Core
import Std.String as Str
import Std.Char as Ch
import Std.Encoding
import Std.Collections

// ─── Channel ─────────────────────────────────────────────────────────────────
/// An open gRPC channel to a single server address.
/// Created by Grpc.openChannel; released by Grpc.closeChannel.
/// Channels are safe to share across calls but are not automatically closed.
///
/// Representation: an opaque type's body is only constructible inside its
/// defining package (this one), but the live handle (an `HttpClient` on
/// .NET, something else on JVM) is owned by the platform kernel package —
/// a *different* package. Rather than leak a platform-specific extern type
/// into this neutral package (which would break the other target's build),
/// the kernel keeps the live handle in its own registry keyed by a plain
/// `Int` (the same `HandleCounter`-allocated-id idiom `lyric-ws` /
/// `lyric-jobs` / `lyric-mq` kernels already use), and this type just wraps
/// that key. `wrapChannelHandle` / `channelHandleId` are the "authoring
/// functions" the language reference (docs/01 §2.8) calls for, reachable
/// from `Grpc.Kernel.Net` / `Grpc.Kernel.Jvm` (same project).
pub opaque type GrpcChannel {
  handle: Int
}

/// Wrap a platform kernel's registry key as a `GrpcChannel`. Kernel-only —
/// `internal` (docs/01-language-reference.md §3.1: cross-package-within-
/// project visible), not `pub` (#6580: a same-project qualified cross-
/// package call to an `internal` function used to fail T0020 "unknown
/// name" — a bridge-level item-visibility bug, not a type-checker one;
/// fixed by threading `pub`-OR-`internal` visibility into a project's own
/// sibling-package item collection). Callers must use qualified syntax
/// (`Types.wrapChannelHandle(id)`), not UFCS (`id.wrapChannelHandle()`):
/// general free-function-via-receiver-dot-syntax is not a supported Lyric
/// construct at all (confirmed via #6580 follow-up investigation — a
/// record receiver rejects it at compile time with T0113, "no method ...
/// on type ..."; only the D037 dot-named-method form, `func Type.method`,
/// is real UFCS and already works cross-package). Qualified syntax is
/// simply the correct spelling here, not a workaround for a bug.
internal func wrapChannelHandle(id: in Int): GrpcChannel {
  GrpcChannel(handle = id)
}

/// Recover the platform kernel's registry key from a `GrpcChannel`.
/// Kernel-only — see `wrapChannelHandle`'s doc comment.
internal func channelHandleId(ch: in GrpcChannel): Int {
  ch.handle
}

// ─── Status codes ────────────────────────────────────────────────────────────
/// Canonical gRPC status codes (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
pub enum GrpcStatusCode {
  case Ok
  // 0 — not an error
  case Cancelled
  // 1 — caller cancelled the operation
  case Unknown
  // 2 — unknown error
  case InvalidArgument
  // 3 — client sent an invalid argument
  case DeadlineExceeded
  // 4 — deadline expired before operation completed
  case NotFound
  // 5 — entity not found
  case AlreadyExists
  // 6 — entity already exists
  case PermissionDenied
  // 7 — caller lacks permission
  case ResourceExhausted
  // 8 — resource quota exhausted
  case FailedPrecondition
  // 9 — system not in required state
  case Aborted
  // 10 — operation aborted
  case OutOfRange
  // 11 — operation out of valid range
  case Unimplemented
  // 12 — method not implemented on server
  case Internal
  // 13 — internal invariant violated
  case Unavailable
  // 14 — service currently unavailable
  case DataLoss
  // 15 — unrecoverable data loss or corruption
  case Unauthenticated
  // 16 — caller is not authenticated
}

/// Map an integer gRPC status code to GrpcStatusCode.
pub func statusCodeFromInt(n: Int): GrpcStatusCode {
  match n {
    case 0 -> GrpcStatusCode.Ok
    case 1 -> GrpcStatusCode.Cancelled
    case 2 -> GrpcStatusCode.Unknown
    case 3 -> GrpcStatusCode.InvalidArgument
    case 4 -> GrpcStatusCode.DeadlineExceeded
    case 5 -> GrpcStatusCode.NotFound
    case 6 -> GrpcStatusCode.AlreadyExists
    case 7 -> GrpcStatusCode.PermissionDenied
    case 8 -> GrpcStatusCode.ResourceExhausted
    case 9 -> GrpcStatusCode.FailedPrecondition
    case 10 -> GrpcStatusCode.Aborted
    case 11 -> GrpcStatusCode.OutOfRange
    case 12 -> GrpcStatusCode.Unimplemented
    case 13 -> GrpcStatusCode.Internal
    case 14 -> GrpcStatusCode.Unavailable
    case 15 -> GrpcStatusCode.DataLoss
    case 16 -> GrpcStatusCode.Unauthenticated
    case _ -> GrpcStatusCode.Unknown
  }
}

/// A gRPC call result status (code + human-readable message).
pub record GrpcStatus {
  code: GrpcStatusCode
  message: String
}

/// A metadata key-value pair (sent as gRPC request headers).
pub record GrpcMetadataEntry {
  key: String
  value: String
  // ─── Call options ─────────────────────────────────────────────────────────────
}

/// Per-call options.
pub record GrpcCallOptions {
  timeoutMs: Option[Int]
  metadata: slice[GrpcMetadataEntry]
  // ─── Server-streaming response ────────────────────────────────────────────────
}

/// A lazy sequence of server-streaming response messages.
/// Call nextMessage() repeatedly until it returns None (end of stream) or Err.
/// Same registry-key representation as `GrpcChannel`; see its doc comment.
pub opaque type GrpcStream {
  handle: Int
}

/// Wrap a platform kernel's registry key as a `GrpcStream`. Kernel-only.
internal func wrapStreamHandle(id: in Int): GrpcStream {
  GrpcStream(handle = id)
}

/// Recover the platform kernel's registry key from a `GrpcStream`. Kernel-only.
internal func streamHandleId(s: in GrpcStream): Int {
  s.handle
}

/// A handle to a running gRPC server.
/// Created by Grpc.startHandle; passed to Grpc.stop for graceful shutdown.
/// Same registry-key representation as `GrpcChannel`; see its doc comment.
pub opaque type GrpcServerHandle {
  handle: Int
}

/// Wrap a platform kernel's registry key as a `GrpcServerHandle`. Kernel-only.
internal func wrapServerHandle(id: in Int): GrpcServerHandle {
  GrpcServerHandle(handle = id)
}

/// Recover the platform kernel's registry key from a `GrpcServerHandle`. Kernel-only.
internal func serverHandleId(h: in GrpcServerHandle): Int {
  h.handle
}

// ─── Server routing ───────────────────────────────────────────────────────────
/// The code of a `GrpcStatusCode`, the inverse of `statusCodeFromInt`.
pub func statusCodeToInt(code: in GrpcStatusCode): Int {
  match code {
    case GrpcStatusCode.Ok -> 0
    case GrpcStatusCode.Cancelled -> 1
    case GrpcStatusCode.Unknown -> 2
    case GrpcStatusCode.InvalidArgument -> 3
    case GrpcStatusCode.DeadlineExceeded -> 4
    case GrpcStatusCode.NotFound -> 5
    case GrpcStatusCode.AlreadyExists -> 6
    case GrpcStatusCode.PermissionDenied -> 7
    case GrpcStatusCode.ResourceExhausted -> 8
    case GrpcStatusCode.FailedPrecondition -> 9
    case GrpcStatusCode.Aborted -> 10
    case GrpcStatusCode.OutOfRange -> 11
    case GrpcStatusCode.Unimplemented -> 12
    case GrpcStatusCode.Internal -> 13
    case GrpcStatusCode.Unavailable -> 14
    case GrpcStatusCode.DataLoss -> 15
    case GrpcStatusCode.Unauthenticated -> 16
  }
}

/// A server-side RPC handler. Both kinds receive the single request message
/// (raw protobuf bytes) and the request metadata (lowercase keys; HTTP/2
/// pseudo-headers and the reserved `content-type`, `te`, `user-agent` and
/// `grpc-*` headers are not included).
///
///   - `Unary` returns the one response message, or the status to fail with.
///   - `ServerStreaming` sends each response message through `emit`, which
///     returns `false` once the client has cancelled or gone away (stop
///     producing then), and returns `Ok(())` to finish the call or the status
///     to fail it with after the messages already sent.
///
/// A handler that panics fails its call with `Internal`; it never takes the
/// server down.
pub union GrpcHandler {
  case Unary(handle: (slice[Byte], slice[GrpcMetadataEntry]) -> Result[slice[Byte], GrpcStatus])
  case ServerStreaming(handle: (slice[Byte], slice[GrpcMetadataEntry], (slice[Byte]) -> Bool) -> Result[Unit, GrpcStatus])
}

/// One registered RPC method: proto service name, proto method name, handler.
pub record GrpcRoute {
  service: String
  method: String
  handler: GrpcHandler
}

/// Immutable registry of gRPC routes; built with `Grpc.addUnary` /
/// `Grpc.addServerStreaming`, passed to `Grpc.start` / `Grpc.startHandle`.
pub record ServiceRegistry {
  routes: slice[GrpcRoute]
}

/// The registered route for `service` / `method`, if any.
pub func findRoute(registry: in ServiceRegistry, service: in String, method: in String): Option[GrpcRoute] {
  for r in registry.routes {
    if r.service == service and r.method == method {
      return Some(value = r)
    }
  }
  None
}

/// Encode a `grpc-message` trailer value: percent-encode `%` and every UTF-8
/// byte outside printable ASCII (the gRPC HTTP/2 spec).
pub func encodeGrpcMessage(message: in String): String {
  val sb = Str.StringBuilder.new()
  for b in encodeUtf8(message) {
    val n = b.toInt()
    if n >= 32 and n <= 126 and n != 37 {
      Str.StringBuilder.appendChar(sb, Ch.fromInt(n))
    } else {
      val one: slice[Byte] = [b]
      Str.StringBuilder.append(sb, "%" + Str.toUpper(encodeHex(one)))
    }
  }
  Str.StringBuilder.toString(sb)
}

/// The inverse of `encodeGrpcMessage`; a malformed escape is kept literally.
pub func decodeGrpcMessage(encoded: in String): String {
  if Str.indexOfRaw(encoded, "%") < 0 {
    return encoded
  }
  val bytes: List[Byte] = newList()
  var i = 0
  while i < encoded.length {
    val c = Str.substring(encoded, i, 1)
    if c == "%" and i + 2 < encoded.length {
      match tryDecodeHex(Str.substring(encoded, i + 1, 2)) {
        case Some(h) -> {
          bytes.add(h[0])
          i = i + 3
        }
        case None -> {
          for b in encodeUtf8(c) {
            bytes.add(b)
          }
          i = i + 1
        }
      }
    } else {
      for b in encodeUtf8(c) {
        bytes.add(b)
      }
      i = i + 1
    }
  }
  match tryDecodeUtf8(bytes.toArray()) {
    case Some(s) -> s
    case None -> encoded
  }
}

// ─── Host-exception mapping ───────────────────────────────────────────────────
func statusCodeFromName(name: in String): GrpcStatusCode {
  // Accepts both gRPC-dotnet's PascalCase ("DeadlineExceeded") and
  // grpc-java's UPPER_SNAKE ("DEADLINE_EXCEEDED") spelling.
  val key = Str.toLower(Str.replace(name, "_", ""))
  match key {
    case "ok" -> GrpcStatusCode.Ok
    case "cancelled" -> GrpcStatusCode.Cancelled
    case "canceled" -> GrpcStatusCode.Cancelled
    case "unknown" -> GrpcStatusCode.Unknown
    case "invalidargument" -> GrpcStatusCode.InvalidArgument
    case "deadlineexceeded" -> GrpcStatusCode.DeadlineExceeded
    case "notfound" -> GrpcStatusCode.NotFound
    case "alreadyexists" -> GrpcStatusCode.AlreadyExists
    case "permissiondenied" -> GrpcStatusCode.PermissionDenied
    case "resourceexhausted" -> GrpcStatusCode.ResourceExhausted
    case "failedprecondition" -> GrpcStatusCode.FailedPrecondition
    case "aborted" -> GrpcStatusCode.Aborted
    case "outofrange" -> GrpcStatusCode.OutOfRange
    case "unimplemented" -> GrpcStatusCode.Unimplemented
    case "internal" -> GrpcStatusCode.Internal
    case "unavailable" -> GrpcStatusCode.Unavailable
    case "dataloss" -> GrpcStatusCode.DataLoss
    case "unauthenticated" -> GrpcStatusCode.Unauthenticated
    case _ -> GrpcStatusCode.Unknown
  }
}

func isStatusCodeName(s: in String): Bool {
  var i = 0
  if s.length == 0 {
    return false
  }
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    val upper = c >= 65 and c <= 90
    val lower = c >= 97 and c <= 122
    if not (upper or lower or c == 95) {
      return false
    }
    i = i + 1
  }
  true
}

/// Map a caught host exception to a `GrpcStatus`. `typeName` and `message` are
/// the caught `Bug`'s fields. gRPC-dotnet's `RpcException.Message` is
/// documented as `Status(StatusCode="Unavailable", Detail="...")` and
/// grpc-java's `StatusRuntimeException.getMessage()` as
/// `UNAVAILABLE: description`; any other exception (or an unrecognised
/// message) is `Unknown` carrying the whole message, never a silent success.
pub func statusFromException(typeName: in String, message: in String): GrpcStatus {
  val dotnetPrefix = "Status(StatusCode=\""
  val dotnetAt = Str.indexOfRaw(message, dotnetPrefix)
  if dotnetAt >= 0 {
    val rest = Str.substring(message, dotnetAt + dotnetPrefix.length)
    val close = Str.indexOfRaw(rest, "\"")
    if close > 0 {
      val code = statusCodeFromName(Str.substring(rest, 0, close))
      val detailMarker = "Detail=\""
      val d = Str.indexOfRaw(rest, detailMarker)
      if d >= 0 {
        var detail = Str.substring(rest, d + detailMarker.length)
        // The detail ends at the closing quote of `Detail="..."`: either
        // `", DebugException=...` or the `")` that closes `Status(...)`
        // (a task's `AggregateException` wraps it in a further `)`).
        val debugAt = Str.indexOfRaw(detail, "\", DebugException=")
        val closeAt = Str.indexOfRaw(detail, "\")")
        var cut = detail.length
        if debugAt >= 0 {
          cut = debugAt
        }
        if closeAt >= 0 and closeAt < cut {
          cut = closeAt
        }
        detail = Str.substring(detail, 0, cut)
        return GrpcStatus(code = code, message = detail)
      }
      return GrpcStatus(code = code, message = message)
    }
  }
  val sep = Str.indexOfRaw(message, ": ")
  val head = if sep > 0 { Str.substring(message, 0, sep) } else { message }
  if isStatusCodeName(head) and (sep > 0 or Str.toUpper(head) == head) {
    val code = statusCodeFromName(head)
    if code != GrpcStatusCode.Unknown or Str.toLower(head) == "unknown" {
      val detail = if sep > 0 { Str.substring(message, sep + 2) } else { "" }
      return GrpcStatus(code = code, message = detail)
    }
  }
  GrpcStatus(code = GrpcStatusCode.Unknown, message = typeName + ": " + message)
}

func metadataEscape(s: in String): String {
  Str.replace(Str.replace(Str.replace(s, "%", "%25"), ",", "%2C"), ":", "%3A")
}

/// Encode metadata as the `key:value,key:value` string the kernels exchange
/// (`%`, `,` and `:` percent-escaped); the inverse of `decodeMetadata`.
pub func encodeMetadata(entries: in slice[GrpcMetadataEntry]): String {
  val parts: List[String] = newList()
  for e in entries {
    parts.add(metadataEscape(e.key) + ":" + metadataEscape(e.value))
  }
  Str.joinList(",", parts)
}

func metadataUnescape(s: in String): String {
  Str.replace(Str.replace(Str.replace(s, "%3A", ":"), "%2C", ","), "%25", "%")
}

/// Decode the `key:value,key:value` metadata string `Grpc.callUnary` hands a
/// kernel (`%25`, `%2C`, `%3A` escape `%`, `,`, `:`); the inverse of
/// `Grpc.metadataString`. An entry without a `:` is dropped.
pub func decodeMetadata(metadata: in String): slice[GrpcMetadataEntry] {
  val entries: List[GrpcMetadataEntry] = newList()
  if metadata.length == 0 {
    return entries.toArray()
  }
  for part in Str.split(metadata, ",") {
    val c = Str.indexOfRaw(part, ":")
    if c > 0 {
      entries.add(
        GrpcMetadataEntry(
          key = metadataUnescape(Str.substring(part, 0, c)),
          value = metadataUnescape(Str.substring(part, c + 1))
        )
      )
    }
  }
  entries.toArray()
}

// ─── Channel addresses ────────────────────────────────────────────────────────
/// A parsed `http://host:port` / `https://host:port` channel address.
pub record GrpcAddress {
  secure: Bool
  authority: String
}

/// Validate a channel address: `http://` or `https://`, then a non-empty
/// `host[:port]` authority with no whitespace and no path, query or fragment.
/// grpc-java addresses a server by `host:port` target (the scheme only picks
/// plaintext or TLS), so the JVM kernel validates with this before building a
/// channel; `GrpcChannel.ForAddress` does its own URI validation on .NET.
pub func parseAddress(address: in String): Result[GrpcAddress, String] {
  var secure = false
  var rest = ""
  if Str.startsWith(address, "https://") {
    secure = true
    rest = Str.substring(address, 8)
  } else if Str.startsWith(address, "http://") {
    rest = Str.substring(address, 7)
  } else {
    return Err("gRPC address must start with http:// or https://: " + address)
  }
  if rest.length == 0 {
    return Err("gRPC address has no host: " + address)
  }
  if Str.endsWith(rest, "/") {
    rest = Str.substring(rest, 0, rest.length - 1)
  }
  var i = 0
  while i < rest.length {
    val c = Str.codeUnitAt(rest, i)
    if c <= 32 or c == 47 or c == 63 or c == 35 {
      return Err("gRPC address must be scheme://host[:port] with no path, query or whitespace: " + address)
    }
    i = i + 1
  }
  if Str.startsWith(rest, ":") {
    return Err("gRPC address has no host: " + address)
  }
  Ok(GrpcAddress(secure = secure, authority = rest))
}
