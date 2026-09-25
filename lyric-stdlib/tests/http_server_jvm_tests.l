//! lyric-stdlib/tests/http_server_jvm_tests.l — request-body handling of the
//! JVM `Std.HttpServer` (`com.sun.net.httpserver.HttpServer`).
//!
//! The JVM server reads each request body, bounded, before queuing the
//! exchange for `nextContext` (#7269): a body within the 10 MiB cap is
//! delivered to `requestBody`, and a larger one is answered `413` without
//! ever reaching the handler, matching the dotnet server's default
//! `EngineLimits.maxBodyBytes`. Before, `requestBody` called an unbounded
//! `readAllBytes`.
//!
//! JVM-only: the raw-socket client below uses `java.net.Socket` through test
//! externs, the same documented test-only exception as
//! `tls_server_jvm_tests.l`.
//!
//!   lyric test --target jvm lyric-stdlib/tests/http_server_jvm_tests.l
@test_module
package Std.HttpServer.JvmTests

import Std.Core
import Std.Encoding
import Std.HttpServer
import Std.String
import Std.Testing

extern type JSocket = "java.net.Socket"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JString = "java.lang.String"

extern type JThread = "java.lang.Thread"

// Send `head` then `repeats` copies of `chunk` on a fresh connection to
// `port`, and return the whole response as text.
func exchange(port: in Int, head: in String, chunk: in slice[Byte], repeats: in Int): String {
  val sock = JSocket.new("127.0.0.1", port)
  sock.setSoTimeout(10000)
  val os: JOutputStream = sock.getOutputStream()
  os.write(encodeUtf8(head))
  var i = 0
  while i < repeats {
    os.write(chunk)
    i = i + 1
  }
  os.flush()
  val ins: JInputStream = sock.getInputStream()
  val text = JString.new(ins.readAllBytes(), "UTF-8")
  sock.close()
  text
}

test "a request body within the cap reaches requestBody" {
  val listener = startListener("http://127.0.0.1:8520/")
  val server = JThread.new({ -> val ctx = nextContext(listener); respondText(ctx, 200, "got=" + requestBody(ctx)); () })
  server.start()
  JThread.sleep(200i64)
  val body = encodeUtf8("hello body")
  val resp = exchange(
    8520,
    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: " + toString(body.length) +
      "\r\nConnection: close\r\n\r\n",
    body,
    1
  )
  server.join()
  stopListener(listener)
  assertTrue(resp.contains("200"), "status 200: " + resp)
  assertTrue(resp.contains("got=hello body"), "body delivered: " + resp)
}

test "a request body over the 10 MiB cap is answered 413 and never queued" {
  // Exactly one byte over the cap: the server reads all of it (the cap, then
  // the one byte proving the overflow) before answering, so the client never
  // writes into a closed connection.
  val listener = startListener("http://127.0.0.1:8521/")
  val mib = encodeUtf8(repeat("x", 1048576))
  val total = 10 * 1048576 + 1
  val sock = JSocket.new("127.0.0.1", 8521)
  sock.setSoTimeout(10000)
  val os: JOutputStream = sock.getOutputStream()
  os.write(
    encodeUtf8("POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: " + toString(total) + "\r\nConnection: close\r\n\r\n")
  )
  var i = 0
  while i < 10 {
    os.write(mib)
    i = i + 1
  }
  os.write(encodeUtf8("x"))
  os.flush()
  val ins: JInputStream = sock.getInputStream()
  val resp = JString.new(ins.readAllBytes(), "UTF-8")
  sock.close()
  stopListener(listener)
  assertTrue(resp.startsWith("HTTP/1.1 413"), "status 413: " + resp)
}
