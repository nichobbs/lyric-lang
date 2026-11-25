//! Grpc.Wire — the gRPC-over-HTTP/2 wire format, shared by the pure-Lyric
//! client (`Grpc.Client`) and the pure-Lyric h2c server (docs/72 section 4.2,
//! slice 6, D802).
//!
//! Everything here is a pure function or a plain value over bytes and header
//! lists, so one definition serves dotnet and the JVM and is tested without a
//! socket:
//!
//!   - length-prefixed messages (`frameMessage`, and `MessageReader`, which
//!     reassembles messages that span DATA frames or share one and refuses a
//!     message over a size limit as soon as its prefix is read),
//!   - `grpc-timeout` encoding (`encodeTimeout`),
//!   - `grpc-encoding: gzip` over `Std.Zip` with bounded output
//!     (`compressMessage`, `decompressMessage`),
//!   - the status mapping tables: an HTTP status without `grpc-status`
//!     (`statusFromHttpStatus`), an HTTP/2 stream failure (`statusFromFailure`)
//!     and a `grpc-status` / `grpc-message` field pair (`statusFromFields`).
@pure
package Grpc.Wire

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Parse
import Std.Zip as Zip
import Std.HttpEngine
import Std.HttpEngine.H2Frame
import Std.HttpEngine.H2Client
import Grpc.Types

// ─── Messages ────────────────────────────────────────────────────────────────
/// The most a message prefix can announce: the length is an unsigned 32-bit
/// value.
pub func maxFramedLength(): Long {
  4294967295i64
}

/// One length-prefixed message (gRPC over HTTP/2, "Length-Prefixed-Message"):
/// a compressed flag (0 or 1), the payload length as 4 big-endian bytes, then
/// the payload.
pub func frameMessage(payload: in slice[Byte], compressed: in Bool): slice[Byte]
  requires: payload.length >= 0
  ensures: result.length == payload.length + 5
{
  val n = payload.length
  val acc: List[Byte] = newListWithCapacity(n + 5)
  acc.add(if compressed { 1.toByte() } else { 0.toByte() })
  acc.add(n.shr(24).and(255).toByte())
  acc.add(n.shr(16).and(255).toByte())
  acc.add(n.shr(8).and(255).toByte())
  acc.add(n.and(255).toByte())
  var i = 0
  while i < n {
    acc.add(payload[i])
    i = i + 1
  }
  acc.toArray()
}

/// What `readerPoll` found at the front of the reader.
///
///   - `WireMessage`: one whole message (still compressed when `compressed`).
///   - `WireNeedMore`: the buffered bytes end inside a prefix or a payload.
///   - `WireTooLarge`: the prefix announces `length` bytes, over the reader's
///     limit; nothing was buffered for it and the reader must be discarded.
///   - `WireBadFlag`: the compressed flag is neither 0 nor 1 (a corrupt or
///     non-gRPC stream); the reader must be discarded.
pub union WireRead {
  case WireMessage(compressed: Bool, payload: slice[Byte])
  case WireNeedMore
  case WireTooLarge(length: Long)
  case WireBadFlag(flag: Int)
}

/// Reassembles length-prefixed messages from the DATA chunks of one HTTP/2
/// stream. Chunks are kept as received and copied once, into the message that
/// completes them, so a message that spans many frames costs one pass over its
/// bytes. `maxMessageBytes` bounds a single message's payload.
pub ref record MessageReader {
  chunks: List[slice[Byte]]
  var first: Int
  var offset: Int
  var buffered: Int
  maxMessageBytes: Int
}

/// An empty reader that refuses messages over `maxMessageBytes`.
pub func newMessageReader(maxMessageBytes: in Int): MessageReader
  requires: maxMessageBytes >= 0
{
  MessageReader(chunks = newList(), first = 0, offset = 0, buffered = 0, maxMessageBytes = maxMessageBytes)
}

/// Append received DATA bytes.
pub func readerFeed(r: in MessageReader, data: in slice[Byte]): Unit {
  if data.length > 0 {
    r.chunks.add(data)
    r.buffered = r.buffered + data.length
  }
}

/// How many bytes are buffered and not yet part of a returned message. Zero at
/// the end of a well-formed stream; anything else there is a truncated message.
pub func readerBuffered(r: in MessageReader): Int {
  r.buffered
}

func readerByteAt(r: in MessageReader, k: in Int): Int {
  var idx = r.first
  var pos = r.offset + k
  while idx < r.chunks.count {
    val c = r.chunks[idx]
    if pos < c.length {
      return c[pos].toInt()
    }
    pos = pos - c.length
    idx = idx + 1
  }
  0
}

func readerTake(r: in MessageReader, n: in Int): slice[Byte] {
  val acc2: List[Byte] = newListWithCapacity(n)
  var need = n
  while need > 0 {
    val c = r.chunks[r.first]
    val avail = c.length - r.offset
    var take = need
    if take > avail {
      take = avail
    }
    var i = 0
    while i < take {
      acc2.add(c[r.offset + i])
      i = i + 1
    }
    need = need - take
    r.buffered = r.buffered - take
    if take == avail {
      r.first = r.first + 1
      r.offset = 0
    } else {
      r.offset = r.offset + take
    }
  }
  if r.first >= r.chunks.count {
    r.chunks.clear()
    r.first = 0
  } else if r.first >= 64 {
    val rest: List[slice[Byte]] = newList()
    var j = r.first
    while j < r.chunks.count {
      rest.add(r.chunks[j])
      j = j + 1
    }
    r.chunks.clear()
    var k = 0
    while k < rest.count {
      r.chunks.add(rest[k])
      k = k + 1
    }
    r.first = 0
  }
  acc2.toArray()
}

/// Take the next whole message off the front of the reader, if the buffered
/// bytes hold one. Call it until it returns `WireNeedMore`: one chunk may hold
/// several messages.
pub func readerPoll(r: in MessageReader): WireRead {
  if r.buffered < 5 {
    return WireNeedMore
  }
  val flag = readerByteAt(r, 0)
  if flag != 0 and flag != 1 {
    return WireBadFlag(flag = flag)
  }
  val length = readerByteAt(r, 1).toLong().shl(24).or(readerByteAt(r, 2).toLong().shl(16)).or(readerByteAt(r, 3).toLong().shl(8)).or(
    readerByteAt(r, 4).toLong()
  )
  if length > r.maxMessageBytes.toLong() {
    return WireTooLarge(length = length)
  }
  val n = length.toInt()
  if r.buffered < 5 + n {
    return WireNeedMore
  }
  val _ = readerTake(r, 5)
  val payload = readerTake(r, n)
  WireMessage(compressed = flag == 1, payload = payload)
}

// ─── Compression ─────────────────────────────────────────────────────────────
/// `payload` as a gzip member (`grpc-encoding: gzip`).
pub func compressMessage(payload: in slice[Byte]): slice[Byte] {
  Zip.gzipEncode(payload)
}

/// The message a compressed frame carries, for the response's `grpc-encoding`.
/// Only `gzip` is implemented. The output is bounded by `maxBytes`, so a
/// decompression bomb is `ResourceExhausted` before it is expanded; a body
/// that is not valid gzip is `Internal`; an encoding this library does not
/// implement is `Unimplemented`; a compressed flag with no encoding (or
/// `identity`) is `Internal`.
pub func decompressMessage(
  encoding: in String, payload: in slice[Byte], maxBytes: in Int
): Result[slice[Byte], GrpcStatus]
  requires: maxBytes >= 0
{
  val enc = Str.toLower(encoding)
  if enc == "gzip" or enc == "x-gzip" {
    match Zip.gzipDecode(payload, maxBytes) {
      case Ok(bytes) -> Ok(value = bytes)
      case Err(Zip.LimitExceeded(_)) -> Err(
        error = GrpcStatus(
          code = GrpcStatusCode.ResourceExhausted,
          message = "decompressed message is larger than the limit of " +
            maxBytes.toString() +
            " bytes"
        )
      )
      case Err(e) -> Err(
        error = GrpcStatus(
          code = GrpcStatusCode.Internal,
          message = "failed to decompress the gzip message: " + Zip.zipErrorMessage(e)
        )
      )
    }
  } else if enc == "" or enc == "identity" {
    Err(
      error = GrpcStatus(
        code = GrpcStatusCode.Internal,
        message = "a message is flagged compressed but the call has no grpc-encoding"
      )
    )
  } else {
    Err(
      error = GrpcStatus(
        code = GrpcStatusCode.Unimplemented,
        message = "unsupported grpc-encoding '" + encoding + "' (supported: identity, gzip)"
      )
    )
  }
}

// ─── Deadlines ───────────────────────────────────────────────────────────────
/// The `grpc-timeout` header value for a deadline `ms` milliseconds away: an
/// integer of at most 8 digits and a unit, rounded up to the next unit that
/// fits (`m`, `S`, `M`, `H`).
pub func encodeTimeout(ms: in Int): String
  requires: ms >= 1
{
  if ms <= 99999999 {
    return ms.toString() + "m"
  }
  val secs = ms / 1000 + (if ms % 1000 > 0 { 1 } else { 0 })
  if secs <= 99999999 {
    return secs.toString() + "S"
  }
  val mins = secs / 60 + (if secs % 60 > 0 { 1 } else { 0 })
  if mins <= 99999999 {
    return mins.toString() + "M"
  };
  (mins / 60 + (if mins % 60 > 0 { 1 } else { 0 })).toString() + "H"
}

// ─── Content type ────────────────────────────────────────────────────────────
/// True when `contentType` is `application/grpc` or one of its `+suffix` or
/// `;parameter` forms (`application/grpc+proto`, `application/grpc; charset=`).
pub func isGrpcContentType(contentType: in String): Bool {
  val ct = Str.toLower(contentType)
  ct == "application/grpc" or Str.startsWith(ct, "application/grpc+") or Str.startsWith(ct, "application/grpc;")
}

// ─── Status mapping ──────────────────────────────────────────────────────────
/// The gRPC status for an HTTP response that carries no `grpc-status` (gRPC over
/// HTTP/2, "HTTP to gRPC Status Code Mapping"): 400 `Internal`, 401
/// `Unauthenticated`, 403 `PermissionDenied`, 404 `Unimplemented`, 429, 502,
/// 503 and 504 `Unavailable`, anything else `Unknown`.
pub func statusFromHttpStatus(httpStatus: in Int): GrpcStatus {
  val code = match httpStatus {
    case 400 -> GrpcStatusCode.Internal
    case 401 -> GrpcStatusCode.Unauthenticated
    case 403 -> GrpcStatusCode.PermissionDenied
    case 404 -> GrpcStatusCode.Unimplemented
    case 429 -> GrpcStatusCode.Unavailable
    case 502 -> GrpcStatusCode.Unavailable
    case 503 -> GrpcStatusCode.Unavailable
    case 504 -> GrpcStatusCode.Unavailable
    case _ -> GrpcStatusCode.Unknown
  }
  GrpcStatus(code = code, message = "unexpected HTTP status " + httpStatus.toString())
}

/// The gRPC status for a call that ended without a `grpc-status` because the
/// HTTP/2 stream or connection failed. RST_STREAM codes follow the gRPC
/// HTTP/2 mapping: `NO_ERROR` (the stream closed without a status),
/// `PROTOCOL_ERROR`, `INTERNAL_ERROR`, `FLOW_CONTROL_ERROR`, `SETTINGS_TIMEOUT`,
/// `STREAM_CLOSED`, `FRAME_SIZE_ERROR`, `COMPRESSION_ERROR`, `CONNECT_ERROR`
/// and anything unknown are `Internal`; `REFUSED_STREAM` is `Unavailable`
/// (the call never ran); `CANCEL` is `Cancelled`; `ENHANCE_YOUR_CALM` is
/// `ResourceExhausted`; `INADEQUATE_SECURITY` is `PermissionDenied`. A lost
/// connection, a refused or unprocessed stream is `Unavailable`, a deadline
/// `DeadlineExceeded`, a local cancel `Cancelled`, a protocol error
/// `Internal`.
pub func statusFromFailure(f: in H2CallFailure): GrpcStatus {
  match f {
    case H2FailDeadlineExceeded -> GrpcStatus(code = GrpcStatusCode.DeadlineExceeded, message = "deadline exceeded")
    case H2FailCancelled -> GrpcStatus(code = GrpcStatusCode.Cancelled, message = "call cancelled")
    case H2FailRefused -> GrpcStatus(
      code = GrpcStatusCode.Unavailable,
      message = "stream refused by the server (REFUSED_STREAM)"
    )
    case H2FailUnprocessed -> GrpcStatus(
      code = GrpcStatusCode.Unavailable,
      message = "the server did not process the call (GOAWAY)"
    )
    case H2FailConnectionLost(m) -> GrpcStatus(code = GrpcStatusCode.Unavailable, message = "connection lost: " + m)
    case H2FailProtocol(_, m) -> GrpcStatus(code = GrpcStatusCode.Internal, message = "HTTP/2 protocol error: " + m)
    case H2FailReset(code) -> statusFromReset(code)
  }
}

func statusFromReset(code: in H2ErrorCode): GrpcStatus {
  match code {
    case H2NoError -> GrpcStatus(
      code = GrpcStatusCode.Internal,
      message = "the stream was closed without a grpc-status (NO_ERROR)"
    )
    case H2RefusedStream -> GrpcStatus(
      code = GrpcStatusCode.Unavailable,
      message = "stream refused by the server (REFUSED_STREAM)"
    )
    case H2Cancel -> GrpcStatus(code = GrpcStatusCode.Cancelled, message = "the server cancelled the stream")
    case H2EnhanceYourCalm -> GrpcStatus(
      code = GrpcStatusCode.ResourceExhausted,
      message = "the server asked the client to slow down (ENHANCE_YOUR_CALM)"
    )
    case H2InadequateSecurity -> GrpcStatus(
      code = GrpcStatusCode.PermissionDenied,
      message = "the connection's security is inadequate (INADEQUATE_SECURITY)"
    )
    case _ -> GrpcStatus(
      code = GrpcStatusCode.Internal,
      message = "the stream was reset by the server, HTTP/2 error code " + errorCodeToLong(code).toString()
    )
  }
}

func fieldValue(fields: in List[HeaderField], name: in String): Option[String] {
  for f in fields {
    if f.name == name {
      return Some(value = f.value)
    }
  }
  None
}

/// The first value of header `name` (lowercase), or `""`.
pub func headerOrEmpty(fields: in List[HeaderField], name: in String): String {
  match fieldValue(fields, name) {
    case Some(v) -> v
    case None -> ""
  }
}

/// The status a header block carries: `None` when it has no `grpc-status`,
/// otherwise `grpc-status` with the percent-decoded `grpc-message`. A value that
/// is not an integer is `Internal`; an integer outside the 17 codes is
/// `Unknown` (as `statusCodeFromInt` maps it).
pub func statusFromFields(fields: in List[HeaderField]): Option[GrpcStatus] {
  match fieldValue(fields, "grpc-status") {
    case None -> None
    case Some(raw) -> {
      val message = decodeGrpcMessage(headerOrEmpty(fields, "grpc-message"))
      match tryParseInt(Str.trim(raw)) {
        case Ok(n) -> Some(value = GrpcStatus(code = statusCodeFromInt(n), message = message))
        case Err(_) -> Some(
          value = GrpcStatus(
            code = GrpcStatusCode.Internal,
            message = "invalid grpc-status value '" + raw + "'" +
              if message == "" { "" } else { ": " + message }
          )
        )
      }
    }
  }
}
