//! slice_func_elem_self_test.l — runtime regression test for function values
//! read out of a `slice` (#8299).
//!
//! On `--target dotnet` a `slice[(A) -> R]` is read through the non-generic
//! `IList.get_Item`, which returns `object`, and the element was bound,
//! returned or invoked as that `object` where its `Func`/`Action` delegate
//! type was expected (ilverify: StackUnexpected).  The element is now
//! narrowed to its delegate type.  The runtime result was already right on
//! all three targets; the test runs on each, and
//! `scripts/ilverify-selfhosted.sh` verifies the dotnet test DLL.  Elements of
//! a `Unit`-returning function type are covered by
//! `slice_func_unit_elem_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/slice_func_elem_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/slice_func_elem_self_test.l
//!   lyric test --target native lyric-compiler/lyric/slice_func_elem_self_test.l
@test_module
package Lyric.SliceFuncElemSelfTest

import Std.Core
import Std.Testing

func boundCall(fs: in slice[(Int) -> Int], x: in Int): Int {
  val f = fs[0]
  f(x)
}

func directCall(fs: in slice[(Int) -> Int], i: in Int, x: in Int): Int {
  fs[i](x)
}

func pick(fs: in slice[(Int) -> Int], i: in Int): (Int) -> Int = fs[i]

func stringCall(fs: in slice[(String) -> String], x: in String): String {
  val f = fs[0]
  f(x)
}

func pairCall(fs: in slice[(Int, Int) -> Int], a: in Int, b: in Int): Int {
  val f = fs[0]
  f(a, b)
}

func thunkCall(fs: in slice[() -> Int]): Int {
  val f = fs[0]
  f()
}

test "a function value bound from a slice element" {
  val fs: slice[(Int) -> Int] = [{ a: Int -> a + 1 }, { a: Int -> a * 2 }]
  assertEqualInt(boundCall(fs, 10), 11, "boundCall")
}

test "a slice element invoked directly" {
  val fs: slice[(Int) -> Int] = [{ a: Int -> a + 1 }, { a: Int -> a * 2 }]
  assertEqualInt(directCall(fs, 1, 10), 20, "directCall")
}

test "a slice element returned as a function value" {
  val fs: slice[(Int) -> Int] = [{ a: Int -> a + 1 }, { a: Int -> a * 2 }]
  val g = pick(fs, 1)
  assertEqualInt(g(3), 6, "pick")
}

test "reference-typed and two-argument function elements" {
  val ss: slice[(String) -> String] = [{ s: String -> s + "!" }]
  assertEqual(stringCall(ss, "hi"), "hi!", "stringCall")
  val ps: slice[(Int, Int) -> Int] = [{ a: Int, b: Int -> a * 10 + b }]
  assertEqualInt(pairCall(ps, 4, 2), 42, "pairCall")
  val ts: slice[() -> Int] = [{ -> 8 }]
  assertEqualInt(thunkCall(ts), 8, "thunkCall")
}
