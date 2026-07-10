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

// DeadLetter's `requires: args.message.id != ""` was removed in the same fix as
// Idempotent's (see mq_aspects.l). A runtime weaving test for it needs a
// user-supplied `QueueConsumer` handler argument, which currently trips a
// separate self-hosted MSIL codegen gap (a woven handler taking an
// interface-typed parameter lowers to an InvalidProgram) — a compiler bug
// distinct from this DoS fix. The Idempotent cases above exercise the identical
// empty-`message.id` code path (the field the removed clause guarded), so the
// no-crash property of the shared fix is covered; a DeadLetter-specific runtime
// test is deferred until the interface-arg weaving codegen gap is closed.
