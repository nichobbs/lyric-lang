//! tests/otlp_jvm_collector_tests.l - OTLP/HTTP export on the JVM against an
//! in-process collector.
//!
//! The collector is a `java.net.ServerSocket` served from a `java.lang.Thread`
//! (real concurrency on the JVM). It records the request line, headers and
//! raw body bytes, so the assertions see exactly what crossed the wire: the
//! path, `Content-Type: application/x-protobuf`, the configured headers and a
//! body byte-identical to `Codec.encodeExportTraceServiceRequest` of the
//! exported spans (which `otlp_codec_tests.l` pins to hand-computed bytes).
//!
//! JVM-only: the MSIL target lowers `spawn`/threads to a synchronous form that
//! cannot host an accepting server beside its client. The raw socket and
//! thread externs are the documented test-only exception also used by
//! `lyric-search/tests/search_jvm_timeout_tests.l`.
@cfg(target = "jvm")
@test_module
package OTel.OtlpJvmCollectorTests

import Std.Core
import Std.Collections
import Std.Char
import Std.Encoding
import Std.Testing
import Std.String as Str
import OTel
import OTel.Types
import OTel.Otlp
import OTel.Otlp.Codec as Codec

extern type JServerSocket = "java.net.ServerSocket"

extern type JSocket = "java.net.Socket"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JByteArrayOutputStream = "java.io.ByteArrayOutputStream"

extern type JString = "java.lang.String"

extern type JThread = "java.lang.Thread"

// What one served request looked like on the wire.
record Captured {
  head: JByteArrayOutputStream
  body: JByteArrayOutputStream
}

func newCaptured(): Captured {
  Captured(head = JByteArrayOutputStream.new(), body = JByteArrayOutputStream.new())
}

func headText(c: in Captured): String {
  JString.new(c.head.toByteArray(), "UTF-8")
}

func bodyBytes(c: in Captured): slice[Byte] {
  c.body.toByteArray()
}

// Read the request head (through the blank line) into `head`.
func readHead(ins: in JInputStream, head: in JByteArrayOutputStream): Unit {
  var matched = 0
  var open = true
  while open {
    val b = ins.read()
    if b < 0 {
      open = false
    } else {
      head.write(b)
      // Track progress through "\r\n\r\n".
      if (matched == 0 or matched == 2) and b == 13 {
        matched = matched + 1
      } else if (matched == 1 or matched == 3) and b == 10 {
        matched = matched + 1
      } else if b == 13 {
        matched = 1
      } else {
        matched = 0
      }
      if matched == 4 {
        open = false
      }
    }
  }
}

func contentLengthOf(head: in String): Int {
  val lower = Str.toLower(head)
  val marker = "content-length:"
  val at = Str.indexOfRaw(lower, marker)
  if at < 0 {
    return 0
  }
  var i = at + marker.length
  var n = 0
  var started = false
  var done = false
  while not done and i < lower.length {
    val c = toInt(Str.charAtOrReplacement(lower, i))
    if c >= 48 and c <= 57 {
      n = n * 10 + (c - 48)
      started = true
    } else if started or c == 13 {
      done = true
    }
    i = i + 1
  }
  n
}

// Accept one connection, record the request, answer with `status` and close.
func serveOnce(server: in JServerSocket, status: in Int, cap: in Captured): Unit {
  val sock = server.accept()
  val ins: JInputStream = sock.getInputStream()
  readHead(ins, cap.head)
  val n = contentLengthOf(headText(cap))
  if n > 0 {
    cap.body.write(ins.readNBytes(n))
  }
  val os: JOutputStream = sock.getOutputStream()
  os.write(encodeUtf8("HTTP/1.1 " + status.toString() + " R\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
  os.flush()
  sock.close()
}

func serveInThread(server: in JServerSocket, status: in Int, cap: in Captured): JThread {
  val t = JThread.new({ -> serveOnce(server, status, cap); () })
  t.start()
  t
}

func urlOf(server: in JServerSocket): String {
  "http://127.0.0.1:" + server.getLocalPort().toString()
}

func bytesEqual(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

func bytesContain(hay: in slice[Byte], needle: in slice[Byte]): Bool {
  var i = 0
  while i + needle.length <= hay.length {
    var j = 0
    while j < needle.length and hay[i + j] == needle[j] {
      j = j + 1
    }
    if j == needle.length {
      return true
    }
    i = i + 1
  }
  false
}

func cfgFor(url: in String, timeoutMs: in Int, headers: in slice[OtlpHeader]): OtlpExporterConfig {
  OtlpExporterConfig(endpoint = url, protocol = OtlpProtocol.HttpProtobuf, timeoutMs = timeoutMs, headers = headers)
}

func configureTraces(cfg: in OtlpExporterConfig): Unit {
  match configureOtlpTraces(cfg) {
    case Err(e) -> assertTrue(false, "configureOtlpTraces failed: " + e)
    case Ok(_) -> {
    }
  }
}

func recordOneSpan(name: in String): Unit {
  val span = startSpan(name, 0)
  setSpanAttribute(span, "test.attr", "café")
  endSpan(span)
}

test "flushOtlpAsync POSTs the encoded trace request to /v1/traces with the configured headers" {
  val _ = globalSpanBuffer.drain()
  val server = JServerSocket.new(0)
  val cap = newCaptured()
  configureTraces(cfgFor(urlOf(server) + "/", 5000, [OtlpHeader(key = "X-Tenant", value = "acme")]))
  recordOneSpan("otlp_jvm.collector.success")
  val expected = Codec.encodeExportTraceServiceRequest(globalSpanBuffer.snapshot())
  val t = serveInThread(server, 200, cap)
  val ok = await flushOtlpAsync(5000)
  t.join()
  server.close()
  assertTrue(ok, "a 2xx response is a successful export")
  val head = headText(cap)
  assertTrue(Str.startsWith(head, "POST /v1/traces HTTP/1.1"), "request line: " + head)
  assertTrue(Str.contains(Str.toLower(head), "content-type: application/x-protobuf"), "content type: " + head)
  assertTrue(Str.contains(Str.toLower(head), "x-tenant: acme"), "configured header: " + head)
  assertTrue(bytesEqual(bodyBytes(cap), expected), "the body is the encoded ExportTraceServiceRequest")
  assertTrue(bytesContain(bodyBytes(cap), encodeUtf8("otlp_jvm.collector.success")), "the span name is on the wire")
  assertTrue(bytesContain(bodyBytes(cap), encodeUtf8("café")), "non-ASCII attribute bytes survive")
  assertEqualInt(globalSpanBuffer.count(), 0, "an exported span leaves the buffer")
}

test "a non-2xx response keeps the span buffered and the next flush retries it" {
  val _ = globalSpanBuffer.drain()
  val server = JServerSocket.new(0)
  configureTraces(cfgFor(urlOf(server), 5000, []))
  recordOneSpan("otlp_jvm.collector.retry")
  val expected = Codec.encodeExportTraceServiceRequest(globalSpanBuffer.snapshot())
  val first = newCaptured()
  val t1 = serveInThread(server, 503, first)
  val ok1 = await flushOtlpAsync(5000)
  t1.join()
  assertFalse(ok1, "503 is a failed export")
  assertEqualInt(globalSpanBuffer.count(), 1, "the span is still buffered after a 503")
  val second = newCaptured()
  val t2 = serveInThread(server, 200, second)
  val ok2 = await flushOtlpAsync(5000)
  t2.join()
  server.close()
  assertTrue(ok2, "the retry succeeds")
  assertTrue(bytesEqual(bodyBytes(first), bodyBytes(second)), "the retry resends the same batch")
  assertTrue(bytesEqual(bodyBytes(second), expected), "and it is the original encoding")
  assertEqualInt(globalSpanBuffer.count(), 0, "the buffer is empty once delivered")
}

test "a collector that accepts and never answers fails the export at the deadline" {
  val _ = globalSpanBuffer.drain()
  val silent = JServerSocket.new(0)
  configureTraces(cfgFor(urlOf(silent), 400, []))
  recordOneSpan("otlp_jvm.collector.silent")
  val ok = await flushOtlpAsync(5000)
  silent.close()
  assertFalse(ok, "a hung collector times out")
  assertEqualInt(globalSpanBuffer.count(), 1, "the span survives a timeout")
}

test "a header the HTTP stack rejects fails the export instead of dropping it" {
  val _ = globalSpanBuffer.drain()
  val server = JServerSocket.new(0)
  configureTraces(cfgFor(urlOf(server), 1000, [OtlpHeader(key = "Content-Type", value = "text/plain")]))
  recordOneSpan("otlp_jvm.collector.rejected_header")
  val ok = await flushOtlpAsync(1000)
  server.close()
  assertFalse(ok, "Content-Type is owned by the transport")
  assertEqualInt(globalSpanBuffer.count(), 1, "nothing was sent, so the span stays buffered")
}

// The exporter configuration is process-global and has no un-configure, so
// this test runs last: once metrics are configured, every later flush would
// also try to deliver them.
test "flushOtlpAsync POSTs metrics to /v1/metrics" {
  val _ = globalSpanBuffer.drain()
  val server = JServerSocket.new(0)
  val cap = newCaptured()
  match configureOtlpMetrics(cfgFor(urlOf(server), 5000, [])) {
    case Err(e) -> assertTrue(false, "configureOtlpMetrics failed: " + e)
    case Ok(_) -> {
    }
  }
  incrementCounter("otlp_jvm.requests", 3, "requests")
  recordHistogram("otlp_jvm.latency", 1.5, "ms")
  val t = serveInThread(server, 200, cap)
  val ok = await flushOtlpAsync(5000)
  t.join()
  server.close()
  assertTrue(ok, "metrics export succeeded")
  val head = headText(cap)
  assertTrue(Str.startsWith(head, "POST /v1/metrics HTTP/1.1"), "request line: " + head)
  assertTrue(Str.contains(Str.toLower(head), "content-type: application/x-protobuf"), "content type: " + head)
  assertTrue(bytesContain(bodyBytes(cap), encodeUtf8("otlp_jvm.requests")), "counter name on the wire")
  assertTrue(bytesContain(bodyBytes(cap), encodeUtf8("otlp_jvm.latency")), "histogram name on the wire")
}
