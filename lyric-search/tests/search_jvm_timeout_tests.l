//! tests/search_jvm_timeout_tests.l - the request deadline against a backend
//! that accepts the connection and never answers (#8571).
//!
//! `sendCatching` reports an elapsed deadline as "request timed out after N
//! ms" only on the `isCancelled` branch, which an unreachable port never
//! reaches (the connection is refused first). A `java.net.ServerSocket` that
//! is bound and never `accept`ed completes the TCP handshake in the kernel
//! backlog and then stays silent, which is exactly a hung backend.
//!
//! JVM-only: the MSIL target cannot host an accepting-but-silent in-process
//! server (`spawn` is synchronous there). The raw `ServerSocket` extern is the
//! same documented test-only exception as `http_server_jvm_tests.l`.
@cfg(target = "jvm")
@test_module
package Search

import Std.Core
import Std.Testing
import Std.Http
import Std.Collections
import Std.String as Str

extern type JServerSocket = "java.net.ServerSocket"

func silentBackend(): JServerSocket {
  JServerSocket.new(0)
}

test "a backend that accepts and never replies reports a request timeout" {
  val server = silentBackend()
  val url = "http://127.0.0.1:" + server.getLocalPort().toString()
  val cfg = HttpConfig.withRequestTimeout(HttpConfig.new(defaultClient(), url, "", ""), 400)
  match sendRequestRaw(cfg, GET, "/", "PROBE") {
    case Err(e) -> {
      assertEqual(e.code, "PROBE", "the failure carries the caller's code")
      assertTrue(Str.contains(e.message, "request timed out after 400 ms"), "the deadline is reported: " + e.message)
    }
    case Ok(_) -> assertTrue(false, "a silent backend cannot answer")
  }
  server.close()
}
