# 61 — HTTPS/TLS and HTTP-version support: client, server, and all three targets

_Specced in D128. Implementation tracked under epic #5874 (one sub-issue per
PR; see §8). Extends `docs/10-stdlib-plan.md` (Std.Http surface),
`docs/44-jvm-production-readiness-plan.md` (JVM parity), and
`native/plan/05-ffi-design.md` (native kernel boundary)._

## 1. Motivation and current state

Lyric's HTTP stack today has a lopsided TLS story: the *clients* on both
managed targets speak HTTPS out of the box (both `System.Net.Http.HttpClient`
and `java.net.http.HttpClient` validate against the platform trust store by
default, and `Url.tryFrom` accepts `https://`), but expose **zero TLS
configuration** — no custom CA, no client certificates, no minimum-version
pin, no development-time escape hatch. The *servers* cannot terminate TLS at
all, and on .NET cannot ever be taught to: the managed `HttpListener` has no
TLS support off-Windows and is HTTP/1.1-only by construction.

| Surface | dotnet | jvm |
|---|---|---|
| Client TLS | Works (platform trust), no config surface | Works (default `SSLContext`), no config surface |
| Client HTTP version | **1.1 only** (`HttpClient` default; the kernel never sets `DefaultRequestVersion`) | **h2 with 1.1 fallback** (JDK default; `_kernel_jvm/http_host.l` never calls `Builder.version()`) |
| Server TLS (`Std.HttpServer`) | Shipped (phase 3.3, #5884): `startListenerTls` over the sans-IO `Std.HttpEngine` + `Std.TcpHost`/`SslStream` transport (identity + `minVersion` + ALPN `http/1.1` + callback-free mTLS); `HttpListener` retired | Shipped (phase 2.1, #5880): `HttpsServer` + `SSLContext` from `TlsServerConfig` (mTLS is #5930) |
| Server TLS (`lyric-web`) | Shipped (phase 3.4, #5885): `Web.serveTls` terminates real TLS via `Std.HttpServer.startListenerTls`, mTLS supported | Shipped (phase 2.2, #5881): Undertow `addHttpsListener` + `ENABLE_HTTP2` (mTLS is #6017) |
| Server HTTP version | 1.1 (`HttpListener` cannot do h2) | 1.1 (`com.sun.net.httpserver` cannot; Undertow can but `ENABLE_HTTP2` is not set) |
| native | No HTTP kernel exists yet | — |

HTTP/3 exists nowhere: on .NET it needs `libmsquic` plus explicit version
policy; on JDK 21 it does not exist in `java.net.http` (JEP 517 is still in
flight upstream).

The client HTTP-version row is itself a finding in the `docs/59` sense: the
two targets silently negotiate different protocol versions for identical
Lyric source. §5 fixes the divergence as part of this design.

## 2. Design decisions (summary)

These were resolved with the project owner (2026-07-16) and are codified in
D128:

1. **Client TLS configuration** lives on `HttpClientBuilder`, backed by a new
   `Std.Tls` module. **PEM is the one cert/key file format** on every target.
2. **Cert/key file paths are runtime-configurable** via `config { }` blocks
   (docs/25 + docs/29 layered precedence) at the library layer, so
   deployments can override paths with environment variables without a
   rebuild.
3. **Insecure skip-verify is dual-key**: it takes both a code opt-in and an
   environment variable to disable verification. Either alone keeps
   verification enabled (see §4 for the full matrix).
4. **Client default HTTP version becomes h2-or-lower via ALPN on both
   targets** — a deliberate .NET behavior change to match the JVM default.
5. **Server TLS config includes mTLS from v1** (require + verify client
   certificates against a configured CA).
6. **JVM server TLS ships first** on the existing stacks (`HttpsServer` for
   `Std.HttpServer`, `addHttpsListener` + `ENABLE_HTTP2` for lyric-web's
   Undertow kernel). The JVM converges onto the shared engine (below) only
   after that engine has parity and performance evidence on .NET —
   Undertow retirement is a tracked issue, not a promise.
7. **The .NET server is replaced by a pure-Lyric sans-IO HTTP protocol
   engine** plus a thin `TcpListener`/`SslStream` transport kernel (§6).
8. **HTTP/2 is TLS-only (ALPN); no h2c.** It is implemented once, in the
   sans-IO engine, and ships on the .NET server first.
9. **HTTP/3 is deferred**: a later opt-in on the .NET client (typed error
   when `libmsquic` is absent); unavailable on JVM until the JDK ships it;
   server-side h3 is not a goal.
10. **Native TLS backend is OpenSSL 3.x, dynamically linked**, behind a
    narrow `lyric_tls_*` seam in `lyric-rt` so an alternative (e.g. mbedTLS
    for static builds) can slot in later (§7).

## 3. Client TLS configuration

### 3.1 `Std.Tls` — shared certificate/key types

A new stdlib module `lyric-stdlib/std/tls.l` with kernel twins
(`_kernel/tls_host.l`, `_kernel_jvm/tls_host.l`) owns certificate and key
loading. Both the client (§3.2) and server (§6.3) configuration surfaces
consume its types, so PEM parsing exists exactly once.

```lyric
package Std.Tls

/// A parsed X.509 certificate (leaf or chain), loaded from PEM.
pub opaque type Certificate { ... }

/// A certificate plus its private key — a server or client identity.
pub opaque type Identity { ... }

/// Minimum protocol version. TLS 1.2 is the floor; there is no
/// constructor for anything older.
pub enum TlsVersion {
  case Tls12
  case Tls13
}

pub func Certificate.fromPemFile(path: in String): Result[Certificate, TlsError]
pub func Certificate.fromPem(pem: in String): Result[Certificate, TlsError]
pub func Identity.fromPemFiles(certPath: in String, keyPath: in String): Result[Identity, TlsError]
pub func Identity.fromPem(certPem: in String, keyPem: in String): Result[Identity, TlsError]
```

`TlsError` is a typed enum (`FileNotFound`, `PemMalformed`, `KeyMismatch`,
`Unsupported`) — loading failures are data, matching the stdlib's
Result-based error discipline.

**Why PEM everywhere.** .NET loads PEM natively
(`X509Certificate2.CreateFromPemFile`). On the JVM, `CertificateFactory`
accepts PEM certificates directly, and a private key needs only a
base64→DER decode (pure Lyric, `Std.Encoding` has the base64 half) into
`PKCS8EncodedKeySpec` → `KeyFactory`. No PKCS#12/JKS container juggling, no
per-target format documentation, and PEM is what ACME/Let's Encrypt and
every service mesh hand out. PKCS#12 import can be added later if a real
consumer needs it (open question Q-TLS-006).

Kernel mapping:

| Operation | dotnet | jvm |
|---|---|---|
| Cert parse | `X509Certificate2.CreateFromPem` / `CreateFromPemFile` | `CertificateFactory.getInstance("X.509")` (accepts PEM) |
| Key parse | `CreateFromPemFile(cert, key)` pairs them | pure-Lyric PEM→DER, `PKCS8EncodedKeySpec`, `KeyFactory` (RSA/EC probe) |
| Trust config | `SslClientAuthenticationOptions.RemoteCertificateValidationCallback` over a custom `X509Chain` with `CustomTrustStore` | `TrustManagerFactory` over a `KeyStore` populated with the CA certs |
| Identity config | `SslClientAuthenticationOptions.ClientCertificates` | `KeyManagerFactory` over a `KeyStore` with the key entry |

### 3.2 `HttpClientBuilder` extensions

The existing builder (`std/http.l`) already composes options
(`socketPath` / redirects) as immutable record copies; TLS options extend the
same shape:

```lyric
val client = HttpClientBuilder.new()
    .withCaCertificate(ca)            // Std.Tls.Certificate: ADDITIONAL trust root
    .withExclusiveCaCertificate(ca)   // REPLACES platform trust entirely
    .withClientIdentity(identity)     // Std.Tls.Identity: mTLS
    .withMinTlsVersion(Tls13)
    .withInsecureSkipVerify()         // dual-key, see §4
    .build()
```

- `withCaCertificate` *adds* a trust root alongside the platform store (the
  common "internal CA plus public internet" case). `withExclusiveCaCertificate`
  *replaces* the platform store (the service-mesh case). Distinct names
  rather than a boolean so the more dangerous semantics is visible at the
  call site.
- **Correction from implementation (§8 phase 1.2, #5877):** this
  paragraph originally sketched one `SocketsHttpHandler.SslOptions`
  (`SslClientAuthenticationOptions`) assembly, assuming the trust-callback
  property's delegate-valued FFI shape was identical to `ConnectCallback`'s.
  It is not: `SslClientAuthenticationOptions.RemoteCertificateValidationCallback`
  is a genuinely custom .NET delegate type, whereas `ConnectCallback` is a
  plain `Func<...>` alias in metadata — D122's delegate-bridge FFI only
  constructs `Func`/`Action` instances, so it cannot bind to the former (found
  empirically, filed as #5947). The shipped wiring instead routes through
  `System.Net.Http.HttpClientHandler`'s own `Func<...>`-typed
  `ServerCertificateCustomValidationCallback`/plain `ClientCertificates`/
  `SslProtocols` properties, which need no new FFI capability. The one
  casualty: Unix sockets (which require `SocketsHttpHandler` for
  `ConnectCallback`) combined with any TLS option is unsupported on this
  target until #5947 lands.
- On JVM they lower to `HttpClient.Builder.sslContext(...)` +
  `sslParameters(...)` built from the §3.1 kernel pieces.
- The builder's `build()` stays infallible: `Std.Tls` loading returns
  `Result` *before* the builder is involved, so all fallible work happens at
  the `Certificate`/`Identity` construction site.

### 3.3 Runtime configuration of cert paths

Per decision 2, libraries expose cert/key *paths* through `config { }`
blocks so operators can re-point them per environment without a rebuild
(docs/25 env-var precedence). The stdlib itself stays config-block-free
(config blocks are a consumer-side DI mechanism); the pattern lands in
`lyric-web` (§6.3) and is documented in the book chapter as the idiom for
any application doing outbound mTLS:

```lyric
config HttpTls {
  caCertPath: String = ""        // "" = platform trust only
  clientCertPath: String = ""
  clientKeyPath: String = ""
}
```

with `LYRIC_CONFIG_<APP>_HTTPTLS_CACERTPATH` etc. overriding at startup.

## 4. The dual-key insecure policy

Disabling certificate verification requires **both** an explicit code opt-in
and an environment variable at runtime:

| `withInsecureSkipVerify()` in code | `LYRIC_TLS_ALLOW_INSECURE=1` in env | Effect |
|---|---|---|
| no | no | Verification enabled (secure default) |
| no | yes | Verification enabled — env var alone is a **no-op** |
| yes | no | Verification enabled, plus a **one-time stderr warning** naming the missing variable |
| yes | yes | Verification disabled for this client only |

Rationale for the warn-not-error cell (owner decision, 2026-07-16): it is a
legitimate workflow to keep `withInsecureSkipVerify()` in code during
development with the env var set locally, and simply *not set* the variable
in production — the deployment becomes secure by dropping one env var, with
no code change or rebuild. Failing loudly would turn that into a production
outage; staying silent would strand a developer who forgot the variable.
The warning is emitted once per constructed client (not per request):

```
[Std.Http] warning: withInsecureSkipVerify() requested but LYRIC_TLS_ALLOW_INSECURE
is not set; TLS certificate verification remains ENABLED.
```

The env var is read at client **build** time, not per request. The same
dual-key policy governs the server's `TlsServerConfig.insecureSkipClientVerify`
(mTLS testing) and the native kernel (via the existing `Std.Environment`
native twin), so the rule is target- and direction-uniform.

`withInsecureSkipVerify` is `@stable` API but its doc comment carries the
policy matrix and a "never in production" warning. It disables *peer chain*
verification and hostname matching together; there is deliberately no
"verify chain but skip hostname" half-measure (that combination is the
classic misconfiguration prior art warns about).

## 5. HTTP versions

### 5.1 Client

New builder knob plus a default change:

```lyric
pub enum HttpVersion {
  case Http11
  case Http2      // h2-or-lower: ALPN-negotiated, falls back to 1.1
  case Http3      // reserved: typed Unsupported error until shipped
}

HttpClientBuilder.withHttpVersion(v: in HttpVersion): HttpClientBuilder
```

- **Default becomes `Http2` (h2-or-lower) on both targets.** On JVM this is
  already the JDK default; on .NET the kernel starts setting
  `DefaultRequestVersion = 2.0` + `DefaultVersionPolicy =
  RequestVersionOrLower` on every constructed client, including the
  process-wide singleton. This only upgrades when the server negotiates h2
  via ALPN (TLS) — plaintext requests stay 1.1 — so it is
  behavior-compatible for existing consumers while closing the cross-target
  divergence. The change is called out in D128 as a deliberate default
  change.
- `Http11` pins down (JVM `Builder.version(HTTP_1_1)`; .NET
  `RequestVersionExact` 1.1).
- `Http3` returns a typed error from `build()`-adjacent validation on JVM
  (JDK has no h3) and is deferred on .NET until the msquic story is settled
  (Q-TLS-002); reserving the enum case now avoids a v1.x surface break.
- `HttpResponse` gains a `negotiatedVersion(): HttpVersion` accessor
  (`response.Version` / `HttpResponse.version()`) so self-tests can assert
  negotiation and callers can log it.

### 5.2 Server

- JVM lyric-web: `UndertowOptions.ENABLE_HTTP2` is set whenever TLS is
  configured (§6.3) — h2 requires ALPN in practice, so it sequences with,
  not before, server TLS.
- `com.sun.net.httpserver` stays 1.1 (it cannot do h2); that path's h2 story
  *is* the engine convergence (decision 6).
- .NET server h2 arrives via the sans-IO engine (§6.4). `HttpListener` h2 is
  impossible, which is one of the reasons `HttpListener` goes away.
- Server h3 is out of scope for this epic.

## 6. The sans-IO server engine and per-target transports

### 6.1 Architecture

The server splits into two layers:

**Protocol engine** (pure Lyric, no externs, no I/O — package
`Std.HttpEngine`): HTTP/1.1 request parser, response serializer, connection
state machine (keep-alive, pipelining rejection, `Content-Length` and
chunked framing, header limits), and — phase 4 — the entire h2 stack (HPACK,
frame codec, stream multiplexing, flow control, ALPN-selected). The engine
consumes byte slices and emits typed events/output bytes; it never touches a
socket. Precedent: `Std.Xml`/`Std.Yaml` (pure-Lyric parsers, D065) and the
MSIL metadata reader (docs/42) — the hard logic is pure Lyric, only the OS
boundary is kernel. Being sans-IO makes it:

- **exhaustively testable** via `lyric test` with zero network — malformed
  request corpora, split-across-reads framing, header-limit attacks are all
  plain byte-slice unit tests;
- **target-independent** — the JVM convergence (decision 6) and the native
  server become transport-kernel work only;
- **concurrency-agnostic** — thread-per-connection (native), virtual threads
  (JVM), and `scope`/`spawn` structured concurrency (.NET, D119/D120) all
  drive the same engine.

**Transport kernels** (per-target, thin):

| Target | Accept + bytes | TLS |
|---|---|---|
| dotnet | `System.Net.Sockets.TcpListener` / `NetworkStream` (new `_kernel/tcp_host.l`) | `System.Net.Security.SslStream` server-auth (`X509Certificate2` from `Std.Tls`), ALPN via `SslServerAuthenticationOptions.ApplicationProtocols`, mTLS via `ClientCertificateRequired` + a `CertificateChainPolicy` (`CustomRootTrust` over `clientCa`) — the callback-free path, since `RemoteCertificateValidationCallback` is a custom delegate the FFI bridge cannot construct (#5947); see D-progress-697 |
| jvm (later, evidence-gated) | virtual-thread `ServerSocket` | `SSLServerSocket` / `SSLEngine`, `setNeedClientAuth` |
| native (phase 5) | POSIX sockets in `lyric-rt` | OpenSSL 3.x (§7) |

Using `SslStream` is emphatically **not** the "implement TLS by hand,
multi-year" item docs/23 §"TLS / cert path" rejected — the handshake,
record layer, and crypto stay in the platform library; Lyric owns only the
plaintext byte streams on either side.

### 6.2 Concurrency model (.NET)

The current `Std.HttpServer` accept loop is single-threaded and synchronous
(its own header says "bootstrap-grade"). The replacement runs a
`scope`/`spawn` structured-concurrency accept loop: one spawned task per
connection, each pumping transport bytes through its own engine instance.
This fixes the concurrency deficiency in the same stroke as TLS —
`async_spawn_self_test.l` already exercises the primitives on both targets.

### 6.3 Public surface

```lyric
// Std.Tls (shared client/server)
pub record TlsServerConfig {
  identity: Identity                    // server cert chain + key (required)
  minVersion: TlsVersion = Tls12
  clientCa: Option[Certificate] = None  // mTLS: CA to verify client certs against
  requireClientCert: Bool = false       // mTLS v1 (decision 5)
}

// Std.HttpServer — TLS twin of startListener; same 12-function surface after it
pub func startListenerTls(host: in String, port: in Int, tls: in TlsServerConfig): Result[HttpListener, TlsListenError]

// lyric-web
pub func serveTls(router: in Router, host: in String, port: in Int, tls: in Std.Tls.TlsServerConfig): Unit
```

`lyric-web` additionally ships a config template (docs/58 `pub config` +
`from`) so cert/key/client-CA paths are env-overridable per decision 2:

```lyric
pub config WebTls from {
  certPath: String
  keyPath: String
  clientCaPath: String = ""
  requireClientCert: Bool = false
}
```

Until phase 3 lands, `serveTls`/`startListenerTls` on **dotnet** return a
typed, documented `TlsListenError` error naming the tracking issue — a
loud tracked gap per the no-silent-skip rule, mirroring how the JVM kernel
rejects `https://` today (but typed, not a panic). On **JVM**,
`startListenerTls` ships for real (phase 2.1, issue #5880, §8) for a
server identity + `minVersion`; requesting mTLS
(`requireClientCert`/`clientCa`) returns the same `TlsListenError` shape
instead — the JVM twin doesn't need phase 3 to work, but mTLS there is
gated on a separate FFI capability (§8, issue #5930), not the phase-3
schedule.

### 6.4 h2 in the engine (phase 4)

TLS-only via ALPN (decision 8): the transport kernel reports the negotiated
protocol (`"h2"` or `"http/1.1"`) and the engine instantiates the matching
connection state machine. Sub-slices (each independently testable pure
Lyric): HPACK codec (RFC 7541, static+dynamic tables, Huffman); frame codec
(RFC 9113 §4); connection/stream FSM + SETTINGS/PING/GOAWAY; flow control
(connection + stream windows). No server push (deprecated in practice); no
prioritization tree (RFC 9113 deprecates RFC 7540 priorities).

The .NET client (which already speaks h2 after §5.1) is the e2e test peer
for the h2 server self-test — both directions of our own stack verify each
other, plus a `curl --http2` smoke in CI for an independent implementation.

### 6.5 JVM convergence criteria (decision 6)

The JVM moves off Undertow/`com.sun` onto the engine only when, on .NET, the
engine has: (a) the full `Std.HttpServer` + lyric-web dispatch test suites
green, (b) the h2 self-tests green, (c) a load-shaped comparison showing
throughput within a documented factor of the `HttpListener` baseline it
replaced. Tracked as its own issue at that point; not scheduled in this
epic's phases.

## 7. Native target

Native has **no HTTP kernel at all yet**, so "HTTPS on native" decomposes
into a transport kernel (sockets + TLS) feeding the same engine and client
core. Considerations codified now so phase 5 doesn't rediscover them:

1. **Backend: OpenSSL 3.x, dynamically linked** (decision 10). Ubiquitous on
   every Linux distro, system CA-store integration, ALPN, TLS 1.3, built-in
   hostname verification. The `lyric-rt` seam is a narrow set of
   `lyric_tls_*` C functions (context create/free, handshake, read/write,
   shutdown, config setters) so mbedTLS can substitute later for
   static/musl builds without touching Lyric code. Target the 3.x ABI only.
2. **Trust store discovery**: `SSL_CTX_set_default_verify_paths` plus
   honoring `SSL_CERT_FILE`/`SSL_CERT_DIR` covers Linux's per-distro bundle
   paths. macOS policy (bundled CA file vs Security.framework) is open
   (Q-TLS-001).
3. **Hostname verification and SNI are opt-in in OpenSSL** — the kernel
   hard-wires `SSL_set1_host` + SNI on every client connection; only the §4
   dual-key policy can disable it (`Std.Environment`'s native twin already
   reads env vars).
4. **Resource lifetime**: `SSL_CTX`/`SSL` are `NativePtr` resources with
   deterministic free via the ARC destructor rules (`native/plan/04`); the
   ASan-compiled `llvm_*_self_test` discipline catches leaks/double-frees.
5. **Concurrency**: blocking client calls are fine (same shape as the JVM
   lowering); the server starts thread-per-connection over the existing
   pthread kernel (callback trampolines shipped in N4), async via LLVM coro
   later. The sans-IO engine is agnostic to this.
6. **Distribution**: dynamic libssl means negotiation behavior varies with
   the host's OpenSSL minor version — documented, not fought. Static
   binaries would switch the seam to mbedTLS (out of scope here).

## 8. Phasing and PR breakdown

Each item is one PR, tracked as a sub-issue of epic #5874. Within a phase,
items marked ∥ are independent and can proceed in parallel.

**Phase 1 — client TLS + versions (both managed targets)**
1. `Std.Tls` module: types, PEM loading, kernel twins, self-tests. ∥ with 4.
2. .NET client TLS: `SslOptions` wiring, builder surface, dual-key insecure
   policy, self-test. (After 1.) _Shipped (D-progress-691, #5877):
   `HttpClientBuilder` gains `withCaCertificate`/`withExclusiveCaCertificate`/
   `withClientIdentity`/`withMinTlsVersion`/`withInsecureSkipVerify` plus a
   `tlsConfigSupported()` capability probe; `build()` stays infallible.
   **Design deviation from the issue's literal wording**: wiring routes
   through `System.Net.Http.HttpClientHandler`'s `Func<...>`-typed
   `ServerCertificateCustomValidationCallback`/`ClientCertificates`/
   `SslProtocols`, not `SocketsHttpHandler.SslOptions` as originally
   sketched — `SslClientAuthenticationOptions.RemoteCertificateValidationCallback`
   is a genuinely custom .NET delegate type, and the delegate-bridge FFI
   (Epic #1877/#3923) only constructs `Func`/`Action` instances (found
   empirically while implementing this; filed as #5947). Consequence:
   Unix sockets (which require `SocketsHttpHandler` for `ConnectCallback`)
   combined with any TLS option is not supported on this target until
   #5947 lands — a typed `ConnectionFailed` naming it, never a silent
   no-TLS-config connection. The dual-key insecure-verify policy
   (`resolveInsecureVerifyPolicy`) is `pub` (not build()-internal) so it
   doubles as the pure, directly-testable decision function and is
   reusable by future server-side TLS config. Verified end-to-end against
   a real HTTPS peer in the implementing sandbox (exclusive/additive CA
   trust, both insecure-policy cells, mTLS identity, `Tls13` pin) —
   not part of committed CI (a public-endpoint test is not CI-acceptable);
   the committed suite (`http_tls_client_tests.l`) covers the policy
   matrix, builder composition, and the per-target capability-probe
   design deterministically, with no live TLS peer needed on either
   target.
3. JVM client TLS: `SSLContext` wiring, same surface/policy, self-test.
   (After 1; ∥ with 2.) _Shipped (D-progress-693, #5878):
   `hostSupportsTlsConfig()` flips to `true`; `_kernel_jvm/http_host.l`
   assembles a `KeyStore`/`TrustManagerFactory`/`SSLContext`/`SSLParameters`
   per request instead of the .NET twin's validation-callback shape (JVM's
   `java.net.http.HttpClient` has no such callback). **Design deviations
   from the issue's literal wording**: (1) additive/exclusive CA trust is a
   MERGED/REPLACED `KeyStore` (system trust anchors read via
   `getAcceptedIssuers()`, reflectively, off the default
   `TrustManagerFactory`) rather than a fallback-order decision callback —
   the JDK's own PKIX validator does the chain check, so there is nothing
   for a `resolveTlsValidationDecision`-shaped function to drive on this
   target (it stays declared, unused, for cross-target #5950 test parity);
   (2) building the required reference-typed Java arrays
   (`TrustManager[]`, `Certificate[]`, `String[]`, `Class[]`) and passing
   a JDK-documented `null` (`KeyStore.load`/`TrustManagerFactory.init`)
   needed a `java.lang.reflect.{Method,Array}` bridge — the JVM auto-FFI
   cannot pass a Lyric `slice[T]` for reference `T` as a call argument at
   all (verified empirically; files a fresh instance of the #5931 array-
   erasure class against `TrustManagerFactory.init`/`SSLContext.init`/
   `SSLParameters.setProtocols`/`Proxy.newProxyInstance`, not just the
   `impl <ExternInterface>` case #5931 originally found); (3)
   `withInsecureSkipVerify()`'s all-trusting `X509TrustManager` cannot be
   written as `impl JX509TrustManager for Record` at all — every method
   mentions a `slice[ExternType]` and hits the same erasure gap at compile
   time ("no matching instance or inherited method") — so it is built via
   `java.lang.reflect.Proxy.newProxyInstance` + `impl JInvocationHandler
   for Record` instead (`InvocationHandler.invoke`'s only array parameter
   is genuinely `Object[]`, an exact match for `slice[JObject]`, so it
   needs none of the workarounds); (4) hostname verification cannot be
   disabled on this target through any public API — verified empirically,
   `java.net.http.HttpClient` enforces its own endpoint-identification
   check unconditionally regardless of the supplied `SSLContext`/
   `SSLParameters`, even with the all-trusting proxy trust manager
   installed and `setEndpointIdentificationAlgorithm` explicitly cleared —
   so `withInsecureSkipVerify()` on jvm disables chain trust only, which is
   STRICTER than docs/61 §4's baseline ("disables peer chain verification
   and hostname matching together"), not a gap. Verified end-to-end
   against real live TLS peers in the implementing sandbox (exclusive CA
   correctly rejects a real public-CA-signed site; additive CA correctly
   accepts one while still trusting the extra CA; the insecure path
   accepts a real self-signed peer; a real wrong-hostname peer is rejected
   on every path, insecure included) — not part of committed CI (a
   public-endpoint test is not CI-acceptable); `http_tls_client_tests.l`
   (shared with #5877) covers the policy matrix, builder composition, and
   the now-target-neutral `tlsConfigSupported()`/Unix-socket-behavioural-
   probe deterministically on both targets, with no live TLS peer needed.
4. HTTP-version knob + h2-or-lower default parity + `negotiatedVersion`
   accessor + self-tests on both targets. ∥ with 1. _Shipped
   (D-progress-690, #5879): `HttpVersion` enum + `HttpClientBuilder.withHttpVersion`
   + `HttpResponse.negotiatedVersion()`; every constructed dotnet
   `HttpClientHandle` (including the process-wide singleton) now defaults
   to h2-or-lower; `Http3` refused with a typed `ConnectionFailed` before
   any kernel call. Coverage boundary: real h2-over-TLS negotiation is not
   asserted in CI (no server TLS yet) — only "plaintext stays 1.1" is
   proven against a live listener, per-target (dotnet child-process,
   jvm in-process `scope`/`spawn`) for the same #5329 reason
   `http_roundtrip_self_test.l` already documents._

**Phase 2 — JVM server TLS**
5. `Std.HttpServer` JVM kernel: `HttpsServer` + `SSLContext` from
   `TlsServerConfig`, incl. mTLS; lift the `https://` rejection. (After 1.)
   _Shipped in phase 2.1 (issue #5880) for the non-mTLS case_:
   `startListenerTls` builds a real `HttpsServer` + `KeyManagerFactory`-backed
   `SSLContext` from `TlsServerConfig.identity`/`minVersion`, verified by a
   real TLS handshake + HTTP/1.1 round trip
   (`tls_server_jvm_tests.l`). **mTLS (`requireClientCert`/`clientCa`) did
   NOT ship**: `HttpsServer` only applies `HttpsParameters.setNeedClientAuth`
   through an application-supplied `HttpsConfigurator.configure(...)`
   override, which requires subclassing the concrete `HttpsConfigurator`
   class — Lyric's `impl <ExternInterface> for Record` only implements
   interfaces (verified empirically: attempting it throws
   `IncompatibleClassChangeError` at class-load time), a real FFI gap filed
   as issue #5930. `startListenerTls` rejects any mTLS request with a typed
   `Err(NotSupportedOnTarget(...))` rather than silently ignoring it. Two
   further FFI gaps surfaced and were worked around rather than blocking
   the whole slice: `impl <ExternInterface> for Record` methods with
   `slice[ExternType]` params/returns emit a mismatched `Object[]`
   descriptor (issue #5931), and the JVM auto-FFI cannot pass a
   reference-typed array as a call argument at all — both sidestepped via
   `KeyManagerFactory`/`java.lang.reflect` instead of a custom
   `X509KeyManager` impl (see `_kernel_jvm/http_server.l`'s module header).
   A same-package multi-file split (`_kernel_jvm/`-only file alongside
   `Std.Tls`'s top-level `tls.l`) was also tried for the `SSLContext`
   construction and found to break unrelated static-call resolution at JVM
   runtime — a fourth gap, filed as issue #5932; the construction lives in
   `_kernel_jvm/http_server.l` instead, reached through the minimal
   `Identity.hostHandle` kernel-only accessor added to `tls.l`. Mutual TLS
   remains tracked (issue #5930); dotnet server TLS shipped (#5884, D-progress-700).
6. lyric-web: Undertow `addHttpsListener` + `ENABLE_HTTP2`, `Web.serveTls`,
   `WebTls` config template, typed dotnet `Unsupported` until phase 3;
   docs + book. (After 1; ∥ with 5.) _Shipped in phase 2.2 (issue #5881,
   D-progress-698)_: `Web.serveTls(router, host, port, tls)` on `--target
   jvm` builds an Undertow HTTPS listener via
   `Undertow.Builder.addHttpsListener(port, host, sslContext)` +
   `UndertowOptions.ENABLE_HTTP2` (h2 via ALPN, TLS-only per decision 8),
   reusing the `Std.HttpServer.serverSslContextFromConfig` `SSLContext`
   builder (newly exposed alongside `startListenerTls`) rather than
   re-declaring the `KeyManagerFactory`/`KeyStore`/reflection extern
   boundary. On `--target dotnet` it returns a typed
   `ServerTlsUnsupported` naming phase 3 / issue #5885. A `WebTls` config
   block (declared as a plain `pub config` with required fields — the
   sketch's `pub config … from { }` form isn't valid parser syntax, since
   `from` is the config-derivation keyword) plus `tlsServerConfigFromWebTls`
   give env-overridable cert/key/client-CA paths (D128 decision 2).
   **mTLS did NOT ship on this path**: the reused identity-only `SSLContext`
   builder carries no client-CA `TrustManager`, and Undertow needs its XNIO
   `SSL_CLIENT_AUTH_MODE` socket option wired too — `serveTls` rejects any
   `requireClientCert`/`clientCa` request with a typed `NotSupportedOnTarget`,
   tracked in issue #6017. Verified end-to-end by
   `tests/jvm_server_smoke.l`'s in-process HTTPS/h2 self-check (a real
   Undertow TLS listener + a `Std.Http` client that trusts the fixture cert
   and asserts `HttpResponse.negotiatedVersion() == Http2`) plus a
   `curl --http2` cross-check, and by `tests/serve_tls_tests.l` on dotnet.

**Phase 3 — .NET server engine**
7. `_kernel/tcp_host.l`: `TcpListener`/`NetworkStream`/`SslStream` transport
   kernel incl. ALPN + mTLS. ∥ with 8. _Shipped in D-progress-697 (#5882): the
   dotnet `Std.TcpHost` package — `hostListen`/`hostAccept`/`hostConnect`
   (plain), `hostAcceptTls`/`hostUpgradeServerTls` (server-side `SslStream`
   termination from `TlsServerConfig`), `hostRead`/`hostWrite`/`hostClose`
   (`Result[_, TcpError]` byte primitives), and `hostAlpn` (negotiated
   protocol). ALPN advertises `http/1.1` (h2 in phase 4); mTLS is the
   callback-free `ClientCertificateRequired` + `CertificateChainPolicy`
   (`CustomRootTrust`) path — NOT the `RemoteCertificateValidationCallback`
   the §6.1 table originally sketched, which is a custom delegate the FFI
   bridge cannot construct (#5947). Verified by
   `lyric-stdlib/tests/tcp_host_tls_tests.l` (6 cases: plain echo, TLS
   handshake + ALPN + byte round trip against the real Lyric HTTPS client,
   mTLS accept, mTLS reject) in committed dotnet CI. The ALPN
   `List<SslApplicationProtocol>` property is set via a documented reflection
   bridge working around generic-`List<ExternValueType>` FFI gap #6029. Item 9
   (the `Std.HttpServer` server assembly on this kernel) shipped in
   D-progress-700 (#5884)._
8. `Std.HttpEngine` HTTP/1.1: parser, serializer, connection FSM, byte-level
   test corpus. ∥ with 7. _Shipped in D-progress-694 (#5883, PR #5999): the
   protocol engine and its exhaustive (59-case) test corpus, including
   RFC 9112 §3.2 Host-header validation and `EngineLimits.maxBodyBytes`
   enforcement added in the same PR's review round. Its transport (item 7,
   `_kernel/tcp_host.l`, D-progress-697) and server assembly (item 9,
   D-progress-700) have since shipped, so the dotnet server is usable
   end-to-end._
9. Server assembly: `scope`/`spawn` accept loop behind the existing
   `Std.HttpServer` 12-function surface + `startListenerTls`; `HttpListener`
   retired; self-tests. (After 7+8.) _Shipped in D-progress-700 (#5884): the
   dotnet `Std.HttpServer` kernel (`_kernel/http_server.l`) rebuilt on
   `Std.TcpHost` + `Std.HttpEngine`. The `System.Net.HttpListener` externs are
   gone; `HttpContext`/`HttpListener` are now Lyric records and the chunked-
   stream handle is the record `HttpChunkedStream` (was the `System.IO.Stream`
   extern). A background `Task.Run` accept loop spawns one `Task.Run`
   per-connection handler that pumps `hostRead` bytes through its own
   `Std.HttpEngine.Connection`, hands each `RequestComplete` to a
   `ConcurrentQueue`+`SemaphoreSlim` pull queue (`nextContext`), and blocks on a
   per-request `SemaphoreSlim` until the puller's `respond*`/chunked helper
   writes the response. Real OS-thread concurrency (`spawn` is degenerate-
   synchronous on dotnet, D119/D120) fixes the old single-threaded
   `HttpListener.GetContext` loop. `startListenerTls` is real on dotnet via
   `hostAcceptTls` (identity + `minVersion` + ALPN `http/1.1` + callback-free
   mTLS); the phase-2 `NotSupportedOnTarget` stub is gone and the mTLS
   misconfiguration guard returns `Err(InvalidConfig(...))`. The 12-function
   public surface is unchanged, so `lyric-web`/`examples` keep building (only
   the internal `Stream` type name updated to `HttpChunkedStream`). Concurrency
   note: `ConcurrentQueue.TryDequeue(out T)` + `SemaphoreSlim` were chosen over
   `BlockingCollection` because every member has a unique arity (no W0008
   overload ambiguity) and the `out`-parameter dequeue preserves a value-type
   record's reference-typed fields (a generic-return `Take(): T` drops them).
   Verified by `lyric-stdlib/tests/http_server_dotnet_tests.l` (plaintext GET,
   POST body, keep-alive reuse, concurrent connections, TLS + mTLS accept/reject,
   `startListenerTls` `InvalidConfig` guard) plus curl/real-client interop. Item
   10 (lyric-web onto the new server, #5885) and h2/ALPN end-to-end (#5889)
   remain._
10. lyric-web dotnet onto the new server; `serveTls` end-to-end both
    targets; docs/book/progress sync. (After 9.) _Shipped (D-progress-701,
    #5885): lyric-web's dotnet `serveTls` (`lyric-web/src/web.l`) now calls
    `Std.HttpServer.startListenerTls` and dispatches through the same pull
    loop / `dispatch` core as plaintext `serve`; the phase-2.2 typed
    `ServerTlsUnsupported`-on-dotnet stub is gone. **mTLS is fully supported
    on dotnet** (the config is passed straight through to the callback-free
    mTLS transport kernel), unlike the JVM Undertow listener (mTLS is #6017);
    a config that cannot bind (mutual-TLS misconfiguration or bind failure)
    returns a typed `ServerTlsUnsupported` carrying the underlying
    `TlsListenError` message, never a silent failure. Verified by
    `lyric-web/tests/serve_tls_tests.l` (real in-process `Web.serveTls`
    end-to-end over TLS + mTLS driven by the real Lyric HTTPS client, plus the
    `WebTls` config-template env-var override), wired into CI via `lyric test
    --manifest lyric-web/lyric.toml`; the JVM path stays covered by
    `tests/jvm_server_smoke.l`. h2/ALPN end-to-end on the dotnet server
    remains #5889._

**Phase 4 — h2 (engine, .NET first)**
11. HPACK codec + tests. ∥ with 12. _Shipped (D-progress-695, #5886):
    `Std.HttpEngine.Hpack` (`lyric-stdlib/std/http_hpack.l`) — a complete,
    pure-Lyric HPACK (RFC 7541) codec: static table (Appendix A, 61 entries),
    dynamic table with `len(name)+len(value)+32` cost accounting, FIFO
    eviction, the oversized-entry-empties-the-table rule, and
    `SETTINGS_HEADER_TABLE_SIZE`-bounded size updates; integer (§5.1) and
    string (§5.2) primitives; the full Appendix B Huffman code (encode +
    trie decode with EOS/padding conformance rejection); and all §6
    representations (indexed, the three literal forms, and size update). No
    externs, no kernel file. `http_hpack_tests.l` (39 cases) asserts the
    codec byte-for-byte against **every RFC 7541 Appendix C vector**
    (C.1–C.6, incl. the C.5/C.6 eviction sequences at table size 256) in both
    directions plus round-trip and adversarial (integer/table-size bombs,
    embedded EOS, invalid Huffman padding) cases; all pass identically on
    `--target dotnet` and `--target jvm`, wired into CI beside
    `http_engine_tests.l`. Encoder policy boundary: always-Huffman-or-never
    (deterministic, RFC-vector-reproducing); size-optimal per-literal choice
    is a tracked follow-up, not a correctness gap._
12. h2 frame codec + tests. ∥ with 11. _Shipped (D-progress-696, #5887):
    `Std.HttpEngine.H2Frame` — pure-Lyric, no-extern frame codec covering the
    9-octet header (§4.1) and all ten §6 frame types (DATA, HEADERS, PRIORITY
    parsed-but-deprecated, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY,
    WINDOW_UPDATE, CONTINUATION) + `UnknownFrame` pass-through, flags/padding,
    the §3.4 connection preface, `SETTINGS_MAX_FRAME_SIZE` (§4.2) enforcement,
    and a sans-IO streaming `FrameDecoder` with typed `FrameError` connection-
    vs stream-level signalling. 58-case byte-vector `@test_module` green on
    dotnet + jvm. HPACK (#5886) and the connection/stream FSM + flow control
    (#5888) stay out of scope — fragments are opaque `slice[Byte]`._
13. h2 connection/stream FSM + flow control + SETTINGS/GOAWAY. (After 11+12.)
    _Shipped (D-progress-699, #5888): `Std.HttpEngine.H2Conn`
    (`lyric-stdlib/std/http_h2conn.l`) — a pure-Lyric, no-extern, sans-IO
    **server-side** HTTP/2 connection/stream state machine composing the frame
    codec (#5887) and HPACK (#5886). Covers the §3.4 preface + `SETTINGS`
    handshake (auto-ACK); `SETTINGS` validation/application incl. the
    `INITIAL_WINDOW_SIZE`-change window adjustment (§6.9.2); the §5.1 per-stream
    lifecycle (idle → open → half-closed remote/local → closed) with
    illegal-transition rejection; HEADERS + CONTINUATION reassembly (§6.2/§6.10)
    feeding the HPACK decoder (incl. the §4.3 decode-a-refused-stream rule);
    connection- and per-stream flow control (§6.9) on both the receive side
    (overrun → `FLOW_CONTROL_ERROR`) and the send side (`sendData` bounded by
    the peer window; `WINDOW_UPDATE` replenish); the concurrent-streams limit
    (`REFUSED_STREAM`); `PING` auto-ACK; `GOAWAY` (received + `sendGoAway`); and
    the §5.4 connection-vs-stream error classification (`GOAWAY` vs
    `RST_STREAM`). No server push (`PUSH_PROMISE` → `PROTOCOL_ERROR`); no
    priority tree (`PRIORITY` accepted + ignored). 62-case `@test_module`
    (`http_h2conn_tests.l`) drives the FSM end to end through the real
    `H2Frame` + `Hpack` calls, green on dotnet + jvm and wired into CI beside
    the #5886/#5887 steps. Two tracked bounded characteristics filed (#6063
    padded-DATA receive-accounting, #6064 closed-stream pruning)._
14. ALPN wiring in the dotnet transport + e2e h2 self-test (own client +
    `curl --http2`). (After 13.)

**Phase 5 — native (opens when native HTTP work starts)**
15. `lyric_tls_*` OpenSSL seam in `lyric-rt` + socket transport + client;
    server thread-per-connection; banded like N-items, planned in a
    follow-on to `native/plan/` rather than fully specced here.

Every PR carries its own docs/book/progress-log sync per the working
conventions; none lands with a silent one-target gap.

## 9. Open questions

- **Q-TLS-001** — macOS native trust: bundled CA file vs Security.framework
  bridge. (Phase 5.)
- **Q-TLS-002** — .NET client HTTP/3 opt-in: msquic distribution/detection
  story and whether `Http3` means exact or 3-or-lower. (Post-phase-4.)
- **Q-TLS-003** — certificate reload/rotation for long-running servers
  (ACME renewals): v1 requires a restart; is a `reloadTls()` or
  mtime-watch surface warranted, and on which layer?
- **Q-TLS-004** — session resumption and 0-RTT policy on native (0-RTT off
  by default; is resumption cache size/TTL configurable?).
- **Q-TLS-005** — JVM engine-convergence bar: what load-test harness and
  threshold constitutes "performance evidence" for §6.5(c)?
- **Q-TLS-006** — PKCS#12 import in `Std.Tls` for Windows-centric consumers:
  needed, or does PEM-only hold?
