//! std/_kernel_jvm/http_server.l - JVM host boundary for a minimal
//! synchronous HTTP server.
//!
//! Mirrors _kernel/http_server.l for the JVM target: the same
//! twelve-function public surface (`startListener` / `nextContext` /
//! `stopListener` / `requestMethod` / `requestPath` / `requestBody` /
//! `requestQuery` / `requestHeaders` / `urlDecode` / `respondText` /
//! `respondJson` / `respondBytesWithHeaders`) over the JDK's built-in
//! `com.sun.net.httpserver.HttpServer` via the JVM auto-FFI.  The previous
//! version routed eight of the twelve through a phantom
//! `lyric.stdlib.jvm.HttpServerHost` class that never existed at runtime,
//! which left Std.HttpServer non-functional on this target (docs/59 F-1c,
//! docs/44 m-89; the four missing functions — `requestQuery` /
//! `requestHeaders` / `urlDecode` / `respondBytesWithHeaders` — are what
//! lyric-web's static-file and dispatch layers consume).
//!
//! Pull-model bridge: `HttpServer` is callback-based (`createContext(path,
//! HttpHandler)` invokes the handler on an executor thread) while this
//! kernel's contract is pull-based (`nextContext` blocks until a request
//! lands, like .NET's `HttpListener.GetContext`).  `startListener` bridges
//! the two with an unbounded `java.util.concurrent.LinkedBlockingQueue`:
//! the registered handler (a Lyric lambda SAM-bridged to `HttpHandler`)
//! only enqueues its `HttpExchange` and returns — the exchange stays open
//! after `handle()` returns until `close()` is called, which is the JDK's
//! documented asynchronous-completion pattern — and `nextContext` is a
//! genuinely blocking `queue.take()`.  The server runs on a
//! virtual-thread-per-task executor so handler dispatch never starves
//! under concurrent connections while exchanges wait in the queue.
//!
//! Behavioural notes vs the .NET twin (both are JDK contracts, not
//! omissions):
//!
//!   - `requestHeaders` keys arrive in `com.sun.net.httpserver.Headers`'
//!     normalized capitalization (first letter of each token upper-cased,
//!     the rest lowered: "X-Req" -> "X-req").  Header names are
//!     case-insensitive per RFC 7230, and consumers (e.g. lyric-web's
//!     `normalizeHeaders`) already fold case before lookup.  Multi-valued
//!     headers are comma-joined, matching the .NET twin's
//!     `WebHeaderCollection.Get` folding.
//!   - `requestBody` decodes as UTF-8 unconditionally; the .NET twin
//!     honours the request's declared content encoding.  UTF-8 is the
//!     interoperable default for every consumer this kernel has.
//!   - `https://` prefixes on `startListener` are still rejected loudly:
//!     that function's single-string-prefix shape has no room for a TLS
//!     config, so it always builds a plaintext `HttpServer`.  Real TLS
//!     termination ships via `startListenerTls` below (docs/61 §6.3,
//!     phase 2.1 of epic #5874, issue #5880) — the `#2663` gap this
//!     header used to describe as unimplemented is closed for the
//!     non-mTLS case; see `startListenerTls`'s own doc comment for the
//!     mTLS boundary (blocked on #5930, an `HttpsConfigurator`
//!     class-subclassing FFI gap).
//!
//! `startListenerTls`'s `SSLContext` construction (below `TlsListenError`)
//! reaches into `Std.Tls`'s `Identity` via the existing `internal`
//! `Identity.rawHandle` kernel-boundary accessor (`std/tls.l`, shipped
//! alongside `Certificate.rawHandle` for docs/61 §3.2 phase 1.2's client
//! TLS wiring, and explicitly anticipating "the future server-side
//! kernels phase 2/3 add") rather than a second same-package file: a
//! `_kernel_jvm/tls_server_jvm.l` declaring `package Std.Tls` was tried
//! first and compiles cleanly, but breaks static-call resolution for
//! unrelated calls elsewhere in `Std.Tls` at JVM runtime — a real
//! compiler bug in per-package JVM source aggregation once a package
//! spans a top-level file plus an additional `_kernel_jvm/`-only file,
//! filed as #5932.
//!
//! The reflection helpers below (`findMethodByNameAndArity`/`nullOfClass`/
//! `emptyCharArrayObj`/`makeTypedArray1`/`invoke2`/`invoke3`/`invoke4`)
//! bridge a separate, real JVM auto-FFI gap: it cannot construct or pass a
//! reference-typed Java array (`Certificate[]`, `KeyManager[]`) as a call
//! argument — only *primitive* arrays get the erasure-aware coercion
//! `jvm/auto_ffi.l`'s `scoreParamMatch` implements (a Lyric `slice[T]` for
//! reference `T` always erases to `Object[]`, which the JDK rejects for a
//! `Certificate[]`/`KeyManager[]`-typed parameter — verified against
//! `KeyStore.setKeyEntry` and `SSLContext.init`). `java.lang.reflect`
//! sidesteps this legitimately: `Array.newInstance`/`Array.set` build a
//! genuinely-typed array one element at a time (each call takes a single
//! object or a class + int, never an array, so it scores fine), and
//! `Method.invoke(Object, Object...)`'s varargs parameter erases to
//! `Object[]` too — an exact match for a Lyric `slice[JObject]` argument,
//! so relaying an already-built array through it needs no coercion at
//! all. The same `Array.newInstance` + `Array.get` trick produces a
//! genuine `null` reference of any class, standing in for Lyric's lack of
//! a null literal (#4775) where the JDK API expects one
//! (`KeyStore.load(null, password)` — `null` is the documented way to
//! initialize a new empty keystore).
//!
//! A custom `impl X509KeyManager for Record` was tried first instead of
//! `KeyManagerFactory` and rejected for two independently-verified
//! reasons: (1) `impl <ExternInterface> for Record`'s JVM codegen does not
//! resolve a `slice[ExternType]` parameter/return type through the file's
//! `externTypes` map, emitting a mismatched `Object[]` descriptor that
//! throws `AbstractMethodError` the moment the JDK dispatches through the
//! interface (filed as #5931); (2) even past that, the plain
//! `X509KeyManager` interface triggers `SSLContextImpl`'s legacy
//! `AbstractKeyManagerWrapper` path under a modern `SSLEngine`-based
//! server and fails every handshake with "No available authentication
//! scheme" — the JDK wants an `X509ExtendedKeyManager`, an ABSTRACT CLASS
//! `impl` cannot target at all (filed as #5930, the same class-vs-interface
//! gap that blocks mTLS below). `KeyManagerFactory` returns a real,
//! correctly-typed, `X509ExtendedKeyManager`-compliant `KeyManager[]` and
//! never asks Lyric to implement the interface itself.
@axiom("com.sun.net.httpserver.HttpServer / javax.net.ssl / java.security / java.lang.reflect operations conform to their documented JVM contracts")
package Std.HttpServer

import Std.Core
import Std.Char
import Std.Collections
import Std.EncodingHost
import Std.Tls

// =====================================================================
// Extern types — JDK classes the helpers below reference.
// =====================================================================
extern type JHttpServer = "com.sun.net.httpserver.HttpServer"

pub extern type HttpContext = "com.sun.net.httpserver.HttpExchange"

extern type JHeaders = "com.sun.net.httpserver.Headers"

extern type JInetSocketAddress = "java.net.InetSocketAddress"

extern type JQueue = "java.util.concurrent.LinkedBlockingQueue"

extern type JExecutors = "java.util.concurrent.Executors"

extern type JString = "java.lang.String"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JIterator = "java.util.Iterator"

extern type JSet = "java.util.Set"

extern type JList = "java.util.List"

extern type JHttpsServer = "com.sun.net.httpserver.HttpsServer"

extern type JHttpsConfigurator = "com.sun.net.httpserver.HttpsConfigurator"

extern type JCertificate = "java.security.cert.Certificate"

extern type JPrivateKey = "java.security.PrivateKey"

extern type JKeyStore = "java.security.KeyStore"

extern type JKeyManager = "javax.net.ssl.KeyManager"

extern type JKeyManagerFactory = "javax.net.ssl.KeyManagerFactory"

extern type JSSLContext = "javax.net.ssl.SSLContext"

extern type JSecureRandom = "java.security.SecureRandom"

extern type JClass = "java.lang.Class"

extern type JMethod = "java.lang.reflect.Method"

extern type JReflectArray = "java.lang.reflect.Array"

extern type JObject = "java.lang.Object"

extern type JCharacter = "java.lang.Character"

/// Failure returned by `startListenerTls`. Currently only `NotSupportedOnTarget`
/// exists: mutual TLS (`requireClientCert` / `clientCa`) cannot be built
/// on this target yet (see `startListenerTls`'s doc comment); a
/// non-mTLS `startListenerTls` call never returns `Err` on the JVM
/// target today.
pub union TlsListenError {
  case NotSupportedOnTarget(message: String)
}

// =====================================================================
// java.lang.reflect bridge for building a server SSLContext (module
// header).
// =====================================================================
func findMethodByNameAndArity(cls: in JClass, name: in String, arity: in Int): JMethod {
  val methods: slice[JMethod] = cls.getMethods()
  var i = 0
  var found: Option[JMethod] = None
  while i < methods.length {
    val m = methods[i]
    if m.getName() == name and m.getParameterCount() == arity {
      found = Some(value = m)
    }
    i = i + 1
  }
  match found {
    case Some(m) -> m
    case None -> panic("Std.HttpServer: reflective method lookup failed for " + name + "/" + arity.toString())
  }
}

// A genuine `null` reference of `className`, via a fresh 1-element array
// (reference array elements are JVM-spec zero-initialized to null) —
// stands in for Lyric's lack of a null literal (#4775).
func nullOfClass(className: in String): JObject {
  val c: JClass = JClass.forName(className)
  val arr: JObject = JReflectArray.newInstance(c, 1)
  JReflectArray.get(arr, 0)
}

// An empty `char[]` (boxed as Object), used as the "no password" argument
// to KeyStore/KeyManagerFactory calls below — built via reflection so it
// never has to pass through a Lyric `slice[Char]` binding (module header:
// any array argument to a plain-`Object`-typed parameter position hits
// the same erasure gap as reference-array parameters).
func emptyCharArrayObj(): JObject {
  val charClass: JClass = JCharacter.TYPE
  JReflectArray.newInstance(charClass, 0)
}

// Builds a genuinely-typed 1-element array of `elemClassName` holding `v`.
func makeTypedArray1[T](elemClassName: in String, v: in T): JObject {
  val elemClass: JClass = JClass.forName(elemClassName)
  val arr: JObject = JReflectArray.newInstance(elemClass, 1)
  JReflectArray.set(arr, 0, v)
  arr
}

func invoke2[A, B, C](target: in A, methodName: in String, arg0: in B, arg1: in C): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 2)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  argsList.add(arg1)
  m.invoke(target, argsList.toArray())
}

func invoke3[A, B, C, D](target: in A, methodName: in String, arg0: in B, arg1: in C, arg2: in D): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 3)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  argsList.add(arg1)
  argsList.add(arg2)
  m.invoke(target, argsList.toArray())
}

func invoke4[A, B, C, D, E](target: in A, methodName: in String, arg0: in B, arg1: in C, arg2: in D, arg3: in E): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 4)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  argsList.add(arg1)
  argsList.add(arg2)
  argsList.add(arg3)
  m.invoke(target, argsList.toArray())
}

// Builds an in-memory PKCS12 keystore holding `identity`'s cert + private
// key under a fixed alias — the standard JDK way to feed a
// `KeyManagerFactory` (module header explains why this goes through the
// keystore/factory path rather than a custom `KeyManager` impl).
func buildIdentityKeyStore(identity: in Identity): JKeyStore {
  val handle = identity.rawHandle()
  val cert: JCertificate = handle.cert
  val privateKey: JPrivateKey = match handle.key {
    case Some(k) -> k
    case None -> panic("Std.HttpServer: server Identity has no private key (invariant violation)")
  }
  val ks: JKeyStore = JKeyStore.getInstance("PKCS12")
  val nullStream = nullOfClass("java.io.InputStream")
  val _load = invoke2(ks, "load", nullStream, emptyCharArrayObj())
  val certChainArr = makeTypedArray1("java.security.cert.Certificate", cert)
  val _setKey = invoke4(ks, "setKeyEntry", "lyric-server", privateKey, emptyCharArrayObj(), certChainArr)
  ks
}

func protocolNameFor(v: in TlsVersion): String {
  match v {
    case Tls12 -> "TLS"
    case Tls13 -> "TLSv1.3"
  }
}

// Build a server-identity SSLContext from `identity`, enforcing
// `minVersion` by selecting the JDK protocol algorithm name accordingly
// (`"TLS"` negotiates the JDK's full supported range — TLS 1.2 and 1.3
// today — matching the `Tls12` floor; `"TLSv1.3"` restricts negotiation
// to that version alone). No client-cert trust manager is configured
// (mTLS is not yet supported on this target — module header); the
// context trusts no client certificates, which is inert since nothing
// requests one without `HttpsParameters.setNeedClientAuth`.
func buildServerSslContext(identity: in Identity, minVersion: in TlsVersion): JSSLContext {
  val ks = buildIdentityKeyStore(identity)
  val kmf: JKeyManagerFactory = JKeyManagerFactory.getInstance(JKeyManagerFactory.getDefaultAlgorithm())
  val _init = invoke2(kmf, "init", ks, emptyCharArrayObj())
  val keyManagers: slice[JKeyManager] = kmf.getKeyManagers()
  val kmArr = makeTypedArray1("javax.net.ssl.KeyManager", keyManagers[0])
  val tmArr = nullOfClass("[Ljavax.net.ssl.TrustManager;")
  val ctx: JSSLContext = JSSLContext.getInstance(protocolNameFor(minVersion))
  val random: JSecureRandom = JSecureRandom.new()
  val _ctxInit = invoke3(ctx, "init", kmArr, tmArr, random)
  ctx
}

/// The listener handle: the running `HttpServer` plus the blocking queue
/// the SAM-bridged handler feeds and `nextContext` drains (module header).
/// A record rather than an extern alias because the pull-model bridge
/// needs both halves; the .NET twin's `HttpListener` alias is equally
/// opaque to consumers.
pub record HttpListener {
  server: JHttpServer
  queue: JQueue
}

// =====================================================================
// Prefix parsing — pure Lyric.  Accepts the same shape the .NET twin's
// `HttpListener` prefixes use: "http://<host>:<port>/<path...>", where
// <host> may be "*" or "+" for a wildcard bind and the port defaults
// to 80 when absent.
// =====================================================================
func isDigit(c: in Char): Bool {
  val cp = toInt(c)
  cp >= 48 and cp <= 57
}

func parsePort(text: in String, prefix: in String): Int {
  if text.length == 0 {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': empty port")
  }
  var value = 0
  var i = 0
  while i < text.length {
    val c = text[i]
    if not isDigit(c) {
      panic("Std.HttpServer: invalid listener prefix '" + prefix + "': non-numeric port '" + text + "'")
    }
    value = value * 10 + (toInt(c) - 48)
    i = i + 1
  }
  if value < 1 or value > 65535 {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': port out of range")
  }
  value
}

record ParsedPrefix {
  bindHost: String
  port: Int
  path: String
}

func parsePrefix(prefix: in String): ParsedPrefix {
  if prefix.startsWith("https://") {
    panic(
      "Std.HttpServer: startListener's single-string prefix has no room for a TLS " +
        "config; use startListenerTls(host, port, tls) for HTTPS listeners"
    )
  }
  if not prefix.startsWith("http://") {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': expected \"http://host:port/\"")
  }
  val rest = prefix.substring(7, prefix.length - 7)
  var slashAt = 0 - 1
  var i = 0
  while i < rest.length and slashAt < 0 {
    if rest[i] == '/' {
      slashAt = i
    }
    i = i + 1
  }
  val hostPort = if slashAt >= 0 { rest.substring(0, slashAt) } else { rest }
  val path = if slashAt >= 0 { rest.substring(slashAt, rest.length - slashAt) } else { "/" }
  var colonAt = 0 - 1
  var j = 0
  while j < hostPort.length {
    if hostPort[j] == ':' {
      colonAt = j
    }
    j = j + 1
  }
  val bindHost = if colonAt >= 0 { hostPort.substring(0, colonAt) } else { hostPort }
  val port = if colonAt >= 0 {
    parsePort(hostPort.substring(colonAt + 1, hostPort.length - colonAt - 1), prefix)
  } else {
    80
  }
  if bindHost.length == 0 {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': empty host")
  }
  ParsedPrefix(bindHost = bindHost, port = port, path = path)
}

// =====================================================================
// Public host helpers.
// =====================================================================
/// Construct + bind + start the server for `prefix` (e.g.
/// `"http://localhost:8080/"`).  The caller owns it and must call
/// `stopListener` on shutdown.  A `"*"` / `"+"` host binds the wildcard
/// address, matching the .NET twin's prefix convention.
pub func startListener(prefix: in String): HttpListener {
  val parsed = parsePrefix(prefix)
  val addr = if parsed.bindHost == "*" or parsed.bindHost == "+" {
    JInetSocketAddress.new(parsed.port)
  } else {
    JInetSocketAddress.new(parsed.bindHost, parsed.port)
  }
  val server = JHttpServer.create(addr, 0)
  val queue = JQueue.new()
  // The handler only parks the exchange for `nextContext`; responding (and
  // closing) happens on the puller's thread — the JDK keeps an exchange
  // open after `handle()` returns until it is explicitly closed.
  server.createContext(parsed.path, { ex: HttpContext -> queue.put(ex); () })
  server.setExecutor(JExecutors.newVirtualThreadPerTaskExecutor())
  server.start()
  HttpListener(server = server, queue = queue)
}

/// Construct + bind + start a TLS-terminated server on `host`:`port`,
/// built from `tls` (docs/61 §6.3, phase 2.1 of epic #5874, issue #5880).
/// The same pull-model bridge as `startListener` backs the returned
/// `HttpListener` — `nextContext`/`requestMethod`/…/`respondBytesWithHeaders`
/// work identically against a TLS listener; only construction differs.
/// A `"*"` / `"+"` host binds the wildcard address, matching
/// `startListener`'s convention. The context path is fixed at `"/"`
/// (`startListener`'s prefix-string form carries an optional path;
/// `startListenerTls`'s host/port/config shape has no room for one, and
/// every current consumer — `lyric-web`'s full-dispatch router — mounts
/// at the root anyway).
///
/// `tls.identity`'s certificate + private key become the server's TLS
/// identity via a `KeyManagerFactory`-backed `SSLContext`
/// (`buildServerSslContext` above); `tls.minVersion` restricts the
/// negotiated protocol range accordingly.
///
/// mTLS (`tls.requireClientCert` / `tls.clientCa`) is NOT yet supported
/// on this target: `com.sun.net.httpserver.HttpsServer` only applies
/// `HttpsParameters.setNeedClientAuth` through an application-supplied
/// `HttpsConfigurator.configure(...)` override, and overriding it
/// requires subclassing the concrete `HttpsConfigurator` class — Lyric's
/// `impl <ExternInterface> for Record` only implements interfaces
/// (verified empirically: `impl JHttpsConfigurator for Record` compiles
/// but throws `IncompatibleClassChangeError` at class-load time, since
/// `HttpsConfigurator` is not an interface). Requesting either field
/// returns `Err(NotSupportedOnTarget(...))` — a loud, typed rejection, never a
/// silent ignore — naming the tracking issue (#5930). Non-mTLS TLS
/// termination (identity + minVersion) is fully supported and never
/// returns `Err` on this target.
pub func startListenerTls(host: in String, port: in Int, tls: in TlsServerConfig): Result[HttpListener, TlsListenError] {
  val mtlsRequested = tls.requireClientCert or
    match tls.clientCa {
      case Some(_) -> true
      case None -> false
    }
  if mtlsRequested {
    return Err(
      error = NotSupportedOnTarget(
        message = "mutual TLS (requireClientCert / clientCa) is not yet supported on --target jvm: " +
          "com.sun.net.httpserver.HttpsServer requires overriding HttpsConfigurator.configure(...) " +
          "to call HttpsParameters.setNeedClientAuth, which needs subclassing the concrete " +
          "HttpsConfigurator class — Lyric's impl <ExternInterface> for Record only implements " +
          "interfaces (tracked in #5930)"
      )
    )
  }
  val ctx = buildServerSslContext(tls.identity, tls.minVersion)
  val addr = if host == "*" or host == "+" {
    JInetSocketAddress.new(port)
  } else {
    JInetSocketAddress.new(host, port)
  }
  val httpsServer: JHttpsServer = JHttpsServer.create(addr, 0)
  httpsServer.setHttpsConfigurator(JHttpsConfigurator.new(ctx))
  val server: JHttpServer = httpsServer
  val queue = JQueue.new()
  server.createContext("/", { ex: HttpContext -> queue.put(ex); () })
  server.setExecutor(JExecutors.newVirtualThreadPerTaskExecutor())
  server.start()
  Ok(value = HttpListener(server = server, queue = queue))
}

/// Block until the next request lands (a genuine `queue.take()`).
pub func nextContext(l: in HttpListener): HttpContext {
  val ex: HttpContext = l.queue.take()
  ex
}

/// Stop accepting connections immediately.
pub func stopListener(l: in HttpListener): Unit {
  l.server.stop(0)
}

/// HTTP method (`"GET"`, `"POST"`, ...).  Returns `"GET"` if the
/// host throws — same defensive shape as the .NET twin.
pub func requestMethod(c: in HttpContext): String {
  return try {
    c.getRequestMethod()
  } catch Bug as _ {
    "GET"
  }
}

/// Absolute path of the request URL.  Returns `"/"` if the host
/// throws — same defensive shape as the .NET twin.
pub func requestPath(c: in HttpContext): String {
  return try {
    c.getRequestURI().getPath() ?? "/"
  } catch Bug as _ {
    "/"
  }
}

/// Read the request body as a UTF-8 string (or `""` on transport error /
/// empty body).  The stream is not closed here: `HttpExchange.close()`
/// (called by every respond helper) drains and closes both directions.
pub func requestBody(c: in HttpContext): String {
  return try {
    val ins: JInputStream = c.getRequestBody()
    val bytes = ins.readAllBytes()
    JString.new(bytes, "UTF-8")
  } catch Bug as _ {
    ""
  }
}

/// Raw query string with no leading `?` (e.g. `"a=1&b=2"`), still
/// percent-escaped — matching the .NET twin's `Uri.Query` handling — or
/// `""` if the URL has none or the host throws.
pub func requestQuery(c: in HttpContext): String {
  return try {
    c.getRequestURI().getRawQuery() ?? ""
  } catch Bug as _ {
    ""
  }
}

/// Every request header as a name/value map.  Multi-valued headers are
/// comma-joined, matching HTTP's own multi-value-header folding rule
/// (RFC 7230 §3.2.2) and the .NET twin's `WebHeaderCollection.Get`.
/// Names carry the JDK's normalized capitalization ("X-req"; module
/// header) — treat them case-insensitively.  Returns an empty map if
/// the host throws.
pub func requestHeaders(c: in HttpContext): Map[String, String] {
  val result: Map[String, String] = newMap()
  try {
    val h: JHeaders = c.getRequestHeaders()
    val names: JSet = h.keySet()
    val it: JIterator = names.iterator()
    while it.hasNext() {
      val name: String = it.next()
      val values: JList = h.get(name)
      val joined: String = JString.join(",", values)
      result.add(name, joined)
    }
  } catch Bug as _ {
    ()
  }
  return result
}

func isHexDigit(c: in Char): Bool {
  val cp = toInt(c);
  (cp >= 48 and cp <= 57) or (cp >= 97 and cp <= 102) or (cp >= 65 and cp <= 70)
}

func hexDigitValue(c: in Char): Int {
  val cp = toInt(c)
  if cp >= 48 and cp <= 57 {
    return cp - 48
  }
  if cp >= 97 and cp <= 102 {
    return cp - 97 + 10
  }
  cp - 65 + 10
}

/// Percent-decode a URL-encoded string (query/path segment values),
/// matching `Uri.UnescapeDataString`: `%XX` runs decode as UTF-8 byte
/// sequences (a multi-byte code point spans consecutive `%XX` escapes,
/// so a whole run is collected before decoding), `+` is NOT treated as
/// a space, and malformed escapes pass through literally.
pub func urlDecode(s: in String): String {
  var result = ""
  val len = s.length
  var i = 0
  while i < len {
    val c = s[i]
    if c == '%' and i + 2 < len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2]) {
      val bytes: List[Byte] = newList()
      while i + 2 < len and s[i] == '%' and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2]) {
        bytes.add(hexDigitValue(s[i + 1]) * 16 + hexDigitValue(s[i + 2]))
        i = i + 3
      }
      result = result + JString.new(bytes.toArray(), "UTF-8")
    } else {
      result = result + ("" + c)
      i = i + 1
    }
  }
  result
}

// Internal: shared response writer.  Sets Content-Type plus any extra
// headers (the JDK requires all headers set before sendResponseHeaders),
// sends the status line with the exact byte length (-1 for an empty body:
// the JDK's "no response body" marker), writes the body, then closes the
// exchange — which drains any unread request body and closes both
// streams, keeping the connection reusable.
func respondBytesWith(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  headers: in Map[String, String],
): Unit {
  val respHeaders: JHeaders = c.getResponseHeaders()
  respHeaders.set("Content-Type", contentType)
  val names = mapKeys(headers).toArray()
  var i = 0
  while i < names.length {
    // Explicit String bindings force checkcasts: the slice element and the
    // Option payload are erased to Object, which Headers.add(String, String)
    // cannot take (the JVM verifier rejects the call) — same idiom as
    // _kernel_jvm/file_host.l's listChildren (#4816).
    val name: String = names[i]
    match mapGet(headers, name) {
      case Some(value) -> {
        val headerValue: String = value
        respHeaders.add(name, headerValue)
      }
      case None -> ()
    }
    i = i + 1
  }
  if body.length > 0 {
    c.sendResponseHeaders(status, intToLong(body.length))
    val os: JOutputStream = c.getResponseBody()
    os.write(body)
    os.close()
  } else {
    c.sendResponseHeaders(status, 0i64 - 1i64)
  }
  c.close()
}

func respondWith(c: in HttpContext, status: in Int, contentType: in String, body: in String): Unit {
  val empty: Map[String, String] = newMap()
  respondBytesWith(c, status, contentType, hostEncodeUtf8("utf-8", body), empty)
}

/// Reply with a plaintext body; closes the exchange.
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "text/plain; charset=utf-8", body)
}

/// Reply with `application/json`; closes the exchange.  The body is
/// passed through verbatim — pre-format with `Std.Json.encodeString`
/// and string-concat for primitive payloads, or hand-build complex
/// shapes.
pub func respondJson(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "application/json; charset=utf-8", body)
}

/// Reply with a raw byte body plus extra response headers; closes the
/// exchange.
pub func respondBytesWithHeaders(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  headers: in Map[String, String],
): Unit {
  respondBytesWith(c, status, contentType, body, headers)
}
