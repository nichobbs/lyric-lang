/// Testing — mock implementations and test helpers for Lyric libraries.
///
/// Provides in-process mock implementations of Cache, Mail, Storage, Mq,
/// Session, and Flags interfaces so that unit tests can exercise application
/// logic without real infrastructure.  Also provides assertion helpers for
/// writing concise, readable test cases.
///
/// Usage:
///
///   import Testing
///   import Std.Core
///
///   val ctx = Testing.newTestContext()
///   Testing.enable(ctx.flags, "new-checkout")
///   Testing.assertOk(someFunction(ctx.mail, ctx.storage), "expected success")
///   Testing.assertEq(ctx.mail.sentCount().toString(), "1", "one email sent")
///
/// See lyric-testing/README.md.

@runtime_checked
package Testing

import Std.Core
import Std.Collections
import Std.Time
import Std.Json
import Cache
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
  headers: [Mq.MessageHeader]
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
pub func advance(clock: in TestClock, ms: in Long): Unit
  requires: ms >= 0
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
  var sentEmails: [SentEmail]
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
    sentEmails = sentEmails + [captured]
    count      = count + 1
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
pub func clearSent(sender: in MockMailSender): Unit {
  sender.sentEmails = []
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
    objects.set(key, obj)
    callCount = callCount + 1
    val meta = Storage.StorageMetadata(
      contentType   = contentType,
      contentLength = 0,
      etag          = "mock-etag",
      lastModified  = "",
      userMeta      = userMeta)
    return Ok(meta)
  }

  func get(key: in String): Result[Storage.StorageObject, Storage.StorageError] {
    match objects.get(key) {
      case Some(obj) -> {
        val meta = Storage.StorageMetadata(
          contentType   = obj.contentType,
          contentLength = 0,
          etag          = "mock-etag",
          lastModified  = "",
          userMeta      = Map.empty())
        val result = Storage.StorageObject(
          bucket     = bucketName,
          key        = key,
          metadata   = meta,
          dataBase64 = obj.dataBase64)
        return Ok(result)
      }
      case None ->
        return Err(Storage.StorageError(
          message = "not found: " + key,
          code    = "NOT_FOUND"))
    }
  }

  func delete(key: in String): Result[Unit, Storage.StorageError] {
    objects.remove(key)
    return Ok(())
  }

  func list(
    prefix:            in String,
    continuationToken: in String,
    maxKeys:           in Int
  ): Result[Storage.ListResult, Storage.StorageError] {
    var entries: [Storage.ListEntry] = []
    for (k, obj) in objects {
      val matches = if prefix.length == 0 {
        true
      } else if k.length >= prefix.length {
        k.substring(0, prefix.length) == prefix
      } else {
        false
      }
      if matches {
        val entry = Storage.ListEntry(
          key           = k,
          contentLength = 0,
          lastModified  = "",
          etag          = "mock-etag")
        entries = entries + [entry]
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
    return Ok("https://mock-storage.test/" + bucketName + "/" + key)
  }

  func exists(key: in String): Result[Bool, Storage.StorageError] {
    match objects.get(key) {
      case Some(_) -> return Ok(true)
      case None    -> return Ok(false)
    }
  }
}

// ─── MockMessageQueue ─────────────────────────────────────────────────────────

/// Mock message queue that captures published messages in memory for assertion.
@stable(since="0.1")
pub record MockMessageQueue {
  var published: [PublishedMessage]
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
    published = published + [captured]
    msgCount  = msgCount + 1
    return Ok(())
  }

  func publishBatch(messages: in [Mq.Message]): Result[Unit, String]
    requires: messages.length > 0
  {
    for msg in messages {
      val captured = PublishedMessage(
        body    = msg.body,
        headers = msg.headers)
      published = published + [captured]
      msgCount  = msgCount + 1
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

/// Mock session store backed by an in-process Cache.CacheStore.
///
/// Sessions are serialised as strings via `serialiseSession` and stored under
/// their session ID.  The TTL defaults to 3600 seconds.
@stable(since="0.1")
pub record MockSessionStore {
  var cache:      Cache.InProcessCacheStore
  var sessionSeq: Int
}

impl Session.SessionStore for MockSessionStore {
  func create(): Result[Session.SessionId, Session.SessionError] {
    sessionSeq = sessionSeq + 1
    val id = "test-session-" + sessionSeq.toString()
    val data = Session.SessionData(
      id             = id,
      entries        = Map.empty(),
      createdAt      = 0,
      lastAccessedAt = 0,
      expiresAt      = 0)
    val json = serialiseSession(data)
    Cache.set(cache, id, json)
    return Ok(id)
  }

  func load(sessionId: in Session.SessionId): Result[Option[Session.SessionData], Session.SessionError] {
    match Cache.get(cache, sessionId) {
      case Some(json) -> return Ok(Some(value = parseSession(json)))
      case None       -> return Ok(None)
    }
  }

  func save(data: in Session.SessionData): Result[Unit, Session.SessionError] {
    val json = serialiseSession(data)
    Cache.set(cache, data.id, json)
    return Ok(())
  }

  func destroy(sessionId: in Session.SessionId): Result[Unit, Session.SessionError] {
    Cache.delete(cache, sessionId)
    return Ok(())
  }

  func touch(sessionId: in Session.SessionId): Result[Unit, Session.SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case Some(data) -> return save(data)
          case None       -> return Ok(())
        }
      case Err(e) -> return Err(e)
    }
  }

  func get(sessionId: in Session.SessionId, key: in String): Result[Option[String], Session.SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case Some(data) -> return Ok(data.entries.get(key))
          case None       -> return Ok(None)
        }
      case Err(e) -> return Err(e)
    }
  }

  func set(sessionId: in Session.SessionId, key: in String, value: in String): Result[Unit, Session.SessionError] {
    match load(sessionId) {
      case Ok(opt) -> {
        val existing = match opt {
          case Some(d) -> d
          case None    ->
            Session.SessionData(
              id             = sessionId,
              entries        = Map.empty(),
              createdAt      = 0,
              lastAccessedAt = 0,
              expiresAt      = 0)
        }
        val updated = Session.SessionData(
          id             = existing.id,
          entries        = existing.entries.set(key, value),
          createdAt      = existing.createdAt,
          lastAccessedAt = existing.lastAccessedAt,
          expiresAt      = existing.expiresAt)
        return save(updated)
      }
      case Err(e) -> return Err(e)
    }
  }

  func delete(sessionId: in Session.SessionId, key: in String): Result[Unit, Session.SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case Some(data) -> {
            val updated = Session.SessionData(
              id             = data.id,
              entries        = data.entries.remove(key),
              createdAt      = data.createdAt,
              lastAccessedAt = data.lastAccessedAt,
              expiresAt      = data.expiresAt)
            return save(updated)
          }
          case None -> return Ok(())
        }
      case Err(e) -> return Err(e)
    }
  }

  func clear(sessionId: in Session.SessionId): Result[Unit, Session.SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case Some(data) -> {
            val updated = Session.SessionData(
              id             = data.id,
              entries        = Map.empty(),
              createdAt      = data.createdAt,
              lastAccessedAt = data.lastAccessedAt,
              expiresAt      = data.expiresAt)
            return save(updated)
          }
          case None -> return Ok(())
        }
      case Err(e) -> return Err(e)
    }
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
    match flags.get(name) {
      case Some(v) -> v
      case None    -> false
    }
  }

  func getValue(name: in String): Option[Flags.FlagValue] {
    match flags.get(name) {
      case Some(v) -> Some(value = Flags.FlagValue.FlagBool(value = v))
      case None    -> None
    }
  }

  func listFlags(): [Flags.FlagEntry] {
    var result: [Flags.FlagEntry] = []
    for (name, v) in flags {
      val entry = Flags.FlagEntry(
        name        = name,
        value       = Flags.FlagValue.FlagBool(value = v),
        description = "")
      result = result + [entry]
    }
    return result
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
  store.flags = store.flags.set(name, true)
}

/// Disable the named flag in the mock store.
@stable(since="0.1")
pub func disable(store: inout MockFlagStore, name: in String): Unit
  requires: name.length > 0
{
  store.flags = store.flags.set(name, false)
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
    mail    = MockMailSender(sentEmails = [], count = 0),
    storage = MockStorageBucket(objects = Map.empty(), bucketName = "test-bucket", callCount = 0),
    queue   = MockMessageQueue(published = [], queueName = "test-queue", msgCount = 0),
    session = MockSessionStore(cache = Cache.inProcess(), sessionSeq = 0),
    flags   = MockFlagStore(flags = Map.empty()),
    clock   = TestClock(currentEpochMs = 0))
}

// ─── Assertion helpers ────────────────────────────────────────────────────────

/// Assert that `result` is Ok.  Panics with `msg` if it is Err.
///
/// Note: the error type is constrained to String because Lyric does not yet
/// expose a top `Any` type.  For other error types, convert to String first.
@stable(since="0.1")
pub func assertOk[T](result: in Result[T, String], msg: in String): Unit {
  match result {
    case Ok(_)    -> ()
    case Err(err) -> panic(msg + " (got Err: " + err + ")")
  }
}

/// Assert that `result` is Err.  Panics with `msg` if it is Ok.
/// Returns the error value when the assertion passes.
@stable(since="0.1")
pub func assertErr[T](result: in Result[T, String], msg: in String): String {
  match result {
    case Err(err) -> return err
    case Ok(_)    -> {
      panic(msg + " (expected Err, got Ok)")
      return ""  // unreachable; panic diverges
    }
  }
}

/// Assert that `opt` is Some.  Panics with `msg` if it is None.
/// Returns the contained value when the assertion passes.
@stable(since="0.1")
pub func assertSome[T](opt: in Option[T], msg: in String): T {
  match opt {
    case Some(v) -> return v
    case None    -> {
      panic(msg + " (expected Some, got None)")
      return default()  // unreachable; panic diverges
    }
  }
}

/// Assert that `opt` is None.  Panics with `msg` if it is Some.
@stable(since="0.1")
pub func assertNone[T](opt: in Option[T], msg: in String): Unit {
  match opt {
    case None    -> ()
    case Some(_) -> panic(msg + " (expected None, got Some)")
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

// ─── Private helpers ──────────────────────────────────────────────────────────

// Produce a minimal SessionData from a stored string.
func parseSession(json: in String): Session.SessionData {
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  var id:             String              = ""
  var createdAt:      Long               = 0
  var lastAccessedAt: Long               = 0
  var expiresAt:      Long               = 0
  var entries:        Map[String, String] = Map.empty()
  match Std.Json.tryGetProperty(root, "id") {
    case Some(v) -> id = Std.Json.getString(v)
    case None    -> ()
  }
  match Std.Json.tryGetProperty(root, "createdAt") {
    case Some(v) ->
      match Std.Json.tryGetLong(v) {
        case Some(n) -> createdAt = n
        case None    -> ()
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "lastAccessedAt") {
    case Some(v) ->
      match Std.Json.tryGetLong(v) {
        case Some(n) -> lastAccessedAt = n
        case None    -> ()
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "expiresAt") {
    case Some(v) ->
      match Std.Json.tryGetLong(v) {
        case Some(n) -> expiresAt = n
        case None    -> ()
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "entries") {
    case Some(obj) -> {
      var en = Std.Json.enumerateObject(obj)
      while Std.Json.objectMoveNext(en) {
        val prop = Std.Json.objectCurrent(en)
        val k    = Std.Json.propertyName(prop)
        val v    = Std.Json.getString(Std.Json.propertyValue(prop))
        entries  = entries.set(k, v)
      }
    }
    case None -> ()
  }
  return Session.SessionData(
    id             = id,
    entries        = entries,
    createdAt      = createdAt,
    lastAccessedAt = lastAccessedAt,
    expiresAt      = expiresAt)
}

func serialiseSession(data: in Session.SessionData): String {
  var entriesJson = "{"
  var first = true
  for (k, v) in data.entries {
    if not first { entriesJson = entriesJson + "," }
    entriesJson = entriesJson + sessionJsonStr(k) + ":" + sessionJsonStr(v)
    first = false
  }
  entriesJson = entriesJson + "}"
  return "{" +
    "\"id\":"             + sessionJsonStr(data.id)             + "," +
    "\"createdAt\":"      + data.createdAt.toString()            + "," +
    "\"lastAccessedAt\":" + data.lastAccessedAt.toString()       + "," +
    "\"expiresAt\":"      + data.expiresAt.toString()            + "," +
    "\"entries\":"        + entriesJson                          +
    "}"
}

// Wrap a string in JSON double-quotes with minimal escaping.
func sessionJsonStr(s: in String): String {
  var out = "\""
  var i   = 0
  while i < s.length {
    val ch = s.charAt(i).toString()
    if ch == "\"" {
      out = out + "\\\""
    } else if ch == "\\" {
      out = out + "\\\\"
    } else if ch == "\n" {
      out = out + "\\n"
    } else if ch == "\r" {
      out = out + "\\r"
    } else if ch == "\t" {
      out = out + "\\t"
    } else {
      out = out + ch
    }
    i = i + 1
  }
  return out + "\""
}
