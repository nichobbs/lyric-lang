# Chapter 25: Caching

The `lyric-cache` library provides a typed, TTL-aware key-value cache.  The
v1 implementation is in-process; the `CacheStore` interface lets you swap in
Redis or another remote store without changing application code.

## Adding the dependency

```toml
# lyric.toml
[dependencies]
"Lyric.Cache" = { path = "../lyric-cache" }
```

## Basic usage

```lyric
import Cache

val store = Cache.inProcess()

Cache.set(store, "greeting", "hello")

match Cache.get(store, "greeting") {
  case Some(v) -> println(v)
  case None    -> println("miss")
}

Cache.setWithTtl(store, "session", token, 300)  // expires in 300 s
```

## API reference

```lyric
Cache.get(store, key)                    // Option[String]
Cache.set(store, key, value)             // Unit — uses config default TTL
Cache.setWithTtl(store, key, value, ttl) // Unit — explicit TTL in seconds
Cache.delete(store, key)                 // Unit
Cache.clear(store)                       // Unit
```

TTL `0` means no expiry.

## The CacheStore interface

`CacheStore` is the extension point for custom backends:

```lyric
pub interface CacheStore {
  func get(key: in String): Option[String]
  func set(key: in String, value: in String, ttlSeconds: in Int): Unit
  func delete(key: in String): Unit
  func clear(): Unit
}
```

Implement this interface for Redis, Memcached, or a test double.

## In-process store

`Cache.inProcess()` creates a store using runtime config defaults:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_CACHE_DEFAULTS_TTLSECONDS` | `300` | Default TTL in seconds |
| `LYRIC_CONFIG_CACHE_DEFAULTS_MAXENTRIES` | `10000` | LRU eviction threshold |

Use `Cache.inProcessWithCapacity(n)` to specify a per-store entry limit:

```lyric
val smallStore = Cache.inProcessWithCapacity(1000)
```

## Aspect templates

### FunctionCache

Cache the return value of matched functions by their qualified name.  Best for
zero-arg or arg-independent loaders (config, feature flags).

```lyric
import Cache.Aspects

aspect ConfigCache from Cache.Aspects.FunctionCache {
  matches: name like "load*"
  config { ttlSeconds: Int = 3600 }
}
```

All calls to the same matched function share one cache slot.

### ItemCache

Cache per-item results using a `cacheKey: String` parameter on the handler.
Apply this template only to handlers that declare `cacheKey: String`; the
compiler reports error A0042 otherwise.

```lyric
aspect UserCache from Cache.Aspects.ItemCache {
  matches: name like "getUser*"
  config { ttlSeconds: Int = 300; keyPrefix: String = "user:" }
}

// Handler must declare cacheKey:
func getUser(id: in String, cacheKey: in String): Result[User, ApiError] {
  // ...
}
```

The effective key is `keyPrefix + args.cacheKey`.

## Aspect config reference

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Applies to |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Both templates |
| `ttlSeconds` | `Int` | `300` | Both templates |
| `keyPrefix` | `String` | `""` | `ItemCache` only |

## Shared store across aspect instantiations

All templates in `Cache.Aspects` (`FunctionCache`, `ItemCache`) share a single
module-level `InProcessCacheStore`.  If you instantiate both templates, or
instantiate the same template twice with different TTLs, both instantiations
read from and write to the same store.  Two instantiations with different
`ttlSeconds` values will both write to the same key if their matched functions
produce the same cache key; whichever `set` call runs last wins.

If you need per-aspect isolation — for example, a short-TTL store for session
data and a long-TTL store for config — write a custom aspect body that
constructs its own `Cache.inProcess()` store rather than using a template.

> **Note:** The in-process store is not thread-safe.  For concurrent access,
> use a Redis-backed `CacheStore` implementation, or wrap your own in-process
> store in a `protected type` (Chapter 10 §10.4) to serialise access.

## Custom store example

```lyric
import Cache

// Implement CacheStore for a Redis client:
record RedisStore { client: RedisClient }

impl Cache.CacheStore for RedisStore {
  func get(key: in String): Option[String] {
    RedisClient.get(client, key)
  }
  func set(key: in String, value: in String, ttlSeconds: in Int): Unit {
    RedisClient.set(client, key, value, ttlSeconds)
  }
  func delete(key: in String): Unit {
    RedisClient.del(client, key)
  }
  func clear(): Unit {
    RedisClient.flushDb(client)
  }
}

// Use it like the in-process store:
val store: Cache.CacheStore = RedisStore(client = redisClient)
Cache.set(store, "key", "value")
```
