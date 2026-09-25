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

// A delivery of an id that is still being handled is not run again (#7321).
// A nested call on the same id stands in for a concurrent consumer: the
// outer call holds the claim for the whole handler.
val nestedCalls: CallCounter = CallCounter(count = 0)

pub func idemGuardedNested(message: in Message): Result[Unit, String] {
  nestedCalls.count = nestedCalls.count + 1
  if nestedCalls.count == 1 {
    val _ = idemGuardedNested(message)
  }
  return Ok(())
}

test "Idempotent: a delivery of an id already in flight does not run the handler" {
  nestedCalls.count = 0
  match idemGuardedNested(mkMsg("in-flight-1")) {
    case Ok(_) -> assertTrue(true, "outer delivery succeeds")
    case Err(_) -> assertTrue(false, "must not error")
  }
  assertEqualInt(nestedCalls.count, 1, "the in-flight duplicate was not run")
}

// A handler that panics must release its claim, or the id could never be
// processed again in this process.
val panicCalls: CallCounter = CallCounter(count = 0)

pub func idemGuardedPanics(message: in Message): Result[Unit, String] {
  panicCalls.count = panicCalls.count + 1
  if panicCalls.count == 1 {
    panic("first attempt fails")
  }
  return Ok(())
}

test "Idempotent: a panicking handler releases its claim" {
  panicCalls.count = 0
  assertPanics("first attempt", { -> val _ = idemGuardedPanics(mkMsg("panics-1")) })
  match idemGuardedPanics(mkMsg("panics-1")) {
    case Ok(_) -> assertTrue(true, "the redelivery runs")
    case Err(_) -> assertTrue(false, "must not error")
  }
  assertEqualInt(panicCalls.count, 2, "the handler ran again after the panic")
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
// dead-letter path (which nacks the broker) is observable. Like `NativeQueue`,
// it answers an empty id with `Err(EMPTY_MESSAGE_ID)` rather than a
// precondition violation, since message ids come from the broker (#7239).
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

  func ack(messageId: in String): Result[Unit, String] {
    return if messageId.length == 0 { Err(EMPTY_MESSAGE_ID) } else { Ok(()) }
  }

  func nack(messageId: in String, requeue: in Bool): Result[Unit, String] {
    consumerCalls.nacks = consumerCalls.nacks + 1
    if messageId.length == 0 {
      return Err(EMPTY_MESSAGE_ID)
    }
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
  // does not nack.
  match handleOrderFail(mkMsg(""), consumer) {
    case Ok(_) -> assertTrue(false, "the failing handler must surface its Err")
    case Err(_) -> assertTrue(true, "the failure is returned without crashing on the empty id")
  }
  assertEqualInt(dlCalls.count, 1, "the woven handler ran")
  assertEqualInt(consumerCalls.nacks, 0, "below the threshold, nothing is dead-lettered")
}

test "DeadLetter: the maxDeliveries-th failed delivery dead-letters, the one before does not (#7320)" {
  dlCalls.count = 0
  consumerCalls.nacks = 0
  val consumer = TestConsumer(tag = 0)
  // deliveryCount is 0-based: 1 is the second delivery, 2 the third.
  val _ = handleOrderFail(mkMsgN("poison-2", 1), consumer)
  assertEqualInt(consumerCalls.nacks, 0, "the second failed delivery is redelivered")
  val _ = handleOrderFail(mkMsgN("poison-2", 2), consumer)
  assertEqualInt(consumerCalls.nacks, 1, "the third failed delivery is dead-lettered with maxDeliveries 3")
  assertEqualInt(dlCalls.count, 2, "the handler ran once per delivery, no extra delivery")
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

test "DeadLetter: an empty-id poison message is dead-lettered without crashing the consumer (#7239)" {
  dlCalls.count = 0
  consumerCalls.nacks = 0
  val consumer = TestConsumer(tag = 0)
  // Past the threshold the advice nacks `args.message.id`; with an empty id
  // that used to trip `nack`'s `requires: messageId.length > 0` and panic the
  // consumer on every redelivery.
  match handleOrderFail(mkMsgN("", 3), consumer) {
    case Ok(_) -> assertTrue(false, "the failing handler must surface its Err")
    case Err(e) -> assertEqual(e, "processing failed", "the handler's own error is returned")
  }
  assertEqualInt(consumerCalls.nacks, 1, "the nack is attempted and answered with Err, not a panic")
}

// A negative TTL is a configuration bug; it must surface before the handler
// runs, never after a successful handler (which would redeliver the message
// and process it twice, #7239).
aspect IdemBadTtl from Mq.Aspects.Idempotent {
  matches: name like "idemBadTtl*"
  config {
    ttlSeconds: Int = -1
  }
}

val badTtlCalls: CallCounter = CallCounter(count = 0)

pub func idemBadTtlHandler(message: in Message): Result[Unit, String] {
  badTtlCalls.count = badTtlCalls.count + 1
  return Ok(())
}

test "Idempotent: a negative ttlSeconds fails before the handler runs (#7239)" {
  badTtlCalls.count = 0
  assertPanicsWith("negative ttl", "ttlSeconds must be >= 0", { -> val _ = idemBadTtlHandler(mkMsg("m-1")) })
  assertEqualInt(badTtlCalls.count, 0, "the handler never ran")
}
