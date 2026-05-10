# lyric-cache

Typed key-value cache with TTL and a pluggable `CacheStore` interface.

## Packages

| Package | Purpose |
|---|---|
| `Cache` | Core types, `CacheStore` interface, in-process implementation, and public API |
| `Cache.Aspects` | Reusable aspect templates: `FunctionCache` and `ItemCache` |

## Quick start

```lyric
import Cache

val store = Cache.inProcess()

Cache.set(store, "greeting", "hello")

match Cache.get(store, "greeting") {
  case Some(v) -> println(v)          // "hello"
  case None    -> println("miss")
}

Cache.setWithTtl(store, "token", accessToken, 300)  // expires in 300 s
```

## CacheStore interface

`CacheStore` is a pluggable interface so you can swap out the backing store:

```lyric
pub interface CacheStore {
  func get(key: in String): Option[String]
  func set(key: in String, value: in String, ttlSeconds: in Int): Unit
  func delete(key: in String): Unit
  func clear(): Unit
}
```

The v1 implementation is `InProcessCacheStore` (in-memory, single-process).
Implement `CacheStore` for Redis, Memcached, or any other backend and pass
the implementation to your own aspect body or helper functions.

## In-process store

`Cache.inProcess()` creates a store using runtime config defaults:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_CACHE_DEFAULTS_TTLSECONDS` | `300` | Default TTL in seconds (0 = no expiry) |
| `LYRIC_CONFIG_CACHE_DEFAULTS_MAXENTRIES` | `10000` | LRU eviction threshold |

`Cache.inProcessWithCapacity(n)` creates a store with a specific max-entry limit,
using the config default TTL.

## API reference

```lyric
Cache.get(store, key)                    // Option[String]
Cache.set(store, key, value)             // Unit — uses config default TTL
Cache.setWithTtl(store, key, value, ttl) // Unit — explicit TTL in seconds
Cache.delete(store, key)                 // Unit
Cache.clear(store)                       // Unit
```

All keys must be non-empty strings. TTL `0` means no expiry.

## Aspect templates (`Cache.Aspects`)

### FunctionCache

B-mode: caches the return value of matched functions by their qualified name.
Best for zero-arg or arg-independent pure functions.

```lyric
import Cache.Aspects

aspect ConfigCache from Cache.Aspects.FunctionCache {
  matches: name like "load*"
  config { ttlSeconds: Int = 3600 }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `ttlSeconds` | `Int` | `300` | Cache TTL; 0 = no expiry |

### ItemCache

C-mode (`@inline_template`): reads a `cacheKey: String` parameter from the
matched handler's argument list. Best for per-item caching.

```lyric
aspect UserCache from Cache.Aspects.ItemCache {
  matches: name like "getUser*"
  config { ttlSeconds: Int = 300; keyPrefix: String = "user:" }
}

// Handler must declare cacheKey: String
func getUser(id: in String, cacheKey: in String): Result[User, ApiError] { ... }
```

If the matched handler does not declare `cacheKey: String`, the compiler
reports shape error A0042.

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `ttlSeconds` | `Int` | `300` | Cache TTL; 0 = no expiry |
| `keyPrefix` | `String` | `""` | Prefix prepended to each key |

## Decision log

See `docs/03-decision-log.md` D055.
