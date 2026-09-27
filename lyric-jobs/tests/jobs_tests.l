//! tests/jobs_tests.l — tests for the pure-Lyric surface of the Jobs package.
//!
//! Covers JobStatus, JobSpec, JobError, JobResult construction, and the
//! InProcessJobScheduler with a synchronous in-process handler.
//! NativeJobScheduler (Hangfire / Quartz) requires infrastructure and is
//! not tested here.
@test_module
package Jobs.JobsTests

import Std.Core
import Std.Testing
import Jobs

// ─── Test handlers for runNext retry/timeout coverage ────────────────────────
// Module-level `Counter` state (not a field on the handler record itself):
// `handler.handle` is called through `handler: in JobHandler`, so a handler
// record's own fields cannot be mutated from inside `handle` — the same
// idiom `jobs_aspect_weaving_tests.l` already uses for its target functions.
record Counter {
  var count: Int = 0
}

val retrySuccessCalls: Counter = Counter()

val retryExhaustCalls: Counter = Counter()

val retryPanicCalls: Counter = Counter()

val timeoutOverrunCalls: Counter = Counter()

record SucceedOnSecondAttemptHandler {
}

impl JobHandler for SucceedOnSecondAttemptHandler {
  func handle(spec: in JobSpec): Result[String, JobError] {
    retrySuccessCalls.count = retrySuccessCalls.count + 1
    if retrySuccessCalls.count < 2 {
      return Err(JobError(message = "transient failure", code = "T"))
    }
    return Ok("succeeded on attempt " + retrySuccessCalls.count.toString())
  }
}

record AlwaysFailHandler {
}

impl JobHandler for AlwaysFailHandler {
  func handle(spec: in JobSpec): Result[String, JobError] {
    retryExhaustCalls.count = retryExhaustCalls.count + 1
    return Err(JobError(message = "persistent failure", code = "P"))
  }
}

record AlwaysPanicHandler {
}

impl JobHandler for AlwaysPanicHandler {
  func handle(spec: in JobSpec): Result[String, JobError] {
    retryPanicCalls.count = retryPanicCalls.count + 1
    panic("handler exploded")
  }
}

record SlowHandler {
}

impl JobHandler for SlowHandler {
  func handle(spec: in JobSpec): Result[String, JobError] {
    timeoutOverrunCalls.count = timeoutOverrunCalls.count + 1
    Jobs.sleepMs(50)
    return Ok("finished too slowly")
  }
}

// ─── JobSpec / JobResult invariant violations ────────────────────────────────
// Named helper functions (not inline lambdas: a block-bodied `() -> { ... }`
// lambda is refused by `lyric fmt`, #7151) passed directly to `assertPanics`.
func makeJobSpecEmptyId(): Unit {
  val _ = JobSpec(id = "", name = "job", payload = "", maxAttempts = 1, timeoutMs = 1000, scheduledAt = 0i64)
}

func makeJobSpecEmptyName(): Unit {
  val _ = JobSpec(id = "job-1", name = "", payload = "", maxAttempts = 1, timeoutMs = 1000, scheduledAt = 0i64)
}

func makeJobSpecZeroMaxAttempts(): Unit {
  val _ = JobSpec(id = "job-1", name = "job", payload = "", maxAttempts = 0, timeoutMs = 1000, scheduledAt = 0i64)
}

func makeJobSpecZeroTimeoutMs(): Unit {
  val _ = JobSpec(id = "job-1", name = "job", payload = "", maxAttempts = 1, timeoutMs = 0, scheduledAt = 0i64)
}

func makeJobSpecNegativeScheduledAt(): Unit {
  val _ = JobSpec(id = "job-1", name = "job", payload = "", maxAttempts = 1, timeoutMs = 1000, scheduledAt = -1i64)
}

func makeJobResultFinishedBeforeStarted(): Unit {
  val _ = JobResult(
    jobId = "job-1",
    status = JobStatus.Failed,
    output = "",
    error = "boom",
    startedAt = 1000i64,
    finishedAt = 500i64
  )
}

test "JobSpec: empty id violates the invariant" {
  assertPanics("empty id", makeJobSpecEmptyId)
}

test "JobSpec: empty name violates the invariant" {
  assertPanics("empty name", makeJobSpecEmptyName)
}

test "JobSpec: maxAttempts below 1 violates the invariant" {
  assertPanics("zero maxAttempts", makeJobSpecZeroMaxAttempts)
}

test "JobSpec: timeoutMs below 1 violates the invariant" {
  assertPanics("zero timeoutMs", makeJobSpecZeroTimeoutMs)
}

test "JobSpec: negative scheduledAt violates the invariant" {
  assertPanics("negative scheduledAt", makeJobSpecNegativeScheduledAt)
}

test "JobResult: finishedAt before startedAt violates the invariant" {
  assertPanics("finishedAt < startedAt", makeJobResultFinishedBeforeStarted)
}

// ─── runNext: retries ─────────────────────────────────────────────────────────
test "runNext: a handler failing once then succeeding is retried and reports 2 attempts" {
  retrySuccessCalls.count = 0
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("succeed-second", "{}", 3, 30000) {
    case Err(e) -> assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      match Jobs.runNext(scheduler, SucceedOnSecondAttemptHandler()) {
        case Err(e) -> assertTrue(false, "runNext must succeed: " + e)
        case Ok(result) -> {
          match result.status {
            case JobStatus.Succeeded -> ()
            case _ -> assertTrue(false, "expected Succeeded after the retry")
          }
          assertEqual(result.output, "succeeded on attempt 2", "output reflects the successful attempt")
        }
      }
      assertEqualInt(Jobs.attemptCount(scheduler, jobId), 2, "exactly two attempts were run")
    }
  }
}

test "runNext: a handler that always fails is retried up to maxAttempts then reports Failed" {
  retryExhaustCalls.count = 0
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("always-fail", "{}", 3, 30000) {
    case Err(e) -> assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      match Jobs.runNext(scheduler, AlwaysFailHandler()) {
        case Err(e) -> assertTrue(false, "runNext must succeed: " + e)
        case Ok(result) -> {
          match result.status {
            case JobStatus.Failed -> ()
            case _ -> assertTrue(false, "expected Failed after exhausting all attempts")
          }
          assertEqual(result.error, "persistent failure", "the last attempt's error is reported")
        }
      }
      assertEqualInt(Jobs.attemptCount(scheduler, jobId), 3, "all three attempts were run")
      assertEqualInt(retryExhaustCalls.count, 3, "the handler itself ran exactly three times")
    }
  }
}

test "runNext: a handler that always panics is retried up to maxAttempts and counted as failed" {
  retryPanicCalls.count = 0
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("always-panic", "{}", 3, 30000) {
    case Err(e) -> assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      match Jobs.runNext(scheduler, AlwaysPanicHandler()) {
        case Err(e) -> assertTrue(false, "runNext must succeed: " + e)
        case Ok(result) -> {
          match result.status {
            case JobStatus.Failed -> ()
            case _ -> assertTrue(false, "expected Failed after every attempt panicked")
          }
          assertTrue(result.error.contains("handler panicked"), "the error names the panic, not a raw crash")
          assertTrue(result.error.contains("handler exploded"), "the error carries the panic message")
        }
      }
      assertEqualInt(Jobs.attemptCount(scheduler, jobId), 3, "a panic still counts as an attempt, retried like an Err")
      assertEqualInt(retryPanicCalls.count, 3, "the handler ran exactly three times despite panicking every time")
    }
  }
}

// ─── runNext: timeoutMs overrun ───────────────────────────────────────────────
test "runNext: a handler that overruns timeoutMs is counted as a failed attempt even though it returned Ok" {
  timeoutOverrunCalls.count = 0
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("too-slow", "{}", 1, 10) {
    case Err(e) -> assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      match Jobs.runNext(scheduler, SlowHandler()) {
        case Err(e) -> assertTrue(false, "runNext must succeed: " + e)
        case Ok(result) -> {
          match result.status {
            case JobStatus.Failed -> ()
            case _ -> assertTrue(false, "an overrun attempt must be reported as Failed, not Succeeded")
          }
          assertTrue(result.error.contains("exceeded timeoutMs"), "the error names the overrun")
        }
      }
      assertEqualInt(Jobs.attemptCount(scheduler, jobId), 1, "the single configured attempt ran exactly once")
      assertEqualInt(timeoutOverrunCalls.count, 1, "the handler itself ran exactly once")
    }
  }
}

test "runNext: a handler that always overruns timeoutMs is retried like any other failure" {
  timeoutOverrunCalls.count = 0
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("too-slow-retried", "{}", 2, 10) {
    case Err(e) -> assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      match Jobs.runNext(scheduler, SlowHandler()) {
        case Err(e) -> assertTrue(false, "runNext must succeed: " + e)
        case Ok(result) -> {
          match result.status {
            case JobStatus.Failed -> ()
            case _ -> assertTrue(false, "every attempt overran, so the final status must be Failed")
          }
        }
      }
      assertEqualInt(Jobs.attemptCount(scheduler, jobId), 2, "both configured attempts ran")
      assertEqualInt(timeoutOverrunCalls.count, 2, "the handler ran exactly twice")
    }
  }
}

// ─── schedule: payload injection ──────────────────────────────────────────────
test "schedule: a payload crafted to inject a cron key stays inside the payload JSON string" {
  val scheduler = Jobs.inProcess()
  val maliciousPayload = "oops\",\"cron\":\"* * * * *\",\"payload\":\"gotcha"
  match scheduler.schedule("injection-attempt", maliciousPayload, "*/5 * * * *", 3, 30000) {
    case Err(e) -> assertTrue(false, "schedule must succeed: " + e)
    case Ok(_) -> {
      val stored = scheduler.queue[0].payload
      assertTrue(
        stored.contains("\"cron\":\"*/5 * * * *\""),
        "the legitimate cron field is present, unmodified, and still the real schedule"
      )
      assertTrue(
        not stored.contains("\"cron\":\"* * * * *\""),
        "the injected cron-shaped text must not appear as a second, unescaped JSON key"
      )
      assertTrue(
        stored.contains(jsonEscapedMaliciousPayload()),
        "the malicious payload text survives verbatim, but only inside the escaped payload string"
      )
    }
  }
}

// The malicious payload's expected JSON-string-escaped form: only `"` needs
// escaping here (no backslashes, newlines, or tabs in the payload text).
func jsonEscapedMaliciousPayload(): String {
  return "oops\\\",\\\"cron\\\":\\\"* * * * *\\\",\\\"payload\\\":\\\"gotcha"
}

// ─── parseCron ─────────────────────────────────────────────────────────────────
test "parseCron: a plain 5-field expression parses and round-trips" {
  match Jobs.parseCron("*/15 9-17 1,15 * 1-5") {
    case Err(e) -> assertTrue(false, "expected a valid cron expression: " + e)
    case Ok(cron) -> assertEqual(Jobs.cronExprToString(cron), "*/15 9-17 1,15 * 1-5", "canonical string round-trips")
  }
}

test "parseCron: every field defaulted to '*' parses" {
  match Jobs.parseCron("* * * * *") {
    case Err(e) -> assertTrue(false, "expected a valid cron expression: " + e)
    case Ok(cron) -> assertEqual(Jobs.cronExprToString(cron), "* * * * *", "canonical string round-trips")
  }
}

test "parseCron: rejects a field count other than 5" {
  match Jobs.parseCron("* * * *") {
    case Ok(_) -> assertTrue(false, "4 fields must be rejected")
    case Err(e) -> assertTrue(e.contains("5 space-separated fields"), "error names the field-count requirement")
  }
}

test "parseCron: rejects a minute value out of range" {
  match Jobs.parseCron("60 * * * *") {
    case Ok(_) -> assertTrue(false, "minute 60 is out of range [0,59]")
    case Err(e) -> assertTrue(e.contains("minute"), "error names the offending field")
  }
}

test "parseCron: rejects an hour value out of range" {
  match Jobs.parseCron("0 24 * * *") {
    case Ok(_) -> assertTrue(false, "hour 24 is out of range [0,23]")
    case Err(e) -> assertTrue(e.contains("hour"), "error names the offending field")
  }
}

test "parseCron: rejects a day-of-month value out of range" {
  match Jobs.parseCron("0 0 32 * *") {
    case Ok(_) -> assertTrue(false, "day-of-month 32 is out of range [1,31]")
    case Err(e) -> assertTrue(e.contains("day-of-month"), "error names the offending field")
  }
}

test "parseCron: rejects a month value out of range" {
  match Jobs.parseCron("0 0 1 13 *") {
    case Ok(_) -> assertTrue(false, "month 13 is out of range [1,12]")
    case Err(e) -> assertTrue(e.contains("month"), "error names the offending field")
  }
}

test "parseCron: rejects a day-of-week value out of range" {
  match Jobs.parseCron("0 0 1 1 8") {
    case Ok(_) -> assertTrue(false, "day-of-week 8 is out of range [0,7]")
    case Err(e) -> assertTrue(e.contains("day-of-week"), "error names the offending field")
  }
}

test "parseCron: accepts an inclusive range" {
  match Jobs.parseCron("0 9-17 * * *") {
    case Err(e) -> assertTrue(false, "9-17 is a valid hour range: " + e)
    case Ok(_) -> ()
  }
}

test "parseCron: rejects a range with start greater than end" {
  match Jobs.parseCron("0 17-9 * * *") {
    case Ok(_) -> assertTrue(false, "17-9 has start greater than end")
    case Err(e) -> assertTrue(e.contains("hour"), "error names the offending field")
  }
}

test "parseCron: accepts a comma-separated list" {
  match Jobs.parseCron("0,15,30,45 * * * *") {
    case Err(e) -> assertTrue(false, "a comma list of valid minutes must parse: " + e)
    case Ok(_) -> ()
  }
}

test "parseCron: rejects an empty list entry" {
  match Jobs.parseCron("0,,30 * * * *") {
    case Ok(_) -> assertTrue(false, "a double comma leaves an empty list entry")
    case Err(e) -> assertTrue(e.contains("empty"), "error names the empty entry")
  }
}

test "parseCron: accepts a '*/n' step" {
  match Jobs.parseCron("*/5 * * * *") {
    case Err(e) -> assertTrue(false, "*/5 is a valid step: " + e)
    case Ok(_) -> ()
  }
}

test "parseCron: accepts an 'a-b/n' step" {
  match Jobs.parseCron("1-30/5 * * * *") {
    case Err(e) -> assertTrue(false, "1-30/5 is a valid range step: " + e)
    case Ok(_) -> ()
  }
}

test "parseCron: rejects a step of 0" {
  match Jobs.parseCron("*/0 * * * *") {
    case Ok(_) -> assertTrue(false, "a step of 0 is meaningless")
    case Err(e) -> assertTrue(e.contains("minute"), "error names the offending field")
  }
}

test "parseCron: rejects a non-numeric step" {
  match Jobs.parseCron("*/x * * * *") {
    case Ok(_) -> assertTrue(false, "'x' is not a valid step")
    case Err(e) -> assertTrue(e.contains("minute"), "error names the offending field")
  }
}

test "parseCron: rejects a non-numeric field value" {
  match Jobs.parseCron("abc * * * *") {
    case Ok(_) -> assertTrue(false, "'abc' is not a valid minute value")
    case Err(e) -> assertTrue(e.contains("minute"), "error names the offending field")
  }
}

test "parseCron: rejects an empty field" {
  match Jobs.parseCron("  * * * *") {
    case Ok(_) -> assertTrue(false, "a leading double space produces an empty field")
    case Err(e) -> assertTrue(e.contains("field"), "error mentions the malformed field")
  }
}

// ─── cronExprToQuartz ──────────────────────────────────────────────────────────
test "cronExprToQuartz: unrestricted day-of-week converts to Quartz '?'" {
  match Jobs.parseCron("5 10 15 * *") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cron) -> {
      match Jobs.cronExprToQuartz(cron) {
        case Err(e) -> assertTrue(false, "expected a convertible expression: " + e)
        case Ok(q) -> assertEqual(q, "0 5 10 15 * ?", "day-of-month passes through; day-of-week becomes '?'")
      }
    }
  }
}

test "cronExprToQuartz: unrestricted day-of-month converts to Quartz '?' and renumbers day-of-week" {
  match Jobs.parseCron("0 9 * * 1") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cron) -> {
      match Jobs.cronExprToQuartz(cron) {
        case Err(e) -> assertTrue(false, "expected a convertible expression: " + e)
        case Ok(q) -> assertEqual(q, "0 0 9 ? * 2", "Unix Monday (1) becomes Quartz 2")
      }
    }
  }
}

test "cronExprToQuartz: both fields unrestricted maps day-of-week to '?'" {
  match Jobs.parseCron("* * * * *") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cron) -> {
      match Jobs.cronExprToQuartz(cron) {
        case Err(e) -> assertTrue(false, "expected a convertible expression: " + e)
        case Ok(q) -> assertEqual(q, "0 * * * * ?", "day-of-month stays '*'; day-of-week becomes '?'")
      }
    }
  }
}

test "cronExprToQuartz: both Unix Sunday spellings (0 and 7) renumber to Quartz 1" {
  match Jobs.parseCron("0 0 * * 0") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cronZero) -> {
      match Jobs.cronExprToQuartz(cronZero) {
        case Err(e) -> assertTrue(false, "expected a convertible expression: " + e)
        case Ok(q) -> assertEqual(q, "0 0 0 ? * 1", "Unix Sunday=0 becomes Quartz 1")
      }
    }
  }
  match Jobs.parseCron("0 0 * * 7") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cronSeven) -> {
      match Jobs.cronExprToQuartz(cronSeven) {
        case Err(e) -> assertTrue(false, "expected a convertible expression: " + e)
        case Ok(q) -> assertEqual(q, "0 0 0 ? * 1", "Unix Sunday=7 becomes Quartz 1")
      }
    }
  }
}

test "cronExprToQuartz: a day-of-week range and list renumber every endpoint" {
  match Jobs.parseCron("0 9 * * 1-5") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cron) -> {
      match Jobs.cronExprToQuartz(cron) {
        case Err(e) -> assertTrue(false, "expected a convertible expression: " + e)
        case Ok(q) -> assertEqual(q, "0 0 9 ? * 2,3,4,5,6", "Mon-Fri (1-5) becomes Quartz 2,3,4,5,6")
      }
    }
  }
  match Jobs.parseCron("0 9 * * 0,6") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cron) -> {
      match Jobs.cronExprToQuartz(cron) {
        case Err(e) -> assertTrue(false, "expected a convertible expression: " + e)
        case Ok(q) -> assertEqual(q, "0 0 9 ? * 1,7", "Sun,Sat (0,6) becomes Quartz 1,7")
      }
    }
  }
}

// ─── cronExprToQuartz: exhaustive day-of-week coverage (#7472, #7473) ───────────
// Renumbering must not touch a step's own digits (`*/2`, `1-5/2`), and a
// range spanning both Unix Sunday spellings (`0-7` and friends) must cover
// the whole week rather than collapsing to a single day.
test "cronExprToQuartz: every single Unix day-of-week value renumbers to its Quartz day" {
  match Jobs.parseCron("0 0 * * 0") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 1", "0 (Sun) -> 1")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 1") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 2", "1 (Mon) -> 2")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 2") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 3", "2 (Tue) -> 3")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 3") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 4", "3 (Wed) -> 4")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 4") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 5", "4 (Thu) -> 5")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 5") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 6", "5 (Fri) -> 6")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 6") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 7", "6 (Sat) -> 7")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 7") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 1", "7 (Sun) -> 1")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "cronExprToQuartz: '0-7' (every day) becomes '*', not a single-day collapse" {
  match Jobs.parseCron("0 0 * * 0-7") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * *", "0-7 spans the whole week")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 0-6") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(
        q,
        "0 0 0 ? * *",
        "0-6 also spans the whole week (0 already covers Sunday)"
      )
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
  match Jobs.parseCron("0 0 * * 1-7") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(
        q,
        "0 0 0 ? * *",
        "1-7 also spans the whole week (7 covers Sunday at the end)"
      )
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "cronExprToQuartz: '5-7' wraps Fri-Sat-Sun without collapsing to Quartz '1-1'" {
  match Jobs.parseCron("0 0 * * 5-7") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(
        q,
        "0 0 0 ? * 1,6,7",
        "Fri,Sat,Sun (5,6,7) -> Quartz 6,7,1, sorted ascending"
      )
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "cronExprToQuartz: '*/2' steps over Unix day numbers, not renumbered digits" {
  match Jobs.parseCron("0 0 * * */2") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 1,3,5,7", "0,2,4,6 -> Quartz 1,3,5,7 (not '*/3')")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "cronExprToQuartz: '1-5/2' steps within the range before renumbering" {
  match Jobs.parseCron("0 0 * * 1-5/2") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 2,4,6", "1,3,5 -> Quartz 2,4,6 (not '2-6/3')")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "cronExprToQuartz: '0-7/3' steps across both Sunday spellings" {
  match Jobs.parseCron("0 0 * * 0-7/3") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(q, "0 0 0 ? * 1,4,7", "0,3,6 -> Quartz 1,4,7")
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "cronExprToQuartz: a comma list mixing both Sunday spellings dedupes" {
  match Jobs.parseCron("0 0 * * 0,7,3") {
    case Ok(cron) -> match Jobs.cronExprToQuartz(cron) {
      case Ok(q) -> assertEqual(
        q,
        "0 0 0 ? * 1,4",
        "0 and 7 both mean Sunday (Quartz 1); deduped against 3 -> Quartz 4"
      )
      case Err(e) -> assertTrue(false, e)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

// ─── parseCron: reject non-digit cron numbers (#7474) ───────────────────────────
test "parseCron: rejects a leading '+' on a bare field value" {
  match Jobs.parseCron("+5 * * * *") {
    case Ok(_) -> assertTrue(false, "'+5' must not parse as a valid minute value")
    case Err(e) -> assertTrue(e.contains("minute"), "error names the offending field")
  }
}

test "parseCron: rejects a leading '+' on a range endpoint" {
  match Jobs.parseCron("0 0 * * +1-5") {
    case Ok(_) -> assertTrue(false, "'+1-5' must not parse as a valid day-of-week range")
    case Err(e) -> assertTrue(e.contains("day-of-week"), "error names the offending field")
  }
}

test "parseCron: rejects a leading '+' on a step" {
  match Jobs.parseCron("*/+2 * * * *") {
    case Ok(_) -> assertTrue(false, "'*/+2' must not parse as a valid step")
    case Err(e) -> assertTrue(e.contains("minute"), "error names the offending field")
  }
}

test "parseCron: rejects a field value with embedded whitespace" {
  match Jobs.parseCron("5\t * * * *") {
    case Ok(_) -> assertTrue(false, "a tab embedded in a field value must not parse as a valid integer")
    case Err(e) -> assertTrue(e.contains("minute"), "error names the offending field")
  }
}

test "cronExprToQuartz: both day-of-month and day-of-week restricted is rejected" {
  match Jobs.parseCron("0 9 15 * 1") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cron) -> {
      match Jobs.cronExprToQuartz(cron) {
        case Ok(q) -> assertTrue(false, "both fields restricted is not representable in Quartz, got: " + q)
        case Err(e) -> assertTrue(e.contains("day-of-month"), "error names the ambiguity")
      }
    }
  }
}

// ─── schedule / scheduleCron: the String-taking API still works ─────────────
test "schedule: an invalid cron expression is rejected rather than forwarded" {
  val scheduler = Jobs.inProcess()
  match Jobs.schedule(scheduler, "bad-cron-job", "{}", "not a cron") {
    case Ok(_) -> assertTrue(false, "an invalid cron expression must not schedule successfully")
    case Err(e) -> assertTrue(e.contains("cron"), "error identifies this as a cron problem")
  }
}

test "scheduleCron: schedules using an already-validated CronExpr" {
  val scheduler = Jobs.inProcess()
  match Jobs.parseCron("0 3 * * *") {
    case Err(e) -> assertTrue(false, "expected a valid cron: " + e)
    case Ok(cron) -> {
      match Jobs.scheduleCron(scheduler, "nightly-job", "{}", cron) {
        case Err(e) -> assertTrue(false, "scheduleCron must succeed: " + e)
        case Ok(jobId) -> assertTrue(jobId.length > 0, "scheduleCron returns a non-empty job ID")
      }
    }
  }
}

// ─── JobStatus ───────────────────────────────────────────────────────────────
test "JobStatus.Pending: can be matched" {
  val s = JobStatus.Pending
  match s {
    case JobStatus.Pending -> ()
    case _ -> assertTrue(false, "expected Pending")
  }
}

test "JobStatus.Running: can be matched" {
  val s = JobStatus.Running
  match s {
    case JobStatus.Running -> ()
    case _ -> assertTrue(false, "expected Running")
  }
}

test "JobStatus.Succeeded: can be matched" {
  val s = JobStatus.Succeeded
  match s {
    case JobStatus.Succeeded -> ()
    case _ -> assertTrue(false, "expected Succeeded")
  }
}

test "JobStatus.Failed: can be matched" {
  val s = JobStatus.Failed
  match s {
    case JobStatus.Failed -> ()
    case _ -> assertTrue(false, "expected Failed")
  }
}

test "JobStatus.Cancelled: can be matched" {
  val s = JobStatus.Cancelled
  match s {
    case JobStatus.Cancelled -> ()
    case _ -> assertTrue(false, "expected Cancelled")
  }
}

// ─── JobSpec ─────────────────────────────────────────────────────────────────
test "JobSpec: fields are accessible" {
  val spec = JobSpec(
    id = "job-1",
    name = "send-email",
    payload = "{\"to\":\"user@example.com\"}",
    maxAttempts = 3,
    timeoutMs = 30000,
    scheduledAt = 0i64
  )
  assertEqual(spec.id, "job-1", "id field")
  assertEqual(spec.name, "send-email", "name field")
  assertEqualInt(spec.maxAttempts, 3, "maxAttempts field")
  assertEqualInt(spec.timeoutMs, 30000, "timeoutMs field")
  assertTrue(spec.scheduledAt == 0i64, "scheduledAt 0 means immediate")
}

test "JobSpec: scheduledAt non-zero is valid (deferred job)" {
  val spec = JobSpec(
    id = "job-2",
    name = "nightly-report",
    payload = "",
    maxAttempts = 1,
    timeoutMs = 60000,
    scheduledAt = 1735689600000i64
  )
  assertTrue(spec.scheduledAt > 0i64, "deferred job has non-zero scheduledAt")
}

// ─── JobError ─────────────────────────────────────────────────────────────────
test "JobError: fields are accessible" {
  val e = JobError(message = "SMTP timeout", code = "SMTP_TIMEOUT")
  assertEqual(e.message, "SMTP timeout", "message field")
  assertEqual(e.code, "SMTP_TIMEOUT", "code field")
}

test "JobError: empty code is valid" {
  val e = JobError(message = "handler panicked", code = "")
  assertEqual(e.code, "", "empty code is valid")
}

// ─── JobResult ────────────────────────────────────────────────────────────────
test "JobResult: fields are accessible" {
  val r = JobResult(
    jobId = "job-1",
    status = JobStatus.Succeeded,
    output = "sent",
    error = "",
    startedAt = 1000i64,
    finishedAt = 1500i64
  )
  assertEqual(r.jobId, "job-1", "jobId field")
  assertEqual(r.output, "sent", "output field")
  assertEqual(r.error, "", "error field is empty on success")
  assertTrue(r.finishedAt > r.startedAt, "finishedAt is after startedAt")
  match r.status {
    case JobStatus.Succeeded -> ()
    case _ -> assertTrue(false, "status must be Succeeded")
  }
}

test "JobResult: failed result carries error field" {
  val r = JobResult(
    jobId = "job-2",
    status = JobStatus.Failed,
    output = "",
    error = "connection refused",
    startedAt = 2000i64,
    finishedAt = 2100i64
  )
  assertEqual(r.error, "connection refused", "error field on failure")
  match r.status {
    case JobStatus.Failed -> ()
    case _ -> assertTrue(false, "status must be Failed")
  }
}

// ─── inProcess / enqueue ─────────────────────────────────────────────────────
test "inProcess: creates scheduler with empty queue" {
  val scheduler = Jobs.inProcess()
  assertTrue(scheduler.queue.length == 0, "fresh scheduler has empty queue")
}

test "enqueue: adds a job to the in-process queue" {
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("my-job", "{}", 3, 30000) {
    case Err(e) -> assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      assertTrue(jobId.length > 0, "enqueue returns non-empty job ID")
      assertTrue(scheduler.queue.length == 1, "queue has one job after enqueue")
    }
  }
}

test "enqueue: successive enqueues each produce a unique job ID" {
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("job-a", "{}", 3, 30000) {
    case Err(e) -> assertTrue(false, "first enqueue failed: " + e)
    case Ok(id1) -> {
      match scheduler.enqueue("job-b", "{}", 3, 30000) {
        case Err(e) -> assertTrue(false, "second enqueue failed: " + e)
        case Ok(id2) -> {
          assertTrue(id1 != id2, "successive enqueues must produce distinct IDs")
          assertTrue(scheduler.queue.length == 2, "queue has two jobs")
        }
      }
    }
  }
}

// ─── enqueue / enqueueWith convenience wrappers ───────────────────────────────
test "enqueue wrapper: uses default limits and queues the job (#3174)" {
  val scheduler = Jobs.inProcess()
  match Jobs.enqueue(scheduler, "wrapped-job", "{}") {
    case Err(e) -> assertTrue(false, "enqueue wrapper must succeed: " + e)
    case Ok(jobId) -> {
      assertTrue(jobId.length > 0, "enqueue wrapper returns non-empty job ID")
      assertTrue(scheduler.queue.length == 1, "queue has one job after enqueue wrapper")
    }
  }
}

test "enqueueWith wrapper: honours explicit maxAttempts/timeoutMs (#3174, #3515)" {
  val scheduler = Jobs.inProcess()
  match Jobs.enqueueWith(scheduler, "tuned-job", "{}", 5, 60000) {
    case Err(e) -> assertTrue(false, "enqueueWith wrapper must succeed: " + e)
    case Ok(jobId) -> {
      assertTrue(jobId.length > 0, "enqueueWith wrapper returns non-empty job ID")
      assertTrue(scheduler.queue.length == 1, "queue has one job after enqueueWith wrapper")
      // Assert the explicit retry/timeout actually reached the stored JobSpec,
      // not just that the job was queued (#3515).
      val spec = scheduler.queue[0]
      assertEqual(spec.name, "tuned-job", "stored spec name")
      assertEqualInt(spec.maxAttempts, 5, "stored spec maxAttempts honours the explicit argument")
      assertEqualInt(spec.timeoutMs, 60000, "stored spec timeoutMs honours the explicit argument")
    }
  }
}

// ─── NativeJobScheduler (real backend, `quartz` feature) ──────────────────────
// `test` blocks don't reliably survive `@cfg` erasure through test synthesis
// (observed to compile into an invalid MSIL program when gated directly on
// the `test` itself — see lyric-search/tests/search_tests.l), so the feature
// split lives on plain helper functions instead, one `@cfg` variant per
// mutually-exclusive backend feature (`inprocess`/`hangfire`/`quartz` — see
// lyric.toml's `[features]` comment) so exactly one always survives erasure
// and the bare `test` block below always compiles.
//
// This is a genuine, real end-to-end run: `Jobs.connectQuartz()` starts a
// real `org.quartz.impl.StdScheduler` (JVM) or returns the tracked "not yet
// implemented" error (dotnet); `Jobs.enqueue` schedules a real Quartz job
// that a real Quartz thread pool executes; the poll loop below observes the
// real state transition via `Jobs.status`.
@cfg(feature = "quartz")
func pollUntilTerminal(scheduler: in JobScheduler, jobId: in String, maxTries: in Int): Result[JobStatus, String] {
  var i = 0
  var last: Result[JobStatus, String] = Err("poll: never queried")
  while i < maxTries {
    val current = Jobs.status(scheduler, jobId)
    last = current
    match current {
      case Err(_) -> return current
      case Ok(JobStatus.Pending) -> ()
      case Ok(_) -> return current
    }
    Jobs.sleepMs(50)
    i = i + 1
  }
  last
}

// NOTE: this scenario deliberately does not call `Jobs.results()`. Building
// a `JobResult` (or `JobStatus`) value from a *function argument* position —
// exactly what `Jobs`'s private `parseResults`/`parseStatus` helpers do
// (`JobResult(status = parseStatus(statusStr), …)`) — hits a pre-existing,
// already-tracked general JVM backend bug where a nullary enum case value is
// corrupted (silently becomes `null`) when passed as a function argument
// (#5380, filed during the D-progress-625 stdlib kernel migration; verified
// independently of this kernel with a minimal one-field-record repro).  It
// is not specific to Quartz, `NativeJobScheduler`, or even `Jobs` — every
// backend's `results()` is affected on `--target jvm` today.  `status()`
// (which builds its `JobStatus` via a bare `match` arm, not an argument
// position) is unaffected and is exercised fully below.
@cfg(feature = "quartz")
func quartzE2EScenario(): String {
  match Jobs.connectQuartz() {
    case Err(e) -> "connectQuartz failed: " + e
    case Ok(scheduler) -> {
      match Jobs.enqueue(scheduler, "quartz-e2e-job", "{}") {
        case Err(e) -> "enqueue failed: " + e
        case Ok(jobId) -> {
          match pollUntilTerminal(scheduler, jobId, 40) {
            case Err(e) -> "status polling failed: " + e
            case Ok(JobStatus.Succeeded) -> quartzE2ECancelAndErrorScenario(scheduler)
            case Ok(other) -> "expected terminal status Succeeded, got " + other.toString()
          }
        }
      }
    }
  }
}

// Second half of the scenario: cancel-before-fire and unknown-ID error paths
// against the SAME live scheduler the happy path already proved works, so a
// single `connectQuartz()` call (and its real Quartz thread pool) covers the
// whole test.
@cfg(feature = "quartz")
func quartzE2ECancelAndErrorScenario(scheduler: in NativeJobScheduler): String {
  match Jobs.enqueue(scheduler, "quartz-cancel-me", "{}") {
    case Err(e) -> "second enqueue failed: " + e
    case Ok(jobId2) -> {
      match Jobs.cancel(scheduler, jobId2) {
        case Err(e) -> "cancel failed: " + e
        case Ok(_) -> {
          match Jobs.status(scheduler, jobId2) {
            case Err(e) -> "status after cancel failed: " + e
            case Ok(JobStatus.Cancelled) -> {
              match Jobs.status(scheduler, "does-not-exist") {
                case Ok(_) -> "status on an unknown job ID unexpectedly succeeded"
                case Err(_) -> "OK"
              }
            }
            case Ok(other) -> "expected Cancelled after cancel(), got " + other.toString()
          }
        }
      }
    }
  }
}

@cfg(feature = "hangfire")
func quartzE2EScenario(): String {
  "OK"    // Hangfire's real-backend coverage is out of scope for this test; see the quartz variant.
}

@cfg(feature = "inprocess")
func quartzE2EScenario(): String {
  "OK"    // No NativeJobScheduler backend selected in this build; nothing to test here.
}

test "NativeJobScheduler (quartz feature): real end-to-end schedule, run, poll, cancel, and error paths" {
  assertEqual(
    quartzE2EScenario(),
    "OK",
    "the quartz-backed scheduler must actually run a job to completion, report Cancelled for a cancelled job, and error on an unknown job ID when the quartz feature is active"
  )
}
