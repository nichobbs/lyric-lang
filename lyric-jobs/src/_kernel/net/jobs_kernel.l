//! Jobs.Kernel.Net — .NET kernel boundary for background job schedulers.
//!
//! Phase 3 of #733: in-process scheduler functional via pure Lyric
//! ConcurrentDictionary state.  Replaces Lyric.Jobs.InProcessHost F# shim.
//!
//! Hangfire and Quartz.NET backends remain declarative-only — their
//! bindings return a clear "not yet implemented" error until durable-
//! persistence shims land (#781 follow-up).
//!
//! Shared threading primitives (nowMs, sleepMs, generateId) are thin
//! wrappers over Std.Time and Std.Uuid — no F# shim required.
//!
//! Job status strings returned by status:
//!   "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled"
//!
//! Results JSON format returned by results:
//!   [{"jobId":"...","status":"...","output":"...","error":"...",
//!     "startedAt":N,"finishedAt":N},...]
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
//!
//! Only active when compiled with feature = "dotnet" (the default; #1444-style
//! target-kernel split with `Jobs.Kernel.Jvm`) — the file-level `@cfg` erases
//! this whole file, including the module-level `val schedulerMap`/`jobMap`
//! that would otherwise call BCL-only `ConcurrentDictionary` externs, on a
//! `--target jvm` build.
@cfg(feature = "dotnet")
package Jobs.Kernel.Net

import Std.Core
import Std.Time
import Std.Uuid
import Std.Char

// ─── BCL threading and identity (always available) ────────────────────────────
pub func nowMs(): Long {
  return nowEpochMillis()
}

pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  sleepMillis(ms)
}

// Returns a hyphenated UUID string: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (36 chars).
pub func generateId(): String {
  return uuidToString(newUuid())
}

// ─── ConcurrentDictionary externs ────────────────────────────────────────────
extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

// ─── Scheduler state ──────────────────────────────────────────────────────────
record JobRecord {
  name: String
  payload: String
  maxAttempts: Int
  timeoutMs: Int
  var status: String = "Pending"
  var attempts: Int = 0
  var startedAt: Long = 0i64
  var finishedAt: Long = 0i64
  var error: String = ""
  var output: String = ""
}

record SchedulerMeta {
  workerCount: Int
}

record JobHandleCounter {
  var next: Int = 0
}

val jobHandleCounter: JobHandleCounter = JobHandleCounter()

val schedulerMap: ConcurrentDict[Int, SchedulerMeta] = newConcurrentDict()

// Global job store; GUIDs are unique across schedulers so no per-scheduler sharding needed.
val jobMap: ConcurrentDict[String, JobRecord] = newConcurrentDict()

// Minimal JSON string escaper for job results output.
func jobJsonStr(s: in String): String {
  var r = "\""
  var i = 0
  while i < s.length {
    val code = toInt(s[i])
    if code == 34 {
      r = r + "\\\""
    } else if code == 92 {
      r = r + "\\\\"
    } else if code == 10 {
      r = r + "\\n"
    } else if code == 13 {
      r = r + "\\r"
    } else if code == 9 {
      r = r + "\\t"
    } else {
      r = r + s[i].toString()
    }
    i = i + 1
  }
  r + "\""
}

// ─── In-process scheduler (Phase 3 functional path) ──────────────────────────
@cfg(feature = "inprocess")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  monitorEnter(jobHandleCounter)
  defer {
    monitorExit(jobHandleCounter)
  }
  jobHandleCounter.next = jobHandleCounter.next + 1
  val handle = jobHandleCounter.next
  val meta = SchedulerMeta(workerCount = workerCount)
  val _ = cdTryAdd(schedulerMap, handle, meta)
  Ok(handle)
}

@cfg(feature = "inprocess")
pub func enqueue(
  schedulerId: in Int, name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int
): Result[String, String]
  requires: name.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  var meta: SchedulerMeta = default()
  if not cdTryGetValue(schedulerMap, schedulerId, meta) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  val id = generateId()
  val rec = JobRecord(
    name = name,
    payload = payload,
    maxAttempts = maxAttempts,
    timeoutMs = timeoutMs,
    startedAt = nowMs()
  )
  val _ = cdTryAdd(jobMap, id, rec)
  Ok(id)
}

@cfg(feature = "inprocess")
pub func schedule(
  schedulerId: in Int,
  name: in String,
  payload: in String,
  cronExpr: in String,
  maxAttempts: in Int,
  timeoutMs: in Int,
): Result[String, String]
  requires: name.length > 0
  requires: cronExpr.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  var meta: SchedulerMeta = default()
  if not cdTryGetValue(schedulerMap, schedulerId, meta) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  Err(
    "lyric-jobs: cron scheduling not supported on in-process backend (Phase 3 of #733; Hangfire/Quartz shims are follow-ups)"
  )
}

@cfg(feature = "inprocess")
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  var meta: SchedulerMeta = default()
  if not cdTryGetValue(schedulerMap, schedulerId, meta) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  var rec: JobRecord = default()
  if cdTryGetValue(jobMap, jobId, rec) {
    monitorEnter(rec)
    defer {
      monitorExit(rec)
    }
    if rec.status == "Pending" or rec.status == "Running" {
      rec.status = "Cancelled"
      rec.finishedAt = nowMs()
    }
  }
  Ok(())
}

@cfg(feature = "inprocess")
pub func status(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  var meta: SchedulerMeta = default()
  if not cdTryGetValue(schedulerMap, schedulerId, meta) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  var rec: JobRecord = default()
  if cdTryGetValue(jobMap, jobId, rec) {
    monitorEnter(rec)
    defer {
      monitorExit(rec)
    }
    return Ok(rec.status)
  }
  Err("unknown job ID '" + jobId + "'")
}

@cfg(feature = "inprocess")
pub func results(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  var meta: SchedulerMeta = default()
  if not cdTryGetValue(schedulerMap, schedulerId, meta) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  var rec: JobRecord = default()
  if not cdTryGetValue(jobMap, jobId, rec) {
    return Ok("[]")
  }
  monitorEnter(rec)
  defer {
    monitorExit(rec)
  }
  val json = "[{\"jobId\":" + jobJsonStr(jobId) + ",\"status\":" + jobJsonStr(rec.status) + ",\"output\":" +
    jobJsonStr(rec.output) +
    ",\"error\":" +
    jobJsonStr(rec.error) +
    ",\"startedAt\":" +
    rec.startedAt.toString() +
    ",\"finishedAt\":" +
    rec.finishedAt.toString() +
    "}]"
  Ok(json)
}

// ─── Hangfire (Phase 3 follow-up of #733) ────────────────────────────────────
@cfg(feature = "hangfire")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  Err("lyric-jobs: Hangfire backend not yet implemented (Phase 3 follow-up of #733)")
}

// ─── Quartz.NET (Phase 3 follow-up of #733) ──────────────────────────────────
@cfg(feature = "quartz")
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  Err("lyric-jobs: Quartz.NET backend not yet implemented (Phase 3 follow-up of #733)")
}
