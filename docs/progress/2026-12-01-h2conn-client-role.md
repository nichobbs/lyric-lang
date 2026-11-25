# `Std.HttpEngine.H2Conn` client role (docs/72 slice 1)

Slice 1 of `docs/72-h2-client-role-plan.md`. Decision: D797 (`docs/decisions/D797-h2conn-gets-a-client-role.md`).

## What shipped

- `newClientConnection` / `newClientConnectionAt` / `clientInitialBytes` / `h2DefaultClientSettings`, and `H2Role`, `H2RoleState` (13-field `H2Connection`, #6089), `H2HeaderPhase`.
- `openStream` with `H2OpenError`, `encodeRequestTrailers`, `sendPing`, `isH2RequestHeaderListSafe`, `malformedResponseReason`, the queries `connectionRole`, `nextLocalStreamId`, `peerMaxConcurrentStreams`, `peerGoAwayLastStreamId`.
- Events `H2InformationalHeaders`, `H2ResponseHeaders`, `H2ResponseData`, `H2ResponseTrailers`, `H2StreamUnprocessed`; client GOAWAY semantics; Rapid Reset accounting gated to the server; role-specific PUSH_PROMISE, idle-id and first-frame handling; closed-stream pruning anchored on the last allocated id.
- `lyric-stdlib/tests/http_h2conn_client_tests.l` (70 tests: loopback in both directions, a negative matrix of hand-built server bytes, the validator tables, and the RFC 9113 client conformance table in its header). `scripts/ci/h2conn-tests.sh` runs it and the server corpus on dotnet and JVM from the two existing ci.yml steps (`ci.yml` shrank by 173 bytes).
- `Std.HttpServer`'s `processH2Event` got no-op arms for the new events (the only exhaustive match over `H2Event`); server behaviour is unchanged.

## Verification

Container without Docker; `make lyric` does not finish here. Toolchain: a private copy of the v0.7.15 release (`cp -r /home/user/tc-s8 /home/user/tc-72-1`), with the stdlib bundle rebuilt from the tree, because dotnet tests link the prebuilt `Lyric.Stdlib.dll`:

```
source /home/user/tc-72-1/env.sh        # LYRIC_STD_PATH points at the worktree's lyric-stdlib/std
$LYRIC build --manifest lyric-stdlib/lyric.full.toml -o <dir>/Lyric.Stdlib.dll --target dotnet --no-restore
cp <dir>/Lyric.Stdlib.dll /home/user/tc-72-1/bin/lib/Lyric.Stdlib.dll
$LYRIC test lyric-stdlib/tests/<file>.l                                   # dotnet
env -u JAVA_TOOL_OPTIONS $LYRIC test --target jvm lyric-stdlib/tests/<file>.l
$LYRIC restore --manifest lyric-grpc/lyric.toml && $LYRIC test --manifest lyric-grpc/lyric.toml
```

| suite | dotnet | JVM |
|---|---|---|
| `http_h2conn_tests` (unmodified) | 82/82 | 82/82 |
| `http_h2conn_client_tests` (new) | 70/70 | 70/70 |
| `http_h2frame_tests` | 70/70 | 70/70 |
| `http_server_tests` | 35/35 | 35/35 |
| `http_server_host_tests` | 15/15 | 15/15 |
| `http_server_stop_tests` | 13/13 | 13/13 |
| `lyric-grpc` (7 suites, server and client) | 7 passed, 0 failed | not run |

Also run: both h2conn suites on `--target native` (82/82 and 70/70, clang present), `scripts/audit-axioms.sh`, `scripts/audit-kernel-stubs.sh` and `scripts/ci/check-workflow-size.sh` (all clean), and `lyric fmt --write` on the three changed `.l` files.

Not run: the lyric-grpc JVM suites (grpc-java needs the Maven resolver and a JVM server fixture; the slice does not touch them), interop against a real h2 server (slice 5), the `claude-review` workflow.
