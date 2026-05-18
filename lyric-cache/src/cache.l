/// Cache — typed key-value cache with TTL and a pluggable store interface.
///
/// `CacheStore` is the public interface for the backing store.  Implement it
/// to plug in Redis, Memcached, or any other remote store.  `InProcessCacheStore`
/// is the bundled in-process implementation backed by a mutable `Map`.
///
/// Usage:
///
///   import Cache
///   import Std.Collections
///
///   var store = Cache.inProcess()
///   Cache.set(store, "users:42", userJson)
///   match Cache.get(store, "users:42") {
///     case Some(v) -> ...
///     case None    -> ...
///   }
///
/// Runtime config env vars (LYRIC_CONFIG_CACHE_DEFAULTS_*):
///   LYRIC_CONFIG_CACHE_DEFAULTS_TTLSECONDS — default TTL (default: 300)
///   LYRIC_CONFIG_CACHE_DEFAULTS_MAXENTRIES — max in-process entries (default: 10000)
///
/// See docs/03-decision-log.md D055 and lyric-cache/README.md.

@runtime_checked
package Cache

import Std.Core
import Std.Collections
import Std.Time

// ─── Store interface ──────────────────────────────────────────────────────────

/// Backing store for the cache.  Implement this interface to plug in Redis,
/// Memcached, or another distributed cache.  The in-process implementation is
/// `InProcessCacheStore`; create one with `Cache.inProcess()`.
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

/// A single entry in the in-process store.
record CacheEntry {
  value:      String
  expiresAt:  Long    // epoch millis; 0 = no expiry
  insertedAt: Long    // monotonic insertion counter for LRU eviction order
}

/// In-process cache store backed by a mutable `Map`.
///
/// Not thread-safe in v1.  For concurrent access, wrap in a `protected type`
/// once the protected-type weaver ships, or use a Redis-backed implementation.
@stable(since="0.1")
pub record InProcessCacheStore {
  var entries:    Map[String, CacheEntry]
  maxEntries: Int
  var insertionCounter: Long    // monotonically increasing; used for LRU eviction
}

impl CacheStore for InProcessCacheStore {
  func get(key: in String): Option[String] {
    val nowMs = Std.Time.SystemClock.now().toEpochMillis()
    match entries.get(key) {
      case Some(entry) ->
        if entry.expiresAt == 0 or entry.expiresAt > nowMs {
          Some(entry.value)
        } else {
          // Sweep the expired entry on read so read-mostly workloads
          // don't accumulate stale entries indefinitely.
          entries.remove(key)
          None
        }
      case None -> None
    }
  }

  func set(key: in String, value: in String, ttlSeconds: in Int): Unit {
    val nowMs   = Std.Time.SystemClock.now().toEpochMillis()
    val expires = if ttlSeconds == 0 then 0 else nowMs + (ttlSeconds * 1000)
    if entries.count >= maxEntries {
      evictOldest(entries)
    }
    insertionCounter = insertionCounter + 1
    entries.set(key, CacheEntry(
      value      = value,
      expiresAt  = expires,
      insertedAt = insertionCounter))
  }

  func delete(key: in String): Unit {
    entries.remove(key)
  }

  func clear(): Unit {
    entries.clear()
  }
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// Default TTL and in-process store capacity.
config Defaults {
  ttlSeconds: Int range 0 ..= 86400    = 300
  maxEntries: Int range 1 ..= 1000000  = 10000
}

// ─── Factory ──────────────────────────────────────────────────────────────────

/// Create an in-process store using the configured defaults.
@stable(since="0.1")
pub func inProcess(): InProcessCacheStore {
  return InProcessCacheStore(
    entries          = Map.empty(),
    maxEntries       = Defaults.maxEntries,
    insertionCounter = 0)
}

/// Create an in-process store with an explicit capacity limit.
@stable(since="0.1")
pub func inProcessWithCapacity(maxEntries: in Int): InProcessCacheStore
  requires: maxEntries >= 1
{
  return InProcessCacheStore(
    entries          = Map.empty(),
    maxEntries       = maxEntries,
    insertionCounter = 0)
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Return the cached value for `key`, or `None`.
@stable(since="0.1")
pub func get(store: in CacheStore, key: in String): Option[String]
  requires: key.length > 0
{
  return store.get(key)
}

/// Store `value` under `key` using the configured default TTL.
@stable(since="0.1")
pub func set(store: in CacheStore, key: in String, value: in String): Unit
  requires: key.length > 0
{
  store.set(key, value, Defaults.ttlSeconds)
}

/// Store `value` under `key` with an explicit TTL in seconds (0 = no expiry).
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

/// Remove the entry for `key`.
@stable(since="0.1")
pub func delete(store: in CacheStore, key: in String): Unit
  requires: key.length > 0
{
  store.delete(key)
}

/// Remove all entries.
@stable(since="0.1")
pub func clear(store: in CacheStore): Unit {
  store.clear()
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Remove the entry with the smallest insertedAt counter (oldest insertion).
// This implements FIFO eviction (first inserted, first evicted), which is correct
// regardless of whether entries have TTLs.  Previously the code evicted by expiresAt,
// which was backwards (shortest TTL first) and silently no-oped when every
// entry had expiresAt == 0 (no-expiry), allowing the map to exceed maxEntries.
func evictOldest(entries: inout Map[String, CacheEntry]): Unit {
  var minKey       = ""
  var minInserted  = Long.maxValue
  for (k, e) in entries {
    if minKey == "" or e.insertedAt < minInserted {
      minKey      = k
      minInserted = e.insertedAt
    }
  }
  if minKey.length > 0 {
    entries.remove(minKey)
  }
}
