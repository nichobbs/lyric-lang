# lyric-jobs

Background job scheduling with pluggable backends (Hangfire, Quartz.NET, Quartz).

## Platform parity

**`InProcessJobScheduler` is production-ready on `dotnet`** (pure
Lyric, no kernel dependency; `Jobs.inProcess()`). On `--target jvm` it
is currently **broken**: `List[JobSpec]`'s `queue` field crashes with a
`ClassCastException` (`class java.util.ArrayList cannot be cast to
class java.lang.Integer`) the moment a job is enqueued — a JVM backend
erased-generics bug (#5456, same family as #5439/#5442/#5444/#5451),
not caused by or specific to this library. Beyond that, the two
targets diverge in an unusual direction — `jvm` actually has *more* real
backend coverage than `dotnet` today, for `NativeJobScheduler` (obtained via
`Jobs.connect()` / `Jobs.connectHangfire()` / `Jobs.connectQuartz()`):

| Platform feature | Backend feature      | Status                                                                 |
|-------------------|----------------------|-------------------------------------------------------------------------|
| `dotnet` (default) | `InProcessJobScheduler`      | Available                                                                |
| `dotnet` (default) | `inprocess`            | Available — real, functional `ConcurrentDictionary`-backed `NativeJobScheduler` (Phase 3 of #733) |
| `dotnet`           | `hangfire`, `quartz`   | `NOT_IMPLEMENTED` — `connect()` returns an error (`src/_kernel/net/jobs_kernel.l`, tracked as a Phase 3 follow-up of #733) |
| `jvm`              | `InProcessJobScheduler`      | **Broken** — #5456 (unrelated to the Quartz kernel below) |
| `jvm`              | `inprocess`            | Available — real, functional `ConcurrentHashMap`-backed `NativeJobScheduler` |
| `jvm`              | `hangfire`, `quartz`   | Real Quartz Scheduler binding (both features map to Quartz — Hangfire has no JVM port) — genuine, tested implementation, not a stub. See "Quartz on JVM" below for exactly what "real" means here. |

`dotnet`/`jvm` (platform) and `inprocess`/`hangfire`/`quartz` (backend) are
two independent, each-mutually-exclusive feature axes — see `lyric.toml`'s
`[features]` comment. Selecting none of `inprocess`/`hangfire`/`quartz` is a
**build-time error** (an unresolved kernel symbol), not a runtime
"not configured" failure: `NativeJobScheduler`/`connect()` genuinely require
picking a backend.

### Quartz on JVM

`src/_kernel/jvm/jobs_kernel.l` binds real `org.quartz-scheduler:quartz` /
`quartz-jobs` types via JVM auto-FFI (`extern type`) — no F# shim, no
`extern package` (that mechanism is a confirmed no-op, epic #5324; this
kernel used to declare one and every function in it was dead code until this
rewrite). `Jobs.connectQuartz()` starts a real
`org.quartz.impl.StdSchedulerFactory`-built `Scheduler` (RAMJobStore,
in-memory); `enqueue`/`schedule` submit real `JobDetail`+`Trigger` pairs that
a genuine Quartz thread pool executes; `cancel` calls the real
`Scheduler.deleteJob`; `status`/`results` poll real Quartz state
(`Scheduler.checkExists`) rather than fabricating a result. Verified against
a real, running Quartz scheduler in `tests/jobs_tests.l`'s
`"NativeJobScheduler (quartz feature): real end-to-end schedule, run, poll,
cancel, and error paths"` test — run it with:

```sh
lyric test --manifest lyric-jobs/lyric.toml --target jvm --no-default-features --features jvm,quartz
```

Two things this kernel genuinely **cannot** do, both pre-existing, disclosed
limits rather than shortcuts taken for this task:

1. **No arbitrary job-handler dispatch.** `NativeJobScheduler.enqueue`/
   `schedule` never accepted a `JobHandler` on *either* target — only
   `InProcessJobScheduler.runNext`/`runAll` do. So there is no application
   code for Quartz to call back into even in principle. Quartz's real thread
   pool instead runs `org.quartz.jobs.NativeJob` (a built-in Job
   implementation shipped by `quartz-jobs`) against a fixed, always-succeeding
   no-op command, purely to exercise genuine Quartz job-store/thread-pool
   machinery end-to-end; `results()`'s `output`/`error` fields are therefore
   always empty. Implementing `org.quartz.Job` from a Lyric record so a real
   handler could run inside Quartz's own thread requires the JVM analogue of
   `impl <ExternInterface> for Record` (docs/51) — shipped for MSIL (D105)
   but not yet for JVM.
2. **`schedule()` (cron) never reports a terminal status.** A recurring
   Quartz trigger doesn't have a single "done" state (matching
   `Jobs.Kernel.Net`, which doesn't implement `schedule` for the native path
   at all) — `status()` stays `"Pending"` between fires.

While verifying this kernel, three general JVM backend gaps were found (see
docs/03-decision-log.md for the full writeup): a `var …: Bool = false`
record field immediately before a `Long` field, or several defaulted fields
before a trailing reference field, miscompile a record constructor
(`VerifyError: Bad type on operand stack`) — worked around here by field
reordering and explicit construction (not fixed at the compiler level;
filed as #5457). Calling a method through an *interface*-typed `extern
type` (rather than a class) mis-emitted `invokevirtual` against an
interface owner and failed class-load verification, because the JVM
class-file reader intentionally skipped interface class files entirely —
this one **was fixed at the compiler level** (landed via `lyric-session`'s
Lettuce Redis kernel work, D-progress-631, integrated into this same PR;
this kernel's own binding to Quartz's public `org.quartz.impl.StdScheduler`
facade class rather than the `Scheduler` interface it implements predates
that fix and was left as-is — both now work). `List[T].removeAt` (used by
`InProcessJobScheduler.cancel`, unrelated to this kernel) had no JDK
`ArrayList.remove(int)` translation at all, which **was** fixed directly in
`lyric-compiler/jvm/codegen/04_calls.l` since it blocked compiling `Jobs` for
JVM altogether.

## Packages

| Package | Purpose |
|---|---|
| `Jobs` | Core types, `JobScheduler` interface, in-process implementation, and public API |
| `Jobs.Aspects` | Reusable aspect templates: `Retryable` and `Timed` |

## Quick start

```lyric
import Jobs

val scheduler = Jobs.inProcess()

match Jobs.enqueue(scheduler, "email-sender", "{\"to\":\"user@example.com\"}") {
  case Err(e) -> println("enqueue failed: " + e)
  case Ok(jobId) -> {
    match Jobs.status(scheduler, jobId) {
      case Ok(Jobs.JobStatus.Pending)   -> println("queued")
      case Ok(Jobs.JobStatus.Running)   -> println("in progress")
      case Ok(Jobs.JobStatus.Succeeded) -> println("done")
      case Ok(Jobs.JobStatus.Failed)    -> println("error")
      case Ok(Jobs.JobStatus.Cancelled) -> println("cancelled")
      case Err(e) -> println("status error: " + e)
    }
  }
}
```

## JobScheduler interface

`JobScheduler` is a pluggable interface supporting multiple backends:

```lyric
pub interface JobScheduler {
  func enqueue(name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int): Result[String, String]
  func schedule(name: in String, payload: in String, cronExpr: in String, maxAttempts: in Int, timeoutMs: in Int): Result[String, String]
  func cancel(jobId: in String): Result[Unit, String]
  func status(jobId: in String): Result[JobStatus, String]
  func results(jobId: in String): Result[JobResultList, String]
}
```

Two implementations are provided: `InProcessJobScheduler` (in-memory,
single-process, obtained via `Jobs.inProcess()`) and `NativeJobScheduler`
(backend-backed, obtained via `Jobs.connect()` / `Jobs.connectHangfire()` /
`Jobs.connectQuartz()` — see "Backends" below for which are real on which
target).

## Backends

### In-process (`InProcessJobScheduler`)

`Jobs.inProcess()` runs jobs sequentially in-memory (`runNext`/`runAll` against
a `JobHandler` you provide). Best for development and testing.

`runNext` honours `spec.maxAttempts` and `spec.timeoutMs`:

- **Retries.** A handler `Err`, or a caught handler panic, is retried
  immediately, up to `maxAttempts` attempts in total, before the job is
  reported `Failed`. A panic is reported as an ordinary failed attempt
  (`"handler panicked: <message>"`) rather than propagating and taking down
  the caller — `runNext` always returns `Ok(result)` for a real attempt
  sequence; `Err` is reserved for "queue empty". `Jobs.attemptCount(scheduler,
  jobId)` reports the total number of attempts run for a job (0 if it never
  ran).
- **Timeout.** `runNext` is a synchronous, single-threaded, in-process
  runner: it cannot pre-empt a running handler. `timeoutMs` is enforced
  honestly for that constraint — after the handler call returns, its elapsed
  wall-clock time is measured, and if it exceeds `timeoutMs` the attempt is
  discarded and counted as failed (`"... exceeded timeoutMs ..."`), subject
  to the same retry budget as a genuine `Err`, even if the handler itself
  returned `Ok`. A handler that never returns still hangs `runNext` — there
  is no cancellation of in-flight work.

### `inprocess` feature (`NativeJobScheduler`)

A second, independent in-memory implementation — real on both targets
(`ConcurrentDictionary` on `dotnet`, `ConcurrentHashMap` on `jvm`) — reachable
through the same `JobScheduler` interface as the Hangfire/Quartz backends via
`Jobs.connect()`. Unlike `InProcessJobScheduler`, it has no handler-dispatch
API either (see "Quartz on JVM" above) — it exists to exercise the
`NativeJobScheduler` code path (kernel dispatch, JSON results encoding) in
tests without a real broker.

### Hangfire (`hangfire` feature)

`Jobs.connectHangfire()` connects to Hangfire on `dotnet`, and to a real
Quartz Scheduler (as a functional substitute — Hangfire has no JVM port) on
`jvm`. **On `dotnet`, this currently returns `Err("... not yet
implemented")`** — the real .NET Hangfire binding is tracked as a Phase 3
follow-up of #733. On `jvm` it's a real binding — see "Quartz on JVM" above
for exactly what "real" covers. There is no connection-string parameter (the
underlying kernel `connect` never accepted one on either target); the
connection string is read from an environment variable instead:

| Env var | Default | Meaning |
|---|---|---|---|
| `LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING` | (required on `dotnet`) | SQL Server or Redis connection string. On `jvm` a non-empty value is ignored with a `Std.Log.warn` (Quartz uses RAMJobStore regardless), rather than silently downgrading persistence. |

### Quartz (`quartz` feature)

`Jobs.connectQuartz(datasourceUrl)` connects to Quartz.NET on `dotnet`
(requires an ADO.NET-compatible data source for persistence) or to real
Quartz Scheduler on `jvm`. **On `dotnet`, this currently returns
`Err("... not yet implemented")`**, same tracking as Hangfire above. On
`jvm` it's a real binding (in-memory `RAMJobStore`, not persistent).

## Cron expressions

`schedule()` takes a cron expression as a plain `String`, but it is
validated, not forwarded verbatim: `parseCron` enforces exactly **one**
dialect — standard 5-field Unix cron (`minute hour day-of-month month
day-of-week`, single-space separated) — and returns a `CronExpr` on
success. Each field accepts:

| Form | Meaning |
|---|---|
| `*` | every value |
| a bare number | a single value, within the field's range |
| `a-b` | an inclusive range |
| `*/n` or `a-b/n` | a step (`n >= 1`) |
| a comma-separated list | any of the above, combined |

Field ranges: minute `0-59`, hour `0-23`, day-of-month `1-31`, month `1-12`,
day-of-week `0-7` (both `0` and `7` mean Sunday, the Unix convention).
Anything outside this — 6/7-field Quartz syntax, named months/days,
`@daily`-style macros — is rejected with an error naming the offending
field, rather than silently misinterpreted (the historical bug this closes:
a raw string was spliced straight into the in-process scheduler's JSON test
payload, so a payload like `1,"cron":"..."` could override the stored cron
field entirely — payload and cron are now both encoded as JSON *string*
values, never spliced in raw).

```lyric
import Jobs

match Jobs.parseCron("*/15 9-17 * * 1-5") {
  case Err(e)   -> println("invalid cron: " + e)
  case Ok(cron) -> {
    val _ = Jobs.scheduleCron(scheduler, "business-hours-job", "{}", cron)
  }
}
```

`schedule(scheduler, name, payload, cronExpr: String)` keeps working exactly
as before for callers passing a raw string — it now calls `parseCron`
internally and returns `Err` for an invalid expression instead of forwarding
it. `scheduleCron`/`scheduleCronWith` take an already-validated `CronExpr`
directly, for callers that parsed (and want to reuse or inspect) it upfront.

**Quartz dialect conversion.** Real Quartz Scheduler (the `jvm` binding
behind both the `hangfire` and `quartz` features, see "Quartz on JVM" above)
parses a 6/7-field expression, not the 5-field Unix dialect above:
`cronExprToQuartz(cron)` renders it as `"<0> <minute> <hour> <dom> <month>
<dow>"` — a leading literal `"0"` seconds field — with Quartz's `?`
day-of-month/day-of-week disambiguation rule applied (Quartz requires
exactly one of the two to be `?`; whichever Unix field is `*` becomes `?`,
and if both are `*` day-of-week becomes `?`) and Unix's `0-7`
(Sunday=`0`/`7`) day-of-week numbering renumbered to Quartz's `1-7`
(Sunday=`1`). `Err` when *both* day-of-month and day-of-week are restricted
(not representable as a single Quartz expression — Quartz has no OR
semantics between the two the way Unix cron does). `Jobs`'s own JVM dispatch
path applies this conversion automatically before calling into
`Jobs.Kernel.Jvm.schedule`, so `NativeJobScheduler.schedule`'s real Quartz
`CronScheduleBuilder` always receives a dialect-correct string; on `dotnet`
the plain 5-field string is forwarded as-is (moot today — the `inprocess`
backend ignores cron content, and `hangfire`/`quartz` fail at `connect()`
before ever reaching a cron string, both tracked as Phase 3 follow-ups of
#733).

## API reference

```lyric
Jobs.connect()                                          // Result[NativeJobScheduler, String]
Jobs.connectHangfire()                                   // Result[NativeJobScheduler, String] (`hangfire` feature)
Jobs.connectQuartz()                                     // Result[NativeJobScheduler, String] (`quartz` feature)
Jobs.inProcess()                                         // InProcessJobScheduler
Jobs.enqueue(scheduler, name, payload)                   // Result[String, String] (job ID)
Jobs.enqueueWith(scheduler, name, payload, maxAttempts, timeoutMs)  // Result[String, String]
Jobs.schedule(scheduler, name, payload, cronExpr)        // Result[String, String] (job ID); cronExpr: String, parsed internally
Jobs.scheduleCron(scheduler, name, payload, cron)        // Result[String, String]; cron: CronExpr
Jobs.scheduleCronWith(scheduler, name, payload, cron, maxAttempts, timeoutMs)  // Result[String, String]
Jobs.cancel(scheduler, jobId)                            // Result[Unit, String]
Jobs.status(scheduler, jobId)                            // Result[JobStatus, String]
Jobs.results(scheduler, jobId)                           // Result[JobResultList, String]
Jobs.runNext(scheduler, handler)                         // Result[JobResult, String] (InProcessJobScheduler only)
Jobs.runAll(scheduler, handler)                          // slice[JobResult] (InProcessJobScheduler only)
Jobs.attemptCount(scheduler, jobId)                      // Int (InProcessJobScheduler only)
Jobs.parseCron(s)                                        // Result[CronExpr, String]
Jobs.cronExprToString(cron)                              // String (canonical 5-field form)
Jobs.cronExprToQuartz(cron)                              // Result[String, String] (Quartz's 6/7-field dialect)
```

## Aspect templates (`Jobs.Aspects`)

### Retryable

B-mode: automatically retries failed job handlers with exponential backoff.

```lyric
import Jobs.Aspects

aspect EmailRetry from Jobs.Aspects.Retryable {
  matches: name like "send*Email"
  config { maxAttempts: Int = 3; initialDelayMs: Int = 1000 }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `maxAttempts` | `Int` | `3` | Total attempts including the first; at least 1 |
| `initialDelayMs` | `Int` | `500` | Delay before the second attempt; 0 to `maxDelayMs` |
| `backoffFactor` | `Int` | `2` | Delay multiplier per retry; below 1 counts as 1 |
| `maxDelayMs` | `Int` | `30000` | Upper bound on any single delay |

The delay before retry *n* is `initialDelayMs × backoffFactor^(n-1)`, capped
at `maxDelayMs` (`Resilience.backoffDelay`).

A configuration outside these bounds is a bug, reported before the handler
runs: the aspect panics with a message naming the values. Earlier versions
accepted `maxAttempts = 0` (no retries) and an `initialDelayMs` above
`maxDelayMs` (silently clamped); set `maxAttempts = 1` and lower
`initialDelayMs` instead.

### Timed

B-mode: logs slow-running jobs via `println`.

```lyric
aspect JobTiming from Jobs.Aspects.Timed {
  matches: matches any
  config { thresholdMs: Int = 5000 }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `thresholdMs` | `Int` | `5000` | Log if job takes longer than threshold |

## Decision log

See `docs/03-decision-log.md` D060 and `docs/10-bootstrap-progress.md`.
