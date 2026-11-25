# `Std.HttpEngine.H2Client`: the pure-Lyric HTTP/2 client driver (docs/72 slice 5)

Slice 5 of `docs/72-h2-client-role-plan.md`. Decision: D800 (which also records the OQ-7 concurrency contract).

## What shipped

- `lyric-stdlib/std/http_h2client.l` (`Std.HttpEngine.H2Client`), no extern, one implementation for dotnet, the JVM and native: `h2Connect` (h2c prior knowledge, or TLS offering only `h2`, `H2ConnectAlpnNotH2` otherwise), `h2StartCall`, `h2SendBody`, `h2NextEvent`, `h2Cancel`, `h2Close`, and the status queries.
- A reader task per connection (`Std.HttpServerHost.startTask`), one lock per connection covering the FSM, the call table and every write, a mailbox per call, WINDOW_UPDATE credit (connection window on receipt, stream window as the consumer reads), sending that honours the peer's windows and blocks on an empty one, per-call deadlines (RST_STREAM CANCEL, the connection survives), cancel from any thread, GOAWAY (unprocessed streams are retry safe, new calls refused, a drained connection closes itself), keepalive PING only when configured, and `h2Close` that interrupts a blocked read through `hostShutdown` independently of the poll interval.
- Registered in `lyric.full.toml` and `STABILITY.md`; the tests are run by `scripts/ci/h2conn-tests.sh` (already a ci.yml step per target, so the workflow file did not change).

## Tests

`lyric-stdlib/tests/http_h2client_tests.l` (23 tests): unary call with trailers, Trailers-Only, 1xx, 8 concurrent calls multiplexed, request body held at the peer's window until it grants, slow-consumer backpressure (the peer observes the stream window stay shut, then the 1 MB body arrives intact), deadline (and the connection serves a later call), cancel from another thread, GOAWAY (unprocessed, draining, in-flight call completes, self-close), REFUSED_STREAM and other resets, peer closing mid-response, stalled peer with a deadline, stalled peer with an unanswered keepalive PING, live peer answering PINGs, close interrupting a blocked read with a 60 s poll interval, connect refused, a protocol violation, and the real `Std.HttpServer` over TLS+ALPN (GET, 1 MiB request body, 6 concurrent calls, untrusted certificate).

`lyric-stdlib/tests/http_h2client_interop_tests.l` (6 tests) against `nghttpd` 1.59 (h2c and TLS+ALPN): small GET, 404, a 5 MiB body, 8 concurrent GETs on one TLS connection.

## Verification

Container without Docker; `make lyric` does not finish here. Toolchain: a private copy of the release (`cp -r /home/user/tc-s8 /home/user/tc-72-5`), with the stdlib bundle rebuilt from the tree because dotnet tests link the prebuilt `Lyric.Stdlib.dll`:

```
source /home/user/tc-72-5/env.sh        # LYRIC_STD_PATH points at the worktree's lyric-stdlib/std
$LYRIC build --manifest lyric-stdlib/lyric.full.toml -o <dir>/Lyric.Stdlib.dll --target dotnet --no-restore
cp <dir>/Lyric.Stdlib.dll /home/user/tc-72-5/bin/lib/Lyric.Stdlib.dll
$LYRIC test lyric-stdlib/tests/http_h2client_tests.l                          # dotnet
env -u JAVA_TOOL_OPTIONS $LYRIC test --target jvm lyric-stdlib/tests/http_h2client_tests.l
$LYRIC test --target native lyric-stdlib/tests/http_h2client_tests.l
# interop: nghttpd from `apt-get download nghttp2-server` (dpkg -x, no install); two listeners, a document root with
# index.html and a 5 MiB big.bin, a self-signed localhost certificate; then, with the LYRIC_NGHTTPD_* variables of
# scripts/ci/h2conn-tests.sh set, the same three commands on http_h2client_interop_tests.l
```

| suite | dotnet | JVM | native |
|---|---|---|---|
| `http_h2client_tests` (new) | 23/23 | 23/23 | 23/23 |
| `http_h2client_interop_tests` (new, nghttpd) | 6/6 | 6/6 | 6/6 |
| `http_h2conn_tests` (unmodified) | 82/82 | 82/82 | not run |
| `http_h2conn_client_tests` | 70/70 | 70/70 | not run |
| `http_h2frame_tests` | 70/70 | 70/70 | not run |
| `http_server_tests` | 35/35 | 35/35 | not run |
| `http_server_host_tests` | 15/15 | 15/15 | not run |
| `tcp_host_tls_tests` | 28/28 | 28/28 | not run |

Also run: `scripts/audit-axioms.sh`, `scripts/audit-kernel-stubs.sh`, `scripts/ci/check-workflow-size.sh` (ci.yml unchanged, 489801 bytes), and `lyric fmt --write` on the three new `.l` files.

Not run: `scripts/ci/h2conn-tests.sh` itself (it needs the AOT binary and `.bootstrap/stage1`; its nghttpd setup commands were run by hand as above), the `claude-review` workflow, and an ALPN-mismatch test (`H2ConnectAlpnNotH2`): `Std.TcpHost`'s server always selects `h2` for a client that offers only `h2`, and no fixture here refuses ALPN.
