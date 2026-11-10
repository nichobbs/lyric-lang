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
//! Thread safety: the registry is a protected type, so registering and checking
//! flags from several threads is safe (#8950).
@runtime_checked
@io
package Flags.Registry

import Std.Core
import Std.Collections

protected type FlagRegistryStore {
  var boolMap: Map[String, Bool] = newMap()
  var stringMap: Map[String, String] = newMap()
  entry boolFlag(name: in String, defaultValue: in Bool): Bool {
    if boolMap.containsKey(name) {
      return boolMap[name]
    }
    return defaultValue
  }
  entry stringFlag(name: in String, defaultValue: in String): String {
    if stringMap.containsKey(name) {
      return stringMap[name]
    }
    return defaultValue
  }
  entry setBool(name: in String, value: in Bool) {
    boolMap[name] = value
  }
  entry setString(name: in String, value: in String) {
    stringMap[name] = value
  }
}

// A module-level `val` initialised through a same-package factory (the
// pattern every other module-level store in this codebase uses).
func newRegistryStore(): FlagRegistryStore {
  return FlagRegistryStore()
}

val globalRegistry: FlagRegistryStore = newRegistryStore()

/// Return the Bool value of a named flag, or `defaultValue` if absent.
@stable(since = "0.1")
pub func checkFlag(name: in String, defaultValue: in Bool): Bool {
  return globalRegistry.boolFlag(name, defaultValue)
}

/// Return the String value of a named flag, or `defaultValue` if absent.
@stable(since = "0.1")
pub func getStringFlag(name: in String, defaultValue: in String): String {
  return globalRegistry.stringFlag(name, defaultValue)
}

/// Register (or overwrite) a Bool flag in the process-global registry.
@stable(since = "0.1")
pub func registerBoolFlag(name: in String, value: in Bool): Unit
  requires: name.length > 0
{
  globalRegistry.setBool(name, value)
}

/// Register (or overwrite) a String flag in the process-global registry.
@stable(since = "0.1")
pub func registerStringFlag(name: in String, value: in String): Unit
  requires: name.length > 0
{
  globalRegistry.setString(name, value)
}
