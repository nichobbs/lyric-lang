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

// #8283: an element of a module-level `val` holding function values, called
// in place.  The type checker recorded the callee type of a call through a
// local's element but not a module-level `val`'s, so the call's result was an
// untyped `object`: dotnet added two `String` results as numbers (invalid IL,
// a crash or garbage), the JVM rejected the same `+` (J008), and native took
// `fns[1]` for explicit type arguments on a function named `fns` (N0007).
func addInts(a: in Int, b: in Int): Int {
  a + b
}

func mulInts(a: in Int, b: in Int): Int {
  a * b
}

val moduleFns: List[(Int, Int) -> Int] = [addInts, mulInts]

val moduleLambdas: List[(String) -> String] = [{ s: String -> s + "!" }, { s: String -> "<" + s + ">" }]

val moduleLongs: slice[(Long) -> Long] = [{ x: Long -> x * 2i64 }, { x: Long -> x + 1i64 }]

val moduleSinks: List[(Int) -> Unit] = [{ x: Int -> sinkLog.add(x) }, { x: Int -> sinkLog.add(x * 100) }]

val sinkLog: List[Int] = newList()

func parseDigit(s: in String): Result[Int, String] {
  match s {
    case "3" -> Ok(value = 3)
    case "4" -> Ok(value = 4)
    case "7" -> Ok(value = 7)
    case _ -> Err(error = "not a digit: " + s)
  }
}

func moduleFnWithPropagate(i: in Int, a: in String, b: in String): Result[Int, String] {
  val r = moduleFns[i](parseDigit(a)?, parseDigit(b)?)
  Ok(value = r)
}

func moduleFnTailPropagate(a: in String): Result[Int, String] {
  Ok(value = moduleFns[1](parseDigit(a)?, 6))
}

func applyAt[T](fs: in List[(T) -> T], i: in Int, x: in T): T {
  fs[i](x)
}

test "an element of a module-level List of functions called in place (#8283)" {
  assertEqualInt(moduleFns[1](3, 4), 12, "mulInts")
  var i = 0
  assertEqualInt(moduleFns[i](3, 4) + 1, 8, "addInts at a variable index")
  i = i + 1
  val r: Int = moduleFns[i](5, 5)
  assertEqualInt(r, 25, "bound result")
  assertEqual(moduleLambdas[1]("x") + moduleLambdas[0]("y"), "<x>y!", "lambda elements")
  assertTrue(moduleLongs[0](21i64) + moduleLongs[1](1i64) == 44i64, "Long elements of a module-level slice")
}

test "a module-level function element called with ? in its arguments (#8283)" {
  match moduleFnWithPropagate(1, "3", "4") {
    case Ok(v) -> assertEqualInt(v, 12, "both arguments propagate")
    case Err(e) -> assertTrue(false, "unexpected Err " + e)
  }
  match moduleFnWithPropagate(0, "3", "x") {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(e) -> assertEqual(e, "not a digit: x", "the second argument's error")
  }
  match moduleFnTailPropagate("7") {
    case Ok(v) -> assertEqualInt(v, 42, "tail position")
    case Err(e) -> assertTrue(false, "unexpected Err " + e)
  }
}

test "a Unit-returning module-level function element (#8283)" {
  moduleSinks[0](4)
  moduleSinks[1](5)
  assertEqualInt(sinkLog.count, 2, "both sinks ran")
  assertEqualInt(sinkLog[0] + sinkLog[1], 504, "sink values")
}

test "a module-level List of functions passed to a generic function (#8283)" {
  val strs: List[(String) -> String] = moduleLambdas
  assertEqual(applyAt(strs, 0, "go"), "go!", "String instantiation")
  val ints: List[(Int) -> Int] = [{ x: Int -> moduleFns[1](x, x) }]
  assertEqualInt(applyAt(ints, 0, 9), 81, "Int instantiation")
}
