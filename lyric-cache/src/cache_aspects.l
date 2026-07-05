//! Cache.Aspects — pub aspect templates for transparent result caching.
//!
//! Two templates, both applying to handlers returning `Result[String, E]`
//! (the cached payload is the `Ok` string; errors are never cached):
//!
//!   FunctionCache — B-mode: caches by `call.qualifiedName`. All calls to
//!                   the same matched function share one cache slot
//!                   regardless of arguments — suitable for functions whose
//!                   return value is argument-independent.
//!
//!   ItemCache     — row-constrained B'-mode (docs/56 / D115): reads
//!                   `args.cacheKey` via a `where TArgs has { cacheKey:
//!                   String }` row clause. The handler must declare a
//!                   `cacheKey: String` parameter; the effective cache key
//!                   is `call.qualifiedName + ":" + keyPrefix +
//!                   args.cacheKey` — the function-identity component keeps
//!                   two differently-matched handlers (or one wildcard
//!                   `matches:` covering several handlers) from colliding
//!                   on the same `cacheKey`, since `itemCacheStore` is one
//!                   process-wide store shared by every `ItemCache`
//!                   instantiation.
//!
//! Typical consumer usage:
//!
//!   import Cache.Aspects
//!
//!   aspect PriceLookupCache from Cache.Aspects.FunctionCache {
//!     matches: name like "fetchExchangeRates*"
//!     config { ttlSeconds: Int = 60 }
//!   }
//!
//!   aspect ProductCache from Cache.Aspects.ItemCache {
//!     matches: name like "loadProduct*"
//!     config { ttlSeconds: Int = 120, keyPrefix: String = "product:" }
//!   }
//!
//! See docs/03-decision-log.md D055, docs/57-stdlib-ecosystem-library-review.md
//! §4, and lyric-cache/README.md.
@runtime_checked
package Cache.Aspects

import Std.Core
import Cache

// ─── FunctionCache ────────────────────────────────────────────────────────────
/// Cache a matched handler's result by `call.qualifiedName` (B-mode).
///
/// The handler's return type must be `Result[String, E]` for this aspect to
/// compose correctly — the cached value is the `Ok` payload string; `Err`
/// results are passed through and never cached (a transient failure
/// shouldn't poison the cache for every other caller of the same function).
///
/// Logic:
///   1. Compute the cache key as `call.qualifiedName`.
///   2. If present in the cache, return `Ok(cachedValue)` without calling
///      the handler.
///   3. Otherwise call the handler (`call.proceed()`).
///   4. On `Ok(value)`, cache `value` with `ttlSeconds` TTL.
///   5. On `Err`, pass the error through unchanged (do not cache failures).
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled    Bool — master switch (default: true)
///   ttlSeconds Int  — how long a cached result is reused (default: 300)
@stable(since = "0.1")
pub aspect FunctionCache {
  config {
    enabled: Bool = true
    ttlSeconds: Int = 300
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = call.qualifiedName
      match Cache.get(functionCacheStore, key) {
        case Some(cached) -> {
          ret = Ok(cached)
        }
        case None -> {
          ret = call.proceed()
          match ret {
            case Ok(value) -> Cache.setWithTtl(functionCacheStore, key, value, ttlSeconds)
            case Err(_) -> ()
          }
        }
      }
    }
  }
}

// Module-level in-process cache shared by all FunctionCache instances.
val functionCacheStore: CacheStore = Cache.inProcess()

// ─── ItemCache ────────────────────────────────────────────────────────────────
/// Cache a matched handler's result by a caller-supplied per-item key.
///
/// Row-constrained B'-mode (docs/56 / D115): reads `args.cacheKey` via a
/// `where TArgs has { cacheKey: String }` row clause.  The handler must
/// declare a `cacheKey: String` parameter; the weaver reports A0047 if it
/// is absent or mistyped.  A `requires: args.cacheKey != ""` contract
/// (elaborated to a runtime assert in this `@runtime_checked` module, per
/// `Storage.Aspects.ValidateKey`'s precedent) rejects an empty `cacheKey`
/// before the handler runs.
///
/// The handler's return type must be `Result[String, E]` for this aspect to
/// compose correctly, for the same reason as FunctionCache above.
///
/// Logic:
///   1. Compute the cache key as `call.qualifiedName + ":" + keyPrefix +
///      args.cacheKey`. The `qualifiedName` component is required, not
///      cosmetic: `itemCacheStore` is one process-wide store shared by
///      every `ItemCache` instantiation, so without it two differently
///      matched handlers called with the same `cacheKey` (or a single
///      wildcard `matches:` pattern covering several handlers) would
///      silently return each other's cached values.
///   2. If present in the cache, return `Ok(cachedValue)` without calling
///      the handler.
///   3. Otherwise call the handler (`call.proceed()`).
///   4. On `Ok(value)`, cache `value` with `ttlSeconds` TTL.
///   5. On `Err`, pass the error through unchanged (do not cache failures).
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled    Bool   — master switch (default: true)
///   ttlSeconds Int    — how long a cached result is reused (default: 300)
///   keyPrefix  String — prepended to every cacheKey (default: "")
@stable(since = "0.1")
pub aspect ItemCache {
  config {
    enabled: Bool = true
    ttlSeconds: Int = 300
    keyPrefix: String = ""
  }
  requires: args.cacheKey != ""
  // handler must declare a cacheKey: String parameter
  around(call) -> ret where TArgs has { cacheKey: String } {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = call.qualifiedName + ":" + keyPrefix + args.cacheKey
      match Cache.get(itemCacheStore, key) {
        case Some(cached) -> {
          ret = Ok(cached)
        }
        case None -> {
          ret = call.proceed()
          match ret {
            case Ok(value) -> Cache.setWithTtl(itemCacheStore, key, value, ttlSeconds)
            case Err(_) -> ()
          }
        }
      }
    }
  }
}

// Module-level in-process cache shared by all ItemCache instances.
val itemCacheStore: CacheStore = Cache.inProcess()
