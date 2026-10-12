//! slice_func_tolist_dotnet_self_test.l — dotnet runtime regression test for
//! `slice.toList()` over function elements (#8299).
//!
//! `toList()` copies a slice into a concrete `List[T]`.  For a function
//! element type it added each element, read through `IList.get_Item` as an
//! `object`, to the `List<Action<...>>` / `List<Func<...>>` unnarrowed
//! (ilverify: StackUnexpected).  Each element is now narrowed to its delegate
//! type first.  dotnet-only: the JVM backend does not lower `slice.toList()`
//! (J008, "method 'toList' cannot be called on a slice receiver"), and the
//! native one does not accept a `Unit`-returning function type as a type
//! argument (N0007).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/slice_func_tolist_dotnet_self_test.l
//!
//! `scripts/ilverify-selfhosted.sh` verifies the test DLL.
@test_module
package Lyric.SliceFuncToListDotnetSelfTest

import Std.Core
import Std.Collections
import Std.Testing

test "toList of a Unit-function slice" {
  val log: List[String] = newList()
  val ss: slice[(Int) -> Unit] = [{ a: Int -> log.add("a" + toString(a)) }]
  val l = ss.toList()
  l[0](1)
  for f in l {
    f(2)
  }
  assertEqualInt(log.count, 2, "calls")
  assertEqual(log[0] + log[1], "a1a2", "order")
}

test "toList of a value-returning function slice" {
  val fs: slice[(Int) -> Int] = [{ a: Int -> a + 1 }, { a: Int -> a * 2 }]
  val l = fs.toList()
  assertEqualInt(l[0](3) + l[1](3), 10, "toList")
}
