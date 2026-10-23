# Sockets and TLS on the Windows native target (D209, #8434)

`Std.Tcp`, `Std.Tls`, `Std.Http` and `Std.HttpServer` now work on `--target native --triple x86_64-pc-windows-msvc`.

- `lyric-rt/src/lyric_sock_win32.c`: the `lyric_sock_*` surface over Winsock 2 (non-inheritable sockets,
  `SO_EXCLUSIVEADDRUSE` listeners, a loopback socket pair for the interruptible accept, WSA error messages).
- `lyric-rt/src/lyric_tls_win32.c`: the `lyric_tls_*` seam over Schannel. PEM certificates and PKCS#8 keys go
  through CryptoAPI and CNG; contexts persist their key under a unique name in the user's key store and delete it
  when freed or at exit. Server certificates are verified by the runtime with `CertGetCertificateChain` and the SSL
  policy (system, exclusive or additive trust), and IP-literal hosts are matched against iPAddress names. The seam
  also covers mutual TLS, ALPN, TLS 1.2/1.3 through `SCH_CREDENTIALS` (with a TLS 1.2 `SCHANNEL_CRED` fallback),
  and TLS 1.3 post-handshake messages.
- Both replace `lyric_net_unsupported.c` in the Windows build (Makefile and CMake), which is now wasm32-only. The
  link adds `ws2_32`, `secur32`, `crypt32` and `ncrypt` (lyric-rt's `WIN_LIBS` and `llvm_bridge.l`'s
  `windowsSystemLibs`).
- `lyric-rt/test/lyric_tls_test.c` builds on Windows and runs in CTest there; its threads, sleeps and clock now use
  lyric-rt's portable calls (and `make test-asan` links `lyric_posix.c` for them).
- `scripts/ci/windows-native-e2e.sh` gains a Lyric TCP and HTTPS program.
- docs/61 §7 records the Windows seam.

Verified locally under wine (clang 18, xwin): the socket tests, and the Schannel client against an `openssl
s_server` with exclusive, additive, system and insecure trust, hostname and IP matching, and ALPN. Wine's CNG cannot
import PKCS#8 keys, so the server half runs only on the Windows CI job. On Linux, `make -C lyric-rt test` and
`make test-asan CC=gcc` pass. Found along the way: a peer that closes early can kill a Linux or macOS native
server with SIGPIPE (#8460).
