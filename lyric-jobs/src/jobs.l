//! Jobs — background job scheduling and execution library for Lyric.
//! Stability: @experimental — the in-process scheduler has tests; the
//! `NativeJobScheduler` (Hangfire/Quartz) path is tested against a real,
//! live Quartz Scheduler on `jvm` (`tests/jobs_tests.l`); Hangfire/Quartz.NET
//! on `dotnet` are not yet implemented (see README "Platform parity").
//!
//! `JobScheduler` is the public interface; implement it to add a custom
//! backend.  Two implementations are provided:
//!
//!   NativeJobScheduler   — delegates to Jobs.Kernel.Net or Jobs.Kernel.Jvm
//!                          (whichever the `dotnet`/`jvm` feature selects)
//!   InProcessJobScheduler — in-memory queue for tests and single-process use
//!
//! Supported backends (feature-gated via lyric.toml [features]; exactly one
//! of `inprocess`/`hangfire`/`quartz` must be active, alongside exactly one
//! of `dotnet`/`jvm` selecting the platform kernel):
//!   inprocess — ConcurrentDictionary (.NET) / ConcurrentHashMap (JVM) backend
//!   hangfire  — Hangfire.Core + Hangfire.SqlServer on `dotnet` (not yet
//!               implemented); real Quartz Scheduler on `jvm` (no JVM port)
//!   quartz    — Quartz.NET on `dotnet` (not yet implemented); real Quartz
//!               Scheduler (RAMJobStore) on `jvm`
//!
//! Usage:
//!
//!   import Jobs
//!   import Std.Core
//!
//!   val scheduler = Jobs.connect()?
//!   val jobId     = Jobs.enqueue(scheduler, "send-email", "{\"to\":\"user@example.com\"}")?
//!   match Jobs.status(scheduler, jobId) {
//!     case Ok(s)  -> println("job status: " + s.toString())
//!     case Err(e) -> println("error: " + e)
//!   }
//!
//! `Jobs.connectHangfire()` / `Jobs.connectQuartz()` are explicit
//! backend-named alternatives to `Jobs.connect()` (which just uses whichever
//! single backend feature is active).
//!
//! Runtime config env vars (LYRIC_CONFIG_JOBS_DEFAULTS_*):
//!   LYRIC_CONFIG_JOBS_DEFAULTS_MAXATTEMPTS       — retry limit (default: 3)
//!   LYRIC_CONFIG_JOBS_DEFAULTS_DEFAULTTIMEOUTMS  — execution timeout ms (default: 30000)
//!   LYRIC_CONFIG_JOBS_DEFAULTS_WORKERCOUNT       — parallel worker threads (default: 4)
//!   LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING  — SQL Server/Redis connection
//!                                                  string (`dotnet` only; a
//!                                                  non-empty value is ignored
//!                                                  with a warning on `jvm`)
//!
//! See docs/03-decision-log.md D056 and lyric-jobs/README.md.
@runtime_checked
package Jobs

import Std.Core
import Std.Collections
import Std.Parse
import Std.Iter
import Std.Log
import Std.Environment
import Std.Char
import Jobs.Kernel.Net as KernelNet
import Jobs.Kernel.Jvm as KernelJvm

// ─── Platform kernel dispatch ─────────────────────────────────────────────────
// `Jobs.Kernel.Net` / `Jobs.Kernel.Jvm` are imported aliased (rather than
// bare, as an earlier draft of this file did) because a bare import would put
// the kernel's own `connect(workerCount: Int)` in scope unqualified, directly
// colliding with this package's zero-arg `pub func connect()` below.  These
// thin wrappers re-export the platform's real threading/identity primitives
// under `Jobs`'s own name so the rest of this file (and `Jobs.Aspects`, which
// calls `nowMs()` bare after `import Jobs`) keeps working unqualified.
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
/// `cronExprToQuartz` converts to Quartz's 6/7-field dialect (seconds
/// prefix, `?` day-of-month/day-of-week disambiguation, 1-7 Sunday=1
/// day-of-week numbering) for the JVM Quartz kernel.
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

/// Convert to Quartz's 6/7-field dialect: a leading `"0"` seconds field,
/// then minute/hour/day-of-month/month/day-of-week, with day-of-week
/// renumbered from Unix's 0-7 (Sunday=0 or 7) to Quartz's 1-7 (Sunday=1).
///
/// Quartz requires exactly one of day-of-month/day-of-week to be `?`
/// (`c.domField`/`c.dowField` cannot both be restricted at once — Quartz has
/// no OR semantics between the two the way Unix cron does). When one field
/// is `*`, it becomes `?` and the other field carries the restriction (both
/// `*` maps to day-of-week `?`, matching common Quartz convention). `Err`
/// when both are restricted (not representable as a single Quartz
/// expression).
@stable(since = "0.1")
pub func cronExprToQuartz(c: in CronExpr): Result[String, String] {
  val domIsStar = c.domField == "*"
  val dowIsStar = c.dowField == "*"
  if not domIsStar and not dowIsStar {
    return Err(
      "cron: Quartz requires exactly one of day-of-month/day-of-week to be '*'; got day-of-month='" + c.domField +
        "' day-of-week='" +
        c.dowField +
        "' (Quartz has no OR semantics between the two fields the way Unix cron does)"
    )
  }
  var quartzDom = "?"
  var quartzDow = "?"
  if dowIsStar {
    quartzDom = c.domField
  } else {
    quartzDow = convertDowFieldToQuartz(c.dowField)
  }
  return Ok("0 " + c.minuteField + " " + c.hourField + " " + quartzDom + " " + c.monthField + " " + quartzDow)
}

// Convert a validated Unix day-of-week field (0-7, Sunday=0/7) to a Quartz
// day-of-week field (1-7, Sunday=1).
//
// Rather than renumbering each list entry's text independently (which
// mishandles a step's own digits and a range spanning both Sunday spellings,
// e.g. `0-7`), every entry is EXPANDED to the set of raw Unix day values it
// covers, each value is mapped to its Quartz day (`unix == 0 or unix == 7`
// both land on Quartz `1`), and the resulting set is deduplicated and
// rendered in ascending Quartz order — either a comma list, or `*` when the
// set covers every day of the week.
func convertDowFieldToQuartz(field: in String): String {
  var d1 = false
  var d2 = false
  var d3 = false
  var d4 = false
  var d5 = false
  var d6 = false
  var d7 = false
  val items = splitStr(field, ",")
  var idx = 0
  while idx < items.length {
    val item = items[idx]
    val slashParts = splitStr(item, "/")
    val base = slashParts[0]
    var step = 1
    if slashParts.length == 2 {
      match parseOptInt(slashParts[1]) {
        case Some(s) -> {
          step = s
        }
        case None -> ()    // unreachable: field is already validated
      }
    }
    var lo = 0
    var hi = 7
    if base != "*" {
      val dashParts = splitStr(base, "-")
      if dashParts.length == 1 {
        match parseOptInt(dashParts[0]) {
          case Some(v) -> {
            lo = v
            hi = v
          }
          case None -> ()    // unreachable: field is already validated
        }
      } else {
        match parseOptInt(dashParts[0]) {
          case Some(v) -> {
            lo = v
          }
          case None -> ()    // unreachable: field is already validated
        }
        match parseOptInt(dashParts[1]) {
          case Some(v) -> {
            hi = v
          }
          case None -> ()    // unreachable: field is already validated
        }
      }
    }
    var u = lo
    while u <= hi {
      val q = if u == 0 or u == 7 { 1 } else { u + 1 }
      if q == 1 {
        d1 = true
      } else if q == 2 {
        d2 = true
      } else if q == 3 {
        d3 = true
      } else if q == 4 {
        d4 = true
      } else if q == 5 {
        d5 = true
      } else if q == 6 {
        d6 = true
      } else {
        d7 = true
      }
      u = u + step
    }
    idx = idx + 1
  }
  if d1 and d2 and d3 and d4 and d5 and d6 and d7 {
    return "*"
  }
  var result = ""
  if d1 {
    result = appendDowDigit(result, "1")
  }
  if d2 {
    result = appendDowDigit(result, "2")
  }
  if d3 {
    result = appendDowDigit(result, "3")
  }
  if d4 {
    result = appendDowDigit(result, "4")
  }
  if d5 {
    result = appendDowDigit(result, "5")
  }
  if d6 {
    result = appendDowDigit(result, "6")
  }
  if d7 {
    result = appendDowDigit(result, "7")
  }
  return result
}

// Append `digit` to the comma-separated accumulator `acc`.
func appendDowDigit(acc: in String, digit: in String): String {
  if acc.length == 0 {
    return digit
  }
  return acc + "," + digit
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
    if not isAsciiDigit(s[i]) {
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

// ─── Native scheduler (backend-backed) ───────────────────────────────────────
/// Backend-backed scheduler.  Obtain one via `Jobs.connect()`.
@stable(since = "0.1")
pub record NativeJobScheduler {
  schedulerId: Int    // opaque handle issued by the kernel
}

impl JobScheduler for NativeJobScheduler {
  func enqueue(name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    return jobsEnqueueBackend(self.schedulerId, name, payload, maxAttempts, timeoutMs)
  }

  func schedule(
    name: in String, payload: in String, cronExpr: in String, maxAttempts: in Int, timeoutMs: in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    match parseCron(cronExpr) {
      case Err(e) -> Err(e)
      case Ok(cron) -> jobsScheduleBackend(self.schedulerId, name, payload, cron, maxAttempts, timeoutMs)
    }
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
      case Err(msg) -> Err(msg)
      case Ok(rawStr) -> Ok(parseStatus(rawStr))
    }
  }

  func results(jobId: in String): Result[JobResultList, String]
    requires: jobId.length > 0
  {
    match jobsResultsBackend(self.schedulerId, jobId) {
      case Err(msg) -> Err(msg)
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
@stable(since = "0.1")
pub record InProcessJobScheduler {
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
    // dialect) before storage, matching NativeJobScheduler, and both it and
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
pub func runNext(scheduler: inout InProcessJobScheduler, handler: in JobHandler): Result[JobResult, String] {
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
pub func runAll(scheduler: inout InProcessJobScheduler, handler: in JobHandler): slice[JobResult] {
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
func connectNative(): Result[NativeJobScheduler, String] {
  match jobsConnectBackend(defaultWorkerCount) {
    case Ok(schedulerId) -> Ok(NativeJobScheduler(schedulerId = schedulerId))
    case Err(msg) -> Err(msg)
  }
}

/// Open a backend scheduler connection using the configured defaults.
/// Returns a `NativeJobScheduler` backed by the active feature (`inprocess`,
/// `hangfire`, or `quartz` — exactly one must be enabled in `[features]`).
@stable(since = "0.1")
pub func connect(): Result[NativeJobScheduler, String] {
  connectNative()
}

@cfg(feature = "jvm")
func warnIfHangfireConnectionStringIgnored(): Unit {
  // Called bare (not `Std.Environment.getVarOrDefault(...)` /
  // `Std.Log.warn(...)`): a fully package-qualified call to another Lyric
  // package's function mis-resolves as a JVM auto-FFI instance call on a
  // `java.lang.Object` receiver and fails to compile — a general JVM
  // backend gap (reproduced independently of this file), not fixed here.
  // Every kernel in this codebase already calls stdlib functions bare after
  // a plain `import Std.X`, for the same reason.
  val conn = getVarOrDefault("LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING", "")
  if conn.length > 0 {
    warn(
      "lyric-jobs: Hangfire connection string ignored on JVM; Quartz uses RAMJobStore (in-memory). Persistence configured for .NET-only Hangfire.SqlServer."
    )
  }
}

@cfg(feature = "dotnet")
func warnIfHangfireConnectionStringIgnored(): Unit {
  ()
}

/// Open a Hangfire-backed scheduler (`hangfire` feature).  On `dotnet`,
/// Hangfire integration itself is not yet implemented — the returned
/// `Result` carries `Err(...)` (tracked, Phase 3 follow-up of #733).  On
/// `jvm`, `hangfire` maps to a real Quartz Scheduler binding (Hangfire has
/// no JVM port); see README "Platform parity".  The connection string is
/// read from `LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING` — there is no
/// connection-string parameter, since neither kernel's `connect` accepts one
/// (the JVM path warns, rather than silently downgrading, when a non-empty
/// value is set but can only be honoured on `dotnet`).
@stable(since = "0.1")
@cfg(feature = "hangfire")
pub func connectHangfire(): Result[NativeJobScheduler, String] {
  warnIfHangfireConnectionStringIgnored()
  connectNative()
}

/// Open a Quartz-backed scheduler (`quartz` feature).  On `dotnet`, Quartz.NET
/// integration is not yet implemented (same tracking as Hangfire above). On
/// `jvm`, this is a real Quartz Scheduler binding backed by an in-memory
/// `RAMJobStore` (not persistent); see README "Platform parity".
@stable(since = "0.1")
@cfg(feature = "quartz")
pub func connectQuartz(): Result[NativeJobScheduler, String] {
  connectNative()
}

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

// ─── Kernel backend dispatch ──────────────────────────────────────────────────
// `Jobs.Kernel.Net` / `Jobs.Kernel.Jvm` each export identically-named
// `connect`/`enqueue`/`schedule`/`cancel`/`status`/`results` functions, each
// gated by the active backend feature (`inprocess`/`hangfire`/`quartz`,
// #733). These wrappers pick the platform kernel via the mutually exclusive
// `dotnet`/`jvm` features and forward under a distinct name so they don't
// collide with `NativeJobScheduler`'s own same-named interface methods.
//
// Exactly one of {inprocess, hangfire, quartz} MUST be active for
// `NativeJobScheduler`/`connect()`/`connectHangfire()`/`connectQuartz()` to
// compile: selecting none is now a build-time error (an unresolved
// `KernelNet.connect`/`KernelJvm.connect` symbol, since the entire backend
// feature's function bodies are `@cfg`-erased) rather than a runtime call
// that silently always fails.
@cfg(feature = "dotnet")
func jobsConnectBackend(workerCount: in Int): Result[Int, String] {
  KernelNet.connect(workerCount)
}

@cfg(feature = "jvm")
func jobsConnectBackend(workerCount: in Int): Result[Int, String] {
  KernelJvm.connect(workerCount)
}

@cfg(feature = "dotnet")
func jobsEnqueueBackend(
  schedulerId: in Int, name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int
): Result[String, String] {
  KernelNet.enqueue(schedulerId, name, payload, maxAttempts, timeoutMs)
}

@cfg(feature = "jvm")
func jobsEnqueueBackend(
  schedulerId: in Int, name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int
): Result[String, String] {
  KernelJvm.enqueue(schedulerId, name, payload, maxAttempts, timeoutMs)
}

// `cron` arrives pre-validated (via `parseCron`); each platform variant
// below renders it into the dialect its real backend actually parses.
// Today only `KernelJvm.schedule`'s real Quartz `CronScheduleBuilder` ever
// looks at the field content — `KernelNet.schedule` either ignores it
// (`inprocess`, "cron scheduling not supported") or never reaches it
// (`hangfire`/`quartz` on `dotnet` fail at `connect()` first, both tracked
// as Phase 3 follow-ups of #733) — but both variants render a dialect-
// correct string on principle rather than assuming today's kernel behaviour.
@cfg(feature = "dotnet")
func jobsScheduleBackend(
  schedulerId: in Int,
  name: in String,
  payload: in String,
  cron: in CronExpr,
  maxAttempts: in Int,
  timeoutMs: in Int,
): Result[String, String] {
  KernelNet.schedule(schedulerId, name, payload, cronExprToString(cron), maxAttempts, timeoutMs)
}

// Quartz (real on `jvm` for both `hangfire` and `quartz` features, see the
// kernel's file header) parses a 6/7-field expression with a leading
// seconds field and `?`/1-7 day-of-week conventions, not the 5-field Unix
// dialect `parseCron` validates — `cronExprToQuartz` renders that dialect
// here so `KernelJvm.schedule`'s `JCronScheduleBuilder.cronSchedule(...)`
// receives a string Quartz actually accepts.
@cfg(feature = "jvm")
func jobsScheduleBackend(
  schedulerId: in Int,
  name: in String,
  payload: in String,
  cron: in CronExpr,
  maxAttempts: in Int,
  timeoutMs: in Int,
): Result[String, String] {
  match cronExprToQuartz(cron) {
    case Err(e) -> Err(e)
    case Ok(quartzCron) -> KernelJvm.schedule(schedulerId, name, payload, quartzCron, maxAttempts, timeoutMs)
  }
}

@cfg(feature = "dotnet")
func jobsCancelBackend(schedulerId: in Int, jobId: in String): Result[Unit, String] {
  KernelNet.cancel(schedulerId, jobId)
}

@cfg(feature = "jvm")
func jobsCancelBackend(schedulerId: in Int, jobId: in String): Result[Unit, String] {
  KernelJvm.cancel(schedulerId, jobId)
}

@cfg(feature = "dotnet")
func jobsStatusBackend(schedulerId: in Int, jobId: in String): Result[String, String] {
  KernelNet.status(schedulerId, jobId)
}

@cfg(feature = "jvm")
func jobsStatusBackend(schedulerId: in Int, jobId: in String): Result[String, String] {
  KernelJvm.status(schedulerId, jobId)
}

@cfg(feature = "dotnet")
func jobsResultsBackend(schedulerId: in Int, jobId: in String): Result[String, String] {
  KernelNet.results(schedulerId, jobId)
}

@cfg(feature = "jvm")
func jobsResultsBackend(schedulerId: in Int, jobId: in String): Result[String, String] {
  KernelJvm.results(schedulerId, jobId)
}

// ─── Private helpers ──────────────────────────────────────────────────────────
// Parse a status string returned by the kernel into a JobStatus variant.
func parseStatus(raw: in String): JobStatus {
  match raw {
    case "Pending" -> JobStatus.Pending
    case "Running" -> JobStatus.Running
    case "Succeeded" -> JobStatus.Succeeded
    case "Failed" -> JobStatus.Failed
    case "Cancelled" -> JobStatus.Cancelled
    case _ -> JobStatus.Failed
  }    // Unknown status → treat as failed.
}

// Index of `needle` in `s` at or after `from`, or -1.  The 2-arg BCL
// `IndexOf(str, from)` overload is not a Lyric surface (#4025) — the former
// `s.indexOf(needle, from)` spelling lowered to a guaranteed runtime throw
// and became a compile error when #6496 made the checker strict.
func indexOfFrom(s: in String, needle: in String, from: in Int): Int {
  if from >= s.length {
    return -1
  }
  val rel = s.substring(from, s.length - from).indexOf(needle)
  if rel < 0 {
    return -1
  }
  from + rel
}

// Split `s` on single-character separator `sep` (used by the cron-field
// parser below). Implemented locally against the built-in `String` methods
// rather than pulling in `Std.String.split`: that module's free functions
// (`indexOf`, `split`, ...) share names with, but not signatures/semantics
// with, the built-in `String` methods this file already calls via dot
// syntax elsewhere (e.g. `json.indexOf(needle)` returning `Int`, not
// `Std.String.indexOf`'s `Option[Int]`) — importing it, even aliased,
// changed those call sites' resolved return type and broke the build.
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

// Parse a JSON array of job result objects from the kernel into a list.
// Wire format: [{"jobId":"...","status":"...","output":"...","error":"...",
//                "startedAt":N,"finishedAt":N},...]
func parseResults(jobId: in String, json: in String): slice[JobResult] {
  if json == "[]" or json == "" {
    return []
  }
  val results: List[JobResult] = newList()
  var pos: Int = 0
  while pos < json.length {
    val objStart = indexOfFrom(json, "{", pos)
    if objStart < 0 {
      pos = json.length
    } else {
      val objEnd = findObjectEnd(json, objStart)
      if objEnd < 0 {
        pos = json.length
      } else {
        val obj = json.substring(objStart, objEnd + 1)
        val statusStr = jsonExtractString(obj, "status")
        val output = jsonExtractString(obj, "output")
        val error = jsonExtractString(obj, "error")
        val startedAt = jsonExtractLong(obj, "startedAt")
        val finishedAt = jsonExtractLong(obj, "finishedAt")
        results.add(
          JobResult(
            jobId = jobId,
            status = parseStatus(statusStr),
            output = output,
            error = error,
            startedAt = startedAt,
            finishedAt = finishedAt
          )
        )
        pos = objEnd + 1
      }
    }
  }
  return results.toArray()
}

// Find the closing brace of a JSON object, respecting nested braces.
func findObjectEnd(json: in String, start: in Int): Int {
  var depth: Int = 0
  var i: Int = start
  while i < json.length {
    val ch = json[i]
    if ch == '{' {
      depth = depth + 1
    } else if ch == '}' {
      depth = depth - 1
      if depth == 0 {
        return i
      }
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
  val start = json.indexOf(needle)
  if start < 0 {
    return ""
  }
  val afterColon = start + needle.length
  val q1 = indexOfFrom(json, "\"", afterColon)
  if q1 < 0 {
    return ""
  }
  val q2 = indexOfFrom(json, "\"", q1 + 1)
  if q2 < 0 {
    return ""
  }
  return json.substring(q1 + 1, q2)
}

// Extract a Long field from a JSON object literal.
func jsonExtractLong(json: in String, field: in String): Long {
  val needle = "\"" + field + "\":"
  val start = json.indexOf(needle)
  if start < 0 {
    return 0i64
  }
  val afterColon = start + needle.length
  var i: Int = afterColon
  while i < json.length and json[i] == ' ' {
    i = i + 1
  }
  var numStr: String = ""
  while i < json.length and json[i] != ',' and json[i] != '}' {
    numStr = numStr + json[i].toString()
    i = i + 1
  }
  match parseOptLong(numStr.trim()) {
    case Some(n) -> return n
    case None -> return 0i64
  }
}
