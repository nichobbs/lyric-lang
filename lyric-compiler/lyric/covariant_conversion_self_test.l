//! A value of a generic type whose type argument is a concrete type that
//! implements an interface is accepted where the same generic type over the
//! interface is declared, and converted into the declared instantiation
//! (#7774, D209).
//!
//! `Result[English, String]` and `Result[Greeter, String]` are different CLR
//! instantiations, so the value used to reach a caller's `match` as a type
//! that has none of the declared type's cases: "match not exhaustive" on
//! dotnet, while the JVM, which erases type arguments, worked.  The
//! conversion is made where the value flows into a place of the declared
//! type: a `return`, a function's tail expression, an argument, an annotated
//! `val`/`var` binding, an assignment, and a record or union-case field,
//! including inside another generic argument (`List[Result[English, String]]`).
//!
//! Every case runs on every target; the JVM shares the value and the
//! conversion is a no-op there, dotnet and native build the declared
//! instantiation.
@test_module
package CovariantConversionSelfTest

import Std.Core
import Std.Collections
import Std.Testing

interface Greeter {
  func greet(self: in Self): String
}

record English {
  n: Int
}

impl Greeter for English {
  func greet(self: in English): String {
    "hello " + toString(self.n)
  }
}

record French {
  n: Int
}

impl Greeter for French {
  func greet(self: in French): String {
    "bonjour " + toString(self.n)
  }
}

union Tree[T] {
  case Leaf(v: T)
  case Node(l: Tree[T], r: Tree[T])
}

record Box[T] {
  v: T
}

record Pair[A, B] {
  a: A
  b: B
}

record Holder {
  r: Result[Greeter, String]
}

union Slot {
  case Filled(r: Result[Greeter, String])
  case Empty
}

func okEnglish(n: in Int): Result[English, String] {
  Ok(value = English(n = n))
}

func errEnglish(msg: in String): Result[English, String] {
  Err(error = msg)
}

func describe(r: in Result[Greeter, String]): String {
  match r {
    case Ok(g) -> g.greet()
    case Err(e) -> "err " + e
  }
}

func returned(n: in Int): Result[Greeter, String] {
  val r = okEnglish(n)
  return r
}

func returnedErr(): Result[Greeter, String] {
  val r = errEnglish("bad")
  return r
}

func tailBlock(n: in Int): Result[Greeter, String] {
  val r = okEnglish(n)
  r
}

func tailExpr(n: in Int): Result[Greeter, String] = okEnglish(n)

func viaParameter(n: in Int): String {
  describe(okEnglish(n))
}

func viaParameterErr(): String {
  describe(errEnglish("no"))
}

func viaBinding(n: in Int): String {
  val r: Result[Greeter, String] = okEnglish(n)
  describe(r)
}

func viaVarBinding(n: in Int): String {
  var r: Result[Greeter, String] = okEnglish(n)
  describe(r)
}

func viaAssignment(n: in Int): String {
  var r: Result[Greeter, String] = errEnglish("first")
  r = okEnglish(n)
  describe(r)
}

func viaField(n: in Int): String {
  val h = Holder(r = okEnglish(n))
  describe(h.r)
}

func viaCaseField(n: in Int): String {
  match Filled(r = okEnglish(n)) {
    case Filled(r) -> describe(r)
    case Empty -> "empty"
  }
}

func greeters(): List[Result[Greeter, String]] {
  val xs: List[Result[English, String]] = newList()
  xs.add(okEnglish(1))
  xs.add(errEnglish("two"))
  xs.add(okEnglish(3))
  xs
}

func optionsOf(n: in Int): Result[Option[Greeter], String] {
  val inner: Option[English] = Some(value = English(n = n))
  val r: Result[Option[English], String] = Ok(value = inner)
  r
}

func noneOf(): Result[Option[Greeter], String] {
  val inner: Option[English] = None
  val r: Result[Option[English], String] = Ok(value = inner)
  r
}

func optionResult(): Option[Result[Greeter, String]] {
  val r = okEnglish(7)
  val o: Option[Result[English, String]] = Some(value = r)
  o
}

func tree(): Tree[Greeter] {
  val t: Tree[English] = Node(
    l = Leaf(v = English(n = 1)),
    r = Node(l = Leaf(v = English(n = 2)), r = Leaf(v = English(n = 3)))
  )
  t
}

func leaves(t: in Tree[Greeter]): String {
  match t {
    case Leaf(v) -> v.greet()
    case Node(l, r) -> leaves(l) + "," + leaves(r)
  }
}

func mkBox(): Box[English] {
  Box(v = English(n = 9))
}

func boxed(): Box[Greeter] {
  val b = mkBox()
  b
}

func paired(): Pair[Greeter, Result[Greeter, String]] {
  val p: Pair[English, Result[English, String]] = Pair(a = English(n = 4), b = okEnglish(5))
  p
}

func sameType(): Result[English, String] {
  val r = okEnglish(11)
  r
}

func sameTypeParameter(r: in Result[English, String]): String {
  match r {
    case Ok(e) -> e.greet()
    case Err(m) -> m
  }
}

func chosen(first: in Bool): Result[Greeter, String] {
  val r = if first { okEnglish(1) } else { errEnglish("second") }
  r
}

test "a returned value is converted" {
  assertEqual(describe(returned(1)), "hello 1", "return")
  assertEqual(describe(returnedErr()), "err bad", "return of the other case")
}

test "a tail expression is converted" {
  assertEqual(describe(tailBlock(2)), "hello 2", "block tail")
  assertEqual(describe(tailExpr(3)), "hello 3", "expression body")
}

test "an argument is converted" {
  assertEqual(viaParameter(4), "hello 4", "Ok")
  assertEqual(viaParameterErr(), "err no", "Err")
}

test "a binding and an assignment convert" {
  assertEqual(viaBinding(5), "hello 5", "val")
  assertEqual(viaVarBinding(6), "hello 6", "var")
  assertEqual(viaAssignment(7), "hello 7", "assignment")
}

test "a record or union-case field converts" {
  assertEqual(viaField(8), "hello 8", "record field")
  assertEqual(viaCaseField(9), "hello 9", "union-case field")
}

test "the elements of a list convert" {
  val xs = greeters()
  assertEqualInt(xs.count, 3, "count")
  assertEqual(describe(xs[0]), "hello 1", "first")
  assertEqual(describe(xs[1]), "err two", "second")
  assertEqual(describe(xs[2]), "hello 3", "third")
}

test "nested generic arguments convert" {
  match optionsOf(3) {
    case Ok(o) -> match o {
      case Some(g) -> assertEqual(g.greet(), "hello 3", "Result[Option]")
      case None -> assertTrue(false, "Some expected")
    }
    case Err(e) -> assertTrue(false, "Ok expected: " + e)
  }
  match noneOf() {
    case Ok(o) -> match o { case Some(_) -> assertTrue(false, "None expected"); case None -> assertTrue(true, "None") }
    case Err(e) -> assertTrue(false, "Ok expected: " + e)
  }
  match optionResult() {
    case Some(r) -> assertEqual(describe(r), "hello 7", "Option[Result]")
    case None -> assertTrue(false, "Some expected")
  }
}

test "a recursive union and generic records convert" {
  assertEqual(leaves(tree()), "hello 1,hello 2,hello 3", "Tree")
  assertEqual(boxed().v.greet(), "hello 9", "Box")
  val p = paired()
  assertEqual(p.a.greet(), "hello 4", "Pair.a")
  assertEqual(describe(p.b), "hello 5", "Pair.b")
}

test "a value of the declared type is not converted" {
  assertEqual(sameTypeParameter(sameType()), "hello 11", "identical instantiations")
  assertEqual(describe(chosen(true)), "hello 1", "a conditional value")
  assertEqual(describe(chosen(false)), "err second", "the other branch")
}
