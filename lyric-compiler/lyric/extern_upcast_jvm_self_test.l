//! lyric-compiler/lyric/extern_upcast_jvm_self_test.l
//!
//! @test_module for the explicit extern upcast `externAsObject(x)` on the JVM
//! target (D212, #7975): extern values reach a `List[JObject]` and an
//! `Object`-typed parameter through the named upcast, and the value that comes
//! back out is the same object.  The file declares itself part of the extern
//! boundary with a file-level `@unsafe_ffi` (N0103 elsewhere).
//!
//! Run: ./bin/lyric test --target jvm lyric-compiler/lyric/extern_upcast_jvm_self_test.l
@test_module
@unsafe_ffi
package Lyric.ExternUpcastJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

extern type JObject = "java.lang.Object"

extern type JStringBuilder = "java.lang.StringBuilder"

extern type JArrayList = "java.util.ArrayList"

func describe(o: in JObject): String = o.toString()

test "extern values are added to a List[JObject] through the upcast" {
  val sb = JStringBuilder.new("hello")
  val al = JArrayList.new()
  val items: List[JObject] = newList()
  items.add(externAsObject(sb))
  items.add(externAsObject(al))
  assertEqualInt(items.count, 2, "two elements")
  assertEqual(describe(items[0]), "hello", "first element is the builder")
  assertEqual(describe(items[1]), "[]", "second element is the empty list")
}

test "an upcast value passes to an Object parameter and keeps its identity" {
  val sb = JStringBuilder.new("a")
  val o: JObject = externAsObject(sb)
  sb.append("b")
  assertEqual(describe(o), "ab", "the upcast aliases the builder")
  assertEqual(describe(externAsObject(sb)), "ab", "an inline upcast argument")
}

test "upcasting a JObject is the identity" {
  val sb = JStringBuilder.new("x")
  val o: JObject = externAsObject(sb)
  val again: JObject = externAsObject(o)
  assertEqual(describe(again), "x", "JObject upcast to JObject")
}
