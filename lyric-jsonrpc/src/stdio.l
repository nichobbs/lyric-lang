//! src/stdio.l — JsonRpc.Stdio: NDJSON and Content-Length stdio framings.
//!
//! Two `RpcTransport` implementations over this process's stdin/stdout:
//!
//!   - `NdjsonTransport`        — one JSON message per `\n`-terminated line
//!     (the MCP stdio transport). `writeValue` is always compact (see
//!     `JsonRpc.Json`), so an outbound message never contains an embedded
//!     newline that would corrupt the framing.
//!   - `ContentLengthTransport` — `Content-Length: N\r\n\r\n` + N bytes (the
//!     LSP framing), byte-accurate on UTF-8.
//!
//! **Inbound framing is byte-level.** Both transports read raw stdin bytes
//! through the `ByteSource` seam (production: `Std.Console`'s
//! `StdinReader`) into a `FrameBuffer`, and cut frames out of it:
//! `ndjsonReceiveFrom` at each `\n` byte, `clReceiveFrom` after exactly the
//! declared number of body bytes. A message is decoded as UTF-8 only once it
//! is complete, so the Content-Length count is exact by construction.
//! `receiveWithin` (#7451) gives each wait for more bytes only the time left
//! before its deadline; when it runs out, the bytes read so far stay in the
//! `FrameBuffer`, so a message that straddles a timeout is returned whole by
//! the next receive, never split or dropped.
//!
//! The character- and line-level cores (`clReceiveVia`/`ndjsonReceiveVia`
//! over the `CharReader`/`LineReader` seams, and `clSendVia`/`ndjsonSendVia`)
//! remain for callers that frame other streams: `Mcp.Stdio` reuses
//! `ndjsonReceiveVia` over a child process's piped stdout. `clReceiveVia`
//! reads UTF-16 code units and tracks the UTF-8 byte length of each one (or
//! of each surrogate pair), so its body read also stops at the exact byte the
//! peer declared.
//!
//! All of it is sans-IO: the framing logic is parameterized over the small
//! `ByteSource`/`CharReader`/`LineReader`/`StringWriter`/`LineWriter`
//! interfaces rather than calling the console directly, so
//! `tests/stdio_tests.l` drives it against in-memory stand-ins with no real
//! pipe. This is deliberately an interface seam, not a stored `() -> Int` /
//! `(String) -> Unit` closure parameter: a closure argument passed *across a
//! package boundary* on the current self-hosted JVM backend is wrapped in a
//! lambda-adapter class scoped to the *caller's* package, which the
//! *callee's* package then fails to downcast back to its own expected lambda
//! type (`ClassCastException: JsonRpc.Stdio.StdioTests$Lambda$0 cannot be
//! cast to class JsonRpc.Stdio.Lyric$Lambda`, reproduced in isolation — the
//! .NET target is unaffected). Cross-package `impl` dispatch on a plain
//! interface does not hit that bug (also matches `lyric-cache/src/cache.l`'s
//! own documented reason for using a record-of-interface `Clock` instead of
//! a stored closure). Filed upstream; see the README's "Known upstream
//! issues" section.
@runtime_checked
package JsonRpc.Stdio

import Std.Core
import Std.Collections
import Std.Console
import Std.Encoding
import Std.Errors
import Std.Parse
import Std.Time
import JsonRpc

// ── Sans-IO seams ────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub interface CharReader {
  /// The next UTF-16 code unit, or a negative value at EOF — matches
  /// `Std.ConsoleHost.hostConsoleRead`'s contract.
  func next(): Int
}

@stable(since = "0.1")
pub interface LineReader {
  /// Matches `Std.Console.readLine`'s contract.
  func nextLine(): Result[String, IOError]
}

@stable(since = "0.1")
pub interface StringWriter {
  func write(s: in String): Unit
}

@stable(since = "0.1")
pub interface LineWriter {
  func writeLine(s: in String): Unit
}

/// Outcome of `ByteSource.readWithin`: the bytes read (never empty), clean
/// end of stream, or nothing within the timeout.
@stable(since = "0.2")
pub union ByteRead {
  case BytesRead(bytes: slice[Byte])
  case BytesEnd
  case BytesTimedOut
}

/// A stream of raw bytes: the seam the byte-level framings read through.
@stable(since = "0.2")
pub interface ByteSource {
  /// Block until at least one byte arrives (`Some`) or the stream ends
  /// (`None`).
  func read(): Result[Option[slice[Byte]], String]

  /// Wait at most `timeoutMs` milliseconds (`timeoutMs >= 0`) for bytes. A
  /// timeout loses nothing: bytes that arrive later are returned by the next
  /// `read` or `readWithin`.
  func readWithin(timeoutMs: in Int): Result[ByteRead, String]
}

// Production adapters onto the real console. The writers carry no state;
// each call is a direct trampoline onto the Std.Console(Host) primitive it
// names. Reading goes through `HostStdinSource` below.
record HostStringWriter {
}

impl StringWriter for HostStringWriter {
  // Writes UTF-8 bytes directly (`Std.Console.writeStdoutBytes`, #7510)
  // rather than through `hostConsoleWrite`'s text writer: the framings
  // above declare Content-Length as a UTF-8 byte count (`clSendVia`), so
  // the bytes actually put on the wire must be that same UTF-8 encoding,
  // not whatever encoding the platform console writer happens to default
  // to.
  func write(s: in String): Unit {
    writeStdoutBytes(encodeUtf8(s))
  }
}

record HostLineWriter {
}

impl LineWriter for HostLineWriter {
  func writeLine(s: in String): Unit {
    println(s)
  }
}

record HostStdinSource {
  reader: StdinReader
}

impl ByteSource for HostStdinSource {
  func read(): Result[Option[slice[Byte]], String] {
    match readStdin(self.reader) {
      case Ok(bytes) -> Ok(value = bytes)
      case Err(e) -> Err(error = IOError.message(e))
    }
  }

  func readWithin(timeoutMs: in Int): Result[ByteRead, String] {
    match readStdinWithin(self.reader, timeoutMs) {
      case Err(e) -> Err(error = IOError.message(e))
      case Ok(chunk) -> match chunk {
        case StdinBytes(bytes) -> Ok(value = BytesRead(bytes = bytes))
        case StdinEnd -> Ok(value = BytesEnd)
        case StdinTimedOut -> Ok(value = BytesTimedOut)
      }
    }
  }
}

// ── Framing limits ──────────────────────────────────────────────────────────
// A peer controls every byte these readers consume, so each framing enforces
// a hard ceiling and reports a violation as a framing `Err` (#7245): a single
// message may not exceed `MAX_MESSAGE_BYTES` (16 MiB, UTF-8), a Content-Length
// header line `MAX_HEADER_LINE_CHARS`, and a header block `MAX_HEADER_LINES`.
val MAX_MESSAGE_BYTES: Int = 16777216

val MAX_HEADER_LINE_CHARS: Int = 8192

val MAX_HEADER_LINES: Int = 64

// ── NDJSON framing (sans-IO core) ───────────────────────────────────────────
/// Read one NDJSON-framed message via `reader`. `EndOfInput` maps to clean
/// `Ok(None)`; every other `IOError` maps to `Err`.
@stable(since = "0.1")
pub func ndjsonReceiveVia(reader: in LineReader): Result[Option[String], String] {
  match reader.nextLine() {
    case Ok(line) -> match ndjsonAcceptLine(line) {
      case Ok(accepted) -> Ok(value = Some(value = accepted))
      case Err(e) -> Err(error = e)
    }
    case Err(e) -> match e { case EndOfInput(_) -> Ok(value = None); case _ -> Err(error = IOError.message(e)) }
  }
}

/// Apply the NDJSON framing limits to a line some other reader already
/// split off (e.g. a bounded read of a child process's stdout): the line
/// itself, or a framing `Err` when it exceeds the 16 MiB message limit.
@stable(since = "0.2")
pub func ndjsonAcceptLine(line: in String): Result[String, String] {
  if line.length > MAX_MESSAGE_BYTES or encodeUtf8(line).length > MAX_MESSAGE_BYTES {
    Err(error = ndjsonTooLong())
  } else {
    Ok(value = line)
  }
}

/// Write one NDJSON-framed message via `writer`. `writeValue` is always
/// compact (no embedded newline), so `payload` is written as exactly one
/// line.
@stable(since = "0.1")
pub func ndjsonSendVia(payload: in String, writer: in LineWriter): Result[Unit, String] {
  writer.writeLine(payload)
  Ok(value = ())
}

@stable(since = "0.1")
pub record NdjsonTransport {
  source: ByteSource
  writer: LineWriter
  buffer: FrameBuffer
}

impl RpcTransport for NdjsonTransport {
  func receive(): Result[Option[String], String] {
    ndjsonReceiveFrom(self.source, self.buffer)
  }

  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String] {
    ndjsonReceiveWithinFrom(self.source, self.buffer, timeoutMs)
  }

  func send(payload: in String): Result[Unit, String] {
    ndjsonSendVia(payload, self.writer)
  }

  func close(): Unit {
  }
}

/// Construct an `RpcTransport` that frames one JSON message per line over
/// stdin/stdout — the MCP stdio transport. It owns stdin: do not also read
/// it through `Std.Console.readLine`.
@stable(since = "0.1")
pub func newNdjsonTransport(): NdjsonTransport {
  NdjsonTransport(
    source = HostStdinSource(reader = openStdinReader()),
    writer = HostLineWriter(),
    buffer = newFrameBuffer()
  )
}

// ── Content-Length framing (sans-IO core) ───────────────────────────────────
// Reads a single header line (up to '\n', with a trailing '\r' stripped)
// via `reader`. Classifies the end-of-stream case precisely:
//   Ok(Some(line)) — a complete line (possibly empty, i.e. the blank line
//                    that ends the header block)
//   Ok(None)       — EOF with zero characters consumed for this line (a
//                    clean stream end exactly at a line boundary)
//   Err(message)   — EOF after at least one character of this line was
//                    already read (a truncated header block)
func clReadHeaderLine(reader: in CharReader): Result[Option[String], String] {
  var line = ""
  var chars = 0
  var any = false
  var result: Result[Option[String], String] = Err(error = "unreachable")
  var done = false
  while not done {
    val c = reader.next()
    if c < 0 {
      if any {
        result = Err(error = "Content-Length framing: unexpected end of stream inside a header line")
      } else {
        result = Ok(value = None)
      }
      done = true
    } else if c == 10 {
      result = Ok(value = Some(value = line))
      done = true
    } else if c == 13 {
      any = true
    } else if chars >= MAX_HEADER_LINE_CHARS {
      result = Err(
        error = "Content-Length framing: header line exceeds " + MAX_HEADER_LINE_CHARS.toString() + " characters"
      )
      done = true
    } else {
      any = true
      chars = chars + 1
      line = line + clCodeUnitText(c)
    }
  }
  result
}

// Reads header lines up to and including the blank line that ends the
// header block, returning the parsed Content-Length.
//   Ok(Some(n))  — header block ended normally with a valid Content-Length
//   Ok(None)     — clean EOF before any header text was read at all
//   Err(message) — truncated header block, or a header block with no
//                  (or a malformed) Content-Length
func clReadHeaders(reader: in CharReader): Result[Option[Int], String] {
  var contentLength = 0 - 1
  var sawAny = false
  var lines = 0
  var outcome: Result[Option[Int], String] = Err(error = "unreachable")
  var done = false
  while not done {
    // NOTE: decomposed into two separate `match` steps (Result, then
    // Option) for the same reason as jsonrpc.l's `runLoop`/`call` — see
    // that file's NOTE on this exact `while`/`match` shape reproducibly
    // breaking on the self-hosted JVM backend when some arms end the loop
    // and others don't.
    val lineResult: Result[Option[String], String] = clReadHeaderLine(reader)
    match lineResult {
      case Err(e) -> {
        outcome = Err(error = e)
        done = true
      }
      case Ok(lineOpt) -> match lineOpt {
        case None -> {
          if sawAny {
            outcome = Err(error = "Content-Length framing: unexpected end of stream inside the header block")
          } else {
            outcome = Ok(value = None)
          }
          done = true
        }
        case Some(lineIn) -> {
          val line: String = lineIn
          sawAny = true
          lines = lines + 1
          if line.length == 0 {
            if contentLength < 0 {
              outcome = Err(error = "Content-Length framing: header block ended without a Content-Length header")
            } else {
              outcome = Ok(value = Some(value = contentLength))
            }
            done = true
          } else if lines > MAX_HEADER_LINES {
            outcome = Err(error = "Content-Length framing: header block exceeds " + MAX_HEADER_LINES.toString() + " lines")
            done = true
          } else {
            val headerErr = clApplyHeaderLine(line, contentLength)
            if headerErr.length > 0 {
              outcome = Err(error = headerErr)
              done = true
            } else {
              contentLength = clContentLengthOf(line, contentLength)
            }
          }
        }
      }
    }
  }
  outcome
}

// The framing error for one header line given the Content-Length seen so far
// (`current`, negative when none yet), or "" when the line is acceptable.  A
// second Content-Length is rejected rather than silently overriding the first,
// and the value must be a non-negative integer within `MAX_MESSAGE_BYTES`.
func clApplyHeaderLine(line: in String, current: in Int): String {
  val colon = line.indexOf(":")
  if colon <= 0 {
    return ""
  }
  val key = line.substring(0, colon).trim()
  if key.toLower() != "content-length" {
    return ""
  }
  if current >= 0 {
    return "Content-Length framing: duplicate Content-Length header"
  }
  val value = line.substring(colon + 1, line.length - colon - 1).trim()
  match parseOptInt(value) {
    case None -> "Content-Length framing: malformed Content-Length header value"
    case Some(n) -> if n < 0 {
      "Content-Length framing: negative Content-Length header value"
    } else if n > MAX_MESSAGE_BYTES {
      "Content-Length framing: Content-Length " + n.toString() + " exceeds the " + MAX_MESSAGE_BYTES.toString() +
        "-byte limit"
    } else {
      ""
    }
  }
}

// The Content-Length after `line` (already accepted by `clApplyHeaderLine`).
func clContentLengthOf(line: in String, current: in Int): Int {
  val colon = line.indexOf(":")
  if colon <= 0 {
    return current
  }
  if line.substring(0, colon).trim().toLower() != "content-length" {
    return current
  }
  match parseOptInt(line.substring(colon + 1, line.length - colon - 1).trim()) {
    case Some(n) -> n
    case None -> current
  }
}

// The text of one UTF-16 code unit read from a `CharReader`.  A `Char` is a
// BMP scalar value, so an unpaired surrogate code unit cannot be kept as-is:
// it becomes U+FFFD, exactly what `encodeUtf8` would have written for it and
// what a UTF-8 decoder yields for the malformed bytes behind it (#7252).
func clCodeUnitText(c: in Int): String {
  if c >= 0xD800 and c <= 0xDFFF {
    "�"
  } else {
    codepointToString(c)
  }
}

// Reads exactly `contentLength` UTF-8 bytes' worth of body, one UTF-16 code
// unit at a time from `reader`. A lone high surrogate is buffered until
// the matching low surrogate arrives, and the pair decodes to one
// supplementary-plane code point (4 UTF-8 bytes, not two independent 3-byte
// encodings). A high surrogate not followed by a low one, or a low
// surrogate with no high one before it, becomes U+FFFD (3 bytes) rather
// than failing the whole frame on that malformed shape. An unpaired high
// surrogate at end-of-body is a framing error, since a conforming UTF-8
// encoder never splits a surrogate pair across the declared byte count.
func clReadBodyBytes(contentLength: in Int, reader: in CharReader): Result[String, String] {
  // Pieces are collected and joined once: repeated `+` on a growing string
  // is quadratic in the body size.
  val parts: List[String] = newList()
  var bytesRead = 0
  var pendingHigh = 0 - 1
  var ok = true
  var err = ""
  while ok and bytesRead < contentLength {
    val c = reader.next()
    if c < 0 {
      ok = false
      err = "Content-Length framing: unexpected end of stream reading the message body (" + bytesRead.toString() + " of " +
        contentLength.toString() +
        " bytes)"
    } else if pendingHigh >= 0 and c >= 0xDC00 and c <= 0xDFFF {
      parts.add(codepointToString(0x10000 + (pendingHigh - 0xD800) * 0x400 + (c - 0xDC00)))
      bytesRead = bytesRead + 4
      pendingHigh = 0 - 1
    } else {
      if pendingHigh >= 0 {
        // The buffered high surrogate was not followed by a matching low
        // surrogate: flush it as U+FFFD and process `c` fresh.
        val replacement = clCodeUnitText(pendingHigh)
        parts.add(replacement)
        bytesRead = bytesRead + encodeUtf8(replacement).length
        pendingHigh = 0 - 1
      }
      if c >= 0xD800 and c <= 0xDBFF {
        pendingHigh = c
      } else {
        val ch = clCodeUnitText(c)
        parts.add(ch)
        bytesRead = bytesRead + encodeUtf8(ch).length
      }
    }
  }
  if not ok {
    Err(error = err)
  } else if pendingHigh >= 0 {
    Err(error = "Content-Length framing: message body ended mid-surrogate-pair")
  } else {
    Ok(value = concatAll(parts))
  }
}

// Concatenate `parts` by pairwise merging: O(n log n) in the total length,
// where a left-to-right `+` fold is quadratic.
func concatAll(parts: in List[String]): String {
  var level: List[String] = parts
  while level.count > 1 {
    val next: List[String] = newList()
    var i = 0
    while i < level.count {
      if i + 1 < level.count {
        next.add(level[i] + level[i + 1])
      } else {
        next.add(level[i])
      }
      i = i + 2
    }
    level = next
  }
  if level.count == 0 {
    ""
  } else {
    level[0]
  }
}

/// Read one Content-Length-framed message via `reader`.
@stable(since = "0.1")
pub func clReceiveVia(reader: in CharReader): Result[Option[String], String] {
  match clReadHeaders(reader) {
    case Err(e) -> Err(error = e)
    case Ok(None) -> Ok(value = None)
    case Ok(Some(contentLength)) -> {
      if contentLength < 0 {
        Err(error = "Content-Length framing: negative Content-Length header value")
      } else if contentLength == 0 {
        Ok(value = Some(value = ""))
      } else {
        match clReadBodyBytes(contentLength, reader) {
          case Ok(body) -> Ok(value = Some(value = body))
          case Err(e) -> Err(error = e)
        }
      }
    }
  }
}

/// Write one Content-Length-framed message via `writer`.
@stable(since = "0.1")
pub func clSendVia(payload: in String, writer: in StringWriter): Result[Unit, String] {
  val n = encodeUtf8(payload).length
  writer.write("Content-Length: " + n.toString() + "\r\n\r\n" + payload)
  Ok(value = ())
}

@stable(since = "0.1")
pub record ContentLengthTransport {
  source: ByteSource
  writer: StringWriter
  buffer: FrameBuffer
}

impl RpcTransport for ContentLengthTransport {
  func receive(): Result[Option[String], String] {
    clReceiveFrom(self.source, self.buffer)
  }

  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String] {
    clReceiveWithinFrom(self.source, self.buffer, timeoutMs)
  }

  func send(payload: in String): Result[Unit, String] {
    clSendVia(payload, self.writer)
  }

  func close(): Unit {
  }
}

/// Construct an `RpcTransport` that frames messages with an LSP-style
/// `Content-Length: N\r\n\r\n` header over stdin/stdout, byte-accurate on
/// UTF-8 (see the module doc). It owns stdin, like `newNdjsonTransport`.
@stable(since = "0.1")
pub func newContentLengthTransport(): ContentLengthTransport {
  ContentLengthTransport(
    source = HostStdinSource(reader = openStdinReader()),
    writer = HostStringWriter(),
    buffer = newFrameBuffer()
  )
}

// ── Byte-level framing over a ByteSource (sans-IO core, #7451) ──────────────
/// Bytes read from a `ByteSource` that no complete frame has consumed yet.
/// A transport keeps one for its whole life, so bytes read before a
/// `receiveWithin` timeout are still there for the next receive.
///
/// `bytes` is a `List[Byte]`, not a `slice[Byte]` (#7520 review): `slice[Byte]` is
/// immutable (`.append`/`.concat` each return a fresh copy — §2.7), so
/// growing one byte-chunk at a time by re-concatenating the whole pending
/// buffer on every `appendBytes` call is O(pending size) per append, i.e.
/// O(message size²) to accumulate one large message split across many small
/// reads. `List[Byte].add` is the same amortized-O(1)-per-element growable
/// array every other byte accumulator in the stdlib already builds on
/// (`Std.Encoding.encodeUtf8`, `Std.Hash`, `Std.Http`'s H2 framer), so
/// appending a chunk of `n` bytes costs amortized O(n), and a full message
/// costs O(message size) regardless of how many reads it arrived in.
@stable(since = "0.2")
pub record FrameBuffer {
  var bytes: List[Byte]
  // Read cursor: bytes before `pos` belong to frames already returned.
  var pos: Int
  // Bytes from `pos` already scanned for a newline without finding one, so
  // a long NDJSON line that arrives in many reads is not rescanned.
  var scanned: Int
  var ended: Bool
}

@stable(since = "0.2")
pub func newFrameBuffer(): FrameBuffer {
  val empty: List[Byte] = newList()
  FrameBuffer(bytes = empty, pos = 0, scanned = 0, ended = false)
}

func pendingBytes(fb: in FrameBuffer): Int {
  fb.bytes.count - fb.pos
}

// Append `more`. Drops the consumed prefix first (once per frame boundary
// crossed, not once per append) so a long-lived connection's buffer does
// not grow without bound; the append itself is `List.add` per byte, which
// is amortized O(1) each — see the FrameBuffer doc comment.
func appendBytes(fb: in FrameBuffer, more: in slice[Byte]): Unit {
  if fb.pos > 0 {
    val compacted: List[Byte] = newList()
    var i = fb.pos
    while i < fb.bytes.count {
      compacted.add(fb.bytes[i])
      i = i + 1
    }
    fb.bytes = compacted
    fb.pos = 0
  }
  var j = 0
  while j < more.length {
    fb.bytes.add(more[j])
    j = j + 1
  }
}

// Materialize `bytes[start, endExclusive)` as a `slice[Byte]` — the one
// place per completed frame (not per append) that copies out of the
// `List[Byte]` accumulator, for `tryDecodeUtf8` and header-line text.
func listByteSlice(bytes: in List[Byte], start: in Int, endExclusive: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = start
  while i < endExclusive {
    acc.add(bytes[i])
    i = i + 1
  }
  acc.toArray()
}

func consumeTo(fb: in FrameBuffer, newPos: in Int): Unit {
  fb.pos = newPos
  fb.scanned = 0
}

// What one attempt to cut a frame out of the buffer found.
union FrameStep {
  case FrameReady(text: String)
  case FrameNeedsMore
  case FrameEnd
  case FrameFailed(message: String)
}

func decodeFrame(bytes: in List[Byte], start: in Int, endExclusive: in Int, framing: in String): FrameStep {
  match tryDecodeUtf8(listByteSlice(bytes, start, endExclusive)) {
    case Some(text) -> FrameReady(text = text)
    case None -> FrameFailed(message = framing + " framing: message is not valid UTF-8")
  }
}

// NDJSON: the next `\n`-terminated line (a `\r` before the `\n` is
// dropped). At end of stream a final unterminated line is still a message,
// matching `Std.Console.readLine`.
//
// The EOF-terminated tail (below) is checked against `MAX_MESSAGE_BYTES`
// with the exact same bound as the `\n`-terminated line above it (#7520 review):
// an earlier version only capped how much could accumulate while still
// waiting for a delimiter (`pendingBytes(fb) > MAX_MESSAGE_BYTES + 1`,
// which allows exactly one more pending byte than a `\n`-terminated line
// is ever allowed to have, since that check runs before the terminator is
// known to be a `\n` or EOF), so an EOF-terminated final line could be
// exactly `MAX_MESSAGE_BYTES + 1` bytes and slip through where the
// `\n`-terminated path would have rejected it.
func ndjsonStep(fb: in FrameBuffer): FrameStep {
  val bytes = fb.bytes
  var i = fb.pos + fb.scanned
  while i < bytes.count {
    if bytes[i] == 10u8 {
      val start = fb.pos
      var cut = i
      if cut > start and bytes[cut - 1] == 13u8 {
        cut = cut - 1
      }
      consumeTo(fb, i + 1)
      if cut - start > MAX_MESSAGE_BYTES {
        return FrameFailed(message = ndjsonTooLong())
      }
      return decodeFrame(bytes, start, cut, "NDJSON")
    }
    i = i + 1
  }
  fb.scanned = bytes.count - fb.pos
  if pendingBytes(fb) > MAX_MESSAGE_BYTES + 1 {
    return FrameFailed(message = ndjsonTooLong())
  }
  if not fb.ended {
    return FrameNeedsMore
  }
  if pendingBytes(fb) == 0 {
    return FrameEnd
  }
  val start = fb.pos
  var cut = bytes.count
  if bytes[cut - 1] == 13u8 {
    cut = cut - 1
  }
  consumeTo(fb, bytes.count)
  if cut - start > MAX_MESSAGE_BYTES {
    return FrameFailed(message = ndjsonTooLong())
  }
  decodeFrame(bytes, start, cut, "NDJSON")
}

func ndjsonTooLong(): String {
  "NDJSON framing: message exceeds the " + MAX_MESSAGE_BYTES.toString() + "-byte limit"
}

// Content-Length: a header block, then exactly the declared body bytes.
// Headers are re-parsed from `pos` on each attempt (they are bounded by
// `MAX_HEADER_LINES` x `MAX_HEADER_LINE_CHARS`), and nothing is consumed
// until the whole frame is present. `\r` bytes in a header line are
// ignored, as `clReceiveVia` ignores them.
func clStep(fb: in FrameBuffer): FrameStep {
  val bytes = fb.bytes
  var i = fb.pos
  var lineStart = i
  var lines = 0
  var contentLength = 0 - 1
  var bodyStart = 0 - 1
  while bodyStart < 0 and i < bytes.count {
    if bytes[i] == 10u8 {
      val line = headerLineText(bytes, lineStart, i)
      if line.length == 0 {
        if contentLength < 0 {
          return FrameFailed(message = "Content-Length framing: header block ended without a Content-Length header")
        }
        bodyStart = i + 1
      } else {
        lines = lines + 1
        if lines > MAX_HEADER_LINES {
          return FrameFailed(message = "Content-Length framing: header block exceeds " + MAX_HEADER_LINES.toString() + " lines")
        }
        val headerErr = clApplyHeaderLine(line, contentLength)
        if headerErr.length > 0 {
          return FrameFailed(message = headerErr)
        }
        contentLength = clContentLengthOf(line, contentLength)
      }
      lineStart = i + 1
    } else if i - lineStart >= MAX_HEADER_LINE_CHARS {
      return FrameFailed(
        message = "Content-Length framing: header line exceeds " + MAX_HEADER_LINE_CHARS.toString() + " characters"
      )
    }
    i = i + 1
  }
  if bodyStart >= 0 and bytes.count - bodyStart >= contentLength {
    consumeTo(fb, bodyStart + contentLength)
    return decodeFrame(bytes, bodyStart, bodyStart + contentLength, "Content-Length")
  }
  if not fb.ended {
    return FrameNeedsMore
  }
  if pendingBytes(fb) == 0 {
    return FrameEnd
  }
  if bodyStart < 0 {
    FrameFailed(message = "Content-Length framing: unexpected end of stream inside the header block")
  } else {
    FrameFailed(
      message = "Content-Length framing: unexpected end of stream reading the message body (" +
        (bytes.count - bodyStart).toString() +
        " of " +
        contentLength.toString() +
        " bytes)"
    )
  }
}

// A header line's text with every `\r` removed. Header bytes outside ASCII
// decode as UTF-8; an invalid line decodes as "?", which `clApplyHeaderLine`
// ignores like any header without a colon.
func headerLineText(bytes: in List[Byte], start: in Int, endExclusive: in Int): String {
  match tryDecodeUtf8(listByteSlice(bytes, start, endExclusive)) {
    case Some(text) -> text.replace("\r", "")
    case None -> "?"
  }
}

func ndjsonFraming(): Int {
  0
}

func clFraming(): Int {
  1
}

func frameStep(framing: in Int, fb: in FrameBuffer): FrameStep {
  if framing == ndjsonFraming() {
    ndjsonStep(fb)
  } else {
    clStep(fb)
  }
}

// Receive one frame, blocking on `source` for as long as it takes.
func receiveFrom(framing: in Int, source: in ByteSource, fb: in FrameBuffer): Result[Option[String], String] {
  var outcome: Result[Option[String], String] = Ok(value = None)
  var done = false
  while not done {
    match frameStep(framing, fb) {
      case FrameReady(text) -> {
        outcome = Ok(value = Some(value = text))
        done = true
      }
      case FrameEnd -> {
        outcome = Ok(value = None)
        done = true
      }
      case FrameFailed(message) -> {
        outcome = Err(error = message)
        done = true
      }
      case FrameNeedsMore -> {
        val read: Result[Option[slice[Byte]], String] = source.read()
        match read {
          case Err(e) -> {
            outcome = Err(error = e)
            done = true
          }
          case Ok(chunk) -> match chunk { case Some(bytes) -> appendBytes(fb, bytes); case None -> { fb.ended = true } }
        }
      }
    }
  }
  outcome
}

// Receive one frame, waiting on `source` for at most `timeoutMs` in total.
func receiveWithinFrom(
  framing: in Int, source: in ByteSource, fb: in FrameBuffer, timeoutMs: in Int
): Result[ReceiveOutcome, String] {
  val deadline = monotonicNanos() + timeoutMs.toLong() * 1000000i64
  var outcome: Result[ReceiveOutcome, String] = Ok(value = RpcTimedOut)
  var done = false
  while not done {
    match frameStep(framing, fb) {
      case FrameReady(text) -> {
        outcome = Ok(value = RpcMessage(text = text))
        done = true
      }
      case FrameEnd -> {
        outcome = Ok(value = RpcEndOfStream)
        done = true
      }
      case FrameFailed(message) -> {
        outcome = Err(error = message)
        done = true
      }
      case FrameNeedsMore -> {
        val left = deadline - monotonicNanos()
        val budget = if left <= 0i64 { 0 } else { ((left + 999999i64) / 1000000i64).toInt() }
        val read: Result[ByteRead, String] = source.readWithin(budget)
        match read {
          case Err(e) -> {
            outcome = Err(error = e)
            done = true
          }
          case Ok(chunk) -> match chunk {
            case BytesRead(bytes) -> appendBytes(fb, bytes)
            case BytesEnd -> {
              fb.ended = true
            }
            case BytesTimedOut -> {
              outcome = Ok(value = RpcTimedOut)
              done = true
            }
          }
        }
      }
    }
  }
  outcome
}

/// Read one NDJSON-framed message from `source`, buffering in `buffer`.
/// `Ok(None)` marks clean end of stream.
@stable(since = "0.2")
pub func ndjsonReceiveFrom(source: in ByteSource, buffer: in FrameBuffer): Result[Option[String], String] {
  receiveFrom(ndjsonFraming(), source, buffer)
}

/// `ndjsonReceiveFrom`, waiting at most `timeoutMs` milliseconds in total.
/// On `RpcTimedOut` the bytes read so far stay in `buffer`.
@stable(since = "0.2")
pub func ndjsonReceiveWithinFrom(
  source: in ByteSource, buffer: in FrameBuffer, timeoutMs: in Int
): Result[ReceiveOutcome, String]
  requires: timeoutMs >= 0
{
  receiveWithinFrom(ndjsonFraming(), source, buffer, timeoutMs)
}

/// Read one Content-Length-framed message from `source`, buffering in
/// `buffer`. `Ok(None)` marks clean end of stream at a frame boundary.
@stable(since = "0.2")
pub func clReceiveFrom(source: in ByteSource, buffer: in FrameBuffer): Result[Option[String], String] {
  receiveFrom(clFraming(), source, buffer)
}

/// `clReceiveFrom`, waiting at most `timeoutMs` milliseconds in total. On
/// `RpcTimedOut` the bytes read so far stay in `buffer`.
@stable(since = "0.2")
pub func clReceiveWithinFrom(
  source: in ByteSource, buffer: in FrameBuffer, timeoutMs: in Int
): Result[ReceiveOutcome, String]
  requires: timeoutMs >= 0
{
  receiveWithinFrom(clFraming(), source, buffer, timeoutMs)
}

/// An NDJSON `RpcTransport` reading from `source` and writing through
/// `writer` — the stdio transport over any byte stream.
@stable(since = "0.2")
pub func newNdjsonTransportOver(source: in ByteSource, writer: in LineWriter): NdjsonTransport {
  NdjsonTransport(source = source, writer = writer, buffer = newFrameBuffer())
}

/// A Content-Length `RpcTransport` reading from `source` and writing
/// through `writer`.
@stable(since = "0.2")
pub func newContentLengthTransportOver(source: in ByteSource, writer: in StringWriter): ContentLengthTransport {
  ContentLengthTransport(source = source, writer = writer, buffer = newFrameBuffer())
}
