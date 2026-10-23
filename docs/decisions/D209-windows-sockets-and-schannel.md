# D209 - Sockets and TLS on the Windows native target: Winsock and Schannel

**Status:** accepted, implemented (docs/67 phase G9, #8434; extends D205, D128 decision 10)

## Decision

On `x86_64-pc-windows-msvc`, `lyric_sock_win32.c` and `lyric_tls_win32.c` replace `lyric_tls.c` (and
`lyric_net_unsupported.c`). They implement the `lyric_sock_*` and `lyric_tls_*` seam of docs/61 §7 with the
contracts in `lyric_rt.h`, so `Std.Tcp`, `Std.Tls`, `Std.Http` and `Std.HttpServer` work on Windows with no Lyric
change.

1. **TLS is Schannel, not OpenSSL.** Windows ships no OpenSSL, and OpenSSL does not read the Windows certificate
   store, so an OpenSSL seam would need every program to bundle two DLLs and a CA bundle before default HTTPS
   verification could work. Schannel is part of Windows, is patched by Windows Update, trusts what the system
   trusts, and is what .NET's `SslStream` uses there, so `--target native` and `--target dotnet` agree on Windows.
   D128 decision 10 already designed the seam to be swapped per platform; this is that swap.
2. **Sockets are Winsock 2.** A `SOCKET` is a kernel handle and Windows guarantees handles fit in 32 bits, so the
   runtime's `int32_t` descriptors carry it unchanged (`INVALID_SOCKET` is -1); they are only ever passed back
   to `lyric_sock_*` and `lyric_tls_*`. Sockets are created non-inheritable. Winsock starts once per process. A
   listener binds with `SO_EXCLUSIVEADDRUSE`, because `SO_REUSEADDR` on Windows lets another socket take over the
   port. The interruptible accept's wake pipe is a connected pair of loopback sockets (checked to be each other's
   peer), since `WSAPoll` waits only on sockets. Errors come from `WSAGetLastError` with system messages, and
   `lyric_sock_accept_errno` reports the WSA code.
3. **Keys are imported for the LSA.** Schannel opens private keys in the LSA process, which cannot use an
   in-memory CNG key, so a context's PKCS#8 key is imported into the Microsoft Software Key Storage Provider
   under a unique per-process name and attached to the certificate through `CERT_KEY_PROV_INFO_PROP_ID`. The key
   is deleted when the context is freed and, for any context still open, at normal exit; a process that is
   killed leaves its keys behind in the user's key store. Validation (`Certificate.fromPem`,
   `Identity.fromPem`) imports an ephemeral key and compares its public half with the certificate's.
4. **The runtime verifies server certificates.** Schannel's own checks are off (`SCH_CRED_MANUAL_CRED_VALIDATION`).
   After the handshake the presented chain is built with `CertGetCertificateChain`: against the Windows roots
   (system trust), against only the caller's anchors (a chain engine with an exclusive root store), or against
   either (additive trust). The chain's own status must be clean and the SSL policy must pass, which matches the
   host name. An IP-literal host is not sent as SNI (RFC 6066) and is matched against the certificate's iPAddress
   names by the runtime, so every Windows release behaves alike. Revocation is not checked, as in the OpenSSL
   seam.
5. **Mutual TLS.** A server with a client CA names it to Schannel as `hRootStore` (the issuer list it sends and
   the roots it accepts) and requests a client certificate; once the handshake completes the runtime checks the
   presented chain against those anchors with the client-authentication policy, and refuses the connection when
   the certificate is missing and required, or does not chain. A client certificate is sent only when one was
   set (`ISC_REQ_USE_SUPPLIED_CREDS`). A client context's connections share its credential, so
   `lyric_tls_client_set_identity` must come before the first connection and fails after it; the OpenSSL twin
   enforces the same rule, so the seam has one contract.
6. **Versions and ALPN.** Contexts use `SCH_CREDENTIALS` with every protocol but TLS 1.2 and 1.3 (or 1.3 only)
   disabled; a Windows release that predates `SCH_CREDENTIALS` falls back to `SCHANNEL_CRED` with TLS 1.2. TLS 1.3
   needs a release whose Schannel offers it (Windows 11, Server 2022); a TLS 1.3-only context reports that when
   credentials cannot be acquired. ALPN goes through `SECBUFFER_APPLICATION_PROTOCOLS`, and the server picks by
   its own preference order. A client whose offer shares no protocol with the server's list is refused with a
   `no_application_protocol` alert, as RFC 7301 §3.2 requires; the OpenSSL twin completes such a handshake with
   no protocol, and Schannel offers no way to do the same. A client that offers no ALPN at all is unaffected.
7. **Records.** Reads decrypt in place and keep any unconsumed bytes for the next call; TLS 1.3 post-handshake
   messages (session tickets, key updates), which `DecryptMessage` hands back as `SEC_I_RENEGOTIATE`, are fed to
   the handshake function, across reads when they span records. A close_notify or the peer closing the
   connection reads as end of stream (`lyric_rt.h`'s contract). Writes are split at the stream's maximum message
   size. A socket timeout surfaces as `timed out`; Windows leaves a socket whose read timed out in an
   indeterminate state, and the kernels close such a connection.

## Rationale

The OpenSSL route would have reused `lyric_tls.c` almost unchanged, but it fails the production bar on Windows:
HTTPS to any public site would not verify without a CA bundle the program has to ship and keep current, and every
program would carry OpenSSL DLLs whose security updates are its own problem. Schannel costs a second seam, and its
behaviour is pinned to the OpenSSL seam's by running the same `lyric_tls_test.c` on both.

## Test

`lyric-rt/test/lyric_tls_test.c` now builds on Windows too (its threads, sleeps and clock moved to lyric-rt's
portable calls; only the OpenSSL-specific CVE-2024-5535 guard test stays POSIX-only). It runs on the Windows CI
job through CTest: plain sockets, peer strings, byte bridging, read timeouts, the interruptible accept (normal,
woken, pre-signalled, double-signalled), and every TLS scenario (server auth with ALPN, a server chain, a
multi-anchor bundle, additive trust, the TLS 1.3 floor, mutual TLS accepted and refused, hostname mismatch,
empty host refused, insecure skip, no ALPN overlap, PEM validation, handshake and read timeouts).
`scripts/ci/windows-native-e2e.sh` adds a Lyric program: a TCP round trip, an HTTPS request to a
`Std.HttpServer` TLS listener from a client thread trusting only the test CA, and the same server refused under
system trust.
