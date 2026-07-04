//! Cache.Aspects — config types and helpers for transparent result caching.
//!
//! The aspect weaver (docs/26-aspects.md) has shipped — B-mode (D047),
//! B'-mode row-typed args (D114/D115/D118) — and sibling libraries
//! (Db.Aspects, Storage.Aspects, Mq.Aspects) already ship real `pub aspect`
//! templates on top of it. This file has not yet been converted: it still
//! only defines config records (FunctionCacheConfig, ItemCacheConfig) and
//! their factory functions. Until the FunctionCache (B-mode, keyed on
//! call.qualifiedName) and ItemCache (B'-mode, row-constrained on a
//! cacheKey field) templates described by these configs are actually
//! written, callers should use Cache.get / Cache.set / Cache.setWithTtl
//! directly, or consult the typed config records below to construct
//! equivalent call-site logic.
//!
//! See docs/03-decision-log.md D055, docs/57-stdlib-ecosystem-library-review.md
//! §4, and lyric-cache/README.md.
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
@stable(since = "0.1")
pub record FunctionCacheConfig {
  enabled: Bool
  ttlSeconds: Int
}

/// Return the default FunctionCache configuration (enabled, 300 s TTL).
@stable(since = "0.1")
pub func defaultFunctionCacheConfig(): FunctionCacheConfig {
  return FunctionCacheConfig(enabled = true, ttlSeconds = 300)
}

// ─── ItemCache ────────────────────────────────────────────────────────────────
/// Configuration for the ItemCache aspect template.
///
/// ItemCache caches per-item using a caller-supplied key (C-mode).
/// The effective cache key is `keyPrefix + cacheKey`.
@stable(since = "0.1")
pub record ItemCacheConfig {
  enabled: Bool
  ttlSeconds: Int
  keyPrefix: String
}

/// Return the default ItemCache configuration (enabled, 300 s TTL, no prefix).
@stable(since = "0.1")
pub func defaultItemCacheConfig(): ItemCacheConfig {
  return ItemCacheConfig(enabled = true, ttlSeconds = 300, keyPrefix = "")
}
