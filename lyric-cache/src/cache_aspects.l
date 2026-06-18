// Cache.Aspects — config types and helpers for transparent result caching.
//
// Two aspect templates are defined here as records + helper functions.
// The full aspect-weaver wiring (B-mode / C-mode, around(call), config
// injection) requires the aspect system described in docs/26-aspects.md and
// is deferred until that system ships.  Until then, callers should use
// Cache.get / Cache.set / Cache.setWithTtl directly, or consult
// the typed config records below to construct equivalent call-site logic.
//
// See docs/03-decision-log.md D055 and lyric-cache/README.md.

@runtime_checked
package Cache.Aspects

import Std.Core
import Cache

// ─── FunctionCache ────────────────────────────────────────────────────────────

/// Configuration for the FunctionCache aspect template.
///
/// FunctionCache caches by `qualifiedName` (B-mode): all calls to the same
/// function share one cache slot regardless of arguments.  Suitable for
/// functions whose return value is argument-independent.
@stable(since="0.1")
pub record FunctionCacheConfig {
  enabled:    Bool
  ttlSeconds: Int
}

/// Return the default FunctionCache configuration (enabled, 300 s TTL).
@stable(since="0.1")
pub func defaultFunctionCacheConfig(): FunctionCacheConfig {
  return FunctionCacheConfig(enabled = true, ttlSeconds = 300)
}

// ─── ItemCache ────────────────────────────────────────────────────────────────

/// Configuration for the ItemCache aspect template.
///
/// ItemCache caches per-item using a caller-supplied key (C-mode).
/// The effective cache key is `keyPrefix + cacheKey`.
@stable(since="0.1")
pub record ItemCacheConfig {
  enabled:    Bool
  ttlSeconds: Int
  keyPrefix:  String
}

/// Return the default ItemCache configuration (enabled, 300 s TTL, no prefix).
@stable(since="0.1")
pub func defaultItemCacheConfig(): ItemCacheConfig {
  return ItemCacheConfig(enabled = true, ttlSeconds = 300, keyPrefix = "")
}
