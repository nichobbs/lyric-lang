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
