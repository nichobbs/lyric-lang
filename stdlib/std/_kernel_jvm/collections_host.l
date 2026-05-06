// std/_kernel_jvm/collections_host.l - JVM host boundary for
// java.util.ArrayList and java.util.HashMap.
//
// Mirrors _kernel/collections_host.l for the JVM target.
//
// tryGetValue adapts Java's null-sentinel get() to the out-parameter +
// Bool pattern that Std.Collections.mapGet expects.  The shim checks
// containsKey before get so it correctly distinguishes a present null
// value from an absent key (though Lyric's type system forbids null
// values in Map[K, V] when V is non-nullable).
//
// Internal: only Std.Collections should import this.

@axiom("java.util.ArrayList / HashMap conform to their documented JVM contracts")
package Std.CollectionsHost

import Std.Core

extern type List[T]   = "java.util.ArrayList"
extern type Map[K, V] = "java.util.HashMap"

// java.util.ArrayList no-arg constructor.
@externTarget("java.util.ArrayList.<init>")
pub func newList[T](): List[T] = ()

// java.util.HashMap no-arg constructor.
@externTarget("java.util.HashMap.<init>")
pub func newMap[K, V](): Map[K, V] = ()

// Adapts HashMap.get(key): V? to the out-parameter + Bool pattern.
// Shim: if map.containsKey(key) { value = map.get(key); return true }
// else { return false }.
@externTarget("lyric.stdlib.jvm.CollectionsHost.tryGetValue")
pub func tryGetValue[K, V](m: in Map[K, V], key: in K, value: out V): Bool = ()
