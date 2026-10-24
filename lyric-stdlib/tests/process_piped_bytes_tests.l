//! stdlib/tests/process_piped_bytes_tests.l — byte-level I/O on piped child
//! processes (`Std.Process.pipedReadBytes`, `pipedReadBytesWithin`,
//! `pipedWriteBytes`) and JSON-RPC 2.0 over a real child through
//! `Std.JsonRpc.Stdio`'s process transports
//! (`newContentLengthTransportOverProcess`, `newNdjsonTransportOverProcess`).
//!
//! Byte level: a round trip through `cat`, a body with no trailing newline,
//! timed-out reads resuming without loss, multibyte UTF-8, end of stream, and
//! mixing line and byte reads on one child in both orders, including after a
//! timed-out read of the other kind.
//!
//! JSON-RPC: `cat` echoes every frame back unchanged (a framing round trip at
//! the transport level, with a receive that times out and then resumes), and
//! a small `sh` JSON-RPC server answers each `Content-Length` request with a
//! response whose `result` is the request object itself (a full
//! `RpcPeer.call` round trip). Both move multibyte UTF-8, so the
//! `Content-Length` byte count is checked against real pipe bytes.
//!
//! A sibling of `process_tests.l` rather than more cases in it: that suite
//! uses `assertPanics`, which needs `try`/`catch` and so cannot build for
//! `--target native` (D-N-003), while this one runs on dotnet, JVM and
//! native. POSIX-only like `process_tests.l`: on Windows `main` returns 0
//! with an informational line.
package Std.Process.PipedBytesTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Environment
import Std.Errors
import Std.Process
import Std.JsonValue
import Std.JsonRpc
import Std.JsonRpc.Stdio
import Std.Testing
import Std.Time

func shArgs(script: in String): List[String] {
  val args: List[String] = newList()
  args.add("-c")
  args.add(script)
  args
}

// ── Byte-level piped I/O ─────────────────────────────────────────────────────
// Read until `want` bytes have arrived (a pipe may deliver them in several
// pieces), or end of stream, a failure, or a 5 s wait for any one piece.
func readBytesExactly(p: in PipedProcess, want: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var done = false
  while not done and acc.count < want {
    match pipedReadBytesWithin(p, 5000) {
      case Ok(PipedBytes(bytes)) -> {
        appendBytes(acc, bytes)
      }
      case _ -> {
        done = true
      }
    }
  }
  acc.toArray()
}

// An index loop, not `for`: on the JVM backend `for` over a slice bound by a
// nested pattern (`case Ok(Some(bytes))`) treats it as an `Iterable` and
// fails at run time.
func appendBytes(acc: in List[Byte], bytes: in slice[Byte]): Unit {
  var i = 0
  while i < bytes.length {
    acc.add(bytes[i])
    i = i + 1
  }
}

// Every byte until end of stream.
func readBytesToEnd(p: in PipedProcess): slice[Byte] {
  val acc: List[Byte] = newList()
  var done = false
  while not done {
    match pipedReadBytes(p) {
      case Ok(Some(bytes)) -> {
        assertTrue(bytes.length > 0, "pipedReadBytes never returns an empty chunk")
        appendBytes(acc, bytes)
      }
      case Ok(None) -> {
        done = true
      }
      case Err(e) -> {
        assertTrue(false, "pipedReadBytes failed: " + e)
        done = true
      }
    }
  }
  acc.toArray()
}

func decoded(bytes: in slice[Byte]): String {
  match tryDecodeUtf8(bytes) {
    case Some(s) -> s
    case None -> "<invalid utf-8>"
  }
}

func writeBytesOk(p: in PipedProcess, text: in String): Unit {
  match pipedWriteBytes(p, encodeUtf8(text)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "pipedWriteBytes failed: " + e)
  }
}

// A Content-Length frame through `cat`: the bytes come back exactly, with no
// newline appended on the way in (the body has none of its own), and
// multibyte UTF-8 (2- and 4-byte sequences) survives byte for byte.
func testPipedBytesRoundTrip(): Unit {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      val body = "{\"name\":\"héllo 😀\"}"
      val bodyBytes = encodeUtf8(body).length
      val frame = "Content-Length: " + bodyBytes.toString() + "\r\n\r\n" + body
      val frameBytes = encodeUtf8(frame).length
      writeBytesOk(p, frame)
      val back = readBytesExactly(p, frameBytes)
      assertEqualInt(back.length, frameBytes, "every byte of the frame comes back")
      assertEqual(decoded(back), frame, "the frame comes back unchanged")
      assertEqual(decoded(back.slice(frameBytes - bodyBytes, frameBytes)), body, "the multibyte body is intact")
      match pipedReadBytesWithin(p, 200) {
        case Ok(PipedBytesTimedOut) -> ()
        case Ok(PipedBytes(extra)) -> assertTrue(
          false,
          "no newline was appended, got " + extra.length.toString() + " extra bytes"
        )
        case _ -> assertTrue(false, "cat is still running: expected a timeout")
      }
      writeBytesOk(p, "")
      pipedCloseStdin(p)
      match pipedWriteBytes(p, encodeUtf8("late")) {
        case Ok(_) -> assertTrue(false, "a write after closing stdin must fail")
        case Err(_) -> ()
      }
      pipedWaitExit(p, 5000)
      pipedClose(p)
    }
  }
}

// A child whose output ends without a newline: every byte, then end of
// stream from both the blocking and the bounded read, repeatedly.
func testPipedBytesEndOfStream(): Unit {
  match spawnPiped("sh", shArgs("printf 'no newline at the end'")) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      assertEqual(decoded(readBytesToEnd(p)), "no newline at the end", "the unterminated output arrives whole")
      match pipedReadBytes(p) {
        case Ok(None) -> ()
        case _ -> assertTrue(false, "end of stream is reported again")
      }
      match pipedReadBytesWithin(p, 1000) {
        case Ok(PipedBytesEnd) -> ()
        case _ -> assertTrue(false, "a bounded read at end of stream reports PipedBytesEnd")
      }
      pipedWaitExit(p, 5000)
      pipedClose(p)
    }
  }
}

// A silent child times out, repeatedly, without losing what comes later; a
// zero budget returns bytes already written.
func testPipedBytesTimeoutResumes(): Unit {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      var i = 0
      while i < 20 {
        match pipedReadBytesWithin(p, 5) {
          case Ok(PipedBytesTimedOut) -> ()
          case _ -> assertTrue(false, "a silent child must time out every time")
        }
        i = i + 1
      }
      match pipedReadBytesWithin(p, 150) {
        case Ok(PipedBytesTimedOut) -> ()
        case _ -> assertTrue(false, "a silent child must time out")
      }
      writeBytesOk(p, "late")
      assertEqual(decoded(readBytesExactly(p, 4)), "late", "bytes written after the timeouts are delivered")
      writeBytesOk(p, "ready")
      // A zero budget returns bytes once they are in the pipe; poll until
      // `cat` has echoed them.
      var got = ""
      var tries = 0
      while got == "" and tries < 500 {
        match pipedReadBytesWithin(p, 0) {
          case Ok(PipedBytes(bytes)) -> {
            got = decoded(bytes)
          }
          case Ok(PipedBytesTimedOut) -> sleepMillis(10)
          case _ -> {
            tries = 500
          }
        }
        tries = tries + 1
      }
      assertEqual(got, "ready", "a zero budget returns bytes already written")
      pipedCloseStdin(p)
      pipedWaitExit(p, 5000)
      pipedClose(p)
    }
  }
}

// Line and byte reads share one buffer of the child's stdout.
func testPipedMixedLineAndByteReads(): Unit {
  // A line read leaves the bytes after its line for the byte read.
  match spawnPiped("sh", shArgs("printf 'first\\nsecond\\nthird'")) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      pipedWaitExit(p, 5000)
      match pipedReadLine(p) {
        case Ok(Some(line)) -> assertEqual(line, "first", "the line read returns the first line")
        case _ -> assertTrue(false, "expected the first line")
      }
      assertEqual(decoded(readBytesToEnd(p)), "second\nthird", "the byte read returns the rest, in order")
      match pipedReadLine(p) {
        case Ok(None) -> ()
        case _ -> assertTrue(false, "nothing is left for a line read")
      }
      pipedClose(p)
    }
  }
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      // A byte read leaves nothing behind for the next line read.
      writeBytesOk(p, "partial ")
      assertEqual(decoded(readBytesExactly(p, 8)), "partial ", "the byte read returns the bytes written")
      pipedWriteLine(p, "whole line")
      match pipedReadLineWithin(p, 5000) {
        case Ok(PipedLine(line)) -> assertEqual(line, "whole line", "the next line read starts after the bytes")
        case _ -> assertTrue(false, "expected 'whole line'")
      }
      // A timed-out line read, then bytes with no newline: the byte read
      // gets them, joining the read the timed-out call left outstanding.
      match pipedReadLineWithin(p, 100) {
        case Ok(PipedTimedOut) -> ()
        case _ -> assertTrue(false, "a silent child must time out")
      }
      writeBytesOk(p, "no newline")
      assertEqual(decoded(readBytesExactly(p, 10)), "no newline", "a byte read after a timed-out line read loses nothing")
      // A timed-out byte read, then a line: the line read gets it whole.
      match pipedReadBytesWithin(p, 100) {
        case Ok(PipedBytesTimedOut) -> ()
        case _ -> assertTrue(false, "a silent child must time out")
      }
      pipedWriteLine(p, "after bytes")
      match pipedReadLine(p) {
        case Ok(Some(line)) -> assertEqual(line, "after bytes", "a line read after a timed-out byte read loses nothing")
        case _ -> assertTrue(false, "expected 'after bytes'")
      }
      // The start of a line picked up by a timed-out line read is returned
      // by the next byte read, ahead of the rest.
      writeBytesOk(p, "half")
      match pipedReadLineWithin(p, 300) {
        case Ok(PipedTimedOut) -> ()
        case _ -> assertTrue(false, "an incomplete line must time out")
      }
      writeBytesOk(p, " and half\n")
      assertEqual(decoded(readBytesExactly(p, 14)), "half and half\n", "buffered bytes of a partial line come first")
      pipedCloseStdin(p)
      match pipedReadBytesWithin(p, 5000) {
        case Ok(PipedBytesEnd) -> ()
        case _ -> assertTrue(false, "end of stream after cat exits")
      }
      pipedWaitExit(p, 5000)
      pipedClose(p)
    }
  }
}

record NoopHandler {
}

impl RpcHandler for NoopHandler {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    Err(error = RpcError(code = methodNotFound, message = "no requests expected: " + method, data = None))
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
  }
}

func expectMessage(r: in Result[Option[String], String], want: in String, what: in String): Unit {
  match r {
    case Ok(Some(text)) -> assertEqual(text, want, what)
    case Ok(None) -> assertTrue(false, what + ": unexpected end of stream")
    case Err(e) -> assertTrue(false, what + ": " + e)
  }
}

func expectSent(r: in Result[Unit, String], what: in String): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, what + ": " + e)
  }
}

// Content-Length frames echoed by `cat`: back-to-back messages, multibyte
// UTF-8 bodies, and a receive that times out with nothing pending, then
// resumes.
func testContentLengthEchoThroughCat(): Unit {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      val transport = newContentLengthTransportOverProcess(p)
      val first = "{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":\"héllo 😀\"}"
      val second = "{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":\"世界\"}"
      expectSent(transport.send(first), "send the first message")
      expectSent(transport.send(second), "send the second message")
      expectMessage(transport.receive(), first, "the first message comes back whole")
      match transport.receiveWithin(5000) {
        case Ok(RpcMessage(text)) -> assertEqual(text, second, "the second message comes back whole")
        case _ -> assertTrue(false, "expected the second message")
      }
      match transport.receiveWithin(150) {
        case Ok(RpcTimedOut) -> ()
        case _ -> assertTrue(false, "nothing is pending: the receive must time out")
      }
      val third = "{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":\"after the timeout\"}"
      expectSent(transport.send(third), "send the third message")
      expectMessage(transport.receive(), third, "a message sent after the timeout is received")
      pipedCloseStdin(p)
      match transport.receiveWithin(5000) {
        case Ok(RpcEndOfStream) -> ()
        case _ -> assertTrue(false, "end of stream once cat exits")
      }
      pipedWaitExit(p, 5000)
      pipedClose(p)
    }
  }
}

// The NDJSON process transport through `cat`.
func testNdjsonEchoThroughCat(): Unit {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      val transport = newNdjsonTransportOverProcess(p)
      val message = "{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":\"été\"}"
      expectSent(transport.send(message), "send")
      expectMessage(transport.receive(), message, "the line comes back whole")
      pipedCloseStdin(p)
      match transport.receive() {
        case Ok(None) -> ()
        case _ -> assertTrue(false, "end of stream once cat exits")
      }
      pipedWaitExit(p, 5000)
      pipedClose(p)
    }
  }
}

// A JSON-RPC server in `sh`: reads the header block, then exactly
// Content-Length body bytes (`head -c`), and answers with the request object
// as the result, its byte length counted by `wc -c`. It sees bytes only, so
// the multibyte parameters below cross the pipe as UTF-8 both ways.
val echoServerScript: String = "cr=$(printf '\\r'); " + "while :; do " + "len=; " + "while IFS= read -r line; do line=\${line%\"$cr\"}; [ -z \"$line\" ] && break; " + "case $line in Content-Length:*) len=\${line#Content-Length: };; esac; done; " + "[ -n \"$len\" ] || exit 0; " + "body=$(head -c \"$len\"); " + "id=$(printf '%s' \"$body\" | sed 's/.*\"id\":\\([0-9]*\\).*/\\1/'); " + "resp=\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":$id,\\\"result\\\":$body}\"; " + "printf 'Content-Length: %s\\r\\n\\r\\n%s' \"$(printf '%s' \"$resp\" | wc -c | tr -d ' ')\" \"$resp\"; " + "done"

func testPeerCallAgainstContentLengthServer(): Unit {
  match spawnPiped("sh", shArgs(echoServerScript)) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      var peer = newPeerWithTimeout(newContentLengthTransportOverProcess(p), NoopHandler(), 10000)
      val greetings = ["héllo", "😀 grin", "世界"]
      for g in greetings {
        match call(peer, "echo", Some(value = JString(value = g))) {
          case Err(e) -> assertTrue(false, "call failed: " + e.message)
          case Ok(result) -> {
            assertEqual(unwrapOr(getString(result, "method"), ""), "echo", "the server saw the method")
            assertEqual(unwrapOr(getString(result, "params"), ""), g, "the parameter crossed the pipe intact")
          }
        }
      }
      pipedCloseStdin(p)
      assertTrue(pipedWaitExit(p, 5000), "the server exits at end of input")
      pipedClose(p)
    }
  }
}

func main(): Int {
  if isWindows() {
    println("process_piped_bytes_tests: skipped on Windows (the fixtures use sh) — ok")
    return 0
  }
  testPipedBytesRoundTrip()
  testPipedBytesEndOfStream()
  testPipedBytesTimeoutResumes()
  testPipedMixedLineAndByteReads()
  testContentLengthEchoThroughCat()
  testNdjsonEchoThroughCat()
  testPeerCallAgainstContentLengthServer()
  println("process_piped_bytes_tests: ok")
  0
}
