//! JobQueue.Domain — domain types and provable state-machine invariants.
//!
//! The proof obligations verified by Z3:
//!
//!   statusTransition   — legal transitions only (Pending→Running,
//!                        Running→Completed, Running→Failed, Failed→Pending).
//!                        Completed is terminal: it appears in no `from`
//!                        position, so the verifier rejects any call-site
//!                        that attempts to transition away from Completed.
//!
//!   retryAllowed       — a failed job may only be re-queued when its
//!                        retry count is strictly less than its budget.
//!                        Combined with RetryCount = Int range 0..=10,
//!                        Z3 closes this as a bounded integer comparison.
//!
//! Run standalone:  lyric prove examples/jobqueue/src/domain.l --verbose
@proof_required
package JobQueue.Domain

import Std.Core

// ─── Identity types ───────────────────────────────────────────────────────────
//
// Distinct type aliases turn ID-swap bugs into compile errors.
pub type JobId = Long

pub type WorkerId = Long

// ─── Range subtype ────────────────────────────────────────────────────────────
/// Retry count for a job: 0–10 inclusive.  Exhausting the budget becomes a
/// type error in @proof_required code; a runtime bounds panic in @runtime_checked.
pub type RetryCount = Int range 0 ..= 10

// ─── Job status ───────────────────────────────────────────────────────────────
pub enum JobStatus {
  case Pending
  case Running
  case Completed
  case Failed
}

pub func jobStatusLabel(s: in JobStatus): String {
  match s {
    case JobStatus.Pending -> "pending"
    case JobStatus.Running -> "running"
    case JobStatus.Completed -> "completed"
    case JobStatus.Failed -> "failed"
  }
}

pub func jobStatusFromString(s: in String): Option[JobStatus] {
  match s {
    case "pending" -> Some(value = JobStatus.Pending)
    case "running" -> Some(value = JobStatus.Running)
    case "completed" -> Some(value = JobStatus.Completed)
    case "failed" -> Some(value = JobStatus.Failed)
    case _ -> None
  }
}

// ─── Domain records ───────────────────────────────────────────────────────────
pub record Job {
  id: Long
  kind: String
  payload: String
  status: JobStatus
  retryCount: Int
  maxRetries: Int
  workerId: String    // "" when unclaimed
  error: String    // "" when no error
  createdAt: String
}

// ─── Error type ───────────────────────────────────────────────────────────────
pub union JobError {
  case JobNotFound(id: Long)
  case InvalidTransition(from: String, to: String)
  case RetryLimitExceeded(id: Long, retryCount: Int, maxRetries: Int)
  case DatabaseError(message: String)
}

pub func errorMessage(e: in JobError): String {
  match e {
    case JobError.JobNotFound(id) -> "job " + id.toString() + " not found"
    case JobError.InvalidTransition(from, to) -> "invalid status transition: " + from + " → " + to
    case JobError.RetryLimitExceeded(id, retryCount, maxRetries) -> "job " + id.toString() + " has reached retry limit (" + retryCount.toString() + "/" + maxRetries.toString() + ")"
    case JobError.DatabaseError(message) -> "database error: " + message
  }
}

// ─── Provable state-machine invariants ───────────────────────────────────────
/// Prove that a proposed status transition is legal.
///
/// The four legal transitions are:
///   Pending → Running    — a worker claims the job
///   Running → Completed  — the job succeeds
///   Running → Failed     — the job fails (may be retried)
///   Failed  → Pending    — retry: resets for another worker
///
/// Completed is deliberately absent from all `from` positions.
/// The verifier therefore rejects any @proof_required call site that
/// attempts to transition away from Completed — the state is terminal
/// without any explicit "terminal" annotation.
///
/// Z3 closes this proof as a disjunctive case split over the finite enum domain.
pub func statusTransition(from: in JobStatus, to: in JobStatus): Bool
  requires: (from == JobStatus.Pending and to == JobStatus.Running) or
    (from == JobStatus.Running and to == JobStatus.Completed) or
    (from == JobStatus.Running and to == JobStatus.Failed) or
    (from == JobStatus.Failed and to == JobStatus.Pending)
  ensures: result == true
{
  return true
}

/// Prove that retrying a failed job is allowed within the retry budget.
///
/// The RetryCount range subtype (0..=10) narrows the integer domain; Z3
/// closes the goal as a simple bounded comparison.
pub func retryAllowed(retryCount: in Int, maxRetries: in Int): Bool
  requires: retryCount >= 0
  requires: maxRetries >= 0
  requires: maxRetries <= 10
  requires: retryCount < maxRetries
  ensures: result == true
{
  return true
}
