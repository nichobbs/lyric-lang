//! structural_tostring_self_test.l — `toString` of a record, union, enum,
//! tuple, `List`, `Map`, `Set`, slice, `Option` and `Result` is one text on
//! every target (D282, #7892).
//!
//! Before D282 this was ``System.Collections.Generic.List`1[...]`` and the CLR
//! type name on dotnet, `[..]` and `P@<hash>` on the JVM, and a compile error
//! on native.  Each case asserts fixed text through every stringifying
//! position (`toString(x)`, `x.toString()`, interpolation, `+`, `+=`), so the
//! target and the position cannot disagree.
//!
//!   lyric test lyric-compiler/lyric/structural_tostring_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/structural_tostring_self_test.l
//!   lyric test --target native lyric-compiler/lyric/structural_tostring_native_self_test.l
//!
//! This is the native copy: `--target native` has no `Set` (N0007), so it leaves
//! out the `Set` case; the other cases are the same.
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.StructuralToStringNativeSelfTest

import Std.Core
import Std.Collections
import Std.String
import Std.Testing

record P {
  x: Int
  y: Int
}

record Empty {
}

record Box[T] {
  v: T
}

record Named {
  p: P
  name: String
  tags: List[String]
}

record Mixed {
  d: Double
  b: Bool
  c: Char
  w: Byte
}

union Shape {
  case Circle(radius: Int)
  case Pair(Int, Int)
  case Dot
}

enum Color {
  case Red
  case Green
}

union Tree {
  case Leaf
  case Node(left: Tree, value: Int, right: Tree)
}

ref record Cell {
  var n: Int
  var next: Option[Cell]
}

func twoPositions(p: in P): String {
  "[" + p + "]"
}

test "record: Name(field = value, ...)" {
  val p = P(x = 1, y = 2)
  assertEqual(toString(p), "P(x = 1, y = 2)", "toString(p)")
  assertEqual(p.toString(), "P(x = 1, y = 2)", "p.toString()")
  assertEqual("${p}", "P(x = 1, y = 2)", "interpolation")
  assertEqual(twoPositions(p), "[P(x = 1, y = 2)]", "concatenation, right operand")
  var s = "p="
  s += p
  assertEqual(s, "p=P(x = 1, y = 2)", "compound assignment")
}

test "record: no fields, generic, nested, collection field" {
  assertEqual(toString(Empty()), "Empty()", "no fields")
  val bi = Box(v = 3)
  assertEqual(toString(bi), "Box(v = 3)", "type arguments are not shown")
  val bp = Box(v = P(x = 1, y = 2))
  assertEqual(toString(bp), "Box(v = P(x = 1, y = 2))", "generic over a record")
  val tags: List[String] = newList()
  tags.add("a")
  tags.add("b")
  val n = Named(p = P(x = 0, y = 9), name = "ann", tags = tags)
  assertEqual(toString(n), "Named(p = P(x = 0, y = 9), name = ann, tags = [a, b])", "nested record, String, List")
}

test "record: scalar leaves render as they do standing alone" {
  val m = Mixed(d = 1500.0, b = true, c = 'z', w = 200u8)
  assertEqual(toString(m), "Mixed(d = 1500, b = true, c = z, w = 200)", "Double, Bool, Char, Byte")
}

test "union: Case(field = value) and the bare case name" {
  val c: Shape = Circle(radius = 5)
  val z: Shape = Dot
  val pr: Shape = Pair(1, 2)
  assertEqual(toString(c), "Circle(radius = 5)", "case with a named field")
  assertEqual(toString(z), "Dot", "case with no fields")
  assertEqual(toString(pr), "Pair(1, 2)", "case with positional fields")
  assertEqual("${c} ${z}", "Circle(radius = 5) Dot", "interpolation")
}

test "union: recursive" {
  val t: Tree = Node(left = Node(left = Leaf, value = 1, right = Leaf), value = 2, right = Leaf)
  assertEqual(toString(t), "Node(left = Node(left = Leaf, value = 1, right = Leaf), value = 2, right = Leaf)", "tree")
}

test "enum: the case name" {
  val g: Color = Green
  assertEqual(toString(g), "Green", "enum")
}

test "Option and Result are ordinary unions" {
  val s: Option[Int] = Some(value = 3)
  val n: Option[Int] = None
  val ok: Result[Int, String] = Ok(value = 1)
  val er: Result[Int, String] = Err(error = "boom")
  assertEqual(toString(s), "Some(value = 3)", "Some")
  assertEqual(toString(n), "None", "None")
  assertEqual(toString(ok), "Ok(value = 1)", "Ok")
  assertEqual(toString(er), "Err(error = boom)", "Err")
}

test "tuple: (a, b)" {
  val t = (1, "x")
  assertEqual(toString(t), "(1, x)", "pair")
  val t3 = (1, 2.5, true)
  assertEqual(toString(t3), "(1, 2.5, true)", "triple")
  val nested = ((1, 2), P(x = 3, y = 4))
  assertEqual(toString(nested), "((1, 2), P(x = 3, y = 4))", "nested")
}

test "List and slice: [a, b]" {
  val xs: List[Int] = newList()
  assertEqual(toString(xs), "[]", "empty list")
  xs.add(1)
  xs.add(2)
  assertEqual(toString(xs), "[1, 2]", "list")
  val ps: List[P] = newList()
  ps.add(P(x = 1, y = 2))
  assertEqual(toString(ps), "[P(x = 1, y = 2)]", "list of records")
  val sl: slice[Int] = [5, 6, 7]
  assertEqual(toString(sl), "[5, 6, 7]", "slice")
  val nested: List[List[Int]] = newList()
  nested.add(xs)
  nested.add(xs)
  assertEqual(toString(nested), "[[1, 2], [1, 2]]", "nested lists")
  val bs: List[Bool] = newList()
  bs.add(false)
  assertEqual(toString(bs), "[false]", "List[Bool] (the case from #7892)")
}

test "List of tuples is not confused with a tuple" {
  val ts: List[(Int, Int)] = newList()
  ts.add((1, 2))
  ts.add((3, 4))
  assertEqual(toString(ts), "[(1, 2), (3, 4)]", "list of tuples")
  val t = (newTwo(), 5)
  assertEqual(toString(t), "([1, 2], 5)", "tuple holding a list")
}

func newTwo(): List[Int] {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs
}

test "Map: {k: v}, ordered by the rendered key" {
  val m: Map[String, Int] = newMap()
  assertEqual(toString(m), "{}", "empty map")
  m.add("b", 2)
  m.add("a", 1)
  m.add("c", 3)
  assertEqual(toString(m), "{a: 1, b: 2, c: 3}", "string keys, inserted out of order")
  val k: Map[Int, String] = newMap()
  k.add(10, "ten")
  k.add(9, "nine")
  assertEqual(toString(k), "{10: ten, 9: nine}", "order is of the rendered text, so 10 precedes 9")
  val mp: Map[String, P] = newMap()
  mp.add("o", P(x = 0, y = 0))
  assertEqual(toString(mp), "{o: P(x = 0, y = 0)}", "record values")
}

test "ref record: fields, and a cycle stops" {
  val a = Cell(n = 1, next = None)
  assertEqual(toString(a), "Cell(n = 1, next = None)", "no cycle")
  a.next = Some(value = a)
  val text = toString(a)
  assertTrue(text.startsWith("Cell(n = 1, next = Some(value = Cell(n = 1, next = Some(value = "), "cycle is entered")
  assertTrue(text.contains("..."), "cycle is cut off")
}

func showIt[T](v: in T): String {
  toString(v)
}

test "a generic function stringifies the type it is specialised at" {
  assertEqual(showIt(P(x = 1, y = 2)), "P(x = 1, y = 2)", "record")
  assertEqual(showIt(newTwo()), "[1, 2]", "list")
  assertEqual(showIt(Some(value = 1)), "Some(value = 1)", "option")
  assertEqual(showIt(5), "5", "scalar")
}
