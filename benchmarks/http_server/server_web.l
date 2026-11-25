//! benchmarks/http_server/server_web.l - the benchmark server over `lyric-web` (docs/73 S0).
//!
//! The same three routes as `server.l`, served through `Web.serve` over `Std.HttpServer` on every
//! target (docs/73 S6, D791). It has to be built inside the lyric-web manifest so the `Lyric.Web`
//! package resolves (the driver script does this):
//!
//!   cp benchmarks/http_server/server_web.l lyric-web/tests/zz_bench_server_web.l   # must sit inside the manifest directory
//!   (cd lyric-web && lyric build --target jvm tests/zz_bench_server_web.l -o web.jar); rm lyric-web/tests/zz_bench_server_web.l
//!
//! Configuration: `BENCH_PORT` (default 8180), and `BENCH_CERT`/`BENCH_KEY` (PEM files) for a TLS
//! listener (`Web.serveTls`), as in `server.l`. Not part of CI (see README.md).
package Web.BenchServer

import Std.Core
import Std.Collections
import Std.Console
import Std.Environment
import Std.Parse
import Std.Tls
import Web

record HelloHandler {
}

impl Web.Handler for HelloHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, "ok")
  }
}

record EchoHandler {
}

impl Web.Handler for EchoHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, req.body)
  }
}

func main(): Int {
  val port = match parseOptInt(getVarOrDefault("BENCH_PORT", "8180")) { case Some(n) -> n; case None -> 8180 }
  var router = Web.create()
  router = Web.addGet(router, "/hello", HelloHandler())
  router = Web.addPost(router, "/echo", EchoHandler())
  val cert = getVarOrDefault("BENCH_CERT", "")
  val key = getVarOrDefault("BENCH_KEY", "")
  if cert.length > 0 and key.length > 0 {
    val identity = match Identity.fromPemFiles(cert, key) {
      case Ok(id) -> id
      case Err(e) -> panic("identity: " + TlsError.message(e))
    }
    match Web.serveTls(router, "127.0.0.1", port, TlsServerConfig(identity = identity)) {
      case Ok(_) -> 0
      case Err(_) -> {
        println("serveTls failed")
        1
      }
    }
  } else {
    println("listening " + port.toString())
    Web.serve(router, "127.0.0.1", port)
    0
  }
}
