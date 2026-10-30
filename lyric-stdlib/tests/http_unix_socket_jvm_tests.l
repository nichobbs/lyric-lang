//! lyric-stdlib/tests/http_unix_socket_jvm_tests.l - `Std.Http` Unix-domain-
//! socket clients on the JVM (#8560).
//!
//! `java.net.http.HttpClient` has no Unix-socket transport, so the JVM kernel
//! writes the request to a `SocketChannel` and frames the response with
//! `Std.HttpClientWire`. Each test starts a one-connection (or two, for the
//! redirect) in-process Unix-socket server on a thread and talks to it through
//! the public `Std.Http` surface.
//!
//! JVM-only: the server below uses `java.nio.channels` through test externs,
//! the same documented test-only exception as `http_server_jvm_tests.l`.
//!
//!   lyric test --target jvm lyric-stdlib/tests/http_unix_socket_jvm_tests.l
@cfg(target = "jvm")
@test_module
package Std.Http.UnixSocketJvmTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Http
import Std.Parse
import Std.String
import Std.Task
import Std.Testing

extern type JServerChannel = "java.nio.channels.ServerSocketChannel"

extern type JSocketChannel = "java.nio.channels.SocketChannel"

extern type JFamily = "java.net.StandardProtocolFamily"

extern type JUnixAddress = "java.net.UnixDomainSocketAddress"

extern type JByteBuffer = "java.nio.ByteBuffer"

extern type JThread = "java.lang.Thread"

extern type JFile = "java.io.File"

extern type JSystem = "java.lang.System"

extern type JString = "java.lang.String"

extern type JClass = "java.lang.Class"

extern type JMethod = "java.lang.reflect.Method"

extern type JObject = "java.lang.Object"

func addArg[T](args: in List[JObject], value: in T): Unit {
  args.add(value)
}

// `bind` is a Lyric keyword, so `server.bind(...)` does not parse; call it
// reflectively. `getMethods()` may list a covariant bridge twin of
// `bind(SocketAddress)`; either one binds.
func bindServer(server: in JServerChannel, address: in JUnixAddress): Unit {
  val cls: JClass = JClass.forName("java.nio.channels.ServerSocketChannel")
  val methods: slice[JMethod] = cls.getMethods()
  var i = 0
  var bound = false
  while i < methods.length and not bound {
    val m = methods[i]
    if m.getName() == "bind" and m.getParameterCount() == 1 {
      val args: List[JObject] = newList()
      addArg(args, address)
      m.invoke(server, args.toArray())
      bound = true
    }
    i = i + 1
  }
  if not bound {
    panic("ServerSocketChannel.bind not found")
  }
}

// A socket path under the system temp dir, unique per test, unbound.
func socketPath(name: in String): String {
  val path = "/tmp/lyric-unix-" + name + "-" + JSystem.nanoTime().toString() + ".sock"
  JFile.new(path).delete()
  path
}

func listen(path: in String): JServerChannel {
  val server: JServerChannel = JServerChannel.open(JFamily.UNIX)
  bindServer(server, JUnixAddress.of(path))
  server
}

// Read from `conn` until the request head (and any Content-Length body) has
// arrived; returns the whole request as text.
func readRequest(conn: in JSocketChannel): String {
  val buf: JByteBuffer = JByteBuffer.allocate(65536)
  var text = ""
  var done = false
  while not done {
    buf.clear()
    val n: Int = conn.read(buf)
    if n < 0 {
      done = true
    } else {
      val array: slice[Byte] = buf.array()
      text = text + JString.new(array, 0, n, "UTF-8")
      if text.contains("\r\n\r\n") {
        val headEnd = match indexOf(text, "\r\n\r\n") { case Some(i) -> i + 4; case None -> 0 }
        val lower = text.toLower()
        val want = match indexOf(lower, "content-length: ") {
          case Some(i) -> {
            val rest = text.substring(i + 16)
            val lineEnd = match indexOf(rest, "\r\n") { case Some(e) -> e; case None -> rest.length }
            match tryParseInt(rest.substring(0, lineEnd)) {
              case Ok(v) -> v
              case Err(_) -> 0
            }
          }
          case None -> 0
        }
        if encodeUtf8(text).length >= encodeUtf8(text.substring(0, headEnd)).length + want {
          done = true
        }
      }
    }
  }
  text
}

func writeAll(conn: in JSocketChannel, text: in String): Unit {
  val buf: JByteBuffer = JByteBuffer.wrap(encodeUtf8(text))
  while buf.hasRemaining() {
    conn.write(buf)
  }
}

// Serve `replies.count` connections in order, then stop. `seen` collects the
// request text of each.
func serve(server: in JServerChannel, replies: in List[String], seen: in List[String]): JThread {
  val thread = JThread.new(
    { ->
      var i = 0
      while i < replies.count {
        val conn: JSocketChannel = server.accept()
        seen.add(readRequest(conn))
        writeAll(conn, replies[i])
        conn.close()
        i = i + 1
      };
      ()
    }
  )
  thread.start()
  thread
}

func urlOf(raw: in String): Url {
  match Url.tryFrom(raw) {
    case Ok(u) -> u
    case Err(_) -> panic("bad test url " + raw)
  }
}

test "GET over a Unix socket returns status, headers and body" {
  val path = socketPath("get")
  val server = listen(path)
  val seen: List[String] = newList()
  val replies: List[String] = newList()
  replies.add("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
  val thread = serve(server, replies, seen)
  val client = clientWithUnixSocket(path)
  match await client.get("http://localhost/v1.43/_ping?x=1") {
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 200, "status")
      match resp.header("content-type") {
        case Some(v) -> assertEqual(v, "text/plain", "header")
        case None -> assertTrue(false, "content-type header missing")
      }
      match await resp.bodyText() {
        case Ok(text) -> assertEqual(text, "hello", "body")
        case Err(_) -> assertTrue(false, "body read failed")
      }
    }
    case Err(e) -> assertTrue(false, "request failed")
  }
  thread.join()
  server.close()
  assertTrue(seen[0].startsWith("GET /v1.43/_ping?x=1 HTTP/1.1\r\nHost: localhost\r\n"), seen[0])
}

test "a chunked response is decoded" {
  val path = socketPath("chunked")
  val server = listen(path)
  val seen: List[String] = newList()
  val replies: List[String] = newList()
  replies.add("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
  val thread = serve(server, replies, seen)
  match await clientWithUnixSocket(path).get("http://localhost/chunked") {
    case Ok(resp) -> match await resp.bodyText() {
      case Ok(text) -> assertEqual(text, "hello world", "dechunked body")
      case Err(_) -> assertTrue(false, "body read failed")
    }
    case Err(_) -> assertTrue(false, "request failed")
  }
  thread.join()
  server.close()
}

test "POST sends the body with Content-Length" {
  val path = socketPath("post")
  val server = listen(path)
  val seen: List[String] = newList()
  val replies: List[String] = newList()
  replies.add("HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")
  val thread = serve(server, replies, seen)
  match await clientWithUnixSocket(path).post("http://localhost/containers/create", "{\"Image\":\"alpine\"}") {
    case Ok(resp) -> assertEqualInt(resp.statusCode(), 201, "status")
    case Err(_) -> assertTrue(false, "request failed")
  }
  thread.join()
  server.close()
  assertTrue(seen[0].startsWith("POST /containers/create HTTP/1.1\r\n"), seen[0])
  assertTrue(seen[0].contains("Content-Length: 18\r\n"), seen[0])
  assertTrue(seen[0].endsWith("\r\n\r\n{\"Image\":\"alpine\"}"), seen[0])
}

test "a redirect is followed over the same socket unless disabled" {
  val path = socketPath("redirect")
  val server = listen(path)
  val seen: List[String] = newList()
  val replies: List[String] = newList()
  replies.add("HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\n\r\n")
  replies.add("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone")
  val thread = serve(server, replies, seen)
  match await clientWithUnixSocket(path).get("http://localhost/start") {
    case Ok(resp) -> assertEqualInt(resp.statusCode(), 200, "followed to the final response")
    case Err(_) -> assertTrue(false, "request failed")
  }
  thread.join()
  server.close()
  assertTrue(seen[1].startsWith("GET /final HTTP/1.1\r\n"), "second request targets Location: " + seen[1])

  val path2 = socketPath("noredirect")
  val server2 = listen(path2)
  val seen2: List[String] = newList()
  val replies2: List[String] = newList()
  replies2.add("HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\n\r\n")
  val thread2 = serve(server2, replies2, seen2)
  match await clientWithUnixSocketNoRedirects(path2).get("http://localhost/start") {
    case Ok(resp) -> assertEqualInt(resp.statusCode(), 302, "the redirect is returned, not followed")
    case Err(_) -> assertTrue(false, "request failed")
  }
  thread2.join()
  server2.close()
}

test "a missing socket reports a connection failure instead of dialing TCP" {
  match await clientWithUnixSocket("/nonexistent/lyric-test.sock").get("http://localhost/") {
    case Ok(_) -> assertTrue(false, "nothing listens on that path")
    case Err(_) -> ()
  }
}

test "a silent daemon fails under the cancellation deadline" {
  val path = socketPath("silent")
  val server = listen(path)
  val src = makeCancelSourceTimeout(300)
  match await clientWithUnixSocket(path).sendWithCancel(request(GET, urlOf("http://localhost/hang")), sourceToken(src)) {
    case Ok(_) -> assertTrue(false, "a silent peer cannot answer")
    case Err(_) -> assertTrue(isCancelled(sourceToken(src)), "the deadline fired")
  }
  disposeSource(src)
  server.close()
}
