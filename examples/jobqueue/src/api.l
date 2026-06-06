//! JobQueue.Api — HTTP handler functions and route table.
//!
//! Route table:
//!   POST  /jobs              — enqueue a new job
//!   GET   /jobs              — list jobs (optional ?status= filter)
//!   GET   /jobs/{id}         — job detail
//!
//! Auth: POST /jobs requires a valid JWT.
//! Rate limiting: all handlers, 120 req/min, burst 20.
@runtime_checked
package JobQueue.Api

import Std.Core
import Std.Collections
import Std.Json
import JobQueue.Domain
import JobQueue.Jobs
import Db
import Web
import Web.Aspects
import OTel

// ─── Aspects ──────────────────────────────────────────────────────────────────
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
  config {
    requestsPerMinute: Int = 120
    burstSize: Int = 20
  }
}

aspect Auth from Web.Aspects.RequiresAuth {
  inside: Throttle
  matches: name in { handleEnqueue }
  config {
    @sensitive
    jwtSecret: String
    issuer: String = "jobqueue-service"
    audience: String = "jobqueue-api"
  }
}

// ─── Request record ───────────────────────────────────────────────────────────
pub record EnqueueRequest {
  kind: String
  payload: String
  maxRetries: Int
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
func jobErrToApi(e: in JobError): ApiError {
  val msg = JobQueue.Domain.errorMessage(e)
  match e {
    case JobError.JobNotFound(_) -> Web.notFound(msg)
    case JobError.InvalidTransition(_, _) -> Web.badRequest(msg)
    case JobError.RetryLimitExceeded(_, _, _) -> Web.unprocessable(msg, [])
    case JobError.DatabaseError(_) -> Web.internalError(msg)
  }
}

func jsonArr(items: in List[String]): String {
  var buf: String = "["
  var first: Bool = true
  for item in items {
    if not first {
      buf = buf + ","
    }
    buf = buf + item
    first = false
  }
  return buf + "]"
}

// ─── Handlers ─────────────────────────────────────────────────────────────────
// authToken is injected from Authorization: Bearer by the Web dispatcher
// and validated by the Auth aspect before this body runs.
@post("/jobs")
pub func handleEnqueue(@body req: in EnqueueRequest, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("jobqueue.job.enqueue", 1)

  if req.kind.length == 0 {
    OTel.endSpan(span)
    return Err(Web.badRequest("kind must not be empty"))
  }
  if req.maxRetries < 0 or req.maxRetries > 10 {
    OTel.endSpan(span)
    return Err(Web.badRequest("maxRetries must be between 0 and 10"))
  }

  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match JobQueue.Jobs.enqueue(conn, req.kind, req.payload, req.maxRetries) { case Err(e) -> { conn.close(); OTel.setSpanError(span, JobQueue.Domain.errorMessage(e)); OTel.endSpan(span); Err(jobErrToApi(e)) }; case Ok(job) -> { conn.close(); OTel.setSpanAttribute(span, "job.id", job.id.toString()); OTel.setSpanAttribute(span, "job.kind", job.kind); OTel.endSpan(span); Ok(JobQueue.Jobs.toJson(job)) } }
  }
}

@get("/jobs")
pub func handleListJobs(status: String): Result[String, ApiError] {
  val span = OTel.startSpan("jobqueue.job.list", 1)
  val filter = if status.length == 0 then "pending" else status
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match JobQueue.Jobs.listByStatus(conn, filter) { case Err(e) -> { conn.close(); OTel.setSpanError(span, JobQueue.Domain.errorMessage(e)); OTel.endSpan(span); Err(jobErrToApi(e)) }; case Ok(jobs) -> { conn.close(); OTel.setSpanAttribute(span, "job.count", jobs.count.toString()); OTel.endSpan(span); val jsons: List[String] = newList(); for j in jobs { jsons.add(JobQueue.Jobs.toJson(j)) }; Ok(jsonArr(jsons)) } }
  }
}

@get("/jobs/{id}")
pub func handleGetJob(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("jobqueue.job.get", 1)
  OTel.setSpanAttribute(span, "job.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match JobQueue.Jobs.getById(conn, id) { case Err(e) -> { conn.close(); OTel.setSpanError(span, JobQueue.Domain.errorMessage(e)); OTel.endSpan(span); Err(jobErrToApi(e)) }; case Ok(None) -> { conn.close(); OTel.endSpan(span); Err(Web.notFound("job " + id.toString() + " not found")) }; case Ok(Some(job)) -> { conn.close(); OTel.endSpan(span); Ok(JobQueue.Jobs.toJson(job)) } }
  }
}

// ─── Route table ──────────────────────────────────────────────────────────────
pub func routes(): Web.Router {
  val r = Web.create()
  val r = Web.addPost(r, "/jobs", "JobQueue.Api.handleEnqueue")
  val r = Web.addGet(r, "/jobs", "JobQueue.Api.handleListJobs")
  val r = Web.addGet(r, "/jobs/{id}", "JobQueue.Api.handleGetJob")
  return r
}
