//! build_carry.l - parameter and field defaults read from the interfaces of the
//! packages a package was built against (docs/70 §6.3, §9.2, D482).  A default
//! is built from its own package's checker tables, so its symbols are that
//! package's; the consumer reads the declaring package's interface with its
//! own `DefPathInterner`, which numbers the default's symbols (and the
//! declarations it names) as the consumer's own.
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Symbols
import Lyric.Tir
import Lyric.Iface

/// The encoded interfaces of the packages a build was checked against, by package name: those
/// built earlier in the same build (registered as each is built) and those of restored
/// dependencies (registered as the build loads them).  One store is shared by the options of
/// every package of a build.
pub record DepDefaults {
  ifaces: Map[String, slice[Byte]]
}

pub func newDepDefaults(): DepDefaults {
  DepDefaults(ifaces = newMap())
}

/// Make the interface `bytes` of package `pkg` readable to the packages checked after it; a
/// package registered again replaces its earlier interface.
pub func registerInterface(dep: in DepDefaults, pkg: in String, bytes: in slice[Byte]) {
  if dep.ifaces.containsKey(pkg) {
    dep.ifaces.remove(pkg)
  }
  dep.ifaces.add(pkg, bytes)
}

/// The package a DefPath key (`Pkg::segments`) belongs to.
func keyPackage(key: in String): String {
  match key.indexOf("::") {
    case Some(i) -> key.substring(0, i)
    case None -> ""
  }
}

/// The interface of `pkg` read with `it`, cached in `cache` (per consumer: the numbering is
/// the consumer's).
func readDepIface(
  dep: in DepDefaults, cache: in Map[String, Iface], pkg: in String, it: in DefPathInterner
): Option[Iface] {
  match mapGet(cache, pkg) {
    case Some(i) -> return Some(value = i)
    case None -> ()
  }
  val bytes = match mapGet(dep.ifaces, pkg) { case Some(b) -> b; case None -> return None }
  match decodeIface(bytes, it) {
    case Ok(i) -> {
      cache.add(pkg, i)
      Some(value = i)
    }
    case Err(_) -> None
  }
}

/// The default of the parameter or field `name` of the function or record declared at `key`,
/// numbered with `it`, with the declarations it names: None when no interface of the build
/// carries it.
pub func readCarriedDefault(
  dep: in DepDefaults,
  cache: in Map[String, Iface],
  key: in String,
  name: in String,
  it: in DefPathInterner,
): Option[IfDefault] {
  val i = match readDepIface(dep, cache, keyPackage(key), it) { case Some(x) -> x; case None -> return None }
  match paramDefaultWithEntries(i, key, name) {
    case Some(d) -> Some(value = d)
    case None -> fieldDefaultOf(i, key, name)
  }
}
