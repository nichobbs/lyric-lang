/// Mq.Aspects — pub aspect templates for message queue cross-cutting concerns.
///
/// Two templates:
///
///   Idempotent  — C-mode (@inline_template): deduplicates message handlers
///                 using a Cache.CacheStore keyed by `args.message.id`.  Reads
///                 `args.message` from the handler argument list, so the handler
///                 must declare a `message: Message` parameter.
///
///   DeadLetter  — B-mode: after a failed consume (handler returns Err), checks
///                 the delivery count against `maxDeliveries` and dead-letters
///                 the message when the limit is exceeded.  The dead-letter store
///                 must be supplied by the consumer's wire block; this aspect
///                 references it by the module-level `deadLetterStore` variable
///                 that the consumer is expected to assign before the aspect fires.
///
/// Typical consumer usage:
///
///   import Mq.Aspects
///   import Cache
///   import Mq
///
///   var idemStore = Cache.inProcess()
///
///   aspect OrderIdempotent from Mq.Aspects.Idempotent {
///     matches: name like "handleOrder*"
///     config { cacheKeyPrefix: String = "mq:order:idem:", ttlSeconds: Int = 7200 }
///   }
///
///   aspect OrderDeadLetter from Mq.Aspects.DeadLetter {
///     matches: name like "handleOrder*"
///     config { enabled: Bool = true, maxDeliveries: Int = 3 }
///   }
///
/// See docs/26-aspects.md §18, docs/27-aspect-libraries.md, and lyric-mq/README.md.

@runtime_checked
package Mq.Aspects

import Std.Core
import Std.Time
import Cache
import Mq

// ─── Idempotent ───────────────────────────────────────────────────────────────

/// Deduplicate message handler calls using a cache keyed by message ID.
///
/// C-mode (@inline_template): reads `args.message.id` from the handler
/// argument list.  The handler must declare a `message: in Message` (or
/// `message: Message`) parameter; the compiler reports shape error A0042
/// if this parameter is absent.
///
/// Logic:
///   1. Compute cache key as `cacheKeyPrefix + args.message.id`.
///   2. If the key exists in the cache, the message was already processed —
///      return Ok(()) immediately without calling the handler.
///   3. Otherwise call the handler (`call.proceed()`).
///   4. On Ok(()) mark the message ID in the cache with `ttlSeconds` TTL.
///   5. On Err pass the error through unchanged (do not cache failures).
///
/// **Type constraint:** apply only to handlers returning `Result[Unit, String]`.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled        Bool   — master switch (default: true)
///   cacheKeyPrefix String — prepended to every message ID (default: "mq:idem:")
///   ttlSeconds     Int    — how long to remember processed IDs (default: 3600)
@stable(since="0.1")
@inline_template
pub aspect Idempotent {
  config {
    enabled:        Bool   = true
    cacheKeyPrefix: String = "mq:idem:"
    ttlSeconds:     Int    = 3600
  }

  requires:
    args.message.id != ""    // handler must declare a message: Message parameter

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = cacheKeyPrefix + args.message.id
      match Cache.get(idempotentStore, key) {
        case Some(_) ->
          // Already processed; skip and return success.
          ret = Ok(())
        case None ->
          ret = call.proceed()
          match ret {
            case Ok(_)  ->
              // Mark as processed so future redeliveries are no-ops.
              Cache.setWithTtl(idempotentStore, key, "1", ttlSeconds)
            case Err(_) -> ()  // Do not mark failed deliveries as processed.
          }
      }
    }
  }
}

// Module-level in-process cache shared by all Idempotent instances.
// Consumers who need a different TTL or store type should set
// `Mq.Aspects.idempotentStore` to their own CacheStore before the first call.
var idempotentStore = Cache.inProcess()

// ─── DeadLetter ───────────────────────────────────────────────────────────────

/// Route messages that exceed their delivery limit to a dead-letter store.
///
/// B-mode: wraps a consume handler.  After the handler returns Err, checks
/// `args.message.deliveryCount + 1` against `maxDeliveries`.  When the limit
/// is reached, appends a `DeadLetterEntry` to `Mq.Aspects.deadLetterStore`
/// and calls `nack(messageId, requeue = false)` on the queue consumer so the
/// broker also removes the message from the live queue.
///
/// Because aspect config fields must be scalar values (Bool, Int, String),
/// the dead-letter store cannot be passed as a config field.  Consumers must
/// assign `Mq.Aspects.deadLetterStore` to an `InProcessDeadLetterStore` (or
/// a custom `DeadLetterStore` implementation) before the aspect fires.  The
/// default value is an in-process store sized to `DeadLetter.maxEntries`.
///
/// **Type constraint:** apply only to handlers returning `Result[Unit, String]`
/// whose argument list includes `message: in Message`.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled       Bool — master switch (default: true)
///   maxDeliveries Int  — delivery attempts before dead-lettering (default: 3)
@stable(since="0.1")
pub aspect DeadLetter {
  config {
    enabled:       Bool = true
    maxDeliveries: Int  = 3
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      ret = call.proceed()
      match ret {
        case Ok(_)  -> ()    // Successful delivery; nothing to do.
        case Err(reason) -> {
          // deliveryCount is 0-based; add 1 for the just-completed attempt.
          val attempts = args.message.deliveryCount + 1
          if attempts >= maxDeliveries {
            val nowMs = Std.Time.SystemClock.now().toEpochMillis()
            val entry = DeadLetterEntry(
              message  = args.message,
              reason   = reason,
              failedAt = nowMs)
            deadLetterStore.append(entry)
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
var deadLetterStore: DeadLetterStore = Mq.inProcessDeadLetterStore(Mq.DeadLetter.maxEntries)
