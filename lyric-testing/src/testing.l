//! Testing — mock implementations and test helpers for Lyric libraries.
//! Stability: @experimental — the mock implementations and assertion helpers
//! have tests, but the surface is intentionally rough and may grow new helpers
//! ahead of `1.0`.
//!
//! WARNING (thread safety): All Mock implementations in this library are NOT
//! thread-safe.  Use them only in single-threaded test contexts; do not
//! share a mock instance across concurrent test workers.  See
//! lyric-lang #411.
//!
//! WARNING (failure injection): The current mocks simulate only the happy path
//! (success returns).  Tests that need to exercise error-handling paths
//! must subclass the relevant interface manually.  Configurable
//! failure-injection hooks are tracked as lyric-lang #410.
//!
//! Provides in-process mock implementations of Cache, Mail, Storage, Mq,
//! Session, Flags, Db, Jobs, Search, and I18n interfaces so that unit tests can exercise
//! application logic without real infrastructure.  Also provides assertion
//! helpers for writing concise, readable test cases.
//!
//! Usage:
//!
//!   import Testing
//!   import Std.Core
//!
//!   val ctx = Testing.newTestContext()
//!   Testing.enable(ctx.flags, "new-checkout")
//!   Testing.assertOk(someFunction(ctx.mail, ctx.storage), "expected success")
//!   Testing.assertEq(ctx.mail.sentCount().toString(), "1", "one email sent")
//!
//! See lyric-testing/README.md.
@runtime_checked
@io
package Testing

import Std.Core
import Std.Collections
import Std.Iter
import Std.Time
import Std.Sort
import Std.String as Str
import Std.Parse
import Cache as Cache
import Mail
import Storage
import Mq
import Session
import Flags
import Db
import Jobs
import Search
import I18n

// ─── Test support types ───────────────────────────────────────────────────────
/// A captured outbound email as recorded by MockMailSender.
@stable(since = "0.1")
pub record SentEmail {
  to: String
  subject: String
  textBody: String
  htmlBody: String
}

/// A stored object as recorded by MockStorageBucket.
@stable(since = "0.1")
pub record StoredObject {
  key: String
  dataBase64: String
  contentType: String
}

/// A captured message header as recorded by MockMessageQueue.
@stable(since = "0.1")
pub record TestMessageHeader {
  key: String
  value: String
}

/// A published message as recorded by MockMessageQueue.
@stable(since = "0.1")
pub record PublishedMessage {
  body: String
  headers: slice[TestMessageHeader]
  // ─── TestClock ────────────────────────────────────────────────────────────────
}

/// A controllable clock for deterministic time-dependent tests.
///
/// Advance the clock with `advance(ms)` to simulate the passage of time
/// without waiting for real wall-clock time.
///
/// Opaque so `currentEpochMs` can only move forward through `advance`:
/// a public mutable field would let a test move time backwards (or set it
/// negative) directly, bypassing `advance`'s own `requires: ms >= 0i64`.
@stable(since = "0.1")
pub opaque type TestClock {
  var currentEpochMs: Long
  invariant: currentEpochMs >= 0i64
}

/// Advance the test clock by `ms` milliseconds.
///
/// `ms` must be non-negative (time cannot move backwards) and small enough
/// that `currentEpochMs + ms` cannot overflow `Long` — the second bound is
/// expressed against the literal `Long` maximum (`9223372036854775807i64`;
/// there is no `Long.MAX` constant in the stdlib).
@stable(since = "0.1")
pub func advance(clock: in TestClock, ms: in Long): Unit
  requires: ms >= 0i64
  requires: ms <= 9223372036854775807i64 - now(clock)
  ensures: now(clock) == old(now(clock)) + ms
{
  clock.currentEpochMs = clock.currentEpochMs + ms
}

/// Return the current epoch time in milliseconds from the test clock.
@pure
@stable(since = "0.1")
pub func now(clock: in TestClock): Long {
  return clock.currentEpochMs
}

// ─── MockMailSender ───────────────────────────────────────────────────────────
/// Mock email sender that captures sent messages in memory for assertion.
///
/// Thread safety: not thread-safe in v1.
@stable(since = "0.1")
pub ref record MockMailSender {
  var sentEmails: List[SentEmail]
  var count: Int
}

impl Mail.MailSender for MockMailSender {
  func send(msg: in Mail.EmailMessage): Result[Unit, Mail.MailError] {
    // Honor the MailSender.send contract (#5499 / #5507): every implementation
    // must reject CRLF/NUL header injection before dispatch. Running the same
    // guard the in-tree NativeSender uses keeps the mock a faithful stand-in —
    // a test that sends an injected message through it observes the same Err a
    // real sender would, and does NOT record the message as "sent".
    match Mail.validateNoInjection(msg) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    val toAddr = if msg.to.length == 0 { "" } else { msg.to[0].address }
    val captured = SentEmail(to = toAddr, subject = msg.subject, textBody = msg.textBody, htmlBody = msg.htmlBody)
    self.sentEmails.add(captured)
    self.count = self.count + 1
    return Ok(())
  }
  func close(): Unit {
    // No-op for the mock sender.
  }
}

/// Return the most recently sent email, or None if none have been sent.
@stable(since = "0.1")
pub func lastSent(sender: in MockMailSender): Option[SentEmail] {
  if sender.count == 0 {
    return None
  }
  return Some(value = sender.sentEmails[sender.count - 1])
}

/// Return the number of emails sent through this mock sender.
@stable(since = "0.1")
pub func sentCount(sender: in MockMailSender): Int {
  return sender.count
}

/// Clear all captured emails from the mock sender.
@stable(since = "0.1")
pub func clearSent(sender: in MockMailSender): Unit {
  sender.sentEmails = newList()
  sender.count = 0
}

// ─── MockStorageBucket ────────────────────────────────────────────────────────
/// Mock storage bucket that keeps objects in memory for assertion.
///
/// Keys are validated like every real backend (`Storage.isSafeKey`, or
/// `Storage.isSafePrefix` for `list`), so a rejected key returns
/// `Err(StorageError(code = "INVALID_KEY"))` here too, and `list` pages by
/// `maxKeys` with the last returned key as the continuation token.
/// Otherwise every operation succeeds.  Use `callCount` to verify that
/// specific methods were invoked.
@stable(since = "0.1")
pub ref record MockStorageBucket {
  var objects: Map[String, StoredObject]
  var orderedKeys: List[String]
  bucketName: String
  var callCount: Int
}

impl Storage.StorageBucket for MockStorageBucket {
  func put(
    key: in String, dataBase64: in String, contentType: in String, userMeta: in Map[String, String]
  ): Result[Storage.StorageMetadata, Storage.StorageError] {
    if not Storage.isSafeKey(key) {
      return Err(mockInvalidKey(key))
    }
    val obj = StoredObject(key = key, dataBase64 = dataBase64, contentType = contentType)
    val existing: Option[StoredObject] = mapGet(self.objects, key)
    if not isSome(existing) {
      self.orderedKeys.add(key)
    }
    self.objects[key] = obj
    self.callCount = self.callCount + 1
    val meta = Storage.StorageMetadata(
      contentType = contentType,
      contentLength = 0,
      etag = "mock-etag",
      lastModified = "",
      userMeta = userMeta
    )
    return Ok(meta)
  }
  func get(

    key: in String,
  ): Result[Storage.StorageObject, Storage.StorageError] {
    if not Storage.isSafeKey(key) {
      return Err(mockInvalidKey(key))
    }
    val found: Option[StoredObject] = mapGet(self.objects, key)
    if not isSome(found) {
      return Err(Storage.StorageError(message = "not found: " + key, code = "NOT_FOUND"))
    }
    val obj = unwrapOr(found, StoredObject(key = "", dataBase64 = "", contentType = ""))
    val meta = Storage.StorageMetadata(
      contentType = obj.contentType,
      contentLength = 0,
      etag = "mock-etag",
      lastModified = "",
      userMeta = newMap()
    )
    val result = Storage.StorageObject(bucket = self.bucketName, key = key, metadata = meta, dataBase64 = obj.dataBase64)
    return Ok(result)
  }
  func delete(

    key: in String,
  ): Result[Unit, Storage.StorageError] {
    if not Storage.isSafeKey(key) {
      return Err(mockInvalidKey(key))
    }
    self.objects.remove(key)
    var newKeys: List[String] = newList()
    for k in self.orderedKeys {
      if k != key {
        newKeys.add(k)
      }
    }
    self.orderedKeys = newKeys
    return Ok(())
  }
  func list(

    prefix: in String,
    continuationToken: in String,
    maxKeys: in Int,
  ): Result[Storage.ListResult, Storage.StorageError]
    requires: maxKeys >= 1
    requires: maxKeys <= 1000
  {
    if not Storage.isSafePrefix(prefix) {
      return Err(mockInvalidKey(prefix))
    }
    // Same paging as `Storage.LocalBucket.list` (#7333): keys under `prefix`
    // strictly after `continuationToken`, in ordinal order, `maxKeys` at a
    // time.  Resuming by comparison, not by finding the token's key, keeps
    // paging correct when that key was deleted between pages.
    val matching: List[String] = newList()
    for k in self.orderedKeys {
      if Str.startsWith(k, prefix) and (continuationToken.length == 0 or Str.compare(k, continuationToken) > 0) {
        matching.add(k)
      }
    }
    val sorted = sortStrings(matching.toArray())
    val truncated = sorted.length > maxKeys
    val pageCount = if truncated { maxKeys } else { sorted.length }
    val acc: List[Storage.ListEntry] = newList()
    var i = 0
    while i < pageCount {
      acc.add(Storage.ListEntry(key = sorted[i], contentLength = 0, lastModified = "", etag = "mock-etag"))
      i = i + 1
    }
    val entries = acc.toArray()
    val next: Option[String] = if truncated and pageCount > 0 { Some(value = sorted[pageCount - 1]) } else { None }
    val result = Storage.ListResult(entries = entries, nextContinuationToken = next, isTruncated = truncated)
    return Ok(result)
  }
  func presignedUrl(

    key: in String,
    expiresInSeconds: in Int,
  ): Result[String, Storage.StorageError]
    requires: expiresInSeconds >= 1
    requires: expiresInSeconds <= 604800
  {
    if not Storage.isSafeKey(key) {
      return Err(mockInvalidKey(key))
    }
    return Ok("https://mock-storage.test/" + self.bucketName + "/" + key)
  }
  func exists(

    key: in String,
  ): Result[Bool, Storage.StorageError] {
    if not Storage.isSafeKey(key) {
      return Err(mockInvalidKey(key))
    }
    val found: Option[StoredObject] = mapGet(self.objects, key)
    return Ok(isSome(found))
  }
}

func mockInvalidKey(key: in String): Storage.StorageError {
  Storage.StorageError(message = "invalid storage key: " + key, code = "INVALID_KEY")
}

// ─── MockMessageQueue ─────────────────────────────────────────────────────────
/// Mock message queue that captures published messages in memory for assertion.
@stable(since = "0.1")
pub ref record MockMessageQueue {
  var published: List[PublishedMessage]
  queueName: String
  var msgCount: Int
}

impl Mq.MessageQueue for MockMessageQueue {
  func publish(message: in Mq.Message): Result[Unit, String]
    requires: message.id.length > 0
  {
    val captured = PublishedMessage(body = message.body, headers = toTestHeaders(message.headers))
    self.published.add(captured)
    self.msgCount = self.msgCount + 1
    return Ok(())
  }
  func publishBatch(

    messages: in slice[Mq.Message],
  ): Result[Unit, String]
    requires: messages.length > 0
  {
    for msg in messages {
      val captured = PublishedMessage(body = msg.body, headers = toTestHeaders(msg.headers))
      self.published.add(captured)
      self.msgCount = self.msgCount + 1
    }
    return Ok(())
  }
}

func toTestHeaders(headers: in slice[Mq.MessageHeader]): slice[TestMessageHeader] {
  val resultAcc: List[TestMessageHeader] = newList()
  for h in headers {
    resultAcc.add(TestMessageHeader(key = h.key, value = h.value))
  }
  return resultAcc.toArray()
}

/// Return the most recently published message, or None if none have been published.
@stable(since = "0.1")
pub func lastPublished(queue: in MockMessageQueue): Option[PublishedMessage] {
  if queue.msgCount == 0 {
    return None
  }
  return Some(value = queue.published[queue.msgCount - 1])
}

/// Return the number of messages published through this mock queue.
@stable(since = "0.1")
pub func publishedCount(queue: in MockMessageQueue): Int {
  return queue.msgCount
}

// ─── MockSessionStore ─────────────────────────────────────────────────────────
/// Mock session store backed by an in-process Map.
///
/// Stores session entries directly in a Map[String, Map[String, String]] to
/// avoid field access on Session.SessionData across package boundaries (the
/// bootstrap emitter's typeIdToClr cannot resolve path-dep record types and
/// falls back to Object, causing E5/E7 on any field read).
/// save() and touch() are no-ops; mock state is managed through set/delete/clear.
@stable(since = "0.1")
pub ref record MockSessionStore {
  var entries: Map[String, Map[String, String]]
  var sessionSeq: Int
}

impl Session.SessionStore for MockSessionStore {
  func create(): Result[String, Session.SessionError] {
    self.sessionSeq = self.sessionSeq + 1
    val id = "test-session-" + self.sessionSeq.toString()
    self.entries[id] = newMap()
    return Ok(id)
  }
  func load(

    sessionId: in String,
  ): Result[Option[Session.SessionData], Session.SessionError] {
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if not isSome(found) {
      return Ok(None)
    }
    val entryMap = unwrapOr(found, newMap())
    return Ok(
      Some(
        value = Session.SessionData(
          id = sessionId,
          entries = entryMap,
          createdAt = 0i64,
          lastAccessedAt = 0i64,
          expiresAt = 0i64
        )
      )
    )
  }
  func save(

    data: in Session.SessionData,
  ): Result[Unit, Session.SessionError] {
    // no-op: mock state is managed through set/delete/clear on the entries map.
    return Ok(())
  }
  func destroy(

    sessionId: in String,
  ): Result[Unit, Session.SessionError] {
    self.entries.remove(sessionId)
    return Ok(())
  }
  func touch(

    sessionId: in String,
  ): Result[Unit, Session.SessionError] {
    // no-op: mock doesn't track TTL.
    return Ok(())
  }
  func get(

    sessionId: in String,
    key: in String,
  ): Result[Option[String], Session.SessionError] {
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if not isSome(found) {
      return Ok(None)
    }
    val entryMap = unwrapOr(found, newMap())
    return Ok(mapGet(entryMap, key))
  }
  func set(

    sessionId: in String,
    key: in String,
    value: in String,
  ): Result[Unit, Session.SessionError] {
    // SECURITY: mirror NativeSessionStore / InProcessSessionStore —
    // refuse to auto-create a session for a caller-supplied id.  See
    // lyric-lang #316 / #436.  Diverging here means tests written
    // against this mock would silently miss a regression of the
    // session-fixation fix.
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if not isSome(found) {
      return Err(
        Session.SessionError(
          message = "session not found; call create() to obtain a fresh id before set()",
          code = "SESSION_NOT_FOUND"
        )
      )
    }
    val entryMap = unwrapOr(found, newMap())
    entryMap[key] = value
    self.entries[sessionId] = entryMap
    return Ok(())
  }
  func delete(

    sessionId: in String,
    key: in String,
  ): Result[Unit, Session.SessionError] {
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if isSome(found) {
      val entryMap = unwrapOr(found, newMap())
      entryMap.remove(key)
      self.entries[sessionId] = entryMap
    }
    return Ok(())
  }
  func clear(

    sessionId: in String,
  ): Result[Unit, Session.SessionError] {
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if isSome(found) {
      self.entries[sessionId] = newMap()
    }
    return Ok(())
  }
}

// ─── MockFlagStore ────────────────────────────────────────────────────────────
/// Mock feature flag store backed by an in-process Map.
///
/// Bool flags are registered with `enable` / `disable`.  The `getValue` method
/// returns FlagBool entries only; for other value types, use `Flags.fromEntries`
/// with a pre-built InProcessFlagStore.
@stable(since = "0.1")
pub ref record MockFlagStore {
  var flags: Map[String, Bool]
}

impl Flags.FlagStore for MockFlagStore {
  func isEnabled(name: in String): Bool {
    return unwrapOr(mapGet(self.flags, name), false)
  }
  func getValue(

    name: in String,
  ): Option[Flags.FlagValue] {
    val found: Option[Bool] = mapGet(self.flags, name)
    match found {
      case None -> return None
      case Some(b) -> return Some(value = Flags.FlagBool(value = b))
    }
  }
  func listFlags(): slice[Flags.FlagEntry] {

    return []
  }
  func refresh(): Result[Unit, Flags.FlagError] {

    return Ok(())
  }
}

/// Enable the named flag in the mock store.
@stable(since = "0.1")
pub func enable(store: in MockFlagStore, name: in String): Unit
  requires: name.length > 0
{
  store.flags[name] = true
}

/// Disable the named flag in the mock store.
@stable(since = "0.1")
pub func disable(store: in MockFlagStore, name: in String): Unit
  requires: name.length > 0
{
  store.flags[name] = false
}

// ─── MockCacheStore ───────────────────────────────────────────────────────────
/// Mock cache store backed by an in-process Map.
///
/// All cache operations succeed by default.  TTL values are accepted but not
/// enforced; the mock store never expires entries.
@stable(since = "0.1")
pub ref record MockCacheStore {
  var entries: Map[String, String]
}

impl Cache.CacheStore for MockCacheStore {
  func get(key: in String): Option[String] {
    return mapGet(self.entries, key)
  }
  func set(key: in String, value: in String, ttlSeconds: in Int): Unit
    requires: ttlSeconds >= 0
  {
    self.entries[key] = value
  }
  func delete(key: in String): Unit {
    val _ = self.entries.remove(key)
  }
  func clear(): Unit {
    self.entries = newMap()
  }
}

/// Return the number of entries currently held in the mock cache.
@stable(since = "0.1")
pub func cacheSize(store: in MockCacheStore): Int {
  return store.entries.count
}

// ─── MockDbTransaction / MockDbConnection ─────────────────────────────────────
/// Mock in-flight database transaction returned by `MockDbConnection.transaction()`.
///
/// `query`/`execute` return empty/zero results by default; `commit`/`rollback`
/// record which one was called via `committed`/`rolledBack` — the mock has no
/// persisted rows to actually roll back. See docs/57 §5.3 / issue #5133: this
/// mock exists specifically to exercise `DbConnection.transaction()` returning
/// an interface-typed (`DbTransaction`) value through a `Result`, with a
/// further interface method dispatched on the unwrapped value — the shape
/// #5133's "narrow" bug (fixed) originally broke.
@stable(since = "0.1")
pub ref record MockDbTransaction {
  var committed: Bool
  var rolledBack: Bool
  var queryCount: Int
  var executeCount: Int
}

impl Db.DbTransaction for MockDbTransaction {
  func query(sql: in Db.SqlText, params: in slice[String]): Result[slice[Db.DbRow], Db.DbError] {
    self.queryCount = self.queryCount + 1
    return Ok([])
  }
  func execute(sql: in Db.SqlText, params: in slice[String]): Result[Int, Db.DbError] {
    self.executeCount = self.executeCount + 1
    return Ok(0)
  }
  func isActive(): Bool {
    return not self.committed and not self.rolledBack
  }
  func commit(): Result[Unit, Db.DbError] {
    self.committed = true
    return Ok(())
  }
  func rollback(): Result[Unit, Db.DbError] {
    self.rolledBack = true
    return Ok(())
  }
}

/// Mock database connection that hands acc `MockDbTransaction` values from
/// `transaction()`.  `query`/`execute` succeed with empty/zero results by
/// default; use `queryCount`/`executeCount`/`txCount` to verify call counts.
@stable(since = "0.1")
pub ref record MockDbConnection {
  var queryCount: Int
  var executeCount: Int
  var txCount: Int
  var closed: Bool
}

impl Db.DbConnection for MockDbConnection {
  func query(sql: in Db.SqlText, params: in slice[String]): Result[slice[Db.DbRow], Db.DbError] {
    self.queryCount = self.queryCount + 1
    return Ok([])
  }
  func execute(sql: in Db.SqlText, params: in slice[String]): Result[Int, Db.DbError] {
    self.executeCount = self.executeCount + 1
    return Ok(0)
  }
  func transaction(): Result[Db.DbTransaction, Db.DbError] {
    self.txCount = self.txCount + 1
    val tx: Db.DbTransaction = MockDbTransaction(committed = false, rolledBack = false, queryCount = 0, executeCount = 0)
    return Ok(tx)
  }
  func close(): Unit {
    self.closed = true
  }
}

/// Return the number of transactions begun on this mock connection.
@stable(since = "0.1")
pub func txCount(conn: in MockDbConnection): Int {
  return conn.txCount
}

// ─── MockJobScheduler ─────────────────────────────────────────────────────────
/// Mock job scheduler that records every submitted job and lets a test drive
/// its outcome.
///
/// `enqueue`/`schedule` store a `Jobs.JobSpec` and report `Pending`; a test
/// then calls `completeJob` or `failJob` to put the job in the state the code
/// under test should react to.  Nothing runs a handler (use
/// `Jobs.inProcess()` with `Jobs.runNext` to execute handlers in a test).
/// Cron expressions are validated like every real backend (`Jobs.parseCron`).
@stable(since = "0.1")
pub ref record MockJobScheduler {
  var specs: List[Jobs.JobSpec]
  var results: Map[String, Jobs.JobResult]
  var counter: Int
}

impl Jobs.JobScheduler for MockJobScheduler {
  func enqueue(name: in String, payload: in String, maxAttempts: in Int, timeoutMs: in Int): Result[String, String]
    requires: name.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    self.counter = self.counter + 1
    return Ok(mockRecordJob(self, "mock-job-" + self.counter.toString(), name, payload, maxAttempts, timeoutMs))
  }
  func schedule(
    name: in String, payload: in String, cronExpr: in String, maxAttempts: in Int, timeoutMs: in Int
  ): Result[String, String]
    requires: name.length > 0
    requires: cronExpr.length > 0
    requires: maxAttempts >= 1
    requires: timeoutMs >= 1
  {
    match Jobs.parseCron(cronExpr) {
      case Err(e) -> return Err(e)
      case Ok(_) -> {
        self.counter = self.counter + 1
        return Ok(mockRecordJob(self, "mock-cron-" + self.counter.toString(), name, payload, maxAttempts, timeoutMs))
      }
    }
  }
  func cancel(jobId: in String): Result[Unit, String]
    requires: jobId.length > 0
  {
    val found: Option[Jobs.JobResult] = mapGet(self.results, jobId)
    if isSome(found) {
      val current = unwrapOr(found, mockJobResult(jobId, Jobs.JobStatus.Pending, "", ""))
      match current.status {
        case Jobs.JobStatus.Pending -> {
          self.results[jobId] = mockJobResult(jobId, Jobs.JobStatus.Cancelled, "", "cancelled")
        }
        case Jobs.JobStatus.Running -> {
          self.results[jobId] = mockJobResult(jobId, Jobs.JobStatus.Cancelled, "", "cancelled")
        }
        case _ -> ()
      }
    }
    return Ok(())
  }
  func status(jobId: in String): Result[Jobs.JobStatus, String]
    requires: jobId.length > 0
  {
    val found: Option[Jobs.JobResult] = mapGet(self.results, jobId)
    if not isSome(found) {
      return Err("job not found: " + jobId)
    }
    val current = unwrapOr(found, mockJobResult(jobId, Jobs.JobStatus.Pending, "", ""))
    return Ok(current.status)
  }
  func results(jobId: in String): Result[Jobs.JobResultList, String]
    requires: jobId.length > 0
  {
    val found: Option[Jobs.JobResult] = mapGet(self.results, jobId)
    if not isSome(found) {
      return Err("job not found: " + jobId)
    }
    return Ok(Jobs.JobResultList(items = [unwrapOr(found, mockJobResult(jobId, Jobs.JobStatus.Pending, "", ""))]))
  }
}

func mockJobResult(jobId: in String, status: in Jobs.JobStatus, output: in String, error: in String): Jobs.JobResult {
  return Jobs.JobResult(
    jobId = jobId,
    status = status,
    output = output,
    error = error,
    startedAt = 0i64,
    finishedAt = 0i64
  )
}

func mockRecordJob(
  s: in MockJobScheduler,
  id: in String,
  name: in String,
  payload: in String,
  maxAttempts: in Int,
  timeoutMs: in Int,
): String {
  s.specs.add(
    Jobs.JobSpec(
      id = id,
      name = name,
      payload = payload,
      maxAttempts = maxAttempts,
      timeoutMs = timeoutMs,
      scheduledAt = 0i64
    )
  )
  s.results[id] = mockJobResult(id, Jobs.JobStatus.Pending, "", "")
  return id
}

/// Mark the job as having succeeded with `output`.
@stable(since = "0.1")
pub func completeJob(scheduler: in MockJobScheduler, jobId: in String, output: in String): Unit
  requires: jobId.length > 0
{
  scheduler.results[jobId] = mockJobResult(jobId, Jobs.JobStatus.Succeeded, output, "")
}

/// Mark the job as having failed with `error`.
@stable(since = "0.1")
pub func failJob(scheduler: in MockJobScheduler, jobId: in String, error: in String): Unit
  requires: jobId.length > 0
{
  scheduler.results[jobId] = mockJobResult(jobId, Jobs.JobStatus.Failed, "", error)
}

/// The number of jobs submitted to the mock (enqueued or scheduled).
@stable(since = "0.1")
pub func submittedCount(scheduler: in MockJobScheduler): Int {
  return scheduler.specs.count
}

/// The most recently submitted job, or None if there is none.
@stable(since = "0.1")
pub func lastSubmitted(scheduler: in MockJobScheduler): Option[Jobs.JobSpec] {
  if scheduler.specs.count == 0 {
    return None
  }
  return Some(value = scheduler.specs[scheduler.specs.count - 1])
}

// ─── MockQueueConsumer ────────────────────────────────────────────────────────
/// Mock queue consumer that delivers a scripted list of messages and records
/// how the code under test settled each one.
///
/// Load messages with `deliver`; each `consume` hands the next one to the
/// handler (an empty script answers `Err("timeout")`, like a real empty
/// queue).  `ackedIds` / `nackedIds` list the settlements in call order.
@stable(since = "0.1")
pub ref record MockQueueConsumer {
  var pending: List[Mq.Message]
  var acked: List[String]
  var nacked: List[String]
  var requeued: List[String]
  var closed: Bool
}

impl Mq.QueueConsumer for MockQueueConsumer {
  func consume(timeoutMs: in Int, handler: (Mq.Message) -> Result[Unit, String]): Result[Unit, String]
    requires: timeoutMs >= 0
  {
    if self.pending.count == 0 {
      return Err("timeout")
    }
    val next = self.pending[0]
    self.pending.removeAt(0)
    return handler(next)
  }
  func ack(messageId: in String): Result[Unit, String] {
    if messageId.length == 0 {
      return Err("lyric-mq: empty message id")
    }
    self.acked.add(messageId)
    return Ok(())
  }
  func nack(messageId: in String, requeue: in Bool): Result[Unit, String] {
    if messageId.length == 0 {
      return Err("lyric-mq: empty message id")
    }
    self.nacked.add(messageId)
    if requeue {
      self.requeued.add(messageId)
    }
    return Ok(())
  }
  func close(): Unit {
    self.closed = true
  }
}

/// Create an empty `MockQueueConsumer`.
@stable(since = "0.1")
pub func newMockQueueConsumer(): MockQueueConsumer {
  return MockQueueConsumer(
    pending = newList(),
    acked = newList(),
    nacked = newList(),
    requeued = newList(),
    closed = false
  )
}

/// Add `message` to the script the consumer will deliver.
@stable(since = "0.1")
pub func deliver(consumer: in MockQueueConsumer, message: in Mq.Message): Unit
  requires: message.id.length > 0
{
  consumer.pending.add(message)
}

/// The ids passed to `ack`, in call order.
@stable(since = "0.1")
pub func ackedIds(consumer: in MockQueueConsumer): slice[String] {
  return consumer.acked.toArray()
}

/// The ids passed to `nack`, in call order.
@stable(since = "0.1")
pub func nackedIds(consumer: in MockQueueConsumer): slice[String] {
  return consumer.nacked.toArray()
}

// ─── MockSearchClient ─────────────────────────────────────────────────────────
/// In-memory `Search.SearchClient` for tests of code that searches.
///
/// It keeps documents per index in insertion order and implements the query
/// model faithfully enough to stand in for an engine: whole-word,
/// case-insensitive text matching (every query word must match some field),
/// `eq`/`contains`/`gt`/`gte`/`lt`/`lte` filters, one-field sorting, `from`/
/// `size` paging with an exact `total`, prefix suggestions, and the same
/// request validation as the real clients (`Search.validateSearchQuery`,
/// `INVALID_PATH_SEGMENT`).  It runs the `Testing.Conformance.Search` suite
/// itself, so it behaves as that contract says.
@stable(since = "0.1")
pub ref record MockSearchClient {
  var docs: Map[String, Search.SearchDocument]
  var order: List[String]
  var versions: Map[String, Long]
  var indexNames: List[String]
  var requests: Int
}

/// Create an empty mock search client.
@stable(since = "0.1")
pub func newMockSearchClient(): MockSearchClient {
  return MockSearchClient(docs = newMap(), order = newList(), versions = newMap(), indexNames = newList(), requests = 0)
}

/// The number of requests the mock has served.
@stable(since = "0.1")
pub func searchRequestCount(client: in MockSearchClient): Int {
  return client.requests
}

func mockSearchKey(index: in String, id: in String): String {
  return index + "\u{0000}" + id
}

func mockSearchError(code: in String, message: in String): Search.SearchError {
  return Search.SearchError(message = message, code = code, statusCode = 0)
}

func mockBadSegment(value: in String): Bool {
  return value == "" or value == "." or value == ".."
}

func mockSegmentError(what: in String, value: in String): Search.SearchError {
  return mockSearchError("INVALID_PATH_SEGMENT", "invalid " + what + " '" + value + "'")
}

// Lowercased alphanumeric words of `s`.
func mockWords(s: in String): slice[String] {
  val acc: List[String] = newList()
  var current = ""
  var i = 0
  while i < s.length {
    val ch = s.substring(i, 1)
    val lower = Str.toLower(ch)
    val isWordChar = (lower >= "a" and lower <= "z") or (lower >= "0" and lower <= "9") or lower.length > 1 or
      Str.charAtOrReplacement(lower, 0) > '\u{007f}'
    if isWordChar {
      current = current + lower
    } else if current.length > 0 {
      acc.add(current)
      current = ""
    }
    i = i + 1
  }
  if current.length > 0 {
    acc.add(current)
  }
  return acc.toArray()
}

func mockDocHasWord(d: in Search.SearchDocument, word: in String): Bool {
  for name in mockFieldNames(d) {
    for w in mockWords(d.fields[name]) {
      if w == word {
        return true
      }
    }
  }
  return false
}

func mockFieldNames(d: in Search.SearchDocument): slice[String] {
  return mapKeys(d.fields).toArray()
}

func mockTextMatches(d: in Search.SearchDocument, text: in String): Bool {
  for word in mockWords(text) {
    if not mockDocHasWord(d, word) {
      return false
    }
  }
  return true
}

// Compare numerically when both sides parse as numbers, else as text.
func mockCompare(a: in String, b: in String): Int {
  match parseOptDouble(a) {
    case Some(x) -> {
      match parseOptDouble(b) {
        case Some(y) -> return if x < y { -1 } else if x > y { 1 } else { 0 }
        case None -> ()
      }
    }
    case None -> ()
  }
  return Str.compare(a, b)
}

func mockFilterMatches(d: in Search.SearchDocument, f: in Search.SearchFilter): Bool {
  if not d.fields.containsKey(f.field) {
    return false
  }
  val actual = d.fields[f.field]
  if f.operator == "eq" {
    return actual == f.value
  }
  if f.operator == "contains" {
    return Str.contains(Str.toLower(actual), Str.toLower(f.value))
  }
  val cmp = mockCompare(actual, f.value)
  if f.operator == "gt" {
    return cmp > 0
  }
  if f.operator == "gte" {
    return cmp >= 0
  }
  if f.operator == "lt" {
    return cmp < 0
  }
  return cmp <= 0
}

func mockSortValue(d: in Search.SearchDocument, field: in String): String {
  if d.fields.containsKey(field) {
    return d.fields[field]
  }
  return ""
}

impl Search.SearchClient for MockSearchClient {
  async func index(doc: in Search.SearchDocument): Result[Search.IndexResult, Search.SearchError]
    requires: doc.index.length > 0
  {
    self.requests = self.requests + 1
    if mockBadSegment(doc.index) {
      return Err(mockSegmentError("index name", doc.index))
    }
    if mockBadSegment(doc.id) {
      return Err(mockSegmentError("document id", doc.id))
    }
    return Ok(mockStore(self, doc))
  }

  async func indexBatch(docs: in slice[Search.SearchDocument]): Result[slice[Search.IndexResult], Search.SearchError] {
    self.requests = self.requests + 1
    val acc: List[Search.IndexResult] = newList()
    for d in docs {
      if d.index.length == 0 or mockBadSegment(d.index) {
        return Err(mockSegmentError("index name", d.index))
      }
      if mockBadSegment(d.id) {
        return Err(mockSegmentError("document id", d.id))
      }
      acc.add(mockStore(self, d))
    }
    return Ok(acc.toArray())
  }

  async func search(query: in Search.SearchQuery): Result[Search.SearchResult, Search.SearchError]
    requires: query.index.length > 0
  {
    self.requests = self.requests + 1
    if mockBadSegment(query.index) {
      return Err(mockSegmentError("index name", query.index))
    }
    match Search.validateSearchQuery(query) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    val matched: List[Search.SearchDocument] = newList()
    for key in self.order.toArray() {
      val d = self.docs[key]
      if d.index == query.index and mockTextMatches(d, query.query) {
        var keep = true
        for f in query.filters {
          if not mockFilterMatches(d, f) {
            keep = false
          }
        }
        if keep {
          matched.add(d)
        }
      }
    }
    if query.sort.length > 0 {
      val s = query.sort[0]
      var i = 1
      while i < matched.count {
        var j = i
        while j > 0 and mockSortOrdered(matched[j - 1], matched[j], s) {
          val t = matched[j]
          matched[j] = matched[j - 1]
          matched[j - 1] = t
          j = j - 1
        }
        i = i + 1
      }
    }
    val hits: List[Search.SearchHit] = newList()
    var n = query.from
    while n < matched.count and hits.count < query.size {
      val d = matched[n]
      hits.add(Search.SearchHit(id = d.id, index = d.index, score = 1.0, highlights = [], source = d.fields))
      n = n + 1
    }
    return Ok(Search.SearchResult(total = matched.count.toLong(), hits = hits.toArray(), tookMs = 0, scrollId = None))
  }

  async func suggest(
    index: in String, text: in String, field: in String, size: in Int
  ): Result[Search.SuggestResult, Search.SearchError]
    requires: index.length > 0
    requires: field.length > 0
  {
    self.requests = self.requests + 1
    match Search.validateSuggestSize(size) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    val prefix = Str.toLower(text)
    val acc: List[String] = newList()
    for key in self.order.toArray() {
      val d = self.docs[key]
      if d.index == index and d.fields.containsKey(field) {
        val value = d.fields[field]
        if Str.startsWith(Str.toLower(value), prefix) and acc.count < size and not mockListHas(acc, value) {
          acc.add(value)
        }
      }
    }
    return Ok(Search.SuggestResult(suggestions = acc.toArray(), tookMs = 0))
  }

  async func delete(index: in String, id: in String): Result[Unit, Search.SearchError]
    requires: index.length > 0
  {
    self.requests = self.requests + 1
    if mockBadSegment(index) {
      return Err(mockSegmentError("index name", index))
    }
    if mockBadSegment(id) {
      return Err(mockSegmentError("document id", id))
    }
    mockRemove(self, mockSearchKey(index, id))
    return Ok(())
  }

  async func deleteIndex(index: in String): Result[Unit, Search.SearchError]
    requires: index.length > 0
  {
    self.requests = self.requests + 1
    if mockBadSegment(index) {
      return Err(mockSegmentError("index name", index))
    }
    for key in self.order.toArray() {
      if self.docs[key].index == index {
        mockRemove(self, key)
      }
    }
    val kept: List[String] = newList()
    for n in self.indexNames.toArray() {
      if n != index {
        kept.add(n)
      }
    }
    self.indexNames = kept
    return Ok(())
  }

  async func exists(index: in String, id: in String): Result[Bool, Search.SearchError]
    requires: index.length > 0
  {
    self.requests = self.requests + 1
    if mockBadSegment(index) {
      return Err(mockSegmentError("index name", index))
    }
    if mockBadSegment(id) {
      return Err(mockSegmentError("document id", id))
    }
    return Ok(self.docs.containsKey(mockSearchKey(index, id)))
  }

  async func createIndex(index: in String, mappingJson: in String): Result[Unit, Search.SearchError]
    requires: index.length > 0
  {
    self.requests = self.requests + 1
    if mockBadSegment(index) {
      return Err(mockSegmentError("index name", index))
    }
    mockNoteIndex(self, index)
    return Ok(())
  }
}

func mockListHas(items: in List[String], value: in String): Bool {
  for it in items.toArray() {
    if it == value {
      return true
    }
  }
  return false
}

func mockNoteIndex(c: in MockSearchClient, index: in String): Unit {
  if not mockListHas(c.indexNames, index) {
    c.indexNames.add(index)
  }
}

func mockStore(c: in MockSearchClient, doc: in Search.SearchDocument): Search.IndexResult {
  mockNoteIndex(c, doc.index)
  val key = mockSearchKey(doc.index, doc.id)
  val existed = c.docs.containsKey(key)
  val version = if existed { c.versions[key] + 1i64 } else { 1i64 }
  if not existed {
    c.order.add(key)
  }
  c.docs[key] = doc
  c.versions[key] = version
  return Search.IndexResult(id = doc.id, version = version, status = if existed { "updated" } else { "created" })
}

func mockRemove(c: in MockSearchClient, key: in String): Unit {
  if c.docs.containsKey(key) {
    c.docs.remove(key)
    c.versions.remove(key)
    val kept: List[String] = newList()
    for k in c.order.toArray() {
      if k != key {
        kept.add(k)
      }
    }
    c.order = kept
  }
}

// True when `a` must come after `b` under sort `s` (so the pair is swapped).
func mockSortOrdered(a: in Search.SearchDocument, b: in Search.SearchDocument, s: in Search.SortField): Bool {
  val cmp = mockCompare(mockSortValue(a, s.field), mockSortValue(b, s.field))
  if s.descending {
    return cmp < 0
  }
  return cmp > 0
}

// ─── MockTranslationStore ─────────────────────────────────────────────────────
/// Translation store for tests of code that localises text.
///
/// Translations are registered with `addTranslation`.  A key with no
/// registered translation comes back as `[<locale>:<key>]` rather than the bare
/// key, so a test can tell a missing translation from a real one, and every
/// requested key is recorded for `requestedKeys`.
@stable(since = "0.1")
pub ref record MockTranslationStore {
  var translations: Map[String, String]
  var localeKeys: List[String]
  var requested: List[String]
}

/// Create an empty `MockTranslationStore`.
@stable(since = "0.1")
pub func newMockTranslationStore(): MockTranslationStore {
  return MockTranslationStore(translations = newMap(), localeKeys = newList(), requested = newList())
}

/// Register `text` as the translation of `key` in `locale`.
@stable(since = "0.1")
pub func addTranslation(store: in MockTranslationStore, locale: in I18n.Locale, key: in String, text: in String): Unit
  requires: key.length > 0
{
  val lk = I18n.localeKey(locale)
  store.translations[lk + "|" + key] = text
  if not mockListHas(store.localeKeys, lk) {
    store.localeKeys.add(lk)
  }
}

/// Every key passed to `translate` / `translateWith`, in call order.
@stable(since = "0.1")
pub func requestedKeys(store: in MockTranslationStore): slice[String] {
  return store.requested.toArray()
}

func mockTranslate(store: in MockTranslationStore, key: in String, locale: in I18n.Locale): String {
  store.requested.add(key)
  val lk = I18n.localeKey(locale)
  val full = lk + "|" + key
  if store.translations.containsKey(full) {
    return store.translations[full]
  }
  return "[" + lk + ":" + key + "]"
}

impl I18n.TranslationStore for MockTranslationStore {
  func translate(key: in String, locale: in I18n.Locale): String
    requires: key.length > 0
  {
    return mockTranslate(self, key, locale)
  }
  func translateWith(key: in String, locale: in I18n.Locale, vars: in Map[String, String]): String
    requires: key.length > 0
  {
    var text = mockTranslate(self, key, locale)
    for name in mapKeys(vars).toArray() {
      text = Str.replace(text, "{" + name + "}", vars[name])
    }
    return text
  }
  func availableLocales(): slice[I18n.Locale] {
    val acc: List[I18n.Locale] = newList()
    for lk in self.localeKeys.toArray() {
      match I18n.parseLocale(lk) {
        case Some(l) -> acc.add(l)
        case None -> ()
      }
    }
    return acc.toArray()
  }
  func hasKey(key: in String, locale: in I18n.Locale): Bool
    requires: key.length > 0
  {
    return self.translations.containsKey(I18n.localeKey(locale) + "|" + key)
  }
}

// ─── TestContext ──────────────────────────────────────────────────────────────
/// A bundle of mock service implementations for use in unit tests.
///
/// Create one with `newTestContext()`.  Pass individual fields to functions
/// under test instead of real infrastructure clients.
@stable(since = "0.1")
pub record TestContext {
  cache: MockCacheStore
  mail: MockMailSender
  storage: MockStorageBucket
  queue: MockMessageQueue
  session: MockSessionStore
  flags: MockFlagStore
  db: MockDbConnection
  jobs: MockJobScheduler
  search: MockSearchClient
  translations: MockTranslationStore
  clock: TestClock
}

/// Create a TestContext with all mocks initialised to sensible defaults.
@stable(since = "0.1")
pub func newTestContext(): TestContext {
  return TestContext(
    cache = MockCacheStore(entries = newMap()),
    mail = MockMailSender(sentEmails = newList(), count = 0),
    storage = MockStorageBucket(
      objects = newMap(),
      orderedKeys = newList(),
      bucketName = "test-bucket",
      callCount = 0
    ),
    queue = MockMessageQueue(published = newList(), queueName = "test-queue", msgCount = 0),
    session = MockSessionStore(entries = newMap(), sessionSeq = 0),
    flags = MockFlagStore(flags = newMap()),
    db = MockDbConnection(queryCount = 0, executeCount = 0, txCount = 0, closed = false),
    jobs = MockJobScheduler(specs = newList(), results = newMap(), counter = 0),
    search = newMockSearchClient(),
    translations = newMockTranslationStore(),
    clock = TestClock(currentEpochMs = 0i64)
  )
}

// ─── Assertion helpers ────────────────────────────────────────────────────────
/// Assert that `result` is Ok.  Panics with `msg` if it is Err.
///
/// Note: the error type is constrained to String because Lyric does not yet
/// expose a top `Any` type.  For other error types, convert to String first.
@stable(since = "0.1")
pub func assertOk[T](result: in Result[T, String], msg: in String): Unit {
  match result {
    case Err(e) -> panic(msg + " (got Err: " + e + ")")
    case Ok(_) -> ()
  }
}

/// Assert that `result` is Err.  Panics with `msg` if it is Ok.
/// Returns the error value when the assertion passes.
@stable(since = "0.1")
pub func assertErr[T](result: in Result[T, String], msg: in String): String {
  match result {
    case Ok(_) -> {
      panic(msg + " (expected Err, got Ok)")
      return ""
    }
    case Err(e) -> return e
  }
}

/// Assert that `opt` is Some.  Panics with `msg` if it is None.
/// Returns the contained value when the assertion passes.
@stable(since = "0.1")
pub func assertSome[T](opt: in Option[T], msg: in String): T {
  if not isSome(opt) {
    panic(msg + " (expected Some, got None)")
  }
  return unwrapOr(opt, default())
}

/// Assert that `opt` is None.  Panics with `msg` if it is Some.
@stable(since = "0.1")
pub func assertNone[T](opt: in Option[T], msg: in String): Unit {
  if isSome(opt) {
    panic(msg + " (expected None, got Some)")
  }
}

/// Assert that two strings are equal.  Panics with a message showing both
/// values when they differ.
@stable(since = "0.1")
pub func assertEq(a: in String, b: in String, msg: in String): Unit {
  if a != b {
    panic(msg + " (expected \"" + a + "\", got \"" + b + "\")")
  }
}

/// Assert that `cond` is true.  Panics with `msg` if it is false.
@stable(since = "0.1")
pub func assertTrue(cond: in Bool, msg: in String): Unit {
  if not cond {
    panic(msg + " (expected true)")
  }
}

/// Assert that `cond` is false.  Panics with `msg` if it is true.
@stable(since = "0.1")
pub func assertFalse(cond: in Bool, msg: in String): Unit {
  if cond {
    panic(msg + " (expected false)")
  }
}
