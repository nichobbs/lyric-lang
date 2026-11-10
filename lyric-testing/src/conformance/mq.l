//! Testing.Conformance.Mq — conformance suites for `Mq.MessageQueue`,
//! `Mq.QueueConsumer` and `Mq.DeadLetterStore`.
//!
//! `runQueue(factory)`: `factory` returns a fresh, empty queue every call, as
//! its two ends: the `MessageQueue` that publishes and the `QueueConsumer`
//! that receives.  They may be the same object (`Mq.NativeQueue` is both).
//!
//! `runDeadLetterStore(factory)`: `factory(maxEntries)` returns a fresh store
//! that keeps at most `maxEntries` entries.
@runtime_checked
@io
package Testing.Conformance.Mq

import Std.Core
import Std.Collections
import Testing.Conformance
import Mq as MqLib

/// The two ends of one queue under test.
@stable(since = "0.1")
pub record QueueEnds {
  publisher: MqLib.MessageQueue
  consumer: MqLib.QueueConsumer
}

/// Run the `MessageQueue` and `QueueConsumer` contract against queues from
/// `factory`.
@stable(since = "0.1")
pub func runQueue(factory: () -> QueueEnds): Checks {
  val c = newChecks("MessageQueue")
  runCase(c, "a published message is delivered intact", { -> roundTrip(c, factory()) })
  runCase(c, "consume on an empty queue reports a timeout", { -> emptyTimeout(c, factory()) })
  runCase(c, "messages are delivered in publish order", { -> fifoOrder(c, factory()) })
  runCase(c, "publishBatch delivers every message in order", { -> batchOrder(c, factory()) })
  runCase(c, "ack settles a delivery for good", { -> ackSettles(c, factory()) })
  runCase(c, "nack with requeue redelivers with a higher deliveryCount", { -> nackRequeues(c, factory()) })
  runCase(c, "nack without requeue does not redeliver", { -> nackDrops(c, factory()) })
  runCase(c, "special characters in a body and headers round-trip", { -> specialCharacters(c, factory()) })
  runCase(c, "an empty message id is an Err on ack and nack", { -> emptyIdIsErr(c, factory()) })
  runCase(c, "a failing handler's error is returned to the caller", { -> handlerErrorPropagates(c, factory()) })
  runCase(c, "the convenience wrappers agree with the interfaces", { -> wrappers(c, factory()) })
  return c
}

func msg(id: in String, body: in String): MqLib.Message {
  return MqLib.Message(id = id, body = body, headers = [], deliveryCount = 0)
}

func publishOrFail(c: in Checks, ends: in QueueEnds, m: in MqLib.Message): Unit {
  match ends.publisher.publish(m) {
    case Ok(_) -> expectTrue(c, true, "publish " + m.id)
    case Err(e) -> failCase(c, "publish " + m.id + " failed: " + e)
  }
}

// A one-slot cell the consume handler writes the delivered message into.
ref record Received {
  var message: MqLib.Message
  var got: Bool
}

func record(slot: in Received, m: in MqLib.Message): Result[Unit, String] {
  slot.message = m
  slot.got = true
  return Ok(())
}

func okHandler(m: in MqLib.Message): Result[Unit, String] {
  return Ok(())
}

func refusingHandler(m: in MqLib.Message): Result[Unit, String] {
  return Err("handler refused")
}

func newReceived(): Received {
  return Received(message = msg("", ""), got = false)
}

// Consume one message (waiting up to `timeoutMs`); returns what was delivered,
// or `None` on a timeout.  Any other consume failure is recorded.
func take(c: in Checks, ends: in QueueEnds, timeoutMs: in Int): Option[MqLib.Message] {
  val slot = newReceived()
  val result = ends.consumer.consume(timeoutMs, { m -> record(slot, m) })
  match result {
    case Ok(_) -> {
      if slot.got {
        return Some(value = slot.message)
      }
      failCase(c, "consume returned Ok without invoking the handler")
      return None
    }
    case Err(e) -> {
      if e != "timeout" {
        failCase(c, "consume failed with \"" + e + "\" (a timeout is Err(\"timeout\"))")
      }
      return None
    }
  }
}

func roundTrip(c: in Checks, ends: in QueueEnds): Unit {
  val sent = MqLib.Message(
    id = "m-1",
    body = "{\"event\":\"order.placed\"}",
    headers = [MqLib.MessageHeader(key = "content-type", value = "application/json")],
    deliveryCount = 0
  )
  publishOrFail(c, ends, sent)
  match take(c, ends, 1000) {
    case None -> failCase(c, "the published message was not delivered")
    case Some(got) -> {
      expectEqual(c, got.id, "m-1", "id")
      expectEqual(c, got.body, "{\"event\":\"order.placed\"}", "body")
      expectEqualInt(c, got.headers.length, 1, "header count")
      if got.headers.length == 1 {
        expectEqual(c, got.headers[0].key, "content-type", "header key")
        expectEqual(c, got.headers[0].value, "application/json", "header value")
      }
      expectEqualInt(c, got.deliveryCount, 0, "deliveryCount on the first delivery")
    }
  }
}

func emptyTimeout(c: in Checks, ends: in QueueEnds): Unit {
  val polled = ends.consumer.consume(0, { m -> okHandler(m) })
  match polled {
    case Err(e) -> expectEqual(c, e, "timeout", "an immediate poll of an empty queue")
    case Ok(_) -> failCase(c, "an empty queue must not deliver a message")
  }
  val waited = ends.consumer.consume(30, { m -> okHandler(m) })
  match waited {
    case Err(e) -> expectEqual(c, e, "timeout", "a short wait on an empty queue")
    case Ok(_) -> failCase(c, "an empty queue must not deliver a message")
  }
}

func fifoOrder(c: in Checks, ends: in QueueEnds): Unit {
  publishOrFail(c, ends, msg("a", "1"))
  publishOrFail(c, ends, msg("b", "2"))
  publishOrFail(c, ends, msg("c", "3"))
  for expected in ["a", "b", "c"] {
    match take(c, ends, 1000) {
      case Some(got) -> expectEqual(c, got.id, expected, "delivery order")
      case None -> failCase(c, "message " + expected + " was not delivered")
    }
  }
  expectTrue(c, not isSome(take(c, ends, 0)), "the queue is empty after three deliveries")
}

func batchOrder(c: in Checks, ends: in QueueEnds): Unit {
  match ends.publisher.publishBatch([msg("x", "1"), msg("y", "2")]) {
    case Ok(_) -> expectTrue(c, true, "publishBatch")
    case Err(e) -> failCase(c, "publishBatch failed: " + e)
  }
  for expected in ["x", "y"] {
    match take(c, ends, 1000) {
      case Some(got) -> expectEqual(c, got.id, expected, "batch delivery order")
      case None -> failCase(c, "batch message " + expected + " was not delivered")
    }
  }
}

func ackSettles(c: in Checks, ends: in QueueEnds): Unit {
  publishOrFail(c, ends, msg("m", "body"))
  match take(c, ends, 1000) {
    case None -> failCase(c, "the message was not delivered")
    case Some(got) -> {
      match ends.consumer.ack(got.id) {
        case Ok(_) -> expectTrue(c, true, "ack")
        case Err(e) -> failCase(c, "ack failed: " + e)
      }
    }
  }
  expectTrue(c, not isSome(take(c, ends, 0)), "an acked message is not redelivered")
}

func nackRequeues(c: in Checks, ends: in QueueEnds): Unit {
  publishOrFail(c, ends, msg("m", "body"))
  match take(c, ends, 1000) {
    case None -> failCase(c, "the message was not delivered")
    case Some(first) -> {
      match ends.consumer.nack(first.id, true) {
        case Ok(_) -> expectTrue(c, true, "nack(requeue)")
        case Err(e) -> failCase(c, "nack failed: " + e)
      }
      match take(c, ends, 1000) {
        case None -> failCase(c, "a requeued message was not redelivered")
        case Some(again) -> {
          expectEqual(c, again.id, "m", "the redelivered id")
          expectEqualInt(c, again.deliveryCount, 1, "deliveryCount after one redelivery")
        }
      }
    }
  }
}

func nackDrops(c: in Checks, ends: in QueueEnds): Unit {
  publishOrFail(c, ends, msg("m", "body"))
  match take(c, ends, 1000) {
    case None -> failCase(c, "the message was not delivered")
    case Some(first) -> {
      match ends.consumer.nack(first.id, false) {
        case Ok(_) -> expectTrue(c, true, "nack(drop)")
        case Err(e) -> failCase(c, "nack failed: " + e)
      }
    }
  }
  expectTrue(c, not isSome(take(c, ends, 0)), "a nacked message with requeue = false is not redelivered")
}

func specialCharacters(c: in Checks, ends: in QueueEnds): Unit {
  val body = "line1\nline2\t\"quoted\" \\ back\u{0001}ctl café 世"
  val sent = MqLib.Message(
    id = "special",
    body = body,
    headers = [MqLib.MessageHeader(key = "k\"1", value = "v\n1")],
    deliveryCount = 0
  )
  publishOrFail(c, ends, sent)
  match take(c, ends, 1000) {
    case None -> failCase(c, "the message was not delivered")
    case Some(got) -> {
      expectEqual(c, got.body, body, "the body survives the wire encoding")
      if got.headers.length == 1 {
        expectEqual(c, got.headers[0].key, "k\"1", "the header key survives")
        expectEqual(c, got.headers[0].value, "v\n1", "the header value survives")
      } else {
        failCase(c, "expected one header, got " + got.headers.length.toString())
      }
    }
  }
}

func emptyIdIsErr(c: in Checks, ends: in QueueEnds): Unit {
  match ends.consumer.ack("") {
    case Err(_) -> expectTrue(c, true, "ack(\"\") is an Err")
    case Ok(_) -> failCase(c, "ack(\"\") must be an Err")
  }
  match ends.consumer.nack("", true) {
    case Err(_) -> expectTrue(c, true, "nack(\"\") is an Err")
    case Ok(_) -> failCase(c, "nack(\"\") must be an Err")
  }
}

func handlerErrorPropagates(c: in Checks, ends: in QueueEnds): Unit {
  publishOrFail(c, ends, msg("m", "body"))
  val result = ends.consumer.consume(1000, { m -> refusingHandler(m) })
  match result {
    case Err(e) -> expectEqual(c, e, "handler refused", "the handler's error")
    case Ok(_) -> failCase(c, "a failing handler must make consume fail")
  }
}

func wrappers(c: in Checks, ends: in QueueEnds): Unit {
  match MqLib.publish(ends.publisher, msg("w", "via wrapper")) {
    case Ok(_) -> expectTrue(c, true, "Mq.publish")
    case Err(e) -> failCase(c, "Mq.publish failed: " + e)
  }
  val slot = newReceived()
  val result = MqLib.consume(ends.consumer, 1000, { m -> record(slot, m) })
  match result {
    case Ok(_) -> expectEqual(c, slot.message.id, "w", "Mq.consume delivered the message")
    case Err(e) -> failCase(c, "Mq.consume failed: " + e)
  }
}

/// Run the `DeadLetterStore` contract against stores from `factory`.
@stable(since = "0.1")
pub func runDeadLetterStore(factory: (Int) -> MqLib.DeadLetterStore): Checks {
  val c = newChecks("DeadLetterStore")
  runCase(c, "a new store is empty", { -> dlEmpty(c, factory(10)) })
  runCase(c, "entries are listed in insertion order", { -> dlOrder(c, factory(10)) })
  runCase(c, "append does not deduplicate by message id", { -> dlNoDedupe(c, factory(10)) })
  runCase(c, "entries keep their message, reason and timestamp", { -> dlFields(c, factory(10)) })
  runCase(c, "at capacity the oldest entry is dropped", { -> dlCapacity(c, factory(3)) })
  return c
}

func entry(id: in String, reason: in String, at: in Long): MqLib.DeadLetterEntry {
  return MqLib.DeadLetterEntry(message = msg(id, "body-" + id), reason = reason, failedAt = at)
}

func dlEmpty(c: in Checks, store: in MqLib.DeadLetterStore): Unit {
  expectEqualInt(c, store.count(), 0, "count of a new store")
  expectEqualInt(c, store.list().length, 0, "list of a new store")
}

func dlOrder(c: in Checks, store: in MqLib.DeadLetterStore): Unit {
  store.append(entry("a", "r", 1i64))
  store.append(entry("b", "r", 2i64))
  store.append(entry("c", "r", 3i64))
  expectEqualInt(c, store.count(), 3, "count")
  val all = store.list()
  if all.length == 3 {
    expectEqual(c, all[0].message.id, "a", "first entry")
    expectEqual(c, all[1].message.id, "b", "second entry")
    expectEqual(c, all[2].message.id, "c", "third entry")
  } else {
    failCase(c, "expected three entries, got " + all.length.toString())
  }
}

func dlNoDedupe(c: in Checks, store: in MqLib.DeadLetterStore): Unit {
  store.append(entry("same", "first", 1i64))
  store.append(entry("same", "second", 2i64))
  expectEqualInt(c, store.count(), 2, "two appends of one id are two entries")
}

func dlFields(c: in Checks, store: in MqLib.DeadLetterStore): Unit {
  store.append(entry("a", "poison message", 1234i64))
  val all = store.list()
  if all.length == 1 {
    expectEqual(c, all[0].message.body, "body-a", "the dead-lettered body")
    expectEqual(c, all[0].reason, "poison message", "the reason")
    expectEqualLong(c, all[0].failedAt, 1234i64, "the failure timestamp")
  } else {
    failCase(c, "expected one entry, got " + all.length.toString())
  }
}

func dlCapacity(c: in Checks, store: in MqLib.DeadLetterStore): Unit {
  for id in ["a", "b", "c", "d", "e"] {
    store.append(entry(id, "r", 1i64))
  }
  expectEqualInt(c, store.count(), 3, "count never exceeds the capacity")
  val all = store.list()
  if all.length == 3 {
    expectEqual(c, all[0].message.id, "c", "the oldest surviving entry")
    expectEqual(c, all[2].message.id, "e", "the newest entry")
  } else {
    failCase(c, "expected three entries, got " + all.length.toString())
  }
}
