# lyric-jobs

Background job scheduling with pluggable backends (Hangfire, Quartz.NET).

## Platform parity

| Feature flag | Backend                                                              | Status                |
|--------------|----------------------------------------------------------------------|-----------------------|
| `dotnet`     | Hangfire / Quartz.NET + `System.Threading.Timer`                     | Available             |
| `jvm`        | Quartz Java + `java.util.concurrent.ScheduledExecutorService`        | Planned (Phase 6)     |

The JVM kernel (`Jobs.Kernel.Jvm`) declares Quartz bindings against
`org.quartz-scheduler:quartz` plus `lyric.jobs.*` helpers; the JVM
helpers are supplied by the Lyric JVM stdlib JAR (out-of-repo).
Until that JAR ships, only the `dotnet` feature produces a runnable
artifact.

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

`Jobs.connectHangfire(connectionString)` connects to Hangfire. Set the connection
string via environment variable:

| Env var | Default | Meaning |
|---|---|---|---|
| `LYRIC_JOBS_HANGFIRE_CONNECTION` | (required) | SQL Server or Redis connection string |

### Quartz.NET (`quartz` feature)

`Jobs.connectQuartz(datasourceUrl)` connects to Quartz.NET. Requires a JDBC-compatible
data source for persistence.

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
