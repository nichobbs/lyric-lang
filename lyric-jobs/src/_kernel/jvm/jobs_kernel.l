//! Jobs.Kernel.Jvm — JVM extern boundary for background job scheduler backends.
//!
//! JVM implementation of the same contract as Jobs.Kernel.Net.
//!
//! Hangfire has no JVM port.  Both the `hangfire` and `quartz` Lyric features
//! are satisfied on JVM by Quartz Scheduler (org.quartz-scheduler:quartz 2.3.2).
//! The @cfg gates are preserved so feature selection still controls which Maven
//! artifact is activated; at runtime both map to the same Quartz Scheduler API.
//!
//! Scheduler handle table, status strings, and results JSON format are identical
//! to the .NET kernel:
//!   status strings: "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled"
//!   results JSON:   [{"jobId":"...","status":"...","output":"...","error":"...",
//!                     "startedAt":N,"finishedAt":N},...]
//!
//! InProcessJobScheduler (no Maven dep) uses `lyric.jobs.InProcessScheduler`,
//! a custom in-process scheduler helper for single-JVM use.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Jobs.Kernel.Jvm

import Std.Core
import Std.Log

// ─── JVM threading and identity (always available) ────────────────────────────

@axiom("java.lang.Thread + java.util.UUID for sleep and identity (JVM)")
extern package lyric.jobs.Runtime {
  /// Return the current UTC wall-clock time as epoch milliseconds.
  pub func nowMs(): Long

  /// Block the calling thread for `ms` milliseconds (Thread.sleep).
  pub func sleepMs(ms: Int): Unit
    requires: ms >= 0

  /// Generate a new random string ID (backed by UUID.randomUUID().toString()).
  pub func generateId(): String
}

// ─── Hangfire (JVM degraded fallback: Quartz Scheduler) ──────────────────────
// Hangfire has no JVM port.  When compiling with feature = "hangfire" on JVM,
// the Quartz Scheduler is used as a functional substitute.  Job semantics are
// preserved; SQL Server storage is not available — jobs are memory-backed.
// @axiom documents the substitution explicitly.

@axiom("org.quartz.Scheduler — degraded JVM fallback for Hangfire.Core; Hangfire has no JVM port")
@cfg(feature = "hangfire")
extern package org.quartz.Scheduler {
  /// Initialise a Quartz scheduler with `workerCount` worker threads.
  /// `connectionString` is accepted for API parity but ignored on JVM
  /// (Quartz uses an in-memory RAMJobStore regardless of the value).
  pub func connect(connectionString: String, workerCount: Int): Result[Int, String]
    requires: connectionString.length >= 0
    requires: workerCount >= 1

  /// Trigger a job for immediate execution.  Returns the assigned job ID.
  pub func enqueue(
    schedulerId: Int,
    name:        String,
    payload:     String,
    maxAttempts: Int,
    timeoutMs:   Int
  ): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1

  /// Schedule a recurring job with a cron trigger.  Returns the job/trigger key.
  pub func schedule(
    schedulerId: Int,
    name:        String,
    payload:     String,
    cronExpr:    String,
    maxAttempts: Int,
    timeoutMs:   Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1

  /// Cancel a job by its key.
  pub func cancel(schedulerId: Int, jobId: String): Result[Unit, String]
    requires: jobId.length > 0

  /// Return the current status string for a job.
  pub func status(schedulerId: Int, jobId: String): Result[String, String]
    requires: jobId.length > 0

  /// Return a JSON array of execution history records for a job.
  pub func results(schedulerId: Int, jobId: String): Result[String, String]
    requires: jobId.length > 0
}

// ─── Quartz.NET → Quartz Scheduler (JVM) ─────────────────────────────────────

@axiom("org.quartz.Scheduler — JVM implementation of Quartz.NET scheduler contract")
@cfg(feature = "quartz")
extern package org.quartz.Scheduler {
  /// Initialise a Quartz scheduler with `workerCount` threads.
  /// Returns a scheduler handle.
  pub func connect(workerCount: Int): Result[Int, String]
    requires: workerCount >= 1

  /// Trigger a job for immediate execution.  Returns the assigned job ID.
  pub func enqueue(
    schedulerId: Int,
    name:        String,
    payload:     String,
    maxAttempts: Int,
    timeoutMs:   Int
  ): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1

  /// Schedule a recurring job with a cron trigger.  Returns the job/trigger key.
  pub func schedule(
    schedulerId: Int,
    name:        String,
    payload:     String,
    cronExpr:    String,
    maxAttempts: Int,
    timeoutMs:   Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1

  /// Interrupt and remove a job by its key.
  pub func cancel(schedulerId: Int, jobId: String): Result[Unit, String]
    requires: jobId.length > 0

  /// Return the current status string for a job/trigger.
  pub func status(schedulerId: Int, jobId: String): Result[String, String]
    requires: jobId.length > 0

  /// Return a JSON array of execution history records for a job.
  pub func results(schedulerId: Int, jobId: String): Result[String, String]
    requires: jobId.length > 0
}

// ─── InProcessJobScheduler helper (no Maven dep) ─────────────────────────────

@axiom("lyric.jobs.InProcessScheduler — custom in-process JVM helper for single-JVM testing")
extern package lyric.jobs.InProcessScheduler {
  /// Return the current UTC wall-clock time as epoch milliseconds.
  pub func nowMs(): Long
}

// ─── Shared re-exports ────────────────────────────────────────────────────────

/// Return the current UTC wall-clock time as epoch milliseconds.
pub func nowMs(): Long {
  lyric.jobs.Runtime.nowMs()
}

/// Block the calling thread for `ms` milliseconds.
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  lyric.jobs.Runtime.sleepMs(ms)
}

/// Generate a new unique job ID.
pub func generateId(): String {
  lyric.jobs.Runtime.generateId()
}

/// Open a backend scheduler.  For Hangfire (JVM degraded fallback), the
/// connection string is accepted for API parity but ignored; Quartz uses an
/// in-memory RAMJobStore on JVM.  A non-empty connection string emits a
/// warning so operators are not silently downgraded from SQL Server-backed
/// persistence to in-memory storage.
@cfg(feature = "hangfire")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  val conn = hangfireConnectionString()
  if conn.length > 0 {
    Std.Log.warn("lyric-jobs: Hangfire connection string ignored on JVM; Quartz uses RAMJobStore (in-memory). Persistence configured for .NET-only Hangfire.SqlServer.")
  }
  return org.quartz.Scheduler.connect(conn, workerCount)
}

/// Open a backend scheduler backed by Quartz on JVM.
@cfg(feature = "quartz")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  return org.quartz.Scheduler.connect(workerCount)
}

/// Enqueue a job for immediate execution.
@cfg(feature = "hangfire")
pub func enqueue(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String]
  requires: name.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  return org.quartz.Scheduler.enqueue(schedulerId, name, payload, maxAttempts, timeoutMs)
}

/// Enqueue a job for immediate execution.
@cfg(feature = "quartz")
pub func enqueue(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String]
  requires: name.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  return org.quartz.Scheduler.enqueue(schedulerId, name, payload, maxAttempts, timeoutMs)
}

/// Schedule a recurring job with a cron expression.
@cfg(feature = "hangfire")
pub func schedule(
  schedulerId: in Int,
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
  return org.quartz.Scheduler.schedule(schedulerId, name, payload, cronExpr, maxAttempts, timeoutMs)
}

/// Schedule a recurring job with a cron expression.
@cfg(feature = "quartz")
pub func schedule(
  schedulerId: in Int,
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
  return org.quartz.Scheduler.schedule(schedulerId, name, payload, cronExpr, maxAttempts, timeoutMs)
}

/// Cancel a job.
@cfg(feature = "hangfire")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  return org.quartz.Scheduler.cancel(schedulerId, jobId)
}

/// Cancel a job.
@cfg(feature = "quartz")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  return org.quartz.Scheduler.cancel(schedulerId, jobId)
}

/// Return the current status string for a job.
@cfg(feature = "hangfire")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return org.quartz.Scheduler.status(schedulerId, jobId)
}

/// Return the current status string for a job.
@cfg(feature = "quartz")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return org.quartz.Scheduler.status(schedulerId, jobId)
}

/// Return the JSON execution history for a job.
@cfg(feature = "hangfire")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return org.quartz.Scheduler.results(schedulerId, jobId)
}

/// Return the JSON execution history for a job.
@cfg(feature = "quartz")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return org.quartz.Scheduler.results(schedulerId, jobId)
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Read the Hangfire connection string from the environment.
// On JVM this value is accepted for API parity but ignored by Quartz (RAMJobStore).
func hangfireConnectionString(): String {
  match Std.Core.getEnv("LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING") {
    case Some(s) -> return s
    case None    -> return ""
  }
}
