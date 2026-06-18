//! Jobs.Kernel.Net — .NET extern boundary for background job scheduler backends.
//!
//! Phase 3 of #733: in-process scheduler functional via
//! `Lyric.Jobs.InProcessHost`.  Hangfire and Quartz.NET backends remain
//! declarative-only — their bindings are routed to placeholder
//! `*NotYet` targets that return a clear "not yet implemented" error
//! until the durable-persistence shims land (#781 follow-up).
//!
//! Shared threading primitives (`nowMs`, `sleepMs`, `generateId`) bind to
//! `Lyric.Jobs.Threading` — the lyric-jobs equivalent of the thread-pool
//! utility namespace.
//!
//! Job status strings returned by `status`:
//!   "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled"
//!
//! Results JSON format returned by `results`:
//!   [{"jobId":"...","status":"...","output":"...","error":"...",
//!     "startedAt":N,"finishedAt":N},...]
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Jobs.Kernel.Net

import Std.Core

// ─── BCL threading and identity (always available) ────────────────────────────

@axiom("Lyric.Jobs.Threading.nowMs — DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()")
@externTarget("Lyric.Jobs.Threading.nowMs")
pub func nowMs(): Long = ()

@axiom("Lyric.Jobs.Threading.sleepMs — Thread.Sleep(ms) when ms > 0")
@externTarget("Lyric.Jobs.Threading.sleepMs")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
  = ()

@axiom("Lyric.Jobs.Threading.generateId — Guid.NewGuid().ToString(\"N\")")
@externTarget("Lyric.Jobs.Threading.generateId")
pub func generateId(): String = ()

// ─── In-process scheduler (Phase 3 functional path) ──────────────────────────
//
// Active when no feature flag is set OR when `feature = "inprocess"` is
// explicitly enabled.  The Hangfire / Quartz arms below shadow these
// with their own externs gated by the relevant feature.

@axiom("Lyric.Jobs.InProcessHost.connect — opens an in-process scheduler with a per-handle Jobs dictionary")
@externTarget("Lyric.Jobs.InProcessHost.connect")
@cfg(feature = "inprocess")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
  = ()

@axiom("Lyric.Jobs.InProcessHost.enqueue — assigns a fresh job ID and records lifecycle metadata")
@externTarget("Lyric.Jobs.InProcessHost.enqueue")
@cfg(feature = "inprocess")
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
  = ()

@axiom("Lyric.Jobs.InProcessHost.schedule — returns Err (cron requires durable persistence — see Hangfire/Quartz follow-up)")
@externTarget("Lyric.Jobs.InProcessHost.schedule")
@cfg(feature = "inprocess")
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
  = ()

@axiom("Lyric.Jobs.InProcessHost.cancel — idempotent; transitions Pending/Running -> Cancelled")
@externTarget("Lyric.Jobs.InProcessHost.cancel")
@cfg(feature = "inprocess")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
  = ()

@axiom("Lyric.Jobs.InProcessHost.status — returns the JobRecord's current status string")
@externTarget("Lyric.Jobs.InProcessHost.status")
@cfg(feature = "inprocess")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
  = ()

@axiom("Lyric.Jobs.InProcessHost.results — JSON array of attempts for this job ID")
@externTarget("Lyric.Jobs.InProcessHost.results")
@cfg(feature = "inprocess")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
  = ()

// ─── Hangfire (Phase 3 follow-up of #733) ────────────────────────────────────

@axiom("Hangfire backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Jobs.InProcessHost.hangfireConnectNotYet")
@cfg(feature = "hangfire")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
  = ()

// ─── Quartz.NET (Phase 3 follow-up of #733) ──────────────────────────────────

@axiom("Quartz.NET backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Jobs.InProcessHost.quartzConnectNotYet")
@cfg(feature = "quartz")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
  = ()
