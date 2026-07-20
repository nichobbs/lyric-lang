//! std/_kernel_native/tcp_host.l - native-target TCP + server-side TLS
//! transport kernel for the sans-IO `Std.HttpEngine` (docs/61 §7, D128;
//! N9.2 of epic #5874 phase 5, issue #6103).
//!
//! Mirrors the dotnet `_kernel/tcp_host.l` public surface —
//! `hostListen`/`hostConnect`/`hostStopListener`/`hostAccept`/
//! `hostAcceptTls`/`hostUpgradeServerTls`/`hostAlpn`/`hostRead`/
//! `hostWrite`/`hostClose`, plus the same `TcpError` cases — over the
//! `lyric_sock_*` / `lyric_tls_*` seam shipped in `lyric-rt/src/lyric_tls.c`
//! (N9.1, D-progress-703). This is the `_kernel_native/` boundary the
//! seam's own header anticipates (D-N-007: externs only here); the
//! Result-native shape below is a genuine port, NOT a line-for-line
//! translation of the dotnet twin's try/catch bodies (D-N-003: native has
//! no exceptions) — every fallible operation here is driven directly off
//! the seam's -1/NULL return values plus `lyric_tls_last_error`.
//!
//! ## Representation: why `Listener`/`Conn` are plain records, not `opaque type`
//!
//! The issue text (and docs/61 §7 item 4) call for "an opaque type whose
//! destructor calls the matching free" — the natural ARC-idiomatic shape.
//! Two things about the CURRENT self-hosted native backend rule that out,
//! verified by reading the code (not assumed) before writing this file:
//!
//! 1. `Llvm.Codegen`'s item-kind dispatch (`lyric-compiler/lyric/
//!    llvm_codegen.l`, the collection loop over `SourceFile.items`) has
//!    cases for `IRecord`/`IUnion`/`IEnum`/`IDistinctType`/`IInterface`/
//!    `IImpl`/`IProtected`/`ITypeAlias`/`IExternType` — no `IOpaque` case
//!    at all, so it falls to the wildcard arm and PANICS at compile time:
//!    "this item form is not yet supported for --target native". Using
//!    `opaque type` here would not compile on native today. Filed as a
//!    tracked compiler gap: issue #6234 (native `opaque type` codegen).
//! 2. Even setting that aside, no Lyric-level mechanism exists yet for a
//!    heap type's destructor to run CUSTOM cleanup code (the free() call)
//!    on a raw resource: `04-arc-design.md`'s synthesised record/union
//!    destructor only releases reference-typed FIELDS (`recHasRefFields`/
//!    `isRefNType` in `llvm_codegen.l`, which only recognises `NPtr(NStruct
//!    (...))` — an ARC-managed heap pointer — as needing release; a raw
//!    `NativePtr[T]` field is inert data to it, exactly like an `Int`).
//!    There is no `@finalize`/custom-destructor annotation a user type can
//!    carry. Genuine ARC-triggered resource cleanup is therefore also a
//!    compiler gap, not just an `opaque type` codegen gap — tracked
//!    alongside #6234.
//!
//! Given both gaps, this file follows the SAME explicit-lifetime
//! discipline every other `_kernel_native/` file already uses for a
//! long-lived resource (`_kernel_native/process_capture_host.l`'s
//! `rtProcessFree`/`_kernel_native/file_host.l`'s `freeC` — nothing here
//! is a new pattern): `Listener`/`Conn` are plain (non-opaque) `pub
//! record`s with package-PRIVATE fields (no `pub` on the fields
//! themselves — the same "public type, private fields, public accessor
//! functions" shape `_kernel_native/process_capture_host.l`'s
//! `ProcessCaptureResult` already uses), and `hostStopListener`/
//! `hostClose` are the explicit, always-must-be-called free path — the
//! exact API contract the dotnet `Std.TcpHost` twin already documents
//! (`Dispose`/`Close` are called explicitly there too; there is no GC
//! finalizer path on that managed target either). `Std.TcpHost` has no
//! JVM twin at all — only the dotnet one, at `_kernel/tcp_host.l` — unlike
//! `Std.TlsHost`/`Std.EncodingHost` below, which genuinely do have JVM
//! twins this file's own header comments compare against. No consumer of
//! this package can read `Listener.fd`/`Conn.tlsConnHandle` directly (no
//! `pub` field), so the encapsulation guarantee `opaque type` would have
//! given is preserved by ordinary visibility, just not by a
//! compiler-enforced ARC destructor.
//!
//! ## Representation: `Conn`'s TLS handle is a `Long`, not a `NativePtr[Byte]`
//!
//! `Conn` must survive across MULTIPLE separate top-level calls
//! (`hostAcceptTls` constructs it, `hostRead`/`hostWrite`/`hostClose` use
//! it later) — so its fields, unlike a `NativePtr[Byte]` local threaded
//! through a single function body (the `_kernel_native/
//! process_capture_host.l` async-op pattern), MUST be storable in a heap
//! record. The mode checker's N0100 boundary (`lyric-compiler/lyric/
//! mode_checker/modechecker_check.l`) documents record/union fields typed
//! `NativePtr[T]` as rejected "unconditionally (heap storage outlives any
//! frame)" — a real invariant about raw-pointer lifetime safety, not
//! merely an enforcement detail (its `checkNativeFfiBoundary` entry point
//! is not yet wired into the native bridge's pipeline, but the documented
//! invariant is honoured here regardless of whether today's compiler
//! would catch a violation).
//!
//! The fix is the same "opaque handle as integer" trick JNI's `jlong`
//! uses for a native peer pointer stashed in a Java field: every
//! `lyric_tls_*` handle in this file (`void*` in C) is declared on the
//! Lyric side as `Long` at BOTH its extern-func return position (server
//! ctx / conn construction) and its extern-func parameter position (every
//! later call taking that handle back) — never `NativePtr[Byte]`. A
//! pointer and an `i64` are the identical machine word on every triple
//! `--target native` supports today (x86-64 / AArch64, both LP64), so the
//! declared LLVM IR type at the `declare`/`call` site (`i64`, from
//! `Long`'s `NI64` mapping) carries the exact same calling-convention
//! register the real `void*`-typed C parameter/return expects — precisely
//! the "the extern declaration is the audited/trusted boundary" contract
//! every `_kernel_native/`/`_kernel/`/`_kernel_jvm/` file already relies
//! on for its `@axiom`-declared signatures. `0i64` is the sentinel for
//! "no TLS" (a plain connection): `malloc` never returns a NULL/0
//! pointer on success, so 0 can never collide with a real handle.
//!
//! A plain socket's fd, by contrast, genuinely IS an `Int` at the C ABI
//! (`int32_t`), so `Listener.fd`/`Conn.fd` need no such trick.
@axiom("lyric_sock_*/lyric_tls_* (lyric-rt/src/lyric_tls.c) conform to their documented contracts")
package Std.TcpHost

import Std.Core
import Std.Tls as Tls
import Std.TlsHost as TlsHost

// =====================================================================
// Public error + connection types.
// =====================================================================
/// Every way a transport operation can fail — the exact case set the
/// dotnet `Std.TcpHost` twin exposes (there is no JVM twin of
/// `Std.TcpHost`), so a driver written against this type is portable to
/// whichever target(s) `Std.TcpHost` ships on.
pub union TcpError {
  case BindFailed(message: String)
  case AcceptFailed(message: String)
  case TlsHandshakeFailed(message: String)
  case TransportFailed(message: String)
  // A rejected server-TLS configuration detected before any socket work —
  // mutual TLS requested (`requireClientCert`) with no `clientCa` to pin
  // trust to (mirrors the dotnet twin's #6042 guard).
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

/// A bound, listening TCP socket. See the module header for why this is
/// a plain record (not `opaque type`) with package-private fields.
pub record Listener {
  fd: Int
}

/// One accepted connection. `tlsConnHandle` is `0i64` for a plain
/// connection, or the seam's `lyric_tls_conn*` (as a `Long`, module
/// header) for a TLS one. `alpn` is the negotiated ALPN protocol (`""`
/// for a plain connection, or a TLS connection where the peer offered
/// none).
pub record Conn {
  fd: Int
  tlsConnHandle: Long
  alpn: String
}

// =====================================================================
// Extern seam bindings (lyric-rt/src/lyric_tls.c).
// =====================================================================
extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtLastErrorString(): String = "lyric_tls_last_error_string"

// --- Plain sockets ----------------------------------------------------
extern func rtSockConnect(host: NativePtr[Byte], port: Int): Int = "lyric_sock_connect"

extern func rtSockListen(ip: NativePtr[Byte], port: Int, backlog: Int): Int = "lyric_sock_listen"

extern func rtSockAccept(listenFd: Int): Int = "lyric_sock_accept"

extern func rtSockLocalPort(fd: Int): Int = "lyric_sock_local_port"

extern func rtSockClose(fd: Int): Int = "lyric_sock_close"

extern func rtSockReadBytes(fd: Int, maxBytes: Long, okOut: NativePtr[Int]): slice[Byte] = "lyric_sock_read_bytes"

extern func rtSockWriteBytes(fd: Int, bytes: slice[Byte]): Long = "lyric_sock_write_bytes"

// --- TLS (server-side; N9.2 has no client-TLS surface — that is
// Std.Http's job, N9.4/#6105) ------------------------------------------
extern func rtTlsServerNew(certPem: NativePtr[Byte], keyPem: NativePtr[Byte], minVersion: Int, clientCaPem: NativePtr[Byte], requireClientCert: Int, alpnCsv: NativePtr[Byte]): Long = "lyric_tls_server_new"

extern func rtTlsServerAccept(serverCtx: Long, fd: Int): Long = "lyric_tls_server_accept"

extern func rtTlsCtxFree(ctx: Long): Unit = "lyric_tls_ctx_free"

extern func rtTlsShutdown(conn: Long): Unit = "lyric_tls_shutdown"

extern func rtTlsFree(conn: Long): Unit = "lyric_tls_free"

extern func rtTlsAlpnString(conn: Long): String = "lyric_tls_alpn_string"

extern func rtTlsReadBytes(conn: Long, maxBytes: Long, okOut: NativePtr[Int]): slice[Byte] = "lyric_tls_read_bytes"

extern func rtTlsWriteBytes(conn: Long, bytes: slice[Byte]): Long = "lyric_tls_write_bytes"

// The server's ALPN preference list — `h2` first, matching docs/61 §6.4
// phase 4.4 and the dotnet twin's `setApplicationProtocols`; a peer that
// offers only `http/1.1` (or no ALPN) falls back to HTTP/1.1.
val alpnPreference: String = "h2,http/1.1"

// =====================================================================
// Public API.
// =====================================================================
/// Bind a listening TCP socket to `host`:`port`. `host` is an IP literal
/// (e.g. `"127.0.0.1"` / `"0.0.0.0"` / `"::"`), not a DNS name — the
/// transport does not resolve names (matches the dotnet twin). A bind
/// failure (port in use, permission denied, malformed address) is
/// `Err(BindFailed(...))`.
@unsafe_ffi
pub func hostListen(host: in String, port: in Int): Result[Listener, TcpError] {
  val c = toC(host)
  val fd = rtSockListen(c, port, 128)
  freeC(c)
  if fd >= 0 {
    Ok(value = Listener(fd = fd))
  } else {
    Err(error = BindFailed(message = rtLastErrorString()))
  }
}

/// Dial a plain (non-TLS) TCP connection to `host`:`port`. `host` may be
/// an IP literal or a DNS name (`lyric_sock_connect`'s `getaddrinfo`
/// resolves it). A connect failure (refused, unreachable, unresolved) is
/// `Err(TransportFailed(...))`.
@unsafe_ffi
pub func hostConnect(host: in String, port: in Int): Result[Conn, TcpError] {
  val c = toC(host)
  val fd = rtSockConnect(c, port)
  freeC(c)
  if fd >= 0 {
    Ok(value = Conn(fd = fd, tlsConnHandle = 0i64, alpn = ""))
  } else {
    Err(error = TransportFailed(message = rtLastErrorString()))
  }
}

/// Stop listening and release the socket. Idempotent-safe: a redundant
/// stop is swallowed rather than surfaced (matches the dotnet twin).
pub func hostStopListener(l: in Listener): Unit {
  val _ = rtSockClose(l.fd)
}

/// The port `l` is actually bound to (`getsockname` under the hood) —
/// lets a caller bind an ephemeral port (`hostListen(host, 0)`) and read
/// back the kernel-assigned one, the same pattern `lyric_tls_test.c`'s
/// own `lyric_sock_local_port` already uses to avoid fixed-port CI
/// flakiness. Native-only: the dotnet `Std.TcpHost` twin has no
/// equivalent accessor (no consumer needs one there yet), so this is not
/// a cross-target parity claim, just a native testing/operational
/// convenience over a seam function that already existed for N9.1.
pub func hostLocalPort(l: in Listener): Int {
  rtSockLocalPort(l.fd)
}

/// Block until a client connects, returning a plain (non-TLS) connection.
/// `alpn` is always `""` for a plain connection.
pub func hostAccept(l: in Listener): Result[Conn, TcpError] {
  val fd = rtSockAccept(l.fd)
  if fd >= 0 {
    Ok(value = Conn(fd = fd, tlsConnHandle = 0i64, alpn = ""))
  } else {
    Err(error = AcceptFailed(message = rtLastErrorString()))
  }
}

// mTLS misconfiguration guard (mirrors the dotnet twin's #6042 check):
// `requireClientCert` with no `clientCa` would mean no client-certificate
// verification actually happens at the seam (lyric_tls_server_new treats
// an empty client_ca_pem as "no CA to verify against" regardless of
// require_client_cert — see lyric_tls_test.c's
// test_server_require_client_cert_without_ca, which locks in that exact
// seam behaviour), silently defeating the purpose of private-CA mutual
// TLS. Rejected loudly here before any socket work, not silently
// downgraded.
func validateServerConfig(cfg: in Tls.TlsServerConfig): Option[TcpError] {
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

func tlsVersionNumber(v: in Tls.TlsVersion): Int {
  match v {
    case Tls13 -> 13
    case Tls12 -> 12
  }
}

// Build a fresh server TLS context from `cfg` (identity, minimum version,
// mTLS, ALPN preference). The context is single-use: `hostUpgradeServerTls`
// frees it immediately after the one `lyric_tls_server_accept` call that
// consumes it (module header — no OpenSSL object needs to persist beyond
// a single accept, unlike the returned `conn` handle).
@unsafe_ffi
func buildServerCtx(cfg: in Tls.TlsServerConfig): Result[Long, TcpError] {
  val handle: TlsHost.CertHandle = cfg.identity.rawHandle()
  val keyPem = match handle.keyPem {
    case Some(k) -> k
    // Std.Tls only ever constructs an Identity's handle via
    // hostIdentityFromPemBytes, which always populates keyPem — a
    // certificate-only handle can never reach here through Identity's
    // type (invariant violation, not a user-reachable error).
    case None -> panic("Std.TcpHost: TlsServerConfig.identity has no private key (invariant violation)")
  }
  val clientCaPem = match cfg.clientCa {
    case Some(ca) -> ca.rawHandle().certPem
    case None -> ""
  }
  val requireClientCert = if cfg.requireClientCert { 1 } else { 0 }
  val certC = toC(handle.certPem)
  val keyC = toC(keyPem)
  val caC = toC(clientCaPem)
  val alpnC = toC(alpnPreference)
  val ctx = rtTlsServerNew(certC, keyC, tlsVersionNumber(cfg.minVersion), caC, requireClientCert, alpnC)
  freeC(alpnC)
  freeC(caC)
  freeC(keyC)
  freeC(certC)
  if ctx != 0i64 {
    Ok(value = ctx)
  } else {
    Err(error = TlsHandshakeFailed(message = rtLastErrorString()))
  }
}

/// Block until a client connects, then terminate TLS on the connection as
/// a server using `cfg` (server certificate, minimum version, ALPN, and
/// mTLS). A handshake failure — including an mTLS client that presents no
/// certificate or one that does not chain to `cfg.clientCa` — is
/// `Err(TlsHandshakeFailed(...))`, and the underlying socket is closed
/// before returning so a rejected peer never leaks a connection.
pub func hostAcceptTls(l: in Listener, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  // No `validateServerConfig` call here: `hostUpgradeServerTls` below
  // validates `cfg` itself, and it is the only other caller of
  // `validateServerConfig`, so validating here too would just run the same
  // check twice on every accept.
  match hostAccept(l) {
    case Err(e) -> Err(error = e)
    case Ok(plain) -> hostUpgradeServerTls(plain, cfg)
  }
}

/// Terminate TLS on an already-accepted plain connection (the
/// accept/upgrade split so a future driver can inspect the peer address
/// before deciding to speak TLS). Same handshake-failure discipline as
/// `hostAcceptTls`.
pub func hostUpgradeServerTls(conn: in Conn, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  match validateServerConfig(cfg) {
    case Some(e) -> {
      val _ = rtSockClose(conn.fd)
      return Err(error = e)
    }
    case None -> ()
  }
  match buildServerCtx(cfg) {
    case Err(e) -> {
      val _ = rtSockClose(conn.fd)
      Err(error = e)
    }
    case Ok(ctx) -> {
      val tlsConn = rtTlsServerAccept(ctx, conn.fd)
      rtTlsCtxFree(ctx)
      if tlsConn == 0i64 {
        val msg = rtLastErrorString()
        val _ = rtSockClose(conn.fd)
        Err(error = TlsHandshakeFailed(message = msg))
      } else {
        val alpn = rtTlsAlpnString(tlsConn)
        Ok(value = Conn(fd = conn.fd, tlsConnHandle = tlsConn, alpn = alpn))
      }
    }
  }
}

/// The negotiated ALPN protocol for this connection (`"http/1.1"`, `"h2"`,
/// or `""` when none was negotiated / the connection is plain). A driver
/// selects the engine's connection FSM on this value (docs/61 §6.4).
pub func hostAlpn(c: in Conn): String {
  c.alpn
}

/// Read up to `maxBytes` bytes from the connection, blocking until at
/// least one byte arrives. Returns the bytes actually read; an empty
/// slice means the peer closed its half of the connection (EOF). A
/// socket/TLS error is `Err(TransportFailed(...))`.
@unsafe_ffi
pub func hostRead(c: in Conn, maxBytes: in Int): Result[slice[Byte], TcpError]
  requires: maxBytes > 0
{
  var ok: Int = 0
  val bytes = if c.tlsConnHandle != 0i64 {
    rtTlsReadBytes(c.tlsConnHandle, maxBytes.toLong(), nativeAddrOf(ok))
  } else {
    rtSockReadBytes(c.fd, maxBytes.toLong(), nativeAddrOf(ok))
  }
  if ok == 1 {
    Ok(value = bytes)
  } else {
    Err(error = TransportFailed(message = rtLastErrorString()))
  }
}

/// Write all of `bytes` to the connection. A broken pipe / reset
/// connection is `Err(TransportFailed(...))` rather than an uncaught
/// panic.
pub func hostWrite(c: in Conn, bytes: in slice[Byte]): Result[Unit, TcpError] {
  val n = if c.tlsConnHandle != 0i64 {
    rtTlsWriteBytes(c.tlsConnHandle, bytes)
  } else {
    rtSockWriteBytes(c.fd, bytes)
  }
  if n < 0i64 {
    Err(error = TransportFailed(message = rtLastErrorString()))
  } else {
    Ok(value = ())
  }
}

/// Close the connection, releasing the socket and (for a TLS connection)
/// the seam's connection handle. Swallows a double-close.
pub func hostClose(c: in Conn): Unit {
  if c.tlsConnHandle != 0i64 {
    rtTlsShutdown(c.tlsConnHandle)
    rtTlsFree(c.tlsConnHandle)
  }
  val _ = rtSockClose(c.fd)
}
