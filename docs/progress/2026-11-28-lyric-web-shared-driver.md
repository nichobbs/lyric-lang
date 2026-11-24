# lyric-web serves through the shared HTTP server driver on every target (docs/73 slice S6, D791)

Slice S6 of `docs/73-jvm-pure-lyric-server-plan.md`; decision, measured table and the list of what S7b and S9 still own are in `docs/decisions/D791-lyric-web-on-the-shared-http-server-driver.md`.

## What shipped

- `lyric-web/src/web.l`: the 39 `@cfg(any(dotnet, native))` annotations of the serve section are deleted, the JVM-only `serve` and `serveTls` are gone, the accept loops use `tryNextContext` and an `AcceptState` so `serve` returns when the listener stops (exit code 1 after a listener failure). The stale #5903 comment is replaced.
- `lyric-web/src/_kernel/jvm/web_kernel.l` (541 lines, 22 Undertow extern types) deleted; `net/web_kernel.l` now compiles on dotnet, the JVM and native; `net/web_prims.l` on dotnet and the JVM. `[maven]` removed from `lyric-web/lyric.toml`.
- `lyric-ws/src/ws.l`: `kernelCreateEndpoint` allocates `Ws.Kernel.Net` registries on the JVM too, so `Web.addWebSocket` runs over `takeConnection` there. Nothing else in lyric-ws changed.
- Tests: `jvm_server_smoke.l` is `web_smoke.l` (no extern), driven with `serve_failure_tests.l` and `streaming_tests.l` by `scripts/ci/lyric-web-smoke.sh <dotnet|jvm>` (replaces `lyric-web-undertow-jvm-smoke.sh`); `serve_tls_tests.l` gains the bound-port error path and a stricter misconfiguration assertion; `web_socket_tests.l` and `concurrent_dispatch_tests.l` now run on the JVM; four test files lose their per-target server-start helpers for `Std.HttpServerHost.startTask`.
- `scripts/ci/http-server-benchmark.sh`: `undertow` target replaced by `web-dotnet`, `web-jvm`, `web-native`.
- Docs: D791, docs/73 (header, 2.2, S6, S7b), docs/61, docs/44, docs/59, lyric-web README, CLAUDE.md, book chapters 14, 24, 29 and appendix B; stale Undertow comments in `tls_server_context.l`, `ui-jvm-suites.sh`, two tests, ci.yml.

## How it was verified

Toolchain as D788/D789 (v0.7.15 compiler, `lib/std` a copy of the tree, `Lyric.Stdlib.dll` rebuilt from it). `lyric test --manifest lyric-web/lyric.toml`: dotnet 103 tests (10 suites), JVM 102 (10 suites, Web.WebSocketTests 4 on each). `lyric-web-smoke.sh dotnet` and `jvm` pass. After rebasing onto S5 (D790): native `native-web-smoke.sh` passes and 81 of the lyric-web manifest tests pass on native (the panic-isolation, aspect-weaving and config-env cases cannot run there, see D791). Benchmarks (`wrk`/`h2load`, one run per cell, same container): the JVM through lyric-web against its Undertow baseline is B1 94%, B2 127%, B3 50.1%, B4 150%; B3 server RSS 1.86x misses the 1.5x gate (#9245, open since D789). Full tables in D791.

## Not verified

- The `lyric-ui` and `lyric-ecosystem` suites on the JVM (a `lyric-ui` JVM run was started, see the report); the CI scripts inside CI; `lyric fmt` is v0.7.15's.
- B5, B6, B7 were not re-run.

## Plan-changing finding

`Web.addWebSocket` could not stay on Undertow, so S6 did the core of S7b. S7b is now the deletion of `Ws.Kernel.Jvm`, its `[maven]` table, the `ownsHandle` routing in `ws.l` and the Maven restores in CI (D791 decision 6).
