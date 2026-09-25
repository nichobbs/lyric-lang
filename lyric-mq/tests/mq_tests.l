//! tests/mq_tests.l — unit tests for the Mq package's pure wire-type surface.
//! Covers Message, MessageHeader, DeadLetterEntry, and AckMode construction
//! and field access without touching any broker-backed kernel functions.
@test_module
package Mq.MqTests

import Std.Core
import Std.Testing
import Mq

// ─── Message ──────────────────────────────────────────────────────────────────
test "Message can be constructed and fields are accessible" {
  val msg = Mq.Message(id = "msg-001", body = "hello", headers = [], deliveryCount = 0)
  assertEqual(msg.id, "msg-001", "id field")
  assertEqual(msg.body, "hello", "body field")
  assertEqualInt(msg.deliveryCount, 0, "deliveryCount field")
  assertEqualInt(msg.headers.length, 0, "headers length")
}

test "Message with empty headers list is valid" {
  val msg = Mq.Message(id = "empty-hdr", body = "payload", headers = [], deliveryCount = 0)
  assertEqualInt(msg.headers.length, 0, "no headers")
}

test "Message with non-zero deliveryCount (redelivery scenario)" {
  val msg = Mq.Message(id = "retry-msg", body = "body", headers = [], deliveryCount = 3)
  assertEqualInt(msg.deliveryCount, 3, "redelivery count is 3")
}

// ─── MessageHeader ────────────────────────────────────────────────────────────
test "MessageHeader construction and field access" {
  val h = Mq.MessageHeader(key = "content-type", value = "application/json")
  assertEqual(h.key, "content-type", "header key")
  assertEqual(h.value, "application/json", "header value")
}

test "Message with multiple headers" {
  val h1 = Mq.MessageHeader(key = "x-trace-id", value = "abc123")
  val h2 = Mq.MessageHeader(key = "x-source", value = "order-service")
  val msg = Mq.Message(id = "hdr-msg", body = "data", headers = [h1, h2], deliveryCount = 0)
  assertEqualInt(msg.headers.length, 2, "two headers")
  assertEqual(msg.headers[0].key, "x-trace-id", "first header key")
  assertEqual(msg.headers[1].value, "order-service", "second header value")
}

// ─── DeadLetterEntry ─────────────────────────────────────────────────────────
test "DeadLetterEntry construction and field access" {
  val msg = Mq.Message(id = "dead-msg", body = "poison", headers = [], deliveryCount = 5)
  val entry = Mq.DeadLetterEntry(message = msg, reason = "exceeded max delivery count", failedAt = 1716000000000)
  assertEqual(entry.message.id, "dead-msg", "entry message id")
  assertEqual(entry.reason, "exceeded max delivery count", "entry reason")
  assertTrue(entry.failedAt == 1716000000000, "entry failedAt")
}

// ─── AckMode ─────────────────────────────────────────────────────────────────
// ─── InProcessDeadLetterStore ─────────────────────────────────────────────────
func deadLetter(id: in String): Mq.DeadLetterEntry {
  val msg = Mq.Message(id = id, body = "", headers = [], deliveryCount = 1)
  Mq.DeadLetterEntry(message = msg, reason = "failed", failedAt = 0)
}

test "InProcessDeadLetterStore keeps the newest maxEntries entries in order (#7279)" {
  val store: Mq.DeadLetterStore = Mq.InProcessDeadLetterStore(entries = [], maxEntries = 3)
  store.append(deadLetter("a"))
  store.append(deadLetter("b"))
  store.append(deadLetter("c"))
  store.append(deadLetter("d"))
  store.append(deadLetter("e"))
  val kept = store.list()
  assertEqualInt(store.count(), 3, "capacity is kept")
  assertEqual(kept[0].message.id, "c", "oldest retained")
  assertEqual(kept[1].message.id, "d", "middle")
  assertEqual(kept[2].message.id, "e", "newest last")
}

test "InProcessDeadLetterStore with maxEntries 0 keeps only the latest entry" {
  val store: Mq.DeadLetterStore = Mq.InProcessDeadLetterStore(entries = [], maxEntries = 0)
  store.append(deadLetter("a"))
  store.append(deadLetter("b"))
  assertEqualInt(store.count(), 1, "one entry")
  assertEqual(store.list()[0].message.id, "b", "the latest")
}

test "AckMode.Auto can be matched" {
  val mode = Mq.AckMode.Auto
  match mode {
    case Mq.AckMode.Auto -> assertTrue(true, "matched Auto")
    case Mq.AckMode.Manual -> assertTrue(false, "should not match Manual")
  }
}

test "AckMode.Manual can be matched" {
  val mode = Mq.AckMode.Manual
  match mode {
    case Mq.AckMode.Auto -> assertTrue(false, "should not match Auto")
    case Mq.AckMode.Manual -> assertTrue(true, "matched Manual")
  }
}

// ─── In-memory broker round-trip (#6511) ─────────────────────────────────────
// End-to-end through the PUBLIC surface: connectTo → publish (with a header) →
// consume → ack → close, against the default in-memory kernel.  Before #6511
// the dispatch stubs never reached any kernel, so `Mq.connect()` returned
// `Err` on every backend and none of this was reachable.  dotnet-only: the
// jvm target has no in-memory kernel (#3385), so these tests erase there.
@cfg(target = "dotnet")
test "in-memory broker round-trips a published message (#6511)" {
  match Mq.connectTo("inmemory://local", "roundtrip-q") {
    case Err(e) -> assertTrue(false, "connectTo failed: " + e)
    case Ok(queue) -> {
      val h = Mq.MessageHeader(key = "content-type", value = "application/json")
      val msg = Mq.Message(id = "rt-001", body = "{\"n\":42}", headers = [h], deliveryCount = 0)
      match Mq.publish(queue, msg) {
        case Err(e2) -> assertTrue(false, "publish failed: " + e2)
        case Ok(_) -> ()
      }
      var gotId = ""
      var gotBody = ""
      var gotHeaderCount = 0
      val consumed = Mq.consume(
        queue,
        0,
        { m -> gotId = m.id; gotBody = m.body; gotHeaderCount = m.headers.length; Ok(()) }
      )
      match consumed {
        case Err(e3) -> assertTrue(false, "consume failed: " + e3)
        case Ok(_) -> ()
      }
      assertEqual(gotId, "rt-001", "consumed message id")
      assertEqual(gotBody, "{\"n\":42}", "consumed message body")
      assertEqualInt(gotHeaderCount, 1, "consumed header count")
      match Mq.ack(queue, "rt-001") {
        case Err(e4) -> assertTrue(false, "ack failed: " + e4)
        case Ok(_) -> ()
      }
      queue.close()
    }
  }
}

@cfg(target = "dotnet")
test "consume on an empty queue reports timeout (#6511)" {
  match Mq.connectTo("inmemory://local", "empty-q") {
    case Err(e) -> assertTrue(false, "connectTo failed: " + e)
    case Ok(queue) -> {
      match Mq.consume(queue, 0, { m -> Ok(()) }) {
        case Ok(_) -> assertTrue(false, "expected timeout on empty queue")
        case Err(e2) -> assertEqual(e2, "timeout", "empty poll reports timeout")
      }
      queue.close()
    }
  }
}

// ─── Broker-supplied input is never a precondition (#7239) ───────────────────
@cfg(target = "dotnet")
func withQueue(name: in String, body: (NativeQueue) -> Unit): Unit {
  match Mq.connectTo("inmemory://local", name) {
    case Err(e) -> assertTrue(false, "connectTo failed: " + e)
    case Ok(queue) -> {
      body(queue)
      queue.close()
    }
  }
}

@cfg(target = "dotnet")
test "control characters in a body round-trip instead of breaking the wire JSON (#7239)" {
  withQueue(
    "ctrl-q",
    { queue ->
      val body = "a\u{0001}b\u{001f}c\u{0008}d\u{000c}e\u{0000}f"
      val h = Mq.MessageHeader(key = "k\u{0002}", value = "v\u{001b}")
      match Mq.publish(queue, Mq.Message(id = "ctrl-1", body = body, headers = [h], deliveryCount = 0)) {
        case Err(e) -> assertTrue(false, "publish failed: " + e)
        case Ok(_) -> ()
      }
      var got = ""
      var gotKey = ""
      match Mq.consume(queue, 0, { m -> got = m.body; gotKey = m.headers[0].key; Ok(()) }) {
        case Err(e) -> assertTrue(false, "consume failed: " + e)
        case Ok(_) -> ()
      }
      assertEqual(got, body, "body with control characters survives")
      assertEqual(gotKey, "k\u{0002}", "header key with a control character survives")
    }
  )
}

@cfg(target = "dotnet")
test "deliveryCount is 0 on first delivery and counts redeliveries (#7239)" {
  withQueue(
    "count-q",
    { queue ->
      match Mq.publish(queue, Mq.Message(id = "cnt-1", body = "b", headers = [], deliveryCount = 0)) {
        case Err(e) -> assertTrue(false, "publish failed: " + e)
        case Ok(_) -> ()
      }
      var first = -1
      val _ = Mq.consume(queue, 0, { m -> first = m.deliveryCount; Ok(()) })
      assertEqualInt(first, 0, "first delivery")
      match Mq.nack(queue, "cnt-1", true) {
        case Err(e) -> assertTrue(false, "nack failed: " + e)
        case Ok(_) -> ()
      }
      var second = -1
      val _ = Mq.consume(queue, 0, { m -> second = m.deliveryCount; Ok(()) })
      assertEqualInt(second, 1, "one earlier delivery")
    }
  )
}

@cfg(target = "dotnet")
test "ack and nack answer an empty message id with Err (#7239)" {
  withQueue(
    "empty-id-q",
    { queue ->
      match Mq.ack(queue, "") {
        case Ok(_) -> assertTrue(false, "ack of an empty id must fail")
        case Err(e) -> assertEqual(e, EMPTY_MESSAGE_ID, "ack")
      }
      match Mq.nack(queue, "", false) {
        case Ok(_) -> assertTrue(false, "nack of an empty id must fail")
        case Err(e) -> assertEqual(e, EMPTY_MESSAGE_ID, "nack")
      }
    }
  )
}

@cfg(target = "dotnet")
test "publishBatch refuses a batch with an empty id before publishing any (#7239)" {
  withQueue(
    "batch-q",
    { queue ->
      val ok = Mq.Message(id = "b-1", body = "b", headers = [], deliveryCount = 0)
      val bad = Mq.Message(id = "", body = "b", headers = [], deliveryCount = 0)
      assertPanics("empty id in a batch", { -> val _ = Mq.publishBatch(queue, [ok, bad]) })
      match Mq.consume(queue, 0, { m -> Ok(()) }) {
        case Ok(_) -> assertTrue(false, "nothing may be published from a rejected batch")
        case Err(e) -> assertEqual(e, "timeout", "the queue is still empty")
      }
    }
  )
}

test "connectTo with no queue name is an Err, not a panic (#7239)" {
  match Mq.connectTo("inmemory://local", "") {
    case Ok(_) -> assertTrue(false, "an empty queue name must not connect")
    case Err(e) -> assertTrue(e.contains("queue name"), "names the missing setting: " + e)
  }
}

test "InProcessDeadLetterStore requires a capacity of at least 1 (#7239)" {
  assertPanics("capacity 0", { -> val _ = InProcessDeadLetterStore(entries = [], maxEntries = 0) })
  assertEqualInt(Mq.inProcessDeadLetterStore(1).maxEntries, 1, "capacity 1 is valid")
}

test "allHaveIds" {
  val m = Mq.Message(id = "x", body = "", headers = [], deliveryCount = 0)
  assertTrue(allHaveIds([m, m]), "all ids present")
  assertFalse(allHaveIds([m, m.copy(id = "")]), "one empty id")
}

// ─── Wire decoding (#7322) ────────────────────────────────────────────────────
// A malformed message from the broker is an Err, never a panic in consume.
func decodeError(json: in String): String {
  match messageFromJson(json) {
    case Ok(_) -> "OK"
    case Err(e) -> e
  }
}

test "messageFromJson decodes a well-formed message" {
  match messageFromJson("{\"id\":\"m1\",\"body\":\"hi\",\"headers\":[{\"key\":\"k\",\"value\":\"v\"}],\"deliveryCount\":2}") {
    case Err(e) -> assertTrue(false, "must decode: " + e)
    case Ok(m) -> {
      assertEqual(m.id, "m1", "id")
      assertEqual(m.body, "hi", "body")
      assertEqualInt(m.headers.length, 1, "one header")
      assertEqual(m.headers[0].value, "v", "header value")
      assertEqualInt(m.deliveryCount, 2, "delivery count")
    }
  }
}

test "messageFromJson returns Err for malformed messages" {
  assertTrue(decodeError("{\"id\":42,\"body\":\"x\"}").contains("'id' must be a string"), "non-string id")
  assertTrue(decodeError("{\"id\":\"a\",\"body\":[1]}").contains("'body' must be a string"), "non-string body")
  assertTrue(decodeError("{\"id\":\"a\",\"headers\":{}}").contains("'headers' must be an array"), "object headers")
  assertTrue(
    decodeError("{\"id\":\"a\",\"headers\":[1]}").contains("each header must be an object"),
    "non-object header"
  )
  assertTrue(
    decodeError("{\"id\":\"a\",\"headers\":[{\"key\":1}]}").contains("header 'key' must be a string"),
    "non-string header key"
  )
  assertTrue(
    decodeError("{\"id\":\"a\",\"deliveryCount\":\"3\"}").contains("'deliveryCount' must be an integer"),
    "string count"
  )
  assertTrue(decodeError("{\"id\":\"a\",\"headers\":[oops]}") != "OK", "invalid JSON")
  assertTrue(decodeError("[]") != "OK", "not an object")
}
