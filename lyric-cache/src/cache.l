//! Cache — typed key-value cache with TTL and a pluggable store interface.
//! Stability: @experimental — the surface compiles and the in-memory store has
//! tests, but the redis-backed store has not been driven against a live
//! cluster in CI.
//!
//! WARNING (thread safety): `InProcessCacheStore` is NOT thread-safe.  Concurrent
//! access from multiple threads produces undefined behaviour (lost updates,
//! torn reads).  Until the `protected type` weaver ships, multi-threaded
//! services should use a Redis-backed store (`Lyric.Cache.Redis`) or guard
//! access with an external mutex.  See lyric-lang #411.
//!
//! `CacheStore` is the public interface for the backing store.  Implement it
//! to plug in Redis, Memcached, or any other remote store.  `InProcessCacheStore`
//! is the bundled in-process implementation backed by a mutable `Map`.
//!
//! Usage:
//!
//!   import Cache
//!   import Std.Collections
//!
//!   var store = Cache.inProcess()
//!   Cache.set(store, "users:42", userJson)
//!   match Cache.get(store, "users:42") {
//!     case Some(v) -> ...
//!     case None    -> ...
//!   }
//!
//! Runtime config env vars (LYRIC_CONFIG_CACHE_DEFAULTS_*):
//!   LYRIC_CONFIG_CACHE_DEFAULTS_TTLSECONDS — default TTL (default: 300)
//!   LYRIC_CONFIG_CACHE_DEFAULTS_MAXENTRIES — max in-process entries (default: 10000)
//!
//! See docs/03-decision-log.md D055 and lyric-cache/README.md.
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
@stable(since = "0.1")
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
// Eviction is by whichever bound is hit first:
//   - FIFO capacity: when `maxEntries` is reached the entry inserted first
//     (among keys not yet deleted) is removed.
//   - TTL expiry: a key set with `ttlSeconds > 0` is treated as absent by
//     `get` once `Std.Time.nowEpochMillis()` passes its recorded expiry
//     timestamp, and is evicted from all three backing collections at that
//     point. `ttlSeconds == 0` means no expiry (the key is never
//     TTL-evicted, only FIFO-evicted). Expiry is stored as epoch
//     milliseconds (`Long`) rather than `Instant` — `Instant` is an extern
//     struct (`System.DateTime`) and boxing it into a `Map`'s type-erased
//     backing store is not yet a supported combination in the self-hosted
//     MSIL emitter (`ilverify` StackUnexpected on the boxed field read).
@stable(since = "0.1")
pub record InProcessCacheStore {
  var valueMap: Map[String, String]  // key → cached value
  maxEntries: Int
  var insertionOrder: List[String]         // keys in FIFO insertion order; oldest first
  var expiryMap: Map[String, Long]  // key → expiry epoch millis; absent means no expiry
}

// Remove `key` from all three backing collections of `store`. Shared by
// `delete` and by `get`'s lazy TTL-expiry eviction.
func evictKey(store: in InProcessCacheStore, key: in String): Unit {
  store.valueMap.remove(key)
  store.expiryMap.remove(key)
  // Remove `key` from the insertion order by index: `List.remove(value)` is
  // not a supported element-removal intrinsic on the MSIL backend (it lowers
  // to a no-op), so a value-based remove would silently leave a stale entry
  // and corrupt the FIFO eviction bound.  Scan for the index and `removeAt`.
  var idx = 0
  var found = 0 - 1
  while idx < store.insertionOrder.count {
    if store.insertionOrder[idx] == key {
      found = idx
      idx = store.insertionOrder.count
    } else {
      idx = idx + 1
    }
  }
  if found >= 0 {
    store.insertionOrder.removeAt(found)
  }
}

impl CacheStore for InProcessCacheStore {
  func get(key: in String): Option[String] {
    if not self.valueMap.containsKey(key) {
      return None
    }
    if self.expiryMap.containsKey(key) {
      val expiresAtMillis = self.expiryMap[key]
      if nowEpochMillis() >= expiresAtMillis {
        evictKey(self, key)
        return None
      }
    }
    return Some(value = self.valueMap[key])
  }

  func set(key: in String, value: in String, ttlSeconds: in Int): Unit {
    val isNew = not self.valueMap.containsKey(key)
    // FIFO capacity bound: before inserting a *new* key into a full store,
    // evict the oldest (front of the insertion order).  `maxEntries <= 0`
    // disables the bound.
    if isNew and self.maxEntries > 0 and self.insertionOrder.count >= self.maxEntries {
      val oldest = self.insertionOrder[0]
      self.valueMap.remove(oldest)
      self.expiryMap.remove(oldest)
      self.insertionOrder.removeAt(0)
    }
    self.valueMap[key] = value
    if isNew {
      self.insertionOrder.add(key)
    }
    if ttlSeconds > 0 {
      self.expiryMap[key] = nowEpochMillis() + ttlSeconds.toLong() * 1000i64
    } else if self.expiryMap.containsKey(key) {
      // Re-`set` of a previously-TTL'd key with ttlSeconds = 0 makes it
      // permanent again; drop the stale expiry entry.
      self.expiryMap.remove(key)
    }
  }

  func delete(key: in String): Unit {
    evictKey(self, key)
  }

  func clear(): Unit {
    // Reset to fresh empty collections.  Records are reference types, so the
    // field reassignment is visible through the `CacheStore` borrow at the call
    // site.  (In-place `Map.clear()` / `List.clear()` are not yet supported
    // intrinsics on the MSIL backend; reassignment is the idiomatic reset.)
    self.valueMap = newMap()
    self.insertionOrder = newList()
    self.expiryMap = newMap()
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────
// Create an in-process store using the configured defaults.
@stable(since = "0.1")
pub func inProcess(): InProcessCacheStore {
  return InProcessCacheStore(
    valueMap = newMap(),
    maxEntries = defaultMaxEntries,
    insertionOrder = newList(),
    expiryMap = newMap()
  )
}

// Create an in-process store with an explicit capacity limit.
@stable(since = "0.1")
pub func inProcessWithCapacity(maxEntries: in Int): InProcessCacheStore
  requires: maxEntries >= 1
{
  return InProcessCacheStore(
    valueMap = newMap(),
    maxEntries = maxEntries,
    insertionOrder = newList(),
    expiryMap = newMap()
  )
}

// ─── Public API ───────────────────────────────────────────────────────────────
// Return the cached value for `key`, or `None`.
@stable(since = "0.1")
pub func get(store: in CacheStore, key: in String): Option[String]
  requires: key.length > 0
{
  return store.get(key)
}

// Store `value` under `key` using the configured default TTL.
@stable(since = "0.1")
pub func set(store: in CacheStore, key: in String, value: in String): Unit
  requires: key.length > 0
{
  store.set(key, value, defaultTtlSeconds)
}

// Store `value` under `key` with an explicit TTL in seconds (0 = no expiry).
@stable(since = "0.1")
pub func setWithTtl(store: in CacheStore, key: in String, value: in String, ttlSeconds: in Int): Unit
  requires: key.length > 0
  requires: ttlSeconds >= 0
{
  store.set(key, value, ttlSeconds)
}

// Remove the entry for `key`.
@stable(since = "0.1")
pub func delete(store: in CacheStore, key: in String): Unit
  requires: key.length > 0
{
  store.delete(key)
}

// Remove all entries.
@stable(since = "0.1")
pub func clear(store: in CacheStore): Unit {
  store.clear()
}
