//! src/stdio.l — JsonRpc.Stdio: NDJSON and Content-Length stdio framings.
//!
//! Two `RpcTransport` implementations over `Std.Console` / `Std.ConsoleHost`
//! primitives (the same seam `lyric-compiler/lyric/lsp.l` reads today):
//!
//!   - `NdjsonTransport`        — one JSON message per `\n`-terminated line
//!     (the MCP stdio transport). `writeValue` is always compact (see
//!     `JsonRpc.Json`), so an outbound message never contains an embedded
//!     newline that would corrupt the framing.
//!   - `ContentLengthTransport` — `Content-Length: N\r\n\r\n` + N bytes (the
//!     LSP framing), byte-accurate on UTF-8. This closes a known gap in
//!     `lsp.l`'s own hand-rolled framing (documented in its header): reading
//!     N *bytes* through `Std.ConsoleHost.hostConsoleRead()`, which returns
//!     UTF-16 *code units*, requires surrogate-pair-aware accounting — a
//!     naive "read N chars" loop under-reads whenever the body contains
//!     any character outside the ASCII range. `clReadBodyBytes` below tracks
//!     UTF-8 byte length incrementally per code unit (or per surrogate
//!     pair, when the code unit is one half of one), so the body read
//!     always stops at the exact byte the peer declared.
//!
//! Both framings are implemented sans-IO: the actual line/byte-counting
//! logic (`clReceiveVia`/`clSendVia`/`ndjsonReceiveVia`/`ndjsonSendVia`)
//! is parameterized over the small `CharReader`/`LineReader`/`StringWriter`/
//! `LineWriter` interfaces below rather than calling `Std.ConsoleHost`
//! directly, so `tests/stdio_tests.l` can drive the framing math against an
//! in-memory stand-in with no real pipe. This is deliberately an
//! interface seam, not a stored `() -> Int` / `(String) -> Unit` closure
//! parameter: a closure argument passed *across a package boundary* on the
//! current self-hosted JVM backend is wrapped in a lambda-adapter class
//! scoped to the *caller's* package, which the *callee's* package then
//! fails to downcast back to its own expected lambda type
//! (`ClassCastException: JsonRpc.Stdio.StdioTests$Lambda$0 cannot be cast
//! to class JsonRpc.Stdio.Lyric$Lambda`, reproduced in isolation — the
//! .NET target is unaffected). Cross-package `impl` dispatch on a plain
//! interface does not hit that bug (also matches `lyric-cache/src/cache.l`'s
//! own documented reason for using a record-of-interface `Clock` instead of
//! a stored closure). Filed upstream; see the README's "Known upstream
//! issues" section.
@runtime_checked
package JsonRpc.Stdio

import Std.Core
import Std.Char
import Std.Console
import Std.ConsoleHost
import Std.Encoding
import Std.Errors
import Std.Parse
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

// Production adapters onto the real console. Records carry no state; each
// method call is a direct trampoline onto the Std.Console(Host) primitive
// it names.
record HostCharReader {
}

impl CharReader for HostCharReader {
  func next(): Int {
    hostConsoleRead()
  }
}

record HostLineReader {
}

impl LineReader for HostLineReader {
  func nextLine(): Result[String, IOError] {
    readLine()
  }
}

record HostStringWriter {
}

impl StringWriter for HostStringWriter {
  func write(s: in String): Unit {
    hostConsoleWrite(s)
  }
}

record HostLineWriter {
}

impl LineWriter for HostLineWriter {
  func writeLine(s: in String): Unit {
    println(s)
  }
}

// ── NDJSON framing (sans-IO core) ───────────────────────────────────────────
/// Read one NDJSON-framed message via `reader`. `EndOfInput` maps to clean
/// `Ok(None)`; every other `IOError` maps to `Err`.
@stable(since = "0.1")
pub func ndjsonReceiveVia(reader: in LineReader): Result[Option[String], String] {
  match reader.nextLine() {
    case Ok(line) -> Ok(value = Some(value = line))
    case Err(e) -> match e { case EndOfInput(_) -> Ok(value = None); case _ -> Err(error = IOError.message(e)) }
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
}

impl RpcTransport for NdjsonTransport {
  func receive(): Result[Option[String], String] {
    ndjsonReceiveVia(HostLineReader())
  }

  func send(payload: in String): Result[Unit, String] {
    ndjsonSendVia(payload, HostLineWriter())
  }

  func close(): Unit {
  }
}

/// Construct an `RpcTransport` that frames one JSON message per line over
/// stdin/stdout — the MCP stdio transport.
@stable(since = "0.1")
pub func newNdjsonTransport(): NdjsonTransport {
  NdjsonTransport()
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
    } else {
      any = true
      line = line + ("" + fromInt(c))
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
      case Ok(lineOpt) -> match lineOpt { case None -> { if sawAny { outcome = Err(error = "Content-Length framing: unexpected end of stream inside the header block") } else { outcome = Ok(value = None) }; done = true }; case Some(lineIn) -> { val line: String = lineIn; sawAny = true; if line.length == 0 { if contentLength < 0 { outcome = Err(error = "Content-Length framing: header block ended without a Content-Length header") } else { outcome = Ok(value = Some(value = contentLength)) }; done = true } else { val colon = line.indexOf(":"); if colon > 0 { val key = line.substring(0, colon).trim(); val value = line.substring(colon + 1, line.length - colon - 1).trim(); if key.toLower() == "content-length" { match parseOptInt(value) { case Some(n) -> { contentLength = n }; case None -> () } } } } } }
    }
  }
  outcome
}

// Reads exactly `contentLength` UTF-8 bytes' worth of body, one UTF-16 code
// unit at a time from `reader`. A lone high surrogate is buffered until
// the matching low surrogate arrives (a complete supplementary-plane code
// point is 4 UTF-8 bytes, not two independent 3-byte encodings); an
// unpaired surrogate at end-of-body is a framing error, since a conforming
// UTF-8 encoder never splits a surrogate pair across the declared byte
// count.
func clReadBodyBytes(contentLength: in Int, reader: in CharReader): Result[String, String] {
  var result = ""
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
    } else if pendingHigh >= 0 {
      if c >= 0xDC00 and c <= 0xDFFF {
        val piece = "" + fromInt(pendingHigh) + "" + fromInt(c)
        result = result + piece
        bytesRead = bytesRead + encodeUtf8(piece).length
        pendingHigh = 0 - 1
      } else {
        // The buffered high surrogate was not followed by a matching low
        // surrogate — flush it standalone and reprocess `c` fresh rather
        // than failing the whole frame outright on this malformed shape.
        val hiChar = "" + fromInt(pendingHigh)
        result = result + hiChar
        bytesRead = bytesRead + encodeUtf8(hiChar).length
        pendingHigh = 0 - 1
        if c >= 0xD800 and c <= 0xDBFF {
          pendingHigh = c
        } else {
          val ch = "" + fromInt(c)
          result = result + ch
          bytesRead = bytesRead + encodeUtf8(ch).length
        }
      }
    } else if c >= 0xD800 and c <= 0xDBFF {
      pendingHigh = c
    } else {
      val ch = "" + fromInt(c)
      result = result + ch
      bytesRead = bytesRead + encodeUtf8(ch).length
    }
  }
  if not ok {
    Err(error = err)
  } else if pendingHigh >= 0 {
    Err(error = "Content-Length framing: message body ended mid-surrogate-pair")
  } else {
    Ok(value = result)
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
}

impl RpcTransport for ContentLengthTransport {
  func receive(): Result[Option[String], String] {
    clReceiveVia(HostCharReader())
  }

  func send(payload: in String): Result[Unit, String] {
    clSendVia(payload, HostStringWriter())
  }

  func close(): Unit {
  }
}

/// Construct an `RpcTransport` that frames messages with an LSP-style
/// `Content-Length: N\r\n\r\n` header over stdin/stdout, byte-accurate on
/// UTF-8 (see the module doc).
@stable(since = "0.1")
pub func newContentLengthTransport(): ContentLengthTransport {
  ContentLengthTransport()
}
