//! lsp_self_test.l — exercises `Lyric.Lsp`'s hover/completion visibility
//! labeling (#6309): `itemSummary`/`symDetail` used to collapse every
//! declared visibility to `"pub "` via `Some(_) -> "pub "`, silently
//! mislabeling `internal` symbols. They now delegate to the canonical
//! `Lyric.Fmt.visibilityPrefixStr` three-way helper.
//!
//! Run via `lyric test lyric-compiler/lyric/lsp_self_test.l`.
@test_module
package Lyric.Lsp.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Json
import Std.Encoding
import Lyric.Lsp

func openDoc(state: in LspState, uri: in String, text: in String): Unit {
  val params = "{\"textDocument\":{\"uri\":" + encodeString(uri) + ",\"text\":" + encodeString(text) + "}}"
  val req = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" + params + "}"
  val _msgs = lspHandle(state, req)
}

func hoverAt(state: in LspState, uri: in String, line: in Int, character: in Int): String {
  val params = "{\"textDocument\":{\"uri\":" + encodeString(uri) + "},\"position\":{\"line\":" + ("" + line) +
    ",\"character\":" +
    ("" + character) +
    "}}"
  val req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\",\"params\":" + params + "}"
  val msgs = lspHandle(state, req)
  if msgs.count == 0 {
    ""
  } else {
    msgs[0]
  }
}

func openDocMessages(state: in LspState, uri: in String, text: in String): String {
  val params = "{\"textDocument\":{\"uri\":" + encodeString(uri) + ",\"text\":" + encodeString(text) + "}}"
  val req = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" + params + "}"
  val msgs = lspHandle(state, req)
  var all = ""
  var i = 0
  while i < msgs.count {
    all = all + msgs[i]
    i = i + 1
  }
  all
}

// #7512: the server runs the rewrites `lyric build` runs before its type
// check (`pipePrepareForCheck`), so it reports what the build reports.
test "a destructuring module val binds its names in the editor as in the build" {
  val state = lspInit()
  val src = "package P\nval (a, b) = (1, true)\nfunc f(): Int { a }\nfunc g(): Bool { b }\n"
  val msgs = openDocMessages(state, "file:///lsp_self_test_modval.l", src)
  assertTrue(Str.contains(msgs, "publishDiagnostics"), "diagnostics are published")
  assertFalse(Str.contains(msgs, "T0020"), "a and b resolve: no unknown-name diagnostic")
}

test "a refutable module val pattern is T0144 in the editor as in the build" {
  val state = lspInit()
  val msgs = openDocMessages(state, "file:///lsp_self_test_refutable.l", "package P\nval Some(x) = Some(1)\n")
  assertTrue(Str.contains(msgs, "T0144"), "refutable module val pattern: T0144")
}

test "hover on an internal record reports internal, not pub" {
  val state = lspInit()
  val uri = "file:///lsp_self_test_internal.l"
  val src = "package P\n\ninternal record Foo {\n  x: Int\n}\n"
  openDoc(state, uri, src)
  // "Foo" starts at column 16 (0-based) on line index 2: "internal record Foo {"
  val hover = hoverAt(state, uri, 2, 17)
  assertTrue(Str.contains(hover, "internal record Foo"), "hover: internal record labeled internal")
  assertFalse(Str.contains(hover, "pub record Foo"), "hover: internal record must not be mislabeled pub")
}

test "hover on a pub record still reports pub" {
  val state = lspInit()
  val uri = "file:///lsp_self_test_pub.l"
  val src = "package P\n\npub record Bar {\n  x: Int\n}\n"
  openDoc(state, uri, src)
  // "Bar" starts at column 11 (0-based) on line index 2: "pub record Bar {"
  val hover = hoverAt(state, uri, 2, 12)
  assertTrue(Str.contains(hover, "pub record Bar"), "hover: pub record still labeled pub")
}

test "hover on a private (unmarked) record reports no visibility prefix" {
  val state = lspInit()
  val uri = "file:///lsp_self_test_private.l"
  val src = "package P\n\nrecord Baz {\n  x: Int\n}\n"
  openDoc(state, uri, src)
  // "Baz" starts at column 7 (0-based) on line index 2: "record Baz {"
  val hover = hoverAt(state, uri, 2, 8)
  assertTrue(Str.contains(hover, "record Baz"), "hover: private record body present")
  assertFalse(Str.contains(hover, "pub record Baz"), "hover: private record must not be labeled pub")
  assertFalse(Str.contains(hover, "internal record Baz"), "hover: private record must not be labeled internal")
}

// ── Framing: UTF-8 byte-exact Content-Length (#7510) ─────────────────────────
// `lspEncodeFrame`/`lspScanFrame` are pure functions over `slice[Byte]` — no
// real stdin/stdout involved — so the wire framing is tested directly here,
// independent of a live LSP session.
test "encodeFrame: Content-Length is the UTF-8 byte length, not String.length, for a pure-ASCII body" {
  val json = "{\"jsonrpc\":\"2.0\"}"
  val frame = lspEncodeFrame(json)
  // Pure ASCII: UTF-8 byte length and UTF-16 code-unit length (json.length)
  // coincide, so the expected header can be built directly from json.length.
  val expectedHeader = "Content-Length: " + ("" + json.length) + "\r\n\r\n"
  assertEqualInt(frame.length, expectedHeader.length + json.length, "frame length is header bytes + body bytes")
  match lspScanFrame(frame) {
    case LspScanFrame(body, consumed) -> {
      assertEqualInt(consumed, frame.length, "whole frame consumed")
      match lspDecodeFrameBody(body) {
        case Some(decoded) -> assertEqual(decoded, json, "ASCII body round-trips")
        case None -> assertTrue(false, "ASCII body must decode as UTF-8")
      }
    }
    case _ -> assertTrue(false, "expected a complete frame")
  }
}

test "encodeFrame: Content-Length is the UTF-8 byte length for a BMP character (é, 2 bytes, 1 UTF-16 unit)" {
  val json = "{\"v\":\"é\"}"
  // json.length (UTF-16 code units) is 9; the UTF-8 encoding of é is 2
  // bytes vs. its 1 UTF-16 code unit, so the correct byte length is 10.
  assertEqualInt(json.length, 9, "sanity: UTF-16 code-unit length")
  val frame = lspEncodeFrame(json)
  match lspScanFrame(frame) {
    case LspScanFrame(body, consumed) -> {
      assertEqualInt(body.length, 10, "Content-Length must be the UTF-8 byte length (10), not json.length (9)")
      assertEqualInt(consumed, frame.length, "whole frame consumed")
      match lspDecodeFrameBody(body) {
        case Some(decoded) -> assertEqual(decoded, json, "é round-trips through UTF-8 bytes")
        case None -> assertTrue(false, "body must decode as UTF-8")
      }
    }
    case _ -> assertTrue(false, "expected a complete frame")
  }
}

test "encodeFrame: Content-Length is the UTF-8 byte length for a supplementary-plane character (😀, 4 bytes, 2 UTF-16 units)" {
  val json = "{\"v\":\"😀\"}"
  // 😀 is U+1F600: 2 UTF-16 code units in json.length, 4 UTF-8 bytes.
  assertEqualInt(json.length, 10, "sanity: UTF-16 code-unit length")
  val frame = lspEncodeFrame(json)
  match lspScanFrame(frame) {
    case LspScanFrame(body, consumed) -> {
      assertEqualInt(body.length, 12, "Content-Length must be the UTF-8 byte length (12), not json.length (10)")
      assertEqualInt(consumed, frame.length, "whole frame consumed")
      match lspDecodeFrameBody(body) {
        case Some(decoded) -> assertEqual(decoded, json, "😀 round-trips through UTF-8 bytes")
        case None -> assertTrue(false, "body must decode as UTF-8")
      }
    }
    case _ -> assertTrue(false, "expected a complete frame")
  }
}

test "two back-to-back frames split at exactly the right boundary" {
  val jsonA = "{\"v\":\"é\"}"
  val jsonB = "{\"v\":\"😀\"}"
  val combined = lspEncodeFrame(jsonA).concat(lspEncodeFrame(jsonB))
  match lspScanFrame(combined) {
    case LspScanFrame(bodyA, consumedA) -> {
      match lspDecodeFrameBody(bodyA) {
        case Some(decoded) -> assertEqual(decoded, jsonA, "first frame decodes on its own")
        case None -> assertTrue(false, "first body must decode as UTF-8")
      }
      val rest = combined.slice(consumedA, combined.length)
      match lspScanFrame(rest) {
        case LspScanFrame(bodyB, consumedB) -> {
          assertEqualInt(consumedB, rest.length, "second frame consumes exactly what's left, nothing more")
          match lspDecodeFrameBody(bodyB) {
            case Some(decoded) -> assertEqual(decoded, jsonB, "second frame decodes cleanly after the split")
            case None -> assertTrue(false, "second body must decode as UTF-8")
          }
        }
        case _ -> assertTrue(false, "expected the second frame to be complete once split off")
      }
    }
    case _ -> assertTrue(false, "expected the first frame to be complete")
  }
}

test "scanFrame: a partial header asks for more bytes, not an error" {
  val partial = encodeUtf8("Content-Length: 5\r\n")
  match lspScanFrame(partial) {
    case LspScanNeedMore -> assertTrue(true, "partial header needs more bytes")
    case _ -> assertTrue(false, "a header without the terminating blank line must not be treated as complete or bad")
  }
}

test "scanFrame: a truncated body (fewer bytes buffered than Content-Length) asks for more bytes" {
  val full = lspEncodeFrame("{\"a\":1}")
  val truncated = full.slice(0, full.length - 2)
  match lspScanFrame(truncated) {
    case LspScanNeedMore -> assertTrue(true, "short body needs more bytes, not an error")
    case _ -> assertTrue(false, "a body shorter than Content-Length must not be treated as complete or bad")
  }
}

test "scanFrame: a missing Content-Length header is a bad header, not a hang" {
  val bytes = encodeUtf8("Foo: bar\r\n\r\n{}")
  match lspScanFrame(bytes) {
    case LspScanBadHeader(message) -> assertTrue(
      Str.contains(message, "Content-Length"),
      "error names the missing header"
    )
    case _ -> assertTrue(false, "missing Content-Length must be rejected, not silently accepted")
  }
}

test "scanFrame: a non-numeric Content-Length is a bad header" {
  val bytes = encodeUtf8("Content-Length: nope\r\n\r\n")
  match lspScanFrame(bytes) {
    case LspScanBadHeader(message) -> assertTrue(Str.contains(message, "Content-Length"), "error names the bad header")
    case _ -> assertTrue(false, "a non-numeric Content-Length must be rejected")
  }
}

test "scanFrame: a negative Content-Length is a bad header" {
  val bytes = encodeUtf8("Content-Length: -1\r\n\r\n")
  match lspScanFrame(bytes) {
    case LspScanBadHeader(message) -> assertTrue(Str.contains(message, "Content-Length"), "error names the bad header")
    case _ -> assertTrue(false, "a negative Content-Length must be rejected")
  }
}

test "scanFrame: a Content-Length above the 16 MiB cap is a bad header, not an overflow panic" {
  val bytes = encodeUtf8("Content-Length: 2147483647\r\n\r\n")
  match lspScanFrame(bytes) {
    case LspScanBadHeader(message) -> assertTrue(Str.contains(message, "limit"), "error names the message limit")
    case _ -> assertTrue(false, "an over-limit Content-Length must be rejected")
  }
}

test "scanFrame: a Content-Length too large for Int is a bad header" {
  val bytes = encodeUtf8("Content-Length: 99999999999999\r\n\r\n")
  match lspScanFrame(bytes) {
    case LspScanBadHeader(message) -> assertTrue(Str.contains(message, "Content-Length"), "error names the bad header")
    case _ -> assertTrue(false, "an out-of-range Content-Length must be rejected")
  }
}

// A scripted byte source for `lspReadFrameVia`: hands out `chunks` in
// order, then end of input.
record ChunkSource {
  chunks: List[slice[Byte]]
  var next: Int
}

impl LspByteSource for ChunkSource {
  func read(): Result[Option[slice[Byte]], String] {
    if self.next >= self.chunks.count {
      return Ok(value = None)
    }
    val chunk = self.chunks[self.next]
    self.next = self.next + 1
    Ok(value = Some(value = chunk))
  }
}

record FailingSource {
  message: String
}

impl LspByteSource for FailingSource {
  func read(): Result[Option[slice[Byte]], String] {
    Err(error = self.message)
  }
}

func sourceOf(parts: in List[String]): ChunkSource {
  val chunks: List[slice[Byte]] = newList()
  var i = 0
  while i < parts.count {
    chunks.add(encodeUtf8(parts[i]))
    i = i + 1
  }
  ChunkSource(chunks = chunks, next = 0)
}

test "readFrameVia: a frame split across chunks is reassembled, then clean EOF" {
  val parts: List[String] = newList()
  parts.add("Content-Len")
  parts.add("gth: 7\r\n\r\n{\"a\"")
  parts.add(":1}")
  val src = sourceOf(parts)
  val empty: slice[Byte] = []
  val first = lspReadFrameVia(empty, src)
  match first.outcome {
    case LspReadFrame(json) -> assertEqual(json, "{\"a\":1}", "reassembled body")
    case _ -> assertTrue(false, "expected a frame")
  }
  val second = lspReadFrameVia(first.buf, src)
  match second.outcome {
    case LspReadEof -> assertTrue(true, "clean EOF between frames")
    case _ -> assertTrue(false, "expected EOF after the only frame")
  }
}

test "readFrameVia: input ending mid-frame is a truncation error, not EOF" {
  val parts: List[String] = newList()
  parts.add("Content-Length: 10\r\n\r\n{\"a\"")
  val src = sourceOf(parts)
  val empty: slice[Byte] = []
  match lspReadFrameVia(empty, src).outcome {
    case LspReadError(message) -> assertTrue(Str.contains(message, "truncated"), "error names the truncation")
    case _ -> assertTrue(false, "a mid-frame EOF must be an error")
  }
}

test "readFrameVia: bytes past one frame are kept for the next read" {
  val parts: List[String] = newList()
  parts.add("Content-Length: 2\r\n\r\n{}Content-Length: 2\r\n\r\n[]")
  val src = sourceOf(parts)
  val empty: slice[Byte] = []
  val first = lspReadFrameVia(empty, src)
  val second = lspReadFrameVia(first.buf, src)
  match second.outcome {
    case LspReadFrame(json) -> assertEqual(json, "[]", "second frame from buffered bytes")
    case _ -> assertTrue(false, "expected the second frame")
  }
}

test "readFrameVia: a read failure is reported as an error" {
  val empty: slice[Byte] = []
  match lspReadFrameVia(empty, FailingSource(message = "boom")).outcome {
    case LspReadError(message) -> assertEqual(message, "boom", "read error propagates")
    case _ -> assertTrue(false, "expected the read error")
  }
}
