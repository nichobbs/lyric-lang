// Jobs — background job scheduling and execution library for Lyric.
//
// `JobScheduler` is the public interface; implement it to add a custom
// backend.  Two implementations are provided:
//
//   NativeJobScheduler   — delegates to Jobs.Kernel.Net (Hangfire or Quartz)
//   InProcessJobScheduler — in-memory queue for tests and single-process use
//
// Supported backends (feature-gated via lyric.toml [features]):
//   hangfire — Hangfire.Core + Hangfire.SqlServer background processing
//   quartz   — Quartz.NET cron-capable scheduler
//
// Usage:
//
//   import Jobs
//   import Std.Core
//
//   val scheduler = Jobs.connect()?
//   val jobId     = Jobs.enqueue(scheduler, "send-email", "{\"to\":\"user@example.com\"}")?
//   match Jobs.status(scheduler, jobId) {
//     case Ok(s)  -> println("job status: " + s.toString())
//     case Err(e) -> println("error: " + e)
//   }
//
// Runtime config env vars (LYRIC_CONFIG_JOBS_DEFAULTS_*):
//   LYRIC_CONFIG_JOBS_DEFAULTS_MAXATTEMPTS       — retry limit (default: 3)
//   LYRIC_CONFIG_JOBS_DEFAULTS_DEFAULTTIMEOUTMS  — execution timeout ms (default: 30000)
//   LYRIC_CONFIG_JOBS_DEFAULTS_WORKERCOUNT       — parallel worker threads (default: 4)
//
// See docs/03-decision-log.md D056 and lyric-jobs/README.md.

@runtime_checked
package Jobs

import Std.Core
import Std.Collections
import Std.Parse
import Std.Iter
import Jobs.Kernel.Net

// ─── Type aliases ─────────────────────────────────────────────────────────────

/// A unique job identifier (opaque string).  Obtained from `enqueue` or `schedule`.
@stable(since="0.1")
pub alias JobId = String

// ─── Enumerations ─────────────────────────────────────────────────────────────

/// The execution state of a background job.
@stable(since="0.1")
pub enum JobStatus {
  /// Waiting to be picked up by a worker.
  case Pending
  /// Currently being executed by a worker.
  case Running
  /// Completed without error.
  case Succeeded
  /// All attempts exhausted with an error.
  case Failed
  /// Cancelled before or during execution.
  case Cancelled
}

// ─── Core records ─────────────────────────────────────────────────────────────

/// The specification for a job submitted to the scheduler.
///
/// `payload` is an application-defined string (typically JSON) that the
/// handler receives.  `scheduledAt` is 0 for immediate enqueue or an
/// epoch-millisecond timestamp for deferred / cron jobs.
@stable(since="0.1")
pub record JobSpec {
  id:          String
  name:        String
  payload:     String
  maxAttempts: Int
  timeoutMs:   Int
  scheduledAt: Long    // epoch ms; 0 = enqueue immediately
}

/// The recorded outcome of a job execution attempt.
@stable(since="0.1")
pub record JobResult {
  jobId:      String
  status:     JobStatus
  output:     String    // handler-produced output (empty when not Succeeded)
  error:      String    // error description (empty when not Failed)
  startedAt:  Long      // epoch ms
  finishedAt: Long      // epoch ms
}

/// A list of job results returned by `JobScheduler.results`.
/// Wraps `slice[JobResult]` to avoid TypeBuilder-instantiation limitations
/// when the slice type appears as a generic argument.
@stable(since="0.1")
pub record JobResultList {
  items: slice[JobResult]
}

/// A structured error returned by a `JobHandler`.
@stable(since="0.1")
pub record JobError {
  message: String
  code:    String    // application-defined error code; "" when unspecified
}

// ─── Handler interface ────────────────────────────────────────────────────────

/// Implement this interface to register a job handler for a given job name.
///
/// `handle` receives the full `JobSpec` and must return either `Ok(output)`
/// where `output` is an application-defined result string, or `Err(JobError)`
/// on failure.  The scheduler will retry the job up to `spec.maxAttempts`
/// times before marking it as `Failed`.
@stable(since="0.1")
pub interface JobHandler {
  func handle(spec: in JobSpec): Result[String, JobError]
    requires: spec.id.length > 0
    requires: spec.name.length > 0
    requires: spec.maxAttempts >= 1
}

// ─── Scheduler interface ──────────────────────────────────────────────────────

/// Interface for submitting, querying, and cancelling background jobs.
@stable(since="0.1")
pub interface JobScheduler {
  /// Enqueue a job for immediate execution.  Returns the assigned String.
  func enqueue(
    name:        in String,
    payload:     in String,
    maxAttempts: in Int,
    timeoutMs:   in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1

  /// Schedule a recurring job using a cron expression.  Returns the String.
  func schedule(
    name:        in String,
    payload:     in String,
    cronExpr:    in String,
    maxAttempts: in Int,
    timeoutMs:   in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1

  /// Cancel a pending or running job.  No-op if the job has already completed.
  func cancel(jobId: in String): Result[Unit, String]
    requires: jobId.length > 0

  /// Return the current status of a job.
  func status(jobId: in String): Result[JobStatus, String]
    requires: jobId.length > 0

  /// Return all recorded results for a job (one per attempt).
  func results(jobId: in String): Result[JobResultList, String]
    requires: jobId.length > 0
}

// ─── Native scheduler (backend-backed) ───────────────────────────────────────

/// Backend-backed scheduler.  Obtain one via `Jobs.connect()`.
@stable(since="0.1")
pub record NativeJobScheduler {
  schedulerId: Int    // opaque handle issued by the kernel
}

impl JobScheduler for NativeJobScheduler {
  func enqueue(
    name:        in String,
    payload:     in String,
    maxAttempts: in Int,
    timeoutMs:   in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    return jobsEnqueueBackend(self.schedulerId, name, payload, maxAttempts, timeoutMs)
  }

  func schedule(
    name:        in String,
    payload:     in String,
    cronExpr:    in String,
    maxAttempts: in Int,
    timeoutMs:   in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    return jobsScheduleBackend(self.schedulerId, name, payload, cronExpr, maxAttempts, timeoutMs)
  }

  func cancel(jobId: in String): Result[Unit, String]
    requires: jobId.length > 0
  {
    return jobsCancelBackend(self.schedulerId, jobId)
  }

  func status(jobId: in String): Result[JobStatus, String]
    requires: jobId.length > 0
  {
    match jobsStatusBackend(self.schedulerId, jobId) {
      case Err(msg)    -> Err(msg)
      case Ok(rawStr)  -> Ok(parseStatus(rawStr))
    }
  }

  func results(jobId: in String): Result[JobResultList, String]
    requires: jobId.length > 0
  {
    match jobsResultsBackend(self.schedulerId, jobId) {
      case Err(msg)    -> Err(msg)
      case Ok(jsonStr) -> Ok(JobResultList(items = parseResults(jobId, jsonStr)))
    }
  }
}

// ─── In-process scheduler (for testing) ──────────────────────────────────────

/// In-memory job scheduler; useful for unit tests and single-process apps.
///
/// Jobs are executed synchronously when `runNext()` is called, or you can
/// call `runAll()` to drain the entire queue.  There is no real cron support;
/// scheduled jobs are added to the queue with their cron expression stored in
/// the spec payload for test inspection.
///
/// Not thread-safe; use in single-threaded test scenarios only.
@stable(since="0.1")
pub record InProcessJobScheduler {
  var jobs:    Map[String, JobResult]
  var queue:   List[JobSpec]
  var counter: Int    // monotonic counter for ID generation
}

impl JobScheduler for InProcessJobScheduler {
  func enqueue(
    name:        in String,
    payload:     in String,
    maxAttempts: in Int,
    timeoutMs:   in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    self.counter = self.counter + 1
    val id = "inproc-" + self.counter.toString()
    val spec = JobSpec(
      id          = id,
      name        = name,
      payload     = payload,
      maxAttempts = maxAttempts,
      timeoutMs   = timeoutMs,
      scheduledAt = 0i64)
    self.queue.add(spec)
    val pending = JobResult(
      jobId      = id,
      status     = JobStatus.Pending,
      output     = "",
      error      = "",
      startedAt  = 0i64,
      finishedAt = 0i64)
    self.jobs[id] = pending
    return Ok(id)
  }

  func schedule(
    name:        in String,
    payload:     in String,
    cronExpr:    in String,
    maxAttempts: in Int,
    timeoutMs:   in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    // In-process scheduler does not evaluate cron expressions; the cron string
    // is stored for test inspection but the job is enqueued immediately.
    self.counter = self.counter + 1
    val id = "inproc-cron-" + self.counter.toString()
    val spec = JobSpec(
      id          = id,
      name        = name,
      payload     = "{\"cron\":\"" + jsonEscapeStr(cronExpr) + "\",\"payload\":" + payload + "}",
      maxAttempts = maxAttempts,
      timeoutMs   = timeoutMs,
      scheduledAt = 0i64)
    self.queue.add(spec)
    val pending = JobResult(
      jobId      = id,
      status     = JobStatus.Pending,
      output     = "",
      error      = "",
      startedAt  = 0i64,
      finishedAt = 0i64)
    self.jobs[id] = pending
    return Ok(id)
  }

  func cancel(jobId: in String): Result[Unit, String]
    requires: jobId.length > 0
  {
    match mapGet(self.jobs, jobId) {
      case None -> Ok(())    // Job not found; treat as no-op.
      case Some(result) -> {
        match result.status {
          case JobStatus.Succeeded -> Ok(())
          case JobStatus.Failed    -> Ok(())
          case JobStatus.Cancelled -> Ok(())
          case _ -> {
            val cancelled = JobResult(
              jobId      = jobId,
              status     = JobStatus.Cancelled,
              output     = "",
              error      = "cancelled",
              startedAt  = result.startedAt,
              finishedAt = nowMs())
            self.jobs[jobId] = cancelled
            // Remove matching entries from the pending queue (iterate backward).
            var i = self.queue.count - 1
            while i >= 0 {
              if self.queue[i].id == jobId {
                self.queue.removeAt(i)
              }
              i = i - 1
            }
            Ok(())
          }
        }
      }
    }
  }

  func status(jobId: in String): Result[JobStatus, String]
    requires: jobId.length > 0
  {
    match mapGet(self.jobs, jobId) {
      case None         -> Err("job not found: " + jobId)
      case Some(result) -> Ok(result.status)
    }
  }

  func results(jobId: in String): Result[JobResultList, String]
    requires: jobId.length > 0
  {
    match mapGet(self.jobs, jobId) {
      case None         -> Err("job not found: " + jobId)
      case Some(result) -> Ok(JobResultList(items = [result]))
    }
  }
}

/// Execute the next pending job using the provided handler.
/// Returns Err("queue empty") when there are no pending jobs.
@stable(since="0.1")
pub func runNext(scheduler: inout InProcessJobScheduler, handler: in JobHandler): Result[JobResult, String] {
  if scheduler.queue.count == 0 {
    return Err("queue empty")
  }
  val spec = scheduler.queue[0]
  scheduler.queue.removeAt(0)
  val startMs = nowMs()
  val running = JobResult(
    jobId      = spec.id,
    status     = JobStatus.Running,
    output     = "",
    error      = "",
    startedAt  = startMs,
    finishedAt = 0i64)
  scheduler.jobs[spec.id] = running
  match handler.handle(spec) {
    case Ok(output) -> {
      val result = JobResult(
        jobId      = spec.id,
        status     = JobStatus.Succeeded,
        output     = output,
        error      = "",
        startedAt  = startMs,
        finishedAt = nowMs())
      scheduler.jobs[spec.id] = result
      return Ok(result)
    }
    case Err(jobErr) -> {
      val result = JobResult(
        jobId      = spec.id,
        status     = JobStatus.Failed,
        output     = "",
        error      = jobErr.message,
        startedAt  = startMs,
        finishedAt = nowMs())
      scheduler.jobs[spec.id] = result
      return Ok(result)
    }
  }
}

/// Drain the entire pending queue, executing each job with `handler`.
/// Returns the list of results in execution order.
@stable(since="0.1")
pub func runAll(scheduler: inout InProcessJobScheduler, handler: in JobHandler): slice[JobResult] {
  var results: slice[JobResult] = []
  while scheduler.queue.count > 0 {
    match runNext(scheduler, handler) {
      case Ok(r)  -> { results = concat(results, [r]) }
      case Err(_) -> ()    // runNext only returns Err on empty queue
    }
  }
  return results
}

// ─── Config ───────────────────────────────────────────────────────────────────
// Default scheduling and worker settings.
// (config block emitter not yet implemented; using module-level val constants)
val defaultMaxAttempts:      Int = 3
val defaultTimeoutMs:        Int = 30000
val defaultWorkerCount:      Int = 4

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open a backend scheduler connection using the configured defaults.
/// Returns a `NativeJobScheduler` backed by the active feature (Hangfire or Quartz).
@stable(since="0.1")
pub func connect(): Result[NativeJobScheduler, String] {
  match jobsConnectBackend(defaultWorkerCount) {
    case Ok(schedulerId) -> Ok(NativeJobScheduler(schedulerId = schedulerId))
    case Err(msg)        -> Err(msg)
  }
}

/// Create an in-process scheduler for testing.
@stable(since="0.1")
pub func inProcess(): InProcessJobScheduler {
  return InProcessJobScheduler(
    jobs    = newMap(),
    queue   = newList(),
    counter = 0)
}

// ─── Convenience wrappers ─────────────────────────────────────────────────────

/// Enqueue a job for immediate execution using the configured default limits.
@stable(since="0.1")
pub func enqueue(
  scheduler: in JobScheduler,
  name:      in String,
  payload:   in String
): Result[String, String]
  requires: name.length > 0
{
  return scheduler.enqueue(name, payload, defaultMaxAttempts, defaultTimeoutMs)
}

/// Enqueue a job with explicit retry and timeout settings.
@stable(since="0.1")
pub func enqueueWith(
  scheduler:   in JobScheduler,
  name:        in String,
  payload:     in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String]
  requires: name.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  return scheduler.enqueue(name, payload, maxAttempts, timeoutMs)
}

/// Schedule a recurring job using a cron expression.
@stable(since="0.1")
pub func schedule(
  scheduler: in JobScheduler,
  name:      in String,
  payload:   in String,
  cronExpr:  in String
): Result[String, String]
  requires: name.length > 0
  requires: cronExpr.length > 0
{
  return scheduler.schedule(name, payload, cronExpr, defaultMaxAttempts, defaultTimeoutMs)
}

/// Cancel a pending or running job.
@stable(since="0.1")
pub func cancel(scheduler: in JobScheduler, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  return scheduler.cancel(jobId)
}

/// Query the current status of a job.
@stable(since="0.1")
pub func status(scheduler: in JobScheduler, jobId: in String): Result[JobStatus, String]
  requires: jobId.length > 0
{
  return scheduler.status(jobId)
}

/// Return all recorded results for a job.
@stable(since="0.1")
pub func results(scheduler: in JobScheduler, jobId: in String): Result[JobResultList, String]
  requires: jobId.length > 0
{
  return scheduler.results(jobId)
}

/// Generate a new unique job ID using the platform kernel.
@stable(since="0.1")
pub func newJobId(): String {
  return generateId()
}



// ─── Private kernel stubs ─────────────────────────────────────────────────────
// When neither the hangfire nor the quartz feature is enabled the
// @cfg-guarded kernel functions are excluded from compilation.  These
// stubs stand in so the type-checker can resolve the call sites; at
// runtime they return Err to signal "no backend configured".

func jobsConnectBackend(workerCount: in Int): Result[Int, String] =
  Err("no backend configured; enable the hangfire or quartz feature in lyric.toml")

func jobsEnqueueBackend(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String] = Err("no backend configured")

func jobsScheduleBackend(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  cronExpr:    in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String] = Err("no backend configured")

func jobsCancelBackend(schedulerId: in Int, jobId: in String): Result[Unit, String] =
  Err("no backend configured")

func jobsStatusBackend(schedulerId: in Int, jobId: in String): Result[String, String] =
  Err("no backend configured")

func jobsResultsBackend(schedulerId: in Int, jobId: in String): Result[String, String] =
  Err("no backend configured")

// ─── Private helpers ──────────────────────────────────────────────────────────

// Parse a status string returned by the kernel into a JobStatus variant.
func parseStatus(raw: in String): JobStatus {
  match raw {
    case "Pending"   -> JobStatus.Pending
    case "Running"   -> JobStatus.Running
    case "Succeeded" -> JobStatus.Succeeded
    case "Failed"    -> JobStatus.Failed
    case "Cancelled" -> JobStatus.Cancelled
    case _           -> JobStatus.Failed    // Unknown status → treat as failed.
  }
}

// Parse a JSON array of job result objects from the kernel into a list.
// Wire format: [{"jobId":"...","status":"...","output":"...","error":"...",
//                "startedAt":N,"finishedAt":N},...]
func parseResults(jobId: in String, json: in String): slice[JobResult] {
  if json == "[]" or json == "" {
    return []
  }
  var results: slice[JobResult] = []
  var pos: Int = 0
  while pos < json.length {
    val objStart = json.indexOf("{", pos)
    if objStart < 0 { pos = json.length }
    else {
      val objEnd = findObjectEnd(json, objStart)
      if objEnd < 0 { pos = json.length }
      else {
        val obj        = json.substring(objStart, objEnd + 1)
        val statusStr  = jsonExtractString(obj, "status")
        val output     = jsonExtractString(obj, "output")
        val error      = jsonExtractString(obj, "error")
        val startedAt  = jsonExtractLong(obj, "startedAt")
        val finishedAt = jsonExtractLong(obj, "finishedAt")
        results = concat(results, [JobResult(
          jobId      = jobId,
          status     = parseStatus(statusStr),
          output     = output,
          error      = error,
          startedAt  = startedAt,
          finishedAt = finishedAt)])
        pos = objEnd + 1
      }
    }
  }
  return results
}

// Find the closing brace of a JSON object, respecting nested braces.
func findObjectEnd(json: in String, start: in Int): Int {
  var depth: Int = 0
  var i:     Int = start
  while i < json.length {
    val ch = json[i]
    if ch == '{' { depth = depth + 1 }
    else if ch == '}' {
      depth = depth - 1
      if depth == 0 { return i }
    }
    i = i + 1
  }
  return -1
}

// Escape a string for JSON serialization (handles \, ", and common control chars).
func jsonEscapeStr(s: in String): String {
  var result = ""
  var i = 0
  while i < s.length {
    val ch = s[i].toString()
    if ch == "\\" {
      result = result + "\\\\"
    } else if ch == "\"" {
      result = result + "\\\""
    } else if ch == "\n" {
      result = result + "\\n"
    } else if ch == "\r" {
      result = result + "\\r"
    } else if ch == "\t" {
      result = result + "\\t"
    } else {
      result = result + ch
    }
    i = i + 1
  }
  return result
}

// Extract a string field from a JSON object literal (simple, no nesting).
func jsonExtractString(json: in String, field: in String): String {
  val needle = "\"" + field + "\":"
  val start  = json.indexOf(needle)
  if start < 0 { return "" }
  val afterColon = start + needle.length
  val q1 = json.indexOf("\"", afterColon)
  if q1 < 0 { return "" }
  val q2 = json.indexOf("\"", q1 + 1)
  if q2 < 0 { return "" }
  return json.substring(q1 + 1, q2)
}

// Extract a Long field from a JSON object literal.
func jsonExtractLong(json: in String, field: in String): Long {
  val needle = "\"" + field + "\":"
  val start  = json.indexOf(needle)
  if start < 0 { return 0i64 }
  val afterColon = start + needle.length
  var i: Int = afterColon
  while i < json.length and json[i] == ' ' { i = i + 1 }
  var numStr: String = ""
  while i < json.length and json[i] != ',' and json[i] != '}' {
    numStr = numStr + json[i].toString()
    i = i + 1
  }
  match parseOptLong(numStr.trim()) {
    case Some(n) -> return n
    case None    -> return 0i64
  }
}
