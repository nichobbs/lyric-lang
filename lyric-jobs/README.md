# lyric-jobs

Background job scheduling behind a `JobScheduler` interface, with an in-process reference backend.

## Platform parity

**`InProcessJobScheduler` is production-ready on both targets** (pure Lyric,
no kernel dependency; `Jobs.inProcess()`). The `dotnet` and `jvm` features
only select the platform kernel that supplies the clock, sleep and job-ID
primitives; they are mutually exclusive, so select the one matching
`--target`:

```sh
lyric test --manifest lyric-jobs/lyric.toml                       # dotnet
lyric test --manifest lyric-jobs/lyric.toml --target jvm --no-default-features --features jvm
```

The JVM suite runs in CI through `scripts/ci/jvm-ecosystem-suites.sh`.

## Migration from earlier releases

Hangfire, Quartz.NET and the JVM Quartz binding were removed from the public
API (D552, docs/71). The `dotnet` backends only ever returned
`NOT_IMPLEMENTED`; the JVM binding scheduled real Quartz jobs but could only
run a fixed no-op native command, never an application handler. Removed:

| Removed | Replacement |
|---|---|
| `Jobs.connect()`, `Jobs.connectHangfire()`, `Jobs.connectQuartz()` | `Jobs.inProcess()` |
| `NativeJobScheduler` | `InProcessJobScheduler`, or your own `JobScheduler` implementation |
| `Jobs.cronExprToQuartz` | none; it existed only to feed the Quartz kernel |
| feature `inprocess` | none; delete it from `--features` (the in-process scheduler needs no feature) |
| feature `hangfire` | none; the flag no longer exists and `--features hangfire` is rejected |
| feature `quartz` | none; the flag no longer exists and `--features quartz` is rejected |
| `[nuget]` entries `Hangfire.Core`, `Hangfire.SqlServer`, `Quartz`; `[maven]` entries `org.quartz-scheduler:quartz`, `quartz-jobs` | none; the package restores nothing |
| env var `LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING` | no longer read |

Durable backends (Hangfire, Quartz) belong in separate packages that implement
`JobScheduler` (D552 item 3); they are not part of this library.

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

One implementation is provided: `InProcessJobScheduler` (in-memory,
single-process, obtained via `Jobs.inProcess()`). Implement the interface to
add a durable backend in a separate package.

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

## API reference

```lyric
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
