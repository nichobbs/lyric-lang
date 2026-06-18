// Testing — mock implementations and test helpers for Lyric libraries.
// Stability: @experimental — the mock implementations and assertion helpers
// have tests, but the surface is intentionally rough and may grow new helpers
// ahead of `1.0`.
//
// WARNING (thread safety): All Mock implementations in this library are NOT
// thread-safe.  Use them only in single-threaded test contexts; do not
// share a mock instance across concurrent test workers.  See
// lyric-lang #411.
//
// WARNING (failure injection): The current mocks simulate only the happy path
// (success returns).  Tests that need to exercise error-handling paths
// must subclass the relevant interface manually.  Configurable
// failure-injection hooks are tracked as lyric-lang #410.
//
// Provides in-process mock implementations of Cache, Mail, Storage, Mq,
// Session, and Flags interfaces so that unit tests can exercise application
// logic without real infrastructure.  Also provides assertion helpers for
// writing concise, readable test cases.
//
// Usage:
//
//   import Testing
//   import Std.Core
//
//   val ctx = Testing.newTestContext()
//   Testing.enable(ctx.flags, "new-checkout")
//   Testing.assertOk(someFunction(ctx.mail, ctx.storage), "expected success")
//   Testing.assertEq(ctx.mail.sentCount().toString(), "1", "one email sent")
//
// See lyric-testing/README.md.

@runtime_checked
package Testing

import Std.Core
import Std.Collections
import Std.Iter
import Std.Time
import Cache as Cache
import Mail
import Storage
import Mq
import Session
import Flags

// ─── Test support types ───────────────────────────────────────────────────────

/// A captured outbound email as recorded by MockMailSender.
@stable(since="0.1")
pub record SentEmail {
  to:       String
  subject:  String
  textBody: String
  htmlBody: String
}

/// A stored object as recorded by MockStorageBucket.
@stable(since="0.1")
pub record StoredObject {
  key:         String
  dataBase64:  String
  contentType: String
}

/// A published message as recorded by MockMessageQueue.
@stable(since="0.1")
pub record PublishedMessage {
  body:    String
  headers: slice[Mq.MessageHeader]
}

// ─── TestClock ────────────────────────────────────────────────────────────────

/// A controllable clock for deterministic time-dependent tests.
///
/// Advance the clock with `advance(ms)` to simulate the passage of time
/// without waiting for real wall-clock time.
@stable(since="0.1")
pub record TestClock {
  var currentEpochMs: Long
}

/// Advance the test clock by `ms` milliseconds.
@stable(since="0.1")
pub func advance(clock: inout TestClock, ms: in Long): Unit
  requires: ms >= 0i64
{
  clock.currentEpochMs = clock.currentEpochMs + ms
}

/// Return the current epoch time in milliseconds from the test clock.
@stable(since="0.1")
pub func now(clock: in TestClock): Long {
  return clock.currentEpochMs
}

// ─── MockMailSender ───────────────────────────────────────────────────────────

/// Mock email sender that captures sent messages in memory for assertion.
///
/// Thread safety: not thread-safe in v1.
@stable(since="0.1")
pub record MockMailSender {
  var sentEmails: List[SentEmail]
  var count:      Int
}

impl Mail.MailSender for MockMailSender {
  func send(msg: in Mail.EmailMessage): Result[Unit, Mail.MailError] {
    val toAddr = if msg.to.length == 0 {
      ""
    } else {
      msg.to[0].address
    }
    val captured = SentEmail(
      to       = toAddr,
      subject  = msg.subject,
      textBody = msg.textBody,
      htmlBody = msg.htmlBody)
    self.sentEmails.add(captured)
    self.count = self.count + 1
    return Ok(())
  }

  func close(): Unit {
    // No-op for the mock sender.
  }
}

/// Return the most recently sent email, or None if none have been sent.
@stable(since="0.1")
pub func lastSent(sender: in MockMailSender): Option[SentEmail] {
  if sender.count == 0 {
    return None
  }
  return Some(value = sender.sentEmails[sender.count - 1])
}

/// Return the number of emails sent through this mock sender.
@stable(since="0.1")
pub func sentCount(sender: in MockMailSender): Int {
  return sender.count
}

/// Clear all captured emails from the mock sender.
@stable(since="0.1")
pub func clearSent(sender: inout MockMailSender): Unit {
  sender.sentEmails = newList()
  sender.count      = 0
}

// ─── MockStorageBucket ────────────────────────────────────────────────────────

/// Mock storage bucket that keeps objects in memory for assertion.
///
/// All operations succeed by default.  Use `callCount` to verify that
/// specific methods were invoked.
@stable(since="0.1")
pub record MockStorageBucket {
  var objects:   Map[String, StoredObject]
  bucketName:    String
  var callCount: Int
}

impl Storage.StorageBucket for MockStorageBucket {
  func put(
    key:         in String,
    dataBase64:  in String,
    contentType: in String,
    userMeta:    in Map[String, String]
  ): Result[Storage.StorageMetadata, Storage.StorageError] {
    val obj = StoredObject(
      key         = key,
      dataBase64  = dataBase64,
      contentType = contentType)
    self.objects[key] = obj
    self.callCount = self.callCount + 1
    val meta = Storage.StorageMetadata(
      contentType   = contentType,
      contentLength = 0,
      etag          = "mock-etag",
      lastModified  = "",
      userMeta      = userMeta)
    return Ok(meta)
  }

  func get(key: in String): Result[Storage.StorageObject, Storage.StorageError] {
    val found = mapGet(self.objects, key)
    if not isSome(found) {
      return Err(Storage.StorageError(
        message = "not found: " + key,
        code    = "NOT_FOUND"))
    }
    val obj = unwrapOr(found, StoredObject(key = "", dataBase64 = "", contentType = ""))
    val meta = Storage.StorageMetadata(
      contentType   = obj.contentType,
      contentLength = 0,
      etag          = "mock-etag",
      lastModified  = "",
      userMeta      = newMap())
    val result = Storage.StorageObject(
      bucket     = self.bucketName,
      key        = key,
      metadata   = meta,
      dataBase64 = obj.dataBase64)
    return Ok(result)
  }

  func delete(key: in String): Result[Unit, Storage.StorageError] {
    self.objects.remove(key)
    return Ok(())
  }

  func list(
    prefix:            in String,
    continuationToken: in String,
    maxKeys:           in Int
  ): Result[Storage.ListResult, Storage.StorageError] {
    var entries: slice[Storage.ListEntry] = []
    for k in self.objects {
      val obj = self.objects[k]
      val matches = if prefix.length == 0 {
        true
      } else if k.length >= prefix.length {
        k.substring(0, prefix.length) == prefix
      } else {
        false
      }
      if matches {
        val listItem = Storage.ListEntry(
          key           = k,
          contentLength = 0,
          lastModified  = "",
          etag          = "mock-etag")
        entries = concat(entries, [listItem])
      }
    }
    val result = Storage.ListResult(
      entries               = entries,
      nextContinuationToken = None,
      isTruncated           = false)
    return Ok(result)
  }

  func presignedUrl(
    key:              in String,
    expiresInSeconds: in Int
  ): Result[String, Storage.StorageError] {
    return Ok("https://mock-storage.test/" + self.bucketName + "/" + key)
  }

  func exists(key: in String): Result[Bool, Storage.StorageError] {
    return Ok(isSome(mapGet(self.objects, key)))
  }
}

// ─── MockMessageQueue ─────────────────────────────────────────────────────────

/// Mock message queue that captures published messages in memory for assertion.
@stable(since="0.1")
pub record MockMessageQueue {
  var published: List[PublishedMessage]
  queueName:     String
  var msgCount:  Int
}

impl Mq.MessageQueue for MockMessageQueue {
  func publish(message: in Mq.Message): Result[Unit, String]
    requires: message.id.length > 0
  {
    val captured = PublishedMessage(
      body    = message.body,
      headers = message.headers)
    self.published.add(captured)
    self.msgCount = self.msgCount + 1
    return Ok(())
  }

  func publishBatch(messages: in slice[Mq.Message]): Result[Unit, String]
    requires: messages.length > 0
  {
    for msg in messages {
      val captured = PublishedMessage(
        body    = msg.body,
        headers = msg.headers)
      self.published.add(captured)
      self.msgCount = self.msgCount + 1
    }
    return Ok(())
  }
}

/// Return the most recently published message, or None if none have been published.
@stable(since="0.1")
pub func lastPublished(queue: in MockMessageQueue): Option[PublishedMessage] {
  if queue.msgCount == 0 {
    return None
  }
  return Some(value = queue.published[queue.msgCount - 1])
}

/// Return the number of messages published through this mock queue.
@stable(since="0.1")
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
@stable(since="0.1")
pub record MockSessionStore {
  var entries:    Map[String, Map[String, String]]
  var sessionSeq: Int
}

impl Session.SessionStore for MockSessionStore {
  func create(): Result[Session.SessionId, Session.SessionError] {
    self.sessionSeq = self.sessionSeq + 1
    val id = "test-session-" + self.sessionSeq.toString()
    self.entries[id] = newMap()
    return Ok(id)
  }

  func load(sessionId: in Session.SessionId): Result[Option[Session.SessionData], Session.SessionError] {
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if not isSome(found) {
      return Ok(None)
    }
    val entryMap = unwrapOr(found, newMap())
    return Ok(Some(value = Session.SessionData(
      id             = sessionId,
      entries        = entryMap,
      createdAt      = 0i64,
      lastAccessedAt = 0i64,
      expiresAt      = 0i64)))
  }

  func save(data: in Session.SessionData): Result[Unit, Session.SessionError] {
    // no-op: mock state is managed through set/delete/clear on the entries map.
    return Ok(())
  }

  func destroy(sessionId: in Session.SessionId): Result[Unit, Session.SessionError] {
    self.entries.remove(sessionId)
    return Ok(())
  }

  func touch(sessionId: in Session.SessionId): Result[Unit, Session.SessionError] {
    // no-op: mock doesn't track TTL.
    return Ok(())
  }

  func get(sessionId: in Session.SessionId, key: in String): Result[Option[String], Session.SessionError] {
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if not isSome(found) {
      return Ok(None)
    }
    val entryMap = unwrapOr(found, newMap())
    return Ok(mapGet(entryMap, key))
  }

  func set(sessionId: in Session.SessionId, key: in String, value: in String): Result[Unit, Session.SessionError] {
    // SECURITY: mirror NativeSessionStore / InProcessSessionStore —
    // refuse to auto-create a session for a caller-supplied id.  See
    // lyric-lang #316 / #436.  Diverging here means tests written
    // against this mock would silently miss a regression of the
    // session-fixation fix.
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if not isSome(found) {
      return Err(Session.SessionError(
        message = "session not found; call create() to obtain a fresh id before set()",
        code    = "SESSION_NOT_FOUND"))
    }
    val entryMap = unwrapOr(found, newMap())
    entryMap[key] = value
    self.entries[sessionId] = entryMap
    return Ok(())
  }

  func delete(sessionId: in Session.SessionId, key: in String): Result[Unit, Session.SessionError] {
    val found: Option[Map[String, String]] = mapGet(self.entries, sessionId)
    if isSome(found) {
      val entryMap = unwrapOr(found, newMap())
      entryMap.remove(key)
      self.entries[sessionId] = entryMap
    }
    return Ok(())
  }

  func clear(sessionId: in Session.SessionId): Result[Unit, Session.SessionError] {
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
@stable(since="0.1")
pub record MockFlagStore {
  var flags: Map[String, Bool]
}

impl Flags.FlagStore for MockFlagStore {
  func isEnabled(name: in String): Bool {
    return unwrapOr(mapGet(self.flags, name), false)
  }

  func getValue(name: in String): Option[Flags.FlagValue] {
    return None
  }

  func listFlags(): slice[Flags.FlagEntry] {
    return []
  }

  func refresh(): Result[Unit, Flags.FlagError] {
    return Ok(())
  }
}

/// Enable the named flag in the mock store.
@stable(since="0.1")
pub func enable(store: inout MockFlagStore, name: in String): Unit
  requires: name.length > 0
{
  store.flags[name] = true
}

/// Disable the named flag in the mock store.
@stable(since="0.1")
pub func disable(store: inout MockFlagStore, name: in String): Unit
  requires: name.length > 0
{
  store.flags[name] = false
}

// ─── TestContext ──────────────────────────────────────────────────────────────

/// A bundle of mock service implementations for use in unit tests.
///
/// Create one with `newTestContext()`.  Pass individual fields to functions
/// under test instead of real infrastructure clients.
@stable(since="0.1")
pub record TestContext {
  cache:   Cache.InProcessCacheStore
  mail:    MockMailSender
  storage: MockStorageBucket
  queue:   MockMessageQueue
  session: MockSessionStore
  flags:   MockFlagStore
  clock:   TestClock
}

/// Create a TestContext with all mocks initialised to sensible defaults.
@stable(since="0.1")
pub func newTestContext(): TestContext {
  val cacheStore = Cache.inProcess()
  return TestContext(
    cache   = cacheStore,
    mail    = MockMailSender(sentEmails = newList(), count = 0),
    storage = MockStorageBucket(objects = newMap(), bucketName = "test-bucket", callCount = 0),
    queue   = MockMessageQueue(published = newList(), queueName = "test-queue", msgCount = 0),
    session = MockSessionStore(entries = newMap(), sessionSeq = 0),
    flags   = MockFlagStore(flags = newMap()),
    clock   = TestClock(currentEpochMs = 0i64))
}

// ─── Assertion helpers ────────────────────────────────────────────────────────

/// Assert that `result` is Ok.  Panics with `msg` if it is Err.
///
/// Note: the error type is constrained to String because Lyric does not yet
/// expose a top `Any` type.  For other error types, convert to String first.
@stable(since="0.1")
pub func assertOk[T](result: in Result[T, String], msg: in String): Unit {
  // Use stdlib isOk/unwrapErrOr to avoid pattern matching on unknown T in
  // the bootstrap emitter (E11 "unknown constructor pattern 'Ok'").
  if not isOk(result) {
    val errMsg = unwrapErrOr(result, "")
    panic(msg + " (got Err: " + errMsg + ")")
  }
}

/// Assert that `result` is Err.  Panics with `msg` if it is Ok.
/// Returns the error value when the assertion passes.
@stable(since="0.1")
pub func assertErr[T](result: in Result[T, String], msg: in String): String {
  if isOk(result) {
    panic(msg + " (expected Err, got Ok)")
    return ""  // unreachable; panic diverges
  }
  return unwrapErrOr(result, "")
}

/// Assert that `opt` is Some.  Panics with `msg` if it is None.
/// Returns the contained value when the assertion passes.
@stable(since="0.1")
pub func assertSome[T](opt: in Option[T], msg: in String): T {
  if not isSome(opt) {
    panic(msg + " (expected Some, got None)")
  }
  return unwrapOr(opt, default())
}

/// Assert that `opt` is None.  Panics with `msg` if it is Some.
@stable(since="0.1")
pub func assertNone[T](opt: in Option[T], msg: in String): Unit {
  if isSome(opt) {
    panic(msg + " (expected None, got Some)")
  }
}

/// Assert that two strings are equal.  Panics with a message showing both
/// values when they differ.
@stable(since="0.1")
pub func assertEq(a: in String, b: in String, msg: in String): Unit {
  if a != b {
    panic(msg + " (expected \"" + a + "\", got \"" + b + "\")")
  }
}

/// Assert that `cond` is true.  Panics with `msg` if it is false.
@stable(since="0.1")
pub func assertTrue(cond: in Bool, msg: in String): Unit {
  if not cond {
    panic(msg + " (expected true)")
  }
}

/// Assert that `cond` is false.  Panics with `msg` if it is true.
@stable(since="0.1")
pub func assertFalse(cond: in Bool, msg: in String): Unit {
  if cond {
    panic(msg + " (expected false)")
  }
}

