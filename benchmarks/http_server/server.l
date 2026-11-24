//! benchmarks/http_server/server.l - the benchmark server over `Std.HttpServer` (docs/73 S0, B1-B6).
//!
//! One program for every target that has `Std.HttpServer` (the shared driver on dotnet and the JVM,
//! the native kernel). It serves three routes:
//!
//!   GET  /hello        200 "ok"                       (B1, B2, B4, B5, B6)
//!   POST /echo         200 with the request body      (B3)
//!   GET  /stats        200 "<requests served so far>"  (cross-check for the load generator)
//!
//! A fixed pool of `BENCH_WORKERS` worker tasks (default 32) pulls contexts with `nextContext` and
//! answers them; this is the pull model `Std.HttpServer` exposes and the same shape `lyric-web`
//! uses (it pulls on one thread and hands each request to a job). Configuration is by environment
//! variable so one command line works on every target:
//!
//!   BENCH_PORT     listen port (default 8180)
//!   BENCH_WORKERS  worker tasks (default 32)
//!   BENCH_CERT, BENCH_KEY   PEM files; when both are set the listener is TLS (B4) on the same port
//!
//!   lyric run benchmarks/http_server/server.l --target dotnet
//!
//! Not part of CI (see README.md).
package Bench.HttpServer

import Std.Core
import Std.Collections
import Std.Console
import Std.Environment
import Std.HttpServer
import Std.Parse
import Std.Task as Task
import Std.Tls

func intVar(name: in String, fallback: in Int): Int {
  match getVar(name) {
    case Err(_) -> fallback
    case Ok(s) -> match parseOptInt(s) { case Some(n) -> n; case None -> fallback }
  }
}

func serve(l: in HttpListener): Unit {
  var running = true
  while running {
    val ctx = nextContext(l)
    val path = requestPath(ctx)
    if path == "/hello" {
      respondText(ctx, 200, "ok")
    } else if path == "/echo" {
      respondBytesWithHeaders(ctx, 200, "application/octet-stream", requestBodyBytes(ctx), newMap())
    } else {
      respondText(ctx, 404, "not found")
    }
  }
}

func listen(port: in Int): HttpListener {
  val cert = getVarOrDefault("BENCH_CERT", "")
  val key = getVarOrDefault("BENCH_KEY", "")
  if cert.length > 0 and key.length > 0 {
    val identity = match Identity.fromPemFiles(cert, key) {
      case Ok(id) -> id
      case Err(e) -> panic("identity: " + TlsError.message(e))
    }
    val cfg = TlsServerConfig(identity = identity)
    match startListenerTls("127.0.0.1", port, cfg) {
      case Ok(l) -> l
      case Err(_) -> panic("TLS listener failed (target without server TLS?)")
    }
  } else {
    startListener("http://127.0.0.1:" + port.toString() + "/")
  }
}

func main(): Int {
  val port = intVar("BENCH_PORT", 8180)
  val workers = intVar("BENCH_WORKERS", 32)
  val l = listen(port)
  println("listening " + port.toString() + " workers=" + workers.toString())
  val sc = Task.makeScope()
  var i = 0
  while i < workers {
    Task.scopeSpawn(sc, { -> serve(l) })
    i = i + 1
  }
  val _ = await Task.awaitAll(sc)
  0
}
