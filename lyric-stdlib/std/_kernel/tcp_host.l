//! std/_kernel/tcp_host.l - dotnet TCP + server-side TLS transport kernel
//! for the sans-IO `Std.HttpEngine` (docs/61-https-tls-http-versions.md
//! §6.1/§6.3, D128; phase 3.1 of epic #5874, issue #5882).
//!
//! This is the audited extern boundary for the .NET server transport. It
//! provides exactly the two layers docs/61 §6.1's transport-kernel table
//! calls for on `--target dotnet`:
//!
//!   * **Accept + bytes** — `System.Net.Sockets.TcpListener` /
//!     `TcpClient` / `NetworkStream`: bind a listener, accept a
//!     connection, and read/write raw byte slices. Every operation returns
//!     `Result[_, TcpError]` (a broken pipe, a reset connection, or a
//!     handshake failure are data, not exceptions) — the same error
//!     discipline `_kernel/http_host.l`'s `*Safe` wrappers already
//!     establish for the client stack.
//!   * **TLS termination** — `System.Net.Security.SslStream` server-auth
//!     from a `Std.Tls.TlsServerConfig`: the server certificate/key
//!     (`identity`), the ALPN protocol list (`http/1.1` now; `h2` arrives
//!     with the engine's h2 stack in phase 4, docs/61 §6.4), the minimum
//!     protocol version, and mutual-TLS (`requireClientCert` +
//!     `clientCa`). The handshake, record layer, and crypto stay entirely
//!     inside the platform library — this is emphatically NOT the
//!     "hand-roll TLS" item docs/23 rejected (docs/61 §6.1); Lyric owns
//!     only the plaintext byte streams on either side of `SslStream`.
//!
//! The kernel is deliberately sans-router and sans-engine: it moves bytes,
//! nothing more. A driver (the server-assembly layer landing in issue
//! #5884) pumps `hostRead` output into `Std.HttpEngine.feed` and writes the
//! engine's serialized responses back out via `hostWrite`, selecting the
//! engine's connection FSM on the negotiated ALPN protocol `hostAlpn`
//! reports. That split is exactly what makes the protocol logic
//! target-independent (docs/61 decision 6/8).
//!
//! ## mTLS without a validation callback (real BCL/FFI constraint)
//!
//! `SslServerAuthenticationOptions.RemoteCertificateValidationCallback` is
//! the custom delegate type `System.Net.Security.
//! RemoteCertificateValidationCallback`, which the Lyric delegate-bridge FFI
//! (D122/docs/50) cannot construct — it only builds `System.Func`/
//! `System.Action` (the exact gap `_kernel/http_host.l`'s TLS-client
//! section documents for the client-side callback, #5947). So mTLS here is
//! wired through the callback-free path .NET 7+ added for precisely this
//! case: `ClientCertificateRequired = true` plus a
//! `CertificateChainPolicy` whose `TrustMode = CustomRootTrust` and whose
//! `CustomTrustStore` holds the configured `clientCa`. `SslStream` then
//! validates the presented client certificate against that policy during
//! the handshake and throws — surfaced here as
//! `TcpError.TlsHandshakeFailed` — when the client presents no certificate
//! (with `requireClientCert`) or one that does not chain to `clientCa`.
//! No delegate is ever needed, so no blocked FFI shape is on this path.
//! `RevocationMode = NoCheck` matches the client kernel's own default
//! (#5952): configuring mTLS must not silently start an online OCSP/CRL
//! probe against the client's CA.
//!
//! `Certificate`/`Identity` are opaque `Std.Tls` types; this file reaches
//! their underlying `Std.TlsHost.CertHandle` (= `X509Certificate2` on this
//! target) only through the `internal` `rawHandle()` accessors `Std.Tls`
//! itself provides (docs/01-language-reference.md §3.1) — the opaque
//! representation is never cracked from outside its own package, exactly as
//! the client-side `_kernel/http_host.l` does.
@axiom("System.Net.Sockets and System.Net.Security operations conform to their documented .NET contracts")
package Std.TcpHost

import Std.Core
import Std.Tls as Tls
import Std.TlsHost as TlsHost

// =====================================================================
// Extern types.
// =====================================================================
extern type TcpListener = "System.Net.Sockets.TcpListener"

extern type TcpClient = "System.Net.Sockets.TcpClient"

extern type NetworkStream = "System.Net.Sockets.NetworkStream"

extern type Stream = "System.IO.Stream"

extern type IPAddress = "System.Net.IPAddress"

extern type MemStream = "System.IO.MemoryStream"

extern type SslStream = "System.Net.Security.SslStream"

extern type SslServerAuthOptions = "System.Net.Security.SslServerAuthenticationOptions"

extern type SslApplicationProtocol = "System.Net.Security.SslApplicationProtocol"

extern type SslProtocols = "System.Security.Authentication.SslProtocols"

extern type X509ChainPolicy = "System.Security.Cryptography.X509Certificates.X509ChainPolicy"

extern type X509Certificate2Collection = "System.Security.Cryptography.X509Certificates.X509Certificate2Collection"

extern type X509ChainTrustMode = "System.Security.Cryptography.X509Certificates.X509ChainTrustMode"

extern type X509RevocationMode = "System.Security.Cryptography.X509Certificates.X509RevocationMode"

// =====================================================================
// Public error + connection types.
// =====================================================================
/// Every way a transport operation can fail. Bind, accept, TLS handshake,
/// and read/write failures are surfaced as data (docs/61 §6.1's
/// Result-based discipline), never as an uncaught host exception.
pub union TcpError {
  case BindFailed(message: String)
  case AcceptFailed(message: String)
  case TlsHandshakeFailed(message: String)
  case TransportFailed(message: String)
  // A rejected server-TLS configuration detected before any socket work —
  // e.g. mutual TLS requested (`requireClientCert`) with no `clientCa` to
  // pin trust to (#6042). Kept distinct from `TlsHandshakeFailed` so a
  // misconfiguration is never confused with a legitimately-rejected peer.
  case TlsConfigInvalid(message: String)
}

/// Human-readable message for a TcpError.
@pure
pub func TcpError.message(e: in TcpError): String {
  match e {
    case BindFailed(m) -> "bind failed: " + m
    case AcceptFailed(m) -> "accept failed: " + m
    case TlsHandshakeFailed(m) -> "TLS handshake failed: " + m
    case TransportFailed(m) -> "I/O error: " + m
    case TlsConfigInvalid(m) -> "TLS configuration invalid: " + m
  }
}

/// A bound, listening TCP socket.
pub opaque type Listener {
  handle: TcpListener
}

/// One accepted connection. `stream` is the readable/writable byte stream
/// (a `NetworkStream` for a plain connection, an authenticated `SslStream`
/// for a TLS one); `client` owns the underlying socket for teardown;
/// `alpn` is the negotiated ALPN protocol (`""` for a plain connection, or
/// a TLS connection where the peer offered no ALPN).
pub opaque type Conn {
  client: TcpClient
  stream: Stream
  alpn: String
}

// =====================================================================
// Primitive externs.
// =====================================================================
@externTarget("System.Net.IPAddress.Parse")
func ipParse(host: in String): IPAddress = ()

@externTarget("System.Net.Sockets.TcpListener..ctor")
func newTcpListener(addr: in IPAddress, port: in Int): TcpListener = ()

// `new TcpClient(host, port)` dials synchronously (name resolution + connect)
// as a side effect of construction — the client-side counterpart to the
// listener path.
@externTarget("System.Net.Sockets.TcpClient..ctor")
func newTcpClientConnected(host: in String, port: in Int): TcpClient = ()

@externInstance
@externTarget("System.Net.Sockets.TcpListener.Start")
func listenerStart(l: in TcpListener): Unit = ()

@externInstance
@externTarget("System.Net.Sockets.TcpListener.Stop")
func listenerStop(l: in TcpListener): Unit = ()

@externInstance
@externTarget("System.Net.Sockets.TcpListener.AcceptTcpClient")
func listenerAccept(l: in TcpListener): TcpClient = ()

// `TcpClient.GetStream()` returns a `NetworkStream`; the wrapper's declared
// return type is the base `Stream` so a plain connection's byte stream and a
// TLS connection's `SslStream` share the one `Conn.stream` field.
@externInstance
@externTarget("System.Net.Sockets.TcpClient.GetStream")
func clientStream(c: in TcpClient): Stream = ()

@externInstance
@externTarget("System.Net.Sockets.TcpClient.Close")
func clientClose(c: in TcpClient): Unit = ()

@externInstance
@externTarget("System.IO.Stream.Read")
func streamReadInto(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Int = ()

@externInstance
@externTarget("System.IO.Stream.Write")
func streamWriteFrom(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Unit = ()

@externInstance
@externTarget("System.IO.Stream.Flush")
func streamFlush(s: in Stream): Unit = ()

// `SslStream`/`NetworkStream` both inherit `Stream.Dispose()`; disposing the
// `SslStream` releases its own state and — because it was constructed with
// `leaveInnerStreamOpen = false` — the wrapped `NetworkStream` too.
@externInstance
@externTarget("System.IO.Stream.Dispose")
func streamDispose(s: in Stream): Unit = ()

// A fresh, zero-filled read buffer of exactly `n` bytes. `MemoryStream(int
// capacity)` allocates an internal `new byte[capacity]` and marks it
// publicly visible, so `GetBuffer()` hands back a genuine `byte[]` of length
// `n` — there is no `new byte[n]` FFI form to call directly, and this is the
// same MemoryStream-as-scratch idiom `_kernel/process_capture_host.l` and
// `lyric-proto` already use for byte accumulation.
@externTarget("System.IO.MemoryStream..ctor")
func newMemStreamCap(capacity: in Int): MemStream = ()

@externInstance
@externTarget("System.IO.MemoryStream.GetBuffer")
func memGetBuffer(m: in MemStream): slice[Byte] = ()

func allocBuffer(n: in Int): slice[Byte] {
  memGetBuffer(newMemStreamCap(n))
}

// --- TLS server externs ---------------------------------------------------
// The ctor's declared return type is the base `Stream` (not `SslStream`),
// so an authenticated TLS connection's byte stream and a plain
// connection's `NetworkStream` share `Conn.stream`. The runtime object is a
// genuine `SslStream`; the `SslStream`-specific members below reach it by
// `@externTarget` name (the receiver's Lyric type is only used for overload
// scoring, so a base-typed receiver still emits the exact `SslStream`
// member call) — every read/write/flush after the handshake is an ordinary
// base-`Stream` operation.
@externTarget("System.Net.Security.SslStream..ctor")
func newServerSslStream(inner: in Stream, leaveInnerStreamOpen: in Bool): Stream = ()

@externTarget("System.Net.Security.SslServerAuthenticationOptions..ctor")
func newServerOptions(): SslServerAuthOptions = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_ServerCertificate")
func optionsSetServerCertificate(o: in SslServerAuthOptions, cert: in TlsHost.CertHandle): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_ClientCertificateRequired")
func optionsSetClientCertificateRequired(o: in SslServerAuthOptions, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_EnabledSslProtocols")
func optionsSetEnabledSslProtocols(o: in SslServerAuthOptions, p: in SslProtocols): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_CertificateChainPolicy")
func optionsSetChainPolicy(o: in SslServerAuthOptions, p: in X509ChainPolicy): Unit = ()

// `SslProtocols.Tls13` — the only version this kernel ever pins explicitly.
// The `Tls12` floor (and the unset case) leave `EnabledSslProtocols` at its
// default (`None`, "let the platform decide"), which already means "TLS 1.2
// or newer" on .NET 10 — the same reasoning `_kernel/http_host.l`'s
// `sslProtocolsTls13` documents (there is no callable bitwise-OR to combine
// `Tls12 | Tls13`, and pinning `Tls12` alone would wrongly exclude 1.3).
@externTarget("System.Security.Authentication.SslProtocols.Tls13")
func sslProtocolsTls13(): SslProtocols = ()

// ALPN protocol list is set through reflection, not a direct
// `options.ApplicationProtocols = list` assignment or an
// `@externTarget("set_ApplicationProtocols")` wrapper. The property type is
// `List<SslApplicationProtocol>` — a generic instantiation over an extern
// *value type* — and the self-hosted MSIL emitter cannot encode that generic
// argument in a MemberRef signature: the `@externTarget` hint path degrades
// the setter's parameter to `System.Object` (so the emitted MemberRef binds
// no real method → `MissingMethodException` at run time), and the auto-FFI
// property-assignment path panics the emitter outright
// (`panicExternSetterUnresolved`: "has a getter but no accessible setter",
// because the generic-typed setter never resolves from reference metadata).
// Filed as #6029. The reflection bridge below builds the
// genuine `List<SslApplicationProtocol>` and assigns it entirely through
// non-generic reflection APIs (`Type`/`Activator`/`IList`/`PropertyInfo`) —
// the same "reach the capability through a non-generic seam" tactic
// `_kernel/http_host.l` uses (its non-generic `IEnumerator` header walk) and
// the JVM server test's reflection helpers use. Remove once the emitter can
// encode a generic-`List<ExternValueType>` member signature.
extern type NetObject = "System.Object"

extern type NetType = "System.Type"

extern type NetActivator = "System.Activator"

extern type IList = "System.Collections.IList"

extern type PropertyInfo = "System.Reflection.PropertyInfo"

// `NetFieldInfo`, not `FieldInfo`: the self-hosted MSIL codegen registers
// every `extern type` alias in one bundle-global, package-unscoped name table
// that is consulted before the package-scoped type resolver, so a bare alias
// named `FieldInfo` here would hijack the compiler's own
// `Jvm.Classfile.FieldInfo` Lyric record (in `lyric-compiler/jvm/classfile.l`)
// during the shared stage-1 build — its `.name` field access then mis-resolves
// to `System.Reflection.FieldInfo.get_name` and hard-crashes codegen (#6041,
// the underlying `externTypeNames` scoping defect). The `Net`-prefix (matching
// `NetObject`/`NetType`/`NetActivator` above) keeps the alias collision-free;
// the CLR type it binds is unchanged.
extern type NetFieldInfo = "System.Reflection.FieldInfo"

@externStatic
@externTarget("System.Type.GetType")
func typeGetType(name: in String): NetType = ()

// `Activator.CreateInstance(Type)` returns `System.Object` at the BCL
// boundary; the runtime object here is the just-constructed
// `List<SslApplicationProtocol>`, which implements the non-generic `IList`,
// so the wrapper is declared to return `IList`. Hint-less on purpose: the
// strict `@externStatic` return-type check would reject the object->IList
// widening, while the calling convention still defaults (correctly) to
// static.
@externTarget("System.Activator.CreateInstance")
func activatorCreateIList(t: in NetType): IList = ()

// `System.Object.GetType()` on the derived receiver — the base-method-on-
// derived pattern used throughout this file.
@externInstance
@externTarget("System.Object.GetType")
func optionsRuntimeType(o: in SslServerAuthOptions): NetType = ()

@externInstance
@externTarget("System.Type.GetProperty")
func typeGetProperty(t: in NetType, name: in String): PropertyInfo = ()

@externInstance
@externTarget("System.Type.GetField")
func typeGetField(t: in NetType, name: in String): NetFieldInfo = ()

// `FieldInfo.GetValue(obj)` returns the field value already boxed to
// `object`. For a STATIC field the `obj` argument is ignored, so passing any
// non-null reference (here `opts`) works — this dodges the need for a null
// literal (which Lyric FFI has no direct form for) AND boxes the value-type
// `SslApplicationProtocol` field for free, sidestepping the
// unboxed-value-type-into-an-`object`-parameter `InvalidProgramException`
// that a direct `IList.Add(sslApplicationProtocolValue)` hits.
@externInstance
@externTarget("System.Reflection.FieldInfo.GetValue")
func fieldGetValueBoxed(f: in NetFieldInfo, ignoredForStaticField: in SslServerAuthOptions): NetObject = ()

@externInstance
@externTarget("System.Collections.IList.Add")
func ilistAddBoxed(l: in IList, item: in NetObject): Int = ()

@externInstance
@externTarget("System.Reflection.PropertyInfo.SetValue")
func propertySetValue(p: in PropertyInfo, obj: in SslServerAuthOptions, value: in IList): Unit = ()

// Assembly-qualified: `SslApplicationProtocol` lives in `System.Net.Security`,
// so a bare name resolves to null through `Type.GetType`.
val sslAppProtoTypeName: String = "System.Net.Security.SslApplicationProtocol, System.Net.Security"

val appProtoListTypeName: String = "System.Collections.Generic.List`1[[System.Net.Security.SslApplicationProtocol, System.Net.Security]]"

// Build a genuine `List<SslApplicationProtocol>` holding only `http/1.1` and
// assign it to `options.ApplicationProtocols` via reflection (see the block
// comment above for why the direct paths are unavailable). `Http11` is a
// static *field* of struct type; read it boxed through `FieldInfo.GetValue`
// so it flows into `IList.Add(object)` as a reference. Phase 4 (docs/61 §6.4)
// adds `"h2"` ahead of `http/1.1` here.
func setApplicationProtocolHttp11(opts: in SslServerAuthOptions): Unit {
  val protoType = typeGetType(sslAppProtoTypeName)
  val http11Boxed = fieldGetValueBoxed(typeGetField(protoType, "Http11"), opts)
  val list = activatorCreateIList(typeGetType(appProtoListTypeName))
  val _ = ilistAddBoxed(list, http11Boxed)
  propertySetValue(typeGetProperty(optionsRuntimeType(opts), "ApplicationProtocols"), opts, list)
}

// `Http11`/`Http2` are static *fields*, not properties, so a `get_*` target
// does not exist and a hint-less field target mis-emits the FieldRef type;
// the `SslApplicationProtocol(string)` constructor yields the identical
// value (the field is defined as exactly this) and binds cleanly. Used only
// to compare against the negotiated protocol below.
@externTarget("System.Net.Security.SslApplicationProtocol..ctor")
func sslAppProtoOf(name: in String): SslApplicationProtocol = ()

// Static `op_Equality` (not the value-type instance `Equals`): comparing the
// negotiated protocol against a known value takes both operands by value into
// a static method, which the metadata FFI binds cleanly — a value-type
// *receiver* instance call is the shape D-progress-686 flags as unsupported,
// and this deliberately avoids it.
@externStatic
@externTarget("System.Net.Security.SslApplicationProtocol.op_Equality")
func sslAppEq(a: in SslApplicationProtocol, b: in SslApplicationProtocol): Bool = ()

@externInstance
@externTarget("System.Net.Security.SslStream.get_NegotiatedApplicationProtocol")
func sslNegotiatedProtocol(s: in Stream): SslApplicationProtocol = ()

@externInstance
@externTarget("System.Net.Security.SslStream.AuthenticateAsServer")
func sslAuthenticateAsServer(s: in Stream, options: in SslServerAuthOptions): Unit = ()

// --- Chain-policy externs (mTLS, mirrors _kernel/http_host.l) --------------
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy..ctor")
func newChainPolicy(): X509ChainPolicy = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy.set_TrustMode")
func chainPolicySetTrustMode(p: in X509ChainPolicy, m: in X509ChainTrustMode): Unit = ()

@externTarget("System.Security.Cryptography.X509Certificates.X509ChainTrustMode.CustomRootTrust")
func chainTrustModeCustomRoot(): X509ChainTrustMode = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy.get_CustomTrustStore")
func chainPolicyCustomTrustStore(p: in X509ChainPolicy): X509Certificate2Collection = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Certificate2Collection.Add")
func trustStoreAdd(c: in X509Certificate2Collection, cert: in TlsHost.CertHandle): Int = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy.set_RevocationMode")
func chainPolicySetRevocationMode(p: in X509ChainPolicy, m: in X509RevocationMode): Unit = ()

@externTarget("System.Security.Cryptography.X509Certificates.X509RevocationMode.NoCheck")
func revocationModeNoCheck(): X509RevocationMode = ()

// =====================================================================
// Public API.
// =====================================================================
/// Bind a listening TCP socket to `host`:`port`. `host` is an IP literal
/// (e.g. `"127.0.0.1"` / `"0.0.0.0"` / `"::"`), not a DNS name — the
/// transport does not resolve names. A bind failure (port in use,
/// permission denied, malformed address) is `Err(BindFailed(...))`.
pub func hostListen(host: in String, port: in Int): Result[Listener, TcpError] {
  try {
    val addr = ipParse(host)
    val l = newTcpListener(addr, port)
    listenerStart(l)
    Ok(value = Listener(handle = l))
  } catch Bug as b {
    Err(error = BindFailed(message = b.message))
  }
}

/// Dial a plain (non-TLS) TCP connection to `host`:`port`. `host` may be an
/// IP literal or a DNS name (the client path resolves names, unlike
/// `hostListen`). A connect failure (refused, unreachable, unresolved) is
/// `Err(TransportFailed(...))`.
pub func hostConnect(host: in String, port: in Int): Result[Conn, TcpError] {
  try {
    val client = newTcpClientConnected(host, port)
    Ok(value = Conn(client = client, stream = clientStream(client), alpn = ""))
  } catch Bug as b {
    Err(error = TransportFailed(message = b.message))
  }
}

/// Stop listening and release the socket. Idempotent-safe: a redundant stop
/// is swallowed rather than surfaced.
pub func hostStopListener(l: in Listener): Unit {
  try {
    listenerStop(l.handle)
  } catch Bug as _ {
    ()
  }
}

/// Block until a client connects, returning a plain (non-TLS) connection.
/// `alpn` is always `""` for a plain connection.
pub func hostAccept(l: in Listener): Result[Conn, TcpError] {
  try {
    val client = listenerAccept(l.handle)
    Ok(value = Conn(client = client, stream = clientStream(client), alpn = ""))
  } catch Bug as b {
    Err(error = AcceptFailed(message = b.message))
  }
}

// Assemble the server-auth options from a `TlsServerConfig`: identity
// certificate, minimum version, the ALPN list (http/1.1 only for now), and —
// when `requireClientCert` or `clientCa` is set — the callback-free mTLS
// chain policy described in the module header.
func buildServerOptions(cfg: in Tls.TlsServerConfig): SslServerAuthOptions {
  val opts = newServerOptions()
  optionsSetServerCertificate(opts, cfg.identity.rawHandle())
  match cfg.minVersion {
    case Tls13 -> optionsSetEnabledSslProtocols(opts, sslProtocolsTls13())
    case Tls12 -> ()
  }
  setApplicationProtocolHttp11(opts)
  if cfg.requireClientCert {
    optionsSetClientCertificateRequired(opts, true)
  }
  match cfg.clientCa {
    case Some(ca) -> {
      val policy = newChainPolicy()
      chainPolicySetTrustMode(policy, chainTrustModeCustomRoot())
      chainPolicySetRevocationMode(policy, revocationModeNoCheck())
      val _ = trustStoreAdd(chainPolicyCustomTrustStore(policy), ca.rawHandle())
      optionsSetChainPolicy(opts, policy)
    }
    case None -> ()
  }
  opts
}

// The negotiated ALPN protocol as a wire string, matched against the set
// this transport can advertise. `""` means no ALPN was negotiated (the peer
// offered none). Phase 4 (docs/61 §6.4) starts advertising `"h2"` too.
func computeAlpn(ssl: in Stream): String {
  val neg = sslNegotiatedProtocol(ssl)
  if sslAppEq(neg, sslAppProtoOf("http/1.1")) {
    "http/1.1"
  } else if sslAppEq(neg, sslAppProtoOf("h2")) {
    "h2"
  } else {
    ""
  }
}

/// Block until a client connects, then terminate TLS on the connection as a
/// server using `cfg` (server certificate, minimum version, ALPN, and mTLS).
/// A handshake failure — including an mTLS client that presents no
/// certificate or one that does not chain to `cfg.clientCa` — is
/// `Err(TlsHandshakeFailed(...))`, and the underlying socket is closed
/// before returning so a rejected peer never leaks a connection.
// mTLS misconfiguration guard (#6042). With the callback-free mTLS path
// (module header), trust in a presented client certificate is pinned ONLY by
// the `CertificateChainPolicy` built from `clientCa`. If `requireClientCert`
// is set but no `clientCa` is configured, `buildServerOptions` installs no
// chain policy, so `SslStream` would validate the client certificate against
// the SYSTEM trust store — accepting ANY publicly-trusted certificate and
// defeating the purpose of private-CA mutual TLS. That is a security
// misconfiguration, not a permissive default, so it is rejected loudly here
// (before any socket work) rather than silently falling back.
func validateServerConfig(cfg: in Tls.TlsServerConfig): Option[TcpError] {
  if cfg.requireClientCert {
    match cfg.clientCa {
      case None ->
        Some(
          value = TlsConfigInvalid(
            message = "requireClientCert is set but no clientCa is configured; mutual TLS must pin trust to a client CA " +
              "(refusing to fall back to the system trust store, which would accept any publicly-trusted client certificate)"
          )
        )
      case Some(_) -> None
    }
  } else {
    None
  }
}

pub func hostAcceptTls(l: in Listener, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  match validateServerConfig(cfg) {
    case Some(e) -> Err(error = e)
    case None -> match hostAccept(l) {
      case Err(e) -> Err(error = e)
      case Ok(plain) -> hostUpgradeServerTls(plain, cfg)
    }
  }
}

/// Terminate TLS on an already-accepted plain connection (the accept/upgrade
/// split so a future driver can inspect the peer address before deciding to
/// speak TLS). Same handshake-failure discipline as `hostAcceptTls`.
pub func hostUpgradeServerTls(conn: in Conn, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  match validateServerConfig(cfg) {
    case Some(e) -> {
      // Reject the misconfiguration (#6042) and release the already-accepted
      // socket rather than upgrading it.
      clientClose(conn.client)
      return Err(error = e)
    }
    case None -> ()
  }
  val ssl = newServerSslStream(conn.stream, false)
  try {
    sslAuthenticateAsServer(ssl, buildServerOptions(cfg))
    Ok(value = Conn(client = conn.client, stream = ssl, alpn = computeAlpn(ssl)))
  } catch Bug as b {
    // Dispose the SslStream (which, via leaveInnerStreamOpen = false, also
    // disposes the wrapped NetworkStream) before closing the socket, so a
    // rejected handshake leaks neither the SslStream's own state nor the
    // socket (#6031).
    disposeQuietly(ssl)
    clientClose(conn.client)
    Err(error = TlsHandshakeFailed(message = b.message))
  }
}

// Best-effort stream dispose: a redundant/double dispose is swallowed.
func disposeQuietly(s: in Stream): Unit {
  try {
    streamDispose(s)
  } catch Bug as _ {
    ()
  }
}

/// The negotiated ALPN protocol for this connection (`"http/1.1"`, `"h2"`,
/// or `""` when none was negotiated / the connection is plain). A driver
/// selects the engine's connection FSM on this value (docs/61 §6.4).
pub func hostAlpn(c: in Conn): String {
  c.alpn
}

/// Read up to `maxBytes` bytes from the connection, blocking until at least
/// one byte arrives. Returns the bytes actually read; an empty slice means
/// the peer closed its half of the connection (EOF). A socket error is
/// `Err(TransportFailed(...))`.
pub func hostRead(c: in Conn, maxBytes: in Int): Result[slice[Byte], TcpError]
  requires: maxBytes > 0
{
  try {
    val buf = allocBuffer(maxBytes)
    val n = streamReadInto(c.stream, buf, 0, maxBytes)
    Ok(value = buf.slice(0, n))
  } catch Bug as b {
    Err(error = TransportFailed(message = b.message))
  }
}

/// Write all of `bytes` to the connection and flush. A broken pipe / reset
/// connection is `Err(TransportFailed(...))` rather than an uncaught exception.
pub func hostWrite(c: in Conn, bytes: in slice[Byte]): Result[Unit, TcpError] {
  try {
    streamWriteFrom(c.stream, bytes, 0, bytes.length)
    streamFlush(c.stream)
    Ok(value = ())
  } catch Bug as b {
    Err(error = TransportFailed(message = b.message))
  }
}

/// Close the connection, releasing the socket and (for a TLS connection) the
/// `SslStream`. Swallows a double-close.
pub func hostClose(c: in Conn): Unit {
  // Dispose the stream first (for a TLS connection this is the SslStream,
  // whose own state clientClose would otherwise leak; for a plain connection
  // it is the NetworkStream, which clientClose also disposes — the double
  // dispose is harmless), then release the socket.
  disposeQuietly(c.stream)
  try {
    clientClose(c.client)
  } catch Bug as _ {
    ()
  }
}
