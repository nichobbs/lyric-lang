//! Inline unions (docs/67 §4.2, G1 #7940): the language-level behaviour of
//! unions whose payloads are all plain values, whatever their representation.
//!
//! On `--target native` such a union lowers to a tagged struct value (no heap
//! allocation, no ARC); the cases here run the whole shared pipeline (`?`
//! propagation, `Option`/`Result` from `Std.Core`, structural `==`) and so pin
//! the same observable behaviour on every target, with the allocation-free
//! claim itself checked in `llvm_inline_union_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inline_union_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inline_union_self_test.l
//!   lyric test --target native lyric-compiler/lyric/inline_union_self_test.l
@test_module
package Lyric.InlineUnionSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Vec3 {
  x: Float
  y: Float
  z: Float
}

union Shape {
  case Circle(r: Float)
  case Rect(w: Int, h: Int)
  case Dot
}

union Pair2 {
  case Both(a: Shape, v: Vec3)
  case Neither
}

union Tree {
  case Leaf
  case Node(l: Tree, r: Tree)
}

union Slot[T] {
  case Full(v: T)
  case Empty
}

record Holder {
  s: Shape
  n: Int
}

record Found {
  at: Option[Vec3]
  n: Int
}

union Msg {
  case Got(o: Option[Int])
  case Quiet
}

func area(s: in Shape): Int {
  match s {
    case Circle(r) -> r.toInt()
    case Rect(w, h) -> w * h
    case Dot -> 0
  }
}

func find(n: in Int): Option[Vec3] {
  if n > 0 {
    Some(Vec3(x = n.toFloat(), y = 1.0, z = 2.0))
  } else {
    None
  }
}

func half(n: in Int): Result[Int, Int] {
  if n % 2 == 0 {
    Ok(n / 2)
  } else {
    Err(n)
  }
}

func chain(n: in Int): Result[Int, Int] {
  val a = half(n)?
  val b = half(a)?
  Ok(a + b)
}

func firstPos(n: in Int): Option[Int] {
  val v = find(n)?
  Some(v.x.toInt() + 1)
}

func depth(t: in Tree): Int {
  match t {
    case Leaf -> 0
    case Node(l, r) -> 1 + depth(l) + depth(r)
  }
}

func slotOr(s: in Slot[Int], d: in Int): Int {
  match s {
    case Full(v) -> v
    case Empty -> d
  }
}

test "a union of scalars, nullary cases included" {
  assertEqualInt(area(Rect(w = 3, h = 4)), 12, "Rect")
  assertEqualInt(area(Circle(r = 5.0f32)), 5, "Circle")
  assertEqualInt(area(Dot), 0, "Dot")
}

test "Option holds a by-value record" {
  val o = find(7)
  val got = match o { case Some(v) -> v.x.toInt(); case None -> 100 }
  assertEqualInt(got, 7, "Some")
  val miss = match find(0) { case Some(v) -> 0; case None -> 100 }
  assertEqualInt(miss, 100, "None")
}

func codeOf(r: in Result[Int, Int]): Int {
  match r {
    case Ok(v) -> v
    case Err(e) -> 1000 + e
  }
}

func optOf(o: in Option[Int]): Int {
  match o {
    case Some(v) -> v
    case None -> 0 - 1
  }
}

test "? propagates through Option and Result" {
  assertEqualInt(codeOf(chain(12)), 9, "Ok(6 + 3)")
  assertEqualInt(codeOf(chain(6)), 1003, "the second half fails with 3")
  assertEqualInt(codeOf(chain(5)), 1005, "the first half fails with 5")
  assertEqualInt(optOf(firstPos(3)), 4, "Some through ?")
  assertEqualInt(optOf(firstPos(0)), 0 - 1, "None through ?")
}

test "inline unions compare structurally" {
  assertTrue(Rect(w = 1, h = 2) == Rect(w = 1, h = 2), "same case, same payload")
  assertTrue(Rect(w = 1, h = 2) != Rect(w = 1, h = 3), "same case, different payload")
  assertTrue(Dot == Dot, "nullary")
  assertTrue(Dot != Rect(w = 0, h = 0), "different cases")
  val none: Option[Int] = None
  assertTrue(Some(3) == Some(3) and Some(3) != Some(4) and Some(3) != none, "Option[Int]")
}

test "inline unions nest in unions and hold records" {
  val p = Both(a = Rect(w = 2, h = 3), v = Vec3(x = 1.0, y = 2.0, z = 3.0))
  val got = match p { case Both(a, v) -> area(a) + v.z.toInt(); case Neither -> 0 }
  assertEqualInt(got, 9, "6 + 3")
  val h = Holder(s = Circle(r = 4.0f32), n = 2)
  assertEqualInt(area(h.s) + h.n, 6, "a record field of union type")
}

test "a recursive union and a generic user union" {
  assertEqualInt(depth(Node(l = Leaf, r = Node(l = Leaf, r = Leaf))), 2, "recursive")
  assertEqualInt(slotOr(Full(v = 5), 9), 5, "Full")
  assertEqualInt(slotOr(Empty, 9), 9, "Empty")
}

test "inline unions in a List and a Map" {
  val xs: List[Option[Int]] = newList()
  xs.add(Some(4))
  xs.add(None)
  xs.add(Some(8))
  xs[1] = Some(16)
  var total = 0
  for x in xs {
    total = total + match x { case Some(k) -> k; case None -> 1000 }
  }
  assertEqualInt(total, 28, "list of Option")
  val m: Map[String, Shape] = newMap()
  m.add("a", Rect(w = 2, h = 5))
  m["a"] = Rect(w = 3, h = 5)
  assertEqualInt(area(m["a"]), 15, "map value replaced")
}

test "closures capture and return inline unions" {
  val base: Option[Int] = Some(10)
  val f = { k: Int -> match base { case Some(v) -> Some(v + k); case None -> None } }
  assertEqualInt(optOf(f(2)), 12, "captured and returned")
}

test "a record and a union holding Option embed it" {
  val a = Found(at = Some(Vec3(x = 1.0, y = 2.0, z = 3.0)), n = 10)
  val none: Option[Vec3] = None
  val b = Found(at = none, n = 20)
  val av = match a.at { case Some(v) -> v.z.toInt() + a.n; case None -> a.n }
  val bv = match b.at { case Some(v) -> v.z.toInt(); case None -> b.n }
  assertEqualInt(av + bv, 33, "13 + 20")
  val m = Got(o = Some(7))
  val got = match m { case Got(o) -> optOf(o); case Quiet -> 0 }
  assertEqualInt(got, 7, "Option[Int] payload")
  assertEqualInt(match Quiet { case Got(o) -> 1; case Quiet -> 2 }, 2, "nullary")
}

test "equality on a record holding a generic inline union" {
  val one: Option[Int] = Some(1)
  val none: Option[Int] = None
  val a = Found(at = None, n = 1)
  val b = Found(at = None, n = 1)
  val c = Found(at = None, n = 2)
  assertTrue(a == b, "equal")
  assertTrue(a != c, "different n")
  assertTrue(Got(o = one) == Got(o = one), "union holding Option")
  assertTrue(Got(o = one) != Got(o = none), "different payload case")
}

test "Option from Map.get" {
  val m: Map[String, Int] = newMap()
  m.add("a", 40)
  assertEqualInt(optOf(mapGet(m, "a")), 40, "hit")
  assertEqualInt(optOf(mapGet(m, "b")), 0 - 1, "miss")
}
