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

## API reference

```lyric
Jobs.connect()                                          // Result[NativeJobScheduler, String]
Jobs.connectHangfire()                                   // Result[NativeJobScheduler, String] (`hangfire` feature)
Jobs.connectQuartz()                                     // Result[NativeJobScheduler, String] (`quartz` feature)
Jobs.inProcess()                                         // InProcessJobScheduler
Jobs.enqueue(scheduler, name, payload)                   // Result[String, String] (job ID)
Jobs.enqueueWith(scheduler, name, payload, maxAttempts, timeoutMs)  // Result[String, String]
Jobs.schedule(scheduler, name, payload, cronExpr)        // Result[String, String] (job ID)
Jobs.cancel(scheduler, jobId)                            // Result[Unit, String]
Jobs.status(scheduler, jobId)                            // Result[JobStatus, String]
Jobs.results(scheduler, jobId)                           // Result[JobResultList, String]
Jobs.runNext(scheduler, handler)                         // Result[JobResult, String] (InProcessJobScheduler only)
Jobs.runAll(scheduler, handler)                          // slice[JobResult] (InProcessJobScheduler only)
```

## Aspect templates (`Jobs.Aspects`)

### Retryable

B-mode: automatically retries failed job handlers with exponential backoff.

```lyric
import Jobs.Aspects

aspect EmailRetry from Jobs.Aspects.Retryable {
  matches: name like "send*Email"
  config { maxAttempts: Int = 3; backoffMs: Int = 1000 }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `maxAttempts` | `Int` | `3` | Maximum retry count |
| `backoffMs` | `Int` | `1000` | Initial exponential backoff in milliseconds |

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
