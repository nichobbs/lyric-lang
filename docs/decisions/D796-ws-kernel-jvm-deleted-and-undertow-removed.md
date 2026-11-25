# D796 - `Ws.Kernel.Jvm` is deleted and no library, script or compiler fixture depends on Undertow (docs/73 slices S7b and S9)

**Status:** accepted. Completes docs/73: extends D791 (lyric-web on the shared driver, S6), D787 (lyric-ws on the JVM over `Std.TcpHost`, S7a) and D795 (S8 close-out). The plan numbered S7b and S9 separately; after S6 each was a few deletions, so they ship together.

## Context

After S6 (D791) nothing reached `Ws.Kernel.Jvm`: `Web.addWebSocket` hands an upgraded connection to `Ws.Kernel.Net` through `takeConnection` on every target, and `Ws.createEndpoint` allocates `Ws.Kernel.Net` registries everywhere. The package, its `[maven]` table (`io.undertow:undertow-core` 2.3.13.Final) and the handle routing in `ws.l` (`WsKernelJvm.ownsHandle`) were dead weight that still forced a Maven restore for every JVM build of lyric-web, lyric-ws and lyric-ui. Four compiler tests and CI scripts also used Undertow as their example of a Maven-sourced extern library.

## Decision

1. **`Ws.Kernel.Jvm` is deleted** (`lyric-ws/src/_kernel/jvm/ws_kernel.l`, 745 lines), together with `lyric-ws`'s `[maven]` table and its `[project.packages]` entry. `ws.l` loses `import Ws.Kernel.Jvm` and the `@cfg(feature = "jvm")` copies of `kernelStopServer`, `kernelSend`, `kernelBroadcast`, `kernelClose`, `kernelConnectionCount` and `kernelIsConnected`; the remaining definitions call `Ws.Kernel.Net` unconditionally. `src/_kernel/jvm/ws_prims.l` stays: it is the JVM's half of `Ws.Kernel.Net`'s per-target primitives.
2. **No JVM build of lyric-web, lyric-ws or lyric-ui restores Maven.** `jvm-ecosystem-suites.sh` restores only `mail`, `grpc` and `db`; `lyric-web-smoke.sh` and `ui-jvm-suites.sh` lose their `make maven-resolver` and `restore` lines. The libraries with a `[maven]` table left are `lyric-db`, `lyric-docker`, `lyric-grpc` and `lyric-mail`.
3. **The compiler's Maven fixtures use grpc-java.** `jvm_auto_ffi_bridge_self_test.l` test 12 (the #6565 acceptance case) builds the real `lyric-grpc/lyric.toml` with `--no-default-features --features jvm` instead of `lyric-web/lyric.toml`; the `jvm-auto-ffi bridge` CI step restores `lyric-grpc` first. The `[maven]` fixtures in `cli_build_self_test.l` and `scripts/ci/cli-args-e2e.sh` name `io.grpc:grpc-stub` 1.65.0; `tir-census.sh` restores `lyric-grpc` for its self-tests area. The comments in `cli_restore.l` and `jvm/codegen/06_items.l` use grpc-java examples.
4. **`ServerSslContext.rawContext` and the `serverSslContextFromConfig*` constructors stay.** The plan listed them for deletion, but `Std.TcpHost` on the JVM (`_kernel_jvm/tcp_host.l`) is their user and `tls_server_jvm_tests.l` pins the TLS 1.2 floor through them; only the comments naming Undertow changed.
5. **Docs and scripts say what is true now.** No `undertow` string remains in code, scripts, manifests, `ci.yml`, READMEs of the libraries it touched or the book chapters it touched, except where a sentence records history (the lyric-web README's note that the JVM kernels it replaced normalised header names, the benchmark README's baseline pointer, docs/44, 59, 61, 62, 65 and 73 status notes, the decision archive and the progress history).
6. **CI.** `ci.yml` shrinks (490 692 to 489 974 bytes): the Maven restore of the JVM auto-FFI bridge step now names lyric-grpc and three comments lose their Undertow clauses. No step is added or removed.

## Consequences

- A JVM build of lyric-web, lyric-ws or lyric-ui declares no Maven dependency, so the CI steps that build them no longer run the Maven resolver.
- `Web.addWebSocket` and `Ws.startServer` are one kernel on every target, so the WebSocket hardening of D792 to D794 reaches every endpoint without a second implementation.
- The compiler test for #6565 now depends on grpc-java coordinates (1.65.0, the version lyric-grpc pins); a bump of that pin needs no change here because the test reads the restored classpath.
