//! std/collections.l - Growable lists and hash maps.
//!
//! `List[T]` and `Map[K, V]` are extern aliases over the BCL generic
//! collections, declared in `_kernel/collections_host.l`
//! (`Std.CollectionsHost`) and re-imported here so users see the
//! idiomatic `Std.Collections` surface.  BCL method dispatch works
//! directly on the extern types: `xs.add(item)`, `xs[i]`, `xs.count`,
//! `m.containsKey(k)`, `m.add(k, v)`, etc.
//!
//! Idiomatic usage:
//!
//!   val xs: List[Int] = newList()
//!   xs.add(1)
//!   xs.add(2)
//!   println(xs.count)
//!   println(xs[0])
//!
//!   val m: Map[String, Int] = newMap()
//!   m.add("a", 10)
//!   if m.containsKey("a") { ... }
//!   match mapGet(m, "a") {
//!     case Some(v) -> println(v)
//!     case None    -> println("missing")
//!   }
package Std.Collections

import Std.Core
import Std.CollectionsHost

/// Lookup `key` in `m`.  Returns `Some(value)` if present, `None` if
/// missing.  Lyric-side wrapper around `tryGetValue` so callers see
/// the idiomatic `Option[V]` shape.
@stable(since = "1.0")
pub func mapGet[K, V](m: in Map[K, V], key: in K): Option[V] {
  var value: V = default()
  if tryGetValue(m, key, value) {
    Some(value = value)
  } else {
    None
  }
}

/// Number of key-value pairs in `m`.
@experimental
pub func mapSize[K, V](m: in Map[K, V]): Int {
  m.count
}

/// True when `m` has no key-value pairs.
@experimental
pub func mapIsEmpty[K, V](m: in Map[K, V]): Bool {
  m.count == 0
}

/// Key-value pair from a `Map[K, V]` — produced by `mapEntries`.
@stable(since = "1.0")
pub record MapEntry[K, V] {
  key: K
  value: V
}

/// Opaque wrapper around the host key collection.
@stable(since = "1.0")
pub extern type MapKeyCollection[K, V] = "System.Collections.Generic.Dictionary`2+KeyCollection"

/// Opaque wrapper around the host value collection.
@stable(since = "1.0")
pub extern type MapValueCollection[K, V] = "System.Collections.Generic.Dictionary`2+ValueCollection"

/// Return the key collection of `m` as a lazy view (no copy).
/// The returned `MapKeyCollection[K, V]` can be iterated with `for`.
@stable(since = "1.0")
pub func mapKeys[K, V](m: in Map[K, V]): MapKeyCollection[K, V] {
  dictGetKeys(m)
}

/// Return the value collection of `m` as a lazy view (no copy).
/// The returned `MapValueCollection[K, V]` can be iterated with `for`.
@stable(since = "1.0")
pub func mapValues[K, V](m: in Map[K, V]): MapValueCollection[K, V] {
  dictGetValues(m)
}

/// Call `action(key, value)` for every entry in `m`.
@stable(since = "1.0")
pub func mapForEach[K, V](m: in Map[K, V], action: in (K, V) -> Unit): Unit {
  for k in dictGetKeys(m) {
    match mapGet(m, k) {
      case Some(v) -> action(k, v)
      case None -> ()
    }
  }
}

/// Copy every entry from `src` into `dst`, overwriting existing keys.
@stable(since = "1.0")
pub func mapPutAll[K, V](dst: in Map[K, V], src: in Map[K, V]): Unit {
  for k in dictGetKeys(src) {
    match mapGet(src, k) {
      case Some(v) -> {
        dst.remove(k)
        dst.add(k, v)
      }
      case None -> ()
    }
  }
}

/// Return all entries of `m` as a list of `MapEntry[K, V]` records.
@stable(since = "1.0")
pub func mapEntries[K, V](m: in Map[K, V]): List[MapEntry[K, V]] {
  val result: List[MapEntry[K, V]] = newList()
  for k in dictGetKeys(m) {
    match mapGet(m, k) {
      case Some(v) -> result.add(MapEntry(key = k, value = v))
      case None -> ()
    }
  }
  result
}
