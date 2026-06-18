/// JobQueue.Worker — background job dispatcher.
///
/// workerTick() is registered with Web.addWorker and fires every
/// LYRIC_CONFIG_WORKER_POLL_INTERVALMS milliseconds.  Each tick:
///   1. Opens a connection and attempts to claim the oldest pending job
///      via SELECT … FOR UPDATE SKIP LOCKED.
///   2. Executes the job by dispatching on `job.kind`.
///   3. Marks the job Completed on success, or calls failOrRetry on error.
///
/// Worker identity:
///   LYRIC_CONFIG_WORKER_WORKER_ID — unique string per process instance
///                                   (default: "worker-1")

@runtime_checked
package JobQueue.Worker

import Std.Core
import JobQueue.Domain
import JobQueue.Jobs
import Db
import OTel

// ─── Config ───────────────────────────────────────────────────────────────────

config Worker {
  workerId:    String = "worker-1"
  pollIntervalMs: Int = 2000
}

// ─── Dispatch ─────────────────────────────────────────────────────────────────

// Execute a claimed job.  Returns Ok(()) on success, Err(msg) on failure.
// Add new job kinds here as the application grows.
func dispatch(job: in Job): Result[Unit, String] {
  match job.kind {
    case "noop" ->
      Ok(())
    case "echo" ->
      Ok(())    // payload already stored; no side-effect needed
    case _ ->
      Err("unknown job kind: " + job.kind)
  }
}

// ─── Worker tick ──────────────────────────────────────────────────────────────

/// Called on each timer tick.  Claims and runs at most one job per invocation
/// so that the polling interval naturally throttles throughput.  Registered
/// via Web.addWorker in main.l.
pub func workerTick(): Result[Unit, String] {
  val span = OTel.startSpan("jobqueue.worker.tick", 1)
  match Db.connectPostgres() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err("db unavailable: " + e.message)
    }
    case Ok(conn) -> {
      match JobQueue.Jobs.claimNext(conn, Worker.workerId) {
        case Err(e) -> {
          conn.close()
          OTel.setSpanError(span, JobQueue.Domain.errorMessage(e))
          OTel.endSpan(span)
          Err(JobQueue.Domain.errorMessage(e))
        }
        case Ok(None) -> {
          conn.close()
          OTel.endSpan(span)
          Ok(())    // queue empty — nothing to do this tick
        }
        case Ok(Some(job)) -> {
          OTel.setSpanAttribute(span, "job.id",   job.id.toString())
          OTel.setSpanAttribute(span, "job.kind", job.kind)
          match dispatch(job) {
            case Ok(_) -> {
              val _ = JobQueue.Jobs.complete(conn, job.id)
              conn.close()
              OTel.setSpanAttribute(span, "job.result", "completed")
              OTel.endSpan(span)
              Ok(())
            }
            case Err(msg) -> {
              val _ = JobQueue.Jobs.failOrRetry(conn, job, msg)
              conn.close()
              OTel.setSpanAttribute(span, "job.result", "failed")
              OTel.setSpanError(span, msg)
              OTel.endSpan(span)
              Err(msg)
            }
          }
        }
      }
    }
  }
}
