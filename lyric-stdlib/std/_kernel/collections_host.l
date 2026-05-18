// std/_kernel/collections_host.l - host boundary for the BCL generic
// collections backing `Std.Collections.List` and `Std.Collections.Map`.
//
// Declares the `extern type` aliases and host constructors directly.
// `Std.Collections` `import`s this package; downstream `import
// Std.Collections` transitively pulls these declarations in via the
// artifact-dependency walker, so user code continues to see `List[T]`
// and `Map[K, V]` as bare names with full BCL method dispatch
// (`xs.add(item)`, `xs[i]`, `m.containsKey(k)`).
//
// Internal: only `Std.Collections` should import this; per
// `compiler/lyric/std/_kernel/README.md` the kernel is the audited
// extern boundary, not a general-purpose API.

@axiom("System.Collections.Generic.List / Dictionary conform to their documented .NET contracts")
package Std.CollectionsHost

import Std.Core

extern type List[T]   = "System.Collections.Generic.List`1"
extern type Map[K, V] = "System.Collections.Generic.Dictionary`2"

@externTarget("System.Collections.Generic.List`1..ctor")
pub func newList[T](): List[T] = ()

@externTarget("System.Collections.Generic.List`1..ctor")
pub func newListWithCapacity[T](capacity: in Int): List[T] = ()

@externTarget("System.Collections.Generic.Dictionary`2..ctor")
pub func newMap[K, V](): Map[K, V] = ()

/// Direct binding to `Dictionary.TryGetValue` via FFI — the canonical
/// .NET "lookup with sentinel" API.  Lifted into `Option[V]` by
/// `Std.Collections.mapGet`.
@externTarget("System.Collections.Generic.Dictionary`2.TryGetValue")
pub func tryGetValue[K, V](m: in Map[K, V], key: in K, value: out V): Bool = ()

// =====================================================================
// Set[T] — thin alias over System.Collections.Generic.HashSet.
//
// BCL method dispatch works directly on the extern type:
//   s.add(item)     → HashSet.Add(T)     : Bool (discarded)
//   s.contains(x)   → HashSet.Contains(T): Bool
//   s.remove(x)     → HashSet.Remove(T)  : Bool
//   s.count         → HashSet.Count      : Int
//
// `setToSlice` was previously a shim (Lyric.Stdlib.SetHost.SetToArray).
// It is now implemented in pure Lyric in `set.l` using `for x in s`
// (IEnumerable for-loop) and `List[T].toArray()`.  No extern needed.
// =====================================================================

extern type Set[T] = "System.Collections.Generic.HashSet`1"

@externTarget("System.Collections.Generic.HashSet`1..ctor")
pub func newSet[T](): Set[T] = ()
