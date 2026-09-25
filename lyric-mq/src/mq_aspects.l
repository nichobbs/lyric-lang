//! Mq.Aspects — pub aspect templates for message queue cross-cutting concerns.
//!
//! Two templates:
//!
//!   Idempotent  — row-constrained B'-mode (docs/56): deduplicates message
//!                 handlers using a Cache.CacheStore keyed by `args.message.id`.
//!                 Reads `args.message` from the handler argument list, so the
//!                 handler must declare a `message: Message` parameter.
//!
//!   DeadLetter  — B-mode: after a failed consume (handler returns Err), checks
//!                 the delivery count against `maxDeliveries` and dead-letters
//!                 the message when the limit is exceeded.  The dead-letter store
//!                 must be supplied by the consumer's wire block; this aspect
//!                 references it by the module-level `deadLetterStore` variable
//!                 that the consumer is expected to assign before the aspect fires.
//!
//! Typical consumer usage:
//!
//!   import Mq.Aspects
//!   import Cache
//!   import Mq
//!
//!   var idemStore = Cache.inProcess()
//!
//!   aspect OrderIdempotent from Mq.Aspects.Idempotent {
//!     matches: name like "handleOrder*"
//!     config { cacheKeyPrefix: String = "mq:order:idem:", ttlSeconds: Int = 7200 }
//!   }
//!
//!   aspect OrderDeadLetter from Mq.Aspects.DeadLetter {
//!     matches: name like "handleOrder*"
//!     config { enabled: Bool = true, maxDeliveries: Int = 3 }
//!   }
//!
//! See docs/26-aspects.md §18, docs/27-aspect-libraries.md, and lyric-mq/README.md.
@runtime_checked
package Mq.Aspects

import Std.Core
import Std.Time
import Std.Collections
import Cache
import Mq

// ─── Idempotent ───────────────────────────────────────────────────────────────
/// Deduplicate message handler calls using a cache keyed by message ID.
///
/// Row-constrained B'-mode (docs/56 / D115): reads `args.message.id` via a
/// `where TArgs has { message: Message }` row clause.  The handler must
/// declare a `message: in Message` (or `message: Message`) parameter; the
/// weaver reports A0047 if this parameter is absent or mistyped.
///
/// Logic:
///   1. Compute cache key as `cacheKeyPrefix + args.message.id`.
///   2. Atomically claim the key (`IdempotencyLedger.claim`).  If it was
///      already processed, or another delivery of the same id is being
///      handled right now, return Ok(()) without calling the handler.
///   3. Otherwise call the handler (`call.proceed()`).
///   4. On Ok(()) mark the message ID in the cache with `ttlSeconds` TTL.
///   5. On Err pass the error through unchanged (do not cache failures).
///   6. Release the claim, also when the handler panics.
///
/// Deduplication is per process: consumers in different processes need a
/// shared store with an atomic put-if-absent, which `CacheStore` does not
/// offer yet.
///
/// **Type constraint:** apply only to handlers returning `Result[Unit, String]`.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled        Bool   — master switch (default: true)
///   cacheKeyPrefix String — prepended to every message ID (default: "mq:idem:")
///   ttlSeconds     Int    — how long to remember processed IDs, >= 0; 0 never
///                           expires (default: 3600)
@stable(since = "0.1")
pub aspect Idempotent {
  config {
    enabled: Bool = true
    cacheKeyPrefix: String = "mq:idem:"
    ttlSeconds: Int = 3600
  }
  // No `requires: args.message.id != ""`: a message id arrives from the broker
  // / external producers, so a `requires:` clause (D118 elaborates it into a
  // runtime precondition assert) would let a single empty-id message crash the
  // consumer — a DoS.  An empty id is also degenerate for dedup (every empty-id
  // message would collide on one idempotency key and be silently dropped as a
  // "duplicate"), so the body processes such messages without dedup instead.
  // handler must declare a message: Message parameter
  around(call) -> ret where TArgs has { message: Message } {
    if not enabled {
      ret = call.proceed()
    } else if ttlSeconds < 0 {
      // A configuration bug, raised before the handler runs: failing after
      // it had succeeded would redeliver and process the message twice.
      panic("Mq.Aspects.Idempotent: ttlSeconds must be >= 0 (0 = never expire), got " + ttlSeconds.toString())
    } else if args.message.id == "" {
      ret = call.proceed()
    } else {
      val key = cacheKeyPrefix + args.message.id
      if not idempotencyLedger.claim(key) {
        // Already processed, or another delivery of the same id is being
        // handled right now; that delivery acks or is redelivered itself.
        ret = Ok(())
      } else {
        // Runs however the handler exits, a panic included, so a failed
        // delivery never leaves its id claimed.
        var succeeded = false
        defer {
          idempotencyLedger.finish(key, succeeded, ttlSeconds)
        }
        ret = call.proceed()
        succeeded = match ret { case Ok(_) -> true; case Err(_) -> false }
      }
    }
  }
}

// Module-level in-process cache shared by all Idempotent instances.  Only
// `IdempotencyLedger` reads or writes it, under its lock.
val idempotentStore: CacheStore = Cache.inProcess()

/// The Idempotent aspect's claim-then-execute ledger (#7321).  `claim`
/// atomically checks both the processed-id cache and the ids currently being
/// handled, and marks the id in flight; `finish` records a success in the
/// cache and releases the claim.  Two concurrent deliveries of one id can
/// therefore never both run the handler.  The ledger is per process: it
/// deduplicates across the consumers of one process, not across processes.
@stable(since = "0.1")
pub protected type IdempotencyLedger {
  var inFlight: Map[String, Bool] = newMap()
  entry claim(key: in String): Bool
    requires: key.length > 0
  {
    if inFlight.containsKey(key) {
      return false
    }
    match Cache.get(idempotentStore, key) {
      case Some(_) -> return false
      case None -> ()
    }
    inFlight[key] = true
    true
  }
  entry finish(key: in String, succeeded: in Bool, ttlSeconds: in Int): Unit
    requires: key.length > 0
    requires: ttlSeconds >= 0
  {
    if succeeded {
      Cache.setWithTtl(idempotentStore, key, "1", ttlSeconds)
    }
    inFlight.remove(key)
  }
}

val idempotencyLedger: IdempotencyLedger = IdempotencyLedger()

// ─── DeadLetter ───────────────────────────────────────────────────────────────
/// Route messages that exceed their delivery limit to a dead-letter store.
///
/// Row-constrained B'-mode (docs/56 / D115): reads `args.message` and
/// `args.consumer` via a `where TArgs has { message: Message, consumer:
/// QueueConsumer }` row clause.  Apply only to handlers whose signature
/// includes both:
///   - `message:  in Message`       — provides id and deliveryCount
///   - `consumer: in QueueConsumer` — called to nack the message after dead-lettering
///
/// The weaver reports A0047 if either parameter is absent or mistyped.
///
/// After the handler returns Err, checks `args.message.deliveryCount + 1`
/// (the deliveries made so far; `deliveryCount` is 0 on the first) against
/// `maxDeliveries`.  When the limit is reached, so on the
/// `maxDeliveries`-th failed delivery, appends a
/// `DeadLetterEntry` to `Mq.Aspects.deadLetterStore` and calls
/// `nack(messageId, requeue = false)` on the consumer so the broker also
/// removes the message from the live queue.
///
/// Because aspect config fields must be scalar values (Bool, Int, String),
/// the dead-letter store cannot be passed as a config field.  Consumers must
/// assign `Mq.Aspects.deadLetterStore` to an `InProcessDeadLetterStore` (or
/// a custom `DeadLetterStore` implementation) before the aspect fires.  The
/// default value is an in-process store sized to `DeadLetter.maxEntries`.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled       Bool — master switch (default: true)
///   maxDeliveries Int  — failed deliveries before dead-lettering, >= 1 (default: 3)
@stable(since = "0.1")
pub aspect DeadLetter {
  config {
    enabled: Bool = true
    maxDeliveries: Int = 3
  }
  // No `requires: args.message.id != ""`: the message arrives from the broker
  // / external producers, so a `requires:` clause (D118 elaborates it into a
  // runtime precondition assert) would let a single empty-id message crash the
  // consumer — a DoS.  The body only uses the id to nack after max deliveries,
  // and `nack` answers an empty id with `Err` rather than a precondition
  // violation, so no early rejection is needed.
  // handler must declare a message: Message parameter
  // handler must declare a consumer: QueueConsumer parameter (shape checked by A0047)
  around(call) -> ret where TArgs has { message: Message, consumer: QueueConsumer } {
    if not enabled {
      ret = call.proceed()
    } else if maxDeliveries < 1 {
      // A configuration bug, raised before the handler runs (#7320).
      panic("Mq.Aspects.DeadLetter: maxDeliveries must be >= 1, got " + maxDeliveries.toString())
    } else {
      ret = call.proceed()
      match ret {
        case Ok(_) -> ()    // Successful delivery; nothing to do.
        case Err(reason) -> {
          // deliveryCount is 0-based (0 on the first delivery), so this is
          // the number of deliveries made, the one that just failed included.
          val attempts = args.message.deliveryCount + 1
          if attempts >= maxDeliveries {
            val nowMs = nowEpochMillis()
            val dlEntry = DeadLetterEntry(message = args.message, reason = reason, failedAt = nowMs)
            deadLetterStore.append(dlEntry)
            // Tell the broker not to redeliver this message.  Ignore errors
            // since the store append already captured the message.
            args.consumer.nack(args.message.id, false)
          }
        }
      }
    }
  }
}

// Module-level dead-letter store shared by all DeadLetter instances.
// Replace this with a custom DeadLetterStore implementation before the
// aspect fires when persistence or a remote store is required.
val deadLetterStore: DeadLetterStore = Mq.inProcessDeadLetterStore(10000)
