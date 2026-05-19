// Jobs.Kernel.Net — .NET extern boundary for background job scheduler backends.
//
// Bridges Lyric's Jobs package to .NET job processing libraries:
//   Hangfire.Core  — Hangfire background processing (@cfg feature = "hangfire")
//   Quartz.Impl    — Quartz.NET cron scheduler       (@cfg feature = "quartz")
//
// Shared BCL functions (always available regardless of feature flags).
//
// All scheduler functions use an integer `schedulerId` handle issued at
// connect time.
//
// Job status strings returned by `status`:
//   "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled"
//
// Results JSON format returned by `results`:
//   [{"jobId":"...","status":"...","output":"...","error":"...",
//     "startedAt":N,"finishedAt":N},...]
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@axiom("BCL system threading and job scheduling operations conform to their documented .NET contracts")
package Jobs.Kernel.Net

import Std.Core

// ─── BCL threading and identity (always available) ────────────────────────────

/// Return the current UTC wall-clock time as epoch milliseconds.
@axiom("System.DateTimeOffset.UtcNow.ToUnixTimeMilliseconds (BCL)")
pub func nowMs(): Long = 0i64

/// Block the calling thread for `ms` milliseconds.
@axiom("System.Threading.Thread.Sleep (BCL)")
pub func sleepMs(ms: in Int): Unit = ()

/// Generate a new random string ID (backed by Guid.NewGuid().ToString("N")).
@axiom("System.Guid.NewGuid().ToString (BCL)")
pub func generateId(): String = ""

// ─── Backend: open a scheduler connection ────────────────────────────────────

/// Open a backend scheduler.
@axiom("Hangfire or Quartz.NET scheduler initialisation (BCL)")
@cfg(feature = "hangfire")
pub func connect(workerCount: in Int): Result[Int, String] = Err("")

/// Open a backend scheduler.
@axiom("Quartz.NET scheduler initialisation (BCL)")
@cfg(feature = "quartz")
pub func connect(workerCount: in Int): Result[Int, String] = Err("")

// ─── Job enqueueing ───────────────────────────────────────────────────────────

/// Enqueue a fire-and-forget job.  Returns the assigned job ID.
@axiom("Hangfire.IBackgroundJobClient.Enqueue (BCL)")
@cfg(feature = "hangfire")
pub func enqueue(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String] = Err("")

/// Trigger a job for immediate execution.  Returns the assigned job ID.
@axiom("Quartz.IScheduler.TriggerJob (BCL)")
@cfg(feature = "quartz")
pub func enqueue(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String] = Err("")

// ─── Job scheduling (cron) ───────────────────────────────────────────────────

/// Enqueue a recurring job using a cron expression.  Returns the job ID.
@axiom("Hangfire.RecurringJob.AddOrUpdate (BCL)")
@cfg(feature = "hangfire")
pub func schedule(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  cronExpr:    in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String] = Err("")

/// Schedule a job with a cron trigger.  Returns the job/trigger key.
@axiom("Quartz.IScheduler.ScheduleJob with cron trigger (BCL)")
@cfg(feature = "quartz")
pub func schedule(
  schedulerId: in Int,
  name:        in String,
  payload:     in String,
  cronExpr:    in String,
  maxAttempts: in Int,
  timeoutMs:   in Int
): Result[String, String] = Err("")

// ─── Job cancellation ────────────────────────────────────────────────────────

/// Cancel a job by ID.
@axiom("Hangfire.IBackgroundJobClient.Delete (BCL)")
@cfg(feature = "hangfire")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String] = Err("")

/// Interrupt and remove a job by its key.
@axiom("Quartz.IScheduler.DeleteJob (BCL)")
@cfg(feature = "quartz")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String] = Err("")

// ─── Job status ──────────────────────────────────────────────────────────────

/// Return the current status string for a job.
@axiom("Hangfire.IMonitoringApi.JobDetails (BCL)")
@cfg(feature = "hangfire")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String] = Err("")

/// Return the current status string for a job/trigger.
@axiom("Quartz.IScheduler.GetTriggerState (BCL)")
@cfg(feature = "quartz")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String] = Err("")

// ─── Job results ─────────────────────────────────────────────────────────────

/// Return a JSON array of result records for all attempts of a job.
@axiom("Hangfire.IMonitoringApi.JobDetails history (BCL)")
@cfg(feature = "hangfire")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String] = Err("")

/// Return a JSON array of execution history records for a job.
@axiom("Quartz.ISchedulerListener execution history (BCL)")
@cfg(feature = "quartz")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String] = Err("")
