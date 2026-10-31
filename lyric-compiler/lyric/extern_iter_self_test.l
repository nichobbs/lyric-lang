//! extern_iter_self_test.l - runtime regression test for `for` over an
//! `extern type` of no type parameters or of two or more (#7809, D302) on
//! `--target dotnet`.
//!
//! The loop variable's type is what the .NET collection protocol declares,
//! read from the reference assemblies: `IEnumerable<T>`'s `T`, or `object`
//! for a collection that is only `System.Collections.IEnumerable`.  The loop
//! iterates through the host's enumerator, so a type that is not an `IList`
//! (a `Queue`, a `SortedDictionary` key view) works as well as one that is.
//!
//!   lyric test lyric-compiler/lyric/extern_iter_self_test.l
@test_module
package Lyric.ExternIterSelfTest

import Std.Core
import Std.Testing

extern type Obj = "System.Object"

extern type ArrayList = "System.Collections.ArrayList"

extern type Queue = "System.Collections.Queue"

extern type SortedDict[K, V] = "System.Collections.Generic.SortedDictionary`2"

extern type SortedKeys[K, V] = "System.Collections.Generic.SortedDictionary`2+KeyCollection"

extern type SortedValues[K, V] = "System.Collections.Generic.SortedDictionary`2+ValueCollection"

@externTarget("System.Collections.Queue..ctor")
func newQueue(): Queue = ()

@externTarget("System.Collections.Queue.Enqueue")
@externInstance
func enqueue(q: in Queue, item: in String): Unit = ()

@externTarget("System.Collections.ArrayList..ctor")
func newArrayList(): ArrayList = ()

@externTarget("System.Collections.ArrayList.Add")
@externInstance
func arrayListAdd(a: in ArrayList, item: in String): Int = ()

@externTarget("System.Convert.ToString")
func objectText(o: in Obj): String = ()

@externTarget("System.Collections.Generic.SortedDictionary`2..ctor")
func newSorted[K, V](): SortedDict[K, V] = ()

@externTarget("System.Collections.Generic.SortedDictionary`2.get_Keys")
@externInstance
func sortedKeys[K, V](d: in SortedDict[K, V]): SortedKeys[K, V] = ()

@externTarget("System.Collections.Generic.SortedDictionary`2.get_Values")
@externInstance
func sortedValues[K, V](d: in SortedDict[K, V]): SortedValues[K, V] = ()

@externTarget("System.Collections.Generic.SortedDictionary`2.set_Item")
@externInstance
func sortedSet[K, V](d: in SortedDict[K, V], key: in K, value: in V): Unit = ()

test "a non-generic IEnumerable that is not an IList yields the host Object" {
  val q = newQueue()
  enqueue(q, "alpha")
  enqueue(q, "be")
  var total = 0
  for o in q {
    val s: String = objectText(o)
    total = total + s.length
  }
  assertEqualInt(total, 7, "each element is the host Object, usable through its methods")
}

test "a non-generic IList yields the host Object" {
  val a = newArrayList()
  val _ = arrayListAdd(a, "x")
  val _2 = arrayListAdd(a, "yz")
  var joined = ""
  for o in a {
    joined = joined + objectText(o)
  }
  assertEqual(joined, "xyz", "ArrayList elements in order")
}

test "an arity-2 extern yields the element of its key view" {
  val d = newSorted[String, Int]()
  sortedSet(d, "b", 2)
  sortedSet(d, "a", 1)
  sortedSet(d, "c", 3)
  var keys = ""
  for k in sortedKeys(d) {
    keys = keys + k
  }
  assertEqual(keys, "abc", "the key view yields K in sorted order")
  var sum = 0
  for v in sortedValues(d) {
    sum = sum + v
  }
  assertEqualInt(sum, 6, "the value view yields V")
}
