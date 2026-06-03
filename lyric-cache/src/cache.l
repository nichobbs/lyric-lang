// Cache — typed key-value cache with TTL and a pluggable store interface.
// Stability: @experimental — the surface compiles and the in-memory store has
// tests, but the redis-backed store has not been driven against a live
// cluster in CI.
//
// WARNING (thread safety): `InProcessCacheStore` is NOT thread-safe.  Concurrent
// access from multiple threads produces undefined behaviour (lost updates,
// torn reads).  Until the `protected type` weaver ships, multi-threaded
// services should use a Redis-backed store (`Lyric.Cache.Redis`) or guard
// access with an external mutex.  See lyric-lang #411.
//
// `CacheStore` is the public interface for the backing store.  Implement it
// to plug in Redis, Memcached, or any other remote store.  `InProcessCacheStore`
// is the bundled in-process implementation backed by a mutable `Map`.
//
// Usage:
//
//   import Cache
//   import Std.Collections
//
//   var store = Cache.inProcess()
//   Cache.set(store, "users:42", userJson)
//   match Cache.get(store, "users:42") {
//     case Some(v) -> ...
//     case None    -> ...
//   }
//
// Runtime config env vars (LYRIC_CONFIG_CACHE_DEFAULTS_*):
//   LYRIC_CONFIG_CACHE_DEFAULTS_TTLSECONDS — default TTL (default: 300)
//   LYRIC_CONFIG_CACHE_DEFAULTS_MAXENTRIES — max in-process entries (default: 10000)
//
// See docs/03-decision-log.md D055 and lyric-cache/README.md.

@runtime_checked
package Cache

import Std.Core
import Std.Collections
import Std.Time

// Default configuration values.
// These replace the config block (config block emitter not yet implemented).
val defaultTtlSeconds: Int = 300
val defaultMaxEntries: Int = 10000

// ─── Store interface ──────────────────────────────────────────────────────────

// Backing store for the cache.  Implement this interface to plug in Redis,
// Memcached, or another distributed cache.  The in-process implementation is
// `InProcessCacheStore`; create one with `Cache.inProcess()`.
@stable(since="0.1")
pub interface CacheStore {
  /// Return the cached value for `key`, or `None` if missing or expired.
  func get(key: in String): Option[String]
    requires: key.length > 0

  /// Store `value` under `key` with the given TTL.
  /// `ttlSeconds = 0` means no expiry.
  func set(key: in String, value: in String, ttlSeconds: in Int): Unit
    requires: key.length > 0
    requires: ttlSeconds >= 0

  /// Remove the entry for `key`.  No-op if the key is absent.
  func delete(key: in String): Unit
    requires: key.length > 0

  /// Remove all entries from the store.
  func clear(): Unit
}

// ─── In-process implementation ────────────────────────────────────────────────

// In-process cache store backed by a mutable `Map[String, String]`.
//
// Eviction is FIFO by insertion order: when `maxEntries` is reached the
// entry inserted first (among keys not yet deleted) is removed.
//
// TTL is accepted but not enforced in v1 — entries are never evicted by
// expiry time, only by capacity.  For time-based expiry use a Redis-backed
// implementation via the `CacheStore` interface.
@stable(since="0.1")
pub record InProcessCacheStore {
  var valueMap:       Map[String, String]  // key → cached value
  maxEntries:         Int
  var insertionOrder: List[String]         // keys in FIFO insertion order; oldest first
}

impl CacheStore for InProcessCacheStore {
  func get(key: in String): Option[String] {
    if self.valueMap.containsKey(key) {
      return Some(value = self.valueMap[key])
    }
    return None
  }

  func set(key: in String, value: in String, ttlSeconds: in Int): Unit {
    val isNew = not self.valueMap.containsKey(key)
    self.valueMap[key] = value
    if isNew {
      self.insertionOrder.add(key)
    }
  }

  func delete(key: in String): Unit {
    self.valueMap.remove(key)
    self.insertionOrder.remove(key)
  }

  func clear(): Unit {
    self.valueMap.clear()
    self.insertionOrder.clear()
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

// Create an in-process store using the configured defaults.
@stable(since="0.1")
pub func inProcess(): InProcessCacheStore {
  return InProcessCacheStore(
    valueMap       = newMap(),
    maxEntries     = defaultMaxEntries,
    insertionOrder = newList())
}

// Create an in-process store with an explicit capacity limit.
@stable(since="0.1")
pub func inProcessWithCapacity(maxEntries: in Int): InProcessCacheStore
  requires: maxEntries >= 1
{
  return InProcessCacheStore(
    valueMap       = newMap(),
    maxEntries     = maxEntries,
    insertionOrder = newList())
}

// ─── Public API ───────────────────────────────────────────────────────────────

// Return the cached value for `key`, or `None`.
@stable(since="0.1")
pub func get(store: in CacheStore, key: in String): Option[String]
  requires: key.length > 0
{
  return store.get(key)
}

// Store `value` under `key` using the configured default TTL.
@stable(since="0.1")
pub func set(store: in CacheStore, key: in String, value: in String): Unit
  requires: key.length > 0
{
  store.set(key, value, defaultTtlSeconds)
}

// Store `value` under `key` with an explicit TTL in seconds (0 = no expiry).
@stable(since="0.1")
pub func setWithTtl(
  store:      in CacheStore,
  key:        in String,
  value:      in String,
  ttlSeconds: in Int
): Unit
  requires: key.length > 0
  requires: ttlSeconds >= 0
{
  store.set(key, value, ttlSeconds)
}

// Remove the entry for `key`.
@stable(since="0.1")
pub func delete(store: in CacheStore, key: in String): Unit
  requires: key.length > 0
{
  store.delete(key)
}

// Remove all entries.
@stable(since="0.1")
pub func clear(store: in CacheStore): Unit {
  store.clear()
}

