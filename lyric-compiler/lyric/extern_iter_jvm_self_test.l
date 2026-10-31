//! extern_iter_jvm_self_test.l - runtime regression test for `for` over an
//! `extern type` of no type parameters or of two or more (#7809, D296) on
//! `--target jvm`.
//!
//! The loop variable's type is what the JDK class declares through its
//! generic `Signature`, walked to `Iterable<T>`: `Path` (no type parameters)
//! iterates `Path`, a `ConcurrentHashMap.KeySetView<K, V>` iterates its first
//! type argument, and a raw `ArrayList` iterates `Object`.
//!
//!   lyric test --target jvm lyric-compiler/lyric/extern_iter_jvm_self_test.l
@test_module
package Lyric.ExternIterJvmSelfTest

import Std.Core
import Std.Testing

extern type JObject = "java.lang.Object"

extern type JArrayList = "java.util.ArrayList"

extern type JFile = "java.io.File"

extern type JPath = "java.nio.file.Path"

extern type KeySet[K, V] = "java.util.concurrent.ConcurrentHashMap$KeySetView"

@externTarget("java.util.concurrent.ConcurrentHashMap.newKeySet")
func newKeySet[K, V](): KeySet[K, V] = ()

test "a raw collection yields the host Object" {
  val a = JArrayList.new()
  val _ = a.add("x")
  val _2 = a.add("yz")
  var joined = ""
  for o in a {
    joined = joined + o.toString()
  }
  assertEqual(joined, "xyz", "ArrayList elements in order")
}

test "an arity-0 class that is Iterable of itself yields that type" {
  val p = JFile.new("a/b/c").toPath()
  var joined = ""
  for part in p {
    joined = joined + part.toString() + "/"
  }
  assertEqual(joined, "a/b/c/", "each Path element is a Path")
}

test "an arity-2 collection yields the element its type argument names" {
  val ks = newKeySet[String, Int]()
  val _ = ks.add("k")
  var total = 0
  for k in ks {
    total = total + k.length
  }
  assertEqualInt(total, 1, "the loop variable is the first type argument, a String")
}
