//! slice_fastpath_listbacked_dotnet_self_test.l — the `IList` fallback
//! behind MSIL's typed slice fast paths (#7259, #7342).
//!
//! Index reads, index writes, `for` iteration and slice copies on MSIL test
//! whether a `slice[T]` is a genuine CLI `T[]` and otherwise fall back to
//! `IList`. The self-hosted code generator only ever produces genuine arrays
//! (see `slice_fastpath_self_test.l`), so this module obtains a real
//! `List`-backed slice from the BCL: `Enumerable.ToList` over a `string[]`
//! instantiates as `ToList<object>` and returns a `List<object>`, which the
//! first case asserts before the others rely on it. Each later case then
//! drives one fast-path site down its fallback branch.
//!
//! dotnet-only: the extern bindings below are test-only (the same documented
//! exception `http_server_dotnet_tests.l` uses for driving the other side of
//! a boundary), and the representation split they exercise exists only on
//! MSIL.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/slice_fastpath_listbacked_dotnet_self_test.l
@test_module
package Lyric.SliceFastpathListBackedDotnetSelfTest

import Std.Core
import Std.Testing

extern type NetType = "System.Type"

@externTarget("System.Object.GetType")
func runtimeType(o: in slice[String]): NetType = ()

@externTarget("System.Object.ToString")
func typeName(t: in NetType): String = ()

@externTarget("System.Linq.Enumerable.ToList")
func toObjectList(xs: in slice[String]): slice[String] = ()

func listBacked(): slice[String] {
  toObjectList(["a", "b", "c"])
}

test "the source is List-backed, not an array" {
  val name = typeName(runtimeType(listBacked()))
  assertTrue(name.startsWith("System.Collections.Generic.List"), "runtime type: " + name)
}

test "index read falls back to IList" {
  val xs = listBacked()
  assertEqual(xs[0], "a", "first")
  assertEqual(xs[2], "c", "last")
  assertEqualInt(xs.length, 3, "length")
}

test "index write falls back to IList" {
  var xs = listBacked()
  xs[1] = "z"
  assertEqual(xs[1], "z", "written element")
  assertEqual(xs[0], "a", "neighbour untouched")
}

test "for iteration falls back to IList" {
  var acc = ""
  for s in listBacked() {
    acc = acc + s
  }
  assertEqual(acc, "abc", "every element in order")
}

test "slice copies fall back to the element loop" {
  val xs = listBacked()
  val sub = xs.slice(1, 3)
  assertEqualInt(sub.length, 2, "sub-slice length")
  assertEqual(sub[0] + sub[1], "bc", "sub-slice elements")
  val both = xs.concat(sub)
  assertEqualInt(both.length, 5, "concat length")
  assertEqual(both[4], "c", "concat tail")
  val more = xs.append("d")
  assertEqual(more[3], "d", "append tail")
  assertEqual(more[0], "a", "append head")
}
