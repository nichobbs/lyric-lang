//! stdlib/tests/http_bytes_body_tests.l - binary request bodies through the
//! public `Std.Http` API (`withBytesBody`), against a live `Std.HttpServer`
//! listener on the loopback interface.
//!
//! The listener echoes what it received (`requestBodyBytes`, the request
//! method, `Content-Type`, `Content-Length`, `Host` and the caller's own
//! headers), so every assertion is about the bytes and header lines that
//! actually crossed the socket:
//!
//!   * a body holding every byte value 0-255 arrives unchanged (a text body
//!     would be re-encoded as UTF-8), with the content type sent as written;
//!   * an empty body is a zero-length body, not "no body";
//!   * the header set a signed request needs (`Authorization`, `x-amz-date`,
//!     `x-amz-content-sha256`, `x-amz-meta-*`) is delivered alongside a body,
//!     and `Host` is the URL's authority;
//!   * PUT, HEAD and DELETE built with `request(method, url)` reach the server
//!     as that method, and `HttpResponse.header`/`bodyBytes` read the reply;
//!   * `HttpResponse.headerNames` lists the reply's headers, so a caller can find
//!     the ones under a prefix (`x-amz-meta-*`) without knowing their names;
//!   * `retry` replays a byte body: the first attempt fails (nothing listens
//!     yet), the second is a fresh request carrying the same bytes.
//!
//! The server runs on its own thread: a `Task.Run` worker on `--target dotnet`
//! (`spawn` is synchronous there), a `spawn` inside a `scope` on `--target
//! jvm`.  Each scenario returns a transcript, so no assertion runs while the
//! server thread is waiting, and ends by asking the server to stop.
@test_module
package Std.Http.BytesBodyTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Errors
import Std.Http
import Std.HttpServer
import Std.Sort
import Std.String as Str
import Std.Testing
import Std.Time

// ─── Echo server ─────────────────────────────────────────────────────────────
val stopPath: String = "/__stop"

func headerValue(ctx: in HttpContext, name: in String): String {
  val wanted = Str.toLower(name)
  val entries = mapEntries(requestHeaders(ctx))
  var found = "-"
  for e in entries {
    if Str.toLower(e.key) == wanted {
      found = e.value
    }
  }
  found
}

func echo(ctx: in HttpContext): Unit {
  val body = requestBodyBytes(ctx)
  val seen: Map[String, String] = newMap()
  seen.add("X-Seen-Method", requestMethod(ctx))
  seen.add("X-Seen-Path", requestPath(ctx))
  seen.add("X-Seen-Content-Type", headerValue(ctx, "Content-Type"))
  seen.add("X-Seen-Content-Length", headerValue(ctx, "Content-Length"))
  seen.add("X-Seen-Host", headerValue(ctx, "Host"))
  seen.add("X-Seen-Authorization", headerValue(ctx, "Authorization"))
  seen.add("X-Seen-Amz-Date", headerValue(ctx, "x-amz-date"))
  seen.add("X-Seen-Amz-Sha", headerValue(ctx, "x-amz-content-sha256"))
  seen.add("X-Seen-Amz-Meta", headerValue(ctx, "x-amz-meta-owner"))
  seen.add("X-Seen-Body-Hex", encodeHex(body).toLower())
  respondBytesWithHeaders(ctx, 200, "application/octet-stream", body, seen)
}

func serveUntilStopped(l: in HttpListener): Unit {
  var running = true
  while running {
    val ctx = nextContext(l)
    if requestPath(ctx) == stopPath {
      respondText(ctx, 200, "stopped")
      running = false
    } else {
      echo(ctx)
    }
  }
}

@cfg(target = "dotnet")
extern type Task = "System.Threading.Tasks.Task"

@cfg(target = "dotnet")
@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@cfg(target = "dotnet")
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

// Start the listener `delayMs` after the scenario begins, so a scenario can
// make its first attempt while nothing listens on the port.
func listenAfter(port: in Int, delayMs: in Int): Unit {
  if delayMs > 0 {
    sleepMillis(delayMs)
  }
  val l = startListener("http://127.0.0.1:" + port.toString() + "/")
  serveUntilStopped(l)
  stopListener(l)
}

@cfg(target = "dotnet")
func withEchoServer(port: in Int, delayMs: in Int, scenario: in (String) -> String): String {
  val server = taskRun({ -> listenAfter(port, delayMs) })
  if delayMs == 0 {
    sleepMillis(300)
  }
  val transcript = scenario("http://127.0.0.1:" + port.toString())
  taskWait(server)
  transcript
}

@cfg(target = "jvm")
func withEchoServer(port: in Int, delayMs: in Int, scenario: in (String) -> String): String {
  var transcript = ""
  scope {
    val server = spawn listenAfter(port, delayMs)
    if delayMs == 0 {
      sleepMillis(300)
    }
    transcript = scenario("http://127.0.0.1:" + port.toString())
    await server
  }
  transcript
}

func stopServer(baseUrl: in String): Unit {
  val _ = await defaultClient().get(baseUrl + stopPath)
}

// ─── Client helpers ──────────────────────────────────────────────────────────
func everyByte(): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < 256 {
    acc.add(i.toByte())
    i = i + 1
  }
  acc.toArray()
}

func urlOf(raw: in String): Url {
  match Url.tryFrom(raw) {
    case Ok(u) -> u
    case Err(e) -> panic("Url.tryFrom failed: " + HttpError.message(e))
  }
}

func seen(resp: in HttpResponse, name: in String): String {
  match HttpResponse.header(resp, name) {
    case Some(v) -> v
    case None -> "(absent)"
  }
}

func bodyHex(resp: in HttpResponse): String {
  match await HttpResponse.bodyBytes(resp) {
    case Ok(bytes) -> encodeHex(bytes).toLower()
    case Err(_) -> "(unreadable)"
  }
}

func describe(sent: in Result[HttpResponse, HttpError]): String {
  match sent {
    case Err(e) -> "err " + HttpError.message(e)
    case Ok(resp) -> HttpResponse.statusCode(resp).toString() + " " + seen(resp, "X-Seen-Method") + " " +
      seen(resp, "X-Seen-Path") +
      " ct=" +
      seen(resp, "X-Seen-Content-Type") +
      " len=" +
      seen(resp, "X-Seen-Content-Length") +
      " body=" +
      bodyHex(resp)
  }
}

func bytesRequest(method: in HttpMethod, url: in String, contentType: in String, bytes: in slice[Byte]): HttpRequest {
  match withBytesBody(request(method, urlOf(url)), contentType, bytes) {
    case Ok(r) -> r
    case Err(e) -> panic("withBytesBody failed: " + HttpError.message(e))
  }
}

func header(req: in HttpRequest, name: in String, value: in String): HttpRequest {
  match withHeader(req, name, value) {
    case Ok(r) -> r
    case Err(e) -> panic("withHeader failed: " + HttpError.message(e))
  }
}

// ─── Scenarios ───────────────────────────────────────────────────────────────
func binaryScenario(baseUrl: in String): String {
  val all = everyByte()
  val put = describe(await sendAsync(bytesRequest(PUT, baseUrl + "/objects/all.bin", "application/octet-stream", all)))
  val viaClient = describe(
    await defaultClient().send(bytesRequest(POST, baseUrl + "/upload", "image/png", [137u8, 80u8, 78u8, 71u8, 0u8, 255u8]))
  )
  val empty: slice[Byte] = []
  val none = describe(await sendAsync(bytesRequest(PUT, baseUrl + "/empty", "application/x-empty", empty)))
  // A text body replaced by a byte body: only the byte body is sent.
  val replaced = match withBytesBody(withTextBody(request(PUT, urlOf(baseUrl + "/replaced")), "text"), "a/b", [1u8, 2u8]) {
    case Ok(r) -> describe(await sendAsync(r))
    case Err(e) -> "err " + HttpError.message(e)
  }
  stopServer(baseUrl)
  put + "\n" + viaClient + "\n" + none + "\n" + replaced
}

func signedHeaderScenario(baseUrl: in String): String {
  var req = bytesRequest(PUT, baseUrl + "/bucket/key%20with%20space/a.txt", "text/plain", encodeUtf8("hi"))
  req = header(
    req,
    "Authorization",
    "AWS4-HMAC-SHA256 Credential=AK/20261112/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=abc"
  )
  req = header(req, "x-amz-date", "20261112T101500Z")
  req = header(req, "x-amz-content-sha256", "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4")
  req = header(req, "x-amz-meta-owner", "alice")
  var text = ""
  match await sendAsync(req) {
    case Err(e) -> {
      text = "err " + HttpError.message(e)
    }
    case Ok(resp) -> {
      text = "path=" + seen(resp, "X-Seen-Path") + "\nhost=" + seen(resp, "X-Seen-Host") + "\nauth=" +
        seen(resp, "X-Seen-Authorization") +
        "\ndate=" +
        seen(resp, "X-Seen-Amz-Date") +
        "\nsha=" +
        seen(resp, "X-Seen-Amz-Sha") +
        "\nmeta=" +
        seen(resp, "X-Seen-Amz-Meta") +
        "\nbody=" +
        bodyHex(resp)
    }
  }
  stopServer(baseUrl)
  text
}

func methodScenario(baseUrl: in String): String {
  var text = ""
  match await sendAsync(header(request(HEAD, urlOf(baseUrl + "/objects/h")), "x-amz-date", "20261112T101500Z")) {
    case Err(e) -> {
      text = text + "head err " + HttpError.message(e)
    }
    case Ok(resp) -> {
      text = text + "head " + HttpResponse.statusCode(resp).toString() + " " + seen(resp, "X-Seen-Method") + " date=" +
        seen(resp, "X-Seen-Amz-Date") +
        " ct=" +
        seen(resp, "X-Seen-Content-Type") +
        " body=" +
        bodyHex(resp)
    }
  }
  match await defaultClient().send(request(DELETE, urlOf(baseUrl + "/objects/d"))) {
    case Err(e) -> {
      text = text + "\ndelete err " + HttpError.message(e)
    }
    case Ok(resp) -> {
      text = text + "\ndelete " + HttpResponse.statusCode(resp).toString() + " " + seen(resp, "X-Seen-Method") + " " +
        seen(resp, "X-Seen-Path") +
        " ct=" +
        seen(resp, "X-Seen-Content-Type")
    }
  }
  stopServer(baseUrl)
  text
}

func headerNamesScenario(baseUrl: in String): String {
  var text = ""
  match await sendAsync(request(GET, urlOf(baseUrl + "/names"))) {
    case Err(e) -> {
      text = "err " + HttpError.message(e)
    }
    case Ok(resp) -> {
      val names = HttpResponse.headerNames(resp)
      val amz: List[String] = newList()
      var hasContentType = false
      var seenMethodCount = 0
      for name in names {
        val lower = Str.toLower(name)
        if Str.startsWith(lower, "x-seen-amz-") {
          amz.add(lower)
        }
        if lower == "content-type" {
          hasContentType = true
        }
        if lower == "x-seen-method" {
          seenMethodCount = seenMethodCount + 1
        }
      }
      text = Str.join(",", sortStrings(amz.toArray())) + "\ncontent-type=" + hasContentType.toString() + "\nx-seen-method=" +
        seenMethodCount.toString()
    }
  }
  stopServer(baseUrl)
  text
}

func retryScenario(baseUrl: in String): String {
  val text = describe(
    await retry(bytesRequest(PUT, baseUrl + "/retried", "application/octet-stream", [0u8, 128u8, 255u8]), 3, 2500i64)
  )
  stopServer(baseUrl)
  text
}

// ─── Tests ───────────────────────────────────────────────────────────────────
test "withBytesBody sends every byte value unchanged, with the content type as written" {
  val lines = Str.split(withEchoServer(19461, 0, binaryScenario), "\n")
  assertEqualInt(lines.length, 4, "four requests were described")
  val allHex = encodeHex(everyByte()).toLower()
  assertEqual(
    lines[0],
    "200 PUT /objects/all.bin ct=application/octet-stream len=256 body=" + allHex,
    "all 256 byte values through sendAsync"
  )
  assertEqual(
    lines[1],
    "200 POST /upload ct=image/png len=6 body=89504e4700ff",
    "a binary POST through HttpClient.send"
  )
  assertEqual(lines[2], "200 PUT /empty ct=application/x-empty len=0 body=", "an empty slice is a zero-length body")
  assertEqual(lines[3], "200 PUT /replaced ct=a/b len=2 body=0102", "a byte body replaces an earlier text body")
}

test "a signed-request header set travels with a byte body, and Host is the URL authority" {
  val lines = Str.split(withEchoServer(19462, 0, signedHeaderScenario), "\n")
  assertEqualInt(lines.length, 7, "seven lines: " + Str.join("|", lines))
  assertEqual(lines[0], "path=/bucket/key%20with%20space/a.txt", "the percent-encoded path is sent as written")
  assertEqual(lines[1], "host=127.0.0.1:19462", "Host is host:port of the URL")
  assertEqual(
    lines[2],
    "auth=AWS4-HMAC-SHA256 Credential=AK/20261112/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=abc",
    "Authorization"
  )
  assertEqual(lines[3], "date=20261112T101500Z", "x-amz-date")
  assertEqual(lines[4], "sha=8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4", "x-amz-content-sha256")
  assertEqual(lines[5], "meta=alice", "x-amz-meta-owner")
  assertEqual(lines[6], "body=6869", "the body")
}

test "HEAD and DELETE requests reach the server as that method" {
  val lines = Str.split(withEchoServer(19463, 0, methodScenario), "\n")
  assertEqualInt(lines.length, 2, "two lines: " + Str.join("|", lines))
  assertEqual(
    lines[0],
    "head 200 HEAD date=20261112T101500Z ct=- body=",
    "HEAD: headers are readable, no body, no Content-Type sent"
  )
  assertEqual(lines[1], "delete 200 DELETE /objects/d ct=-", "DELETE without a body sends no Content-Type")
}

test "HttpResponse.headerNames lists response headers, so a prefix can be discovered" {
  val lines = Str.split(withEchoServer(19465, 0, headerNamesScenario), "\n")
  assertEqualInt(lines.length, 3, "three lines: " + Str.join("|", lines))
  assertEqual(lines[0], "x-seen-amz-date,x-seen-amz-meta,x-seen-amz-sha", "every header under a prefix is found")
  assertEqual(lines[1], "content-type=true", "content headers are listed too")
  assertEqual(lines[2], "x-seen-method=1", "each name is listed once")
}

test "retry replays a byte body in a fresh request" {
  val text = withEchoServer(19464, 1200, retryScenario)
  assertEqual(
    text,
    "200 PUT /retried ct=application/octet-stream len=3 body=0080ff",
    "the second attempt carries the same bytes"
  )
}

test "withBytesBody rejects an empty or unsafe content type" {
  val req = request(PUT, urlOf("http://127.0.0.1:1/x"))
  match withBytesBody(req, "", [1u8]) {
    case Err(InvalidHeader(_, name)) -> assertEqual(name, "Content-Type", "the rejected header is named")
    case Err(other) -> panic("expected InvalidHeader, got: " + HttpError.message(other))
    case Ok(_) -> panic("an empty content type must be rejected")
  }
  match withBytesBody(req, "text/plain\r\nX-Injected: 1", [1u8]) {
    case Err(InvalidHeader(_, _)) -> ()
    case Err(other) -> panic("expected InvalidHeader, got: " + HttpError.message(other))
    case Ok(_) -> panic("a content type with CR/LF must be rejected")
  }
}

test "a byte-body request to a closed port is a typed ConnectionFailed, also through retry" {
  val req = bytesRequest(PUT, "http://127.0.0.1:1/x", "application/octet-stream", [1u8, 2u8, 3u8])
  match await retry(req, 2, 0i64) {
    case Err(ConnectionFailed(_, _)) -> ()
    case Err(other) -> panic("expected ConnectionFailed, got: " + HttpError.message(other))
    case Ok(_) -> panic("nothing listens on port 1")
  }
}
