//! tests/mq_aspect_weaving_tests.l — runtime weaving tests for the
//! Mq.Aspects templates (Idempotent, DeadLetter).
//!
//! Both aspects previously carried a `requires: args.message.id != ""` clause,
//! which elaborates into a runtime precondition assert (D118) that PANICKED the
//! consumer process on a message with an empty/absent id (plausible from a
//! malformed or adversarial producer) — the same DoS class fixed for
//! `lyric-web`. The fix removed the clause; Idempotent now passes an empty-id
//! message straight through (no dedup, since an empty id is degenerate for
//! keying), and DeadLetter proceeds normally. These tests pin that an empty id
//! never crashes the woven handler.
@test_module
package Mq.MqAspectWeavingTests

import Std.Core
import Std.Testing
// DeadLetter's B'-mode body is compiled into THIS (consumer) assembly and
// calls the unqualified `nowEpochMillis()` from Std.Time, so the consumer must
// import Std.Time for that symbol to resolve — an unresolved unqualified call
// in a woven body otherwise lowers to invalid IL.
import Std.Time
import Mq
import Mq.Aspects

record CallCounter {
  var count: Int
}

func mkMsg(id: in String): Message {
  return Message(id = id, body = "payload", headers = [], deliveryCount = 0)
}

// ─── Idempotent ─────────────────────────────────────────────────────────────
aspect IdemGuard from Mq.Aspects.Idempotent {
  matches: name like "idemGuarded*"
  config {
    cacheKeyPrefix: String = "idem-weave-test:"
    ttlSeconds: Int = 300
  }
}

val idemCalls: CallCounter = CallCounter(count = 0)

pub func idemGuardedHandler(message: in Message): Result[Unit, String] {
  idemCalls.count = idemCalls.count + 1
  return Ok(())
}

test "Idempotent: an empty message id does not crash and is not deduplicated (was a panic)" {
  idemCalls.count = 0
  match idemGuardedHandler(mkMsg("")) {
    case Ok(_) -> assertTrue(true, "empty-id message processed without crashing")
    case Err(_) -> assertTrue(false, "empty-id message must not error")
  }
  // Empty ids bypass the idempotency cache, so a second empty-id call runs again.
  match idemGuardedHandler(mkMsg("")) {
    case Ok(_) -> assertTrue(true, "second empty-id message also processed")
    case Err(_) -> assertTrue(false, "empty-id message must not error")
  }
  assertEqualInt(idemCalls.count, 2, "empty ids are not deduplicated, so both calls ran")
}

test "Idempotent: a repeated non-empty id is deduplicated (only the first call runs)" {
  idemCalls.count = 0
  val first = idemGuardedHandler(mkMsg("msg-42"))
  val second = idemGuardedHandler(mkMsg("msg-42"))
  match first {
    case Ok(_) -> assertTrue(true, "first delivery runs the handler")
    case Err(_) -> assertTrue(false, "must not error")
  }
  match second {
    case Ok(_) -> assertTrue(true, "duplicate delivery is short-circuited to Ok")
    case Err(_) -> assertTrue(false, "must not error")
  }
  assertEqualInt(idemCalls.count, 1, "the handler ran only once for the repeated non-empty id")
}

// ─── DeadLetter ─────────────────────────────────────────────────────────────
// DeadLetter's `requires: args.message.id != ""` was removed in the same fix as
// Idempotent's (see mq_aspects.l). Its woven handler additionally takes a
// user-supplied `QueueConsumer` interface-typed argument, which once tripped a
// self-hosted MSIL codegen gap (an interface-typed woven-handler parameter
// lowered to an InvalidProgram). That gap is now closed (interface method
// signatures resolve ctx-aware in Msil.Codegen, docs/59 wave 1), so these
// tests exercise the real woven `around(call)` advice directly.
//
// A test QueueConsumer that records how many times `nack` is called, so the
// dead-letter path (which nacks the broker) is observable. `nack` keeps the
// interface's `requires: messageId.length > 0` contract, so the empty-id cases
// below must stay on a path that never nacks (Ok, or a failure below the
// delivery threshold) — an empty id reaching `nack` is a consumer-contract
// violation, not the aspect DoS under test.
record ConsumerCalls {
  var nacks: Int
}

val consumerCalls: ConsumerCalls = ConsumerCalls(nacks = 0)

record TestConsumer {
  tag: Int
}

impl Mq.QueueConsumer for TestConsumer {
  func consume(timeoutMs: in Int, handler: (Message) -> Result[Unit, String]): Result[Unit, String]
    requires: timeoutMs >= 0
  {
    return Ok(())
  }

  func ack(messageId: in String): Result[Unit, String]
    requires: messageId.length > 0
  {
    return Ok(())
  }

  func nack(messageId: in String, requeue: in Bool): Result[Unit, String]
    requires: messageId.length > 0
  {
    consumerCalls.nacks = consumerCalls.nacks + 1
    return Ok(())
  }

  func close(): Unit {
    ()
  }
}

func mkMsgN(id: in String, deliveryCount: in Int): Message {
  return Message(id = id, body = "payload", headers = [], deliveryCount = deliveryCount)
}

aspect OrderDeadLetter from Mq.Aspects.DeadLetter {
  matches: name like "handleOrder*"
  config {
    maxDeliveries: Int = 3
  }
}

val dlCalls: CallCounter = CallCounter(count = 0)

// A handler that always succeeds — the DeadLetter advice proceeds and, on Ok,
// never touches `message.id` or the consumer.
pub func handleOrderOk(message: in Message, consumer: in QueueConsumer): Result[Unit, String] {
  dlCalls.count = dlCalls.count + 1
  return Ok(())
}

// A handler that always fails — the DeadLetter advice inspects deliveryCount
// and, past maxDeliveries, appends a dead-letter entry and nacks the consumer.
pub func handleOrderFail(message: in Message, consumer: in QueueConsumer): Result[Unit, String] {
  dlCalls.count = dlCalls.count + 1
  return Err("processing failed")
}

test "DeadLetter: an empty message id does not crash the woven handler (was a panic)" {
  dlCalls.count = 0
  consumerCalls.nacks = 0
  val consumer = TestConsumer(tag = 0)
  // Removed `requires: args.message.id != ""` used to panic here before the
  // body ran, regardless of the handler's result. On the Ok path DeadLetter
  // proceeds and does nothing further.
  match handleOrderOk(mkMsg(""), consumer) {
    case Ok(_) -> assertTrue(true, "empty-id message processed without crashing")
    case Err(_) -> assertTrue(false, "the Ok handler must not error")
  }
  assertEqualInt(dlCalls.count, 1, "the woven handler ran")
  assertEqualInt(consumerCalls.nacks, 0, "a successful delivery is never dead-lettered")
}

test "DeadLetter: an empty-id failure below the delivery threshold does not crash or dead-letter" {
  dlCalls.count = 0
  consumerCalls.nacks = 0
  val consumer = TestConsumer(tag = 0)
  // deliveryCount 0 -> attempts 1 <= maxDeliveries 3, so the Err path runs but
  // does not nack — the empty id therefore never reaches the consumer's
  // `requires: messageId.length > 0` contract.
  match handleOrderFail(mkMsg(""), consumer) {
    case Ok(_) -> assertTrue(false, "the failing handler must surface its Err")
    case Err(_) -> assertTrue(true, "the failure is returned without crashing on the empty id")
  }
  assertEqualInt(dlCalls.count, 1, "the woven handler ran")
  assertEqualInt(consumerCalls.nacks, 0, "below the threshold, nothing is dead-lettered")
}

test "DeadLetter: a failure past maxDeliveries dead-letters and nacks the consumer" {
  dlCalls.count = 0
  consumerCalls.nacks = 0
  val consumer = TestConsumer(tag = 0)
  // deliveryCount 3 -> attempts 4 > maxDeliveries 3, so DeadLetter appends a
  // dead-letter entry and nacks. This drives the woven interface-typed
  // `args.consumer.nack(...)` path — the exact shape that once InvalidProgram'd.
  match handleOrderFail(mkMsgN("poison-1", 3), consumer) {
    case Ok(_) -> assertTrue(false, "the failing handler must surface its Err")
    case Err(_) -> assertTrue(true, "the poison message's failure is returned")
  }
  assertEqualInt(dlCalls.count, 1, "the woven handler ran")
  assertEqualInt(consumerCalls.nacks, 1, "past the threshold the consumer is nacked exactly once")
}
