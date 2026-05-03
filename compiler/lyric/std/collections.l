// std/collections.l - Growable lists and hash maps.
//
// `List[T]` and `Map[K, V]` are extern aliases over the BCL generic
// collections, declared in `_kernel/collections_host.l`
// (`Std.CollectionsHost`) and re-imported here so users see the
// idiomatic `Std.Collections` surface.  BCL method dispatch works
// directly on the extern types: `xs.add(item)`, `xs[i]`, `xs.count`,
// `m.containsKey(k)`, `m.add(k, v)`, etc.
//
// Idiomatic usage:
//
//   val xs: List[Int] = newList()
//   xs.add(1)
//   xs.add(2)
//   println(xs.count)
//   println(xs[0])
//
//   val m: Map[String, Int] = newMap()
//   m.add("a", 10)
//   if m.containsKey("a") { ... }
//   match mapGet(m, "a") {
//     case Some(v) -> println(v)
//     case None    -> println("missing")
//   }
package Std.Collections

import Std.Core
import Std.CollectionsHost

/// Lookup `key` in `m`.  Returns `Some(value)` if present, `None` if
/// missing.  Lyric-side wrapper around `tryGetValue` so callers see
/// the idiomatic `Option[V]` shape.
pub func mapGet[K, V](m: in Map[K, V], key: in K): Option[V] {
  var value: V = default()
  if tryGetValue(m, key, value) {
    Some(value = value)
  } else {
    None
  }
}
