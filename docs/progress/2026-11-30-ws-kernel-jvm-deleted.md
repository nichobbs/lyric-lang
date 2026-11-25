# Ws.Kernel.Jvm deleted, no Undertow dependency left (docs/73 slices S7b and S9)

Slices S7b and S9 of `docs/73-jvm-pure-lyric-server-plan.md`, decision D796. After S6 (D791) the JVM never reached `Ws.Kernel.Jvm`; this change deletes it and everything that only existed for it.

## What shipped

- `lyric-ws/src/_kernel/jvm/ws_kernel.l` (745 lines, the Undertow endpoint kernel) is deleted, with `lyric-ws`'s `[maven]` table and the `Ws.Kernel.Jvm` entry in `[project.packages]`. `ws.l` drops its import and the six `@cfg(feature = "jvm")` routing wrappers; `Ws.Kernel.Net` is called unconditionally.
- No Maven restore remains for lyric-web, lyric-ws or lyric-ui: `jvm-ecosystem-suites.sh` restores only `mail`, `grpc` and `db`, and `lyric-web-smoke.sh` and `ui-jvm-suites.sh` no longer build or use the resolver. The manifests that still declare `[maven]` are `lyric-db`, `lyric-docker`, `lyric-grpc` and `lyric-mail`.
- The compiler's Maven fixtures use grpc-java: the #6565 acceptance test in `jvm_auto_ffi_bridge_self_test.l` builds `lyric-grpc/lyric.toml` (`--no-default-features --features jvm`), its CI step restores `lyric-grpc`, the `[maven]` fixtures in `cli_build_self_test.l` and `cli-args-e2e.sh` name `io.grpc:grpc-stub`, and `tir-census.sh` restores `lyric-grpc`. The header of the bridge self-test, which claimed the file was not wired into CI, now says it runs in `compiler-self-tests-jvm-b`.
- Comments and READMEs that named Undertow as a live dependency are corrected (lyric-ws README, `ws.l`, lyric-web sources and tests, `tls_server_context.l`, the benchmark README and scripts, docs/59, 62, 65, 70, book chapters 24 and 29, CLAUDE.md). Sentences that record history are kept.
- `ci.yml`: 490 692 to 489 974 bytes; no step added or removed.
- `ServerSslContext.rawContext` and the `serverSslContextFromConfig*` constructors, which the plan listed for removal, stay: `Std.TcpHost` on the JVM uses them.

## Verification

Toolchain: the v0.7.15 compiler with a stdlib bundle built from the same stdlib sources as this tree (only comments differ), as for S6 and S8.

- `lyric test --manifest lyric-ws/lyric.toml` on dotnet: 6 suites, 6 passed (frame 28, handshake 18, end-to-end 11, hardening 12, aspect weaving 6, unit 6).
- The same on the JVM (`--no-default-features --features jvm`), with no Maven restore: 6 suites, 6 passed, with the same test counts.
- `lyric test --manifest lyric-web/lyric.toml`: dotnet 10 suites passed (103 tests), JVM 10 suites passed (102 tests; the circuit-breaker aspect case is dotnet-only, #3669), as for S6.
- `scripts/audit-axioms.sh`, `scripts/audit-kernel-stubs.sh` and `scripts/ci/check-workflow-size.sh` pass; `lyric fmt --write` over every changed `.l` file changed nothing.

Not run locally: the compiler self-tests (`jvm_auto_ffi_bridge_self_test.l`, `cli_build_self_test.l`) and `cli-args-e2e.sh`, which need a compiler built from this tree (`make lyric` does not finish in the sandbox), the lyric-ui JVM suites and the CI scripts end to end. CI runs them.
