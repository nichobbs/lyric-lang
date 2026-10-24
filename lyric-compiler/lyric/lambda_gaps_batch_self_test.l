//! lambda_gaps_batch_self_test.l — runtime regression tests for lambda and
//! closure gaps on the self-hosted backends.
//!
//!   * #8345  an outer name shadowed by a `for` variable inside a lambda is
//!            still captured for the code after the loop.
//!   * #8442  a lambda returning a lambda that matches a generic union, called
//!            with a bare case constructor argument (`f(Left(3))`), whose type
//!            arguments come from the function value's parameter type.
//!   * #8349  a slice lambda parameter reaching a typed local and a typed
//!            function parameter (ilverify-gated on dotnet).
//!   * #8347  a member read on the result of a chained curried call under
//!            explicit type arguments (`boxer[Int]()(9)().v`).
//!   * #8319  a function-typed field of a generic record instance.
//!   * #8302  a lambda as a parameter or record field default.
//!   * #8232  `assert` inside a lambda inside a generic function.
//!   * #7880  a lambda given to a record constructor takes its field's function
//!            type, including a widening result.
//!   * #7460  a closure writing a field of a captured record, `var` and `val`.
//!   * #7152  `return` nested in a lambda's `if`/`else` returns the lambda's
//!            own result type.
//!   * #7219  a `Unit`-returning function value stored in a field and passed
//!            to a parameter of the same function type.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/lambda_gaps_batch_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/lambda_gaps_batch_self_test.l
//!
//! `scripts/ilverify-selfhosted.sh` verifies the dotnet test DLL.  Imports
//! only `Std.*`.
@test_module
package Lyric.LambdaGapsBatchSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─── #8345 ──────────────────────────────────────────────────────────────────
func runSum(f: in () -> Int): Int {
  f()
}

test "a for variable shadowing a captured name leaves the capture after the loop" {
  val x = 100
  val xs = [1, 2, 3]
  val r = runSum({ -> var s = 0; for x in xs { s = s + x }; s + x })
  assertEqualInt(r, 106, "the loop sums 1..3, then x is the captured 100")
}

test "a match arm binding shadowing a captured name leaves the capture after the match" {
  val n = 7
  val r = runSum(
    { ->
      val o: Option[Int] = Some(1)
      val inner = match o { case Some(n) -> n + 10; case None -> 0 }
      inner + n
    }
  )
  assertEqualInt(r, 18, "the arm binds its own n, the tail reads the captured one")
}

// ─── #8442 ──────────────────────────────────────────────────────────────────
union Either[A, B] {
  case Left(a: A)
  case Right(b: B)
}

test "a function value called with a bare generic case argument builds the declared instantiation" {
  val g: (Either[Int, String]) -> String = { e ->
    match e {
      case Left(a) -> "L" + toString(a)
      case Right(b) -> "R" + b
    }
  }
  assertEqual(g(Left(3)), "L3", "Left argument")
  assertEqual(g(Right("x")), "Rx", "Right argument")
}

test "a lambda returning a lambda that matches a union it captured" {
  val f: (Either[Int, String]) -> () -> String = { e ->
    { -> match e { case Left(a) -> "L" + toString(a); case Right(b) -> "R" + b } }
  }
  assertEqual(f(Left(3))(), "L3", "captured Left")
  assertEqual(f(Right("x"))(), "Rx", "captured Right")
  val v: Either[Int, String] = Right("y")
  assertEqual(f(v)(), "Ry", "captured bound Right")
}

// ─── #8349 ──────────────────────────────────────────────────────────────────
func firstOf(s: in slice[Int]): Int {
  s[0]
}

func lenOf(s: in slice[String]): Int {
  s.length
}

test "a slice lambda parameter reaches a typed local and a typed parameter" {
  val f = { xs: slice[Int] -> val cp = xs; firstOf(cp) }
  assertEqualInt(f([4, 5]), 4, "slice[Int] through a local")
  val g = { ss: slice[String] -> lenOf(ss) }
  assertEqualInt(g(["a", "b", "c"]), 3, "slice[String] to a parameter")
}

test "a slice lambda parameter captured by an inner lambda" {
  val f = { xs: slice[Int] -> { -> firstOf(xs) } }
  assertEqualInt(f([9, 8])(), 9, "captured slice")
}

// ─── #8347 ──────────────────────────────────────────────────────────────────
record Box[T] {
  v: T
}

func boxer[T](): (T) -> () -> Box[T] {
  { t: T -> { -> Box(v = t) } }
}

test "a member read on the result of a chained curried call" {
  assertEqualInt(boxer[Int]()(9)().v, 9, "chained, Int")
  assertEqual(boxer[String]()("s")().v, "s", "chained, String")
  val g = boxer[Int]()
  val h = g(4)
  val b = h()
  assertEqualInt(b.v, 4, "untyped bindings")
}

// ─── #8319 ──────────────────────────────────────────────────────────────────
record Holder[T] {
  f: (T) -> T
}

test "a function-typed field of a generic record instance" {
  val u = { x: Int -> x + 1 }
  assertEqualInt(Holder(f = u).f(3), 4, "constructed in place")
  val h = Holder(f = u)
  assertEqualInt(h.f(4), 5, "bound")
}

// ─── #8302 ──────────────────────────────────────────────────────────────────
record WithDefault {
  v: Int
  f: () -> Int = { -> 1 }

  func call(self: in WithDefault, h: () -> Int = { -> 3 }): Int {
    h() + self.v
  }
}

record GenericDefault[T] {
  v: T
  g: () -> Int = { -> 2 }
}

func withDefault(h: () -> Int = { -> 4 }): Int {
  h()
}

func withDefaultTwice(a: () -> Int = { -> 5 }, b: (Int) -> Int = { n -> n + 1 }): Int {
  b(a())
}

test "a lambda parameter default" {
  assertEqualInt(withDefault(), 4, "default used")
  assertEqualInt(withDefault({ -> 40 }), 40, "default overridden")
  assertEqualInt(withDefault(), 4, "default used again")
  assertEqualInt(withDefaultTwice(), 6, "two defaults")
}

test "a lambda record field default" {
  val p = WithDefault(v = 3)
  assertEqualInt(p.f(), 1, "field default")
  val q = WithDefault(v = 3, f = { -> 9 })
  assertEqualInt(q.f(), 9, "field default overridden")
}

test "a lambda method parameter default" {
  val m = WithDefault(v = 10)
  assertEqualInt(m.call(), 13, "method default")
  assertEqualInt(m.call({ -> 1 }), 11, "method default overridden")
}

test "a lambda default of a generic record" {
  val s: GenericDefault[Int] = GenericDefault(v = 3)
  assertEqualInt(s.g(), 2, "generic record field default")
}

// ─── #8232 ──────────────────────────────────────────────────────────────────
func assertingLambda[T](x: T, s: String): () -> String {
  { -> assert(s.length > 0, "nonempty"); s + "!" }
}

func assertingCount[T](xs: List[T]): () -> Int {
  { -> assert(xs.count >= 0); xs.count }
}

func applyThunk[T](f: () -> T): T {
  f()
}

func assertingInArg[T](x: T): T {
  applyThunk({ -> assert(true, "in arg"); x })
}

test "assert inside a lambda inside a generic function" {
  assertEqual(assertingLambda(1, "a")(), "a!", "String capture")
  val l: List[String] = ["a", "b"]
  assertEqualInt(assertingCount(l)(), 2, "List capture")
  assertEqual(assertingInArg("q"), "q", "String specialisation")
  assertEqualInt(assertingInArg(8), 8, "Int specialisation")
}

// ─── #7880 ──────────────────────────────────────────────────────────────────
record LongFn {
  f: () -> Long
}

test "a lambda given to a record constructor takes the field's function type" {
  val a = LongFn(f = { -> 5 })
  val b = LongFn({ -> 6 })
  assertEqualLong(a.f(), 5i64, "named")
  assertEqualLong(b.f(), 6i64, "positional")
}

// ─── #7460 ──────────────────────────────────────────────────────────────────
ref record Cell {
  var n: Int
}

func runUnit(f: in () -> Unit): Unit {
  f()
}

@cfg(not(target = "native"))
test "a closure writing a field of a captured record" {
  var b = Cell(n = 1)
  runUnit({ -> b.n = 5 })
  assertEqualInt(b.n, 5, "var local")
  val c = Cell(n = 1)
  runUnit({ -> c.n = 7 })
  assertEqualInt(c.n, 7, "val local")
}

// ─── #7152 ──────────────────────────────────────────────────────────────────
func apply1(g: in (Int) -> Int): Int {
  g(5)
}

func nestedReturn(): Int {
  apply1({ x: Int -> if x > 0 { return x * 2 } else { return 0 } })
}

func nestedReturnInUnit(): Unit {
  val r = apply1({ x: Int -> if x > 0 { return x * 2 } else { return 0 } })
  assertEqualInt(r, 10, "lambda return inside a Unit function")
}

test "return nested in a lambda returns the lambda's own result" {
  assertEqualInt(nestedReturn(), 10, "Int function")
  nestedReturnInUnit()
}

// ─── #8319 follow-up: Std.Core functions called on a union ──────────────────
test "a stdlib function named on a union binds by its first argument" {
  val o: Option[Int] = Some(4)
  assertTrue(o.isSome(), "Std.Core isSome")
  val r: Result[Int, String] = Ok(1)
  assertTrue(r.isOk(), "Std.Core isOk")
}

// ─── #7219 ──────────────────────────────────────────────────────────────────
record Host {
  start: (Int) -> Unit
}

func callWith(a: in (Int) -> Unit, n: in Int): Unit {
  a(n)
}

test "a Unit-returning function value stored in a field and passed on" {
  val seen: List[Int] = newList()
  val s = { n: Int -> seen.add(n) }
  val h = Host(start = s)
  h.start(1)
  callWith(s, 2)
  callWith(h.start, 3)
  assertEqualInt(seen.count, 3, "called three times")
  assertEqualInt(seen[2], 3, "the field's value is the same function")
}
