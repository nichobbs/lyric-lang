//! std/_kernel/tcp_host.l - dotnet TCP + TLS (server and client) transport kernel
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
//!     (`identity`), the ALPN protocol list (`h2` then `http/1.1`, docs/61
//!     §6.4 phase 4.4), the minimum
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
//!
//! ## Server-readiness surface (D621, docs/73 slice S1)
//!
//! `hostShutdown(conn)` interrupts a read or write blocked on the connection
//! from another thread without releasing it (the owner still calls
//! `hostClose`), the contract native already had. `hostRead` reuses a
//! per-connection buffer and `hostSetIoTimeout` bounds each blocking read and
//! write by `Socket.ReceiveTimeout`/`SendTimeout`. Every connection has
//! `TCP_NODELAY` set (as the JVM kernel does): a server writes a response as
//! one or two segments and must not wait out Nagle's algorithm against the
//! peer's delayed ACK. The listen backlog is
//! `TcpListener.Start()`'s default (SOMAXCONN, clamped by the operating
//! system); the JVM and native kernels pass 128.
@axiom("System.Net.Sockets and System.Net.Security operations conform to their documented .NET contracts")
@io
package Std.TcpHost

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Parse as Parse
import Std.Tls as Tls
import Std.TlsHost as TlsHost
import Std.Time as Time

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

extern type Socket = "System.Net.Sockets.Socket"

extern type EndPoint = "System.Net.EndPoint"

extern type SocketShutdownMode = "System.Net.Sockets.SocketShutdown"

extern type SslServerAuthOptions = "System.Net.Security.SslServerAuthenticationOptions"

extern type SslClientAuthOptions = "System.Net.Security.SslClientAuthenticationOptions"

extern type X509CertificateCollection = "System.Security.Cryptography.X509Certificates.X509CertificateCollection"

extern type X509Store = "System.Security.Cryptography.X509Certificates.X509Store"

extern type X509StoreLocation = "System.Security.Cryptography.X509Certificates.StoreLocation"

extern type X509OpenFlags = "System.Security.Cryptography.X509Certificates.OpenFlags"

extern type X509VerificationFlags = "System.Security.Cryptography.X509Certificates.X509VerificationFlags"

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
@experimental
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
@experimental
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
@experimental
pub opaque type Listener {
  handle: TcpListener
}

/// One accepted connection. `stream` is the readable/writable byte stream
/// (a `NetworkStream` for a plain connection, an authenticated `SslStream`
/// for a TLS one); `client` owns the underlying socket for teardown;
/// `alpn` is the negotiated ALPN protocol (`""` for a plain connection, or
/// a TLS connection where the peer offered no ALPN).
@experimental
pub opaque type Conn {
  client: TcpClient
  stream: Stream
  alpn: String
  // Reused by every `hostRead` on this connection (#7269), so a read costs one
  // allocation the size of the bytes actually received instead of a fresh
  // zeroed buffer of `maxBytes`. A connection is read from one thread at a time.
  // `Stream.Read` writes this stream's backing array in place, so the array is
  // never bound as a `slice[Byte]`: nothing may write a slice that Lyric code
  // holds (T0157, #8730). It is fetched as an extern argument, and the bytes a
  // read returns leave as a fresh slice.
  readBuf: MemStream
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

extern type ConnectTask = "System.Threading.Tasks.Task"

@externTarget("System.Net.Sockets.TcpClient..ctor")
func newTcpClientUnconnected(): TcpClient = ()

@externInstance
@externTarget("System.Net.Sockets.TcpClient.ConnectAsync")
func clientConnectAsync(c: in TcpClient, host: in String, port: in Int): ConnectTask = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func connectTaskWait(t: in ConnectTask, ms: in Int): Bool = ()

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

// Per-operation socket timeouts in milliseconds (0 = wait forever). A
// synchronous `NetworkStream` read/write, and an `SslStream` handshake or
// record read/write layered over it, fails with an `IOException` once one
// blocking socket call exceeds the timeout.
@externInstance
@externTarget("System.Net.Sockets.TcpClient.set_ReceiveTimeout")
func clientSetReceiveTimeout(c: in TcpClient, ms: in Int): Unit = ()

@externInstance
@externTarget("System.Net.Sockets.TcpClient.get_ReceiveTimeout")
func clientGetReceiveTimeout(c: in TcpClient): Int = ()

@externInstance
@externTarget("System.Net.Sockets.TcpClient.set_SendTimeout")
func clientSetSendTimeout(c: in TcpClient, ms: in Int): Unit = ()

@externInstance
@externTarget("System.Net.Sockets.TcpClient.set_NoDelay")
func clientSetNoDelay(c: in TcpClient, on: in Bool): Unit = ()

// `TcpClient.Client` (the underlying `Socket`) and `Socket.RemoteEndPoint`
// back `hostRemoteAddress` (used by `lyric-ws`'s dotnet WebSocket kernel to
// populate `onOpen`'s `remoteAddress` callback argument — docs/62 §6). The
// base-`Object.ToString()` hint on the derived `EndPoint`-typed value is the
// same pattern `chainPolicyCustomTrustStore` below uses for a
// base-method-on-derived-receiver call.
@externTarget("System.Net.Sockets.TcpClient.get_Client")
func clientSocket(c: in TcpClient): Socket = ()

@externTarget("System.Net.Sockets.Socket.get_RemoteEndPoint")
func socketRemoteEndPoint(s: in Socket): EndPoint = ()

@externTarget("System.Net.Sockets.SocketShutdown.Both")
func socketShutdownBoth(): SocketShutdownMode = ()

@externInstance
@externTarget("System.Net.Sockets.Socket.Shutdown")
func socketShutdown(s: in Socket, how: in SocketShutdownMode): Unit = ()

@externTarget("System.Object.ToString")
func endPointToString(e: in EndPoint): String = ()

@externTarget("System.Net.Sockets.TcpListener.get_LocalEndpoint")
func listenerLocalEndPoint(l: in TcpListener): EndPoint = ()

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

func allocBuffer(n: in Int): MemStream {
  newMemStreamCap(n)
}

// The per-connection read buffer size: one TLS record's maximum plaintext
// (RFC 8446 section 5.1), which is also the most an `SslStream` read returns.
val readBufferSize: Int = 16384

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
func newSslStream(inner: in Stream, leaveInnerStreamOpen: in Bool): Stream = ()

@externTarget("System.Net.Security.SslServerAuthenticationOptions..ctor")
func newServerOptions(): SslServerAuthOptions = ()

// The server identity as a prebuilt `SslStreamCertificateContext` (the
// documented way to share one certificate across many handshakes: the chain
// is built once here instead of once per connection). `offline = true`
// builds the chain from the certificate and the local stores only, never
// fetching missing intermediates over the network from inside a listener's
// startup path.
extern type SslCertContext = "System.Net.Security.SslStreamCertificateContext"

@externTarget("System.Security.Cryptography.X509Certificates.X509Certificate2Collection..ctor")
func newCertCollection(): X509Certificate2Collection = ()

@externTarget("System.Net.Security.SslStreamCertificateContext.Create")
func newCertContext(
  target: in TlsHost.CertHandle, additional: in X509Certificate2Collection, offline: in Bool
): SslCertContext = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_ServerCertificateContext")
func optionsSetServerCertificateContext(o: in SslServerAuthOptions, c: in SslCertContext): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_ClientCertificateRequired")
func optionsSetClientCertificateRequired(o: in SslServerAuthOptions, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_EnabledSslProtocols")
func optionsSetEnabledSslProtocols(o: in SslServerAuthOptions, p: in SslProtocols): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_CertificateChainPolicy")
func optionsSetChainPolicy(o: in SslServerAuthOptions, p: in X509ChainPolicy): Unit = ()

// --- TLS client externs ------------------------------------------------------
// `SslClientAuthenticationOptions` mirrors the server options above: the same
// callback-free trust path (`CertificateChainPolicy` over a `CustomRootTrust`
// store), because `RemoteCertificateValidationCallback` is a delegate type the
// FFI bridge cannot construct (#5947). `TargetHost` is both the SNI name and the
// name the peer certificate is verified against (RFC 6125): the runtime keeps
// that check on whatever chain policy is installed.
@externTarget("System.Net.Security.SslClientAuthenticationOptions..ctor")
func newClientOptions(): SslClientAuthOptions = ()

@externInstance
@externTarget("System.Net.Security.SslClientAuthenticationOptions.set_TargetHost")
func clientOptionsSetTargetHost(o: in SslClientAuthOptions, host: in String): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslClientAuthenticationOptions.set_EnabledSslProtocols")
func clientOptionsSetEnabledSslProtocols(o: in SslClientAuthOptions, p: in SslProtocols): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslClientAuthenticationOptions.set_CertificateChainPolicy")
func clientOptionsSetChainPolicy(o: in SslClientAuthOptions, p: in X509ChainPolicy): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslClientAuthenticationOptions.set_ApplicationProtocols")
func clientOptionsSetApplicationProtocols(o: in SslClientAuthOptions, protocols: in ApplicationProtocolList): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslClientAuthenticationOptions.set_ClientCertificates")
func clientOptionsSetClientCertificates(o: in SslClientAuthOptions, c: in X509CertificateCollection): Unit = ()

@externTarget("System.Security.Cryptography.X509Certificates.X509CertificateCollection..ctor")
func newClientCertCollection(): X509CertificateCollection = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509CertificateCollection.Add")
func clientCertCollectionAdd(c: in X509CertificateCollection, cert: in TlsHost.CertHandle): Int = ()

@externInstance
@externTarget("System.Net.Security.SslStream.AuthenticateAsClient")
func sslAuthenticateAsClient(s: in Stream, options: in SslClientAuthOptions): Unit = ()

// `SslProtocols.Tls13` — the only version this kernel ever pins explicitly.
// The `Tls12` floor (and the unset case) leave `EnabledSslProtocols` at its
// default (`None`, "let the platform decide"), which already means "TLS 1.2
// or newer" on .NET 10 — the same reasoning `_kernel/http_host.l`'s
// `sslProtocolsTls13` documents (there is no callable bitwise-OR to combine
// `Tls12 | Tls13`, and pinning `Tls12` alone would wrongly exclude 1.3).
@externTarget("System.Security.Authentication.SslProtocols.Tls13")
func sslProtocolsTls13(): SslProtocols = ()

// ALPN protocol list is now set through a direct `List<SslApplicationProtocol>`
// construction and the real `set_ApplicationProtocols` setter — a bracket-
// suffixed extern-type alias used as an `@externTarget` parameter type,
// exactly the shape D-progress-999 (#6029) fixed: the self-hosted MSIL
// emitter previously erased that generic instantiation to `System.Object` at
// a parameter/return position (`MissingMethodException` at run time), and the
// auto-FFI property-assignment path still panics outright
// (`panicExternSetterUnresolved`) — the `@externTarget`-wrapper form used
// here sidesteps that separately-tracked gap (#7444). This replaces the
// previous reflection bridge (`Type`/`Activator`/`IList`/`PropertyInfo`),
// removed now that the emitter encodes the generic signature directly.
extern type ApplicationProtocolList = "System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol]"

@externTarget("System.Collections.Generic.List`1..ctor")
func newApplicationProtocolList(): ApplicationProtocolList = ()

@externInstance
@externTarget("System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol].Add")
func applicationProtocolListAdd(l: in ApplicationProtocolList, item: in SslApplicationProtocol): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_ApplicationProtocols")
func optionsSetApplicationProtocols(o: in SslServerAuthOptions, protocols: in ApplicationProtocolList): Unit = ()

// Build a genuine `List<SslApplicationProtocol>` holding `h2` (first, so it is
// the server's ALPN preference) and `http/1.1`, and assign it directly to
// `options.ApplicationProtocols`. `sslAppProtoOf` (below) already constructs
// the identical value the BCL's `Http2`/`Http11` static fields hold (its own
// doc comment explains why the ctor and the field agree) and is already used
// this way for comparison in `computeAlpn` below, so reusing it here needs no
// new construction path. Advertising `h2` here is the ALPN half of docs/61
// §6.4 phase 4.4 (issue #5889): a peer that offers h2 negotiates HTTP/2 (the
// server assembly selects the h2 FSM on the `hostAlpn` result), and a peer
// that offers only `http/1.1` (or no ALPN) falls back to HTTP/1.1.
func setApplicationProtocols(opts: in SslServerAuthOptions): Unit {
  val list = newApplicationProtocolList()
  applicationProtocolListAdd(list, sslAppProtoOf("h2"))
  applicationProtocolListAdd(list, sslAppProtoOf("http/1.1"))
  optionsSetApplicationProtocols(opts, list)
}

// `Http11`/`Http2` are static *fields*, not properties, so a `get_*` target
// does not exist and a hint-less field target mis-emits the FieldRef type;
// the `SslApplicationProtocol(string)` constructor yields the identical
// value (the field is defined as exactly this) and binds cleanly. Used both
// to build the advertised ALPN list (`setApplicationProtocols` above) and to
// compare against the negotiated protocol (`computeAlpn` below).
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

// The platform's trusted roots, for an additive CA: `X509ChainPolicy` rejects a
// custom store in `System` trust mode, so additive trust is `CustomRootTrust`
// over the roots the platform would have trusted plus the extra CA.
@externTarget("System.Security.Cryptography.X509Certificates.X509Store..ctor")
func newRootStore(name: in String, location: in X509StoreLocation): X509Store = ()

@externTarget("System.Security.Cryptography.X509Certificates.StoreLocation.LocalMachine")
func storeLocationLocalMachine(): X509StoreLocation = ()

@externTarget("System.Security.Cryptography.X509Certificates.OpenFlags.ReadOnly")
func openFlagsReadOnly(): X509OpenFlags = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Store.Open")
func rootStoreOpen(s: in X509Store, flags: in X509OpenFlags): Unit = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Store.get_Certificates")
func rootStoreCertificates(s: in X509Store): X509Certificate2Collection = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Store.Close")
func rootStoreClose(s: in X509Store): Unit = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509Certificate2Collection.AddRange")
func trustStoreAddRange(c: in X509Certificate2Collection, other: in X509Certificate2Collection): Unit = ()

@externInstance
@externTarget("System.Security.Cryptography.X509Certificates.X509ChainPolicy.set_VerificationFlags")
func chainPolicySetVerificationFlags(p: in X509ChainPolicy, f: in X509VerificationFlags): Unit = ()

@externTarget("System.Security.Cryptography.X509Certificates.X509VerificationFlags.AllFlags")
func verificationFlagsAll(): X509VerificationFlags = ()

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
@experimental
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

/// The port `l` is actually bound to: lets a caller bind an ephemeral port
/// (`hostListen(host, 0)`) and read back the one the OS assigned, the same
/// accessor the native `Std.TcpHost` twin has. `0` if it cannot be read.
@experimental
pub func hostLocalPort(l: in Listener): Int {
  try {
    val text = endPointToString(listenerLocalEndPoint(l.handle))
    val colon = Str.lastIndexOfRaw(text, ":")
    if colon < 0 {
      0
    } else {
      match Parse.tryParseInt(Str.substring(text, colon + 1)) {
        case Ok(n) -> n
        case Err(_) -> 0
      }
    }
  } catch Bug as _ {
    0
  }
}

/// Dial a plain (non-TLS) TCP connection to `host`:`port`. `host` may be an
/// IP literal or a DNS name (the client path resolves names, unlike
/// `hostListen`). `connectTimeoutMs` bounds the connect, name resolution
/// included (`0` = the operating system's own limit). A connect failure
/// (refused, unreachable, unresolved, timed out) is `Err(TransportFailed(...))`.
// Dials on the Task `ConnectAsync` returns and waits for it for at most
// `timeoutMs`; a connect that is still pending then is abandoned by
// disposing the client, which aborts it.
func connectWithin(host: in String, port: in Int, timeoutMs: in Int): TcpClient {
  val client = newTcpClientUnconnected()
  try {
    val pending = clientConnectAsync(client, host, port)
    if not connectTaskWait(pending, timeoutMs) {
      clientClose(client)
      panic("connect timed out after " + timeoutMs.toString() + " ms")
    }
    client
  } catch Bug as b {
    clientClose(client)
    panic(b.message)
  }
}

@experimental
pub func hostConnect(host: in String, port: in Int, connectTimeoutMs: in Int): Result[Conn, TcpError]
  requires: connectTimeoutMs >= 0
{
  try {
    val client = if connectTimeoutMs == 0 {
      newTcpClientConnected(host, port)
    } else {
      connectWithin(host, port, connectTimeoutMs)
    }
    // `clientStream` (`GetStream()`) is wrapped in its own try so a failure
    // here — after the client is already connected — closes the socket
    // before returning the error instead of leaking it (#6057).
    val stream = try {
      val s = clientStream(client)
      clientSetNoDelay(client, true)
      s
    } catch Bug as b {
      clientClose(client)
      return Err(error = TransportFailed(message = b.message))
    }
    Ok(value = Conn(client = client, stream = stream, alpn = "", readBuf = allocBuffer(readBufferSize)))
  } catch Bug as b {
    Err(error = TransportFailed(message = b.message))
  }
}

/// Stop listening and release the socket. Idempotent-safe: a redundant stop
/// is swallowed rather than surfaced.
@experimental
pub func hostStopListener(l: in Listener): Unit {
  try {
    listenerStop(l.handle)
  } catch Bug as _ {
    ()
  }
}

/// Release the listening socket's remaining resources once `hostStopListener`
/// has been called and no thread can still be inside `hostAccept` on `l` (the
/// accept loop has ended). Nothing is left to release on this target:
/// `hostStopListener` already closed the socket. The native twin keeps the
/// descriptor open after `hostStopListener` (closing it under a thread still in
/// `accept` would let another descriptor reuse its number) and frees it here,
/// so a driver written once calls this after it has joined its accept loop.
@experimental
pub func hostCloseListener(l: in Listener): Unit {
  ()
}

/// Block until a client connects, returning a plain (non-TLS) connection.
/// `alpn` is always `""` for a plain connection.
@experimental
pub func hostAccept(l: in Listener): Result[Conn, TcpError] {
  try {
    val client = listenerAccept(l.handle)
    // `clientStream` (`GetStream()`) is wrapped in its own try so a failure
    // here — after the socket is already accepted — closes it before
    // returning the error instead of leaking it (#6057).
    val stream = try {
      val s = clientStream(client)
      clientSetNoDelay(client, true)
      s
    } catch Bug as b {
      clientClose(client)
      return Err(error = AcceptFailed(message = b.message))
    }
    Ok(value = Conn(client = client, stream = stream, alpn = "", readBuf = allocBuffer(readBufferSize)))
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
  optionsSetServerCertificateContext(opts, newCertContext(cfg.identity.rawHandle(), newCertCollection(), true))
  match cfg.minVersion {
    case Tls13 -> optionsSetEnabledSslProtocols(opts, sslProtocolsTls13())
    case Tls12 -> ()
  }
  setApplicationProtocols(opts)
  if cfg.requireClientCert {
    optionsSetClientCertificateRequired(opts, true)
  }
  match cfg.clientCa {
    case Some(ca) -> {
      val policy = newChainPolicy()
      chainPolicySetTrustMode(policy, chainTrustModeCustomRoot())
      chainPolicySetRevocationMode(policy, revocationModeNoCheck())
      val store = chainPolicyCustomTrustStore(policy)
      val anchors = ca.rawHandles()
      var i = 0
      while i < anchors.count {
        val _ = trustStoreAdd(store, anchors[i])
        i = i + 1
      }
      optionsSetChainPolicy(opts, policy)
    }
    case None -> ()
  }
  opts
}

// The negotiated ALPN protocol as a wire string, matched against the set
// this transport advertises (`h2` and `http/1.1`, docs/61 §6.4). `""` means no
// ALPN was negotiated (the peer offered none) — the server assembly then serves
// HTTP/1.1.
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
func validateServerConfig(
  // mTLS misconfiguration guard (#6042). With the callback-free mTLS path
  // (module header), trust in a presented client certificate is pinned ONLY by
  // the `CertificateChainPolicy` built from `clientCa`. If `requireClientCert`
  // is set but no `clientCa` is configured, `buildServerOptions` installs no
  // chain policy, so `SslStream` would validate the client certificate against
  // the SYSTEM trust store — accepting ANY publicly-trusted certificate and
  // defeating the purpose of private-CA mutual TLS. That is a security
  // misconfiguration, not a permissive default, so it is rejected loudly here
  // (before any socket work) rather than silently falling back.
  cfg: in Tls.TlsServerConfig,
): Option[TcpError] {
  if cfg.requireClientCert {
    match cfg.clientCa {
      case None -> Some(
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

@experimental
pub func hostAcceptTls(l: in Listener, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  match validateServerConfig(cfg) {
    case Some(e) -> Err(error = e)
    case None -> match hostAccept(l) {
      case Err(e) -> Err(error = e)
      case Ok(plain) -> hostUpgradeServerTls(plain, cfg)
    }
  }
}

/// A server TLS configuration validated and compiled once, for reuse across
/// every connection a listener accepts (#7268): the `SslServerAuthenticationOptions`,
/// its `SslStreamCertificateContext` (certificate chain), ALPN list and mTLS
/// chain policy are built by `hostPrepareServerTls` and only read afterwards,
/// so concurrent handshakes share them safely.
@experimental
pub opaque type ServerTls {
  options: SslServerAuthOptions
}

/// Validate `cfg` and build its reusable server TLS state. A mutual-TLS
/// misconfiguration (`requireClientCert` with no `clientCa`, #6042) or an
/// identity the platform cannot use is `Err(TlsConfigInvalid(...))`.
@experimental
pub func hostPrepareServerTls(cfg: in Tls.TlsServerConfig): Result[ServerTls, TcpError] {
  match validateServerConfig(cfg) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }
  try {
    Ok(value = ServerTls(options = buildServerOptions(cfg)))
  } catch Bug as b {
    Err(error = TlsConfigInvalid(message = b.message))
  }
}

/// Release a `ServerTls` once no connection will be upgraded with it again.
/// Nothing to free on this target (the options are garbage-collected); the
/// native twin frees its OpenSSL context here.
@experimental
pub func hostReleaseServerTls(t: in ServerTls): Unit {
  ()
}

/// Bound every subsequent blocking read and write on `conn` to `timeoutMs`
/// milliseconds of inactivity (`0` = no limit). A read or write that times
/// out returns `Err(TransportFailed(...))`. Best-effort: a socket that is
/// already closed ignores the call (its next read or write fails anyway).
@experimental
pub func hostSetIoTimeout(conn: in Conn, timeoutMs: in Int): Unit
  requires: timeoutMs >= 0
{
  try {
    clientSetReceiveTimeout(conn.client, timeoutMs)
    clientSetSendTimeout(conn.client, timeoutMs)
  } catch Bug as _ {
    ()
  }
}

/// Terminate TLS on an already-accepted plain connection (the accept/upgrade
/// split so a driver can run the handshake off its accept loop, #7268).
/// `handshakeTimeoutMs` (`0` = no limit) bounds each blocking socket operation
/// of the handshake, so a peer that connects and never finishes its
/// ClientHello fails instead of holding the connection open forever; the
/// timeout is cleared again on success. On `Err` the plain `conn` is left for
/// the caller to `hostClose`, so a caller that tracks live connections can
/// deregister it before its socket is released.
@experimental
pub func hostUpgradeServerTlsPrepared(
  conn: in Conn, tls: in ServerTls, handshakeTimeoutMs: in Int
): Result[Conn, TcpError]
  requires: handshakeTimeoutMs >= 0
{
  // The `SslStream` ctor itself is wrapped in its own try (#6058) so a throw
  // maps to `TlsHandshakeFailed` like every other fallible BCL call in this
  // file instead of escaping as a raw host exception.
  val ssl = try {
    newSslStream(conn.stream, false)
  } catch Bug as b {
    return Err(error = TlsHandshakeFailed(message = b.message))
  }
  try {
    if handshakeTimeoutMs > 0 {
      clientSetReceiveTimeout(conn.client, handshakeTimeoutMs)
      clientSetSendTimeout(conn.client, handshakeTimeoutMs)
    }
    sslAuthenticateAsServer(ssl, tls.options)
    if handshakeTimeoutMs > 0 {
      clientSetReceiveTimeout(conn.client, 0)
      clientSetSendTimeout(conn.client, 0)
    }
    Ok(value = Conn(client = conn.client, stream = ssl, alpn = computeAlpn(ssl), readBuf = conn.readBuf))
  } catch Bug as b {
    // Dispose the SslStream (which, via leaveInnerStreamOpen = false, also
    // disposes the wrapped NetworkStream) so a rejected handshake does not
    // leak its state (#6031); the caller's `hostClose(conn)` releases the
    // socket.
    disposeQuietly(ssl)
    Err(error = TlsHandshakeFailed(message = b.message))
  }
}

/// Terminate TLS on an already-accepted plain connection using `cfg`, with no
/// handshake timeout. On failure the socket is closed before returning, so a
/// rejected peer never leaks a connection. Builds the server TLS state for
/// this one connection; a
/// driver upgrading many connections should call `hostPrepareServerTls` once
/// and `hostUpgradeServerTlsPrepared` per connection instead.
@experimental
pub func hostUpgradeServerTls(conn: in Conn, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  match hostPrepareServerTls(cfg) {
    case Err(e) -> {
      // Reject the misconfiguration (#6042) and release the already-accepted
      // socket rather than upgrading it.
      clientClose(conn.client)
      Err(error = e)
    }
    case Ok(tls) -> match hostUpgradeServerTlsPrepared(conn, tls, 0) {
      case Ok(upgraded) -> Ok(value = upgraded)
      case Err(e) -> {
        hostClose(conn)
        Err(error = e)
      }
    }
  }
}

// =====================================================================
// Client TLS (docs/72 slice 4).
// =====================================================================
// The ALPN protocols named by a comma-separated list, trimmed, empty names
// dropped, most preferred first.
func alpnNames(alpnCsv: in String): List[String] {
  val names: List[String] = newList()
  val parts = Str.split(alpnCsv, ",")
  var i = 0
  while i < parts.length {
    val name = Str.trim(parts[i])
    if name.length > 0 {
      names.add(name)
    }
    i = i + 1
  }
  names
}

// The negotiated protocol as the offered name it matches, or `""` when the
// peer selected none (or one this client did not offer).
func negotiatedAmong(ssl: in Stream, offered: in List[String]): String {
  val neg = sslNegotiatedProtocol(ssl)
  var i = 0
  while i < offered.count {
    if sslAppEq(neg, sslAppProtoOf(offered[i])) {
      return offered[i]
    }
    i = i + 1
  }
  ""
}

// Trust anchors from PEM text; a PEM that does not parse is a rejected
// configuration, not a handshake failure.
func trustAnchors(caPem: in String): Result[List[TlsHost.CertHandle], TcpError] {
  match Tls.Certificate.fromPem(caPem) {
    case Err(e) -> Err(error = TlsConfigInvalid(message = "client trust CA: " + Tls.TlsError.message(e)))
    case Ok(cert) -> Ok(value = cert.rawHandles())
  }
}

// A chain policy that trusts exactly `anchors` and checks no revocation (the
// server mTLS policy above; an online OCSP/CRL probe must not start as a side
// effect of configuring trust, #5952).
func customRootPolicy(anchors: in List[TlsHost.CertHandle]): X509ChainPolicy {
  val policy = newChainPolicy()
  chainPolicySetTrustMode(policy, chainTrustModeCustomRoot())
  chainPolicySetRevocationMode(policy, revocationModeNoCheck())
  val store = chainPolicyCustomTrustStore(policy)
  var i = 0
  while i < anchors.count {
    val _ = trustStoreAdd(store, anchors[i])
    i = i + 1
  }
  policy
}

func buildClientOptions(
  sniHost: in String,
  trust: in Tls.TlsClientTrust,
  clientIdentity: in Option[Tls.Identity],
  minVersion: in Tls.TlsVersion,
  offered: in List[String],
): Result[SslClientAuthOptions, TcpError] {
  val opts = newClientOptions()
  clientOptionsSetTargetHost(opts, sniHost)
  match minVersion {
    case Tls13 -> clientOptionsSetEnabledSslProtocols(opts, sslProtocolsTls13())
    case Tls12 -> ()
  }
  if offered.count > 0 {
    val list = newApplicationProtocolList()
    var i = 0
    while i < offered.count {
      applicationProtocolListAdd(list, sslAppProtoOf(offered[i]))
      i = i + 1
    }
    clientOptionsSetApplicationProtocols(opts, list)
  }
  match clientIdentity {
    case Some(id) -> {
      val certs = newClientCertCollection()
      val _ = clientCertCollectionAdd(certs, id.rawHandle())
      clientOptionsSetClientCertificates(opts, certs)
    }
    case None -> ()
  }
  match trust {
    case Tls.TlsTrustSystemDefault -> Ok(value = opts)
    case Tls.TlsTrustExclusive(caPem) -> match trustAnchors(caPem) {
      case Err(e) -> Err(error = e)
      case Ok(anchors) -> {
        clientOptionsSetChainPolicy(opts, customRootPolicy(anchors))
        Ok(value = opts)
      }
    }
    case Tls.TlsTrustAdditive(caPem) -> match trustAnchors(caPem) {
      case Err(e) -> Err(error = e)
      case Ok(anchors) -> {
        val policy = customRootPolicy(anchors)
        val roots = newRootStore("Root", storeLocationLocalMachine())
        rootStoreOpen(roots, openFlagsReadOnly())
        trustStoreAddRange(chainPolicyCustomTrustStore(policy), rootStoreCertificates(roots))
        rootStoreClose(roots)
        clientOptionsSetChainPolicy(opts, policy)
        Ok(value = opts)
      }
    }
    case Tls.TlsTrustInsecure -> {
      val policy = customRootPolicy(newList())
      chainPolicySetVerificationFlags(policy, verificationFlagsAll())
      clientOptionsSetChainPolicy(opts, policy)
      Ok(value = opts)
    }
  }
}

/// Terminate TLS on an already-connected plain connection, as a client (the
/// connect/upgrade split mirrors `hostAcceptTls`/`hostUpgradeServerTls`).
/// `sniHost` is the name sent as SNI and verified against the peer's
/// certificate (RFC 6125). `trust` is the caller's resolved trust decision
/// (`Std.Tls.TlsClientTrust`), `clientIdentity` the mTLS identity to present
/// (`None` presents no certificate), `minVersion` the protocol floor, and
/// `alpnCsv` the ALPN protocols to offer, most preferred first (`""` offers
/// none); `hostAlpn` of the result is the one the peer selected, `""` when it
/// selected none. The underlying socket is closed on every failure path so a
/// rejected handshake never leaks a connection. A socket timeout set with
/// `hostSetIoTimeout` bounds each socket operation of the handshake. A trust PEM that does
/// not parse is `Err(TlsConfigInvalid(...))`; a handshake failure (an
/// untrusted or expired certificate, a hostname mismatch, a rejected client
/// identity) is `Err(TlsHandshakeFailed(...))`. The same signature as the JVM
/// and native kernels.
@experimental
pub func hostUpgradeClientTls(
  conn: in Conn,
  sniHost: in String,
  trust: in Tls.TlsClientTrust,
  clientIdentity: in Option[Tls.Identity],
  minVersion: in Tls.TlsVersion,
  alpnCsv: in String,
): Result[Conn, TcpError] {
  val offered = alpnNames(alpnCsv)
  val opts = try {
    match buildClientOptions(sniHost, trust, clientIdentity, minVersion, offered) {
      case Ok(o) -> o
      case Err(e) -> {
        hostClose(conn)
        return Err(error = e)
      }
    }
  } catch Bug as b {
    hostClose(conn)
    return Err(error = TlsConfigInvalid(message = b.message))
  }
  val ssl = try {
    newSslStream(conn.stream, false)
  } catch Bug as b {
    hostClose(conn)
    return Err(error = TlsHandshakeFailed(message = b.message))
  }
  try {
    sslAuthenticateAsClient(ssl, opts)
    Ok(value = Conn(client = conn.client, stream = ssl, alpn = negotiatedAmong(ssl, offered), readBuf = conn.readBuf))
  } catch Bug as b {
    disposeQuietly(ssl)
    hostClose(conn)
    Err(error = TlsHandshakeFailed(message = b.message))
  }
}

/// Dial `host`:`port` and terminate TLS on the connection as a client.
/// `host` is used for BOTH the socket dial and SNI / hostname verification,
/// the ordinary case where the URL authority names the peer. Everything else
/// is as `hostUpgradeClientTls`; `connectTimeoutMs` bounds the connect as
/// `hostConnect`'s does (`0` = the operating system's own limit). A connect
/// failure is `Err(TransportFailed(...))`. The same signature as the JVM and
/// native kernels.
@experimental
pub func hostConnectTls(
  host: in String,
  port: in Int,
  trust: in Tls.TlsClientTrust,
  clientIdentity: in Option[Tls.Identity],
  minVersion: in Tls.TlsVersion,
  alpnCsv: in String,
  connectTimeoutMs: in Int,
): Result[Conn, TcpError]
  requires: connectTimeoutMs >= 0
{
  match hostConnect(host, port, connectTimeoutMs) {
    case Err(e) -> Err(error = e)
    case Ok(plain) -> hostUpgradeClientTls(plain, host, trust, clientIdentity, minVersion, alpnCsv)
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
@experimental
pub func hostAlpn(c: in Conn): String {
  c.alpn
}

/// Read up to `maxBytes` bytes from the connection, blocking until at least
/// one byte arrives. Returns the bytes actually read; an empty slice means
/// the peer closed its half of the connection (EOF). A socket error is
/// `Err(TransportFailed(...))`. Reads on one connection must not run
/// concurrently: they share the connection's read buffer.
@experimental
pub func hostRead(c: in Conn, maxBytes: in Int): Result[slice[Byte], TcpError]
  requires: maxBytes > 0
{
  try {
    val want = if maxBytes < readBufferSize { maxBytes } else { readBufferSize }
    val n = streamReadInto(c.stream, memGetBuffer(c.readBuf), 0, want)
    Ok(value = memGetBuffer(c.readBuf).slice(0, n))
  } catch Bug as b {
    Err(error = TransportFailed(message = b.message))
  }
}

/// Why a deadline-bounded read did not return bytes.
@experimental
pub union ReadDeadlineError {
  // The deadline passed before a byte arrived. Nothing was consumed: the
  // connection (plain or TLS) stays usable for further reads and writes.
  case ReadDeadlinePassed
  // The read itself failed, as `hostRead`'s would.
  case ReadFailed(error: TcpError)
}

/// Human-readable message for a ReadDeadlineError.
@pure
@experimental
pub func ReadDeadlineError.message(e: in ReadDeadlineError): String {
  match e {
    case ReadDeadlinePassed -> "read deadline passed"
    case ReadFailed(error) -> TcpError.message(error)
  }
}

// Milliseconds from now to `deadlineNanos`, rounded up and at least one (a
// zero receive timeout means "wait forever"); an already-passed deadline still
// lets one read collect what has arrived.
func millisUntil(deadlineNanos: in Long): Int {
  val left = deadlineNanos - Time.monotonicNanos()
  if left <= 0i64 {
    1
  } else {
    val ms = (left + 999999i64) / 1000000i64
    if ms > 2147483647i64 {
      2147483647
    } else {
      ms.toInt()
    }
  }
}

func isReadTimeout(message: in String): Bool {
  Str.indexOfFromRaw(Str.toLower(message), "timed out", 0) >= 0
}

/// `hostRead` that gives up at `deadlineNanos`, an absolute point on the
/// `Std.Time.monotonicNanos()` clock (`0i64` = no deadline, exactly
/// `hostRead`). A deadline that has already passed still lets the read collect
/// bytes that have arrived. On `ReadDeadlinePassed` nothing was consumed and the
/// connection is intact, so a driver can poll with a short deadline to notice
/// a per-call deadline or a close request and read again. The I/O timeout of
/// `hostSetIoTimeout` is restored afterwards. Reads on one connection must not
/// run concurrently. The same signature and contract on every target.
@experimental
pub func hostReadDeadline(c: in Conn, maxBytes: in Int, deadlineNanos: in Long): Result[slice[Byte], ReadDeadlineError]
  requires: maxBytes > 0
{
  if deadlineNanos == 0i64 {
    return match hostRead(c, maxBytes) { case Ok(b) -> Ok(value = b); case Err(e) -> Err(error = ReadFailed(error = e)) }
  }
  var previous = 0
  try {
    previous = clientGetReceiveTimeout(c.client)
    clientSetReceiveTimeout(c.client, millisUntil(deadlineNanos))
    val want = if maxBytes < readBufferSize { maxBytes } else { readBufferSize }
    val n = streamReadInto(c.stream, memGetBuffer(c.readBuf), 0, want)
    clientSetReceiveTimeout(c.client, previous)
    Ok(value = memGetBuffer(c.readBuf).slice(0, n))
  } catch Bug as b {
    try {
      clientSetReceiveTimeout(c.client, previous)
    } catch Bug as _ {
      ()
    }
    if isReadTimeout(b.message) {
      Err(error = ReadDeadlinePassed)
    } else {
      Err(error = ReadFailed(error = TransportFailed(message = b.message)))
    }
  }
}

/// Write all of `bytes` to the connection and flush. A broken pipe / reset
/// connection is `Err(TransportFailed(...))` rather than an uncaught exception.
@experimental
pub func hostWrite(c: in Conn, bytes: in slice[Byte]): Result[Unit, TcpError] {
  try {
    streamWriteFrom(c.stream, bytes, 0, bytes.length)
    streamFlush(c.stream)
    Ok(value = ())
  } catch Bug as b {
    Err(error = TransportFailed(message = b.message))
  }
}

/// The connection's remote endpoint as a string (e.g. `"127.0.0.1:54321"`),
/// or `""` if it cannot be determined (a closed/disposed socket throws,
/// which is swallowed rather than surfaced — a best-effort diagnostic value,
/// never load-bearing for protocol correctness).
@experimental
pub func hostRemoteAddress(c: in Conn): String {
  try {
    endPointToString(socketRemoteEndPoint(clientSocket(c.client)))
  } catch Bug as _ {
    ""
  }
}

/// Interrupt a blocking `hostRead`/`hostWrite` in progress on this connection
/// FROM ANOTHER THREAD, without releasing the connection (that stays the owning
/// thread's job, via `hostClose`). `Socket.Shutdown(Both)` on the underlying
/// socket, for a plain and a TLS connection alike (a blocked `SslStream` read
/// or write fails because its transport does): a blocked read returns end of
/// stream or `Err(TransportFailed(...))` and a blocked write fails with
/// `Err(TransportFailed(...))`. No TLS close_notify is sent. `hostClose` is
/// still required afterwards and is safe to call after a shutdown. The same
/// contract as native's `hostShutdown` (D621).
@experimental
pub func hostShutdown(c: in Conn): Unit {
  try {
    socketShutdown(clientSocket(c.client), socketShutdownBoth())
  } catch Bug as _ {
    ()
  }
}

/// Close the connection, releasing the socket and (for a TLS connection) the
/// `SslStream`. Swallows a double-close.
@experimental
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
