# lyric-grpc: the pure-Lyric server on both targets (docs/72 slice 8)

Slice 8 of `docs/72-h2-client-role-plan.md`. Decision: D804.

## What shipped

- `Grpc.Server` (`lyric-grpc/src/server.l`): the D287 dotnet h2c server made portable (`Std.TcpHost`, `Std.HttpEngine.H2Conn`, `Std.HttpServerHost`), replacing the grpc-java `Server` on the JVM, which is deleted. `Grpc.start`, `startHandle`, `startHandleAt`, `serverPort` and `stop` call it on both targets.
- TLS (`Grpc.startHandleTlsAt`, `Grpc.startTls`), gzip request decode with a bounded output, `grpc-timeout` enforcement (`Grpc.Wire.parseTimeout`, `Grpc.requestTimeoutMs`) and handler panic isolation on the JVM as well as dotnet.
- Tests: `server_h2_tests.l` (22, both targets), `server_interop_jvm_tests.l` (grpc-java client, 6), `server_interop_dotnet_tests.l` (`Grpc.Net.Client`, 6), `wire_tests.l` +2 (`parseTimeout`); `server_dotnet_tests.l` became `server_connection_tests.l` and runs on both targets.
- Docs: `lyric-grpc/README.md`, `docs/72` (header, slice row, status paragraph), `CLAUDE.md`, the book's lyric-grpc section and matrix row.

## Not done

- grpc-java and `Grpc.Net.Client` over TLS, and mutual TLS with a real client certificate (no fixture with a client leaf certificate).
- Native (slice 7), client and bidirectional streaming (slice 9), removal of the SDK kernels (slice 10).

## Findings

- dotnet: a Task.Run-based deadline watcher starves behind blocking handlers unless the thread pool minimum is raised (`ensureThreadCapacity`); the D287 server never needed it because nothing waited on a second task.

## Verification

Container without Docker; toolchain `cp -r /home/user/tc-72-s6 /home/user/tc-72-s8` (stdlib bundle already rebuilt from the tree for slice 5; no stdlib file changed here), `LYRIC_STD_PATH` at the worktree.

```
source /home/user/tc-72-s8/env.sh
$LYRIC restore --manifest lyric-grpc/lyric.toml
$LYRIC test --manifest lyric-grpc/lyric.toml                                                       # dotnet
env -u JAVA_TOOL_OPTIONS $LYRIC test --manifest lyric-grpc/lyric.toml --target jvm --no-default-features --features jvm
$LYRIC test --manifest lyric-grpc/lyric.toml --no-default-features --features dotnet,legacy-client
env -u JAVA_TOOL_OPTIONS $LYRIC test --manifest lyric-grpc/lyric.toml --target jvm --no-default-features --features jvm,legacy-client
bash scripts/audit-axioms.sh; bash scripts/audit-kernel-stubs.sh; bash scripts/ci/check-workflow-size.sh
```

| suite | dotnet | JVM | dotnet `legacy-client` | JVM `legacy-client` |
|---|---|---|---|---|
| `grpc_types_tests` | 25/25 | 25/25 | 25/25 | 25/25 |
| `server_tests` | 13/13 | 13/13 | 13/13 | 13/13 |
| `server_connection_tests` | 2/2 | 2/2 | 2/2 | 2/2 |
| `server_h2_tests` (new) | 22/22 | 22/22 | gated off | gated off |
| `server_interop_dotnet_tests` (new, `Grpc.Net.Client`) | 6/6 | n/a | 6/6 | n/a |
| `server_interop_jvm_tests` (new, grpc-java) | n/a | 6/6 | n/a | 6/6 |
| `wire_tests` | 15/15 | 15/15 | 15/15 | 15/15 |
| `client_h2_tests`, `client_dotnet_tests` / `client_jvm_tests`, `rate_limit*`, `channel_lifecycle`, `security_aspect_weaving` | pass | pass | pass | pass |

`audit-axioms.sh` clean (.NET=42, JVM=34), `audit-kernel-stubs.sh` clean, `check-workflow-size.sh` 489801 bytes; `lyric fmt --write` ran over every changed `.l` file with no refusal. Native not run (the slice does not claim it).

The JVM `legacy-client` run found the missing GOAWAY on `stop`: the grpc-java client reported an unrelated code for a connection closed without one in about two of three runs, passing four of four after the fix.
