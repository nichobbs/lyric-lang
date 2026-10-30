//! lyric-stdlib/tests/http_client_wire_tests.l - corpus for
//! `Std.HttpClientWire`, the sans-IO HTTP/1.1 client codec (#8560).
//!
//! Pure Lyric with no externs, so `--target dotnet` and `--target jvm` must
//! agree. Covers request serialization (including header-injection
//! rejection), each response framing mode, interim 1xx skipping, bodiless
//! responses, and the incremental `Incomplete` contract (byte-at-a-time).
@test_module
package Std.HttpClientWire.Tests

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding
import Std.HttpEngine
import Std.HttpClientWire
import Std.Testing

func bytesOf(s: in String): slice[Byte] {
  encodeUtf8(s)
}

func textOf(bytes: in slice[Byte]): String {
  match tryDecodeUtf8(bytes) {
    case Some(s) -> s
    case None -> panic("invalid UTF-8 in fixture")
  }
}

func noHeaders(): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h
}

func headerOr(headers: in List[HeaderField], name: in String): String {
  match headerValue(headers, name) {
    case Some(v) -> v
    case None -> ""
  }
}

func expectComplete(p: in ClientParse): ClientResponse {
  match p {
    case Complete(r) -> r
    case Incomplete -> panic("expected Complete, got Incomplete")
    case Malformed(m) -> panic("expected Complete, got Malformed: " + m)
  }
}

func isIncomplete(p: in ClientParse): Bool {
  match p {
    case Incomplete -> true
    case Complete(_) -> false
    case Malformed(_) -> false
  }
}

func isMalformed(p: in ClientParse): Bool {
  match p {
    case Malformed(_) -> true
    case Incomplete -> false
    case Complete(_) -> false
  }
}

func malformedMessage(p: in ClientParse): String {
  match p {
    case Malformed(m) -> m
    case Incomplete -> "<incomplete>"
    case Complete(_) -> "<complete>"
  }
}

test "a GET request serializes with Host and Connection close" {
  match serializeClientRequest("GET", "/v1.43/containers/json?all=1", "localhost", noHeaders(), "", None) {
    case Ok(bytes) -> assertEqual(
      textOf(bytes),
      "GET /v1.43/containers/json?all=1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
      "request bytes"
    )
    case Err(e) -> assertTrue(false, e)
  }
}

test "a POST body carries Content-Type and a byte-accurate Content-Length" {
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = "X-Trace", value = "abc"))
  val body = bytesOf("{\"k\":\"é\"}")
  match serializeClientRequest("POST", "/x", "localhost", headers, "application/json", Some(value = body)) {
    case Ok(bytes) -> {
      val text = textOf(bytes)
      assertTrue(text.startsWith("POST /x HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nX-Trace: abc\r\n"), text)
      assertTrue(text.contains("Content-Type: application/json\r\n"), "content type")
      assertTrue(text.contains("Content-Length: " + body.length.toString() + "\r\n\r\n"), "UTF-8 byte length")
      assertTrue(text.endsWith("{\"k\":\"é\"}"), "body last")
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "an empty POST sends Content-Length 0" {
  match serializeClientRequest("POST", "/x", "localhost", noHeaders(), "", None) {
    case Ok(bytes) -> assertTrue(textOf(bytes).contains("Content-Length: 0\r\n\r\n"), textOf(bytes))
    case Err(e) -> assertTrue(false, e)
  }
}

test "header and target injection is rejected" {
  val bad: List[HeaderField] = newList()
  bad.add(HeaderField(name = "X-A", value = "v\r\nX-Evil: 1"))
  assertTrue(serializeClientRequest("GET", "/", "h", bad, "", None).isErr(), "CRLF in a value")
  val badName: List[HeaderField] = newList()
  badName.add(HeaderField(name = "X A", value = "v"))
  assertTrue(serializeClientRequest("GET", "/", "h", badName, "", None).isErr(), "space in a name")
  assertTrue(serializeClientRequest("GET", "/a b", "h", noHeaders(), "", None).isErr(), "space in the target")
  assertTrue(serializeClientRequest("GE T", "/", "h", noHeaders(), "", None).isErr(), "space in the method")
  val generated: List[HeaderField] = newList()
  generated.add(HeaderField(name = "content-length", value = "5"))
  assertTrue(serializeClientRequest("POST", "/", "h", generated, "", None).isErr(), "generated framing header")
}

test "a Content-Length response is complete only once the body is present" {
  val wire = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
  val full = bytesOf(wire)
  assertTrue(isIncomplete(parseClientResponse(full.slice(0, full.length - 2), false, false)), "short body")
  val r = expectComplete(parseClientResponse(full, false, false))
  assertEqualInt(r.status, 200, "status")
  assertEqual(r.reason, "OK", "reason")
  assertEqual(textOf(r.body), "hello", "body")
  assertEqual(headerOr(r.headers, "content-type"), "text/plain", "case-insensitive header lookup")
}

test "bytes beyond Content-Length are not part of the body" {
  val r = expectComplete(
    parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokEXTRA"), false, false)
  )
  assertEqual(textOf(r.body), "ok", "body is exactly Content-Length")
}

test "a chunked body is decoded, with extensions and trailers" {
  val wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-T: 1\r\n\r\n"
  val r = expectComplete(parseClientResponse(bytesOf(wire), false, false))
  assertEqual(textOf(r.body), "hello world", "dechunked")
}

test "a truncated chunked body is Incomplete, then Malformed at end of stream" {
  val bytes = bytesOf("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel")
  assertTrue(isIncomplete(parseClientResponse(bytes, false, false)), "waits for more")
  assertTrue(isMalformed(parseClientResponse(bytes, false, true)), "EOF inside the body")
}

test "a body with no framing runs to end of stream" {
  val bytes = bytesOf("HTTP/1.0 200 OK\r\n\r\nstream")
  assertTrue(isIncomplete(parseClientResponse(bytes, false, false)), "no EOF yet")
  val r = expectComplete(parseClientResponse(bytes, false, true))
  assertEqual(textOf(r.body), "stream", "body to EOF")
}

test "HEAD, 204 and 304 responses have no body despite Content-Length" {
  val head = expectComplete(parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n"), true, false))
  assertEqualInt(head.body.length, 0, "HEAD")
  val nc = expectComplete(parseClientResponse(bytesOf("HTTP/1.1 204 No Content\r\n\r\n"), false, false))
  assertEqualInt(nc.status, 204, "204")
  val nm = expectComplete(
    parseClientResponse(bytesOf("HTTP/1.1 304 Not Modified\r\nContent-Length: 4\r\n\r\n"), false, false)
  )
  assertEqualInt(nm.body.length, 0, "304")
}

test "interim 100 Continue responses are skipped" {
  val wire = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 1\r\n\r\nx"
  val r = expectComplete(parseClientResponse(bytesOf(wire), false, false))
  assertEqualInt(r.status, 201, "final status")
  assertEqual(textOf(r.body), "x", "final body")
}

test "framing conflicts and bad heads are Malformed" {
  assertTrue(
    malformedMessage(parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n"), false, false)).contains(
      "both"
    ),
    "TE and CL together"
  )
  assertTrue(
    isMalformed(
      parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"), false, false)
    ),
    "conflicting Content-Length"
  )
  assertTrue(
    isMalformed(parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n"), false, false)),
    "non-numeric length"
  )
  assertTrue(isMalformed(parseClientResponse(bytesOf("HTTP/9 200 OK\r\n\r\n"), false, false)), "bad version")
  assertTrue(isMalformed(parseClientResponse(bytesOf("HTTP/1.1 20 OK\r\n\r\n"), false, false)), "short status")
  assertTrue(
    isMalformed(parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\nBadHeader\r\n\r\n"), false, false)),
    "header without colon"
  )
  assertTrue(
    isMalformed(parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n"), false, false)),
    "unsupported coding"
  )
  assertTrue(isMalformed(parseClientResponse(bytesOf("HTTP/1.1 200 OK\r\n"), false, true)), "EOF inside the head")
}

test "feeding the response one byte at a time yields the same result" {
  val wire = bytesOf("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
  var got = false
  var n = 1
  while n <= wire.length {
    val p = parseClientResponse(wire.slice(0, n), false, false)
    if n < wire.length {
      assertTrue(isIncomplete(p), "incomplete at " + n.toString())
    } else {
      assertEqual(textOf(expectComplete(p).body), "abcde", "complete at the last byte")
      got = true
    }
    n = n + 1
  }
  assertTrue(got, "reached the end")
}
