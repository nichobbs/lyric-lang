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

func pickInc(c: in Bool): (Int) -> Int {
  if c {
    { a: Int -> a + 1 }
  } else {
    { a: Int -> a - 1 }
  }
}

test "function elements of a slice's append, slice and concat" {
  val fs: slice[(Int) -> Int] = [{ a: Int -> a + 1 }]
  val f2 = fs.append({ a: Int -> a * 3 })
  assertEqualInt(f2[1](5), 15, "append")
  val f3 = f2.concat(fs).slice(1, 3)
  assertEqualInt(f3[0](2) + f3[1](2), 9, "concat then slice")
  var total = 0
  for f in f2 {
    total = total + f(10)
  }
  assertEqualInt(total, 41, "for over append")
}

test "function values an if produces and a destructured tuple holds" {
  assertEqualInt(pickInc(true)(5) + pickInc(false)(5), 10, "pickInc")
  val ti: slice[(Int, (Int) -> Int)] = [(1, { a: Int -> a + 5 })]
  val (m, tg) = ti[0]
  assertEqualInt(tg(m), 6, "tuple")
}
