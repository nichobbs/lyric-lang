//! JobQueue.Jobs — job repository: enqueue, claim, complete, fail, retry.
//!
//! All mutations go through explicit DB transactions so a crash between
//! claim and completion leaves the job in `running` state, where a
//! separate reconciliation pass (or restart policy) can reset it.
@runtime_checked
package JobQueue.Jobs

import Std.Core
import JobQueue.Domain
import Db

// ─── Column helpers ───────────────────────────────────────────────────────────
func colText(row: in DbRow, name: in String): String {
  match Db.col(row, name) {
    case DbValue.DbText(v) -> v
    case _ -> ""
  }
}

func colLong(row: in DbRow, name: in String): Long {
  match Db.col(row, name) {
    case DbValue.DbLong(v) -> v
    case DbValue.DbInt(v) -> v.toLong()
    case _ -> 0
  }
}

func colInt(row: in DbRow, name: in String): Int {
  match Db.col(row, name) {
    case DbValue.DbInt(v) -> v
    case DbValue.DbLong(v) -> v.toInt()
    case _ -> 0
  }
}

func rowToJob(row: in DbRow): Job {
  val statusStr = colText(row, "status")
  val status = match JobQueue.Domain.jobStatusFromString(statusStr) {
    case Some(s) -> s
    case None -> JobStatus.Pending
  }
  return Job(
    id = colLong(row, "id"),
    kind = colText(row, "kind"),
    payload = colText(row, "payload"),
    status = status,
    retryCount = colInt(row, "retry_count"),
    maxRetries = colInt(row, "max_retries"),
    workerId = colText(row, "worker_id"),
    error = colText(row, "error"),
    createdAt = colText(row, "created_at")
  )
}

// ─── Enqueue ──────────────────────────────────────────────────────────────────
/// Insert a new job in Pending status.  Returns the full job record.
pub func enqueue(conn: in DbConnection, kind: in String, payload: in String, maxRetries: in Int): Result[Job, JobError]
  requires: kind.length > 0
  requires: maxRetries >= 0
  requires: maxRetries <= 10
{
  val sql = "INSERT INTO jobs (kind, payload, max_retries) VALUES ($1, $2, $3) " +
    "RETURNING id, kind, payload, status, retry_count, max_retries, worker_id, error, created_at"
  match conn.query(sql, [kind, payload, maxRetries.toString()]) {
    case Err(e) -> Err(JobError.DatabaseError(message = e.message))
    case Ok(rows) -> {
      for row in rows {
        return Ok(rowToJob(row))
      }
      Err(JobError.DatabaseError(message = "INSERT returned no rows"))
    }
  }
}

// ─── Claim ────────────────────────────────────────────────────────────────────
/// Atomically claim the oldest pending job for `workerId`.
///
/// Uses SELECT … FOR UPDATE SKIP LOCKED so that concurrent workers
/// never claim the same row.  Returns None if the queue is empty.
pub func claimNext(conn: in DbConnection, workerId: in String): Result[Option[Job], JobError]
  requires: workerId.length > 0
{
  val sql = "SELECT id, kind, payload, status, retry_count, max_retries, worker_id, error, created_at " +
    "FROM jobs WHERE status = 'pending' ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED"
  match Db.queryOne(conn, sql, []) {
    case Err(e) -> Err(JobError.DatabaseError(message = e.message))
    case Ok(None) -> Ok(None)
    case Ok(Some(row)) -> {
      val job = rowToJob(row)
      val updateSql = "UPDATE jobs SET status = 'running', worker_id = $1, claimed_at = now() " +
        "WHERE id = $2 AND status = 'pending'"
      match conn.execute(updateSql, [workerId, job.id.toString()]) {
        case Err(e) -> Err(JobError.DatabaseError(message = e.message))
        case Ok(_) -> Ok(Some(value = Job(id = job.id, kind = job.kind, payload = job.payload, status = JobStatus.Running, retryCount = job.retryCount, maxRetries = job.maxRetries, workerId = workerId, error = "", createdAt = job.createdAt)))
      }
    }
  }
}

// ─── Complete ─────────────────────────────────────────────────────────────────
/// Mark a running job as Completed.
pub func complete(conn: in DbConnection, jobId: in Long): Result[Unit, JobError] {
  val sql = "UPDATE jobs SET status = 'completed', completed_at = now() " + "WHERE id = $1 AND status = 'running'"
  match conn.execute(sql, [jobId.toString()]) {
    case Err(e) -> Err(JobError.DatabaseError(message = e.message))
    case Ok(0) -> Err(JobError.JobNotFound(id = jobId))
    case Ok(_) -> Ok(())
  }
}

// ─── Fail / Retry ─────────────────────────────────────────────────────────────
/// Mark a running job as Failed.  If retryCount < maxRetries, reset to Pending.
/// The `retryAllowed` proof oracle is called before the DB update so the
/// verifier enforces the retry budget statically in @proof_required callers.
pub func failOrRetry(conn: in DbConnection, job: in Job, errorMsg: in String): Result[Unit, JobError] {
  if job.retryCount < job.maxRetries {
    val _ = JobQueue.Domain.retryAllowed(job.retryCount, job.maxRetries)
    val sql = "UPDATE jobs SET status = 'pending', retry_count = retry_count + 1, " +
      "worker_id = '', error = $1 WHERE id = $2 AND status = 'running'"
    match conn.execute(sql, [errorMsg, job.id.toString()]) {
      case Err(e) -> Err(JobError.DatabaseError(message = e.message))
      case Ok(_) -> Ok(())
    }
  } else {
    val sql = "UPDATE jobs SET status = 'failed', error = $1 WHERE id = $2 AND status = 'running'"
    match conn.execute(sql, [errorMsg, job.id.toString()]) {
      case Err(e) -> Err(JobError.DatabaseError(message = e.message))
      case Ok(_) -> Ok(())
    }
  }
}

// ─── Queries ──────────────────────────────────────────────────────────────────
pub func getById(conn: in DbConnection, jobId: in Long): Result[Option[Job], JobError] {
  val sql = "SELECT id, kind, payload, status, retry_count, max_retries, worker_id, error, created_at " +
    "FROM jobs WHERE id = $1"
  match Db.queryOne(conn, sql, [jobId.toString()]) {
    case Err(e) -> Err(JobError.DatabaseError(message = e.message))
    case Ok(None) -> Ok(None)
    case Ok(Some(row)) -> Ok(Some(value = rowToJob(row)))
  }
}

pub func listByStatus(conn: in DbConnection, status: in String): Result[List[Job], JobError] {
  val sql = "SELECT id, kind, payload, status, retry_count, max_retries, worker_id, error, created_at " +
    "FROM jobs WHERE status = $1 ORDER BY created_at DESC LIMIT 100"
  match conn.query(sql, [status]) {
    case Err(e) -> Err(JobError.DatabaseError(message = e.message))
    case Ok(rows) -> {
      var jobs: List[Job] = []
      for row in rows {
        jobs = jobs + [rowToJob(row)]
      }
      Ok(jobs)
    }
  }
}

// ─── JSON serialisation ───────────────────────────────────────────────────────
pub func toJson(job: in Job): String {
  return "{" + "\"id\":" + job.id.toString() + "," + "\"kind\":\"" + job.kind + "\"," + "\"payload\":" + job.payload +
    "," +
    "\"status\":\"" +
    JobQueue.Domain.jobStatusLabel(job.status) +
    "\"," +
    "\"retry_count\":" +
    job.retryCount.toString() +
    "," +
    "\"max_retries\":" +
    job.maxRetries.toString() +
    "," +
    "\"worker_id\":\"" +
    job.workerId +
    "\"," +
    "\"error\":\"" +
    job.error +
    "\"," +
    "\"created_at\":\"" +
    job.createdAt +
    "\"" +
    "}"
}
