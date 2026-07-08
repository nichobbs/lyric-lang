//! Web.Kernel.Runtime (JVM) — Undertow HTTP server extern boundary.
//!
//! JVM implementation of Web's server-lifecycle contract, plus the same
//! rate limiter the `.NET` twin exposes (`_kernel/net/web_kernel.l`, same
//! package name — exactly one file is compiled per build, selected by
//! feature).
//!
//! Web.serve's dotnet branch runs its own Std.HttpServer accept loop and
//! never calls into this package.  Std.HttpServer's JVM kernel does not yet
//! expose the query-string/header/byte-body primitives Web.dispatch needs
//! (see `lyric-stdlib/std/_kernel_jvm/http_server.l`'s header comment), so
//! this kernel binds `io.undertow` directly instead of routing through
//! Std.HttpServer: Web.serve's jvm branch delegates entirely to serve()
//! below.
//!
//! Dispatch model: one `LyricUndertowHandler` — a Lyric record implementing
//! the real JDK interface `io.undertow.server.HttpHandler` via `impl`
//! (docs/51-ffi-interfaces-proposal.md; the JVM backend previously
//! resolved a single-segment `impl <ExternInterface> for Record` target
//! against the *local package* instead of the extern type's real JDK FQN,
//! so `implements` clauses against an extern interface were unreachable
//! from the JDK caller — fixed in `Jvm.Codegen.constraintRefToJvmClass`)
//! — is installed as Undertow's root handler.  Each request is read fully
//! into a `Web.Request` (blocking I/O, via `exchange.startBlocking()`),
//! routed through the same `Web.dispatch(router, req)` pure core the
//! `.NET` kernel's accept loop uses, and the resulting `Web.Response` is
//! written back onto the exchange.  Undertow's own XNIO I/O and worker
//! thread pool handles concurrent requests natively — unlike the `.NET`
//! kernel's documented single-threaded accept loop (`lyric-web/README.md`
//! "Known gaps").
//!
//! Only active when compiled with feature = "jvm".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
package Web.Kernel.Runtime

import Std.Core
import Std.Collections
import Std.Console as Console
import Web

// ─── Undertow HTTP server ───────────────────────────────────────────────────
extern type JUndertow = "io.undertow.Undertow"

extern type JUndertowBuilder = "io.undertow.Undertow$Builder"

extern type JHttpHandler = "io.undertow.server.HttpHandler"

extern type JHttpServerExchange = "io.undertow.server.HttpServerExchange"

extern type JHeaderMap = "io.undertow.util.HeaderMap"

extern type JHttpString = "io.undertow.util.HttpString"

// Real type: java.util.Collection<HttpString> (HeaderMap.getHeaderNames()).
// Phantom type param mirrors Std.CollectionsHost's MapKeyCollection/
// MapValueCollection so `for name in headerNamesOf(hm)` binds `name` to the
// instantiated element type instead of the erased java.lang.Object.
extern type JHttpStringCollection[T] = "java.util.Collection"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JString = "java.lang.String"

extern type JCountDownLatch = "java.util.concurrent.CountDownLatch"

// `await` is a Lyric keyword (structured concurrency), so `latch.await()`
// cannot be spelled as a dotted auto-FFI call — bind it explicitly instead.
@externTarget("java.util.concurrent.CountDownLatch.await")
func latchAwaitForever(latch: in JCountDownLatch): Unit = ()

func headerNamesOf(hm: in JHeaderMap): JHttpStringCollection[JHttpString] {
  hm.getHeaderNames()
}

// Lower-cased, matching Web.Request.headers' documented case-insensitive
// contract (Web.header does `name.toLower()` on lookup).  Only the first
// value per header name is kept — HeaderMap.getFirst — mirroring the .NET
// kernel's NameValueCollection.Get single-string-per-name contract closely
// enough for the shared Web.Request shape (neither backend preserves the
// full multi-value list).
func buildRequestHeaders(hm: in JHeaderMap): Map[String, String] {
  val result: Map[String, String] = newMap()
  for name in headerNamesOf(hm) {
    val key = name.toString().toLower()
    result[key] = hm.getFirst(name)
  }
  result
}

func readRequestBody(exchange: in JHttpServerExchange): String {
  val stream: JInputStream = exchange.getInputStream()
  val bytes = stream.readAllBytes()
  JString.new(bytes, "UTF-8")
}

// `pathParams` is filled in by Web.dispatch's route matching, not here —
// mirrors Web.serve's own dotnet-side buildRequest.
func buildJvmRequest(exchange: in JHttpServerExchange): Web.Request {
  val method = exchange.getRequestMethod().toString().toUpper()
  val path = exchange.getRequestPath()
  val queryParams = Web.parseQueryString(exchange.getQueryString())
  val headers = buildRequestHeaders(exchange.getRequestHeaders())
  val body = if method == "GET" or method == "HEAD" { "" } else { readRequestBody(exchange) }
  val noParams: Map[String, String] = newMap()
  Web.Request(
    method = method,
    path = path,
    pathParams = noParams,
    queryParams = queryParams,
    headers = headers,
    body = body
  )
}

func writeJvmResponse(exchange: in JHttpServerExchange, resp: in Web.Response): Unit {
  exchange.setStatusCode(resp.status)
  val respHeaders: JHeaderMap = exchange.getResponseHeaders()
  if resp.contentType.length > 0 {
    val _ = respHeaders.put(JHttpString.new("Content-Type"), resp.contentType)
  }
  val names = mapKeys(resp.headers)
  for name in names {
    match mapGet(resp.headers, name) {
      case Some(headerValue) -> {
        val v: String = headerValue
        val _ = respHeaders.put(JHttpString.new(name), v)
      }
      case None -> ()
    }
  }
  val outStream: JOutputStream = exchange.getOutputStream()
  outStream.write(resp.bodyBytes)
  outStream.close()
  val _ = exchange.endExchange()
}

record LyricUndertowHandler {
  router: Web.Router
}

impl JHttpHandler for LyricUndertowHandler {
  // The dotnet accept loop (`web.l`'s `serve`) treats an unhandled panic as
  // fatal — it logs, stops the listener, and exits the process — because
  // that single-threaded loop cannot make progress past a broken request.
  // Undertow dispatches each request on its own worker thread, so the same
  // choice would be wrong here: crashing the process on one bad request
  // would take down every other request in flight.  Instead, isolate the
  // failure to this one request — log it loudly (matching the dotnet
  // loop's "surface failures, don't go silent" intent) and return a 500
  // rather than letting the panic propagate into Undertow's own per-request
  // exception handling with no application-level logging at all.
  func handleRequest(exchange: in JHttpServerExchange): Unit {
    // getInputStream()/getOutputStream() require blocking mode; Undertow
    // completes the exchange automatically once this method returns.
    val _ = exchange.startBlocking()
    try {
      val req = buildJvmRequest(exchange)
      val resp = Web.dispatch(self.router, req)
      writeJvmResponse(exchange, resp)
    } catch Bug as e {
      Console.error("[lyric-web] request handling failed: " + e.message)
      writeJvmResponse(exchange, Web.errorResponse(Web.internalError(e.message)))
    }
  }
}

/// Start the Undertow HTTP server and block the calling thread forever
/// (until the JVM process is terminated externally — SIGTERM/SIGINT).
/// Undertow's own XNIO I/O and worker threads handle concurrent requests;
/// this call only blocks the thread that started the server.
@stable(since = "0.1")
pub func serve(host: in String, port: in Int, router: in Web.Router): Unit
  requires: host.length > 0
  requires: port >= 1
  requires: port <= 65535
{
  val handler: JHttpHandler = LyricUndertowHandler(router = router)
  val server: JUndertow = JUndertow.builder().addHttpListener(port, host).setHandler(handler).build()
  server.start()
  val latch = JCountDownLatch.new(1)
  latchAwaitForever(latch)
}

// ─── Rate limiting (tumbling window) ────────────────────────────────────────
// Mirrors the .NET kernel's algorithm (`_kernel/net/web_kernel.l`) over
// java.util.concurrent primitives instead of System.Collections.Concurrent /
// System.Threading.Monitor.  See that file for the algorithm's documented
// one-shot-burst tumbling-window semantics and the #778 sliding-window
// follow-up.
//
// Named `JvmConcurrentDict` rather than the more obvious `ConcurrentDict` to
// avoid #5443: this file and `_kernel/net/web_kernel.l` are two alternative
// sources for the SAME package (`[project.packages]` array form, selected by
// feature), and a same-named `extern type` alias bound to different host
// types in each file leaks the non-selected file's binding into the compiled
// unit on `--target jvm`.  #5458 tracks a second, previously-masked bug this
// rename exposed: JVM auto-FFI cannot resolve `dict.get(key)` from inside
// this file's own generic `cdTryGetValue[K, V]`/`cdPut[K, V]` helpers.
extern type JvmConcurrentDict[K, V] = "java.util.concurrent.ConcurrentHashMap"

@externTarget("java.util.concurrent.ConcurrentHashMap.<init>")
func newConcurrentDict[K, V](): JvmConcurrentDict[K, V] = ()

func cdTryGetValue[K, V](dict: in JvmConcurrentDict[K, V], key: in K, value: out V): Bool {
  value = dict.get(key)
  dict.containsKey(key)
}

func cdPut[K, V](dict: in JvmConcurrentDict[K, V], key: in K, value: in V): Unit {
  val _ = dict.put(key, value)
}

extern type JLock = "java.util.concurrent.locks.ReentrantLock"

@externTarget("java.util.concurrent.locks.ReentrantLock.<init>")
func newLock(): JLock = ()

@externTarget("java.lang.System.currentTimeMillis")
func currentTimeMillis(): Long = ()

record WebRateEntry {
  var windowStartMs: Long = 0i64
  var usedInWindow: Int = 0
  var burstAvailable: Int = 0
}

val webRateLock: JLock = newLock()

val webRateLimitMap: JvmConcurrentDict[String, WebRateEntry] = newConcurrentDict()

/// Check whether a call from this endpoint is within the rate limit.
/// Returns true (allow) or false (deny).  State is per-process and
/// per-endpoint; resets on process restart.
@stable(since = "0.1")
pub func checkRateLimit(endpoint: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: endpoint.length > 0
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  val nowMs = currentTimeMillis()
  webRateLock.lock()
  defer {
    webRateLock.unlock()
  }

  var re: WebRateEntry = default()
  if not cdTryGetValue(webRateLimitMap, endpoint, re) {
    val newEntry = WebRateEntry(windowStartMs = nowMs, usedInWindow = 0, burstAvailable = burstSize)
    cdPut(webRateLimitMap, endpoint, newEntry)
    var re2: WebRateEntry = default()
    if cdTryGetValue(webRateLimitMap, endpoint, re2) {
      re = re2
    } else {
      re = newEntry
    }
  }

  val elapsed: Long = nowMs - re.windowStartMs
  if elapsed >= 60000i64 {
    re.windowStartMs = nowMs
    re.usedInWindow = 0
  }

  if re.usedInWindow < requestsPerMinute {
    re.usedInWindow = re.usedInWindow + 1
    return true
  }

  if re.burstAvailable > 0 {
    re.burstAvailable = re.burstAvailable - 1
    re.usedInWindow = re.usedInWindow + 1
    return true
  }

  false
}
