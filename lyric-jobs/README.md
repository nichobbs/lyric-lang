# lyric-jobs

Background job scheduling with pluggable backends (Hangfire, Quartz.NET).

## Platform parity

**`InProcessJobScheduler` is pure Lyric with no kernel dependency**
(defined directly in `src/jobs.l`), so it compiles wherever `jobs.l`
itself compiles.

| Feature flag | Backend                     | Status                                                                 |
|--------------|------------------------------|-------------------------------------------------------------------------|
| `dotnet`     | `InProcessJobScheduler`      | Available                                                                |
| `dotnet`     | `hangfire`, `quartz`         | `NOT_IMPLEMENTED` — `connect()` returns an error (`jobs_kernel.l:254,262`, tracked as a Phase 3 follow-up of #733) |
| `jvm`        | (any)                        | Not built today — `lyric-jobs/lyric.toml` registers no JVM package, no `jvm` feature flag, and no `[maven]` table |

There is no working JVM Quartz binding today. A `Jobs.Kernel.Jvm` file
using `extern package org.quartz.Scheduler` previously existed, but it
was dead code: `lyric.toml`'s `[project.packages]` never registered
it (only `Jobs.Kernel.Net` is), `jobs.l` never imported it, and
`extern package` is itself a confirmed no-op FFI mechanism in both the
type checker and both codegens (see `docs/03-decision-log.md`). It was
deleted rather than fixed in place — a real JVM Quartz backend needs a
`[maven]` dependency on `org.quartz-scheduler:quartz`, registration in
`[project.packages]`, and a rewrite onto the working `extern type` +
JVM auto-FFI mechanism (mirroring `lyric-stdlib/std/_kernel_jvm/`).
This corrects the previous version of this README, which claimed the
Quartz binding was "real Lyric FFI source, not a placeholder" —
that claim did not hold up under verification.

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
