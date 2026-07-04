# lyric-jobs

Background job scheduling with pluggable backends (Hangfire, Quartz.NET).

## Platform parity

**`InProcessJobScheduler` is production-ready on both targets** (pure
Lyric, no kernel dependency). Beyond that, the two targets diverge in an
unusual direction — `jvm` actually has *more* real backend coverage than
`dotnet` today:

| Feature flag | Backend                     | Status                                                                 |
|--------------|------------------------------|-------------------------------------------------------------------------|
| `dotnet`     | `InProcessJobScheduler`      | Available                                                                |
| `dotnet`     | `hangfire`, `quartz`         | `NOT_IMPLEMENTED` — `connect()` returns an error (`jobs_kernel.l:254,262`, tracked as a Phase 3 follow-up of #733) |
| `jvm`        | `InProcessJobScheduler`      | Available                                                                |
| `jvm`        | `hangfire`, `quartz`         | Real `extern package org.quartz.Scheduler` bindings (both features map to Quartz — Hangfire has no JVM port) — genuine implementation, not a stub |

The JVM kernel's Quartz binding is real Lyric FFI source, not a
placeholder — but the overall `jvm` target still needs the out-of-repo
Lyric JVM stdlib JAR to produce a runnable artifact end-to-end, so
"real binding code" and "runnable today" are two different claims. See
`docs/57-stdlib-ecosystem-library-review.md` §3 (this table corrects
that document's earlier, inaccurate claim that Quartz/Hangfire were
stub-only on both targets).

## Packages

| Package | Purpose |
|---|---|
| `Jobs` | Core types, `JobScheduler` interface, in-process implementation, and public API |
| `Jobs.Aspects` | Reusable aspect templates: `Retryable` and `Timed` |

## Quick start

```lyric
import Jobs

val scheduler = Jobs.inProcess()

val spec = Jobs.JobSpec(
  name: "email-sender",
  handler: "sendEmail",
  args: ["user@example.com"],
  delaySeconds: 0
)

Jobs.enqueue(scheduler, spec)

match Jobs.status(scheduler, jobId) {
  case Jobs.JobStatus.Pending   -> println("queued")
  case Jobs.JobStatus.Running   -> println("in progress")
  case Jobs.JobStatus.Completed -> println("done")
  case Jobs.JobStatus.Failed    -> println("error")
}
```

## JobScheduler interface

`JobScheduler` is a pluggable interface supporting multiple backends:

```lyric
pub interface JobScheduler {
  func enqueue(spec: in JobSpec): String
  func schedule(spec: in JobSpec, atEpochMs: in Long): String
  func cancel(jobId: in String): Bool
  func status(jobId: in String): JobStatus
  func results(jobId: in String): List[JobResult]
}
```

The v1 implementation is `InProcessJobScheduler` (in-memory, single-process).
For production use, deploy with the `hangfire` or `quartz` backend via feature flags.

## Backends

### In-process (`InProcessJobScheduler`)

`Jobs.inProcess()` runs jobs sequentially in-memory. Best for development and testing.

### Hangfire (`hangfire` feature)

`Jobs.connectHangfire(connectionString)` connects to Hangfire on `dotnet`,
and to Quartz Scheduler (as a functional substitute — Hangfire has no JVM
port) on `jvm`. **On `dotnet`, this currently returns
`Err("... not yet implemented")`** — the real .NET Hangfire binding is
tracked as a Phase 3 follow-up of #733. On `jvm` it's a real binding.

| Env var | Default | Meaning |
|---|---|---|---|
| `LYRIC_JOBS_HANGFIRE_CONNECTION` | (required) | SQL Server or Redis connection string |

### Quartz (`quartz` feature)

`Jobs.connectQuartz(datasourceUrl)` connects to Quartz.NET on `dotnet`
(requires an ADO.NET-compatible data source for persistence) or to real
Quartz Scheduler on `jvm`. **On `dotnet`, this currently returns
`Err("... not yet implemented")`**, same tracking as Hangfire above. On
`jvm` it's a real binding (in-memory `RAMJobStore`, not persistent).

## API reference

```lyric
Jobs.enqueue(scheduler, spec)                    // String (job ID)
Jobs.enqueueWith(scheduler, spec, delay)         // String (job ID)
Jobs.schedule(scheduler, spec, epochMs)          // String (job ID)
Jobs.cancel(scheduler, jobId)                    // Bool
Jobs.status(scheduler, jobId)                    // JobStatus
Jobs.results(scheduler, jobId)                   // List[JobResult]
Jobs.runNext(scheduler)                          // Unit (in-process only)
Jobs.runAll(scheduler)                           // Unit (in-process only)
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
