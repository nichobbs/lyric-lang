# D799 - Client TLS with ALPN in `Std.TcpHost` on every target, `TlsClientTrust` in `Std.Tls`, and a portable deadline-bounded read (docs/72 slice 4, with 4b)

**Status:** accepted. Implements slice 4 of `docs/72-h2-client-role-plan.md` (§3.1 to §3.4, §3.7; resolves OQ-3 and OQ-8). Extends D611 (`Std.TcpHost` on the JVM), D605 (the bounded operations on native) and docs/61 §3 and §4. The dual-key insecure policy itself (docs/61 §4) is unchanged and stays with `Std.Http`.

## Decision

1. **One surface on dotnet, the JVM and native.** `Std.TcpHost` exports, with the same signatures on all three targets:
   - `hostConnectTls(host, port, trust, clientIdentity, minVersion, alpnCsv, connectTimeoutMs): Result[Conn, TcpError]`
   - `hostUpgradeClientTls(conn, sniHost, trust, clientIdentity, minVersion, alpnCsv): Result[Conn, TcpError]`
   - `hostReadDeadline(conn, maxBytes, deadlineNanos): Result[slice[Byte], ReadDeadlineError]`, with `ReadDeadlineError = ReadDeadlinePassed | ReadFailed(error: TcpError)` and `ReadDeadlineError.message`.

   `hostConnectTls` is `hostConnect` (with its connect timeout, `0` = the operating system's) followed by `hostUpgradeClientTls` with `sniHost = host`. Native already had both functions (N9.4, #6105); it gained the trailing `connectTimeoutMs` (native's `hostConnectTls` dialled with no timeout) and every caller was updated. `hostAlpn(result)` is the protocol the peer selected among those offered, `""` when none.

2. **`TlsClientTrust` moved to `Std.Tls` (OQ-8).** The union (`TlsTrustSystemDefault`, `TlsTrustAdditive(caPem)`, `TlsTrustExclusive(caPem)`, `TlsTrustInsecure`) was declared only in the native kernel; it now lives in `std/tls.l` next to `Identity` and `TlsServerConfig`, with the same cases, so a driver written once names one type. The CA precedence policy (docs/61 §3.2: exclusive over additive over none) and the dual-key insecure policy (docs/61 §4) are resolved by the caller before the union is built; no kernel reads `LYRIC_TLS_ALLOW_INSECURE`, as native never did. A trust PEM that does not parse (checked with `Certificate.fromPem`, the same on every target) is `Err(TlsConfigInvalid)` and the plain socket is closed; native used to report it as a handshake failure from the C seam.

3. **ALPN offer list.** `alpnCsv` is split on commas, each name trimmed, empty names dropped, most preferred first; `""` offers nothing. The same normalisation runs on all three targets (native passed the text to C unchanged before).

4. **Failure contract.** A refused connect is `Err(TransportFailed)`; a failed handshake (untrusted or expired certificate, hostname mismatch, rejected client identity, no ALPN overlap) is `Err(TlsHandshakeFailed)`; the underlying socket is closed on every failure path of `hostUpgradeClientTls`. A socket timeout set with `hostSetIoTimeout` before the upgrade bounds each socket operation of the handshake.

5. **dotnet** (`_kernel/tcp_host.l`): `SslStream.AuthenticateAsClient(SslClientAuthenticationOptions)`, `TargetHost = sniHost`, `ApplicationProtocols` from the offer list, `EnabledSslProtocols = Tls13` only for a TLS 1.3 floor (the platform default already means 1.2 or newer), the identity as `ClientCertificates`. Trust is callback-free, because `RemoteCertificateValidationCallback` is a delegate the FFI bridge cannot build (#5947):
   - system default: no chain policy;
   - exclusive: `CertificateChainPolicy` with `TrustMode = CustomRootTrust` over the given CA only, `RevocationMode = NoCheck` (the server mTLS policy);
   - additive: the same, with the platform's trusted roots (`X509Store("Root", LocalMachine)`) added to the custom store, because the runtime rejects a custom store in `System` trust mode ("Custom trust certificates were provided while in System trust mode");
   - insecure: an empty `CustomRootTrust` policy with `VerificationFlags = AllFlags`. This is a true no-verification mode: an unknown CA, an expired certificate and a certificate for another name are all accepted (tested). Hostname verification stays on under every other policy (tested: a certificate that chains to the pinned CA but names `other.example` is refused).

   **OQ-3 is therefore resolved without a `TlsConfigInvalid` fallback**: the insecure decision is executable on dotnet through the chain policy, no delegate involved. #5947 still blocks the same option for `Std.Http`'s Unix-socket client and is not closed by this.

6. **JVM** (`_kernel_jvm/tcp_host.l`): an `SSLSocket` layered over the connected socket with `SSLSocketFactory.createSocket(plain, sniHost, port, true)` (so `sniHost` is both the SNI name and the name checked), `SSLParameters.setApplicationProtocols` through `java.lang.reflect` (a Lyric `slice[String]` erases to `Object[]`), `startHandshake()`, `getApplicationProtocol()` into `Conn.alpn`. **Hostname verification is explicit**: a raw `SSLSocket` verifies no name by default, so `clientSslParameters` sets the endpoint identification algorithm to `HTTPS` on every trust decision except `TlsTrustInsecure`, which clears it; `tcp_host_tls_tests.l` proves a chain-valid certificate for another name is refused, and a mutation run (the parameter forced off) makes exactly that test fail.

   The client `SSLContext` (trust stores, the all-trusting `X509TrustManager` built with `java.lang.reflect.Proxy`, the identity `KeyManagerFactory`, protocol floor) moved from `_kernel_jvm/http_host.l` into a new `_kernel_jvm/tls_client_context.l` (`Std.TlsClientContext`, the client twin of `Std.TlsServerContext`), and `Std.HttpHost`'s `hostClientWithTls` calls it, so there is one site that decides what a JVM client trusts. No behaviour of `Std.Http` changed (`http_tls_client_tests.l` and `http_tests.l` unchanged and green).

7. **`hostReadDeadline` (4b).** `deadlineNanos` is an absolute point on the `Std.Time.monotonicNanos()` clock, `0i64` meaning none (exactly `hostRead`). On `ReadDeadlinePassed` **nothing was consumed and the connection, plain or TLS, stays usable for further reads and writes** (tested on a plain and a TLS connection on every target: pass the deadline, then receive the data sent afterwards, nothing lost); that is what lets a driver poll with a short deadline to notice a per-call deadline or a close request. An already-passed deadline still lets the read collect bytes that have arrived, as native's `hostReadBounded` does. dotnet sets `ReceiveTimeout` to the remaining milliseconds (at least 1) and maps the platform's timeout exception; the JVM does the same with `SO_TIMEOUT`; both restore the `hostSetIoTimeout` value afterwards. Native wraps `hostReadBounded(c, n, deadline, -1)`; a wake pipe (`BoundInterrupted`) has no portable form, so `hostReadDeadline` is deliberately the subset of the native function that every target can offer. A close from another thread interrupts a blocked read on every target through `hostShutdown`, as before.

## Not changed

- `Std.Http`'s clients (`HttpClient`, `java.net.http`, native's hand-rolled client) keep their own TLS paths; they gained nothing and lost nothing. The dual-key policy is still resolved in `Std.Http`.
- No keepalive, pooling or driver: those are slices 5 and 6.
