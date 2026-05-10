/// Cache.Aspects — pub aspect templates for transparent result caching.
///
/// Two templates:
///
///   FunctionCache  — B-mode: caches by `call.qualifiedName`.  Best for
///                    zero-arg or arg-independent pure functions (e.g.
///                    `loadConfig()`, `getFeatureFlags()`).
///
///   ItemCache      — C-mode (@inline_template): reads a `cacheKey: String`
///                    parameter from the handler's argument list.  Best for
///                    per-item caching (e.g. `getUser(id, cacheKey)`).
///
/// Both templates share a package-level in-process store.  Consumers who
/// need Redis or another remote store should implement `Cache.CacheStore`
/// and call `Cache.get` / `Cache.set` directly in their own aspect body.
///
/// Typical consumer usage:
///
///   import Cache.Aspects
///
///   aspect ConfigCache from Cache.Aspects.FunctionCache {
///     matches: name like "load*"
///     config { ttlSeconds: Int = 3600 }
///   }
///
///   aspect UserItemCache from Cache.Aspects.ItemCache {
///     matches: name like "getUser*"
///     config { ttlSeconds: Int = 300; keyPrefix: String = "user:" }
///   }
///
/// See docs/03-decision-log.md D055 and lyric-cache/README.md.

@runtime_checked
package Cache.Aspects

import Std.Core
import Cache

// Shared in-process store for all templates in this package.
var store = Cache.inProcess()

// ─── FunctionCache ────────────────────────────────────────────────────────────

/// Cache the return value of matched functions by their qualified name.
///
/// B-mode: the cache key is always `call.qualifiedName`, so all calls to
/// the same function share one cache slot regardless of arguments.  Only
/// suitable for functions whose return value does not depend on their
/// arguments (e.g. config loaders, feature-flag fetchers).
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled    Bool — master switch (default: true)
///   ttlSeconds Int  — per-entry TTL in seconds; 0 = no expiry (default: 300)
@stable(since="0.1")
pub aspect FunctionCache {
  config {
    enabled:    Bool = true
    ttlSeconds: Int  = 300
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = call.qualifiedName
      match Cache.get(store, key) {
        case Some(cached) ->
          ret = Ok(cached)
        case None ->
          ret = call.proceed()
          match ret {
            case Ok(value) ->
              Cache.setWithTtl(store, key, value, ttlSeconds)
            case Err(_) -> ()
          }
      }
    }
  }
}

// ─── ItemCache ────────────────────────────────────────────────────────────────

/// Cache the return value of matched functions using a `cacheKey: String`
/// parameter on the handler.
///
/// C-mode (@inline_template): body is re-compiled in the consumer's package
/// so it can read `args.cacheKey` from the concrete handler parameter list.
/// Apply only to handlers that declare a `cacheKey: String` parameter;
/// the compiler reports shape error A0042 otherwise.
///
/// The effective key is `keyPrefix + args.cacheKey`.  Only `Ok` results are
/// cached; `Err` results pass through without caching.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled    Bool   — master switch (default: true)
///   ttlSeconds Int    — per-entry TTL in seconds; 0 = no expiry (default: 300)
///   keyPrefix  String — prefix prepended to each cache key (default: "")
@stable(since="0.1")
@inline_template
pub aspect ItemCache {
  config {
    enabled:    Bool   = true
    ttlSeconds: Int    = 300
    keyPrefix:  String = ""
  }

  requires:
    args.cacheKey != ""    // handler must declare a cacheKey: String parameter

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = keyPrefix + args.cacheKey
      match Cache.get(store, key) {
        case Some(cached) ->
          ret = Ok(cached)
        case None ->
          ret = call.proceed()
          match ret {
            case Ok(value) ->
              Cache.setWithTtl(store, key, value, ttlSeconds)
            case Err(_) -> ()
          }
      }
    }
  }
}
