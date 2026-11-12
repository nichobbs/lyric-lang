# Ecosystem library remediation plan

Status: accepted in D552 (2026-11-09). Phase 2 progress: lyric-mq reference broker on both targets and broker declarations removed (see docs/progress/2026-11-10-mq-in-memory-reference.md). Source: the ecosystem audit of 2026-11-09
(README, manifest, CI-script and source-marker review; suites were not re-run).
Extends docs/57 and `docs/12-todo-plan.md` item 3.

## 1. Audit result

| Group | Libraries |
|---|---|
| Stable on both targets | proto, validation, i18n, health, testing, generator-sdk, unicode, unicode-dict; auth except `ValidateKey` on JVM |
| Real, labelled `@experimental` | web, ws, mcp, grpc, forms, lambda, aws-xray, resilience, session, feature-flags, ui |
| Headline backend missing | mq (only `inmemory`, dotnet), storage (S3, Azure; removed from the public API, see progress 2026-11-10-storage-remove-s3-azure), db (no JVM), jobs (Hangfire, Quartz.NET on dotnet), otel (OTLP JVM, logs, gRPC; JVM transport implemented and logs/gRPC removed in #8953), lambda (HTTP, streaming), aws-secrets (native `config`) |
| Broken in one configuration | session and jobs in-process stores on JVM (#5451, #5456); auth `ValidateKey` and aws-xray `Tracing` on JVM (B-prime weaver); cache thread safety (#7457); search against a live server (`HttpResponse.bodyText`; does not reproduce on `main`, see section 2) |
| Docs out of step | logging README (weaver "planned"), book matrix rows (proto, logging, search, five libraries missing), `cache_aspects.l` header |
| Out of scope | graphics, window, GPU, text, draw, game, access, native lyric-ui (D548) |

## 2. Compiler root causes (phase 1)

| Cause | Unblocks | Owner |
|---|---|---|
| JVM erased generics (#5456, #5451, #5439, #5442, #5444) | jobs, session, i18n on JVM | session P1a |
| B-prime weaver on JVM (`__LyricBModeCallContext`) | auth `ValidateKey`, aws-xray `Tracing`, ws aspects | session P1a |
| `impl <Interface> for <protected type>` (#7457), both backends | cache thread safety, other in-process stores | session P1b |
| ~~Cross-package free async function and `HttpResponse.bodyText` from outside `Std.Http` (lyric-search README defects 1 to 3, lyric-lambda `dispatch.l` header)~~ **Does not reproduce on `main`** (verified 2026-11-10, #8940: `tests/search_live_tests.l` reads every response body across packages from a fake `Std.HttpServer` engine on dotnet and the JVM, for both backends, and awaits a `SearchClient` call from an `async func`). The README text was stale; no compiler or stdlib change was needed | none (search is tested end to end; lambda HTTP is a missing feature, not this defect) | done |

## 3. Phases

- **Phase 0, documentation.** Reconcile README, chapter 29 matrix, docs/12 and
  `lyric.toml` stability; add the missing matrix rows; fix stale text. This PR.
- **Phase 1, compiler root causes.** Section 2. Each fix ships a regression
  self-test and un-breaks the dependent library in the same PR. Library suites
  for jobs, session, auth, logging and otel join `jvm-ecosystem-suites.sh` as
  they pass.
- **Phase 2, stability and API cleanup.**
  1. `[package] stability` in `Lyric.Manifest`, `lyric publish` check (F-series
     diagnostic), README and matrix generated or checked from it.
  2. Remove `NOT_IMPLEMENTED` backends from public APIs per D552 item 2:
     mq, storage, jobs, db, otel, lambda (HTTP, `Lambda.Stream`), aws-secrets.
     Progress: lambda (HTTP entry point, `Lambda.Stream`) and aws-secrets (native
     annotation path, `NotImplemented`) done on `claude/eco-lambda-secrets`.
     _Progress:_ jobs done. Hangfire, Quartz.NET, the JVM Quartz binding,
     `NativeJobScheduler` and `Jobs.connect*` are removed; `InProcessJobScheduler`
     is the reference backend (the Quartz kernel never ran application
     handlers and CI never selected it).
  3. Conformance suites in `lyric-testing` for `MessageQueue`, `StorageBucket`,
     `JobScheduler`, `CacheStore`, `SessionStore`, `SearchClient`, `FlagStore`.
  4. Real in-tree reference backends where missing: lyric-db JVM (JDBC with
     SQLite and PostgreSQL, #8932, done), lyric-mq `inmemory` on JVM, lyric-otel OTLP/HTTP on JVM.
- **Phase 3, CI and tests.** Missing `Lyric.Testing` mocks (Db, Jobs, Search,
  i18n, Ws); every stable library in the JVM suite or a documented exemption.
- **Phase 4, extraction.** New repository for SDK-bound backends, one package
  per backend, each running the published conformance suite; version
  compatibility via the registry (docs/39). Starts only after phase 1 and the
  registry flow are verified.
  _Progress:_ `nichobbs/lyric-ecosystem` has its workspace, CI and first six
  packages: `Lyric.Storage.S3`, `Lyric.Jobs.Quartz`, `Lyric.Redis`,
  `Lyric.Cache.Redis`, `Lyric.Session.Redis`, `Lyric.Mq.ActiveMq` (see
  docs/progress/2026-11-12-ecosystem-first-backends.md). It builds against a
  pinned `lyric-lang` commit through `[workspace.overrides]` until the registry
  flow carries the conformance suites. Since then: TLS for the Redis, ActiveMQ and
  RabbitMQ clients, and `Lyric.Storage.AzureBlob`, `Lyric.Storage.Gcs`,
  `Lyric.Jobs.QuartzNet`, `Lyric.Mq.RabbitMq`, `Lyric.Mq.Sqs`,
  `Lyric.Flags.Flipt` and `Lyric.Aws.SigV4`
  (docs/progress/2026-11-13-ecosystem-tls-and-second-wave.md).

## 4. Open questions

- **Q-ECO-001.** Resolved in D561: one `lyric-ecosystem` monorepo with
  independently versioned packages, split later if a backend's release cadence
  demands it.
- **Q-ECO-002.** Compatibility policy between a library's interface version and
  an external backend (SemVer range on the interface package, conformance suite
  version pinned in the backend's CI).
- **Q-ECO-003.** Resolved 2026-11-10: search's JVM state is "passes CI". The
  README's "no kernel" text predated docs/59 wave 4 (H5 fixed); `Std.Http`'s
  JVM kernel is real and `search_live_tests.l` passes on `--target jvm` for
  both backends. The remaining gap is that CI runs the JVM suite with the
  default `elasticsearch` feature only.

## 5. Tracking

Execution is split into nested sessions grouped by build cycle: P1a (JVM
backend), P1b (protected-type dispatch and cache), then phase 1c and phase 2
after both land. Progress notes go in `docs/progress/`.
