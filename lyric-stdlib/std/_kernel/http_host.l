//! std/_kernel/http_host.l - host boundary for HTTP.
//!
//! This file is the audited extern boundary for `Std.Http`.  Every
//! host-facing function below is either:
//!
//!   * a direct `@externTarget` to a single BCL method / property /
//!     constructor (the trivial pass-through case), or
//!   * a native Lyric helper that composes a sequence of those
//!     primitives (the multi-step orchestration case — `hostMakeRequest`,
//!     `hostWithStringBody`, etc.).
//!
//! G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
//! the F# `Lyric.Stdlib.HttpClientHost` shim retires entirely.
//!
//! TLS client configuration (docs/61-https-tls-http-versions.md §3.2,
//! D128; phase 1.2, #5877) widens the extern boundary this file audits to
//! `System.Net.Security` (`SslClientAuthenticationOptions`) and the
//! `System.Security.Cryptography.X509Certificates` chain-validation
//! surface (`X509Chain`/`X509ChainPolicy`) — see the "TLS client
//! configuration" section below for the design rationale.
@axiom("System.Net.Http and System.Net.Security TLS configuration operations conform to their documented .NET contracts")
package Std.HttpHost

import Std.Core
import Std.Task
import Std.Tls as Tls
import Std.TlsHost as TlsHost

// =====================================================================
// Extern types — BCL classes the helpers below reference.  Each one
// is the host-side type for a value that flows through Std.Http but
// stays opaque from the user's perspective.
// =====================================================================
extern type HttpClientHandle = "System.Net.Http.HttpClient"

extern type HttpClientHandler = "System.Net.Http.HttpClientHandler"

extern type HttpRequestMessage = "System.Net.Http.HttpRequestMessage"

extern type HttpResponseMessage = "System.Net.Http.HttpResponseMessage"

extern type HttpContent = "System.Net.Http.HttpContent"

extern type StringContent = "System.Net.Http.StringContent"

// `BclHttpMethod` rather than `HttpMethod` because `Std.Http`
// declares its own user-facing `pub enum HttpMethod { Get, Post, … }`
// and would shadow this extern.
extern type BclHttpMethod = "System.Net.Http.HttpMethod"

extern type HttpHeaders = "System.Net.Http.Headers.HttpHeaders"

extern type Encoding = "System.Text.Encoding"

extern type SocketsHttpHandler = "System.Net.Http.SocketsHttpHandler"

extern type UnixDomainSocketEndPoint = "System.Net.Sockets.UnixDomainSocketEndPoint"

extern type Socket = "System.Net.Sockets.Socket"

extern type SocketAddressFamily = "System.Net.Sockets.AddressFamily"

extern type SocketKind = "System.Net.Sockets.SocketType"

extern type SocketProtocolType = "System.Net.Sockets.ProtocolType"

extern type NetworkStream = "System.Net.Sockets.NetworkStream"

extern type SocketsHttpConnectionContext = "System.Net.Http.SocketsHttpConnectionContext"

extern type ValueTaskOfStream = "System.Threading.Tasks.ValueTask`1[System.IO.Stream]"

// HTTP-version knob (docs/61 §5.1, D128 decision 4; #5879).
extern type Version = "System.Version"

extern type HttpVersionPolicy = "System.Net.Http.HttpVersionPolicy"

// =====================================================================
// Primitive externs (private to this kernel file).  These bind the
// individual BCL members; the public `host*` helpers compose them.
// =====================================================================
@externTarget("System.Text.Encoding.UTF8")
func utf8(): Encoding = ()

@externTarget("System.Net.Http.HttpMethod..ctor")
func newHttpMethod(name: in String): BclHttpMethod = ()

@externTarget("System.Net.Http.HttpRequestMessage..ctor")
func newRequest(method: in BclHttpMethod, url: in String): HttpRequestMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpRequestMessage.Headers")
func requestHeaders(req: in HttpRequestMessage): HttpHeaders = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.TryAddWithoutValidation")
func headersTryAdd(h: in HttpHeaders, name: in String, value: in String): Bool = ()

@externTarget("System.Net.Http.StringContent..ctor")
func newStringContent(body: in String, encoding: in Encoding, mediaType: in String): StringContent = ()

@externInstance
@externTarget("System.Net.Http.HttpRequestMessage.set_Content")
func setRequestContent(req: in HttpRequestMessage, content: in StringContent): Unit = ()

// Raw ctors (private, no version applied): every public `hostClient*`
// function below builds through exactly one of these, then applies exactly
// one of `applyHttp2OrLower`/`applyHttp11Exact` (below) before handing the
// client back — never both, so no constructed client is ever version-
// stamped twice. D128 decision 4's "every constructed client, including the
// singleton" default is impossible to bypass at a call site: every path to
// a raw ctor is followed by exactly one `apply*` call.
@externTarget("System.Net.Http.HttpClient..ctor")
func rawNewClient(): HttpClientHandle = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func rawNewClientFromHandler(handler: in HttpClientHandler): HttpClientHandle = ()

@externTarget("System.Net.Http.HttpClientHandler..ctor")
func newHandler(): HttpClientHandler = ()

@externInstance
@externTarget("System.Net.Http.HttpClientHandler.set_AllowAutoRedirect")
func setAllowAutoRedirect(h: in HttpClientHandler, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Net.Http.HttpClientHandler.set_MaxAutomaticRedirections")
func setMaxAutomaticRedirections(h: in HttpClientHandler, n: in Int): Unit = ()

@externTarget("System.Net.Sockets.UnixDomainSocketEndPoint..ctor")
func newUnixDomainSocketEndPoint(path: in String): UnixDomainSocketEndPoint = ()

@externTarget("System.Net.Http.SocketsHttpHandler..ctor")
func newSocketsHandler(): SocketsHttpHandler = ()

@externInstance
@externTarget("System.Net.Http.SocketsHttpHandler.set_AllowAutoRedirect")
func socketsSetAllowAutoRedirect(h: in SocketsHttpHandler, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Net.Http.SocketsHttpHandler.set_MaxAutomaticRedirections")
func socketsSetMaxAutomaticRedirections(h: in SocketsHttpHandler, n: in Int): Unit = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func rawNewClientFromSocketsHandler(handler: in SocketsHttpHandler): HttpClientHandle = ()

// ---------------------------------------------------------------------------
// HTTP-version knob (docs/61 §5.1, D128 decision 4; #5879).
//
// `HttpClient.DefaultRequestVersion`/`DefaultVersionPolicy` are plain
// mutable instance properties (unlike the JVM twin's immutable-at-build
// `HttpClient`, see `_kernel_jvm/http_host.l`), so every construction path
// converges on the two `apply*` helpers below applied once, right after
// construction, before the client is ever used.
// ---------------------------------------------------------------------------
@externInstance
@externTarget("System.Net.Http.HttpClient.set_DefaultRequestVersion")
func setDefaultRequestVersion(c: in HttpClientHandle, v: in Version): Unit = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.set_DefaultVersionPolicy")
func setDefaultVersionPolicy(c: in HttpClientHandle, p: in HttpVersionPolicy): Unit = ()

@externTarget("System.Version..ctor")
func newVersion(major: in Int, minor: in Int): Version = ()

@externTarget("System.Net.Http.HttpVersionPolicy.RequestVersionOrLower")
func versionPolicyOrLower(): HttpVersionPolicy = ()

@externTarget("System.Net.Http.HttpVersionPolicy.RequestVersionExact")
func versionPolicyExact(): HttpVersionPolicy = ()

// h2-or-lower (docs/61 default): request HTTP/2, but negotiate down to
// HTTP/1.1 rather than fail if the peer doesn't support h2.  This only
// takes effect when ALPN is available (TLS) — a plaintext peer has no
// ALPN to negotiate with, so the connection stays HTTP/1.1 regardless.
func applyHttp2OrLower(c: in HttpClientHandle): HttpClientHandle {
  setDefaultRequestVersion(c, newVersion(2, 0))
  setDefaultVersionPolicy(c, versionPolicyOrLower())
  c
}

// Exact HTTP/1.1 pin: never attempt an h2 upgrade.
func applyHttp11Exact(c: in HttpClientHandle): HttpClientHandle {
  setDefaultRequestVersion(c, newVersion(1, 1))
  setDefaultVersionPolicy(c, versionPolicyExact())
  c
}

@externTarget("System.Net.Sockets.AddressFamily.Unix")
func addressFamilyUnix(): SocketAddressFamily = ()

@externTarget("System.Net.Sockets.SocketType.Stream")
func socketKindStream(): SocketKind = ()

@externTarget("System.Net.Sockets.ProtocolType.Unspecified")
func protocolTypeUnspecified(): SocketProtocolType = ()

@externTarget("System.Net.Sockets.Socket..ctor")
func newSocket(family: in SocketAddressFamily, kind: in SocketKind, protocolType: in SocketProtocolType): Socket = ()

@externInstance
@externTarget("System.Net.Sockets.Socket.Connect")
func socketConnect(s: in Socket, endpoint: in UnixDomainSocketEndPoint): Unit = ()

@externInstance
@externTarget("System.Net.Sockets.Socket.Dispose")
func socketDispose(s: in Socket): Unit = ()

@externTarget("System.Net.Sockets.NetworkStream..ctor")
func newNetworkStream(s: in Socket, ownsSocket: in Bool): NetworkStream = ()

// `ValueTask`1` has no implicit-conversion operator — the C# compiler's
// `return value;` sugar inside an `async ValueTask<T>` method lowers directly
// to `newobj ValueTask`1::.ctor(!0)`, not an `op_Implicit` call (there isn't
// one on this type; only `ValueTask`, the non-generic sibling, defines
// `FromResult`/no implicit operators either). `ValueTask`1` has THREE
// constructors — `(TResult result)`, `(Task<TResult> task)`, and
// `(IValueTaskSource<TResult>, short)` — so arity-only `@externTarget`
// resolution alone cannot tell the first two apart (compiler W0008). The
// metadata-direct resolver now scores candidates against the declared Lyric
// argument type, and a `!0`-typed parameter position scores as a match for
// any concrete argument (`scoreSigType`'s `STVar` arm, metadata_reader.l),
// which correctly picks `.ctor(TResult)` over `.ctor(Task<TResult>)` for a
// `NetworkStream` argument (D-progress-686).
@externTarget("System.Threading.Tasks.ValueTask`1..ctor")
func newValueTaskOfStream(stream: in NetworkStream): ValueTaskOfStream = ()

@externInstance
@externTarget("System.Net.Http.SocketsHttpHandler.set_ConnectCallback")
func socketsSetConnectCallback(
  h: in SocketsHttpHandler,
  cb: in (SocketsHttpConnectionContext, CancellationToken) -> ValueTaskOfStream,
): Unit = ()

// Opens a raw Unix domain socket connected to `socketPath` and wraps it in a
// `NetworkStream`, disposing the socket (not just leaking the handle) if the
// connect itself fails.  Local Unix-socket connects (Docker, systemd, …) are
// effectively instantaneous, so this dials synchronously rather than binding
// `Socket.ConnectAsync`/honouring the delegate's `CancellationToken` — unlike
// the network-facing async connect the retired `UnixSocketHttpClient.cs` used,
// there is no meaningful wait to cancel here.  A caller that cancels the
// surrounding HTTP request cannot abort an in-flight connect call; see
// `docs/01-language-reference.md` §11.3's D122 paragraph for the documented
// contract (#5804).
func connectUnixSocket(socketPath: in String): NetworkStream {
  val socket = newSocket(addressFamilyUnix(), socketKindStream(), protocolTypeUnspecified())
  try {
    socketConnect(socket, newUnixDomainSocketEndPoint(socketPath))
    newNetworkStream(socket, true)
  } catch Bug as b {
    socketDispose(socket)
    panic(b.message)
  }
}

@externInstance
@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsync(client: in HttpClientHandle, request: in HttpRequestMessage): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsyncCancel(
  client: in HttpClientHandle,
  request: in HttpRequestMessage,
  token: in CancellationToken,
): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsync(client: in HttpClientHandle, url: in String): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsyncCancel(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsync(client: in HttpClientHandle, url: in String, content: in StringContent): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsyncCancel(
  client: in HttpClientHandle,
  url: in String,
  content: in StringContent,
  token: in CancellationToken,
): HttpResponseMessage = ()

@externInstance
@externTarget("System.Net.Http.HttpResponseMessage.StatusCode")
func responseStatusInt(response: in HttpResponseMessage): Int = ()

@externInstance
@externTarget("System.Net.Http.HttpResponseMessage.Content")
func responseContent(response: in HttpResponseMessage): HttpContent = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsString(c: in HttpContent): String = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsStringCancel(c: in HttpContent, token: in CancellationToken): String = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytes(c: in HttpContent): slice[Byte] = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytesCancel(c: in HttpContent, token: in CancellationToken): slice[Byte] = ()

// =====================================================================
// Public host helpers — the names `Std.Http` resolves through
// `import Std.HttpHost as HostHttp`.  Each is either a thin alias or
// a multi-step composition that wraps the primitives above.
// =====================================================================
// #333: process-wide HttpClientHandle singleton — initialised once in the package `.cctor`,
// reused on every request.  Per-call construction exhausts the TCP socket pool
// (sockets stay in TIME_WAIT for two MSL after GC).
// Named `processClient` (not `defaultClient`) to avoid a name-resolution clash with
// the `Std.Http.defaultClient()` factory function when both packages are compiled together.
val processClient: HttpClientHandle = applyHttp2OrLower(rawNewClient())

pub func hostDefaultClient(): HttpClientHandle {
  processClient
}

pub func hostMakeRequest(httpMethod: in String, url: in String): HttpRequestMessage {
  newRequest(newHttpMethod(httpMethod), url)
}

pub func hostWithHeader(request: in HttpRequestMessage, key: in String, value: in String): HttpRequestMessage {
  val _ = headersTryAdd(requestHeaders(request), key, value)
  request
}

pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage {
  setRequestContent(request, newStringContent(body, utf8(), contentType))
  request
}

pub func hostStatusCode(response: in HttpResponseMessage): Int {
  responseStatusInt(response)
}

// Raw (unversioned) redirect-configured client builders — shared by the
// default-version and `*Http11` public functions below, each of which
// applies exactly one `apply*` call to the result (docs/61 §5.1; #5879:
// building through `hostClientWithRedirects` and re-applying a second
// version would stamp the handle twice).
func buildRedirectingClient(maxRedirects: in Int): HttpClientHandle {
  val handler = newHandler()
  setAllowAutoRedirect(handler, true)
  setMaxAutomaticRedirections(handler, maxRedirects)
  rawNewClientFromHandler(handler)
}

func buildNonRedirectingClient(): HttpClientHandle {
  val handler = newHandler()
  setAllowAutoRedirect(handler, false)
  rawNewClientFromHandler(handler)
}

pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle {
  applyHttp2OrLower(buildRedirectingClient(maxRedirects))
}

pub func hostClientNoRedirects(): HttpClientHandle {
  applyHttp2OrLower(buildNonRedirectingClient())
}

// ---------------------------------------------------------------------------
// Unix domain socket support for local protocol access (Docker, systemd, etc).
// Native Lyric via a `SocketsHttpHandler.ConnectCallback` typed-delegate
// binding (D122/docs/50-ffi-delegates-proposal.md) — no host-assembly
// dependency, unlike the retired `Lyric.Cli.Aot.UnixSocketHttpClient` this
// replaced (D-progress-686; docs/59-compiler-stdlib-deep-review.md §7.3).
// ---------------------------------------------------------------------------
// Shared construction for every `hostClientWithUnixSocket*` variant below —
// a `SocketsHttpHandler` whose `ConnectCallback` dials `socketPath` on every
// connection.
func newUnixSocketHandler(socketPath: in String): SocketsHttpHandler {
  val handler = newSocketsHandler()
  socketsSetConnectCallback(
    handler,
    { context: SocketsHttpConnectionContext, ct: CancellationToken ->
      newValueTaskOfStream(connectUnixSocket(socketPath))
    }
  )
  handler
}

// Raw (unversioned) Unix-socket client builders — same one-`apply*`-call
// discipline as `buildRedirectingClient`/`buildNonRedirectingClient` above.
func buildUnixSocketClient(socketPath: in String): HttpClientHandle {
  rawNewClientFromSocketsHandler(newUnixSocketHandler(socketPath))
}

func buildUnixSocketRedirectingClient(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  val handler = newUnixSocketHandler(socketPath)
  socketsSetAllowAutoRedirect(handler, true)
  socketsSetMaxAutomaticRedirections(handler, maxRedirects)
  rawNewClientFromSocketsHandler(handler)
}

func buildUnixSocketNonRedirectingClient(socketPath: in String): HttpClientHandle {
  val handler = newUnixSocketHandler(socketPath)
  socketsSetAllowAutoRedirect(handler, false)
  rawNewClientFromSocketsHandler(handler)
}

pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle {
  applyHttp2OrLower(buildUnixSocketClient(socketPath))
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  applyHttp2OrLower(buildUnixSocketRedirectingClient(socketPath, maxRedirects))
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle {
  applyHttp2OrLower(buildUnixSocketNonRedirectingClient(socketPath))
}

// ---------------------------------------------------------------------------
// HTTP/1.1 exact-pin variants (docs/61 §5.1, D128 decision 4; #5879).
//
// Each mirrors its default-version counterpart above but applies
// `applyHttp11Exact` instead of `applyHttp2OrLower` — to the SAME raw,
// not-yet-versioned handle a fresh `buildXxx`/`rawNewClient*` call
// produces, never to an already-versioned handle (that would stamp the
// version twice). `hostClientHttp11` builds a FRESH client via
// `rawNewClient()` directly (never `processClient`, the shared singleton
// `hostDefaultClient` returns) — the singleton's version must stay at the
// process-wide h2-or-lower default for every other caller.
// ---------------------------------------------------------------------------
pub func hostClientHttp11(): HttpClientHandle {
  applyHttp11Exact(rawNewClient())
}

pub func hostClientWithRedirectsHttp11(maxRedirects: in Int): HttpClientHandle {
  applyHttp11Exact(buildRedirectingClient(maxRedirects))
}

pub func hostClientNoRedirectsHttp11(): HttpClientHandle {
  applyHttp11Exact(buildNonRedirectingClient())
}

pub func hostClientWithUnixSocketHttp11(socketPath: in String): HttpClientHandle {
  applyHttp11Exact(buildUnixSocketClient(socketPath))
}

pub func hostClientWithUnixSocketAndRedirectsHttp11(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  applyHttp11Exact(buildUnixSocketRedirectingClient(socketPath, maxRedirects))
}

pub func hostClientWithUnixSocketNoRedirectsHttp11(socketPath: in String): HttpClientHandle {
  applyHttp11Exact(buildUnixSocketNonRedirectingClient(socketPath))
}

// ---------------------------------------------------------------------------
// TLS client configuration (docs/61 §3.2, D128; phase 1.2, #5877).
//
// Real BCL constraint that shaped this section: the natural-looking design
// — assembling one `SocketsHttpHandler.SslOptions` (`SslClientAuthentication
// Options`), same as the Unix-socket path above uses `SocketsHttpHandler`
// for its `ConnectCallback` — does NOT work for certificate validation.
// `SslClientAuthenticationOptions.RemoteCertificateValidationCallback` is
// typed as the CUSTOM delegate `System.Net.Security.
// RemoteCertificateValidationCallback`, not a `Func<...>`. The delegate-
// bridge FFI (Epic #1877/#3923, D122/docs/50) only constructs `System.Func`/
// `System.Action` instances at a bridged call site — verified empirically
// here: binding a Lyric lambda to that property compiles, but throws
// `MissingMethodException` at run time because the constructed `Func`5`
// does not match the real (non-`Func`) delegate parameter type. There is no
// bitwise-OR workaround either (see `sslProtocolsTls13`'s comment on the
// same class of gap for `SslProtocols`).
//
// The fix: `System.Net.Http.HttpClientHandler` (the plain handler this
// file already uses for the ordinary redirect-only path above) exposes the
// SAME capabilities as direct, non-nested members whose delegate-typed one
// genuinely IS `Func<HttpRequestMessage, X509Certificate2, X509Chain,
// SslPolicyErrors, bool>` — `ServerCertificateCustomValidationCallback` —
// alongside plain `SslProtocols`/`ClientCertificates` properties with no
// delegate involved at all. Every TLS option this file can honor routes
// through `HttpClientHandler`, reusing the SAME `newHandler`/
// `setAllowAutoRedirect`/`setMaxAutomaticRedirections`/`rawNewClientFromHandler`
// primitives the plain path already declares above.
//
// The one combination this leaves unsupported: Unix domain sockets require
// `SocketsHttpHandler` (the only handler exposing `ConnectCallback`), whose
// only certificate-validation hook IS the blocked custom-delegate property.
// `Std.Http.HttpClientBuilder.build()` treats "Unix socket + any TLS
// option" as an unsupported combination for exactly this reason (a real
// BCL/FFI limitation, not a design choice) — tracked in issue #5947 (custom-
// delegate FFI bridging, an Epic #1877/#3923 follow-up); `minTlsVersion`/
// `clientIdentity` are needlessly given up too in that combination (they
// don't actually need the blocked callback) in exchange for a single,
// simple, honest gate rather than a partially-applied TLS config silently
// dropping just the CA/insecure-verify pieces.
//
// `Certificate`/`Identity` are opaque `Std.Tls` types; this file reaches
// their underlying `Std.TlsHost.CertHandle` (= `X509Certificate2` on this
// target) only through the `internal` `rawHandle()` accessors `Std.Tls`
// itself provides (docs/01-language-reference.md §3.1) — the opaque
// representation is never cracked from outside its own package.
//
// `hostSupportsTlsConfig()` is the capability probe `Std.Http` checks
// before ever calling `hostClientWithTls`: on this target it is `true`
// (this section is the real wiring); the JVM twin
// (`_kernel_jvm/http_host.l`) returns `false` until #5878 ships JVM TLS
// support, so a TLS-configured client on that target still builds (`build()`
// stays infallible) but fails every request with a typed error naming
// #5878 instead of silently connecting without the configured options.
// ---------------------------------------------------------------------------
pub func hostSupportsTlsConfig(): Bool {
  true
}

extern type SslProtocols = "System.Security.Authentication.SslProtocols"

extern type X509CertificateCollection = "System.Security.Cryptography.X509Certificates.X509CertificateCollection"

extern type X509Certificate2Collection = "System.Security.Cryptography.X509Certificates.X509Certificate2Collection"

extern type X509Chain = "System.Security.Cryptography.X509Certificates.X509Chain"

extern type X509ChainPolicy = "System.Security.Cryptography.X509Certificates.X509ChainPolicy"

extern type X509ChainTrustMode = "System.Security.Cryptography.X509Certificates.X509ChainTrustMode"

extern type SslPolicyErrors = "System.Net.Security.SslPolicyErrors"

extern type X509RevocationMode = "System.Security.Cryptography.X509Certificates.X509RevocationMode"

@externInstance
@externTarget("System.Net.Http.HttpClientHandler.set_SslProtocols")
func handlerSetSslProtocols(h: in HttpClientHandler, p: in SslProtocols): Unit = ()

// Only the `Tls13`-exact pin ever sets `SslProtocols` explicitly.
// `SslProtocols` is a `[Flags]` enum with no bitwise-OR method in its
// metadata (C#'s `|` on enums lowers straight to an IL `or` over the
// underlying int with no callable member; there is no `Tls12AndTls13`
// named constant to bind to instead), so combining `Tls12 | Tls13` via
// this file's `@externTarget("Type.STATIC_FIELD")` idiom is not available
// without a second, riskier FFI capability this change does not need:
// leaving `SslProtocols` at its default (`SslProtocols.None`, "let the
// platform decide") already means "TLS 1.2 or newer" on every current
// .NET 10 target platform — there is no TLS version between 1.2 and 1.3
// for the default to wrongly admit, and .NET has not negotiated below
// TLS 1.2 by default since long before this module shipped. Explicitly
// pinning `Tls12` alone would be WRONG (it would exclude 1.3), so the
// floor case and the unset case both take the "leave it alone" branch.
@externTarget("System.Security.Authentication.SslProtocols.Tls13")
func sslProtocolsTls13(): SslProtocols = ()

@externInstance
@externTarget("System.Net.Http.HttpClientHandler.get_ClientCertificates")
func handlerClientCertificates(h: in HttpClientHandler): X509CertificateCollection = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509CertificateCollection.Add")
func certCollectionAdd(c: in X509CertificateCollection, cert: in TlsHost.CertHandle): Int = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Certificate2Collection.Add")
func x2CollectionAdd(c: in X509Certificate2Collection, cert: in TlsHost.CertHandle): Int = ()

@externTarget("System.Security.Cryptography.X509Certificates.X509Chain..ctor")
func newX509Chain(): X509Chain = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Chain.get_ChainPolicy")
func chainPolicyOf(c: in X509Chain): X509ChainPolicy = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy.set_TrustMode")
func chainPolicySetTrustMode(p: in X509ChainPolicy, m: in X509ChainTrustMode): Unit = ()

@externTarget("System.Security.Cryptography.X509Certificates.X509ChainTrustMode.CustomRootTrust")
func chainTrustModeCustomRoot(): X509ChainTrustMode = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy.get_CustomTrustStore")
func chainPolicyCustomTrustStoreOf(p: in X509ChainPolicy): X509Certificate2Collection = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy.set_RevocationMode")
func chainPolicySetRevocationMode(p: in X509ChainPolicy, m: in X509RevocationMode): Unit = ()

// Matches `HttpClientHandler`'s own default (`CheckCertificateRevocationList
// = false`, i.e. no revocation check) so configuring a TLS option does not
// silently start an online OCSP/CRL check as a side effect (#5952) — that
// would add unexpected latency, or hang outright, against a peer whose
// revocation endpoint is unreachable (notably the air-gapped/restricted-
// egress service-mesh case `withExclusiveCaCertificate` targets).
@externTarget("System.Security.Cryptography.X509Certificates.X509RevocationMode.NoCheck")
func revocationModeNoCheck(): X509RevocationMode = ()

// The two `SslPolicyErrors` values `applyTlsOptions`'s validation callback
// checks against via plain `==` (a `ceq` over the enum's underlying int
// representation — no FFI method call, so the no-bitwise-op-in-FFI gap
// `sslProtocolsTls13`'s comment documents does not apply to equality
// checks against a SPECIFIC known value, only to combining/decomposing
// flags generically).
@externTarget("System.Net.Security.SslPolicyErrors.None")
func sslPolicyErrorsNone(): SslPolicyErrors = ()

@externTarget("System.Net.Security.SslPolicyErrors.RemoteCertificateChainErrors")
func sslPolicyErrorsChainErrorsOnly(): SslPolicyErrors = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Chain.Build")
func chainBuild(c: in X509Chain, cert: in TlsHost.CertHandle): Bool = ()

@externInstance
@externTarget("System.Net.Http.HttpClientHandler.set_ServerCertificateCustomValidationCallback")
func handlerSetValidationCallback(
  h: in HttpClientHandler,
  cb: in (HttpRequestMessage, TlsHost.CertHandle, X509Chain, SslPolicyErrors) -> Bool,
): Unit = ()

// Builds a FRESH chain with `TrustMode = CustomRootTrust` (ONLY `ca` is a
// trusted root — the platform trust store is not consulted),
// `RevocationMode = NoCheck` (#5952), and validates `cert` against it.
// Used directly for `withExclusiveCaCertificate` (replaces platform trust
// unconditionally) and as the fallback for `withCaCertificate` (additive:
// only reached once the platform's own chain validation, reported via
// `sslPolicyErrors`, has already failed).
func buildCustomChain(cert: in TlsHost.CertHandle, ca: in Tls.Certificate): Bool {
  val chain = newX509Chain()
  val policy = chainPolicyOf(chain)
  chainPolicySetTrustMode(policy, chainTrustModeCustomRoot())
  chainPolicySetRevocationMode(policy, revocationModeNoCheck())
  val _ = x2CollectionAdd(chainPolicyCustomTrustStoreOf(policy), ca.rawHandle())
  chainBuild(chain, cert)
}

// Which CA-trust option (if any) is configured — the third input to
// `resolveTlsValidationDecision` below. Kept as its own tiny enum rather
// than passing `Option[Tls.Certificate]` twice into a pure function so
// that function stays entirely extern-type-free (directly testable from
// any package, no `Std.Tls` dependency needed for the test).
pub enum TlsCaMode {
  case NoCaConfigured
  case AdditiveCa
  case ExclusiveCa
}

/// What the validation callback should do once it has decided whether the
/// platform-reported result is even eligible for this callback to act on.
pub enum TlsValidationDecision {
  case RejectImmediately
  case AcceptWithoutCustomChain
  case TryCustomChain
}

/// Pure decision core for the `ServerCertificateCustomValidationCallback`
/// installed below (docs/61 §3.2; #5877, MITM fix #5950).
///
/// `hostnameAndAvailabilityOk` must be `false` whenever the platform's own
/// `SslPolicyErrors` carried `RemoteCertificateNameMismatch` or
/// `RemoteCertificateNotAvailable`, in ANY combination — see
/// `applyTlsOptions`'s call site for how that's derived. This function
/// does not know or care WHY it's false, only that once it is,
/// `RejectImmediately` is the only possible outcome regardless of
/// `chainAlreadyOk` or `caMode`: no chain-trust configuration, however
/// permissive, can ever paper over a hostname mismatch or an absent
/// certificate. This is the exact property #5950 was filed against (the
/// original callback re-ran ONLY a chain check and never looked at
/// hostname at all) and the property `http_tls_client_tests.l`'s
/// `resolveTlsValidationDecision` regression test asserts exhaustively.
///
/// Once hostname+availability are confirmed fine: an exclusive CA always
/// re-validates against ONLY that CA (`TryCustomChain`), even when the
/// platform already trusted the chain via the platform store — exclusive
/// means the platform's own trust conclusion never counts. An additive CA
/// accepts the platform's own verdict directly when the chain was already
/// fine (`AcceptWithoutCustomChain`), and only asks for the custom-CA
/// fallback when the platform's chain check failed
/// (`TryCustomChain`). With no CA configured (only reachable when
/// `insecureSkipVerify` installed this callback but its own short-circuit
/// at the call site didn't fire — never in practice), this mirrors the
/// platform's own chain verdict directly.
@pure
pub func resolveTlsValidationDecision(
  hostnameAndAvailabilityOk: in Bool, chainAlreadyOk: in Bool, caMode: in TlsCaMode
): TlsValidationDecision {
  if not hostnameAndAvailabilityOk {
    RejectImmediately
  } else {
    match caMode {
      case ExclusiveCa -> TryCustomChain
      case AdditiveCa ->
        if chainAlreadyOk {
          AcceptWithoutCustomChain
        } else {
          TryCustomChain
        }
      case NoCaConfigured ->
        if chainAlreadyOk {
          AcceptWithoutCustomChain
        } else {
          RejectImmediately
        }
    }
  }
}

// Assembles TLS options directly on `handler` (module header: no separate
// options object on this path — every property here is either a plain
// `HttpClientHandler` property or, for the validation callback, a genuine
// `Func<...>`-typed one). The validation callback is installed only when
// it can change the outcome (`insecureSkipVerify`, or a configured CA) —
// with neither, the platform's ordinary validation already applies and
// needs no override.
//
// The callback itself is written as a lambda LITERAL directly at the
// `handlerSetValidationCallback` call site, not built by a separate
// function and passed in: the delegate-bridge FFI boundary (Epic #1877/
// #3923, F0026) requires the argument bound to a real .NET delegate type
// to be a lambda literal at the call site itself — binding it to a `val`
// or returning it from a helper function first is rejected at compile
// time. `insecureSkipVerify`/`caCertificate`/`exclusiveCaCertificate` are
// ordinary closure captures (unaffected by that constraint, which is
// specifically about the ARGUMENT EXPRESSION shape, not about capturing).
// Calling a plain function FROM WITHIN the lambda body (as this one calls
// `resolveTlsValidationDecision`) is unaffected too — F0026 is about what
// the lambda ITSELF is bound to, not what its body does.
//
// #5950 (MITM fix): installing this callback disables .NET's OWN
// hostname check entirely — the runtime still RUNS it (and its own chain
// validation) before invoking the callback, but only reports the combined
// result via `sslPolicyErrors`; it is this callback's job to honor that
// result, not just the chain half of it. `hostnameAndAvailabilityOk`
// below is `true` only for exactly `SslPolicyErrors.None` (everything
// passed) or exactly `RemoteCertificateChainErrors` (ONLY the chain
// failed — hostname and cert-presence were both fine); every other value
// — `RemoteCertificateNameMismatch` or `RemoteCertificateNotAvailable`,
// alone or combined with a chain error — makes it `false`, and
// `resolveTlsValidationDecision` above then rejects unconditionally
// before any CA logic runs, so a certificate valid-by-chain but issued
// for the wrong host is never accepted. This is a plain `==` (`ceq` over
// the enum's underlying int) against a SPECIFIC known value, not a
// bitwise decompose/combine, so it needs no FFI capability beyond what
// `sslPolicyErrorsNone`/`sslPolicyErrorsChainErrorsOnly`'s comment
// already covers.
//
// `insecureSkipVerify` (already resolved through the dual-key policy by
// `Std.Http` before this is ever called) short-circuits to `true`
// unconditionally BEFORE any of the above runs — the "nuclear option,"
// which deliberately skips the hostname check too, matching docs/61 §4
// ("disables peer chain verification and hostname matching together").
func applyTlsOptions(
  handler: in HttpClientHandler,
  caCertificate: in Option[Tls.Certificate],
  exclusiveCaCertificate: in Option[Tls.Certificate],
  clientIdentity: in Option[Tls.Identity],
  minTlsVersion: in Option[Tls.TlsVersion],
  insecureSkipVerify: in Bool,
): Unit {
  match minTlsVersion {
    case Some(v) -> match v {
      case Tls13 -> handlerSetSslProtocols(handler, sslProtocolsTls13())
      case Tls12 -> ()
    }
    case None -> ()
  }
  match clientIdentity {
    case Some(identity) -> {
      val _ = certCollectionAdd(handlerClientCertificates(handler), identity.rawHandle())
    }
    case None -> ()
  }
  val caMode = match exclusiveCaCertificate {
    case Some(_) -> ExclusiveCa
    case None -> match caCertificate {
      case Some(_) -> AdditiveCa
      case None -> NoCaConfigured
    }
  }
  val needsCallback = insecureSkipVerify or isSome(caCertificate) or isSome(exclusiveCaCertificate)
  if needsCallback {
    handlerSetValidationCallback(
      handler,
      {
        request: HttpRequestMessage, cert: TlsHost.CertHandle, chain: X509Chain, sslPolicyErrors: SslPolicyErrors ->
          if insecureSkipVerify {
            true
          } else {
            val hostnameAndAvailabilityOk =
              sslPolicyErrors == sslPolicyErrorsNone() or sslPolicyErrors == sslPolicyErrorsChainErrorsOnly()
            val chainAlreadyOk = sslPolicyErrors == sslPolicyErrorsNone()
            match resolveTlsValidationDecision(hostnameAndAvailabilityOk, chainAlreadyOk, caMode) {
              case RejectImmediately -> false
              case AcceptWithoutCustomChain -> true
              case TryCustomChain -> match exclusiveCaCertificate {
                case Some(ca) -> buildCustomChain(cert, ca)
                case None -> match caCertificate {
                  case Some(ca) -> buildCustomChain(cert, ca)
                  case None -> false
                }
              }
            }
          }
      }
    )
  }
}

// The single entry point for every TLS-configured client — `Std.Http`
// calls this only when `socketPath` is unset (module header: Unix sockets
// and TLS options don't compose on this target today), so this always
// builds through `HttpClientHandler`, never `SocketsHttpHandler`. Reuses
// the existing `newHandler`/`setAllowAutoRedirect`/
// `setMaxAutomaticRedirections`/`rawNewClientFromHandler` primitives and
// the `applyHttp11Exact`/`applyHttp2OrLower` one-`apply*`-call discipline,
// so a TLS-configured client is version-stamped exactly once, same as
// every other client this file constructs.
pub func hostClientWithTls(
  maxRedirects: in Option[Int],
  noRedirects: in Bool,
  pinHttp11: in Bool,
  caCertificate: in Option[Tls.Certificate],
  exclusiveCaCertificate: in Option[Tls.Certificate],
  clientIdentity: in Option[Tls.Identity],
  minTlsVersion: in Option[Tls.TlsVersion],
  insecureSkipVerify: in Bool,
): HttpClientHandle {
  val handler = newHandler()
  if noRedirects {
    setAllowAutoRedirect(handler, false)
  } else {
    setAllowAutoRedirect(handler, true)
    match maxRedirects {
      case Some(n) -> setMaxAutomaticRedirections(handler, n)
      case None -> ()
    }
  }
  applyTlsOptions(handler, caCertificate, exclusiveCaCertificate, clientIdentity, minTlsVersion, insecureSkipVerify)
  val raw = rawNewClientFromHandler(handler)
  if pinHttp11 {
    applyHttp11Exact(raw)
  } else {
    applyHttp2OrLower(raw)
  }
}

// `ResponseHeader` (#5568): native Lyric over `HttpHeaders.Contains` +
// `HttpHeaders.GetValues`, plus a NON-GENERIC `System.Collections.IEnumerator`
// walk to take the first value.  The previous shape —
// `HttpHeaders.TryGetValues(name, out IEnumerable<string>)` — was an instance
// extern with a generic-typed `out` parameter: the emitted MemberRef was
// unbindable, so every `HttpResponse.header` call faulted at run time with
// MissingMethodException.  `Contains` guards `GetValues`, so the
// absent-header case never rides on exception control flow; the value walk
// goes through the non-generic `IEnumerable` slot (which
// `IEnumerable<string>` always implements), so no MemberRef in this chain
// mentions a generic parameter in an argument position.  The BCL splits
// headers across `response.Headers` (general + caller-set) and
// `response.Content.Headers` (Content-Type, Content-Length, …) — try the
// former first, then fall through to the latter, then `""`.
extern type HttpResponseHeaders = "System.Net.Http.Headers.HttpResponseHeaders"

extern type HttpContentHeaders = "System.Net.Http.Headers.HttpContentHeaders"

extern type IEnumerableStr = "System.Collections.Generic.IEnumerable`1[System.String]"

extern type NonGenericEnumerator = "System.Collections.IEnumerator"

@externInstance
@externTarget("System.Net.Http.HttpResponseMessage.Headers")
func responseHeadersOf(r: in HttpResponseMessage): HttpResponseHeaders = ()

@externInstance
@externTarget("System.Net.Http.HttpContent.Headers")
func contentHeadersOf(c: in HttpContent): HttpContentHeaders = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.Contains")
func responseHeadersContain(h: in HttpResponseHeaders, name: in String): Bool = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.Contains")
func contentHeadersContain(h: in HttpContentHeaders, name: in String): Bool = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.GetValues")
func responseHeaderValues(h: in HttpResponseHeaders, name: in String): IEnumerableStr = ()

@externInstance
@externTarget("System.Net.Http.Headers.HttpHeaders.GetValues")
func contentHeaderValues(h: in HttpContentHeaders, name: in String): IEnumerableStr = ()

@externInstance
@externTarget("System.Collections.IEnumerable.GetEnumerator")
func headerValuesEnumerator(values: in IEnumerableStr): NonGenericEnumerator = ()

@externInstance
@externTarget("System.Collections.IEnumerator.MoveNext")
func enumeratorMoveNext(e: in NonGenericEnumerator): Bool = ()

@externInstance
@externTarget("System.Collections.IEnumerator.Current")
func enumeratorCurrent(e: in NonGenericEnumerator): String = ()

// First element of `values`, or `""` when the sequence is empty.
func firstHeaderValue(values: in IEnumerableStr): String {
  val e = headerValuesEnumerator(values)
  if enumeratorMoveNext(e) {
    enumeratorCurrent(e)
  } else {
    ""
  }
}

pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  // Each leg is exception-mapped SEPARATELY: `Contains` throws
  // InvalidOperationException for a known header of the other category
  // (`response.Headers.Contains("Content-Type")` — the strict category
  // check that motivated the BCL's TryGetValues) and FormatException for a
  // syntactically invalid name, so a throwing response-leg lookup must
  // still fall through to the content leg rather than aborting the whole
  // read.
  val fromResponse = try {
    val respHeaders = responseHeadersOf(response)
    if responseHeadersContain(respHeaders, name) {
      firstHeaderValue(responseHeaderValues(respHeaders, name))
    } else {
      ""
    }
  } catch Bug as _ {
    ""
  }
  if fromResponse.length > 0 {
    return fromResponse
  }
  return try {
    val contentHeaders = contentHeadersOf(responseContent(response))
    if contentHeadersContain(contentHeaders, name) {
      firstHeaderValue(contentHeaderValues(contentHeaders, name))
    } else {
      ""
    }
  } catch Bug as _ {
    ""
  }
}

// `negotiatedVersion` (docs/61 §5.1; #5879): `HttpResponseMessage.Version`
// carries the wire protocol version the response actually used. Only the
// major component distinguishes HTTP/1.1 from h2/h3, so `Std.Http` maps
// this raw major int onto `HttpVersion` (1 -> Http11, 2 -> Http2, 3 ->
// Http3).
@externInstance
@externTarget("System.Net.Http.HttpResponseMessage.Version")
func responseVersionOf(response: in HttpResponseMessage): Version = ()

@externInstance
@externTarget("System.Version.Major")
func versionMajorOf(v: in Version): Int = ()

pub func hostResponseVersionMajor(response: in HttpResponseMessage): Int {
  versionMajorOf(responseVersionOf(response))
}

// ---------------------------------------------------------------------------
// V0012-safe wrappers — issue #2985.
//
// The self-hosted MSIL emitter cannot emit SM resume labels inside CLR
// protected regions (try/catch/finally): the JIT rejects branches INTO a
// protected region (#2737).  Std.Http keeps its awaits OUTSIDE try blocks
// for exactly this reason.
//
// The wrappers below are safe despite using await-in-try because every
// awaited callee (`clientSendAsync`, `clientGetAsync`, etc.) is declared
// `@externTarget async func` with return type T (not Task<T>).  The MSIL
// emitter's `isTaskTypeMsil` check therefore returns false for every EAwait
// in these bodies: Phase A counts zero SM resume points, Phase B emits no
// SM resume labels, and the `try` block compiles as ordinary (non-SM) IL
// — no label ever lands inside a CLR protected region.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientSendAsync(client, request))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientGetAsync(client, url))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientPostAsync(client, url, newStringContent(body, utf8(), contentType)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  return try {
    Ok(value = await contentReadAsString(responseContent(response)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  return try {
    Ok(value = await contentReadAsBytes(responseContent(response)))
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
    Ok(value = await clientSendAsyncCancel(client, request, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await clientGetAsyncCancel(client, url, token))
  } catch Bug as b {
    Err(error = b.message)
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
    Ok(value = await clientPostAsyncCancel(client, url, newStringContent(body, utf8(), contentType), token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  return try {
    Ok(value = await contentReadAsStringCancel(responseContent(response), token))
  } catch Bug as b {
    Err(error = b.message)
  }
}
