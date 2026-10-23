//! expected_type_inference_self_test.l — cross-target runtime regression test
//! for constructions that take their type from the position they sit in
//! rather than from their own arguments: a bare `None`, `Ok(..)`, `Err(..)`,
//! `newList()` or `newMap()` as an argument, a comparison operand, a tuple
//! component or a module-level initialiser.
//!
//!   - a call through a function value builds its arguments at the
//!     function type's parameter types (#8346);
//!   - a method of a generic receiver builds a bare `None` argument at the
//!     receiver's instantiated parameter type (#8303);
//!   - a nested `newMap()` / `newList()` argument is built at the parameter's
//!     element type (#8274);
//!   - `r == Ok(..)` types the constructor operand from the other operand
//!     (#8144);
//!   - a `List` of tuples keeps its element type, so a `None` component is
//!     built at its `Option[T]` (#8092);
//!   - a module-level `val xs: List[Int] = newList()` is a `List[Int]`
//!     (#7293).
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/expected_type_inference_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/expected_type_inference_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ExpectedTypeInferenceSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Src[T] {
  x: T

  func inner(self: in Src[T], o: in Option[T]): Int {
    match o {
      case Some(_) -> 1
      case None -> 0
    }
  }
}

func Src.matchy[T](self: in Src[T], o: in Option[T]): Int {
  match o {
    case Some(_) -> 1
    case None -> 0
  }
}

func Src.pick[T](self: in Src[T], o: in Option[T], d: in T): T {
  match o {
    case Some(v) -> v
    case None -> d
  }
}

val moduleInts: List[Int] = newList()

val moduleStrs: List[String] = newList[String]()

val moduleMap: Map[String, Int] = newMap[String, Int]()

union Maybe[T] {
  case Just(v: T)
  case Nothing
}

func innerCount(m: in Map[String, Bool]): Int = m.count

func sumLongs(xs: in List[Long], k: in Long): Long {
  xs[0] + xs[1] + k
}

func sumDoubles(xs: in List[Double]): Double {
  xs[0] + xs[1]
}

func sumSlice(xs: in slice[Long]): Long {
  xs[0] + xs[1]
}

func pairFirst(p: in (array[2, Int], Int)): Int {
  match p {
    case (a, b) -> a[0] + b
  }
}

func countStrs(xs: in List[String]): Int = xs.count

func identityList[T](xs: in List[T]): List[T] = xs

func nestedCount[T](x: in List[List[T]]): Int = x.count

func sliceOfLists(xs: in slice[List[Int]]): Int = xs[1].count + xs[0].count

func innerLen(l: in List[Int]): Int = l.count

func isNone2(p: in (Option[Int], Int)): Bool {
  match p {
    case (Some(_), _) -> false
    case (None, _) -> true
  }
}

test "a call through a function value builds None at the parameter type" {
  val f = { o: Option[Int] -> match o { case Some(v) -> v; case None -> 0 } }
  assertEqualInt(f(None), 0, "None")
  assertEqualInt(f(Some(value = 4)), 4, "Some")
}

test "a call through a function value builds Ok and Err at the parameter type" {
  val g = { r: Result[Int, String] -> match r { case Ok(v) -> v; case Err(e) -> e.length } }
  assertEqualInt(g(Ok(value = 3)), 3, "Ok")
  assertEqualInt(g(Err(error = "xyz")), 3, "Err")
}

test "a function-typed parameter called with a bare None" {
  val h: (Option[String], Int) -> Int = { o, n -> match o { case Some(s) -> s.length + n; case None -> n } }
  assertEqualInt(h(None, 7), 7, "None first")
}

test "a bare None argument of a generic method takes the receiver's type argument" {
  val a: Src[String] = Src(x = "a")
  val b: Src[Int] = Src(x = 1)
  assertEqualInt(a.matchy(None), 0, "String receiver")
  assertEqualInt(b.matchy(None), 0, "Int receiver")
  assertEqualInt(b.matchy(Some(value = 2)), 1, "Int receiver, Some")
  assertEqualInt(a.inner(None), 0, "String receiver, record method")
  assertEqualInt(b.inner(None), 0, "Int receiver, record method")
  assertEqualInt(b.inner(Some(value = 1)), 1, "Int receiver, record method, Some")
  assertEqualInt(b.pick(None, 9), 9, "Int pick")
  assertEqual(a.pick(None, "d"), "d", "String pick")
}

test "newMap and newList passed as nested collection values" {
  val m: Map[String, Map[String, Bool]] = newMap()
  m.add("a", newMap())
  assertEqualInt(m.count, 1, "map in map via add")
  assertEqualInt(innerCount(newMap()), 0, "map to a user function")
  val l: List[List[Int]] = newList()
  l.add(newList())
  assertEqualInt(l.count, 1, "list in list via add")
  assertEqualInt(innerLen(newList()), 0, "list to a user function")
}

test "comparing a Result with a bare case constructor" {
  val a: Result[Long, Int] = Ok(2i64)
  assertTrue(a == Ok(2i64), "a == Ok")
  assertTrue(Ok(2i64) == a, "Ok == a")
  assertTrue(a != Err(1), "a != Err")
  assertFalse(a == Err(1), "a == Err")
  assertFalse(a != Ok(2i64), "a != Ok")
}

test "comparing an Option with a bare None" {
  val n: Option[Int] = None
  val s: Option[Int] = Some(value = 3)
  assertTrue(n == None, "None == None")
  assertTrue(s != None, "Some != None")
  assertTrue(s == Some(value = 3), "Some == Some")
}

test "a List of tuples keeps its element type for None components" {
  val ys: List[(Option[Int], Int)] = [(None, 7)]
  ys.add((None, 1))
  assertTrue(isNone2(ys[0]), "literal element")
  assertTrue(isNone2(ys[1]), "added element")
  ys.add(0, (None, 2))
  assertTrue(isNone2(ys[0]), "inserted element")
}

test "a generic call whose only argument is a bare None" {
  assertTrue(isNone(None), "isNone(None)")
}

test "a module-level val initialised with newList" {
  moduleInts.add(1)
  moduleStrs.add("a")
  moduleMap.add("k", 1)
  assertEqualInt(moduleMap.count, 1, "newMap[String, Int]()")
  assertEqualInt(moduleInts.count, 1, "newList()")
  assertEqualInt(moduleStrs.count, 1, "newList[String]()")
}

test "an Int bracket literal passed to a List[Long], List[Double] parameter" {
  assertEqualLong(sumLongs([7, 8], 1), 16i64, "List[Long]")
  assertTrue(sumDoubles([1.5, 2.5]) == 4.0, "List[Double]")
}

test "a bracket literal argument takes the shape its parameter gives it" {
  assertEqualLong(sumSlice([7, 8]), 15i64, "slice[Long]")
  assertEqualInt(pairFirst(([7, 8], 9)), 16, "tuple holding an array")
}

test "toList on a bracket literal passed where a List is expected" {
  var t = 0
  for s in ["a", "b"] {
    t = t + countStrs([s].toList())
  }
  assertEqualInt(t, 2, "[s].toList()")
}

test "a bracket literal in a generic call takes its List type from the result" {
  val r: List[Long] = identityList([1, 2])
  assertEqualLong(r[1], 2i64, "return type binds T")
  assertEqualInt(nestedCount([[1], [2, 3, 4]]), 2, "List[List[T]] parameter")
  val o: Option[List[Int]] = Some(value = [1, 2])
  match o {
    case Some(l) -> assertEqualInt(l.count, 2, "Some payload")
    case None -> assertTrue(false, "Some expected")
  }
  val b: slice[List[Int]] = [[1], [5, 6]]
  assertEqualInt(sliceOfLists(b), 3, "slice of List")
}

test "a lambda returning a bracket literal where a List is expected" {
  val f: () -> List[Long] = { -> [1, 2] }
  val l = f()
  assertEqualInt(l.count, 2, "count")
  assertEqualLong(l[0] + l[1], 3i64, "widened elements")
}

func okOrErrTuple(b: in Bool): Int {
  val t = match b { case true -> (Ok(1), 5); case false -> (Err("ee"), 6) }
  match t {
    case (Ok(v), n) -> v + n
    case (Err(e), n) -> e.length + n
  }
}

func maybeNothingFirst(b: in Bool): Int {
  val m = match b { case true -> Nothing; case false -> Just(7) }
  match m {
    case Just(v) -> v
    case Nothing -> 0
  }
}

func optBranch(c: in Bool): Int {
  val o = if c { None } else { Some(value = 4) }
  match o {
    case Some(v) -> v
    case None -> 100
  }
}

test "branches that leave a type argument open are built at the joined type" {
  assertEqualInt(okOrErrTuple(true), 6, "Ok in a tuple")
  assertEqualInt(okOrErrTuple(false), 8, "Err in a tuple")
  assertEqualInt(maybeNothingFirst(true), 0, "Nothing first")
  assertEqualInt(maybeNothingFirst(false), 7, "Just second")
  assertEqualInt(optBranch(true), 100, "None branch")
  assertEqualInt(optBranch(false), 4, "Some branch")
}

record Twin[A, B] {
  a: A
  b: B
}

func makeTwin(): Twin[Int, String] {
  Twin(a = 1, b = "x")
}

func makeTwinReturn(c: in Bool): Twin[Int, String] {
  if c {
    return Twin(a = 2, b = "yy")
  }
  Twin(a = 3, b = "z")
}

test "return position gives a generic record constructor its type" {
  assertEqualInt(makeTwin().a, 1, "tail generic record constructor")
  assertEqual(makeTwinReturn(true).b, "yy", "returned generic record constructor")
  assertEqual(makeTwinReturn(false).b, "z", "tail after a return")
}

union Key {
  case Named(name: String)
  case Anonymous
}

func fallbackName(k: in Key): Option[String] = None

func pickName(k: in Key): String {
  val got = match k { case Named(n) -> if n.length == 0 { None } else { Some(value = n) }; case _ -> fallbackName(k) }
  match got {
    case Some(s) -> s
    case None -> "none"
  }
}

union Shape {
  case Round(n: Int)
  case Flat
}

record Wrap {
  s: Shape
}

func pickWrap(p: in Option[Int], q: in Option[Int]): Option[Wrap] {
  val custom = match p {
    case Some(x) -> match q { case Some(_) -> Some(value = Round(n = x)); case None -> { return None } }
    case None -> match q { case Some(_) -> { return None }; case None -> None }
  }
  val shape = match custom { case Some(c) -> c; case None -> Flat }
  Some(value = Wrap(s = shape))
}

test "an if arm holding None beside Some, and a None arm beside returning arms" {
  assertEqual(pickName(Named(name = "x")), "x", "Some arm")
  assertEqual(pickName(Named(name = "")), "none", "None arm")
  assertEqual(pickName(Anonymous), "none", "other arm")
  var seen = 0
  match pickWrap(Some(value = 1), Some(value = 2)) {
    case Some(w) -> match w.s { case Round(n) -> { seen = n }; case Flat -> () }
    case None -> ()
  }
  assertEqualInt(seen, 1, "Round")
  var flat = 0
  match pickWrap(None, None) {
    case Some(w) -> match w.s { case Flat -> { flat = 1 }; case Round(_) -> () }
    case None -> ()
  }
  assertEqualInt(flat, 1, "Flat")
}
