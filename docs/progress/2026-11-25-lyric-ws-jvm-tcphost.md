# `Ws.startServer` on the JVM over `Std.TcpHost` (docs/73 slice S7a, D787)

Slice S7a of `docs/73-jvm-pure-lyric-server-plan.md`; the decision is `docs/decisions/D787-lyric-ws-jvm-over-tcphost.md`.

## What shipped

- `Ws.startServer*` on `--target jvm` is the pure-Lyric RFC 6455 server (`Ws.Kernel.Net`) that dotnet and native already ran. New `lyric-ws/src/_kernel/jvm/ws_prims.l` (`ReentrantLock` locks, virtual-thread `runBackground`, `Thread.sleep`, `catch Bug` handler isolation); the lock-guarded map moved from the native prims into `_kernel/net/ws_dict.l` and is shared by the JVM and native.
- `Ws.Kernel.Jvm` is cut from 921 to 745 lines: `startServer`, `createRegistry`, `checkRateLimit`, the Undertow server start and stop and their externs are gone. What remains is the Undertow endpoint `lyric-web` mounts for `Web.addWebSocket` on the JVM (`createEndpoint`, `endpointHandler`, the registry operations), because `lyric-web` still serves HTTP through Undertow until S4 and S6. **Not deleted, and `[maven]` stays in `lyric-ws/lyric.toml`: S7b does both.** `Ws` routes a `NativeRegistry` to the kernel that owns it by handle (the Undertow kernel's handles start at 1 000 000 000).
- Gains on the JVM: fragmented-message reassembly, automatic ping keepalive, strict UTF-8 validation and the rest of `Ws.Frame`'s checks (docs/62 Q-WS-001 is closed).
- #9335 (dotnet): `startServer` and `createEndpoint` raise the threadpool minimum (`ensureThreadCapacity`, `SetMinThreads(4096, 200)`). 1 000 of 1 000 clients now connect on the default configuration (below).
- Tests: `tests/ws_e2e_tests.l` (`Ws.WsE2eTests`, renamed from `ws_dotnet_e2e_tests.l`) runs on dotnet, the JVM and native, 11 tests: the original 8, a listed-and-unlisted-origin test, a 250-connection test (the #9335 regression test) and an endpoint-registry-versus-server-registry routing test. `tests/ws_jvm_origin_smoke.l`, `scripts/ci/lyric-ws-undertow-jvm-smoke.sh` and its `ci.yml` step are deleted (the step is removed in place, which frees bytes). `scripts/ci/jvm-ecosystem-suites.sh` no longer excludes the loopback suite on the JVM; `scripts/ci/native-web-smoke.sh` runs lyric-ws's loopback and codec suites on native.

## How it was verified

`make lyric` cannot finish in this container (the AOT step needs .NET 11, only the 10 SDK is installed). The toolchain is the v0.7.15 release compiler with `lib/std` replaced by this tree's `lyric-stdlib/std`; the dotnet runs link v0.7.15's `Lyric.Stdlib.dll` (this change does not touch the stdlib, so that bundle is enough; it predates D621's `TCP_NODELAY`, which does not matter to a WebSocket test). `lyric fmt` is v0.7.15's.

| Run | Result |
|---|---|
| `--target dotnet`, whole `lyric-ws` manifest | 5 suites passed: `WsTests` 6, `WsFrameTests` 28, `WsHandshakeTests` 18, `WsE2eTests` 11, `WsSecurityAspectWeavingTests` 6 |
| `--target jvm --no-default-features --features jvm`, whole manifest (Maven restored for the Undertow endpoint) | the same 5 suites passed |
| `--target native --no-default-features --features native`, `WsTests`, `WsFrameTests`, `WsHandshakeTests`, `WsE2eTests` | 4 suites passed (the throwing-handler check is a no-op on native). `WsSecurityAspectWeavingTests` does not build on native: `A0045`, cross-package aspect templates, the existing #3498 limit, same before this change |
| `lyric-web` `Web.DispatchTests` on `--target jvm` | 44 passed (compiles `lyric-web`'s Undertow kernel against the reduced `Ws.Kernel.Jvm`) |

Not run: `lyric-web`'s `Web.WebSocketTests` (gated off on the JVM by `@cfg`, so there is no in-tree JVM test of `Web.addWebSocket` but the UI browser end to end); `scripts/ci/ui-jvm-suites.sh` and its headless-Chromium run (no Chromium here); the three CI scripts as scripts (`native-web-smoke.sh` needs a built `lyric-rt` and `examples/native-web`; its new last lines run the same command that passed by hand). The regression test for #9335 was observed red before the change only as a hang (over three minutes, then killed), not as a clean failure; it passes in 5 s after.

## B7 (1 000 clients, 1 KiB broadcast at 10 Hz for 30 s, clients on the JVM)

One run each, one shared 4-core container, `benchmarks/http_server/ws_server.l` and `ws_clients.l`. The Undertow column is S0's.

| | dotnet, default pool (S0) | dotnet, pool minimum 1 500 (S0) | dotnet, this change | JVM pure Lyric, this change | JVM pure Lyric, `-Xmx256m` | Undertow (S0) |
|---|---|---|---|---|---|---|
| connected of 1 000 | 125 | 999 | 1 000 | 1 000 | 999 (1 failed) | 997 |
| delivery p50 / p99 / max ms | 1 / 2 / 62 (125 clients) | 7 / 49 / 87 | 8 / 62 / 131 | 13 / 42 / 197 | 12 / 85 / 247 | 33 / 76 / 421 |
| messages per connection min / max | - | 15 / 299 | 289 / 299 | 286 / 298 | 286 / 297 | 293 / 294 |
| server RSS max, threads max | 92, 81 | 240, 1 545 | not sampled | 453 MB, 31 | 224 MB, 31 | 233 MB, 27 |

Against D780's B7 gate (all connect, no message loss, p99 within 2x of Undertow's, 76 ms so at most 152 ms): the JVM server connects 1 000 of 1 000 and its p99 is 42 ms. "No message loss" is not shown by these figures: the spread of 286 to 298 messages per connection is the handshake ramp (late joiners see fewer broadcasts), the same as the dotnet rows, and the client reports no per-connection gap count; Undertow's 293 / 294 came from a ramp that finished earlier. RSS is not in the B7 gate; at the default heap the server grows to 453 MB, with `-Xmx256m` it ran in 224 MB (one connect failure in that run, not reproduced and not investigated), so the live set is small and the default figure is a lazy heap. The 1 000-connection p99 includes the serial 1 000-connection broadcast loop, so slow-consumer handling (S8) is the lever for tail latency.

## Findings (issue texts below are for this session's report; none is filed)

- **dotnet `lyric-ws` threadpool (#9335):** fixed by this change.
- **A test that depends on the server making progress hangs instead of failing** when the dotnet threadpool is starved: the 250-connection test, run against the unfixed kernel, did not finish in over three minutes although every client read has a 5 s timeout. Not root-caused; the server side and `hostSetIoTimeout` on dotnet are the suspects. The test passes in 5 s with the fix.
- **`lyric-ws/lyric.toml` declares no `[package] targets`** although it builds and runs on dotnet, the JVM and native; `ecosystem-library` CLAUDE.md rule 3 wants it. Not added here: whether to claim native depends on the aspect-template gap (`A0045`), a decision outside this slice.
