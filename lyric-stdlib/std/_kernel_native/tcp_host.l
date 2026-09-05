//! std/_kernel_native/tcp_host.l - native-target TCP + client/server TLS
//! transport kernel for the sans-IO `Std.HttpEngine` (docs/61 §7, D128;
//! N9.2 of epic #5874 phase 5, issue #6103) and for `Std.HttpHost`'s
//! native client twin (N9.4, issue #6105).
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
//! **Client TLS (`hostConnectTls`/`hostUpgradeClientTls`) added for N9.4.**
//! The N9.2 header below originally said "N9.2 has no client-TLS surface —
//! that is Std.Http's job, N9.4/#6105"; this is that job. It lives HERE,
//! not in `_kernel_native/http_host.l`, for the same reason
//! `hostAcceptTls`/`hostUpgradeServerTls` live here rather than in a
//! caller's package: constructing a `Conn` requires touching its
//! package-private `fd`/`tlsConnHandle`/`alpn` fields (module header below),
//! so the function that builds one from a client-side handshake must be a
//! member of this package, exactly like its server-side counterpart.
//! `Std.HttpHost`'s native kernel calls `hostConnectTls` and otherwise reads
//! the resulting `Conn` only through `hostRead`/`hostWrite`/`hostClose`,
//! same as every other `Std.TcpHost` consumer.
//!
//! ## Representation: why `Listener`/`Conn` are plain records, not `opaque type`
//!
//! The issue text (and docs/61 §7 item 4) call for "an opaque type whose
//! destructor calls the matching free" — the natural ARC-idiomatic shape.
//! At the time this file was written, TWO things about the self-hosted
//! native backend ruled that out, verified by reading the code (not
//! assumed) before writing this file. **Gap 1 is now fixed** (#6234 part 1,
//! shipped after this file was written) — see the correction below; gap 2
//! remains open and is the only reason this file still uses plain records:
//!
//! 1. **FIXED, #6234 part 1.** At the time this file was written,
//!    `Llvm.Codegen`'s item-kind dispatch (`lyric-compiler/lyric/
//!    llvm_codegen.l`, the collection loop over `SourceFile.items`) had
//!    cases for `IRecord`/`IUnion`/`IEnum`/`IDistinctType`/`IInterface`/
//!    `IImpl`/`IProtected`/`ITypeAlias`/`IExternType` — no `IOpaque` case
//!    at all, so it fell to the wildcard arm and PANICKED at compile time:
//!    "this item form is not yet supported for --target native". Using
//!    `opaque type` here would not have compiled on native then.
//!    `Llvm.Codegen.opaqueToRecordDecl` now reshapes an `OpaqueTypeDecl`
//!    into the equivalent `RecordDecl` at item-collection time (both the
//!    single-file and bundled-stdlib paths), so `opaque type` compiles,
//!    constructs, and releases correctly on native — verified end to end
//!    against `Std.Tls`'s real `Certificate`/`Identity` opaque types
//!    (`llvm_tls_self_test.l` item B). `opaque type` is a perfectly usable
//!    shape for `Listener`/`Conn` today, as far as gap 1 alone goes.
//! 2. Even setting that aside, no Lyric-level mechanism exists yet for a
//!    heap type's destructor to run CUSTOM cleanup code (the free() call)
//!    on a raw resource: `04-arc-design.md`'s synthesised record/union
//!    destructor only releases reference-typed FIELDS (`recHasRefFields`/
//!    `isRefNType` in `llvm_codegen.l`, which only recognises `NPtr(NStruct
//!    (...))` — an ARC-managed heap pointer — as needing release; a raw
//!    `NativePtr[T]` field is inert data to it, exactly like an `Int`).
//!    There is no `@finalize`/custom-destructor annotation a user type can
//!    carry. **This gap (#6234 part 2) is still open and is now the SOLE
//!    reason this file doesn't use `opaque type`**: converting
//!    `Listener`/`Conn` to `opaque type` today would compile and run fine,
//!    but ARC release still wouldn't call `hostClose`/`hostStopListener`'s
//!    underlying free automatically — the explicit-call discipline below
//!    would still be required in practice, so there's no correctness or
//!    ergonomics win in switching representations until part 2 lands.
//!
//! Given gap 2 (gap 1 resolved, see above), this file follows the SAME
//! explicit-lifetime discipline every other `_kernel_native/` file already
//! uses for a long-lived resource (`_kernel_native/process_capture_host.l`'s
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
/// How a `hostAccept`/`hostAcceptTls` failure should be treated by a
/// caller's own accept loop (issue #6805; `Std.HttpServer`'s native twin is
/// the first real consumer). Before this existed, `AcceptFailed` carried no
/// detail at all, so every accept() failure -- transient or not -- looked
/// identical to the caller and had to be treated as fatal.
pub union AcceptFailureKind {
  // The listening socket itself is gone: the intentional
  // `hostStopListener` wake-pipe interrupt (see that function's own doc
  // comment, issue #6806), or a genuine unexpected socket-level fault. The
  // caller's accept loop should end.
  case AcceptFatal
  // An already-pending network error on the NEW connection, not the
  // listening socket -- `ECONNABORTED` and the handful of related codes
  // Linux's accept(2) documents passing through this way (a portability
  // wrinkle other BSD-derived accept() implementations don't share).
  // POSIX's own recommendation is to just retry immediately, exactly like
  // any other single bad peer being skipped elsewhere in this file.
  case AcceptTransient
  // `EMFILE`/`ENFILE`: the process- or system-wide open-file table is
  // full. Also not the listening socket's fault, but retrying immediately
  // would spin-loop burning CPU while every accept() call fails the same
  // way until something else closes a descriptor -- the caller should
  // back off briefly before retrying.
  case AcceptOverloaded
}

pub union TcpError {
  case BindFailed(message: String)
  // `errno` is the raw platform errno (diagnostic detail alongside
  // `message`'s already-`strerror`'d text); `kind` is the portable
  // classification a caller's accept loop should actually branch on (see
  // `AcceptFailureKind`'s own doc comment) -- issue #6805.
  case AcceptFailed(message: String, errno: Int, kind: AcceptFailureKind)
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
    case AcceptFailed(m, _, _) -> "accept failed: " + m
    case TlsHandshakeFailed(m) -> "TLS handshake failed: " + m
    case TransportFailed(m) -> "I/O error: " + m
    case TlsConfigInvalid(m) -> "TLS configuration invalid: " + m
  }
}

/// A bound, listening TCP socket. See the module header for why this is
/// a plain record (not `opaque type`) with package-private fields.
/// `wakeReadFd`/`wakeWriteFd` back the portable accept()-interrupt seam
/// (issue #6806) -- see `hostStopListener`'s doc comment.
pub record Listener {
  fd: Int
  wakeReadFd: Int
  wakeWriteFd: Int
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

/// A fully-resolved client trust decision (N9.4, issue #6105): the CA
/// precedence policy (docs/61 §3.2 — `withExclusiveCaCertificate` beats
/// `withCaCertificate`, which beats "no CA configured") is a `Std.Http`
/// concern and is resolved BEFORE calling `hostConnectTls`/
/// `hostUpgradeClientTls`; this union is the fully-decided instruction the
/// seam executes. `TlsTrustAdditive`/`TlsTrustExclusive` carry the PEM text
/// directly (not a `Tls.Certificate`) so this file never depends on
/// `Std.HttpHost`'s builder-level `Option[Certificate]` shape.
pub union TlsClientTrust {
  // Verify against the platform's default trust store only
  // (`SSL_CTX_set_default_verify_paths` + `SSL_CERT_FILE`/`SSL_CERT_DIR`).
  case TlsTrustSystemDefault
  // Platform trust store PLUS `caPem` (`lyric_tls_client_new_additive`) — a
  // chain valid against either set verifies.
  case TlsTrustAdditive(caPem: String)
  // ONLY `caPem` (`lyric_tls_client_new`'s exclusive case) — the platform
  // trust store is never consulted.
  case TlsTrustExclusive(caPem: String)
  // Disable certificate AND hostname verification outright (docs/61 §4's
  // dual-key policy — the caller has already resolved that policy before
  // this union is constructed).
  case TlsTrustInsecure
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

// Diagnostic detail + portable classification for the most recent
// rtSockAcceptInterruptible failure ON THIS THREAD (issue #6805) -- see
// AcceptFailureKind's own doc comment for what the classification means.
extern func rtSockAcceptErrno(): Int = "lyric_sock_accept_errno"

extern func rtSockAcceptErrorClass(): Int = "lyric_sock_accept_error_class"

// Portable accept()-interrupt seam (issue #6806) -- see hostStopListener's
// doc comment below for why this replaces a bare rtSockAccept in
// hostAccept.
extern func rtSockWakePipeNew(readFdOut: NativePtr[Int], writeFdOut: NativePtr[Int]): Int = "lyric_sock_wake_pipe_new"

extern func rtSockWakePipeSignal(writeFd: Int): Int = "lyric_sock_wake_pipe_signal"

extern func rtSockAcceptInterruptible(listenFd: Int, wakeReadFd: Int): Int = "lyric_sock_accept_interruptible"

extern func rtSockLocalPort(fd: Int): Int = "lyric_sock_local_port"

extern func rtSockClose(fd: Int): Int = "lyric_sock_close"

// POSIX shutdown(2): interrupts a blocking read/write on `fd` from ANOTHER
// thread without invalidating the descriptor itself (unlike close(2), which
// would race a concurrent owner-thread close on the same fd if a stale
// reference to it survived — the classic fd-reuse hazard). `how = 2` is
// `SHUT_RDWR`'s numeric value, which is the same constant on every POSIX
// platform this project targets (Linux/macOS), so no platform table is
// needed the way `_kernel_native/libc.l`'s `oRdonly`/`oCreat`/etc. need one
// for open(2) flags. Used ONLY by `hostShutdown` below, for an already-
// ACCEPTED connection's fd -- `shutdown()` reliably interrupts a blocked
// read/write on a CONNECTED socket on every POSIX platform this project
// targets (unlike its behaviour on a LISTENING socket, which is Linux-only
// and is why `hostStopListener` below uses the wake-pipe seam instead;
// issue #6806).
extern func rtShutdown(fd: Int, how: Int): Int = "shutdown"

extern func rtSockReadBytes(fd: Int, maxBytes: Long, okOut: NativePtr[Int]): slice[Byte] = "lyric_sock_read_bytes"

extern func rtSockWriteBytes(fd: Int, bytes: slice[Byte]): Long = "lyric_sock_write_bytes"

// --- TLS (server-side) --------------------------------------------------
extern func rtTlsServerNew(certPem: NativePtr[Byte], keyPem: NativePtr[Byte], minVersion: Int, clientCaPem: NativePtr[Byte], requireClientCert: Int, alpnCsv: NativePtr[Byte]): Long = "lyric_tls_server_new"

extern func rtTlsServerAccept(serverCtx: Long, fd: Int): Long = "lyric_tls_server_accept"

extern func rtTlsCtxFree(ctx: Long): Unit = "lyric_tls_ctx_free"

extern func rtTlsShutdown(conn: Long): Unit = "lyric_tls_shutdown"

extern func rtTlsFree(conn: Long): Unit = "lyric_tls_free"

extern func rtTlsAlpnString(conn: Long): String = "lyric_tls_alpn_string"

extern func rtTlsReadBytes(conn: Long, maxBytes: Long, okOut: NativePtr[Int]): slice[Byte] = "lyric_tls_read_bytes"

extern func rtTlsWriteBytes(conn: Long, bytes: slice[Byte]): Long = "lyric_tls_write_bytes"

// --- TLS (client-side; N9.4, issue #6105) -------------------------------
extern func rtTlsClientNew(caPem: NativePtr[Byte], minVersion: Int, insecure: Int): Long = "lyric_tls_client_new"

extern func rtTlsClientNewAdditive(caPem: NativePtr[Byte], minVersion: Int, insecure: Int): Long = "lyric_tls_client_new_additive"

extern func rtTlsClientSetIdentity(clientCtx: Long, certPem: NativePtr[Byte], keyPem: NativePtr[Byte]): Int = "lyric_tls_client_set_identity"

extern func rtTlsClientConnect(clientCtx: Long, fd: Int, sniHost: NativePtr[Byte], alpnCsv: NativePtr[Byte]): Long = "lyric_tls_client_connect"

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
/// `Err(BindFailed(...))`. Also allocates the wake pipe `hostAccept`/
/// `hostStopListener` use to implement a portable accept() interrupt
/// (issue #6806); a failure to allocate it closes the just-bound socket
/// and reports `BindFailed` too, since a `Listener` this kernel cannot
/// later interrupt is not safely usable.
@unsafe_ffi
pub func hostListen(host: in String, port: in Int): Result[Listener, TcpError] {
  val c = toC(host)
  val fd = rtSockListen(c, port, 128)
  freeC(c)
  if fd >= 0 {
    var wakeRead: Int = -1
    var wakeWrite: Int = -1
    val pipeRc = rtSockWakePipeNew(nativeAddrOf(wakeRead), nativeAddrOf(wakeWrite))
    if pipeRc == 0 {
      Ok(value = Listener(fd = fd, wakeReadFd = wakeRead, wakeWriteFd = wakeWrite))
    } else {
      val msg = rtLastErrorString()
      val _ = rtSockClose(fd)
      Err(error = BindFailed(message = msg))
    }
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
///
/// **Portable accept()-interrupt via a self-pipe (issue #6806), not
/// `shutdown()` on the listening socket.** An earlier version of this
/// function called `rtShutdown(l.fd, 2)` before `rtSockClose` to unblock a
/// concurrent, already-blocked `hostAccept` on the accept-loop thread —
/// Linux documents `shutdown()` on a LISTENING socket delivering an error
/// (`EINVAL`) to a blocked `accept()` on the same fd, which worked, but
/// ONLY on Linux: on macOS/BSD, `shutdown()` on a listening socket returns
/// `ENOTCONN` and does not unblock a concurrently-blocked `accept()` at
/// all, so `Std.HttpServer.stopListener`'s `pthreadJoin` on that thread
/// hung forever there. `hostAccept` below no longer calls the bare
/// blocking `rtSockAccept` seam at all — it calls
/// `rtSockAcceptInterruptible`, which `poll(2)`s the listening socket
/// alongside the read end of a private pipe (`Listener.wakeReadFd`,
/// allocated in `hostListen`) and returns a `-2` sentinel the instant
/// EITHER a connection arrives OR that pipe becomes readable, without ever
/// calling `accept()` on the interrupt path. `hostStopListener` writes a
/// single byte to `wakeWriteFd` (`rtSockWakePipeSignal`) to trigger that
/// wakeup — an ordinary pipe write, portable to every POSIX target this
/// project builds for, not a Linux-specific socket-state side effect. The
/// pipe is closed only AFTER `rtSockClose`, so any handler that is (or
/// races to be) still polling it sees a valid fd for the whole interrupt
/// sequence.
///
/// **Note for callers on other threads:** this only wakes an
/// `rtSockAcceptInterruptible` call that reads THIS `Listener`'s
/// `wakeReadFd` — i.e. `hostAccept`/`hostAcceptTls` on the SAME `Listener`
/// value. It does not touch any already-accepted `Conn` (use
/// `hostShutdown` for that, per that function's own doc comment).
pub func hostStopListener(l: in Listener): Unit {
  val _ = rtSockWakePipeSignal(l.wakeWriteFd)
  val _ = rtSockClose(l.fd)
  val _ = rtSockClose(l.wakeReadFd)
  val _ = rtSockClose(l.wakeWriteFd)
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

// Maps rtSockAcceptErrorClass's portable classification code to the typed
// AcceptFailureKind a caller's accept loop actually branches on (issue
// #6805). See lyric_sock_accept_error_class's own doc comment in
// lyric_rt.h for what each code means.
func acceptFailureKindFromClass(classCode: in Int): AcceptFailureKind {
  if classCode == 1 {
    AcceptTransient
  } else if classCode == 2 {
    AcceptOverloaded
  } else {
    AcceptFatal
  }
}

/// Block until a client connects, returning a plain (non-TLS) connection,
/// OR until `hostStopListener` is called on this same `Listener` from
/// another thread (issue #6806). `alpn` is always `""` for a plain
/// connection. A failure carries a classified `AcceptFailureKind` (issue
/// #6805) so a caller's own accept loop can retry a transient or
/// resource-exhaustion failure instead of treating every accept() error as
/// fatal to the whole listener; an interrupt from `hostStopListener`
/// always classifies as `AcceptFatal` (the caller's accept loop should
/// end), same as the fatal case ever was.
///
/// Uses `rtSockAcceptInterruptible`, NOT the bare blocking `rtSockAccept`
/// — see `hostStopListener`'s doc comment for why (issue #6806: the prior
/// `rtSockAccept`-based design relied on a Linux-only `shutdown()` side
/// effect to unblock this call, which macOS/BSD do not share).
pub func hostAccept(l: in Listener): Result[Conn, TcpError] {
  val fd = rtSockAcceptInterruptible(l.fd, l.wakeReadFd)
  if fd >= 0 {
    Ok(value = Conn(fd = fd, tlsConnHandle = 0i64, alpn = ""))
  } else if fd == -2 {
    // The portable interrupt sentinel (hostStopListener was called on this
    // Listener from another thread) -- always AcceptFatal, matching the
    // classification a caller's accept loop already treats as "end the
    // loop" (acceptFailureKindFromClass's own default arm, below).
    Err(error = AcceptFailed(message = rtLastErrorString(), errno = 0, kind = AcceptFatal))
  } else {
    val rawErrno = rtSockAcceptErrno()
    val kind = acceptFailureKindFromClass(rtSockAcceptErrorClass())
    Err(error = AcceptFailed(message = rtLastErrorString(), errno = rawErrno, kind = kind))
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
  // Explicit static-call form (`Tls.Identity.rawHandle(cfg.identity)`), NOT the
  // UFCS spelling (`cfg.identity.rawHandle()`): the native backend's
  // bundled-import-closure UFCS resolver does not find an `internal`
  // cross-package function by receiver-method lookup (confirmed by direct
  // repro: "method '.rawHandle' on this receiver is not yet supported for
  // --target native (no matching function 'rawHandle/1' in the bundled
  // import closure)"), while the plain call form resolves and lowers
  // correctly. N9.4/#6105 (this file's own client identity handling below
  // hit the identical gap first — fixed here too since `hostAcceptTls`'s
  // real accept path was never previously exercised on native, item D of
  // `llvm_tls_self_test.l`'s own header).
  val handle: TlsHost.CertHandle = Tls.Identity.rawHandle(cfg.identity)
  val keyPem = match handle.keyPem {
    case Some(k) -> k
    // Std.Tls only ever constructs an Identity's handle via
    // hostIdentityFromPemBytes, which always populates keyPem — a
    // certificate-only handle can never reach here through Identity's
    // type (invariant violation, not a user-reachable error).
    case None -> panic("Std.TcpHost: TlsServerConfig.identity has no private key (invariant violation)")
  }
  val clientCaPem = match cfg.clientCa { case Some(ca) -> Tls.Certificate.rawHandle(ca).certPem; case None -> "" }
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
  val n = if c.tlsConnHandle != 0i64 { rtTlsWriteBytes(c.tlsConnHandle, bytes) } else { rtSockWriteBytes(c.fd, bytes) }
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

/// The raw file descriptor backing this connection. Exposed for a caller
/// (e.g. `Std.HttpServer`'s native twin) that needs to identify a specific
/// live `Conn` in its own registry -- matching by fd -- without holding the
/// whole `Conn` value past the point its natural owner (the thread that
/// will eventually `hostClose` it) still needs it.
pub func hostFd(c: in Conn): Int {
  c.fd
}

/// Interrupt a blocking `hostRead`/`hostWrite` in progress on this
/// connection FROM ANOTHER THREAD, without releasing the underlying
/// descriptor (that stays the owning thread's job, via `hostClose`). A raw
/// `shutdown(fd, SHUT_RDWR)`: works for both a plain and a TLS connection,
/// since it interrupts the underlying socket syscall a blocked
/// `recv()`/`SSL_read()` (etc.) is itself waiting on, regardless of any TLS
/// layered on top. The descriptor itself remains valid and must still be
/// `hostClose`'d by its owner -- this is a wake-up, not a close. Callers
/// coordinating a concurrent shutdown must ensure the fd has not ALREADY
/// been `hostClose`'d before calling this (a `shutdown()` racing a `close()`
/// on an already-reused fd is not safe); a mutex-protected active-connection
/// registry that the owning thread removes itself from strictly BEFORE its
/// own `hostClose` call (never after) gives exactly that guarantee.
pub func hostShutdown(c: in Conn): Unit {
  val _ = rtShutdown(c.fd, 2)
}

// =====================================================================
// Client TLS (N9.4, issue #6105).
// =====================================================================
@unsafe_ffi
func buildClientCtx(trust: in TlsClientTrust, minVersionNum: in Int): Result[Long, TcpError] {
  match trust {
    case TlsTrustInsecure -> {
      val emptyC = toC("")
      val ctx = rtTlsClientNew(emptyC, minVersionNum, 1)
      freeC(emptyC)
      if ctx != 0i64 {
        Ok(value = ctx)
      } else {
        Err(error = TlsHandshakeFailed(message = rtLastErrorString()))
      }
    }
    case TlsTrustSystemDefault -> {
      val emptyC = toC("")
      val ctx = rtTlsClientNew(emptyC, minVersionNum, 0)
      freeC(emptyC)
      if ctx != 0i64 {
        Ok(value = ctx)
      } else {
        Err(error = TlsHandshakeFailed(message = rtLastErrorString()))
      }
    }
    case TlsTrustExclusive(caPem) -> {
      val caC = toC(caPem)
      val ctx = rtTlsClientNew(caC, minVersionNum, 0)
      freeC(caC)
      if ctx != 0i64 {
        Ok(value = ctx)
      } else {
        Err(error = TlsHandshakeFailed(message = rtLastErrorString()))
      }
    }
    case TlsTrustAdditive(caPem) -> {
      val caC = toC(caPem)
      val ctx = rtTlsClientNewAdditive(caC, minVersionNum, 0)
      freeC(caC)
      if ctx != 0i64 {
        Ok(value = ctx)
      } else {
        Err(error = TlsHandshakeFailed(message = rtLastErrorString()))
      }
    }
  }
}

@unsafe_ffi
func applyClientIdentity(ctx: in Long, clientIdentity: in Option[Tls.Identity]): Result[Unit, TcpError] {
  match clientIdentity {
    case None -> Ok(value = ())
    case Some(id) -> {
      val handle: TlsHost.CertHandle = Tls.Identity.rawHandle(id)
      val keyPem = match handle.keyPem {
        case Some(k) -> k
        // Std.Tls only ever constructs an Identity's handle via
        // hostIdentityFromPemBytes, which always populates keyPem — a
        // certificate-only handle can never reach here through Identity's
        // type (invariant violation, not a user-reachable error). Mirrors
        // buildServerCtx's identical guard above.
        case None -> panic("Std.TcpHost: client Identity has no private key (invariant violation)")
      }
      val certC = toC(handle.certPem)
      val keyC = toC(keyPem)
      val rc = rtTlsClientSetIdentity(ctx, certC, keyC)
      freeC(keyC)
      freeC(certC)
      if rc == 0 {
        Ok(value = ())
      } else {
        Err(error = TlsHandshakeFailed(message = rtLastErrorString()))
      }
    }
  }
}

/// Dial `host`:`port` and terminate TLS on the connection as a client,
/// using `trust` for certificate verification, `clientIdentity` for mTLS
/// (`None` presents no client certificate), `minVersion` for the minimum
/// negotiated TLS protocol version, and `alpnCsv` to advertise ALPN
/// protocols (e.g. `"http/1.1"`; `""` disables ALPN). `host` is used for
/// BOTH the socket dial (`hostConnect`'s `getaddrinfo` resolution) and SNI
/// / RFC 6125 hostname verification — the ordinary case where the URL
/// authority names the peer directly. A connect failure is
/// `Err(TransportFailed(...))`; a handshake failure (including hostname
/// mismatch, or `TlsTrustInsecure` misuse — see the seam's own fail-closed
/// guard) is `Err(TlsHandshakeFailed(...))`.
pub func hostConnectTls(
  host: in String,
  port: in Int,
  trust: in TlsClientTrust,
  clientIdentity: in Option[Tls.Identity],
  minVersion: in Tls.TlsVersion,
  alpnCsv: in String,
): Result[Conn, TcpError] {
  match hostConnect(host, port) {
    case Err(e) -> Err(error = e)
    case Ok(plain) -> hostUpgradeClientTls(plain, host, trust, clientIdentity, minVersion, alpnCsv)
  }
}

/// Terminate TLS on an already-connected plain connection, as a client
/// (the connect/upgrade split mirrors `hostAcceptTls`/
/// `hostUpgradeServerTls`'s server-side shape). `sniHost` is the name sent
/// as SNI and verified against the peer's certificate (RFC 6125) — see
/// `hostConnectTls`'s doc comment for the ordinary case where it equals the
/// dial host. The underlying socket is closed on every failure path so a
/// rejected handshake never leaks a connection.
@unsafe_ffi
pub func hostUpgradeClientTls(
  conn: in Conn,
  sniHost: in String,
  trust: in TlsClientTrust,
  clientIdentity: in Option[Tls.Identity],
  minVersion: in Tls.TlsVersion,
  alpnCsv: in String,
): Result[Conn, TcpError] {
  val minVersionNum = tlsVersionNumber(minVersion)
  match buildClientCtx(trust, minVersionNum) {
    case Err(e) -> {
      val _ = rtSockClose(conn.fd)
      Err(error = e)
    }
    case Ok(ctx) -> match applyClientIdentity(ctx, clientIdentity) {
      case Err(e) -> {
        rtTlsCtxFree(ctx)
        val _ = rtSockClose(conn.fd)
        Err(error = e)
      }
      case Ok(_) -> {
        val sniC = toC(sniHost)
        val alpnC = toC(alpnCsv)
        val tlsConn = rtTlsClientConnect(ctx, conn.fd, sniC, alpnC)
        freeC(alpnC)
        freeC(sniC)
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
}
