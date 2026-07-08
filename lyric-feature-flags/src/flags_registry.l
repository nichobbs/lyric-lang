//! Flags.Registry — process-global flag registry for aspect use.
//!
//! Backed by plain Lyric `Map`s (`Std.Collections`), not an extern boundary:
//! modelling "map of flag name to value" needs no BCL/JDK object reference,
//! so this package is pure Lyric and behaves identically on every
//! compilation target.  It used to be an `extern package lyric.flags.Registry`
//! declaration in `_kernel/net` and `_kernel/jvm`; `extern package` never
//! resolves to a real binding on either backend (issue #5324), so the
//! registry was silently a no-op that always returned `defaultValue` — never
//! noticed because `Flags.Aspects.FlagGated` (the only caller) was never
//! applied anywhere in the repo.  See `lyric-feature-flags/tests/
//! flags_aspect_weaving_tests.l` for the regression coverage that would have
//! caught this.
//!
//! `Flags.Aspects.FlagGated` / `FlagVariant` read from this registry because
//! they cannot carry a `FlagStore` reference through aspect config; register
//! flags here at application startup with `registerBoolFlag` /
//! `registerStringFlag`.
//!
//! WARNING (thread safety): NOT thread-safe.  Concurrent register/check calls
//! from multiple threads produce undefined behaviour (lost updates, torn
//! reads).  Until the `protected type` weaver ships, wrap access in an
//! external mutex if the process registers flags concurrently with checking
//! them.  Mirrors the same caveat on `Flags.InProcessFlagStore` and
//! `Cache.InProcessCacheStore` (lyric-lang #411).
@runtime_checked
package Flags.Registry

import Std.Core
import Std.Collections

record FlagRegistryStore {
  var boolMap: Map[String, Bool]
  var stringMap: Map[String, String]
}

// A module-level `val` initialized directly with a record literal that
// carries a generic `Map` field crashes the self-hosted MSIL lowering pass
// (`Msil.Lowering.dictTokensForLowering: Dictionary`2 TypeRef not seeded`);
// routing the construction through a same-package factory function avoids
// it, matching the pattern every other module-level store instance in this
// codebase already uses (e.g. `Cache.inProcess()`,
// `Cache.Aspects.functionCacheStore`).
func newRegistryStore(): FlagRegistryStore {
  return FlagRegistryStore(boolMap = newMap(), stringMap = newMap())
}

val globalRegistry: FlagRegistryStore = newRegistryStore()

/// Return the Bool value of a named flag, or `defaultValue` if absent.
@stable(since = "0.1")
pub func checkFlag(name: in String, defaultValue: in Bool): Bool {
  match mapGet(globalRegistry.boolMap, name) {
    case Some(v) -> return v
    case None -> return defaultValue
  }
}

/// Return the String value of a named flag, or `defaultValue` if absent.
@stable(since = "0.1")
pub func getStringFlag(name: in String, defaultValue: in String): String {
  match mapGet(globalRegistry.stringMap, name) {
    case Some(v) -> return v
    case None -> return defaultValue
  }
}

/// Register (or overwrite) a Bool flag in the process-global registry.
@stable(since = "0.1")
pub func registerBoolFlag(name: in String, value: in Bool): Unit {
  globalRegistry.boolMap[name] = value
}

/// Register (or overwrite) a String flag in the process-global registry.
@stable(since = "0.1")
pub func registerStringFlag(name: in String, value: in String): Unit {
  globalRegistry.stringMap[name] = value
}
