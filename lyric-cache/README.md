# lyric-cache

**Stability:** `stable`

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

`InProcessCacheStore` is thread-safe. It is a `protected type` that implements
`CacheStore`, so every `get`/`set`/`delete`/`clear` runs under the store's
instance lock and one store can be shared between threads (the aspect stores
`functionCacheStore` and `itemCacheStore` are process-wide). Each operation is
atomic, but a sequence of separate calls is not: a `get` followed by a `set`
can interleave with another thread, so two threads may both miss and both
compute. `tests/cache_concurrency_{dotnet,jvm}_tests.l` hammer one store from
four real threads on each target.

## In-process store

`Cache.inProcess()` creates a store using runtime config defaults:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_CACHE_DEFAULTS_TTLSECONDS` | `300` | Default TTL in seconds (0 = no expiry) |
| `LYRIC_CONFIG_CACHE_DEFAULTS_MAXENTRIES` | `10000` | LRU eviction threshold |

`Cache.inProcessWithCapacity(n)` creates a store with a specific max-entry limit
(`n >= 1`; there is no "0 or negative means unbounded" mode — use a large
explicit `n`, e.g. `Int.maxValue`, for an effectively unbounded store), using
the config default TTL.

`InProcessCacheStore` carries an invariant — `maxEntries >= 1` and
`insertionOrder.count == valueMap.count` — which, as for any protected type, the
compiler checks after every member returns. The factories reject `maxEntries < 1`
with a `requires:` clause; constructing the type directly with an invalid
capacity panics on its first operation rather than at construction.

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
Best for zero-arg or arg-independent pure functions. The matched handler's
return type must be `Result[String, E]` — the cached payload is the `Ok`
string; `Err` results are never cached.

```lyric
import Cache.Aspects

aspect ConfigCache from Cache.Aspects.FunctionCache {
  matches: name like "load*"
  config { ttlSeconds: Int = 3600 }
}

func loadConfig(): Result[String, ConfigError] { ... }
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `ttlSeconds` | `Int range 0 ..= 31536000` | `300` | Cache TTL in seconds, up to 1 year; `0` means no expiry, as for `Cache.setWithTtl` (entries stay bounded by the store's FIFO capacity). An out-of-range default or override is a compile-time `G0010`. |

### ItemCache

Row-constrained B'-mode (docs/56 / D115): reads a `cacheKey: String`
parameter from the matched handler's argument list via a
`where TArgs has { cacheKey: String }` row clause. Best for per-item caching.
The matched handler's return type must also be `Result[String, E]`, for the
same reason as FunctionCache above.

```lyric
aspect UserCache from Cache.Aspects.ItemCache {
  matches: name like "getUser*"
  config { ttlSeconds: Int = 300; keyPrefix: String = "user:" }
}

// Handler must declare cacheKey: String
func getUser(id: in String, cacheKey: in String): Result[String, ApiError] { ... }
```

If the matched handler does not declare `cacheKey: String`, the weaver
reports row-constraint error A0047.

The effective cache key is `call.qualifiedName + ":" + keyPrefix +
args.cacheKey` — the `qualifiedName` component is load-bearing, not
cosmetic: `ItemCache`'s backing store is one process-wide store shared by
every `ItemCache` instantiation, so without it two differently-matched
handlers (or a single wildcard `matches:` pattern covering several
handlers, as above) could collide on an identical `cacheKey`.

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `ttlSeconds` | `Int range 0 ..= 31536000` | `300` | Cache TTL in seconds, up to 1 year; `0` means no expiry. |
| `keyPrefix` | `String` | `""` | Prefix prepended to each key |

## Decision log

See `docs/03-decision-log.md` D055.
