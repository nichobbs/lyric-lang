//! Testing.Conformance.Jobs — conformance suite for `Jobs.JobScheduler`.
//!
//! `run(factory)`: `factory` returns a fresh scheduler every call.
//!
//! The suite covers submission, status, cancellation, cron validation and
//! result lookup, which every backend answers the same way.  Running the
//! handler is backend-specific (a pull-based `runNext` in process, a worker
//! server elsewhere), so the execution lifecycle is covered by each backend's
//! own tests, not here.
@runtime_checked
@io
package Testing.Conformance.Jobs

import Std.Core
import Std.Collections
import Testing.Conformance
import Jobs as JobsLib

/// Run the `JobScheduler` contract against schedulers from `factory`.
@stable(since = "0.1")
pub func run(factory: () -> JobsLib.JobScheduler): Checks {
  val c = newChecks("JobScheduler")
  runCase(c, "enqueue returns a non-empty id and the job starts Pending", { -> enqueuePending(c, factory()) })
  runCase(c, "every enqueue returns a distinct id", { -> distinctIds(c, factory()) })
  runCase(c, "status of an unknown job is an Err", { -> unknownStatus(c, factory()) })
  runCase(c, "results of an unknown job is an Err", { -> unknownResults(c, factory()) })
  runCase(c, "results of a known job is Ok", { -> knownResults(c, factory()) })
  runCase(c, "cancel moves a pending job to Cancelled", { -> cancelPending(c, factory()) })
  runCase(c, "cancel is idempotent and leaves other jobs alone", { -> cancelIdempotent(c, factory()) })
  runCase(c, "schedule accepts a valid cron expression", { -> scheduleValid(c, factory()) })
  runCase(c, "schedule rejects an invalid cron expression", { -> scheduleInvalid(c, factory()) })
  runCase(c, "a scheduled job has a status and can be cancelled", { -> scheduledLifecycle(c, factory()) })
  runCase(c, "the convenience wrappers agree with the interface", { -> wrappers(c, factory()) })
  return c
}

// The id of a newly enqueued job; "" (after recording a failure) when the
// enqueue fails.
func enqueueOne(c: in Checks, sched: in JobsLib.JobScheduler, name: in String): String {
  match sched.enqueue(name, "{\"n\":1}", 3, 30000) {
    case Ok(id) -> {
      expectTrue(c, id.length > 0, "enqueue returns a non-empty id")
      return id
    }
    case Err(e) -> {
      failCase(c, "enqueue failed: " + e)
      return ""
    }
  }
}

func statusName(r: in Result[JobsLib.JobStatus, String]): String {
  match r {
    case Ok(s) -> {
      match s {
        case JobsLib.JobStatus.Pending -> return "Pending"
        case JobsLib.JobStatus.Running -> return "Running"
        case JobsLib.JobStatus.Succeeded -> return "Succeeded"
        case JobsLib.JobStatus.Failed -> return "Failed"
        case JobsLib.JobStatus.Cancelled -> return "Cancelled"
      }
    }
    case Err(e) -> return "Err(" + e + ")"
  }
}

func enqueuePending(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  val id = enqueueOne(c, sched, "send-email")
  if id.length > 0 {
    expectEqual(c, statusName(sched.status(id)), "Pending", "the status of a new job")
  }
}

func distinctIds(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  val a = enqueueOne(c, sched, "job")
  val b = enqueueOne(c, sched, "job")
  expectTrue(c, a != b, "two enqueues of the same name get different ids")
}

func unknownStatus(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  match sched.status("no-such-job") {
    case Err(_) -> expectTrue(c, true, "status of an unknown job is an Err")
    case Ok(_) -> failCase(c, "status of an unknown job must be an Err")
  }
}

func unknownResults(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  match sched.results("no-such-job") {
    case Err(_) -> expectTrue(c, true, "results of an unknown job is an Err")
    case Ok(_) -> failCase(c, "results of an unknown job must be an Err")
  }
}

func knownResults(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  val id = enqueueOne(c, sched, "job")
  if id.length > 0 {
    match sched.results(id) {
      case Ok(_) -> expectTrue(c, true, "results of a known job")
      case Err(e) -> failCase(c, "results of a known job failed: " + e)
    }
  }
}

func cancelPending(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  val id = enqueueOne(c, sched, "job")
  if id.length > 0 {
    match sched.cancel(id) {
      case Ok(_) -> expectTrue(c, true, "cancel")
      case Err(e) -> failCase(c, "cancel failed: " + e)
    }
    expectEqual(c, statusName(sched.status(id)), "Cancelled", "the status after cancel")
  }
}

func cancelIdempotent(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  val a = enqueueOne(c, sched, "a")
  val b = enqueueOne(c, sched, "b")
  if a.length > 0 and b.length > 0 {
    val first = sched.cancel(a)
    val second = sched.cancel(a)
    match first {
      case Ok(_) -> expectTrue(c, true, "first cancel")
      case Err(e) -> failCase(c, "first cancel failed: " + e)
    }
    match second {
      case Ok(_) -> expectTrue(c, true, "second cancel")
      case Err(e) -> failCase(c, "cancelling a cancelled job must not fail: " + e)
    }
    expectEqual(c, statusName(sched.status(a)), "Cancelled", "the cancelled job")
    expectEqual(c, statusName(sched.status(b)), "Pending", "the other job is unaffected")
  }
}

func scheduleValid(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  for expr in ["*/5 * * * *", "0 3 * * 1-5", "30 6 1 * *", "0 0,12 * * *"] {
    match sched.schedule("report", "{}", expr, 1, 30000) {
      case Ok(id) -> expectTrue(c, id.length > 0, "schedule(\"" + expr + "\") returns an id")
      case Err(e) -> failCase(c, "schedule(\"" + expr + "\") failed: " + e)
    }
  }
}

func scheduleInvalid(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  for expr in ["not a cron", "* * * *", "61 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "*/0 * * * *"] {
    match sched.schedule("report", "{}", expr, 1, 30000) {
      case Err(_) -> expectTrue(c, true, "schedule(\"" + expr + "\") is rejected")
      case Ok(_) -> failCase(c, "schedule(\"" + expr + "\") must be rejected")
    }
  }
}

func scheduledLifecycle(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  match sched.schedule("nightly", "{}", "0 3 * * *", 1, 30000) {
    case Err(e) -> failCase(c, "schedule failed: " + e)
    case Ok(id) -> {
      match sched.status(id) {
        case Ok(_) -> expectTrue(c, true, "a scheduled job has a status")
        case Err(e) -> failCase(c, "status of a scheduled job failed: " + e)
      }
      match sched.cancel(id) {
        case Ok(_) -> expectTrue(c, true, "cancel a scheduled job")
        case Err(e) -> failCase(c, "cancel of a scheduled job failed: " + e)
      }
      expectEqual(c, statusName(sched.status(id)), "Cancelled", "the status after cancelling a scheduled job")
    }
  }
}

func wrappers(c: in Checks, sched: in JobsLib.JobScheduler): Unit {
  match JobsLib.enqueue(sched, "wrapped", "{}") {
    case Err(e) -> failCase(c, "Jobs.enqueue failed: " + e)
    case Ok(id) -> {
      expectEqual(c, statusName(JobsLib.status(sched, id)), "Pending", "Jobs.status")
      match JobsLib.cancel(sched, id) {
        case Ok(_) -> expectTrue(c, true, "Jobs.cancel")
        case Err(e) -> failCase(c, "Jobs.cancel failed: " + e)
      }
      expectEqual(c, statusName(JobsLib.status(sched, id)), "Cancelled", "Jobs.status after Jobs.cancel")
    }
  }
}
