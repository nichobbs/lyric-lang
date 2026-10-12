//! slice_func_unit_elem_self_test.l — runtime regression test for
//! `Unit`-returning function values in a slice or list (#8299).
//!
//! On `--target dotnet` a `(T1, ..., TN) -> Unit` type is a real
//! `System.Action`.  A lambda literal inside a slice or list literal of that
//! element type was built as a `Func<..., object>`, so a `List[(Int) -> Unit]`
//! literal failed in `List.Add` with `ArrayTypeMismatchException`, and a
//! slice's element was read as `object` and invoked as an `Action` that it was
//! not (ilverify: StackUnexpected).  The literal is now built as the `Action`,
//! and an indexed read or a `for` loop narrows the element to it.  So are the
//! lambdas an `if`/`match` produces for an `Action` destination (a return, a
//! list element, an annotated `val`), the elements of a slice's `.append`/
//! `.concat`/`.slice` (which used to lose the element type and invoke an
//! `Action` as a `Func`, `InvalidCastException`), and a destructured tuple
//! element.  Every lambda whose checked type returns `Unit` ends in `()` before
//! codegen, so it is built as an `Action` wherever it is made: unannotated, in
//! a generic's body, or given to a generic record's `T` field.  A lambda
//! ending in `xs.add(x)` is a `(T) -> Unit` like any other
//! (the type checker left its result unknown before).  `.toList()` is covered
//! by `slice_func_tolist_dotnet_self_test.l`.  An element of a container
//! built with no element type (`val hs = [{ -> c = v }]`) is known only as an
//! `object`; calling it tests whether it is an `Action` or a `Func`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/slice_func_unit_elem_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/slice_func_unit_elem_self_test.l
//!
//! `scripts/ilverify-selfhosted.sh` verifies the dotnet test DLL.  Not run on
//! `--target native`, whose codegen does not yet accept a `Unit`-returning
//! function type as a type argument (N0007) or a lambda that assigns a
//! captured `var`.
@test_module
package Lyric.SliceFuncUnitElemSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func unitCall(fs: in slice[(Int) -> Unit], x: in Int): Unit {
  val f = fs[0]
  f(x)
  fs[1](x)
}

func unitLoop(fs: in slice[(Int) -> Unit], x: in Int): Unit {
  for f in fs {
    f(x)
  }
}

func pick(c: in Bool, log: in List[String]): (Int) -> Unit {
  if c {
    { a: Int -> log.add("t" + toString(a)) }
  } else {
    { a: Int -> log.add("f" + toString(a)) }
  }
}

func pickMatch(c: in Bool, log: in List[String]): (Int) -> Unit {
  match c {
    case true -> ({ a: Int -> log.add("mt" + toString(a)) })
    case false -> ({ a: Int -> log.add("mf" + toString(a)) })
  }
}

func wrapList[T](x: in T): List[T] {
  val l: List[T] = newList()
  l.add(x)
  l
}

func joined(log: in List[String]): String {
  var acc = ""
  for s in log {
    acc = acc + s + " "
  }
  acc
}

record Holder[T] {
  v: T
}

record Getter[T] {
  v: T

  func get(self: in Getter[T]): T {
    self.v
  }
}

record Hooks {
  start: (Int) -> Unit
  close: () -> Unit
}

func runIt(f: in () -> Unit): Unit {
  f()
}

func makeHooks[T](x: in T, log: in List[String]): Hooks {
  val start = { n: Int -> runIt({ -> log.add("s") }); log.add(toString(n)) }
  val close = { -> log.add("c") }
  Hooks(start = start, close = close)
}

func unitListCall(fs: in List[(Int) -> Unit], x: in Int): Unit {
  val f = fs[0]
  f(x)
}

test "Unit-returning function elements of a slice, indexed" {
  var total = 0
  val us: slice[(Int) -> Unit] = [{ a: Int -> total = total + a }, { a: Int -> total = total + a * 100 }]
  unitCall(us, 3)
  assertEqualInt(total, 303, "unitCall")
}

test "Unit-returning function elements of a slice, iterated" {
  var total = 0
  val named: (Int) -> Unit = { a: Int -> total = total + a * 10 }
  val us: slice[(Int) -> Unit] = [named, { a: Int -> total = total + a }]
  unitLoop(us, 2)
  assertEqualInt(total, 22, "unitLoop")
}

test "a Unit-returning lambda literal in a list literal" {
  var total = 0
  val ls: List[(Int) -> Unit] = [{ a: Int -> total = total + a + 1 }]
  unitListCall(ls, 4)
  assertEqualInt(total, 5, "unitListCall")
}

test "the elements of a Unit-function slice's append, slice and concat" {
  val log: List[String] = newList()
  val ss: slice[(Int) -> Unit] = [{ a: Int -> log.add("a" + toString(a)) }]
  val s2 = ss.append(ss[0])
  s2[1](1)
  for f in s2 {
    f(2)
  }
  val s3 = s2.slice(0, 1)
  s3[0](3)
  val s4 = ss.concat(ss)
  s4[1](4)
  val s5 = ss.append({ a: Int -> log.add("lit" + toString(a)) })
  s5[1](7)
  val un = { a: Int -> log.add("un" + toString(a)) }
  val s6 = ss.append(un)
  s6[1](8)
  assertEqual(joined(log), "a1 a2 a2 a3 a4 lit7 un8 ", "slice ops")
}

test "Unit lambdas an if or a match produces for an Action destination" {
  val log: List[String] = newList()
  pick(true, log)(1)
  pick(false, log)(2)
  pickMatch(true, log)(3)
  pickMatch(false, log)(4)
  val c = true
  val ls: List[(Int) -> Unit] = [
    if c {
      { a: Int -> log.add("li" + toString(a)) }
    } else {
      { a: Int -> log.add("le" + toString(a)) }
    },
    match c {
      case true -> ({ a: Int -> log.add("lm" + toString(a)) })
      case false -> ({ a: Int -> log.add("ln" + toString(a)) })
    }
  ]
  for f in ls {
    f(5)
  }
  val sel: (Int) -> Unit = if c { { a: Int -> log.add("v" + toString(a)) } } else { pick(false, log) }
  sel(6)
  val wl = wrapList(pick(true, log))
  wl[0](7)
  assertEqual(joined(log), "t1 f2 mt3 mf4 li5 lm5 v6 t7 ", "if/match lambdas")
}

test "a destructured tuple's Unit-function element" {
  val log: List[String] = newList()
  val u: (Int) -> Unit = { a: Int -> log.add("u" + toString(a)) }
  val tups: slice[(Int, (Int) -> Unit)] = [(1, u), (2, u)]
  val (n, tf) = tups[1]
  tf(n)
  for t in tups {
    val (k, g) = t
    g(k)
  }
  assertEqual(joined(log), "u2 u1 u2 ", "tuple")
}

test "a Unit lambda given to a generic record's T field" {
  val log: List[String] = newList()
  val gb = Holder(v = { a: Int -> log.add("h" + toString(a)) })
  val f = gb.v
  f(1)
  val ub = Getter(v = { a: Int -> log.add("g" + toString(a)) })
  val g = ub.get()
  g(2)
  assertEqual(joined(log), "h1 g2 ", "generic field")
}

test "unannotated Unit lambdas a generic function stores in Unit-function fields" {
  val log: List[String] = newList()
  val h = makeHooks(5, log)
  h.start(1)
  h.close()
  assertEqual(joined(log), "s 1 c ", "generic make")
}

test "an element of a list literal with no element type, called" {
  var c = 0
  val hs = [{ -> c = 7 }]
  hs[0]()
  assertEqualInt(c, 7, "Unit element called through its index")
  val h = hs[0]
  c = 0
  h()
  assertEqualInt(c, 7, "Unit element bound, then called")
  val ks = [{ -> 5 }]
  val k = ks[0]
  assertEqual(toString(k()), "5", "value element")
}
