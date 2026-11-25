# Client TLS with ALPN in `Std.TcpHost` on every target, shared `TlsClientTrust`, `hostReadDeadline` (docs/72 slice 4, 4b)

Slice 4 of `docs/72-h2-client-role-plan.md`. Decision: D799.

## What shipped

- `hostConnectTls` / `hostUpgradeClientTls` with identical signatures on dotnet (`SslStream.AuthenticateAsClient`), the JVM (`SSLSocket`) and native; native gained a trailing `connectTimeoutMs` on `hostConnectTls` and normalises the ALPN offer list and rejects an unparseable trust PEM as `TlsConfigInvalid`, as the other two do.
- `TlsClientTrust` moved from the native kernel to `Std.Tls` (OQ-8); every caller updated (native `Std.HttpHost`, `lyric-ws` and compiler self tests).
- OQ-3 resolved without a fallback: dotnet's insecure mode is callback-free (`CertificateChainPolicy`, `VerificationFlags = AllFlags`) and accepts an unknown CA, an expired certificate and a certificate for another name (tested).
- Hostname verification is tested on every target (a certificate that chains to the pinned CA but names `other.example` is refused). On the JVM it is the explicit endpoint identification algorithm; a mutation run (parameter forced off) fails exactly that test.
- JVM client `SSLContext` construction moved from `_kernel_jvm/http_host.l` into `_kernel_jvm/tls_client_context.l` (`Std.TlsClientContext`), used by both `Std.HttpHost` and `Std.TcpHost`.
- `hostReadDeadline(conn, maxBytes, deadlineNanos)` (4b) on every target; after a passed deadline the connection (plain and TLS) is intact (tested).
- `tests/tcp_host_tls_tests.l`: 19 new tests (client success, ALPN h2 / http/1.1 / no overlap, hostname mismatch, SNI host vs dial host, expired, untrusted, system trust, additive/exclusive, mTLS identity and its absence, TLS 1.3 floor, malformed trust PEM, refused connect, insecure, three deadline-read tests). The file is now native-compilable (the `AcceptFailed` message test is per target). The WebSocket-over-TLS test in `lyric-ws/tests/ws_hardening_tests.l`, native-only in D794, now runs on dotnet too.

## Verification

Toolchain: copy of the S8 toolchain (`/home/user/tc-72-4`), `LYRIC_STD_PATH` at the tree, dotnet bundle rebuilt from the tree: `lyric build --manifest lyric-stdlib/lyric.full.toml -o /home/user/tc-72-4/bin/lib/Lyric.Stdlib.dll --target dotnet --no-restore` (31 s). Commands: `lyric test lyric-stdlib/tests/<f>.l`; `env -u JAVA_TOOL_OPTIONS lyric test --target jvm <f>`; `lyric test --target native <f> --filter <name>`.

| suite | dotnet | JVM | native |
|---|---|---|---|
| `tcp_host_tls_tests` | 28/28 | 28/28 | all 19 client tests and the plain, server-TLS, TLS 1.3, shutdown and bind tests pass (run per `--filter`); the two older `mTLS` tests hang on native (see below) |
| `http_tls_client_tests` | 13 | 13 | not run |
| `tcp_host_tests` | 16 | 16 | not run |
| `http_server_tests` | 35 | 35 | not run |
| `http_h2conn_tests` | 82 | 82 | not run |
| `tls_tests` | 30 | 30 | not run |
| `tls_server_jvm_tests` / `http_tests` | n/a | 6 / 15 | not run |
| `lyric-ws` `wss` tests | 6 (13 listed) | cannot build here (Undertow jars) | not run |

Platform trust was checked with `SSL_CERT_FILE` (dotnet) and `-Djavax.net.ssl.trustStore` (JVM) naming the test CA: system default trusts it, additive with another CA still trusts it, exclusive does not. `scripts/audit-axioms.sh`, `audit-kernel-stubs.sh`, `ci/check-workflow-size.sh` (490692) pass; `docs/17` section 18 updated. All changed `.l` files formatted with the toolchain's `lyric fmt --write` (release compiler's formatter, not the tree's).

## Not verified / findings

- The compiler self tests whose embedded programs call `hostConnectTls` (`llvm_http_server_self_test`, `llvm_wasm32_self_test`, `llvm_enum_case_resolve_self_test`) were edited but not run.
- On native the two pre-existing `mTLS` server tests in `tcp_host_tls_tests.l` (via `Std.Http`'s native client) hang; that file was never run on native before. Needs an issue.
- Windows (`lyric_tls_win32.c`) was not touched or tested.
