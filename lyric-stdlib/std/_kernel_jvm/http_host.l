//! std/_kernel_jvm/http_host.l - JVM host boundary for HTTP client.
//!
//! Mirrors _kernel/http_host.l for the JVM target: the same public
//! surface (client construction, request building, the ten `*Safe`
//! wrappers, status/header/body accessors) over `java.net.http.HttpClient`
//! via the JVM auto-FFI.  The previous version routed every function
//! through phantom `lyric.stdlib.jvm.HttpClientHost` /
//! `HttpRequestBuilder` / `HttpResponseWrapper` classes that never existed
//! at runtime, which left Std.Http non-functional on this target
//! (docs/59 F-1c, docs/44 m-89).
//!
//! Representation choices:
//!
//!   - `HttpRequestMessage` is a pure-Lyric accumulation record rather
//!     than a `java.net.http.HttpRequest.Builder` alias: the JDK builder's
//!     only body-setting entry point is `method(name, publisher)`, so a
//!     later `hostWithStringBody` would need the method name back out of
//!     the builder, which the Builder interface cannot answer.  The real
//!     `HttpRequest` is built once, inside the send path.
//!   - `HttpResponseMessage` buffers status/headers/body eagerly at send
//!     time (`BodyHandlers.ofInputStream` + `readAllBytes`) — the same
//!     fully-buffered semantics as the .NET twin's default
//!     `HttpCompletionOption.ResponseContentRead`.  `ofInputStream` rather
//!     than `ofByteArray` because `HttpResponse.body()` is an erased
//!     generic (`()Ljava/lang/Object;`): a class-typed binding checkcast
//!     (`JInputStream`) is auto-FFI-expressible where an array checkcast
//!     (`[B`) is not.
//!
//! The JDK's synchronous `send(HttpRequest, BodyHandler)` blocks the
//! calling virtual thread (JEP 444); the JVM scheduler parks the carrier
//! thread on I/O without blocking the OS thread, so the `async` surface
//! below lowers to plain synchronous calls, as everywhere on this target.
//!
//! Cancellation is cooperative on this target: the JDK's synchronous
//! `send` accepts no cancellation token, so the `*WithCancel*` family
//! (a) polls the token before sending and before body reads, and (b) maps
//! a `makeCancelSourceTimeout` deadline onto `HttpRequest.Builder.timeout`
//! (the JDK's own in-flight request deadline, surfacing as
//! `HttpTimeoutException` -> `Err` through the `*Safe` wrappers).  An
//! explicit `cancelSource` fired while a request is already in flight is
//! observed at the next poll point rather than aborting the transfer —
//! the same cooperative-cancellation contract `_kernel_jvm/task.l`
//! documents for this target.
@axiom("java.net.http.HttpClient and javax.net.ssl / java.security TLS configuration operations conform to their documented JVM contracts")
@io
package Std.HttpHost

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding
import Std.HttpEngine
import Std.HttpClientWire
import Std.Task
import Std.Tls
import Std.TlsHost
import Std.TlsClientContext as Cli

// =====================================================================
// Extern types — JDK classes the helpers below reference.
// =====================================================================
extern type JHttpClient = "java.net.http.HttpClient"

extern type JHttpClientBuilder = "java.net.http.HttpClient$Builder"

extern type JRedirect = "java.net.http.HttpClient$Redirect"

// HTTP-version knob (docs/61 §5.1, D128 decision 4; #5879).  JDK 21 has no
// `HTTP_3` case — the JDK's own `HttpClient.Version` enum only distinguishes
// `HTTP_1_1`/`HTTP_2` — so `Std.Http.HttpVersion.Http3` has no dotnet-style
// "pin" here at all; it is refused entirely at the `Std.Http` layer before
// any kernel call is made (see `HttpClientImpl.unsupportedReason`).
extern type JHttpVersion = "java.net.http.HttpClient$Version"

extern type JHttpRequest = "java.net.http.HttpRequest"

extern type JHttpRequestBuilder = "java.net.http.HttpRequest$Builder"

extern type JBodyPublishers = "java.net.http.HttpRequest$BodyPublishers"

extern type JBodyHandlers = "java.net.http.HttpResponse$BodyHandlers"

extern type JHttpResponse = "java.net.http.HttpResponse"

extern type JHttpHeaders = "java.net.http.HttpHeaders"

extern type JOptional = "java.util.Optional"

extern type JMap = "java.util.Map"

extern type JIterator = "java.util.Iterator"

extern type JSSLContext = "javax.net.ssl.SSLContext"

extern type JSSLParameters = "javax.net.ssl.SSLParameters"

extern type JURI = "java.net.URI"

extern type JString = "java.lang.String"

extern type JInputStream = "java.io.InputStream"

extern type JDuration = "java.time.Duration"

extern type JSystem = "java.lang.System"

extern type JThreadCls = "java.lang.Thread"

extern type JRunnableIface = "java.lang.Runnable"

extern type JAtomicFlag = "java.util.concurrent.atomic.AtomicBoolean"

/// A client. `unixPath` is empty for the JDK transport (`jdk` is the client
/// that sends); otherwise every request is written to that Unix domain socket
/// by the pure-Lyric HTTP/1.1 codec (`Std.HttpClientWire`) and `jdk` is unused
/// (`java.net.http.HttpClient` has no Unix-socket transport, #8560).
/// `maxRedirects` is the redirect hop limit of the Unix path, 0 meaning none;
/// the JDK transport takes its redirect policy from `jdk` itself.
pub record HttpClientHandle {
  jdk: JHttpClient
  unixPath: String
  maxRedirects: Int
}

/// Request under construction: method/URL/headers/body accumulate in
/// pure Lyric; the JDK `HttpRequest` is built once in the send path
/// (module header).  `timeoutNanos` (0 = none) carries a
/// `*WithCancel*` deadline onto `HttpRequest.Builder.timeout`.
pub record HttpRequestMessage {
  method: String
  url: String
  headerNames: List[String]
  headerValues: List[String]
  contentType: String
  body: slice[Byte]
  hasBody: Bool
  timeoutNanos: Long
}

/// Response, fully buffered at send time (module header).  `version` is
/// the negotiated wire protocol (docs/61 §5.1; #5879).
pub record HttpResponseMessage {
  status: Int
  jheaders: Option[JHttpHeaders]
  wireHeaders: List[HeaderField]
  bodyBytes: slice[Byte]
  version: JHttpVersion
}

// =====================================================================
// Client construction.
// =====================================================================
// `version` (docs/61 §5.1, D128 decision 4; #5879): `HttpClient` is built
// immutably on this target — unlike the .NET twin's mutable
// `DefaultRequestVersion`/`DefaultVersionPolicy` properties, there is no
// post-construction way to change it — so every construction path takes the
// desired version up front rather than patching an already-built client.
func jdkHandle(client: in JHttpClient): HttpClientHandle {
  HttpClientHandle(jdk = client, unixPath = "", maxRedirects = 0)
}

func buildClient(followRedirects: in Bool, version: in JHttpVersion): HttpClientHandle {
  val b: JHttpClientBuilder = JHttpClient.newBuilder()
  val withRedirect: JHttpClientBuilder = if followRedirects {
    b.followRedirects(JRedirect.NORMAL)
  } else {
    b.followRedirects(JRedirect.NEVER)
  }
  val withVersion: JHttpClientBuilder = withRedirect.version(version)
  val built: JHttpClient = withVersion.build()
  jdkHandle(built)
}

// #333 parity with the .NET twin: process-wide client singleton,
// initialised once in the package `.cctor` and reused on every request.
// Redirect-following by default, matching .NET's HttpClientHandler.
// `HTTP_2` matches the JDK's own out-of-the-box default (h2-or-lower,
// falling back to HTTP/1.1) — explicit here per docs/61 §5.1 for clarity
// rather than relying on the builder's implicit default.
val processClient: HttpClientHandle = buildClient(true, JHttpVersion.HTTP_2)

pub func hostDefaultClient(): HttpClientHandle {
  processClient
}

/// Redirect-following client.  `Redirect.NORMAL` follows same-or-safer
/// scheme redirects up to the JDK's internal hop cap; the cap itself is
/// process-wide (`-Djdk.httpclient.redirects.retrylimit`), not
/// per-client, so `maxRedirects` here selects between following
/// (positive) and not following (zero or negative) rather than setting
/// an exact hop count.
pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle {
  buildClient(maxRedirects > 0, JHttpVersion.HTTP_2)
}

pub func hostClientNoRedirects(): HttpClientHandle {
  buildClient(false, JHttpVersion.HTTP_2)
}

// ---------------------------------------------------------------------------
// HTTP/1.1 exact-pin variants (docs/61 §5.1, D128 decision 4; #5879) —
// mirrors `_kernel/http_host.l`'s `hostClient*Http11` family so `Std.Http`'s
// `HttpClientBuilder.build()` calls the same-named function on either
// kernel.
// ---------------------------------------------------------------------------
pub func hostClientHttp11(): HttpClientHandle {
  buildClient(true, JHttpVersion.HTTP_1_1)
}

pub func hostClientWithRedirectsHttp11(maxRedirects: in Int): HttpClientHandle {
  buildClient(maxRedirects > 0, JHttpVersion.HTTP_1_1)
}

pub func hostClientNoRedirectsHttp11(): HttpClientHandle {
  buildClient(false, JHttpVersion.HTTP_1_1)
}

// ---------------------------------------------------------------------------
// Unix domain socket support (#8560).  `java.net.http.HttpClient` exposes no
// Unix-socket transport, so a Unix-socket client writes each request to a
// `java.nio.channels.SocketChannel` itself and parses the response with the
// sans-IO `Std.HttpClientWire` codec (transport below, "Unix domain socket
// transport").  HTTP/1.1 only, so the `*Http11` variants are the plain ones.
// ---------------------------------------------------------------------------
/// Redirect hop limit of a Unix-socket client built without an explicit
/// `maxRedirects`; .NET's `SocketsHttpHandler.MaxAutomaticRedirections`
/// default, which the dotnet kernel's Unix-socket client follows.
val DEFAULT_UNIX_REDIRECTS: Int = 50

func unixHandle(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  HttpClientHandle(
    jdk = processClient.jdk,
    unixPath = socketPath,
    maxRedirects = if maxRedirects > 0 { maxRedirects } else { 0 }
  )
}

pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle {
  unixHandle(socketPath, DEFAULT_UNIX_REDIRECTS)
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixHandle(socketPath, maxRedirects)
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle {
  unixHandle(socketPath, 0)
}

pub func hostClientWithUnixSocketHttp11(socketPath: in String): HttpClientHandle {
  unixHandle(socketPath, DEFAULT_UNIX_REDIRECTS)
}

pub func hostClientWithUnixSocketAndRedirectsHttp11(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixHandle(socketPath, maxRedirects)
}

pub func hostClientWithUnixSocketNoRedirectsHttp11(socketPath: in String): HttpClientHandle {
  unixHandle(socketPath, 0)
}

// ---------------------------------------------------------------------------
// TLS client configuration (docs/61 §3.2, D128; phase 1.3, #5878) — the JVM
// twin of `_kernel/http_host.l`'s `applyTlsOptions`/`hostClientWithTls`.
//
// `Std.Http.HttpClientBuilder.build()` calls `hostSupportsTlsConfig()` BEFORE
// ever attempting kernel-level TLS wiring; it now returns `true` on this
// target, so `build()` routes a TLS-configured builder into
// `hostClientWithTls` below exactly as it already does on `--target dotnet`.
//
// Trust model, and why it differs in SHAPE from the dotnet kernel even
// though the OUTCOME (docs/61 §3.2/§4's policy matrix) is identical:
// `java.net.http.HttpClient` has no per-request certificate-validation
// CALLBACK the way `HttpClientHandler.ServerCertificateCustomValidationCallback`
// does — TLS trust on this target is configured once, structurally, via a
// `KeyStore` fed to a `TrustManagerFactory`, which the JDK's own PKIX path
// builder then validates every handshake against. So instead of mirroring
// `resolveTlsValidationDecision`'s "ask the platform, then decide whether to
// fall back to a custom chain" callback shape, this kernel builds the
// KeyStore itself (in `Std.TlsClientContext`, `_kernel_jvm/tls_client_context.l`,
// the one construction site shared with `Std.TcpHost`'s client TLS):
//   - **Additive** (`withCaCertificate`): a KeyStore containing the
//     configured CA PLUS every certificate the platform's own default
//     `TrustManagerFactory` reports as an accepted issuer (`systemTrustAnchors`
//     in `Std.TlsClientContext`) — a chain that validates against EITHER trust anchor set
//     validates overall, matching "ADDITIONAL trust root" (`Std.Http`'s
//     `withCaCertificate` doc comment).
//   - **Exclusive** (`withExclusiveCaCertificate`): a KeyStore containing
//     ONLY the configured CA — the platform trust store is never consulted,
//     matching "REPLACES the platform trust store entirely".
//   - **Neither configured** (client identity and/or minTlsVersion only):
//     a `TrustManagerFactory` initialised with a `null` KeyStore, the
//     documented JDK idiom for "use the platform default" — identical
//     behaviour to an unconfigured client.
// `resolveCaMode` (below) still picks between these three exactly as it
// does on dotnet — the exclusive-wins precedence rule (#5975) is
// target-neutral pure logic and is reused, not re-derived.
//
// Hostname verification — the load-bearing security property #5950 fixed on
// dotnet — is NEVER at risk of the same regression here, for a structural
// reason rather than a callback discipline: `java.net.http.HttpClient`
// performs its own endpoint-identification check independently of whatever
// `SSLContext`/`SSLParameters` the caller supplies, and does so
// UNCONDITIONALLY — verified empirically (see `clientSslParameters`'s
// doc comment in `Std.TlsClientContext`): even installing a custom, all-trusting
// `X509TrustManager` and explicitly clearing
// `SSLParameters.setEndpointIdentificationAlgorithm` could not make this
// target accept a certificate issued for the wrong hostname. There is
// consequently no "callback that forgot to check hostname" bug class
// possible on this target at all — chain trust (KeyStore-driven) and
// hostname matching (enforced by the JDK's `HttpClient` implementation
// itself, never by kernel code) are two independent, non-overridable
// checks. `setEndpointIdentificationAlgorithm("HTTPS")` is still set
// explicitly on every non-insecure path below anyway, matching the
// defence-in-depth posture #5878 was asked to preserve, even though this
// target's own enforcement does not depend on it.
//
// `TlsCaMode`/`resolveCaMode`/`TlsValidationDecision`/`resolveTlsValidationDecision`
// remain declared (mirrored verbatim from the dotnet twin, as before) so
// `http_tls_client_tests.l`'s exhaustive #5950/#5975 regression coverage
// keeps running identically on both targets — target-neutral pure logic,
// no BCL dependency. `resolveCaMode` IS now genuinely consumed by
// `clientTrustSource` below; `resolveTlsValidationDecision`/
// `TlsValidationDecision` are not — this target's real trust decision is
// the JDK's own PKIX path validator over the KeyStore built above, not a
// hand-rolled decision core, so there is nothing here for that callback
// shape to drive. It stays for cross-target parity of the tested pure
// function, not because a caller invokes it.
// ---------------------------------------------------------------------------
pub func hostSupportsTlsConfig(): Bool {
  true
}

pub enum TlsCaMode {
  case NoCaConfigured
  case AdditiveCa
  case ExclusiveCa
}

// Precedence rule when both `withCaCertificate` and
// `withExclusiveCaCertificate` are configured on the same builder
// (#5975) — mirrored verbatim from the dotnet twin; see that file's doc
// comment for the full rationale. Exclusive always wins. Genuinely
// consumed by `clientTrustSource` below (module header).
@pure
pub func resolveCaMode(caCertificate: in Option[Certificate], exclusiveCaCertificate: in Option[Certificate]): TlsCaMode {
  match exclusiveCaCertificate {
    case Some(_) -> ExclusiveCa
    case None -> match caCertificate { case Some(_) -> AdditiveCa; case None -> NoCaConfigured }
  }
}

pub enum TlsValidationDecision {
  case RejectImmediately
  case AcceptWithoutCustomChain
  case TryCustomChain
}

// Kept for cross-target #5950 regression parity in `http_tls_client_tests.l`
// (module header) — not called by this target's real wiring.
@pure
pub func resolveTlsValidationDecision(
  hostnameAndAvailabilityOk: in Bool, chainAlreadyOk: in Bool, caMode: in TlsCaMode
): TlsValidationDecision {
  if not hostnameAndAvailabilityOk {
    RejectImmediately
  } else {
    match caMode {
      case ExclusiveCa -> TryCustomChain
      case AdditiveCa -> if chainAlreadyOk { AcceptWithoutCustomChain } else { TryCustomChain }
      case NoCaConfigured -> if chainAlreadyOk { AcceptWithoutCustomChain } else { RejectImmediately }
    }
  }
}

// Which trust source a builder's CA options select; `insecureSkipVerify` (already
// resolved through the dual-key policy by `Std.Http`) wins over both, then an
// exclusive CA over an additive one (`resolveCaMode`, #5975).
func clientTrustSource(
  caCertificate: in Option[Certificate],
  exclusiveCaCertificate: in Option[Certificate],
  insecureSkipVerify: in Bool,
): Cli.ClientTrustSource {
  if insecureSkipVerify {
    Cli.NoVerification
  } else {
    match resolveCaMode(caCertificate, exclusiveCaCertificate) {
      case ExclusiveCa -> match exclusiveCaCertificate {
        case Some(cert) -> Cli.ExclusiveTrust(anchors = Certificate.rawHandles(cert))
        case None -> Cli.PlatformTrust
      }
      case AdditiveCa -> match caCertificate {
        case Some(cert) -> Cli.AdditiveTrust(anchors = Certificate.rawHandles(cert))
        case None -> Cli.PlatformTrust
      }
      case NoCaConfigured -> Cli.PlatformTrust
    }
  }
}

// The single entry point for every TLS-configured client — mirrors
// `_kernel/http_host.l`'s `hostClientWithTls` signature exactly (`Std.Http`
// calls whichever kernel's copy the active `--target` resolves to). Redirect
// handling mirrors the existing non-TLS `hostClient*`/`hostClientWithRedirects`
// family: `noRedirects` wins outright, otherwise a positive `maxRedirects`
// follows redirects (the hop CAP itself is process-wide on this target —
// module header on `hostClientWithRedirects` above — not configurable
// per-client), and no explicit redirect configuration defaults to following,
// matching `hostDefaultClient`.
pub func hostClientWithTls(
  maxRedirects: in Option[Int],
  noRedirects: in Bool,
  pinHttp11: in Bool,
  caCertificate: in Option[Certificate],
  exclusiveCaCertificate: in Option[Certificate],
  clientIdentity: in Option[Identity],
  minTlsVersion: in Option[TlsVersion],
  insecureSkipVerify: in Bool,
): HttpClientHandle {
  val built = Cli.clientSslContext(
    clientTrustSource(caCertificate, exclusiveCaCertificate, insecureSkipVerify),
    clientIdentity
  )
  val ctx: JSSLContext = Cli.ClientSslContext.rawContext(built)
  val params: JSSLParameters = Cli.clientSslParameters(ctx, minTlsVersion, not insecureSkipVerify)
  val followRedirects = if noRedirects {
    false
  } else {
    match maxRedirects {
      case Some(n) -> n > 0
      case None -> true
    }
  }
  val version: JHttpVersion = if pinHttp11 { JHttpVersion.HTTP_1_1 } else { JHttpVersion.HTTP_2 }
  val b: JHttpClientBuilder = JHttpClient.newBuilder()
  val withRedirect: JHttpClientBuilder = if followRedirects {
    b.followRedirects(JRedirect.NORMAL)
  } else {
    b.followRedirects(JRedirect.NEVER)
  }
  val withVersion: JHttpClientBuilder = withRedirect.version(version)
  val withCtx: JHttpClientBuilder = withVersion.sslContext(ctx)
  val withParams: JHttpClientBuilder = withCtx.sslParameters(params)
  val built: JHttpClient = withParams.build()
  jdkHandle(built)
}

// =====================================================================
// Request construction.
// =====================================================================
pub func hostMakeRequest(httpMethod: in String, url: in String): HttpRequestMessage {
  val names: List[String] = newList()
  val values: List[String] = newList()
  val noBody: slice[Byte] = []
  HttpRequestMessage(
    method = httpMethod,
    url = url,
    headerNames = names,
    headerValues = values,
    contentType = "",
    body = noBody,
    hasBody = false,
    timeoutNanos = 0i64
  )
}

/// Framing headers `hostMakeRequest`/`hostWithStringBody` and this kernel's
/// own request builder (below) generate automatically (`Host`, `Connection`
/// on the request; `Content-Type`/`Content-Length` on the content once a
/// body is attached). Letting a caller add one of these via
/// `hostWithHeader` produces a duplicate header line on the wire once the
/// automatic one is appended — request-smuggling-adjacent, since which of
/// two duplicate headers a peer honors is implementation-defined (RFC 9112
/// §5.1) — so `hostWithHeader` rejects them instead (#6658). Case-
/// insensitive per RFC 9110 §5.1 (header field names are case-
/// insensitive). Mirrored verbatim in `_kernel/http_host.l` and
/// `_kernel_native/http_host.l`. (`java.net.http.HttpRequest.Builder.header`
/// already throws `IllegalArgumentException` for a subset of these
/// — connection/content-length/expect/host/upgrade — but rejecting here
/// gives a typed `Result` uniformly across all three kernels instead of an
/// unhandled exception on this target alone.)
func isReservedFramingHeader(name: in String): Bool {
  val lower = name.toLower()
  lower == "host" or lower == "connection" or lower == "content-type" or lower == "content-length"
}

pub func hostWithHeader(
  request: in HttpRequestMessage, key: in String, value: in String
): Result[HttpRequestMessage, String] {
  if isReservedFramingHeader(key) {
    return Err(error = key)
  }
  request.headerNames.add(key)
  request.headerValues.add(value)
  return Ok(value = request)
}

pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage {
  hostWithBytesBody(request, contentType, encodeUtf8(body))
}

pub func hostWithBytesBody(
  request: in HttpRequestMessage, contentType: in String, body: in slice[Byte]
): HttpRequestMessage {
  HttpRequestMessage(
    method = request.method,
    url = request.url,
    headerNames = request.headerNames,
    headerValues = request.headerValues,
    contentType = contentType,
    body = body,
    hasBody = true,
    timeoutNanos = request.timeoutNanos
  )
}

func withTimeoutNanos(request: in HttpRequestMessage, nanos: in Long): HttpRequestMessage {
  HttpRequestMessage(
    method = request.method,
    url = request.url,
    headerNames = request.headerNames,
    headerValues = request.headerValues,
    contentType = request.contentType,
    body = request.body,
    hasBody = request.hasBody,
    timeoutNanos = nanos
  )
}

// =====================================================================
// Send path (internal).
// =====================================================================
func buildJavaRequest(request: in HttpRequestMessage): JHttpRequest {
  var b: JHttpRequestBuilder = JHttpRequest.newBuilder()
  b = b.uri(JURI.create(request.url))
  var i = 0
  while i < request.headerNames.count {
    val name: String = request.headerNames[i]
    val value: String = request.headerValues[i]
    b = b.header(name, value)
    i = i + 1
  }
  if request.timeoutNanos > 0i64 {
    b = b.timeout(JDuration.ofNanos(request.timeoutNanos))
  }
  if request.hasBody {
    b = b.header("Content-Type", request.contentType)
    b = b.method(request.method, JBodyPublishers.ofByteArray(request.body))
  } else {
    b = b.method(request.method, JBodyPublishers.noBody())
  }
  b.build()
}

// Close on the failure path too, so a transfer aborted mid-body does not
// leak the connection's stream until GC (the _kernel_jvm/file_host.l
// hostReadAllBytes idiom, #4780).
func readAllAndClose(ins: in JInputStream): slice[Byte] {
  try {
    val bytes = ins.readAllBytes()
    ins.close()
    bytes
  } catch Bug as b {
    ins.close()
    panic(b.message)
  }
}

// The text every kernel reports for a send that ended because its deadline
// passed; `Std.Http` turns exactly this into `HttpError.Timeout`.
val timedOutText: String = "request timed out"

pub func hostTimeoutMessage(): String {
  timedOutText
}

// Closes `ins` when `deadlineNanos` (a `System.nanoTime()` instant) passes
// before the reader has claimed `state`. The JDK's request timeout covers only
// the time until the response headers arrive, so a body that stalls would
// otherwise hold the call past its deadline; closing the stream from another
// thread is what unblocks a blocked `read`. The reader interrupts this thread
// once it is done, so a fast response does not leave a sleeper behind.
ref record BodyWatchdog {
  ins: JInputStream
  deadlineNanos: Long
  state: JAtomicFlag
}

func sleepNanos(nanos: in Long): Unit {
  JThreadCls.sleep(nanos / 1000000i64, (nanos % 1000000i64).toInt())
}

impl JRunnableIface for BodyWatchdog {
  func run(): Unit {
    try {
      val remaining = self.deadlineNanos - JSystem.nanoTime()
      if remaining > 0i64 {
        sleepNanos(remaining)
      }
      if self.state.compareAndSet(false, true) {
        self.ins.close()
      }
    } catch Bug as _ {
      ()
    }
  }
}

// Reads the whole body, ending the call at `deadlineNanos` (0 = no deadline)
// with `timedOutText`.
func readAllWithin(ins: in JInputStream, deadlineNanos: in Long): slice[Byte] {
  if deadlineNanos == 0i64 {
    return readAllAndClose(ins)
  }
  val state: JAtomicFlag = JAtomicFlag.new(false)
  val dog = BodyWatchdog(ins = ins, deadlineNanos = deadlineNanos, state = state)
  val watcher: JThreadCls = JThreadCls.startVirtualThread(dog)
  try {
    val bytes = ins.readAllBytes()
    if not state.compareAndSet(false, true) {
      panic(timedOutText)
    }
    watcher.interrupt()
    ins.close()
    bytes
  } catch Bug as b {
    val expired = not state.compareAndSet(false, true)
    watcher.interrupt()
    ins.close()
    if expired {
      panic(timedOutText)
    }
    panic(b.message)
  }
}

func doSend(client: in HttpClientHandle, request: in HttpRequestMessage): HttpResponseMessage {
  if client.unixPath.length > 0 {
    return doSendUnix(client, request)
  }
  val deadlineNanos = if request.timeoutNanos > 0i64 { JSystem.nanoTime() + request.timeoutNanos } else { 0i64 }
  val jreq = buildJavaRequest(request)
  val jdk: JHttpClient = client.jdk
  val resp: JHttpResponse = jdk.send(jreq, JBodyHandlers.ofInputStream())
  val ins: JInputStream = resp.body()
  val bytes = readAllWithin(ins, deadlineNanos)
  val headers: JHttpHeaders = resp.headers()
  HttpResponseMessage(
    status = resp.statusCode(),
    jheaders = Some(value = headers),
    wireHeaders = noWireHeaders(),
    bodyBytes = bytes,
    version = resp.version()
  )
}

// Apply a `makeCancelSourceTimeout` deadline as the JDK request timeout
// (module header).  A poll-race where the deadline elapses between the
// caller's `throwIfCancelled` and here still panics the same way the
// poll would, rather than handing `Duration.ofNanos` a non-positive value.
func withCancelDeadline(request: in HttpRequestMessage, token: in CancellationToken): HttpRequestMessage {
  if token.deadlineMs > 0i64 {
    val remaining = token.deadlineMs - JSystem.nanoTime()
    if remaining <= 0i64 {
      panic("OperationCanceledException: cancellation was requested")
    }
    withTimeoutNanos(request, remaining)
  } else {
    request
  }
}

func doGet(client: in HttpClientHandle, url: in String): HttpResponseMessage {
  doSend(client, hostMakeRequest("GET", url))
}

func doPostString(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): HttpResponseMessage {
  doSend(client, hostWithStringBody(hostMakeRequest("POST", url), contentType, body))
}

// =====================================================================
// Unix domain socket transport (#8560).
// =====================================================================
// One connection per request (`Connection: close`).  The channel is
// non-blocking and driven by a `Selector` so a `makeCancelSourceTimeout`
// deadline bounds the write and the read, which a blocking channel cannot
// honour.  The response is read to end of stream and handed to
// `Std.HttpClientWire.parseClientResponse`, which frames it.
extern type JSocketChannel = "java.nio.channels.SocketChannel"

extern type JUnixSocketAddress = "java.net.UnixDomainSocketAddress"

extern type JSelector = "java.nio.channels.Selector"

extern type JSelectionKey = "java.nio.channels.SelectionKey"

extern type JByteBuffer = "java.nio.ByteBuffer"

extern type JByteArrayOutputStream = "java.io.ByteArrayOutputStream"

extern type JSet = "java.util.Set"

val OP_READ: Int = 1

val OP_WRITE: Int = 4

val UNIX_READ_BUFFER_BYTES: Int = 65536

func noWireHeaders(): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h
}

/// Block until the channel is ready for `ops` or `deadlineNanos` (an absolute
/// `System.nanoTime()` value, 0 for none) passes; panics with the JDK's own
/// timeout wording on expiry.
func awaitReady(selector: in JSelector, key: in JSelectionKey, ops: in Int, deadlineNanos: in Long): Unit {
  key.interestOps(ops)
  if deadlineNanos > 0i64 {
    val remainingNanos = deadlineNanos - JSystem.nanoTime()
    if remainingNanos <= 0i64 {
      panic("request timed out")
    }
    val remainingMs = remainingNanos / 1000000i64 + 1i64
    selector.select(remainingMs)
  } else {
    selector.select()
  }
  val selected: JSet = selector.selectedKeys()
  selected.clear()
}

func writeFully(
  channel: in JSocketChannel,
  selector: in JSelector,
  key: in JSelectionKey,
  bytes: in slice[Byte],
  deadlineNanos: in Long,
): Unit {
  val buf: JByteBuffer = JByteBuffer.wrap(bytes)
  while buf.hasRemaining() {
    val n: Int = channel.write(buf)
    if n == 0 {
      awaitReady(selector, key, OP_WRITE, deadlineNanos)
    }
  }
}

func readToEnd(
  channel: in JSocketChannel, selector: in JSelector, key: in JSelectionKey, deadlineNanos: in Long
): slice[Byte] {
  val sink: JByteArrayOutputStream = JByteArrayOutputStream.new()
  val buf: JByteBuffer = JByteBuffer.allocate(UNIX_READ_BUFFER_BYTES)
  var eof = false
  while not eof {
    buf.clear()
    val n: Int = channel.read(buf)
    if n < 0 {
      eof = true
    } else if n == 0 {
      awaitReady(selector, key, OP_READ, deadlineNanos)
    } else {
      // The buffer's backing array goes straight to the sink: the next
      // `channel.read` writes it in place, so no `slice[Byte]` binding may
      // hold it (#8730).
      sink.write(buf.array(), 0, n)
    }
  }
  sink.toByteArray()
}

/// Write `requestBytes` to the Unix socket at `path` and return everything
/// the peer sends before closing.  Both the channel and the selector are
/// closed on every path.
func unixRoundTrip(path: in String, requestBytes: in slice[Byte], deadlineNanos: in Long): slice[Byte] {
  val address: JUnixSocketAddress = JUnixSocketAddress.of(path)
  val channel: JSocketChannel = JSocketChannel.open(address)
  val selector: JSelector = JSelector.open()
  try {
    channel.configureBlocking(false)
    val key: JSelectionKey = channel.register(selector, OP_WRITE)
    writeFully(channel, selector, key, requestBytes, deadlineNanos)
    val response = readToEnd(channel, selector, key, deadlineNanos)
    selector.close()
    channel.close()
    response
  } catch Bug as b {
    selector.close()
    channel.close()
    panic(b.message)
  }
}

/// `host`/`target` of an absolute `http://` URL.  `https://` is refused: the
/// socket is plaintext.  A fragment is dropped (never sent on the wire).
record UnixTarget {
  host: String
  target: String
}

func splitUnixUrl(url: in String): UnixTarget {
  if url.startsWith("https://") {
    panic("Std.Http: https:// is not supported over a Unix domain socket: " + url)
  }
  if not url.startsWith("http://") {
    panic("Std.Http: a Unix domain socket request needs an absolute http:// URL: " + url)
  }
  val rest = url.substring(7)
  val noFragment = match indexOf(rest, "#") { case Some(i) -> rest.substring(0, i); case None -> rest }
  var hostEnd = noFragment.length
  var i = 0
  while i < noFragment.length and hostEnd == noFragment.length {
    val c = noFragment.substring(i, 1)
    if c == "/" or c == "?" {
      hostEnd = i
    }
    i = i + 1
  }
  val host = noFragment.substring(0, hostEnd)
  val tail = noFragment.substring(hostEnd)
  val target = if tail.length == 0 { "/" } else if tail.startsWith("?") { "/" + tail } else { tail }
  UnixTarget(host = host, target = target)
}

func wireRequestHeaders(request: in HttpRequestMessage): List[HeaderField] {
  val headers: List[HeaderField] = newList()
  var i = 0
  while i < request.headerNames.count {
    headers.add(HeaderField(name = request.headerNames[i], value = request.headerValues[i]))
    i = i + 1
  }
  headers
}

func isRedirectStatus(status: in Int): Bool {
  status == 301 or status == 302 or status == 303 or status == 307 or status == 308
}

/// Resolve a `Location` value against the URL it answered. Every host maps
/// onto the one socket, so only the path matters; the scheme must stay `http`.
func resolveRedirect(current: in String, location: in String): String {
  if location.startsWith("http://") {
    location
  } else if location.startsWith("https://") {
    panic("Std.Http: redirect to https:// is not supported over a Unix domain socket: " + location)
  } else {
    val base = splitUnixUrl(current)
    if location.startsWith("/") {
      "http://" + base.host + location
    } else {
      val path = match indexOf(base.target, "?") { case Some(q) -> base.target.substring(0, q); case None -> base.target }
      val dir = match lastIndexOf(path, "/") { case Some(slash) -> path.substring(0, slash + 1); case None -> "/" }
      "http://" + base.host + dir + location
    }
  }
}

func unixHop(client: in HttpClientHandle, request: in HttpRequestMessage, deadlineNanos: in Long): ClientResponse {
  val parts = splitUnixUrl(request.url)
  val body: Option[slice[Byte]] = if request.hasBody { Some(value = request.body) } else { None }
  val requestBytes = match serializeClientRequest(request.method, parts.target, parts.host, wireRequestHeaders(request), request.contentType, body) {
    case Ok(bytes) -> bytes
    case Err(message) -> panic("Std.Http: " + message)
  }
  val raw = unixRoundTrip(client.unixPath, requestBytes, deadlineNanos)
  match parseClientResponse(raw, request.method.toUpper() == "HEAD", true) {
    case Complete(response) -> response
    case Malformed(message) -> panic("Std.Http: malformed HTTP response from " + client.unixPath + ": " + message)
    case Incomplete -> panic("Std.Http: incomplete HTTP response from " + client.unixPath)
  }
}

func doSendUnix(client: in HttpClientHandle, request: in HttpRequestMessage): HttpResponseMessage {
  val deadlineNanos = if request.timeoutNanos > 0i64 { JSystem.nanoTime() + request.timeoutNanos } else { 0i64 }
  var current = request
  var hops = 0
  var result = unixHop(client, current, deadlineNanos)
  while client.maxRedirects > 0 and isRedirectStatus(result.status) and hasLocation(result) {
    if hops >= client.maxRedirects {
      panic("Std.Http: too many redirects (limit " + client.maxRedirects.toString() + ")")
    }
    val next = resolveRedirect(current.url, locationOf(result))
    val method = current.method.toUpper()
    val noBody: slice[Byte] = []
    val keepsMethod = result.status == 307 or result.status == 308
    val becomesGet = not keepsMethod and method != "GET" and method != "HEAD"
    current = HttpRequestMessage(
      method = if becomesGet { "GET" } else { current.method },
      url = next,
      headerNames = current.headerNames,
      headerValues = current.headerValues,
      contentType = if becomesGet { "" } else { current.contentType },
      body = if becomesGet { noBody } else { current.body },
      hasBody = if becomesGet { false } else { current.hasBody },
      timeoutNanos = current.timeoutNanos
    )
    result = unixHop(client, current, deadlineNanos)
    hops = hops + 1
  }
  HttpResponseMessage(
    status = result.status,
    jheaders = None,
    wireHeaders = result.headers,
    bodyBytes = result.body,
    version = JHttpVersion.HTTP_1_1
  )
}

func hasLocation(response: in ClientResponse): Bool {
  locationOf(response).length > 0
}

func locationOf(response: in ClientResponse): String {
  match headerValue(response.headers, "Location") {
    case Some(value) -> value
    case None -> ""
  }
}

// =====================================================================
// Response accessors.
// =====================================================================
pub func hostStatusCode(response: in HttpResponseMessage): Int {
  response.status
}

/// `negotiatedVersion` (docs/61 §5.1; #5879): maps the JDK's
/// `HttpClient.Version` enum to the major-version int `Std.Http` matches
/// against `HttpVersion` (mirrors `_kernel/http_host.l`'s
/// `hostResponseVersionMajor`). JDK 21's enum has exactly two cases
/// (`HTTP_1_1`/`HTTP_2` — no `HTTP_3`), so anything that isn't `HTTP_2`
/// is `HTTP_1_1`.
pub func hostResponseVersionMajor(response: in HttpResponseMessage): Int {
  if response.version.equals(JHttpVersion.HTTP_2) {
    2
  } else {
    1
  }
}

/// First value of the named response header, or `""` if absent.
/// `java.net.http.HttpHeaders` is case-insensitive and carries content
/// headers in the same map, matching the .NET twin's two-collection
/// fallthrough.
pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  match response.jheaders {
    case Some(headers) -> {
      val opt: JOptional = headers.firstValue(name)
      val value: String = opt.orElse("")
      value
    }
    case None -> match headerValue(response.wireHeaders, name) { case Some(value) -> value; case None -> "" }
  }
}

/// The name of every header on the response, as the JDK reports them
/// (lowercase over HTTP/2, as sent over HTTP/1.1).
pub func hostResponseHeaderNames(response: in HttpResponseMessage): List[String] {
  val names: List[String] = newList()
  match response.jheaders {
    case Some(headers) -> {
      val byName: JMap = headers.map()
      val keys: JSet = byName.keySet()
      val it: JIterator = keys.iterator()
      while it.hasNext() {
        val name: String = it.next()
        names.add(name)
      }
    }
    case None -> {
      var i = 0
      while i < response.wireHeaders.count {
        names.add(response.wireHeaders[i].name)
        i = i + 1
      }
    }
  }
  names
}

func readBodyTextOf(response: in HttpResponseMessage): String {
  JString.new(response.bodyBytes, "UTF-8")
}

// ---------------------------------------------------------------------------
// Deadline classification (#9067).  A send under a `makeCancelSourceTimeout`
// token ends one of three ways when the deadline passes: the JDK's own
// request timeout fires (`HttpTimeoutException` / `HttpConnectTimeoutException`,
// "request timed out" / "HTTP connect timed out"), the body watchdog fires
// (`timedOutText`), or the deadline had already passed before the send began
// (the `OperationCanceledException` panic of `throwIfCancelled`).  All three
// are reported as `timedOutText`.  The JDK timer is armed from the time
// remaining at send, while the token compares `System.nanoTime()` to its
// deadline lazily, so the JDK can report a timeout a few microseconds before
// `isCancelled(token)` turns true; the failure is held back until it has, so
// a caller that checks the token after a timeout always sees it cancelled.
// An explicit `cancelSource` keeps the cancellation wording, and every other
// failure keeps its own text.
// ---------------------------------------------------------------------------
val maxDeadlineSlackNanos: Long = 1000000000i64

func deadlinePassed(token: in CancellationToken): Bool {
  JSystem.nanoTime() - token.deadlineMs >= 0i64
}

func awaitDeadline(token: in CancellationToken): Unit {
  var left = token.deadlineMs - JSystem.nanoTime()
  while left > 0i64 {
    sleepNanos(if left > 1000000i64 { 1000000i64 } else { left })
    left = token.deadlineMs - JSystem.nanoTime()
  }
}

func looksLikeDeadline(typeName: in String, message: in String): Bool {
  typeName.contains("TimeoutException") or message == timedOutText or message.contains("timed out") or
    message.contains("cancellation was requested") or
    typeName.contains("CancellationException")
}

func sendFailureText(typeName: in String, message: in String, token: in CancellationToken): String {
  if token.deadlineMs > 0i64 and not token.flag.get() and looksLikeDeadline(typeName, message) {
    if deadlinePassed(token) or token.deadlineMs - JSystem.nanoTime() <= maxDeadlineSlackNanos {
      awaitDeadline(token)
      timedOutText
    } else {
      message
    }
  } else {
    message
  }
}

// ---------------------------------------------------------------------------
// V0012-safe wrappers — the public send/read surface, mirroring
// _kernel/http_host.l.  On JVM there is no CLR protected-region
// restriction; the try/catch here is the kernel's exception -> Result
// boundary, same division of labour as the .NET twin.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doSend(client, request))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doGet(client, url))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doPostString(client, url, body, contentType))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  return try {
    Ok(value = readBodyTextOf(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  return try {
    Ok(value = response.bodyBytes)
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostSendWithCancelSafe(
  client: in HttpClientHandle,
  request: in HttpRequestMessage,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = doSend(client, withCancelDeadline(request, token)))
  } catch Bug as b {
    Err(error = sendFailureText(b.typeName, b.message, token))
  }
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = doSend(client, withCancelDeadline(hostMakeRequest("GET", url), token)))
  } catch Bug as b {
    Err(error = sendFailureText(b.typeName, b.message, token))
  }
}

pub async func hostPostStringWithCancelSafe(
  client: in HttpClientHandle,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  return try {
    throwIfCancelled(token)
    val request = hostWithStringBody(hostMakeRequest("POST", url), contentType, body)
    Ok(value = doSend(client, withCancelDeadline(request, token)))
  } catch Bug as b {
    Err(error = sendFailureText(b.typeName, b.message, token))
  }
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = readBodyTextOf(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}
