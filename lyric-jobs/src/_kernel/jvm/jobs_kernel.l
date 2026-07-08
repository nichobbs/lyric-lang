//! Jobs.Kernel.Jvm — JVM extern boundary for background job scheduler backends.
//!
//! Mirrors Jobs.Kernel.Net's contract (`connect` / `enqueue` / `schedule` /
//! `cancel` / `status` / `results` / `nowMs` / `sleepMs` / `generateId`) over
//! real `org.quartz-scheduler:quartz` types via JVM auto-FFI, replacing the
//! `extern package org.quartz.Scheduler { … }` / `extern package
//! lyric.jobs.Runtime { … }` blocks this file used to declare — `extern
//! package` parses but is a no-op in both the type checker and both codegens
//! (epic #5324), so every function below was unreachable dead declaration
//! until this rewrite (same elimination as the `environment_host.l` /
//! `process_host.l` stdlib kernel migration, D-progress-625).
//!
//! Hangfire has no JVM port.  Both the `hangfire` and `quartz` Lyric features
//! are satisfied on JVM by real Quartz Scheduler usage; the `@cfg` gates in
//! `Jobs.connectHangfire` / `Jobs.connectQuartz` are preserved so feature
//! selection still controls which Maven artifact is restored, but both
//! resolve to the same `connect` implementation below.
//!
//! ─── What is genuinely real here, and what NativeJobScheduler cannot do ───
//! `connect` starts a real `org.quartz.impl.StdSchedulerFactory`-built
//! `Scheduler` (RAMJobStore, in-memory — matches the .NET kernel's own
//! `inprocess` ConcurrentDictionary path in not persisting across restarts).
//! `enqueue` / `schedule` build real `JobDetail` + `Trigger` pairs and submit
//! them via `Scheduler.scheduleJob`, so a genuine background thread in
//! Quartz's own thread pool executes the job.  `cancel` calls the real
//! `Scheduler.deleteJob`.  `status` / `results` poll real Quartz state
//! (`Scheduler.checkExists`) rather than fabricating a result.
//!
//! What Quartz's job actually *runs* is `org.quartz.jobs.NativeJob`, a Job
//! implementation shipped by `quartz-jobs` that runs a native OS command —
//! NOT an arbitrary Lyric callback.  This is not a shortcut specific to this
//! kernel: `NativeJobScheduler.enqueue`/`schedule` (both targets, including
//! `Jobs.Kernel.Net`) never accepted a `JobHandler` in the first place, so
//! there is no application code for Quartz to call back into even in
//! principle — only `InProcessJobScheduler.runNext`/`runAll` take a handler
//! (`jobs.l`).  Implementing `org.quartz.Job` from a Lyric record so a *real*
//! handler could run inside Quartz's thread pool needs the JVM analogue of
//! `impl <ExternInterface> for Record` — shipped for MSIL (D105, docs/51)
//! but not yet for JVM (no JVM `InterfaceImpl`/vtable-wiring codegen exists
//! today). Tracked as a compiler-level follow-up; this kernel runs a fixed,
//! always-succeeding no-op command (`true`) as the real unit of
//! Quartz-scheduled work so that `enqueue`/`schedule`/`cancel`/`status`
//! exercise genuine Quartz job-store and thread-pool machinery end-to-end,
//! and documents `output`/`error` as always empty (no handler ran) rather
//! than fabricating a result.
//!
//! Scheduler handle table, status strings, and results JSON format are
//! identical to `Jobs.Kernel.Net`:
//!   status strings: "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled"
//!   results JSON:   [{"jobId":"...","status":"...","output":"...","error":"...",
//!                     "startedAt":N,"finishedAt":N},...]
//! `status` only distinguishes Pending (still registered with the scheduler)
//! / Cancelled (explicitly cancelled) / Succeeded (fired and — because the
//! default `JobDetail` is non-durable — removed by Quartz itself).  A
//! recurring `schedule()` cron job never reaches a terminal state this way
//! (there is no such thing as "this recurring job is done"); this mirrors
//! `Jobs.Kernel.Net`, which does not implement `schedule` for the native path
//! at all.
//!
//! `java.util.concurrent.ConcurrentHashMap` generics erase away, so
//! `schedulerRegistry` / `jobRegistry` are used via their raw type, same as
//! `Resilience.Kernel.Jvm`'s `circuitRegistry`.  Presence is always checked
//! with a real `containsKey` before a `get` + `?? panic(...)` read (matching
//! `Resilience.Kernel.Jvm`'s idiom): matching `case None -> … case Some(_) ->
//! …` directly on a raw `.get()` result type-checks but currently miscompiles
//! on this backend (`Jvm.Codegen: match not exhaustive` at runtime — filed
//! separately, not fixed here since it is a general JVM match-lowering bug
//! unrelated to this kernel), so this kernel avoids that pattern entirely.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
package Jobs.Kernel.Jvm

import Std.Core
import Std.Time
import Std.Uuid
import Std.Char

// ─── JVM auto-FFI bindings against real Quartz / JDK types ────────────────────
extern type JThread = "java.lang.Thread"

extern type JProperties = "java.util.Properties"

extern type JClass = "java.lang.Class"

extern type JConcurrentHashMap = "java.util.concurrent.ConcurrentHashMap"

extern type JReentrantLock = "java.util.concurrent.locks.ReentrantLock"

extern type JAtomicInteger = "java.util.concurrent.atomic.AtomicInteger"

extern type JStdSchedulerFactory = "org.quartz.impl.StdSchedulerFactory"

// Bound to Quartz's own public `StdScheduler` facade class (`org.quartz.impl`),
// not the `Scheduler` interface it implements: the JVM auto-FFI class-file
// reader intentionally skips interface class files entirely (`Jvm.ClassReader`
// only parses classes), so calling any method through an interface-typed
// extern type currently mis-emits `invokevirtual` against an interface owner
// and fails class-load verification (`IncompatibleClassChangeError`) — a real,
// general JVM backend gap, not fixed here. `StdSchedulerFactory.getScheduler()`
// is documented/guaranteed to return a `StdScheduler` instance (verified: its
// runtime class really is `org.quartz.impl.StdScheduler`), and `StdScheduler`
// declares every method this kernel calls directly on itself (not inherited),
// so binding here avoids the interface-resolution gap entirely while calling
// through the exact same real methods `Scheduler` declares.
extern type JScheduler = "org.quartz.impl.StdScheduler"

extern type JJobBuilder = "org.quartz.JobBuilder"

extern type JTriggerBuilder = "org.quartz.TriggerBuilder"

extern type JCronScheduleBuilder = "org.quartz.CronScheduleBuilder"

extern type JJobKey = "org.quartz.JobKey"

extern type JTriggerKey = "org.quartz.TriggerKey"

extern type JJobDetail = "org.quartz.JobDetail"

extern type JTrigger = "org.quartz.Trigger"

// The fixed group every Lyric-Jobs-managed Quartz job/trigger key lives in;
// `generateId()` (a UUID) is the name half, so (name, group) pairs never collide.
val jobGroup: String = "LYRIC_JOBS"

// A fixed, always-succeeding native command — see file header for why this
// (rather than an arbitrary application callback) is the real unit of work
// Quartz's thread pool executes.  `/bin/sh -c "true "` on POSIX via
// `NativeJob`'s own OS-name branching; harmless and deterministic.
val noOpCommand: String = "true"

// ─── State (thread-safe; mirrors Resilience.Kernel.Jvm's ConcurrentHashMap use) ─
// Field order matters here: a `var …: Bool = false` field immediately
// followed by a `Long` field was observed to miscompile on this backend
// (`VerifyError: Bad type on operand stack`, a record-constructor local-slot
// width bug — reproduced independently of Jobs in a minimal record with the
// same field shape).  Both `Long` fields are declared before `cancelled`
// below to avoid it; a general codegen gap, not fixed here.
// All fields explicit (no `= default` initializers) at every construction
// site: a defaulted field ahead of a `Long`, or multiple defaulted fields
// ahead of a trailing reference field, were both observed to miscompile the
// record constructor on this backend (see `newJobRecord` below and the file
// header note on JVM backend record-constructor bugs); not fixed here.
record JobRecord {
  name: String
  payload: String
  maxAttempts: Int
  timeoutMs: Int
  startedAt: Long
  var finishedAt: Long
  var cancelled: Bool
  lock: JReentrantLock
}

val schedulerHandleCounter: JAtomicInteger = JAtomicInteger.new(0)

// Keyed by `handle.toString()` — a real `org.quartz.Scheduler` instance per handle.
val schedulerRegistry: JConcurrentHashMap = JConcurrentHashMap.new()

// Keyed by jobId (UUID). Global across schedulers, matching Jobs.Kernel.Net.
val jobRegistry: JConcurrentHashMap = JConcurrentHashMap.new()

func schedulerHandleKey(schedulerId: in Int): String {
  schedulerId.toString()
}

func schedulerExists(schedulerId: in Int): Bool {
  schedulerRegistry.containsKey(schedulerHandleKey(schedulerId))
}

// Only call after `schedulerExists` has confirmed presence; the map entry is
// never removed once inserted, so no TOCTOU race exists between the two calls.
func getScheduler(schedulerId: in Int): JScheduler {
  val existing = schedulerRegistry.get(schedulerHandleKey(schedulerId))
  existing ??
    panic("lyric-jobs: scheduler handle " + schedulerId.toString() + " vanished (internal invariant violation)")
}

func jobExists(jobId: in String): Bool {
  jobRegistry.containsKey(jobId)
}

// Only call after `jobExists` has confirmed presence; `jobRegistry` entries
// are mutated in place and never removed.
func getJobRecord(jobId: in String): JobRecord {
  val existing = jobRegistry.get(jobId)
  existing ?? panic("lyric-jobs: job record '" + jobId + "' vanished (internal invariant violation)")
}

// Minimal JSON string escaper for job results output (identical to Jobs.Kernel.Net).
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

// ─── BCL/JDK-parity threading and identity (always available) ────────────────
pub func nowMs(): Long {
  return nowEpochMillis()
}

pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  JThread.sleep(ms.toLong())
}

pub func generateId(): String {
  return uuidToString(newUuid())
}

// ─── Real Quartz Scheduler backend ────────────────────────────────────────────
/// Start a real Quartz `Scheduler` (RAMJobStore, `workerCount` worker
/// threads) and register it under a fresh handle.  Each call gets its own
/// uniquely-named scheduler instance (`StdSchedulerFactory.getScheduler()`
/// otherwise returns a cached instance for a repeated `instanceName`).
pub func connect(workerCount: in Int): Result[Int, String]
  requires: workerCount >= 1
{
  try {
    val props = JProperties.new()
    val _ = props.setProperty("org.quartz.scheduler.instanceName", "LyricJobs-" + generateId())
    val _ = props.setProperty("org.quartz.threadPool.threadCount", workerCount.toString())
    val _ = props.setProperty("org.quartz.jobStore.class", "org.quartz.simpl.RAMJobStore")
    val factory = JStdSchedulerFactory.new(props)
    // `getScheduler()` is declared to return `org.quartz.Scheduler` (the
    // interface); the explicit `JScheduler` annotation here re-types the
    // local to `StdScheduler` (see the `extern type JScheduler` comment
    // above) so every subsequent call resolves against a real, loadable
    // class instead of the skipped interface.
    val scheduler: JScheduler = factory.getScheduler()
    scheduler.start()
    val handle = schedulerHandleCounter.incrementAndGet()
    val _ = schedulerRegistry.put(handle.toString(), scheduler)
    Ok(handle)
  } catch Bug as b {
    Err("lyric-jobs: failed to start Quartz scheduler: " + b.message)
  }
}

/// Trigger a job for immediate execution.  Returns the assigned job ID.
/// See file header: the scheduled job runs a fixed no-op native command, not
/// an application callback — `NativeJobScheduler` has no handler-registration
/// API on either target.
///
/// The job/trigger-building steps below are split into small helper
/// functions (rather than one long fluent chain of `val`s) to keep each
/// function's live-local count low: a JVM backend local-slot-width bug for
/// `Long` locals (surfaced by `nowMs()`'s return value colliding with an
/// adjacent slot — `VerifyError: Bad type on operand stack`) was observed
/// when this logic lived in one large function body.  A general codegen
/// gap, not specific to this kernel; not fixed here.
func buildOneShotJobDetail(jobKey: in JJobKey): JJobDetail {
  val nativeJobClass = JClass.forName("org.quartz.jobs.NativeJob")
  JJobBuilder.newJob(nativeJobClass).withIdentity(jobKey).usingJobData("command", noOpCommand).build()
}

func buildDurableJobDetail(jobKey: in JJobKey): JJobDetail {
  val nativeJobClass = JClass.forName("org.quartz.jobs.NativeJob")
  JJobBuilder.newJob(nativeJobClass).withIdentity(jobKey).usingJobData("command", noOpCommand).storeDurably(true).build()
}

func buildImmediateTrigger(triggerKey: in JTriggerKey, jobKey: in JJobKey): JTrigger {
  JTriggerBuilder.newTrigger().withIdentity(triggerKey).forJob(jobKey).startNow().build()
}

func buildCronTrigger(triggerKey: in JTriggerKey, jobKey: in JJobKey, cronExpr: in String): JTrigger {
  val cronSchedule = JCronScheduleBuilder.cronSchedule(cronExpr)
  JTriggerBuilder.newTrigger().withIdentity(triggerKey).forJob(jobKey).withSchedule(cronSchedule).build()
}

func newJobRecord(name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int): JobRecord {
  JobRecord(
    name = name,
    payload = payload,
    maxAttempts = maxAttempts,
    timeoutMs = timeoutMs,
    startedAt = nowMs(),
    finishedAt = 0i64,
    cancelled = false,
    lock = JReentrantLock.new()
  )
}

pub func enqueue(
  schedulerId: in Int, name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int
): Result[String, String]
  requires: name.length > 0
  requires: maxAttempts >= 1
  requires: timeoutMs >= 1
{
  if not schedulerExists(schedulerId) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  val scheduler = getScheduler(schedulerId)
  try {
    val jobId = generateId()
    val jobKey = JJobKey.new(jobId, jobGroup)
    val triggerKey = JTriggerKey.new(jobId, jobGroup)
    val jobDetail = buildOneShotJobDetail(jobKey)
    val trigger = buildImmediateTrigger(triggerKey, jobKey)
    val _ = jobRegistry.put(jobId, newJobRecord(name, payload, maxAttempts, timeoutMs))
    val _ = scheduler.scheduleJob(jobDetail, trigger)
    Ok(jobId)
  } catch Bug as b {
    Err("lyric-jobs: failed to enqueue job '" + name + "': " + b.message)
  }
}

/// Schedule a recurring job with a real Quartz `CronTrigger`.  Returns the
/// job/trigger key (jobId).  See the file header for why `status()` cannot
/// report a terminal state for a recurring job.
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
  if not schedulerExists(schedulerId) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  val scheduler = getScheduler(schedulerId)
  try {
    val jobId = generateId()
    val jobKey = JJobKey.new(jobId, jobGroup)
    val triggerKey = JTriggerKey.new(jobId, jobGroup)
    val jobDetail = buildDurableJobDetail(jobKey)
    val trigger = buildCronTrigger(triggerKey, jobKey, cronExpr)
    val _ = jobRegistry.put(jobId, newJobRecord(name, payload, maxAttempts, timeoutMs))
    val _ = scheduler.scheduleJob(jobDetail, trigger)
    Ok(jobId)
  } catch Bug as b {
    Err("lyric-jobs: failed to schedule cron job '" + name + "': " + b.message)
  }
}

// Marks `rec` cancelled (idempotent) while holding its lock.  Extracted into
// its own function, and using plain `lock()`/`unlock()` rather than `defer`,
// because a `defer`-guarded block combined with `try`/`catch`-as-expression
// and multiple early-return paths in one function body was observed to
// produce a real JVM backend bug (`VerifyError: Inconsistent stackmap
// frames`, a local-variable-slot-reuse mismatch) — a general codegen gap,
// not something specific to this kernel; not fixed here.  No panicking
// operation runs between `lock()` and `unlock()` below, so the lock is
// always released.
func markCancelledLocked(rec: in JobRecord): Unit {
  rec.lock.lock()
  if not rec.cancelled and rec.finishedAt == 0i64 {
    rec.cancelled = true
    rec.finishedAt = nowMs()
  }
  rec.lock.unlock()
}

/// Interrupt and remove a job by its key via the real `Scheduler.deleteJob`.
pub func cancel(schedulerId: in Int, jobId: in String): Result[Unit, String]
  requires: jobId.length > 0
{
  if not schedulerExists(schedulerId) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  val scheduler = getScheduler(schedulerId)
  try {
    val jobKey = JJobKey.new(jobId, jobGroup)
    val _ = scheduler.deleteJob(jobKey)
    if jobExists(jobId) {
      markCancelledLocked(getJobRecord(jobId))
    }
    Ok(())
  } catch Bug as b {
    Err("lyric-jobs: failed to cancel job '" + jobId + "': " + b.message)
  }
}

// Computes the status string while holding `rec`'s lock (see
// `markCancelledLocked` above for why this is a separate, `defer`-free
// function).  `checkExists` is wrapped in its own `try`/`catch` statement
// (not an expression assignment) to further avoid the stackmap bug.
func computeStatusLocked(scheduler: in JScheduler, rec: in JobRecord, jobId: in String): String {
  rec.lock.lock()
  if rec.cancelled {
    rec.lock.unlock()
    return "Cancelled"
  }
  val jobKey = JJobKey.new(jobId, jobGroup)
  var stillRegistered = false
  try {
    stillRegistered = scheduler.checkExists(jobKey)
  } catch Bug as _ {
    stillRegistered = false
  }
  var result = "Pending"
  if not stillRegistered {
    if rec.finishedAt == 0i64 {
      rec.finishedAt = nowMs()
    }
    result = "Succeeded"
  }
  rec.lock.unlock()
  result
}

/// Return the current status string for a job/trigger, derived from real
/// Quartz scheduler state (`Scheduler.checkExists`) plus the `cancelled` flag
/// this kernel tracks locally (Quartz has no "cancelled vs completed" signal
/// once a job's non-durable `JobDetail` has been auto-removed).
pub func status(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  if not schedulerExists(schedulerId) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  if not jobExists(jobId) {
    return Err("unknown job ID '" + jobId + "'")
  }
  val scheduler = getScheduler(schedulerId)
  val rec = getJobRecord(jobId)
  Ok(computeStatusLocked(scheduler, rec, jobId))
}

/// Return a JSON array of execution history records for a job.  `output` /
/// `error` are always empty — see file header (no application handler ran).
pub func results(schedulerId: in Int, jobId: in String): Result[String, String]
  requires: jobId.length > 0
{
  if not schedulerExists(schedulerId) {
    return Err("unknown scheduler handle " + schedulerId.toString())
  }
  if not jobExists(jobId) {
    return Ok("[]")
  }
  val rec = getJobRecord(jobId)
  match status(schedulerId, jobId) {
    case Err(msg) -> Err(msg)
    case Ok(st) -> {
      val json = "[{\"jobId\":" + jobJsonStr(jobId) + ",\"status\":" + jobJsonStr(st) + ",\"output\":" + jobJsonStr("") +
        ",\"error\":" +
        jobJsonStr("") +
        ",\"startedAt\":" +
        rec.startedAt.toString() +
        ",\"finishedAt\":" +
        rec.finishedAt.toString() +
        "}]"
      Ok(json)
    }
  }
}
