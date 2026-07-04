# 57 — Standard Library & Ecosystem Library Review (2026-07)

**Status:** Unbacked (audit). No decision-log entry yet — this document
catalogues findings; see §7 for suggested follow-up.

**Builds on:** `docs/14-native-stdlib-plan.md` (kernel boundary),
`docs/41-self-hosted-compiler-gap-analysis.md` and
`docs/44-jvm-production-readiness-plan.md` (audit format precedent),
`docs/47-import-extern-syntax.md`, `docs/48-constructor-shorthand.md`,
`docs/55`/`docs/56` (aspect idiom currency).

**Scope:** `lyric-stdlib/std/`, `lyric-stdlib/tests/`, and all 26 ecosystem
libraries at the repo root (`lyric-auth` … `lyric-ws`), read-only. Six
parallel review passes covered: (1) stdlib core, (2)
web/ws/session/grpc/proto/docker, (3) auth/validation/resilience/
feature-flags/i18n, (4) db/cache/storage/search/mq/jobs, (5)
logging/otel/health/testing/mail, (6) lambda/aws-secrets/aws-xray/
generator-sdk.

---

## 1. Headline finding: `import extern` + `.new()` shipped yesterday, adoption is zero, and the docs still say otherwise

Commit `a64e649` (2026-07-03, "Address 119 compiler-backend/compiler-frontend
review-finding issues", #4714) landed real type-checker support for `import
extern` (`typechecker_checker.l:1487,1513`, `isExtern` handling) and codegen
support for `.new()` constructor shorthand on reference-type extern types
(`msil/codegen.l:22220,22485-22547`), plus a passing proof: 
`lyric-compiler/lyric/import_extern_self_test.l` resolves
`SystemMath.Max`/`Min`/`Abs` through an `import extern System.{ Math as
SystemMath }` binding.

Two problems fall out of this timing:

- **Docs are stale.** `docs/47-import-extern-syntax.md` and
  `docs/48-constructor-shorthand.md` both still say "Type-checker
  integration is deferred to Phase 2" / "Implementation deferred pending
  type-checker Phase 2 integration." That's no longer true. Every one of
  the six review passes independently concluded the feature "hasn't
  shipped yet" and recommended waiting for it — because the docs told
  them to. **Fix:** update both status headers to "Shipped" and cite the
  commit/PR, the same way `docs/43`/`docs/51` track phase completion.
- **The self-test isn't wired into CI.** `import_extern_self_test.l`
  exists and presumably passes locally, but neither `Makefile` nor
  `.github/workflows/ci.yml` reference it (unlike
  `ffi_iface_impl_self_test.l`, which is wired at `ci.yml:997`). A
  regression here would go undetected. **Fix:** add it to the CI self-test
  matrix now, before any library starts depending on the feature.

Net effect: **zero files across stdlib or the 26 ecosystem libraries use
`import extern` or `.new()` today** — not because of resistance to the
idiom, but because it landed one day before this review and the docs said
not to use it yet. This is good news framed as a gap: there is a large,
well-defined, low-risk modernization backlog once the two items above are
fixed. §7 has a suggested rollout order.

---

## 2. FFI modernization backlog (constructor-wrapper → `.new()`)

Every kernel boundary in the repo still uses the pre-D117 pattern:
`@externTarget("Namespace.Type..ctor") @externStatic func newFoo(...): Foo
= ()`. These are pure mechanical migrations once §1 is resolved — delete
the wrapper, call `Foo.new(...)` at the (small number of) call sites.
Concrete examples surfaced across the sweep:

| Library | File | Constructors |
|---|---|---|
| stdlib | `std/_kernel/collections_host.l:23-30` | `newList`, `newListWithCapacity`, `newMap` |
| stdlib | `std/_kernel/http_host.l:20-30` | `HttpMethod`, `HttpRequestMessage`, `StringContent`, `HttpClient`, `HttpClientHandler`, `SocketsHttpHandler` |
| stdlib | `std/_kernel/random_host.l`, `std/_kernel/task.l`, `std/_kernel/process_capture_host.l` | `Random`, `CancellationTokenSource`, `ProcessStartInfo`/`MemoryStream`/`StreamReader` |
| stdlib | `std/_kernel_jvm/collections_host.l:24-33` | JVM parity (`ArrayList`, `HashMap`) |
| lyric-web | `src/web.l:65` | `HttpListener` |
| lyric-web, lyric-ws, lyric-mq, lyric-jobs, lyric-resilience | `_kernel/net/*_kernel.l` | `ConcurrentDictionary`/`ConcurrentQueue` wrappers (5+ occurrences each in mq/jobs kernels) |
| lyric-mail | `src/_kernel/net/mail_kernel.l:41-135` | `SmtpClient`, `NetworkCredential`, `MailMessage`, `MailAddress`, `MemoryStream`, `Attachment` (9 total) |

`import extern` grouping candidates (files with 3+ scattered single-line
`extern type` declarations that would read more clearly grouped by
namespace): `std/_kernel/json_host.l:18-31` (7 `System.Text.Json` types),
`std/_kernel/http_host.l` (`System.Net.Http` types), and
`lyric-session/src/_kernel/net/session_kernel.l:50-76` (10 StackExchange.Redis
types across 27 lines — the densest single offender found).

**Recommendation:** pick one high-traffic module as the reference
migration (stdlib's `http_host.l` or `collections_host.l` are good
candidates — widely imported, moderate size) and use it to establish the
pattern before sweeping the rest. Property-setter wrappers (e.g.
`mail_kernel.l`'s `smtpSetEnableSsl`/`mailSetFrom` family) are a separate,
lower-priority cleanup — `.new()` doesn't help there; leave them as-is
unless auto-FFI gains property-assignment sugar.

---

## 3. Platform parity gaps (.NET / JVM / native / local)

- ~~**lyric-resilience JVM kernel is non-functional stubs**
  (`src/_kernel/jvm/resilience_kernel.l:17-32` return `false`/no-op by
  default) while the .NET kernel is fully wired. This is more than a
  documentation gap — `Retry`/`CircuitBreaker` silently do nothing useful
  on JVM.~~ **Fixed (#5037):** `Resilience.Kernel.Jvm` now implements the
  real circuit-breaker state machine — a process-global
  `java.util.concurrent.ConcurrentHashMap` (used as its raw, erased type
  via ordinary `extern type` auto-FFI, no `@externTarget`-style generic
  member emission needed) plus a per-entry `ReentrantLock` (the JVM has no
  callable `Monitor.Enter`/`Exit` equivalent — object monitors are only
  reachable via the `synchronized` keyword, which Lyric source can't
  express) guarding the same read-modify-write logic as
  `Resilience.Kernel.Net`. `Retry`/`CircuitBreaker` now work identically
  on both targets.
- **lyric-otel JVM kernel is compile-only** (`otel_kernel.l` JVM variant
  header: "Marked `@phase(6)` — not compiled today; present to drive API
  parity"). Accurately documented but worth a runtime-facing note in
  `otel.l` so users importing on JVM don't expect traces to actually
  export.
- **stdlib JVM gaps**: HTTP Unix-domain-socket support
  (`std/_kernel_jvm/http_host.l:106-116`, tracked #2663) and regex
  timeout (`std/_kernel_jvm/regex_host.l:75-76`, tracked #1103) both route
  to stubs. Already tracked; no new issue needed, just confirming they're
  still open.
- **lyric-storage**: only the local-filesystem backend is
  production-grade; S3 and Azure Blob backends
  (`storage_kernel.l:24-29`, `storage.l:850-880`) return
  `NOT_IMPLEMENTED` pending native `extern type` bindings against the AWS
  SDK / Azure SDK. Documented as deliberate (no active users yet) but the
  library's own doc comment (`docs/03-decision-log.md` D056) and its
  README should say so up front — a user reading "S3, Azure Blob, and
  local filesystem backends" in CLAUDE.md's library list would reasonably
  expect all three to work today.
- **lyric-mq**: .NET in-memory backend works; RabbitMQ/SQS/Azure Service
  Bus/Kafka are stubbed (`mq_kernel.l:213-237`). JVM kernel supports only
  RabbitMQ/Kafka — no in-memory, no SQS/Azure — so the two targets aren't
  even stubbing the same subset.
- **lyric-jobs**: in-process scheduler works; Hangfire/Quartz.NET backends
  are stub-only.
- **lyric-search**: both Elasticsearch and Meilisearch backends are
  stubbed (`search.l:52-63`, returning `"<backend> not linked"`); the
  whole module is `@experimental`, which is the right marker given the
  state.

**Recommendation:** these backend gaps are individually reasonable
(each is honestly stubbed, not silently broken), but CLAUDE.md's
top-level library list describes several of them (storage, mq, jobs,
search) as if all listed backends are equally real. Add one sentence per
library README naming exactly which backend is production-grade today
and which are stubs, so a new consumer doesn't discover the gap at
runtime.

---

## 4. Aspect idiom currency

Good news first: of the aspect-bearing libraries reviewed (auth,
validation, resilience, feature-flags, storage, mq, jobs, db, logging,
lambda), all but one use current D115/D118 idiom correctly — B-mode
`around(call) -> ret` with `call.proceed()`/`call.qualifiedName` for
argument-independent aspects, and B′-mode `where TArgs has { field: Type
}` row constraints for argument-dependent ones (e.g. `Auth.ValidateKey`'s
`apiKey`, `Storage.ValidateKey`'s `key`, `Mq.Idempotent`'s
`message.id`, `Lambda.DeadlineGuard`'s `ctx`).

One real gap: **`lyric-cache/src/cache_aspects.l`'s header is wrong.** It
says "The full aspect-weaver wiring (B-mode / C-mode, around(call), config
injection) ... is deferred until that system ships" — but the aspect
weaver shipped in D047, B′-mode in D114, row-typed args in D115/D118.
The file currently defines only config records
(`FunctionCacheConfig`/`ItemCacheConfig`) and factory functions, no actual
`pub aspect` templates, even though every sibling library (db, storage,
mq, jobs, validation) has shipped equivalent caching-adjacent aspects
using the exact machinery this file says doesn't exist yet. **Fix:**
either write the two aspect templates the comment describes (a
`FunctionCache` B-mode template keyed on `call.qualifiedName`, an
`ItemCache` B′-mode template keyed on a row-constrained `cacheKey` field)
using `lyric-storage`'s `ValidateKey` as a reference, or — if there's a
reason it's still config-only — correct the comment to stop claiming the
weaver doesn't exist.

One reviewed-and-rejected suggestion, for the record: a sub-review flagged
`Auth.Aspects.ValidateKey` (`lyric-auth/src/auth_aspects.l:53-58`) for
handling an empty `apiKey` via a runtime `if` instead of a `requires:`
contract clause on `args.apiKey`. That's actually correct as written —
`requires:` violations are runtime asserts/panics (per
`docs/08-contract-semantics.md`), which is the wrong failure mode for
untrusted external input (a missing header shouldn't crash the process);
returning `Err("API key is missing")` is the right behavior and matches
what `validation_aspects.l` does for its own untrusted-input checks. No
change needed here.

---

## 5. Testing gaps

### 5.1 stdlib core — real coverage holes (name-matching false positives excluded)

Cross-checking `std/*.l` against `tests/*.l` by content (not just naming
convention — `testing_mocking.l` is in fact covered by
`tests/mocking_tests.l`, a naming mismatch, not a gap) leaves these
**stdlib modules with genuinely no dedicated test file**: `app.l`,
`console.l`, `core_proof.l`, `directory.l`, `file.l`, `http.l`, `log.l`,
`random.l`, `secure_random.l`, `stream.l`, `testing_property.l`,
`testing_snapshot.l`. Of these, **`file.l`, `directory.l`, and `http.l`
are core, widely-imported I/O surface** and should be the priority — every
ecosystem library that touches the filesystem or makes HTTP calls is
currently relying on untested stdlib primitives. `random.l`/
`secure_random.l` can't test exact output but can and should test range
bounds, non-degenerate distribution, and (for `secure_random`) that
successive calls don't repeat a fixed seed.

### 5.2 Ecosystem libraries — untested public APIs behind "requires live service" comments

A recurring pattern: a public function's only test coverage is
constructing its input/output records, while the function itself is
skipped with a comment like "requires a live server, not exercised here."
This is reasonable when no test-double infrastructure exists yet, but
several of these are core, not edge-case, functionality:

- **lyric-lambda** (`tests/lambda_tests.l:10-11`): `serve()` and the four
  runtime-kernel dispatch loops (aws/jvm/local/web) have zero invocation
  tests. Given `docs/35-lambda-library.md`'s scope (SQS/SNS/S3/
  EventBridge/DynamoDB/Kinesis event handlers, TOKEN/REQUEST/HTTP
  authorizers), the **local** kernel is exactly the one that shouldn't
  need a live AWS account to test — it's the in-process test double.
  Recommend building event-source-specific dispatch tests against the
  local kernel first (one per handler type), since that infrastructure
  already exists and needs no network access.
- **lyric-aws-secrets** (`tests/secrets_tests.l:5-6`): `init()`,
  `getSecret()`, `getParameter()` are untested; so is the `ttlSeconds`
  caching logic and the `AccessDenied`/`DecryptionError`/`ParseError`
  error paths. The library ships a `secrets_kernel_local.l` — same
  opportunity as lambda above.
- **lyric-aws-xray** (`tests/xray_tests.l`): a single "package can be
  imported" smoke test. No coverage of `currentSubsegment()`,
  `annotate()`, `metadata()`, or the `Tracing` aspect weaving. Also
  inconsistent: `xray.l` marks itself `@experimental`, which is at least
  honest about the test gap, but the aspect weaving specifically (pure
  Lyric, no AWS dependency) is testable today with a mock subsegment
  handle and should be.
- **lyric-grpc** (`tests/grpc_types_tests.l`): only enum/status-code
  mapping is tested; the `GrpcChannel` opaque type and call functions
  need a live gRPC server per the file's own comment. No unary/streaming/
  timeout/error-recovery tests exist.
- **lyric-docker** (`tests/basic_operations_tests.l`): only stream
  demultiplexing is tested; zero coverage of container/image operations,
  error paths, or auth/config. `docker_api.l:14-23`'s
  `DockerResponsePlaceholder` is an explicitly-labeled Phase 1 placeholder
  per `docs/54` — expected, not a new finding, but worth linking from the
  test file so the gap is traceable to the tracked doc.
- **lyric-mail**: SMTP connectivity itself isn't exercised (only the
  pure-Lyric `EmailMessage`/`Attachment` envelope is); SES/SendGrid are
  placeholder bindings pending Testcontainers infra (`mail_kernel.l:9`,
  tracked #780 follow-up) — already tracked, no new issue needed.
- **lyric-feature-flags**: `FlagGated`/`FlagVariant` aspect weaving has no
  regression test (only the underlying flag-store functions are tested).
- **lyric-i18n**: no coverage for `fromJson` parse errors or a fully
  exhausted locale-fallback chain (request locale absent, primary
  fallback absent, secondary fallback absent).
- **lyric-web / lyric-ws**: CORS, rate-limiting, and aspect weaving are
  tested; routing/handler dispatch and WebSocket connection lifecycle are
  not (this converges with §3's note that HTTP kernel dispatch itself is
  a pending compiler/runtime milestone, so some of this is intentionally
  blocked, not neglected).

### 5.3 `lyric-testing` mock coverage vs. the interfaces it should cover

`Lyric.Testing` ships `MockMailSender`, `MockStorageBucket`,
`MockMessageQueue`, `MockSessionStore`, `MockFlagStore`, `TestClock`. Cross-
referencing against every ecosystem interface that plausibly needs a test
double surfaces concrete missing mocks: **`MockDbConnection`** (lyric-db),
**`MockJobScheduler`** (lyric-jobs — `InProcessJobScheduler` exists in
lyric-jobs itself but isn't part of the shared testing library),
**`MockSearchClient`** (lyric-search), **`MockQueueConsumer`**
(lyric-mq — only the publish side is mocked, not `QueueConsumer`/
`DeadLetterStore`), **`MockTranslationStore`** (lyric-i18n), and
**`MockWsHandler`/`MockWsRegistry`** (lyric-ws). Also already tracked and
worth reiterating here since it compounds every mock above: `testing.l:13-14`
documents that all current mocks simulate only the happy path — no
failure-injection hooks (tracked #410). Given how many of the gaps in
§5.2 are literally "no live-service test double," closing #410 and adding
the mocks above would unblock a large fraction of the testing gaps found
in this review at once.

---

## 6. Stale comments to clean up (not functional bugs)

- `lyric-storage/src/storage.l:424-425,467` — leftover bootstrap-era
  comments ("SFor not supported in bootstrap", "once codegen lands") from
  before the self-hosted compiler shipped `SFor`/full codegen. Delete;
  they actively mislead a reader into thinking a feature is still
  missing.
- `lyric-cache/src/cache_aspects.l` header — see §4, factually wrong about
  weaver status.
- `docs/47-import-extern-syntax.md`, `docs/48-constructor-shorthand.md`
  status headers — see §1, factually wrong about Phase 2 status.

---

## 7. Suggested rollout order

1. Update `docs/47`/`docs/48` status headers to "Shipped" (§1) and wire
   `import_extern_self_test.l` into `Makefile`/`ci.yml` self-test targets.
2. Pick one stdlib kernel file (`http_host.l` or `collections_host.l`) as
   the reference `.new()`/`import extern` migration; use it as the
   pattern for the rest of §2's backlog.
3. Close the stdlib I/O test gap: `file_tests.l`, `directory_tests.l`,
   `http_tests.l` (§5.1) — highest leverage since every ecosystem library
   built on top inherits the coverage.
4. Fix `lyric-cache/src/cache_aspects.l` (§4) — either ship the two
   templates or correct the comment.
5. Add local-kernel-backed tests for lyric-lambda event handlers and
   lyric-aws-secrets (§5.2) — no live-service dependency required, so this
   is pure engineering time, not blocked on infra.
6. Track backend-completeness asymmetry (§3) with one README sentence per
   library naming which backend is real vs. stubbed, so CLAUDE.md's
   library list stays accurate without needing this document as a cross-
   reference.
7. Expand `lyric-testing` mocks per §5.3, prioritized by #410
   (failure-injection) since it multiplies the value of every mock added
   after it.
