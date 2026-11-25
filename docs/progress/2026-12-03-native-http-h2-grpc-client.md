# Native `Std.Http` over h2, and the gRPC client on native (docs/72 slice 7)

Slice 7 of `docs/72-h2-client-role-plan.md`. Decision: D803.

## What shipped

- `Std.HttpEngine.H2Client.h2ConnectOn(transport, opts)`: `h2Connect`'s tail (preface, FSM, reader) on an already-established connection; `h2Connect` itself is unchanged in behaviour.
- `_kernel_native/http_host.l`: ALPN `h2,http/1.1` on `https` (`http/1.1` only when pinned), one connection either way: `h2` goes to `H2Client`, anything else to the existing HTTP/1.1 client on the same connection. Request header mapping, buffered response under the HTTP/1.1 caps, `versionMajor` 2, the D605 deadline and `cancelSource` semantics over h2 (the latter through a 5 ms watcher), redirects through the existing loop. The module header's items 1, 2 and 5 are rewritten.
- `lyric-grpc` `native` feature: the pure-Lyric client builds and passes on native. `startHandle` and `server_tests.l` are gated `not(feature = "native")`; slice 8 removes the gates with its portable server.
- Tests: `http_client_h2_native_tests.l` (10: GET, Http11 pin, 300 KB POST, 1 MiB response, request header, redirect, 4 concurrent sends, deadline, `cancelSource`, in-deadline response; against `Std.HttpServer` over TLS) and `http_client_h2_interop_tests.l` (4: nghttpd GET, 404, 5 MiB; `openssl s_server -WWW` without ALPN falls back to HTTP/1.x), started by the new `scripts/ci/native-h2-client-interop.sh`. All wired into `scripts/ci/native-backend-self-tests.sh` (ci.yml untouched), together with `http_h2client_tests.l` and the gRPC native run.
- `http_timeout_native_tests.l` and the two https clients of `llvm_http_client_self_test.l` now pin HTTP/1.1: their raw TLS peers speak HTTP/1.1 and the shared TLS server context answers an `h2,http/1.1` offer with `h2`.

## Not done

- **The native gRPC server.** Slice 8's portable server is the one to run on native; building a second, native-only one here would be discarded. Until then the server surface, `checkRateLimit` and `Grpc.Aspects` are not part of the native build.
- Connection reuse (one connection per request, as before), prior-knowledge h2c from `Std.Http`.
- An ASan run of the h2 path (the repo's ASan lane is the compiler-hosted `llvm_*` suite, not available here).
- `llvm_http_client_self_test.l` (needs the compiler bundle), the AOT-binary CI steps, the Windows native lane.

## Findings (not fixed here)

- dotnet `Std.Http`: `send`/`sendWithCancel` negotiate HTTP/1.1 against an h2 server where `get`/`post` negotiate h2.
- JVM `Std.Http`: `sendWithCancel` is not ended by `cancelSource` from another thread (the late response is returned); dotnet reports that case as `HttpError.Timeout`.
- `var out = ...` fails with a cascade of `I0001 ... EError has no type and no error was reported` (`out` is a keyword; no diagnostic names it).

## Verification

Container without Docker; toolchain `cp -r /home/user/tc-s8 /home/user/tc-72-s7` (env.sh pointed at the copy and the worktree), stdlib bundle rebuilt from the tree for the dotnet runs:

```
source /home/user/tc-72-s7/env.sh        # PATH to nghttpd: apt-get download nghttp2-server, dpkg -x, add usr/sbin
$LYRIC build --manifest lyric-stdlib/lyric.full.toml -o <dir>/Lyric.Stdlib.dll --target dotnet --no-restore
cp <dir>/Lyric.Stdlib.dll /home/user/tc-72-s7/bin/lib/Lyric.Stdlib.dll
$LYRIC test --target native lyric-stdlib/tests/http_client_h2_native_tests.l
LYRIC=$LYRIC bash scripts/ci/native-h2-client-interop.sh
$LYRIC test --target native lyric-stdlib/tests/http_timeout_native_tests.l   # and http_h2client_tests, http_timeout_tests, tls_tests, http_server_host_tests
$LYRIC test --manifest lyric-grpc/lyric.toml --target native --no-default-features --features native
$LYRIC test lyric-stdlib/tests/http_h2client_tests.l; env -u JAVA_TOOL_OPTIONS $LYRIC test --target jvm lyric-stdlib/tests/http_h2client_tests.l
$LYRIC test --manifest lyric-grpc/lyric.toml; env -u JAVA_TOOL_OPTIONS $LYRIC test --manifest lyric-grpc/lyric.toml --target jvm --no-default-features --features jvm
```

| suite | native | dotnet | JVM |
|---|---|---|---|
| `http_client_h2_native_tests` (new) | 10/10 | n/a (native only) | n/a |
| `http_client_h2_interop_tests` (new) | 4/4 | n/a | n/a |
| `http_timeout_native_tests` | 21/21 | n/a | n/a |
| `http_h2client_tests` | 23/23 | 23/23 | 23/23 |
| `http_timeout_tests`, `tls_tests`, `http_server_host_tests` | 3/3, 30/30, 15/15 | not run | not run |
| lyric-grpc manifest (types 25, wire 13, client_h2 32) | 70/70 | 9 packages passed (types 25, security 4, rate limit 8, lifecycle 12, client 12, server 13, server dotnet 2, wire 13, client_h2 32) | 6 packages passed (types 25, client 12, server 13, rate limit 5, wire 13, client_h2 32) |
| `http_h2conn_client_tests` | not run | 70/70 | not run |

`scripts/audit-axioms.sh`, `scripts/audit-kernel-stubs.sh` clean; `check-workflow-size.sh` 489801 bytes (ci.yml unchanged); `lyric fmt --write` run over every changed `.l` file.
