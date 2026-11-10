//! Jobs — background job scheduling and execution library for Lyric.
//! Stability: @experimental — `InProcessJobScheduler`, the one in-tree
//! reference backend, is real and tested on `dotnet` and `jvm`.  Hangfire,
//! Quartz.NET and Quartz backends are not part of this package (docs/71,
//! D552); see lyric-jobs/README.md for the migration note.
//!
//! `JobScheduler` is the public interface; implement it to add a custom
//! backend.  One implementation is provided:
//!
//!   InProcessJobScheduler — in-memory queue for tests and single-process use
//!
//! Usage:
//!
//!   import Jobs
//!   import Std.Core
//!
//!   val scheduler = Jobs.inProcess()
//!   val jobId     = Jobs.enqueue(scheduler, "send-email", "{\"to\":\"user@example.com\"}")?
//!   match Jobs.status(scheduler, jobId) {
//!     case Ok(s)  -> println("job status: " + s.toString())
//!     case Err(e) -> println("error: " + e)
//!   }
//!
//! The `dotnet` and `jvm` features select the platform kernel
//! (`Jobs.Kernel.Net` / `Jobs.Kernel.Jvm`) that supplies the clock, sleep and
//! job-ID primitives; exactly one must be active, matching `--target`.
//!
//! See docs/03-decision-log.md D056 and lyric-jobs/README.md.
@runtime_checked
@io
package Jobs

import Std.Core
import Std.Collections
import Std.Parse
import Std.Iter
import Std.Char
import Jobs.Kernel.Net as KernelNet
import Jobs.Kernel.Jvm as KernelJvm
import Std.String as Str

// ─── Platform kernel dispatch ─────────────────────────────────────────────────
// `Jobs.Kernel.Net` / `Jobs.Kernel.Jvm` are imported aliased so these thin
// wrappers can re-export the platform's real clock, sleep and identity
// primitives under `Jobs`'s own name; the rest of this file (and
// `Jobs.Aspects`, which calls `nowMs()` bare after `import Jobs`) then keeps
// working unqualified.
@cfg(feature = "dotnet")
pub func nowMs(): Long {
  KernelNet.nowMs()
}

@cfg(feature = "jvm")
pub func nowMs(): Long {
  KernelJvm.nowMs()
}

@cfg(feature = "dotnet")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  KernelNet.sleepMs(ms)
}

@cfg(feature = "jvm")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  KernelJvm.sleepMs(ms)
}

@cfg(feature = "dotnet")
func generateId(): String {
  KernelNet.generateId()
}

@cfg(feature = "jvm")
func generateId(): String {
  KernelJvm.generateId()
}

// ─── Type aliases ─────────────────────────────────────────────────────────────
/// A unique job identifier (opaque string).  Obtained from `enqueue` or `schedule`.
@stable(since = "0.1")
pub alias JobId = String

// ─── Enumerations ─────────────────────────────────────────────────────────────
/// The execution state of a background job.
@stable(since = "0.1")
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
@stable(since = "0.1")
pub record JobSpec {
  id: String
  name: String
  payload: String
  maxAttempts: Int
  timeoutMs: Int
  scheduledAt: Long    // epoch ms; 0 = enqueue immediately
  invariant: id.length > 0 and name.length > 0
  invariant: maxAttempts >= 1 and timeoutMs >= 1 and scheduledAt >= 0
}

/// The recorded outcome of a job execution attempt.
@stable(since = "0.1")
pub record JobResult {
  jobId: String
  status: JobStatus
  output: String    // handler-produced output (empty when not Succeeded)
  error: String    // error description (empty when not Failed)
  startedAt: Long      // epoch ms
  finishedAt: Long      // epoch ms
  invariant: finishedAt == 0 or finishedAt >= startedAt
}

/// A list of job results returned by `JobScheduler.results`.
/// Wraps `slice[JobResult]` to avoid TypeBuilder-instantiation limitations
/// when the slice type appears as a generic argument.
@stable(since = "0.1")
pub record JobResultList {
  items: slice[JobResult]
}

/// A structured error returned by a `JobHandler`.
@stable(since = "0.1")
pub record JobError {
  message: String
  code: String    // application-defined error code; "" when unspecified
}

// ─── Cron expressions ─────────────────────────────────────────────────────────
/// A validated cron expression, exactly one dialect: standard 5-field Unix
/// cron (`minute hour day-of-month month day-of-week`, single-space
/// separated). Construct with `parseCron`; the fields are private so a
/// `CronExpr` value is always valid.
///
/// Each field accepts, per POSIX/Vixie cron:
///   `*`                 — every value
///   a bare number        — within the field's range
///   `a-b`                — an inclusive range
///   `*/n` or `a-b/n`      — a step (n >= 1)
///   a comma-separated list of any of the above
///
/// Field ranges: minute 0-59, hour 0-23, day-of-month 1-31, month 1-12,
/// day-of-week 0-7 (both 0 and 7 mean Sunday, the Unix convention).
@stable(since = "0.1")
pub opaque type CronExpr {
  minuteField: String
  hourField: String
  domField: String
  monthField: String
  dowField: String
}

/// Parse and validate a standard 5-field Unix cron expression. Returns
/// `Err` naming the offending field on any dialect violation.
@stable(since = "0.1")
pub func parseCron(s: in String): Result[CronExpr, String] {
  val fields = splitStr(s, " ")
  if fields.length != 5 {
    return Err(
      "cron: expected 5 space-separated fields (minute hour day-of-month month day-of-week), got " +
        fields.length.toString() +
        " in '" +
        s +
        "'"
    )
  }
  match validateCronField(fields[0], "minute", 0, 59) {
    case Err(e) -> return Err(e)
    case Ok(_) -> ()
  }
  match validateCronField(fields[1], "hour", 0, 23) {
    case Err(e) -> return Err(e)
    case Ok(_) -> ()
  }
  match validateCronField(fields[2], "day-of-month", 1, 31) {
    case Err(e) -> return Err(e)
    case Ok(_) -> ()
  }
  match validateCronField(fields[3], "month", 1, 12) {
    case Err(e) -> return Err(e)
    case Ok(_) -> ()
  }
  match validateCronField(fields[4], "day-of-week", 0, 7) {
    case Err(e) -> return Err(e)
    case Ok(_) -> ()
  }
  return Ok(
    CronExpr(
      minuteField = fields[0],
      hourField = fields[1],
      domField = fields[2],
      monthField = fields[3],
      dowField = fields[4]
    )
  )
}

/// The canonical 5-field Unix cron string for `c`.
@stable(since = "0.1")
pub func cronExprToString(c: in CronExpr): String {
  return c.minuteField + " " + c.hourField + " " + c.domField + " " + c.monthField + " " + c.dowField
}

// Validate one comma-separated cron field against [minV, maxV].
func validateCronField(field: in String, fieldName: in String, minV: in Int, maxV: in Int): Result[Unit, String] {
  if field.length == 0 {
    return Err("cron: " + fieldName + " field is empty")
  }
  val items = splitStr(field, ",")
  var i = 0
  while i < items.length {
    match validateCronItem(items[i], fieldName, minV, maxV) {
      case Err(e) -> return Err(e)
      case Ok(_) -> ()
    }
    i = i + 1
  }
  return Ok(())
}

// Validate one list item: `*`, `*/n`, `a-b`, `a-b/n`, or a bare number.
func validateCronItem(item: in String, fieldName: in String, minV: in Int, maxV: in Int): Result[Unit, String] {
  if item.length == 0 {
    return Err("cron: " + fieldName + " field has an empty list entry")
  }
  val slashParts = splitStr(item, "/")
  if slashParts.length > 2 {
    return Err("cron: " + fieldName + " field entry '" + item + "' has more than one '/'")
  }
  if slashParts.length == 2 {
    if not isAllAsciiDigits(slashParts[1]) {
      return Err("cron: " + fieldName + " field step '" + slashParts[1] + "' is not a valid integer")
    }
    match parseOptInt(slashParts[1]) {
      case None -> return Err("cron: " + fieldName + " field step '" + slashParts[1] + "' is not a valid integer")
      case Some(step) -> {
        if step < 1 {
          return Err("cron: " + fieldName + " field step '" + slashParts[1] + "' must be >= 1")
        }
      }
    }
  }
  val base = slashParts[0]
  if base == "*" {
    return Ok(())
  }
  return validateCronRangeOrNumber(base, fieldName, minV, maxV)
}

// Validate `base` as either a bare number or an `a-b` range within [minV, maxV].
func validateCronRangeOrNumber(base: in String, fieldName: in String, minV: in Int, maxV: in Int): Result[Unit, String] {
  val dashParts = splitStr(base, "-")
  if dashParts.length == 1 {
    return validateCronNumber(dashParts[0], fieldName, minV, maxV)
  } else if dashParts.length == 2 {
    match validateCronNumber(dashParts[0], fieldName, minV, maxV) {
      case Err(e) -> return Err(e)
      case Ok(_) -> ()
    }
    match validateCronNumber(dashParts[1], fieldName, minV, maxV) {
      case Err(e) -> return Err(e)
      case Ok(_) -> ()
    }
    val lo = parseOptInt(dashParts[0])
    val hi = parseOptInt(dashParts[1])
    match lo {
      case Some(loV) -> {
        match hi {
          case Some(hiV) -> {
            if loV > hiV {
              return Err("cron: " + fieldName + " field range '" + base + "' has start greater than end")
            }
          }
          case None -> ()
        }
      }
      case None -> ()
    }
    return Ok(())
  } else {
    return Err("cron: " + fieldName + " field entry '" + base + "' has more than one '-'")
  }
}

// True when `s` is non-empty and every character is an ASCII digit (0-9);
// rejects a leading `+`/`-` and any embedded whitespace that `parseOptInt`
// would otherwise silently tolerate.
func isAllAsciiDigits(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    if not isAsciiDigit(Str.charAtOrReplacement(s, i)) {
      return false
    }
    i = i + 1
  }
  return true
}

// Validate `numStr` as a bare integer within [minV, maxV]. Every character
// must be an ASCII digit — `parseOptInt` alone also accepts a leading `+`
// and surrounding whitespace, which cron numbers (bare, range-endpoint, or
// step) must not.
func validateCronNumber(numStr: in String, fieldName: in String, minV: in Int, maxV: in Int): Result[Unit, String] {
  if not isAllAsciiDigits(numStr) {
    return Err("cron: " + fieldName + " field value '" + numStr + "' is not a valid integer")
  }
  match parseOptInt(numStr) {
    case None -> return Err("cron: " + fieldName + " field value '" + numStr + "' is not a valid integer")
    case Some(n) -> {
      if n < minV or n > maxV {
        return Err(
          "cron: " + fieldName + " field value '" + numStr + "' out of range [" + minV.toString() + "," +
            maxV.toString() +
            "]"
        )
      }
      return Ok(())
    }
  }
}

// ─── Handler interface ────────────────────────────────────────────────────────
/// Implement this interface to register a job handler for a given job name.
///
/// `handle` receives the full `JobSpec` and must return either `Ok(output)`
/// where `output` is an application-defined result string, or `Err(JobError)`
/// on failure.  The scheduler will retry the job up to `spec.maxAttempts`
/// times before marking it as `Failed`.
///
/// `spec`'s shape constraints (non-empty `id`/`name`, `maxAttempts >= 1`,
/// `timeoutMs >= 1`, `scheduledAt >= 0`) are carried as `invariant:` clauses
/// on `JobSpec` itself rather than as `requires:` here — a `JobSpec` that
/// violates them can never be constructed in the first place, so blame for
/// a bad spec lands on whichever scheduler built it, not on this interface.
@stable(since = "0.1")
pub interface JobHandler {
  func handle(spec: in JobSpec): Result[String, JobError]
}

// ─── Scheduler interface ──────────────────────────────────────────────────────
/// Interface for submitting, querying, and cancelling background jobs.
@stable(since = "0.1")
pub interface JobScheduler {
  /// Enqueue a job for immediate execution.  Returns the assigned String.
  func enqueue(name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1

  /// Schedule a recurring job using a cron expression.  Returns the String.
  /// `cronExpr` must be a valid standard 5-field Unix cron expression (see
  /// `parseCron`); every implementation validates it and returns `Err` on an
  /// invalid expression rather than forwarding it unchecked.
  func schedule(name: in String, payload: in String, cronExpr: in String, maxAttempts: in Int, timeoutMs: in Int): Result[String, String]
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

// ─── In-process scheduler (for testing) ──────────────────────────────────────
/// In-memory job scheduler; useful for unit tests and single-process apps.
///
/// Jobs are executed synchronously when `runNext()` is called, or you can
/// call `runAll()` to drain the entire queue.  There is no real cron support;
/// scheduled jobs are added to the queue with their cron expression stored in
/// the spec payload for test inspection.
///
/// Not thread-safe; use in single-threaded test scenarios only.
@stable(since = "0.1")
pub ref record InProcessJobScheduler {
  var jobs: Map[String, JobResult]
  var queue: List[JobSpec]
  var counter: Int    // monotonic counter for ID generation
  var attempts: Map[String, Int]    // total attempts run so far, keyed by job ID
}

impl JobScheduler for InProcessJobScheduler {
  func enqueue(name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    self.counter = self.counter + 1
    val id = "inproc-" + self.counter.toString()
    val spec = JobSpec(
      id = id,
      name = name,
      payload = payload,
      maxAttempts = maxAttempts,
      timeoutMs = timeoutMs,
      scheduledAt = 0i64
    )
    self.queue.add(spec)
    val pending = JobResult(
      jobId = id,
      status = JobStatus.Pending,
      output = "",
      error = "",
      startedAt = 0i64,
      finishedAt = 0i64
    )
    self.jobs[id] = pending
    return Ok(id)
  }

  func schedule(
    name: in String, payload: in String, cronExpr: in String, maxAttempts: in Int, timeoutMs: in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    // In-process scheduler does not evaluate cron expressions; the cron
    // string is stored for test inspection but the job is enqueued
    // immediately. `cronExpr` is validated (as a standard 5-field Unix
    // dialect) before storage, and both it and
    // `payload` are embedded as JSON *string* values (not spliced in raw),
    // so neither can inject extra keys into the wrapper object.
    match parseCron(cronExpr) {
      case Err(e) -> return Err(e)
      case Ok(cron) -> {
        self.counter = self.counter + 1
        val id = "inproc-cron-" + self.counter.toString()
        val spec = JobSpec(
          id = id,
          name = name,
          payload = "{\"cron\":\"" + jsonEscapeStr(cronExprToString(cron)) + "\",\"payload\":\"" +
            jsonEscapeStr(payload) +
            "\"}",
          maxAttempts = maxAttempts,
          timeoutMs = timeoutMs,
          scheduledAt = 0i64
        )
        self.queue.add(spec)
        val pending = JobResult(
          jobId = id,
          status = JobStatus.Pending,
          output = "",
          error = "",
          startedAt = 0i64,
          finishedAt = 0i64
        )
        self.jobs[id] = pending
        return Ok(id)
      }
    }
  }

  func cancel(jobId: in String): Result[Unit, String]
    requires: jobId.length > 0
  {
    match mapGet(self.jobs, jobId) {
      case None -> Ok(())    // Job not found; treat as no-op.
      case Some(found) -> {
        // Re-typed local (rather than reading `.status` off `found`
        // directly): on `--target jvm`, a value read out of an
        // `Option[JobResult]` produced by a generic `Map[String, JobResult]`
        // lookup is erased, and a field read on it fails to resolve at
        // compile time (a general JVM backend generics gap, not specific to
        // this map) unless it is first re-bound through an explicitly-typed
        // local.
        val result: JobResult = found
        match result.status {
          case JobStatus.Succeeded -> Ok(())
          case JobStatus.Failed -> Ok(())
          case JobStatus.Cancelled -> Ok(())
          case _ -> {
            val cancelled = JobResult(
              jobId = jobId,
              status = JobStatus.Cancelled,
              output = "",
              error = "cancelled",
              startedAt = result.startedAt,
              finishedAt = nowMs()
            )
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
      case None -> Err("job not found: " + jobId)
      case Some(found) -> {
        val result: JobResult = found    // see `cancel`'s comment on this re-typing
        Ok(result.status)
      }
    }
  }

  func results(jobId: in String): Result[JobResultList, String]
    requires: jobId.length > 0
  {
    match mapGet(self.jobs, jobId) {
      case None -> Err("job not found: " + jobId)
      case Some(result) -> Ok(JobResultList(items = [result]))
    }
  }
}

/// Run one attempt of `handler.handle(spec)`, catching a handler panic
/// (`Bug`) and reporting it as an ordinary failed attempt rather than
/// propagating it — an unhandled panic inside a scheduled job must not take
/// down the scheduler.
func runHandlerAttempt(handler: in JobHandler, spec: in JobSpec): Result[String, String] {
  try {
    match handler.handle(spec) {
      case Ok(output) -> Ok(output)
      case Err(jobErr) -> Err(jobErr.message)
    }
  } catch Bug as b {
    Err("handler panicked: " + b.message)
  }
}

/// Execute the next pending job using the provided handler, honouring
/// `spec.maxAttempts` and `spec.timeoutMs`:
///
///   - An `Err` result (or a caught handler panic, surfaced as `Bug`) is
///     retried immediately, up to `spec.maxAttempts` attempts in total. The
///     returned `JobResult` reflects only the last attempt's `output`/
///     `error`; `attemptCount` reports the total number of attempts run.
///   - `spec.timeoutMs` is enforced honestly for a synchronous, single-
///     threaded, in-process runner: the handler call itself cannot be
///     pre-empted, so this measures the *elapsed wall-clock time* of each
///     attempt after it returns and, if it exceeds `spec.timeoutMs`, discards
///     an otherwise-`Ok` result and counts that attempt as a failure (subject
///     to the same retry budget as a genuine `Err`). A handler that never
///     returns will hang `runNext` — there is no cancellation of in-flight
///     work here.
///
/// Returns `Err("queue empty")` when there are no pending jobs.
@stable(since = "0.1")
pub func runNext(scheduler: in InProcessJobScheduler, handler: in JobHandler): Result[JobResult, String] {
  if scheduler.queue.count == 0 {
    return Err("queue empty")
  }
  val spec = scheduler.queue[0]
  scheduler.queue.removeAt(0)
  val startMs = nowMs()
  val running = JobResult(
    jobId = spec.id,
    status = JobStatus.Running,
    output = "",
    error = "",
    startedAt = startMs,
    finishedAt = 0i64
  )
  scheduler.jobs[spec.id] = running

  var attempt = 1
  var succeeded = false
  var lastOutput = ""
  var lastError = ""
  while attempt <= spec.maxAttempts and not succeeded {
    val attemptStartMs = nowMs()
    match runHandlerAttempt(handler, spec) {
      case Ok(output) -> {
        val elapsedMs = nowMs() - attemptStartMs
        if elapsedMs > spec.timeoutMs.toLong() {
          lastError = "handler exceeded timeoutMs: took " + elapsedMs.toString() + "ms, limit " + spec.timeoutMs.toString() +
            "ms (the in-process scheduler cannot pre-empt a running handler; the overrun is only detected " +
            "after the handler returns, and that attempt is counted as failed)"
        } else {
          lastOutput = output
          succeeded = true
        }
      }
      case Err(msg) -> {
        lastError = msg
      }
    }
    scheduler.attempts[spec.id] = attempt
    attempt = attempt + 1
  }

  val finishedAt = nowMs()
  val result = if succeeded {
    JobResult(
      jobId = spec.id,
      status = JobStatus.Succeeded,
      output = lastOutput,
      error = "",
      startedAt = startMs,
      finishedAt = finishedAt
    )
  } else {
    JobResult(
      jobId = spec.id,
      status = JobStatus.Failed,
      output = "",
      error = lastError,
      startedAt = startMs,
      finishedAt = finishedAt
    )
  }
  scheduler.jobs[spec.id] = result
  return Ok(result)
}

/// The total number of attempts `runNext` has run for `jobId` so far (0 if
/// the job has never been run, e.g. it is still queued or was cancelled
/// before its first attempt).
@stable(since = "0.1")
pub func attemptCount(scheduler: in InProcessJobScheduler, jobId: in String): Int {
  match mapGet(scheduler.attempts, jobId) {
    case Some(n) -> n
    case None -> 0
  }
}

/// Drain the entire pending queue, executing each job with `handler`.
/// Returns the list of results in execution order.
@stable(since = "0.1")
pub func runAll(scheduler: in InProcessJobScheduler, handler: in JobHandler): slice[JobResult] {
  val results: List[JobResult] = newList()
  while scheduler.queue.count > 0 {
    match runNext(scheduler, handler) {
      case Ok(r) -> {
        results.add(r)
      }
      case Err(_) -> ()
    }    // runNext only returns Err on empty queue
  }
  return results.toArray()
}

// ─── Config ───────────────────────────────────────────────────────────────────
// Default scheduling and worker settings.
// (config block emitter not yet implemented; using module-level val constants)
val defaultMaxAttempts: Int = 3

val defaultTimeoutMs: Int = 30000

val defaultWorkerCount: Int = 4

// ─── Factory functions ────────────────────────────────────────────────────────
/// Create an in-process scheduler for testing.
@stable(since = "0.1")
pub func inProcess(): InProcessJobScheduler {
  return InProcessJobScheduler(jobs = newMap(), queue = newList(), counter = 0, attempts = newMap())
}

// ─── Convenience wrappers ─────────────────────────────────────────────────────
/// Enqueue a job for immediate execution using the configured default limits.
@stable(since = "0.1")
pub func enqueue(scheduler: in JobScheduler, name: in String, payload: in String): Result[String, String]
  requires: name.length > 0
{
  return scheduler.enqueue(name, payload, defaultMaxAttempts, defaultTimeoutMs)
}

/// Enqueue a job with explicit retry and timeout settings.
@stable(since = "0.1")
pub func enqueueWith(
  scheduler: in JobScheduler,
  name: in String,
  payload: in String,
  maxAttempts: in Int,
  timeoutMs: in Int,
): Result[String, String]
  requires: name.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  return scheduler.enqueue(name, payload, maxAttempts, timeoutMs)
}

/// Schedule a recurring job using a cron expression.
@stable(since = "0.1")
pub func schedule(
  scheduler: in JobScheduler, name: in String, payload: in String, cronExpr: in String
): Result[String, String]
  requires: name.length > 0
  requires: cronExpr.length > 0
{
  return scheduler.schedule(name, payload, cronExpr, defaultMaxAttempts, defaultTimeoutMs)
}

/// Schedule a recurring job from an already-validated `CronExpr`, using the
/// configured default retry/timeout limits.
@stable(since = "0.1")
pub func scheduleCron(
  scheduler: in JobScheduler, name: in String, payload: in String, cron: in CronExpr
): Result[String, String]
  requires: name.length > 0
{
  return scheduler.schedule(name, payload, cronExprToString(cron), defaultMaxAttempts, defaultTimeoutMs)
}

/// Schedule a recurring job from an already-validated `CronExpr`, with
/// explicit retry and timeout settings.
@stable(since = "0.1")
pub func scheduleCronWith(
  scheduler: in JobScheduler,
  name: in String,
  payload: in String,
  cron: in CronExpr,
  maxAttempts: in Int,
  timeoutMs: in Int,
): Result[String, String]
  requires: name.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  return scheduler.schedule(name, payload, cronExprToString(cron), maxAttempts, timeoutMs)
}

/// Cancel a pending or running job.
@stable(since = "0.1")
pub func cancel(scheduler: in JobScheduler, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  return scheduler.cancel(jobId)
}

/// Query the current status of a job.
@stable(since = "0.1")
pub func status(scheduler: in JobScheduler, jobId: in String): Result[JobStatus, String]
  requires: jobId.length > 0
{
  return scheduler.status(jobId)
}

/// Return all recorded results for a job.
@stable(since = "0.1")
pub func results(scheduler: in JobScheduler, jobId: in String): Result[JobResultList, String]
  requires: jobId.length > 0
{
  return scheduler.results(jobId)
}

/// Generate a new unique job ID using the platform kernel.
@stable(since = "0.1")
pub func newJobId(): String {
  return generateId()
}

// ─── Private helpers ──────────────────────────────────────────────────────────
// Index of `needle` in `s` at or after `from`, or -1.  The 2-arg BCL
// `IndexOf(str, from)` overload is not a Lyric surface (#4025) — the former
// `s.indexOf(needle, from)` spelling lowered to a guaranteed runtime throw
// and became a compile error when #6496 made the checker strict.
func indexOfFrom(s: in String, needle: in String, from: in Int): Int {
  if from >= s.length {
    return -1
  }
  val rel = Str.indexOfRaw(s.substring(from, s.length - from), needle)
  if rel < 0 {
    return -1
  }
  from + rel
}

// Split `s` on single-character separator `sep` (used by the cron-field
// parser below). With `Std.String` imported, `s.indexOf(x)` is
// `Std.String.indexOf`'s `Option[Int]` form (#6496), so the `Int` searches in
// this file spell `Str.indexOfRaw` explicitly.
func splitStr(s: in String, sep: in String): slice[String] {
  val parts: List[String] = newList()
  var partStart = 0
  var more = true
  while more {
    val i = indexOfFrom(s, sep, partStart)
    if i < 0 {
      more = false
    } else {
      parts.add(s.substring(partStart, i - partStart))
      partStart = i + sep.length
    }
  }
  parts.add(s.substring(partStart, s.length - partStart))
  return parts.toArray()
}

// Escape a string for JSON serialization (handles \, ", and common control chars).
func jsonEscapeStr(s: in String): String {
  var result = ""
  var i = 0
  while i < s.length {
    val ch = Str.substring(s, i, 1)
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
