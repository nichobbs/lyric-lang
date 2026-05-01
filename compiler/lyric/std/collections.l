// std/collections.l - Growable lists and hash maps via FFI.
//
// Each container is a generic `extern type` mapping to the matching
// BCL generic.  Most operations come for free via BCL method dispatch
// (e.g. `xs.add(item)`, `xs.contains(x)`, `m.containsKey(k)`,
// `m.add(k, v)`, `xs[i]`, `m[k]`); this file declares only what the
// BCL surface doesn't expose ergonomically — the constructor (no
// way to invoke `new` on an extern type without an `@externTarget`
// helper) and `mapGet` returning `Option[V]`.
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
//   m.add("a", 10)                       // BCL Add(K, V)
//   if m.containsKey("a") { ... }
//   match mapGet(m, "a") {
//     case Some(v) -> println(v)
//     case None    -> println("missing")
//   }
package Std.Collections

import Std.Core

// =====================================================================
// List[T] — backed by `System.Collections.Generic.List<T>`.
//
// Available via BCL dispatch on `xs: List[T]`:
//   xs.add(item)         — Add(T)
//   xs[i]                — get_Item(int) (read)
//   xs.count             — get_Count() : int
//   xs.contains(item)    — Contains(T) : bool
//   xs.removeAt(i)       — RemoveAt(int)
//   xs.clear()           — Clear()
//   xs.toArray()         — ToArray() : T[]   (use as slice[T])
// =====================================================================

extern type List[T] = "System.Collections.Generic.List`1"

@externTarget("System.Collections.Generic.List`1..ctor")
pub func newList[T](): List[T] = ()

// =====================================================================
// Map[K, V] — backed by `System.Collections.Generic.Dictionary<K, V>`.
//
// Available via BCL dispatch on `m: Map[K, V]`:
//   m.add(key, value)        — Add(K, V) (throws on duplicate key)
//   m[key]                    — get_Item(K) (read; throws if missing)
//   m.containsKey(key)        — ContainsKey(K) : bool
//   m.remove(key)             — Remove(K) : bool
//   m.count                   — get_Count() : int
//   m.clear()                 — Clear()
//
// Use `mapGet(m, key)` for the safe lookup — returns `Option[V]`.
// =====================================================================

extern type Map[K, V] = "System.Collections.Generic.Dictionary`2"

@externTarget("System.Collections.Generic.Dictionary`2..ctor")
pub func newMap[K, V](): Map[K, V] = ()

/// Direct binding to `Dictionary.TryGetValue` via FFI — the canonical
/// .NET "lookup with sentinel" API.  Now that `out` parameters are
/// supported across the FFI boundary, this is a one-liner; previously
/// we routed through a `MapHelpers.Has` + `GetOrDefault` pair.
@externTarget("System.Collections.Generic.Dictionary`2.TryGetValue")
pub func tryGetValue[K, V](m: in Map[K, V], key: in K, value: out V): Bool = ()

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
