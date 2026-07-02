//! std/_kernel_jvm/collections_host.l - JVM host boundary for
//! java.util.ArrayList and java.util.HashMap.
//!
//! Mirrors _kernel/collections_host.l for the JVM target.
//!
//! tryGetValue adapts Java's null-sentinel get() to the out-parameter +
//! Bool pattern that Std.Collections.mapGet expects; it checks
//! containsKey before get so it correctly distinguishes a present null
//! value from an absent key (though Lyric's type system forbids null
//! values in Map[K, V] when V is non-nullable).  All bodies here are
//! plain Lyric over the JVM auto-FFI — no F#/Java shim classes.
//!
//! Internal: only Std.Collections should import this.
@axiom("java.util.ArrayList / HashMap conform to their documented JVM contracts")
package Std.CollectionsHost

import Std.Core

extern type List[T] = "java.util.ArrayList"

extern type Map[K, V] = "java.util.HashMap"

// java.util.ArrayList no-arg constructor.
@externTarget("java.util.ArrayList.<init>")
pub func newList[T](): List[T] = ()

// java.util.ArrayList pre-sized constructor (capacity overload).
@externTarget("java.util.ArrayList.<init>")
pub func newListWithCapacity[T](capacity: in Int): List[T] = ()

// java.util.HashMap no-arg constructor.
@externTarget("java.util.HashMap.<init>")
pub func newMap[K, V](): Map[K, V] = ()

/// Adapts HashMap.get(key): V? to the out-parameter + Bool pattern.
/// containsKey runs first so a present-but-null value is distinguished
/// from an absent key; on the miss path the out slot keeps the caller's
/// value (callers ignore it when the result is false).
pub func tryGetValue[K, V](m: in Map[K, V], key: in K, value: out V): Bool {
  if m.containsKey(key) {
    value = m.get(key)
    true
  } else {
    false
  }
}

// =====================================================================
// Key / value collection views of a `Map[K, V]` without copying.
// HashMap.keySet() returns java.util.Set and .values() returns
// java.util.Collection; both implement Iterable, so `for` iterates
// them through the emitter's Iterable path.
// =====================================================================
extern type DictKeyCollection[K, V] = "java.util.Set"

extern type DictValueCollection[K, V] = "java.util.Collection"

/// Key view of `m` (java.util.HashMap.keySet, no copy).
pub func dictGetKeys[K, V](m: in Map[K, V]): DictKeyCollection[K, V] {
  m.keySet()
}

/// Value view of `m` (java.util.HashMap.values, no copy).
pub func dictGetValues[K, V](m: in Map[K, V]): DictValueCollection[K, V] {
  m.values()
}

// =====================================================================
// Set[T] — alias over java.util.HashSet.
//
// BCL-style method dispatch on the extern type:
//   s.add(item)      → HashSet.add(E)      : boolean (discarded)
//   s.contains(x)    → HashSet.contains(E) : boolean
//   s.remove(x)      → HashSet.remove(E)   : boolean
//   s.size()         → HashSet.size()      : int
//
// `setToSlice` routes through the JVM shim because java.util.HashSet
// has no .toArray(T[]) convenience variant matching the Lyric call shape.
// =====================================================================
extern type Set[T] = "java.util.HashSet"

@externTarget("java.util.HashSet.<init>")
pub func newSet[T](): Set[T] = ()

/// Snapshot of `s` as a slice.  HashSet.toArray() returns Object[],
/// which is exactly the erased `slice[T]` representation on the JVM.
pub func setToSlice[T](s: in Set[T]): slice[T] {
  s.toArray()
}
