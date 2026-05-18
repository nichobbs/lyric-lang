// tests/testing_tests.l — unit tests for the Testing library's mock
// implementations and assertion helpers.

@test_module
package Testing.TestingTests

import Std.Core
import Std.Testing
import Std.Collections
import Testing
import Mail
import Storage
import Mq
import Flags
import Session
import Cache

// ─── Helpers ─────────────────────────────────────────────────────────────────

func makeEmailMsg(): Mail.EmailMessage {
  val fromAddr = Mail.makeAddress("test@example.com")
  val toAddr   = Mail.makeAddress("recipient@example.com")
  Mail.EmailMessage(
    from        = fromAddr,
    to          = [toAddr],
    cc          = [],
    bcc         = [],
    subject     = "Test",
    textBody    = "Hello",
    htmlBody    = "",
    attachments = [],
    replyTo     = None)
}

func makeMqMsg(id: in String): Mq.Message {
  Mq.Message(id = id, body = "payload", headers = [], deliveryCount = 0)
}

// ─── TestContext ──────────────────────────────────────────────────────────────

test "newTestContext creates context with all fields initialized" {
  val ctx = Testing.newTestContext()
  // Verify all fields are present and have sane defaults.
  assertEqualInt(Testing.sentCount(ctx.mail), 0, "mail: initial count")
  assertEqualInt(Testing.publishedCount(ctx.queue), 0, "queue: initial count")
  assertEqualInt(Testing.now(ctx.clock).toInt(), 0, "clock: starts at 0")
}

// ─── TestClock ────────────────────────────────────────────────────────────────

test "TestClock starts at 0" {
  val ctx = Testing.newTestContext()
  assertEqualInt(Testing.now(ctx.clock).toInt(), 0, "initial epoch ms is 0")
}

test "advance moves clock forward by given ms" {
  val ctx = Testing.newTestContext()
  Testing.advance(ctx.clock, 1000)
  assertEqualInt(Testing.now(ctx.clock).toInt(), 1000, "after 1000ms advance")
}

test "advance accumulates across multiple calls" {
  val ctx = Testing.newTestContext()
  Testing.advance(ctx.clock, 500)
  Testing.advance(ctx.clock, 250)
  assertEqualInt(Testing.now(ctx.clock).toInt(), 750, "500 + 250 = 750ms")
}

test "advance by 0 is a no-op" {
  val ctx = Testing.newTestContext()
  Testing.advance(ctx.clock, 1000)
  Testing.advance(ctx.clock, 0)
  assertEqualInt(Testing.now(ctx.clock).toInt(), 1000, "advance(0) leaves clock unchanged")
}

// ─── MockMailSender ───────────────────────────────────────────────────────────

test "MockMailSender: send returns Ok" {
  val ctx = Testing.newTestContext()
  val msg = makeEmailMsg()
  match ctx.mail.send(msg) {
    case Err(e) -> assertTrue(false, "send() must return Ok: " + e.message)
    case Ok(_)  -> ()
  }
}

test "MockMailSender: sentCount increments after send" {
  val ctx = Testing.newTestContext()
  val msg = makeEmailMsg()
  ctx.mail.send(msg)
  assertEqualInt(Testing.sentCount(ctx.mail), 1, "count after one send")
}

test "MockMailSender: lastSent returns None when no emails sent" {
  val ctx = Testing.newTestContext()
  match Testing.lastSent(ctx.mail) {
    case Some(_) -> assertTrue(false, "lastSent must be None before any sends")
    case None    -> ()
  }
}

test "MockMailSender: lastSent returns Some after send" {
  val ctx = Testing.newTestContext()
  val msg = makeEmailMsg()
  ctx.mail.send(msg)
  match Testing.lastSent(ctx.mail) {
    case None    -> assertTrue(false, "lastSent must be Some after one send")
    case Some(e) -> Testing.assertEq(e.subject, "Test", "subject matches")
  }
}

test "MockMailSender: sentCount is accurate after multiple sends" {
  val ctx = Testing.newTestContext()
  val msg = makeEmailMsg()
  ctx.mail.send(msg)
  ctx.mail.send(msg)
  ctx.mail.send(msg)
  assertEqualInt(Testing.sentCount(ctx.mail), 3, "count after three sends")
}

test "MockMailSender: clearSent resets count to 0" {
  val ctx = Testing.newTestContext()
  val msg = makeEmailMsg()
  ctx.mail.send(msg)
  ctx.mail.send(msg)
  Testing.clearSent(ctx.mail)
  assertEqualInt(Testing.sentCount(ctx.mail), 0, "count after clearSent")
}

test "MockMailSender: lastSent is None after clearSent" {
  val ctx = Testing.newTestContext()
  val msg = makeEmailMsg()
  ctx.mail.send(msg)
  Testing.clearSent(ctx.mail)
  match Testing.lastSent(ctx.mail) {
    case Some(_) -> assertTrue(false, "lastSent must be None after clearSent")
    case None    -> ()
  }
}

// ─── MockStorageBucket ────────────────────────────────────────────────────────

test "MockStorageBucket: put returns Ok" {
  val ctx = Testing.newTestContext()
  match Storage.put(ctx.storage, "mykey", "data", "text/plain") {
    case Err(e) -> assertTrue(false, "put() must return Ok: " + e.message)
    case Ok(_)  -> ()
  }
}

test "MockStorageBucket: get returns NOT_FOUND for missing key" {
  val ctx = Testing.newTestContext()
  match Storage.get(ctx.storage, "missing-key") {
    case Ok(_)  -> assertTrue(false, "get() for missing key must return Err")
    case Err(e) -> Testing.assertEq(e.code, "NOT_FOUND", "error code")
  }
}

test "MockStorageBucket: put then get round-trip" {
  val ctx = Testing.newTestContext()
  Storage.put(ctx.storage, "rkey", "aGVsbG8=", "text/plain")
  match Storage.get(ctx.storage, "rkey") {
    case Err(e)  -> assertTrue(false, "get() after put() must succeed: " + e.message)
    case Ok(obj) -> Testing.assertEq(obj.dataBase64, "aGVsbG8=", "data round-trip")
  }
}

test "MockStorageBucket: delete removes key" {
  val ctx = Testing.newTestContext()
  Storage.put(ctx.storage, "delkey", "data", "text/plain")
  Storage.delete(ctx.storage, "delkey")
  match Storage.get(ctx.storage, "delkey") {
    case Ok(_)  -> assertTrue(false, "get() after delete() must return Err")
    case Err(e) -> Testing.assertEq(e.code, "NOT_FOUND", "deleted key is NOT_FOUND")
  }
}

test "MockStorageBucket: exists returns false before put" {
  val ctx = Testing.newTestContext()
  match Storage.exists(ctx.storage, "no-such-key") {
    case Err(e)   -> assertTrue(false, "exists() must succeed: " + e.message)
    case Ok(found) -> assertFalse(found, "exists before put must be false")
  }
}

test "MockStorageBucket: exists returns true after put" {
  val ctx = Testing.newTestContext()
  Storage.put(ctx.storage, "existkey", "data", "text/plain")
  match Storage.exists(ctx.storage, "existkey") {
    case Err(e)   -> assertTrue(false, "exists() must succeed: " + e.message)
    case Ok(found) -> assertTrue(found, "exists after put must be true")
  }
}

test "MockStorageBucket: presignedUrl returns url containing bucket name" {
  val ctx = Testing.newTestContext()
  match Storage.presignedUrl(ctx.storage, "some/key", 3600) {
    case Err(e)  -> assertTrue(false, "presignedUrl() must succeed: " + e.message)
    case Ok(url) -> assertTrue(url.contains("test-bucket"), "url contains bucket name")
  }
}

test "MockStorageBucket: list with prefix filters correctly" {
  val ctx = Testing.newTestContext()
  Storage.put(ctx.storage, "images/a.jpg", "data1", "image/jpeg")
  Storage.put(ctx.storage, "images/b.jpg", "data2", "image/jpeg")
  Storage.put(ctx.storage, "docs/c.pdf",   "data3", "application/pdf")
  match Storage.list(ctx.storage, "images/") {
    case Err(e)  -> assertTrue(false, "list() must succeed: " + e.message)
    case Ok(res) -> assertEqualInt(res.entries.length, 2, "only image/ entries listed")
  }
}

test "MockStorageBucket: list with empty prefix returns all keys" {
  val ctx = Testing.newTestContext()
  Storage.put(ctx.storage, "a", "d1", "text/plain")
  Storage.put(ctx.storage, "b", "d2", "text/plain")
  match Storage.list(ctx.storage, "") {
    case Err(e)  -> assertTrue(false, "list() must succeed: " + e.message)
    case Ok(res) -> assertTrue(res.entries.length >= 2, "all keys included")
  }
}

// ─── MockMessageQueue ─────────────────────────────────────────────────────────

test "MockMessageQueue: publish returns Ok and increments count" {
  val ctx = Testing.newTestContext()
  val msg = makeMqMsg("m1")
  match ctx.queue.publish(msg) {
    case Err(e) -> assertTrue(false, "publish() must return Ok: " + e)
    case Ok(_)  -> ()
  }
  assertEqualInt(Testing.publishedCount(ctx.queue), 1, "count after one publish")
}

test "MockMessageQueue: publishBatch publishes all messages" {
  val ctx = Testing.newTestContext()
  val msgs = [makeMqMsg("b1"), makeMqMsg("b2"), makeMqMsg("b3")]
  match ctx.queue.publishBatch(msgs) {
    case Err(e) -> assertTrue(false, "publishBatch() must return Ok: " + e)
    case Ok(_)  -> ()
  }
  assertEqualInt(Testing.publishedCount(ctx.queue), 3, "count after batch of 3")
}

test "MockMessageQueue: lastPublished returns None when nothing published" {
  val ctx = Testing.newTestContext()
  match Testing.lastPublished(ctx.queue) {
    case Some(_) -> assertTrue(false, "lastPublished must be None before any publishes")
    case None    -> ()
  }
}

test "MockMessageQueue: lastPublished returns correct message after publish" {
  val ctx = Testing.newTestContext()
  val msg = makeMqMsg("last-msg")
  ctx.queue.publish(Mq.Message(id = "first",    body = "first-payload",   headers = [], deliveryCount = 0))
  ctx.queue.publish(Mq.Message(id = "last-msg", body = "expected-payload", headers = [], deliveryCount = 0))
  match Testing.lastPublished(ctx.queue) {
    case None    -> assertTrue(false, "lastPublished must be Some after publishes")
    case Some(p) -> Testing.assertEq(p.body, "expected-payload", "last published body")
  }
}

// ─── MockFlagStore ────────────────────────────────────────────────────────────

test "MockFlagStore: isEnabled returns false for unknown flag" {
  val ctx = Testing.newTestContext()
  assertFalse(ctx.flags.isEnabled("unknown-flag"), "unknown flag is disabled by default")
}

test "MockFlagStore: enable makes isEnabled return true" {
  val ctx = Testing.newTestContext()
  Testing.enable(ctx.flags, "my-feature")
  assertTrue(ctx.flags.isEnabled("my-feature"), "flag is enabled after enable()")
}

test "MockFlagStore: disable makes isEnabled return false" {
  val ctx = Testing.newTestContext()
  Testing.enable(ctx.flags, "toggle-flag")
  Testing.disable(ctx.flags, "toggle-flag")
  assertFalse(ctx.flags.isEnabled("toggle-flag"), "flag is disabled after disable()")
}

test "MockFlagStore: getValue returns FlagBool(true) for enabled flag" {
  val ctx = Testing.newTestContext()
  Testing.enable(ctx.flags, "bool-flag")
  match ctx.flags.getValue("bool-flag") {
    case None    -> assertTrue(false, "getValue must return Some for known flag")
    case Some(v) ->
      match v {
        case Flags.FlagValue.FlagBool(b) -> assertTrue(b, "FlagBool value should be true")
        case _                           -> assertTrue(false, "unexpected FlagValue variant")
      }
  }
}

test "MockFlagStore: getValue returns None for unknown flag" {
  val ctx = Testing.newTestContext()
  match ctx.flags.getValue("nonexistent") {
    case None    -> ()
    case Some(_) -> assertTrue(false, "getValue must be None for unknown flag")
  }
}

// ─── Assertion helpers ────────────────────────────────────────────────────────

test "Testing.assertOk passes for Ok result" {
  val r: Result[Int, String] = Ok(42)
  Testing.assertOk(r, "should be Ok")
}

test "Testing.assertErr passes for Err result and returns error string" {
  val r: Result[Int, String] = Err("expected failure")
  val msg = Testing.assertErr(r, "should be Err")
  Testing.assertEq(msg, "expected failure", "error string returned")
}

test "Testing.assertSome passes for Some and returns value" {
  val opt: Option[String] = Some(value = "hello")
  val v = Testing.assertSome(opt, "should be Some")
  Testing.assertEq(v, "hello", "unwrapped value matches")
}

test "Testing.assertNone passes for None" {
  val opt: Option[String] = None
  Testing.assertNone(opt, "should be None")
}

test "Testing.assertEq passes when strings are equal" {
  Testing.assertEq("abc", "abc", "equal strings")
}

test "Testing.assertTrue passes for true" {
  Testing.assertTrue(true, "literal true")
}

test "Testing.assertFalse passes for false" {
  Testing.assertFalse(false, "literal false")
}
