//! unit_value_self_test.l -- `Unit` is an ordinary type with exactly one value
//! on every target (#8236, #8266; repo-owner decision recorded in
//! docs/decisions/D271-unit-is-an-ordinary-value.md).
//!
//! Before the fix a `Unit`-typed parameter, local, field, or type argument was
//! lowered as "no value": dotnet emitted `InvalidProgramException` /
//! `TypeLoadException`, the JVM failed J008 (stackmap underflow), and native
//! passed `void` as an argument type that clang rejects.  Now the value `()` is
//! materialised wherever storage is needed, and a `func f(): Unit` keeps its
//! void-returning calling convention where nothing observes the value.
//!
//! Runs on dotnet, the JVM and native.
@test_module
package Lyric.UnitValueSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// -- a Unit parameter on a free function ------------------------------------
func takesUnit(u: in Unit): Int = 2

func takesUnitAndInt(n: in Int, u: in Unit, m: in Int): Int = n * 10 + m

test "a free function takes a Unit parameter" {
  val u = ()
  assertTrue(takesUnit(u) == 2, "Unit local as argument")
  assertTrue(takesUnit(()) == 2, "literal () as argument")
  assertTrue(takesUnitAndInt(3, (), 4) == 34, "Unit between two Int parameters")
}

func effect(): Unit {
  ()
}

protected type Tick {
  var n: Int = 0
  entry inc(): Unit {
    n = n + 1
  }
  func get(): Int = n
}

test "a Unit argument expression is still evaluated for its effects" {
  val t = Tick()
  assertTrue(takesUnit(t.inc()) == 2, "call with an effectful Unit argument")
  assertTrue(t.get() == 1, "the argument ran exactly once")
}

// -- a Unit parameter on a record method ------------------------------------
ref record Meter {
  var n: Int
}

func Meter.bump(self: in Meter, u: in Unit): Int {
  self.n + 1
}

test "a record method takes a Unit parameter" {
  val m = Meter(n = 4)
  assertTrue(m.bump(()) == 5, "Unit argument to a method")
}

// -- a Unit parameter on an interface method and a protected entry -----------
interface Sink {
  func accept(u: in Unit, tag: in Int): Int
}

record Tagger {
  base: Int
}

impl Sink for Tagger {
  func accept(u: in Unit, tag: in Int): Int {
    self.base + tag
  }
}

protected type Gate {
  var hits: Int = 0
  entry touch(u: in Unit): Int {
    hits = hits + 1
    hits
  }
  func peek(u: in Unit): Int = hits
}

test "an interface method takes a Unit parameter" {
  val s: Sink = Tagger(base = 100)
  assertTrue(s.accept((), 7) == 107, "dispatch with a Unit parameter")
}

test "a protected entry and member take a Unit parameter" {
  val g = Gate()
  assertTrue(g.touch(()) == 1, "entry")
  assertTrue(g.touch(()) == 2, "entry again")
  assertTrue(g.peek(()) == 2, "member")
}

// -- generic functions at T = Unit ------------------------------------------
func idg[T](x: in T): T = x

func firstOf[T](a: in T, b: in T): T = a

func wrap[T](x: in T): Option[T] = Some(x)

test "a generic function is instantiated at T = Unit" {
  val u = idg(())
  assertTrue(idg(3) == 3, "T = Int still works")
  match wrap(u) {
    case Some(_) -> assertTrue(true, "Some(Unit)")
    case None -> assertTrue(false, "wrap returned None")
  }
  val v = firstOf((), ())
  assertTrue(takesUnit(v) == 2, "the result is a usable Unit value")
}

func retG[T](x: in T): (Int) -> T {
  { n: Int -> x }
}

test "a generic function returns a lambda whose result is T = Unit" {
  val f = retG(())
  val r = f(3)
  assertTrue(takesUnit(r) == 2, "calling the lambda yields a Unit value")
}

// -- Result[Unit, E], Option[Unit], List[Unit] -------------------------------
func okUnit(flag: in Bool): Result[Unit, String] {
  if flag {
    Ok(())
  } else {
    Err("no")
  }
}

func chain(flag: in Bool): Result[Int, String] {
  val u = okUnit(flag)?
  Ok(takesUnit(u))
}

test "Result[Unit, E] carries and yields a Unit value" {
  match okUnit(true) {
    case Ok(u) -> assertTrue(takesUnit(u) == 2, "bound Ok payload is a Unit value")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  match okUnit(false) {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(e) -> assertTrue(e == "no", "Err payload")
  }
  match chain(true) {
    case Ok(n) -> assertTrue(n == 2, "? yields a usable Unit")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  match chain(false) {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(e) -> assertTrue(e == "no", "? propagates the Err")
  }
}

test "Option[Unit] carries a Unit value" {
  val o: Option[Unit] = Some(())
  match o {
    case Some(u) -> assertTrue(takesUnit(u) == 2, "Some payload")
    case None -> assertTrue(false, "expected Some")
  }
  val n: Option[Unit] = None
  match n {
    case Some(_) -> assertTrue(false, "expected None")
    case None -> assertTrue(true, "None")
  }
}

test "List[Unit] stores and returns Unit values" {
  val xs: List[Unit] = newList()
  xs.add(())
  xs.add(())
  xs.add(())
  assertTrue(xs.count == 3, "three elements")
  val first = xs[0]
  assertTrue(takesUnit(first) == 2, "an element is a Unit value")
}

// -- generic records with a Unit field --------------------------------------
record Holder[T] {
  value: T
  tag: Int
}

record Plain {
  u: Unit
  n: Int
}

test "a generic record has a Unit field" {
  val h = Holder(value = (), tag = 9)
  assertTrue(h.tag == 9, "sibling field")
  assertTrue(takesUnit(h.value) == 2, "the Unit field reads back as a Unit value")
}

test "a non-generic record has a Unit field" {
  val p = Plain(u = (), n = 5)
  assertTrue(p.n == 5, "sibling field")
  assertTrue(takesUnit(p.u) == 2, "the Unit field reads back as a Unit value")
}

// -- lambdas and function values --------------------------------------------
test "a lambda accepts and returns Unit" {
  val f = { u: Unit -> u }
  val r = f(())
  assertTrue(takesUnit(r) == 2, "identity over Unit")
}

test "a function value of type (Unit) -> Unit" {
  val t = Tick()
  val g: (Unit) -> Unit = { u: Unit -> t.inc() }
  g(())
  g(())
  assertTrue(t.get() == 2, "the Unit-taking function value ran twice")
}

test "a function value of type () -> Unit still runs for its effect" {
  val t = Tick()
  val g: () -> Unit = { -> t.inc() }
  g()
  assertTrue(t.get() == 1, "the nullary Unit function value ran")
}

func applyTo[T](f: in (T) -> T, x: in T): T = f(x)

test "a generic higher-order function at T = Unit" {
  val r = applyTo({ u: Unit -> u }, ())
  assertTrue(takesUnit(r) == 2, "applyTo over Unit")
}

test "a Unit-returning function result is observable as a value" {
  val u = effect()
  assertTrue(takesUnit(u) == 2, "val bound to a Unit call")
}

// -- annotated bindings, forwarding, captures --------------------------------
func forward(u: in Unit): Int = takesUnit(u) + 1

func pass2(a: in Unit, b: in Unit): Int = forward(b)

test "an annotated Unit binding holds the unit value" {
  val a: Unit = ()
  val b: Unit = effect()
  assertTrue(takesUnit(a) == 2, "annotated from a literal")
  assertTrue(takesUnit(b) == 2, "annotated from a Unit call")
}

test "a Unit parameter is forwarded to another call" {
  assertTrue(forward(()) == 3, "forwarded once")
  assertTrue(pass2((), effect()) == 3, "forwarded through two Unit parameters")
}

test "a closure captures a Unit local" {
  val u = ()
  val f = { -> takesUnit(u) }
  assertTrue(f() == 2, "the captured unit value is usable inside the closure")
}

func unitCapture(u: in Unit): (Int) -> Int {
  { n: Int -> n + takesUnit(u) }
}

test "a closure captures a Unit parameter" {
  val g = unitCapture(())
  assertTrue(g(1) == 3, "capture of a Unit parameter, used as a call argument")
}

record Wrap[T] {
  inner: T
}

func Wrap.get[T](self: in Wrap[T]): T = self.inner

test "a generic record method at T = Unit" {
  val w = Wrap(inner = ())
  val u = w.get()
  assertTrue(takesUnit(u) == 2, "the field read through a generic method")
}

test "Map[String, Unit] stores Unit values" {
  val m: Map[String, Unit] = newMap()
  m.add("a", ())
  assertTrue(m.containsKey("a"), "key present")
  assertTrue(m.count == 1, "one entry")
}

// -- stringification ----------------------------------------------------------
test "a Unit value renders as ()" {
  val u = ()
  assertTrue(toString(u) == "()", "toString of a Unit binding")
  assertTrue("${u}" == "()", "interpolation of a Unit binding")
  assertTrue("a" + toString(u) == "a()", "concatenation of toString")
  assertTrue(toString(effect()) == "()", "toString of a Unit call")
  assertTrue("${effect()}" == "()", "interpolation of a Unit call")
  val xs: List[Unit] = newList()
  xs.add(())
  assertTrue(toString(xs[0]) == "()", "an element read back from a List")
  assertTrue("${idg(())}" == "()", "interpolation of a generic result at T = Unit")
}
