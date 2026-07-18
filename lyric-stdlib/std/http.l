//! std/http.l - safe HTTP client foundation.
//!
//! Public HTTP APIs are Result-based: connection, timeout, invalid URL,
//! and response-body failures are data, not exceptions. The only place
//! host failures are caught is this stdlib boundary.
@runtime_checked
package Std.Http

import Std.Console
import Std.Core
import Std.Environment
import Std.Errors
import Std.HttpHost as HostHttp
import Std.Task
import Std.Tls

// ---------------------------------------------------------------------------
// HTTP request and response types.
// ---------------------------------------------------------------------------
@stable(since = "1.0")
pub enum HttpMethod {
  case GET
  case POST
  case PUT
  case DELETE
  case PATCH
  case HEAD
  case OPTIONS
}

/// Negotiated (or requested) HTTP protocol version (docs/61 §5.1, D128
/// decision 4).
///
/// `Http2` is the default on both targets: it negotiates h2-or-lower via
/// ALPN over TLS and falls back to HTTP/1.1 automatically. Plaintext
/// (`http://`) connections have no ALPN to negotiate with, so they stay
/// HTTP/1.1 regardless of this setting — this default only changes
/// behaviour for HTTPS peers that advertise h2. `Http11` pins the
/// connection to HTTP/1.1 exactly, never attempting an upgrade. `Http3`
/// is reserved: neither target has a usable HTTP/3 story yet (the JDK
/// has none; the .NET msquic distribution/detection story is open, see
/// docs/61 Q-TLS-002). A builder configured with `Http3` still
/// `build()`s successfully — builder construction stays infallible by
/// design — but every operation on the resulting client fails with a
/// typed `HttpError.ConnectionFailed` naming this limitation.
@stable(since = "1.2")
pub enum HttpVersion {
  case Http11
  case Http2
  case Http3
}

/// Opaque validated URL wrapper.
///
/// URLs enter the stdlib as strings and are validated once at the
/// boundary. This first slice accepts HTTP and HTTPS URLs only; richer
/// URI decomposition belongs in the future `Std.Net` surface.
@stable(since = "1.0")
pub opaque type Url {
  value: String
  invariant: value.length > 0
}

/// Alias for callers that prefer URI terminology.
@stable(since = "1.0")
pub alias Uri = Url

/// Opaque request wrapper.
///
/// The host request handle is hidden so callers compose requests via
/// Std.Http helpers instead of mutating host objects directly.
@stable(since = "1.0")
pub opaque type HttpRequest {
  handle: HostHttp.HttpRequestMessage
  url: String
}

/// Opaque response wrapper.
///
/// Body reads remain explicit and fallible through `bodyText` and
/// `bodyBytes`; status inspection itself is total.
@stable(since = "1.0")
pub opaque type HttpResponse {
  handle: HostHttp.HttpResponseMessage
  url: String
}

/// Header collection marker reserved for future request/response header
/// iteration. Phase 4 exposes mutation through `withHeader`.
@stable(since = "1.0")
pub opaque type Headers {
  request: HostHttp.HttpRequestMessage
}

// ---------------------------------------------------------------------------
// HttpClient interface — the public contract for outbound HTTP transport.
//
// Callers receive an HttpClient from the factory functions or from
// HttpClientBuilder.build(); they never construct HttpClientImpl directly.
// Holding the interface rather than a concrete type allows dependency
// injection, test doubles, and alternative transport implementations.
// ---------------------------------------------------------------------------
/// Contract for outbound HTTP transport.
///
/// All methods accept the URL as a plain `String`; validation and
/// `InvalidUrl` errors are surfaced through the `Result` return type.
/// For requests that need custom headers or non-string bodies, use
/// `send` with a pre-built `HttpRequest`.
@stable(since = "1.1")
pub interface HttpClient {
  /// Send a pre-built HTTP request.
  async func send(request: in HttpRequest): Result[HttpResponse, HttpError]

  /// Send a pre-built HTTP request with explicit cancellation, honouring
  /// *this* client's own configuration (redirects, Unix socket, etc.) —
  /// unlike the free `sendWithCancelAsync`/`getWithCancelAsync`/
  /// `postWithCancelAsync` functions, which always operate on the global
  /// default client and so cannot be used by callers holding an injected
  /// `HttpClient` built via `clientWithRedirects`/`clientWithUnixSocket`/
  /// `HttpClientBuilder`. Compose with `request`/`withJsonBody`/
  /// `withStringBody` to cancel PUT/DELETE/PATCH calls; there is no
  /// separate `getWithCancel`/`postWithCancel` on this interface since
  /// `sendWithCancel` covers every verb. Added in the interface's 1.2 slice
  /// (#4014).
  async func sendWithCancel(request: in HttpRequest, token: in CancellationToken): Result[HttpResponse, HttpError]

  /// GET the given URL.
  async func get(url: in String): Result[HttpResponse, HttpError]

  /// POST a UTF-8 text body to the given URL.
  ///
  /// Content-Type is fixed at `text/plain; charset=utf-8`. For a JSON
  /// body, build the request explicitly instead:
  /// `send(withJsonBody(request(POST, url), json))`.
  async func post(url: in String, body: in String): Result[HttpResponse, HttpError]

  /// PUT a UTF-8 text body to the given URL.
  ///
  /// Content-Type is fixed at `text/plain; charset=utf-8` (see `post`).
  async func put(url: in String, body: in String): Result[HttpResponse, HttpError]

  /// DELETE the resource at the given URL.
  async func delete(url: in String): Result[HttpResponse, HttpError]

  /// PATCH a UTF-8 text body to the given URL.
  ///
  /// Content-Type is fixed at `text/plain; charset=utf-8` (see `post`).
  async func patch(url: in String, body: in String): Result[HttpResponse, HttpError]
}

// Private concrete implementation backed by a kernel HttpClientHandle.
// Constructed only by the factory functions and HttpClientBuilder.build().
//
// `unsupportedReason`: set only for a builder configured with
// `withHttpVersion(Http3)`. Builder construction stays infallible (docs/61
// §3.2's `build()`-never-fails contract), so the typed failure is deferred
// to first use here instead: every trait method below checks this field
// FIRST and returns `ConnectionFailed` without ever touching `handle` or the
// kernel. `handle` still holds an ordinary (never-used) client in that case
// so this record's shape doesn't need an `Option`.
record HttpClientImpl {
  handle: HostHttp.HttpClientHandle
  unsupportedReason: Option[String]
}

func unsupportedClientError(url: in String, reason: in String): HttpError {
  ConnectionFailed(url = url, message = reason)
}

impl HttpClient for HttpClientImpl {
  async func send(request: in HttpRequest): Result[HttpResponse, HttpError] {
    match self.unsupportedReason {
      case Some(reason) -> return Err(error = unsupportedClientError(request.url, reason))
      case None -> ()
    }
    val result = await HostHttp.hostSendSafe(self.handle, request.handle)
    match result {
      case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
      case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
    }
  }

  async func sendWithCancel(request: in HttpRequest, token: in CancellationToken): Result[HttpResponse, HttpError] {
    match self.unsupportedReason {
      case Some(reason) -> return Err(error = unsupportedClientError(request.url, reason))
      case None -> ()
    }
    val result = await HostHttp.hostSendWithCancelSafe(self.handle, request.handle, token)
    match result {
      case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
      case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
    }
  }

  async func get(url: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        match self.unsupportedReason {
          case Some(reason) -> return Err(error = unsupportedClientError(parsed.value, reason))
          case None -> ()
        }
        val result = await HostHttp.hostGetSafe(self.handle, parsed.value)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func post(url: in String, body: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        match self.unsupportedReason {
          case Some(reason) -> return Err(error = unsupportedClientError(parsed.value, reason))
          case None -> ()
        }
        val result = await HostHttp.hostPostStringSafe(self.handle, parsed.value, body, "text/plain")
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func put(url: in String, body: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        match self.unsupportedReason {
          case Some(reason) -> return Err(error = unsupportedClientError(parsed.value, reason))
          case None -> ()
        }
        val req = HttpRequest(
          handle = HostHttp.hostWithStringBody(
            HostHttp.hostMakeRequest("PUT", parsed.value),
            "text/plain",
            body
          ),
          url = parsed.value
        )
        val result = await HostHttp.hostSendSafe(self.handle, req.handle)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func delete(url: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        match self.unsupportedReason {
          case Some(reason) -> return Err(error = unsupportedClientError(parsed.value, reason))
          case None -> ()
        }
        val req = HttpRequest(handle = HostHttp.hostMakeRequest("DELETE", parsed.value), url = parsed.value)
        val result = await HostHttp.hostSendSafe(self.handle, req.handle)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func patch(url: in String, body: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        match self.unsupportedReason {
          case Some(reason) -> return Err(error = unsupportedClientError(parsed.value, reason))
          case None -> ()
        }
        val req = HttpRequest(
          handle = HostHttp.hostWithStringBody(
            HostHttp.hostMakeRequest("PATCH", parsed.value),
            "text/plain",
            body
          ),
          url = parsed.value
        )
        val result = await HostHttp.hostSendSafe(self.handle, req.handle)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// HttpClientBuilder — fluent configuration for HttpClient instances.
//
// Each with* method returns a new builder value; call build() to obtain
// the configured HttpClient.  The factory convenience functions
// (defaultClient, clientWithUnixSocket, etc.) cover the common cases.
// ---------------------------------------------------------------------------
/// Builder for configuring an HttpClient.
///
/// ```lyric
/// val client = HttpClientBuilder.new()
///     .withUnixSocket("/var/run/docker.sock")
///     .withNoRedirects()
///     .build()
/// ```
@stable(since = "1.1")
pub record HttpClientBuilder {
  socketPath: Option[String]
  maxRedirects: Option[Int]
  noRedirects: Bool
  httpVersion: Option[HttpVersion]
  caCertificate: Option[Certificate]
  exclusiveCaCertificate: Option[Certificate]
  clientIdentity: Option[Identity]
  minTlsVersion: Option[TlsVersion]
  insecureSkipVerify: Bool
}

/// Construct a default builder (TCP transport, redirect-following, process-wide singleton).
@stable(since = "1.1")
pub func HttpClientBuilder.new(): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = None,
    maxRedirects = None,
    noRedirects = false,
    httpVersion = None,
    caCertificate = None,
    exclusiveCaCertificate = None,
    clientIdentity = None,
    minTlsVersion = None,
    insecureSkipVerify = false
  )
}

/// Route all requests through the Unix domain socket at `path`.
///
/// Common paths: Docker at `/var/run/docker.sock`, systemd at
/// `/run/systemd/private/io.systemd.Journal`.
@stable(since = "1.1")
pub func HttpClientBuilder.withUnixSocket(b: in HttpClientBuilder, path: in String): HttpClientBuilder
  requires: path.length > 0
{
  HttpClientBuilder(
    socketPath = Some(value = path),
    maxRedirects = b.maxRedirects,
    noRedirects = b.noRedirects,
    httpVersion = b.httpVersion,
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = b.clientIdentity,
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// Follow up to `max` redirects automatically.
@stable(since = "1.1")
pub func HttpClientBuilder.withRedirects(b: in HttpClientBuilder, max: in Int): HttpClientBuilder
  requires: max >= 0
{
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = Some(value = max),
    noRedirects = false,
    httpVersion = b.httpVersion,
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = b.clientIdentity,
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// Do not follow redirects.  3xx responses are returned to the caller as-is.
@stable(since = "1.1")
pub func HttpClientBuilder.withNoRedirects(b: in HttpClientBuilder): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = None,
    noRedirects = true,
    httpVersion = b.httpVersion,
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = b.clientIdentity,
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// Set the negotiated HTTP protocol version. See `HttpVersion` for the
/// per-case semantics (default `Http2`, exact `Http11` pin, reserved
/// `Http3`).
@stable(since = "1.2")
pub func HttpClientBuilder.withHttpVersion(b: in HttpClientBuilder, version: in HttpVersion): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = b.maxRedirects,
    noRedirects = b.noRedirects,
    httpVersion = Some(value = version),
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = b.clientIdentity,
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// Add `cert` as an ADDITIONAL trust root alongside the platform trust
/// store (docs/61 §3.2) — the common "internal CA plus public internet"
/// case. See `withExclusiveCaCertificate` for the trust-REPLACING variant;
/// the two have distinct names precisely so the more dangerous semantics
/// is visible at the call site.
///
/// **Precedence when both are configured on the same builder:**
/// `withExclusiveCaCertificate` always wins — the stricter, service-mesh
/// intent takes priority, and a `cert` passed here is silently discarded
/// (call-site order does not matter either way). Configure only one of
/// the two on a given builder; combining them is legal but the additive
/// certificate never takes effect.
///
/// Supported on both `--target dotnet` and `--target jvm` (#5877, #5878).
/// On jvm, `cert` is added to a `KeyStore` alongside every certificate the
/// platform's own default trust store already accepts — a chain valid
/// against either set is accepted.
@stable(since = "1.2")
pub func HttpClientBuilder.withCaCertificate(b: in HttpClientBuilder, cert: in Certificate): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = b.maxRedirects,
    noRedirects = b.noRedirects,
    httpVersion = b.httpVersion,
    caCertificate = Some(value = cert),
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = b.clientIdentity,
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// REPLACE the platform trust store entirely with `cert` (docs/61 §3.2) —
/// the service-mesh case, where a peer's certificate is signed by a
/// private CA and public-internet trust should not apply at all. See
/// `withCaCertificate` for the additive variant.
///
/// **Precedence:** if `withCaCertificate` was also called on this
/// builder, THIS wins unconditionally — see its doc comment for the full
/// rule.
///
/// Supported on both targets (#5877, #5878). On jvm, `cert` is the ONLY
/// entry in the `KeyStore` fed to the `TrustManagerFactory` — the
/// platform's own trust store is never consulted.
@stable(since = "1.2")
pub func HttpClientBuilder.withExclusiveCaCertificate(b: in HttpClientBuilder, cert: in Certificate): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = b.maxRedirects,
    noRedirects = b.noRedirects,
    httpVersion = b.httpVersion,
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = Some(value = cert),
    clientIdentity = b.clientIdentity,
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// Present `identity` as this client's own certificate for mutual TLS
/// (docs/61 §3.2).
///
/// Supported on both targets (#5877, #5878). On jvm, `identity`'s
/// certificate + private key populate a `KeyStore` fed to a
/// `KeyManagerFactory`.
@stable(since = "1.2")
pub func HttpClientBuilder.withClientIdentity(b: in HttpClientBuilder, identity: in Identity): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = b.maxRedirects,
    noRedirects = b.noRedirects,
    httpVersion = b.httpVersion,
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = Some(value = identity),
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// Set the minimum negotiated TLS protocol version (docs/61 §3.2).
/// `Std.Tls.TlsVersion`'s floor is TLS 1.2 — there is no way to configure
/// anything older.
///
/// Supported on both targets (#5877, #5878). On jvm, lowers to
/// `SSLParameters.setProtocols` (`["TLSv1.3"]` for the `Tls13` pin,
/// `["TLSv1.2", "TLSv1.3"]` for the `Tls12` floor).
@stable(since = "1.2")
pub func HttpClientBuilder.withMinTlsVersion(b: in HttpClientBuilder, version: in TlsVersion): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = b.maxRedirects,
    noRedirects = b.noRedirects,
    httpVersion = b.httpVersion,
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = b.clientIdentity,
    minTlsVersion = Some(value = version),
    insecureSkipVerify = b.insecureSkipVerify
  )
}

/// Request that TLS certificate verification be disabled for this client
/// (docs/61 §4, D128 decision 2).
///
/// **This alone does NOT disable verification.** Per the dual-key policy,
/// the environment variable `LYRIC_TLS_ALLOW_INSECURE=1` must ALSO be set
/// at `build()` time:
///
/// | This called? | Env var set? | Effect |
/// |---|---|---|
/// | no | no | Verification enabled (secure default) |
/// | no | yes | Verification enabled — env var alone is a no-op |
/// | yes | no | Verification enabled, plus a one-time stderr warning |
/// | yes | yes | Verification disabled for this client only |
///
/// Never use in production. Supported on both targets (#5877, #5878).
///
/// **jvm-specific note:** this disables CHAIN/CA verification (installs an
/// all-trusting `X509TrustManager`) but NOT hostname verification —
/// `java.net.http.HttpClient` enforces its own endpoint-identification
/// check unconditionally, independent of any supplied `SSLContext`/
/// `SSLParameters`, and there is no public API to disable it (verified
/// empirically). This is STRICTER than the policy this doc comment
/// otherwise describes ("disables peer chain verification and hostname
/// matching together"), not a gap: on `--target jvm` a hostname-mismatched
/// certificate is rejected even with this option enabled.
@stable(since = "1.2")
pub func HttpClientBuilder.withInsecureSkipVerify(b: in HttpClientBuilder): HttpClientBuilder {
  HttpClientBuilder(
    socketPath = b.socketPath,
    maxRedirects = b.maxRedirects,
    noRedirects = b.noRedirects,
    httpVersion = b.httpVersion,
    caCertificate = b.caCertificate,
    exclusiveCaCertificate = b.exclusiveCaCertificate,
    clientIdentity = b.clientIdentity,
    minTlsVersion = b.minTlsVersion,
    insecureSkipVerify = true
  )
}

/// Whether this compilation target's kernel can honor
/// `HttpClientBuilder`'s TLS options (`withCaCertificate`,
/// `withExclusiveCaCertificate`, `withClientIdentity`,
/// `withMinTlsVersion`, `withInsecureSkipVerify`; docs/61 §3.2).
///
/// `true` on `--target dotnet` and `--target jvm` (#5877, #5878) —
/// `build()` stays infallible either way, but a TLS-configured client
/// actually connects with the configured options on both targets today.
/// A future target lacking TLS config support would still have `build()`
/// succeed, with every request through the resulting client failing with a
/// typed `ConnectionFailed` naming the gap, rather than silently
/// connecting without the configured options — this probe exists so
/// callers can detect that case ahead of time.
@stable(since = "1.2")
pub func tlsConfigSupported(): Bool {
  HostHttp.hostSupportsTlsConfig()
}

func hasTlsOptions(b: in HttpClientBuilder): Bool {
  isSome(b.caCertificate)
    or isSome(b.exclusiveCaCertificate)
    or isSome(b.clientIdentity)
    or isSome(b.minTlsVersion)
    or b.insecureSkipVerify
}

/// Outcome of resolving the dual-key insecure-verify policy (docs/61 §4,
/// D128 decision 2) from its two independent inputs. Exposed as `pub`
/// (rather than kept an internal `build()` implementation detail) for two
/// reasons: it makes the pure resolution logic directly unit-testable
/// without mutating the process environment, and the same policy governs
/// `Std.Tls.TlsServerConfig`'s future `insecureSkipClientVerify` (docs/61
/// §4) — server-side TLS code can reuse this instead of re-deriving it.
@stable(since = "1.2")
pub enum InsecureVerifyPolicy {
  case VerificationEnabled
  case VerificationEnabledWarn
  case VerificationDisabled
}

/// Pure resolution of the dual-key policy matrix (docs/61 §4 — the exact
/// table `withInsecureSkipVerify`'s doc comment reproduces). Both inputs
/// are read once, at `build()` time.
@pure
@stable(since = "1.2")
pub func resolveInsecureVerifyPolicy(codeOptIn: in Bool, envAllows: in Bool): InsecureVerifyPolicy {
  if not codeOptIn {
    VerificationEnabled
  } else if envAllows {
    VerificationDisabled
  } else {
    VerificationEnabledWarn
  }
}

val insecureAllowEnvVar: String = "LYRIC_TLS_ALLOW_INSECURE"

// Read once, at build() time (docs/61 §4: "The env var is read at client
// build time, not per request").
func envAllowsInsecure(): Bool {
  getVarOrDefault(insecureAllowEnvVar, "") == "1"
}

func warnInsecureVerifyRequestedWithoutEnv(): Unit {
  error(
    "[Std.Http] warning: withInsecureSkipVerify() requested but " + insecureAllowEnvVar +
      " is not set; TLS certificate verification remains ENABLED."
  )
}

/// Build the configured `HttpClient`.
///
/// Stays infallible even when `httpVersion` is `Http3`, or when TLS
/// options are configured on a target that does not support them yet
/// (see `HttpVersion`'s doc comment and `tlsConfigSupported()`): the
/// returned client is fully constructed, but every operation on it fails
/// with a typed `ConnectionFailed` naming the unsupported feature.
@stable(since = "1.1")
pub func HttpClientBuilder.build(b: in HttpClientBuilder): HttpClient {
  // Unwrap `Option[HttpVersion]` to a plain `HttpVersion` (defaulting the
  // unset case to `Http2`, the documented default) BEFORE matching its
  // cases: matching a nested union case directly inside `Some(...)` (e.g.
  // `case Some(Http11) -> ...`) is avoided here on purpose — matching the
  // already-unwrapped value one level down keeps every case match a plain
  // top-level `HttpVersion` match, the same shape used everywhere else in
  // this file.
  val version = match b.httpVersion {
    case Some(v) -> v
    case None -> Http2
  }
  val pinHttp11 = match version {
    case Http11 -> true
    case Http2 -> false
    case Http3 -> false
  }

  // Dual-key insecure-verify policy (docs/61 §4) — resolved once, here,
  // before any kernel construction.
  val insecurePolicy = resolveInsecureVerifyPolicy(b.insecureSkipVerify, envAllowsInsecure())
  match insecurePolicy {
    case VerificationEnabledWarn -> warnInsecureVerifyRequestedWithoutEnv()
    case VerificationEnabled -> ()
    case VerificationDisabled -> ()
  }
  val effectiveInsecureSkipVerify = match insecurePolicy {
    case VerificationDisabled -> true
    case VerificationEnabled -> false
    case VerificationEnabledWarn -> false
  }

  val hasTls = hasTlsOptions(b)
  val tlsSupported = HostHttp.hostSupportsTlsConfig()
  // Unix sockets and TLS options don't compose on `--target dotnet` today
  // (see `_kernel/http_host.l`'s TLS section header: Unix sockets require
  // `SocketsHttpHandler`, whose only certificate-validation hook is a
  // custom .NET delegate type the current FFI delegate-bridge cannot bind
  // to). `--target jvm` never reaches this branch for a DIFFERENT,
  // unrelated, pre-existing reason: Unix domain sockets are unconditionally
  // unsupported there regardless of TLS (#2663 — `java.net.http.HttpClient`
  // has no Unix-socket transport at all; `hostClientWithUnixSocket` panics
  // unconditionally on that target). Gated on `tlsSupported` so this
  // dotnet-specific reason never shadows the generic "unsupported on this
  // target" reason below on a hypothetical future target with no TLS
  // config support at all. `hostClientWithTls` is therefore only ever
  // called when there is no socket path at all.
  val unixSocketBlocksTls = isSome(b.socketPath) and hasTls and tlsSupported
  val tlsHandledByKernel = hasTls and tlsSupported and not unixSocketBlocksTls

  val handle = if tlsHandledByKernel {
    HostHttp.hostClientWithTls(
      b.maxRedirects,
      b.noRedirects,
      pinHttp11,
      b.caCertificate,
      b.exclusiveCaCertificate,
      b.clientIdentity,
      b.minTlsVersion,
      effectiveInsecureSkipVerify
    )
  } else {
    match b.socketPath {
      case Some(path) ->
        if b.noRedirects {
          if pinHttp11 {
            HostHttp.hostClientWithUnixSocketNoRedirectsHttp11(path)
          } else {
            HostHttp.hostClientWithUnixSocketNoRedirects(path)
          }
        } else {
          match b.maxRedirects {
            case Some(n) ->
              if pinHttp11 {
                HostHttp.hostClientWithUnixSocketAndRedirectsHttp11(path, n)
              } else {
                HostHttp.hostClientWithUnixSocketAndRedirects(path, n)
              }
            case None ->
              if pinHttp11 {
                HostHttp.hostClientWithUnixSocketHttp11(path)
              } else {
                HostHttp.hostClientWithUnixSocket(path)
              }
          }
        }
      case None ->
        if b.noRedirects {
          if pinHttp11 {
            HostHttp.hostClientNoRedirectsHttp11()
          } else {
            HostHttp.hostClientNoRedirects()
          }
        } else {
          match b.maxRedirects {
            case Some(n) ->
              if pinHttp11 {
                HostHttp.hostClientWithRedirectsHttp11(n)
              } else {
                HostHttp.hostClientWithRedirects(n)
              }
            case None ->
              if pinHttp11 {
                HostHttp.hostClientHttp11()
              } else {
                HostHttp.hostDefaultClient()
              }
          }
        }
    }
  }

  val http3UnsupportedReason = match version {
    case Http3 ->
      Some(
        value = "HTTP/3 is not supported on this target yet (see #5874 / docs/61-https-tls-http-versions.md Q-TLS-002)"
      )
    case Http11 -> None
    case Http2 -> None
  }
  val tlsUnsupportedReason = if unixSocketBlocksTls {
    Some(
      value = "TLS client configuration combined with withUnixSocket is not supported yet on this target " +
        "(SslClientAuthenticationOptions.RemoteCertificateValidationCallback is a custom .NET delegate type " +
        "the current FFI delegate-bridge cannot bind to); see issue #5947"
    )
  } else if hasTls and not tlsSupported {
    // Unreachable on both currently-shipped targets (dotnet: #5877; jvm:
    // #5878) — kept as a generic, honest fallback for any future target
    // whose kernel has not yet wired TLS config (docs/61's no-silent-skip
    // rule: `build()` still succeeds, but every request fails with a typed
    // error naming this gap, never a silent no-TLS-config connection).
    Some(
      value = "TLS client configuration (withCaCertificate/withExclusiveCaCertificate/withClientIdentity/" +
        "withMinTlsVersion/withInsecureSkipVerify) is not supported yet on this target " +
        "(docs/61-https-tls-http-versions.md §3.2)"
    )
  } else {
    None
  }
  val unsupportedReason = match http3UnsupportedReason {
    case Some(_) -> http3UnsupportedReason
    case None -> tlsUnsupportedReason
  }
  HttpClientImpl(handle = handle, unsupportedReason = unsupportedReason)
}

@pure
func methodName(method: in HttpMethod): String {
  match method {
    case GET -> "GET"
    case POST -> "POST"
    case PUT -> "PUT"
    case DELETE -> "DELETE"
    case PATCH -> "PATCH"
    case HEAD -> "HEAD"
    case OPTIONS -> "OPTIONS"
  }
}

// ---------------------------------------------------------------------------
// URL construction.
// ---------------------------------------------------------------------------
/// Parse and validate an HTTP(S) URL.
///
/// # Preconditions as data
/// - `raw` must be non-empty.
/// - `raw` must start with `http://` or `https://`.
///
/// # Errors
/// - `InvalidUrl`: empty or unsupported URL syntax.
@stable(since = "1.0")
pub func Url.tryFrom(raw: in String): Result[Url, HttpError] {
  if raw.length == 0 {
    return Err(error = InvalidUrl(url = raw))
  }
  if raw.startsWith("http://") or raw.startsWith("https://") {
    return Ok(value = Url(value = raw))
  }
  return Err(error = InvalidUrl(url = raw))
}

/// Return the original string value for a validated URL.
@pure
@stable(since = "1.0")
pub func Url.toString(url: in Url): String {
  return url.value
}

// ---------------------------------------------------------------------------
// Request construction.
// ---------------------------------------------------------------------------
/// Build a request with the given method and URL.
///
/// # Preconditions as data
/// - `url` must have been constructed by `Url.tryFrom`.
///
/// Host request construction failures are represented as HttpError by
/// `sendAsync`, not by this pure request-shaping helper.
@stable(since = "1.0")
pub func request(method: in HttpMethod, url: in Url): HttpRequest {
  return HttpRequest(handle = HostHttp.hostMakeRequest(methodName(method), url.value), url = url.value)
}

/// Add or replace one request header.
///
/// # Preconditions
/// - `key` must be non-empty. Empty header names are caller bugs.
@stable(since = "1.0")
pub func withHeader(request: in HttpRequest, key: in String, value: in String): HttpRequest
  requires: key.length > 0
{
  return HttpRequest(handle = HostHttp.hostWithHeader(request.handle, key, value), url = request.url)
}

/// Attach a JSON string body and set the request content type.
///
/// This helper does not validate that `json` is syntactically valid
/// JSON. Source-generated JSON encoders will feed this in later phases.
@stable(since = "1.0")
pub func withJsonBody(request: in HttpRequest, json: in String): HttpRequest {
  return HttpRequest(handle = HostHttp.hostWithStringBody(request.handle, "application/json", json), url = request.url)
}

/// Attach a plain UTF-8 text body.
@stable(since = "1.0")
pub func withTextBody(request: in HttpRequest, text: in String): HttpRequest {
  return HttpRequest(
    handle = HostHttp.hostWithStringBody(request.handle, "text/plain", text),
    url = request.url
  )
}

// ---------------------------------------------------------------------------
// Free-function HTTP operations — use the process-wide default client.
//
// These remain for callers that don't need per-call client configuration.
// For custom transport (Unix sockets, redirect policy, etc.) use
// HttpClientBuilder.build() and call methods on the resulting HttpClient.
// ---------------------------------------------------------------------------
/// Send a prepared HTTP request using the default client.
///
/// # Errors
/// - `ConnectionFailed`: DNS, connection, TLS, cancellation, or other
///   host send failures that are not classified more precisely yet.
/// - `Timeout`: reserved for future host timeout classification.
///
/// Non-2xx status codes are returned as successful HttpResponse values.
/// Callers decide whether to treat them as domain errors via status
/// helpers or `ensureSuccess`.
@stable(since = "1.0")
pub async func sendAsync(request: in HttpRequest): Result[HttpResponse, HttpError] {
  val result = await HostHttp.hostSendSafe(HostHttp.hostDefaultClient(), request.handle)
  match result {
    case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
    case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
  }
}

/// GET a URL string using the default client.
///
/// # Preconditions as data
/// - `url` must be a valid HTTP(S) URL or `InvalidUrl` is returned.
///
/// # Errors
/// - `InvalidUrl`: URL parsing failed.
/// - `ConnectionFailed` / `Timeout`: host send failures.
@stable(since = "1.0")
pub async func getAsync(url: in String): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostGetSafe(HostHttp.hostDefaultClient(), parsed.value)
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

/// POST a UTF-8 text body to a URL using the default client.
@stable(since = "1.0")
pub async func postAsync(url: in String, body: in String): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostPostStringSafe(HostHttp.hostDefaultClient(), parsed.value, body, "text/plain")
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Response inspection and body reads.
// ---------------------------------------------------------------------------
/// Return the numeric HTTP status code.
@pure
@stable(since = "1.0")
pub func HttpResponse.statusCode(response: in HttpResponse): Int {
  return HostHttp.hostStatusCode(response.handle)
}

/// Return true for 2xx status codes.
@pure
@stable(since = "1.0")
pub func HttpResponse.isSuccess(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 200 and code <= 299
}

/// Return true for 4xx status codes.
@pure
@stable(since = "1.0")
pub func HttpResponse.isClientError(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 400 and code <= 499
}

/// Return true for 5xx status codes.
@pure
@stable(since = "1.0")
pub func HttpResponse.isServerError(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 500 and code <= 599
}

/// Convert non-success HTTP status into `HttpError.BadStatus`.
///
/// Use this when the caller wants a transport-style error for any
/// non-2xx response. Otherwise inspect status codes explicitly.
@stable(since = "1.0")
pub func HttpResponse.ensureSuccess(response: in HttpResponse): Result[HttpResponse, HttpError] {
  if HttpResponse.isSuccess(response) {
    return Ok(value = response)
  }
  return Err(error = BadStatus(url = response.url, statusCode = HttpResponse.statusCode(response)))
}

/// Read the response body as text.
///
/// # Errors
/// - `IoError`: host body read, decoding, cancellation, or stream
///   failures.
@stable(since = "1.0")
pub async func HttpResponse.bodyText(response: in HttpResponse): Result[String, IOError] {
  val result = await HostHttp.hostReadBodyTextSafe(response.handle)
  match result {
    case Err(message) -> return Err(error = IoError(path = response.url, message = message))
    case Ok(text) -> return Ok(value = text)
  }
}

/// Read the response body as bytes.
///
/// # Errors
/// - `IoError`: host body read, cancellation, or stream failures.
@stable(since = "1.0")
pub async func HttpResponse.bodyBytes(response: in HttpResponse): Result[slice[Byte], IOError] {
  val result = await HostHttp.hostReadBodyBytesSafe(response.handle)
  match result {
    case Err(message) -> return Err(error = IoError(path = response.url, message = message))
    case Ok(bytes) -> return Ok(value = bytes)
  }
}

// ---------------------------------------------------------------------------
// Higher-level helpers.
// ---------------------------------------------------------------------------
/// Retry a request up to maxAttempts times, with optional delay between
/// attempts.  Passing `backoffMs = 0` retries immediately.  Returns the
/// first successful response, or the last error if all attempts fail.
@stable(since = "1.0")
pub async func retry(request: in HttpRequest, maxAttempts: in Int, backoffMs: in Long): Result[HttpResponse, HttpError]
  requires: maxAttempts > 0
  requires: backoffMs >= 0
{
  var attempts: Int = 0
  var last: Result[HttpResponse, HttpError] = Err(
    error = ConnectionFailed(url = request.url, message = "not attempted")
  )
  while attempts < maxAttempts {
    last = await sendAsync(request)
    match last {
      case Ok(response) -> return Ok(value = response)
      case Err(e) -> ()
    }
    attempts += 1
  }
  return last
}

// ---------------------------------------------------------------------------
// Phase C cancellation / timeout / redirect (D-progress-070).
// ---------------------------------------------------------------------------
/// Send a request with explicit cancellation.  Pass a token from
/// `Std.Task.makeCancelSource()` (or a structured-concurrency
/// `Std.Task.Scope`) so the host honours cancellation requests
/// while the request is in flight.
///
/// # Errors
/// - `ConnectionFailed`: classified for cancellations as well as
///   transport failures (the message includes "cancelled" when
///   the token signalled).
@stable(since = "1.0")
pub async func sendWithCancelAsync(
  request: in HttpRequest, token: in CancellationToken
): Result[HttpResponse, HttpError] {
  val result = await HostHttp.hostSendWithCancelSafe(HostHttp.hostDefaultClient(), request.handle, token)
  match result {
    case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
    case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
  }
}

/// Send a request with a timeout in milliseconds.  An auto-cancelling
/// `CancellationTokenSource` fires after `timeoutMs`; the request is
/// cancelled, surfacing as `ConnectionFailed` with a "cancelled"
/// message.  The source is disposed when the call returns.
@stable(since = "1.0")
pub async func sendWithTimeoutAsync(request: in HttpRequest, timeoutMs: in Int): Result[HttpResponse, HttpError]
  requires: timeoutMs > 0
{
  val src = makeCancelSourceTimeout(timeoutMs)
  val tok = sourceToken(src)
  defer {
    disposeSource(src)
  }
  val result = await HostHttp.hostSendWithCancelSafe(HostHttp.hostDefaultClient(), request.handle, tok)
  match result {
    case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
    case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
  }
}

/// GET a URL with explicit cancellation.
@stable(since = "1.0")
pub async func getWithCancelAsync(url: in String, token: in CancellationToken): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostGetWithCancelSafe(HostHttp.hostDefaultClient(), parsed.value, token)
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

/// GET a URL with a timeout.  Same shape as `sendWithTimeoutAsync`.
@stable(since = "1.0")
pub async func getWithTimeoutAsync(url: in String, timeoutMs: in Int): Result[HttpResponse, HttpError]
  requires: timeoutMs > 0
{
  val src = makeCancelSourceTimeout(timeoutMs)
  val tok = sourceToken(src)
  defer {
    disposeSource(src)
  }
  return await getWithCancelAsync(url, tok)
}

/// POST a UTF-8 text body to a URL with explicit cancellation.
@stable(since = "1.0")
pub async func postWithCancelAsync(
  url: in String, body: in String, token: in CancellationToken
): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostPostStringWithCancelSafe(HostHttp.hostDefaultClient(), parsed.value, body, "text/plain", token)
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

/// POST a UTF-8 text body to a URL with a timeout.
@stable(since = "1.0")
pub async func postWithTimeoutAsync(url: in String, body: in String, timeoutMs: in Int): Result[HttpResponse, HttpError]
  requires: timeoutMs > 0
{
  val src = makeCancelSourceTimeout(timeoutMs)
  val tok = sourceToken(src)
  defer {
    disposeSource(src)
  }
  return await postWithCancelAsync(url, body, tok)
}

/// Read the response body as text, honouring cancellation.  Same
/// `IoError` discipline as `bodyText`.
@stable(since = "1.0")
pub async func HttpResponse.bodyTextWithCancel(
  response: in HttpResponse, token: in CancellationToken
): Result[String, IOError] {
  val result = await HostHttp.hostReadBodyTextWithCancelSafe(response.handle, token)
  match result {
    case Err(message) -> return Err(error = IoError(path = response.url, message = message))
    case Ok(text) -> return Ok(value = text)
  }
}

/// Look up a single response header by name.  Returns `None` when
/// the header isn't present.  Both response-level and content-level
/// header collections are consulted.
@stable(since = "1.0")
pub func HttpResponse.header(response: in HttpResponse, name: in String): Option[String] {
  val v = HostHttp.hostResponseHeader(response.handle, name)
  if v.length == 0 {
    None
  } else {
    Some(value = v)
  }
}

/// The HTTP protocol version this response was actually negotiated over
/// (docs/61 §5.1). A plaintext (`http://`) response is always `Http11` —
/// h2 only upgrades via ALPN, which requires TLS — regardless of the
/// requesting client's `HttpVersion` default or pin.
@stable(since = "1.2")
pub func HttpResponse.negotiatedVersion(response: in HttpResponse): HttpVersion {
  val major = HostHttp.hostResponseVersionMajor(response.handle)
  match major {
    case 1 -> Http11
    case 2 -> Http2
    case 3 -> Http3
    case _ -> panic("Std.Http: unexpected negotiated HTTP major version " + toString(major))
  }
}

// ---------------------------------------------------------------------------
// HttpClient factory convenience functions.
//
// These wrap HttpClientBuilder for the common single-option cases.
// For composite configuration, use HttpClientBuilder directly.
// ---------------------------------------------------------------------------
/// Return the process-wide default HttpClient (TCP, follows redirects).
///
/// Prefer this over constructing a new client per request.  The singleton
/// handle avoids TCP socket-pool exhaustion from repeated construction.
@stable(since = "1.1")
pub func defaultClient(): HttpClient {
  HttpClientImpl(handle = HostHttp.hostDefaultClient(), unsupportedReason = None)
}

/// Construct an `HttpClient` that follows up to `maxRedirects`
/// redirects automatically.
@stable(since = "1.0")
pub func clientWithRedirects(maxRedirects: in Int): HttpClient
  requires: maxRedirects >= 0
{
  HttpClientImpl(handle = HostHttp.hostClientWithRedirects(maxRedirects), unsupportedReason = None)
}

/// Construct an `HttpClient` that does NOT follow redirects.
/// Useful for callers that want to inspect 3xx responses
/// themselves (e.g. capturing the `Location` header via
/// `HttpResponse.header(...)`).
@stable(since = "1.0")
pub func clientNoRedirects(): HttpClient {
  HttpClientImpl(handle = HostHttp.hostClientNoRedirects(), unsupportedReason = None)
}

// ---------------------------------------------------------------------------
// Unix domain socket support for local protocol access (Docker, systemd, etc).
// ---------------------------------------------------------------------------
/// Construct an `HttpClient` connected to a Unix domain socket.
///
/// Unix domain sockets are used for local inter-process communication on
/// Unix-like systems (Linux, macOS). Common applications include Docker
/// (at `/var/run/docker.sock`), systemd, and dbus.
///
/// # Preconditions as data
/// - `socketPath` must be a valid path to an accessible Unix socket.
///
/// Connection failures are represented as `ConnectionFailed` by `send`.
@stable(since = "1.1")
pub func clientWithUnixSocket(socketPath: in String): HttpClient
  requires: socketPath.length > 0
{
  HttpClientImpl(handle = HostHttp.hostClientWithUnixSocket(socketPath), unsupportedReason = None)
}

/// Construct an `HttpClient` connected to a Unix domain socket with redirect following.
///
/// # Preconditions as data
/// - `socketPath` must be a valid path to an accessible Unix socket.
/// - `maxRedirects` must be non-negative.
@stable(since = "1.1")
pub func clientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClient
  requires: socketPath.length > 0
  requires: maxRedirects >= 0
{
  HttpClientImpl(
    handle = HostHttp.hostClientWithUnixSocketAndRedirects(socketPath, maxRedirects),
    unsupportedReason = None
  )
}

/// Construct an `HttpClient` connected to a Unix domain socket without redirect following.
///
/// Useful when the caller wants to inspect 3xx responses directly.
///
/// # Preconditions as data
/// - `socketPath` must be a valid path to an accessible Unix socket.
@stable(since = "1.1")
pub func clientWithUnixSocketNoRedirects(socketPath: in String): HttpClient
  requires: socketPath.length > 0
{
  HttpClientImpl(handle = HostHttp.hostClientWithUnixSocketNoRedirects(socketPath), unsupportedReason = None)
}

// Future: scoped HttpClient (per-Scope cancellation flow) needs the
// AsyncLocal<T> propagation from D-progress-059's Phase 4 follow-up;
// today users thread tokens explicitly via `sendWithCancelAsync`.
