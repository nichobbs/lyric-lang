// Jobs.Kernel.Net — .NET extern boundary for background job scheduler backends.
//
// Bridges Lyric's Jobs package to .NET job processing libraries:
//   Hangfire.Core  — Hangfire background processing (@cfg feature = "hangfire")
//   Quartz.Impl    — Quartz.NET cron scheduler       (@cfg feature = "quartz")
//
// Shared BCL functions (always available regardless of feature flags):
//   System.Threading — nowMs, sleepMs (Thread.Sleep), generateId (Guid)
//
// All scheduler functions use an integer `schedulerId` handle issued at
// connect time.  The kernel maintains a handle table (ConcurrentDictionary)
// mapping each ID to the underlying scheduler instance.
//
// Job status strings returned by `status`:
//   "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled"
//
// Results JSON format returned by `results`:
//   [{"jobId":"...","status":"...","output":"...","error":"...",
//     "startedAt":N,"finishedAt":N},...]
//
// Error strings contain the driver exception message and, where available,
// a structured error code.
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Jobs.Kernel.Net

import Std.Core

// ─── BCL threading and identity (always available) ────────────────────────────

@axiom("System.Threading for sleep and System.DateTime for wall clock (BCL)")
extern package System.Threading {
  /// Return the current UTC wall-clock time as epoch milliseconds.
  pub func nowMs(): Long

  /// Block the calling thread for `ms` milliseconds.
  pub func sleepMs(ms: Int): Unit
    requires: ms >= 0

  /// Generate a new random string ID (backed by Guid.NewGuid().ToString("N")).
  pub func generateId(): String
}

// ─── Hangfire ─────────────────────────────────────────────────────────────────

@axiom("Hangfire background job processing (.NET — Hangfire.Core + Hangfire.SqlServer)")
@cfg(feature = "hangfire")
extern package Hangfire.Core {
  /// Initialise a Hangfire server with `workerCount` worker threads.
  /// `connectionString` is the SQL Server (or other storage) DSN.
  /// Returns a scheduler handle.
  pub func connect(connectionString: String, workerCount: Int): Result[Int, String]
    requires: connectionString.length > 0
    requires: workerCount >= 1

  /// Enqueue a fire-and-forget job.  Returns the assigned job ID.
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

  /// Enqueue a recurring job using a cron expression.  Returns the job ID.
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

  /// Cancel a job by ID.
  pub func cancel(schedulerId: Int, jobId: String): Result[Unit, String]
    requires: jobId.length > 0

  /// Return the current status string for a job.
  pub func status(schedulerId: Int, jobId: String): Result[String, String]
    requires: jobId.length > 0

  /// Return a JSON array of result records for all attempts of a job.
  pub func results(schedulerId: Int, jobId: String): Result[String, String]
    requires: jobId.length > 0
}

// ─── Quartz.NET ───────────────────────────────────────────────────────────────

@axiom("Quartz.NET cron-capable scheduler (.NET — Quartz)")
@cfg(feature = "quartz")
extern package Quartz.Impl {
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

  /// Schedule a job with a cron trigger.  Returns the job/trigger key.
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

// ─── Shared re-exports ────────────────────────────────────────────────────────

/// Return the current UTC wall-clock time as epoch milliseconds.
pub func nowMs(): Long {
  System.Threading.nowMs()
}

/// Block the calling thread for `ms` milliseconds.
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  System.Threading.sleepMs(ms)
}

/// Generate a new unique job ID.
pub func generateId(): String {
  System.Threading.generateId()
}

/// Open a backend scheduler.  For Hangfire, reads the connection string from
/// the `LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING` env var automatically.
@cfg(feature = "hangfire")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  return Hangfire.Core.connect(hangfireConnectionString(), workerCount)
}

/// Open a backend scheduler.  For Quartz the scheduler is memory-backed by default.
@cfg(feature = "quartz")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  return Quartz.Impl.connect(workerCount)
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
  return Hangfire.Core.enqueue(schedulerId, name, payload, maxAttempts, timeoutMs)
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
  return Quartz.Impl.enqueue(schedulerId, name, payload, maxAttempts, timeoutMs)
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
  return Hangfire.Core.schedule(schedulerId, name, payload, cronExpr, maxAttempts, timeoutMs)
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
  return Quartz.Impl.schedule(schedulerId, name, payload, cronExpr, maxAttempts, timeoutMs)
}

/// Cancel a job.
@cfg(feature = "hangfire")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  return Hangfire.Core.cancel(schedulerId, jobId)
}

/// Cancel a job.
@cfg(feature = "quartz")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  return Quartz.Impl.cancel(schedulerId, jobId)
}

/// Return the current status string for a job.
@cfg(feature = "hangfire")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return Hangfire.Core.status(schedulerId, jobId)
}

/// Return the current status string for a job.
@cfg(feature = "quartz")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return Quartz.Impl.status(schedulerId, jobId)
}

/// Return the JSON execution history for a job.
@cfg(feature = "hangfire")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return Hangfire.Core.results(schedulerId, jobId)
}

/// Return the JSON execution history for a job.
@cfg(feature = "quartz")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  return Quartz.Impl.results(schedulerId, jobId)
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Read the Hangfire connection string from the environment.
// The env var is set by the host; falls back to an empty string which
// causes Hangfire to use an in-memory storage (development only).
func hangfireConnectionString(): String {
  match Std.Core.getEnv("LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING") {
    case Some(s) -> return s
    case None    -> return ""
  }
}
