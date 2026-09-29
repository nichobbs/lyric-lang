//! generator_element_type_self_test.l — dual-target runtime regression test
//! for the type of a `for` loop variable iterating a generator (#7750).
//!
//! `async func pts(): Pt` types its call as the element type `Pt`, and the type
//! checker's `for` typed the loop variable as if that type were the iterable:
//!
//!   * a record or union element was not a recognized iterable, so the loop
//!     variable was left untyped, and `--target jvm` -- which reads each element
//!     back through `java.util.Iterator.next()` as an erased `Object` -- then
//!     failed to compile `p.x` with J007 ("member cannot be resolved on an
//!     erased (statically Object) receiver");
//!   * a `List[Int]` element was typed as the list's own element `Int`;
//!   * an `Option[Int]` element was rejected outright with T0126 ("cannot
//!     iterate over 'Option[Int]'").
//!
//! The checker now takes a generator call's type as the loop's element type
//! whatever it is, and records the loop variable so `Lyric.Mono` binds it
//! through a local annotated with that type, which the JVM narrows the erased
//! element to.  Every case below reads members of, or matches on, the loop
//! variable directly.
//!
//! Reaching those loops exposed three more gaps, fixed alongside: on the JVM a
//! generator call's recorded generic arguments were its element type's own
//! (`[Int]` for `Option[Int]`), so each `Option` element was unboxed as an
//! `Integer`; a mono-specialised generic generator (`each[T]`) was called
//! through a descriptor returning its element type rather than the generator
//! object (`NoSuchMethodError`); and on dotnet `yield None` in an
//! `Option[Int]` generator built an `Option<object>` case.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generator_element_type_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generator_element_type_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GeneratorElementTypeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Pt {
  x: Int
  y: Int
}

union Shape {
  case Circle(r: Int)
  case Square(side: Int)
  case Dot
}

record Tagged {
  name: String
  at: Pt
}

async func points(): Pt {
  yield Pt(x = 1, y = 2)
  yield Pt(x = 3, y = 4)
  yield Pt(x = 5, y = 6)
}

async func shapes(): Shape {
  yield Circle(r = 2)
  yield Square(side = 5)
  yield Dot
}

async func lists(): List[Int] {
  val a: List[Int] = newList()
  a.add(1)
  a.add(2)
  yield a
  val b: List[Int] = newList()
  b.add(10)
  yield b
}

async func options(): Option[Int] {
  yield Some(value = 4)
  yield None
  yield Some(value = 6)
}

async func tagged(): Tagged {
  yield Tagged(name = "a", at = Pt(x = 7, y = 8))
  yield Tagged(name = "bc", at = Pt(x = 9, y = 10))
}

async func pointsUpTo(n: in Int): Pt {
  var i = 1
  while i <= n {
    yield Pt(x = i, y = i * i)
    i = i + 1
  }
}

async func each[T](xs: in List[T]): T {
  for x in xs {
    yield x
  }
}

test "generator element: record fields read from the loop variable" {
  var sx = 0
  var sy = 0
  for p in points() {
    sx = sx + p.x
    sy = sy + p.y
  }
  assertEqualInt(sx, 9, "sum of x")
  assertEqualInt(sy, 12, "sum of y")
}

test "generator element: record passed on and compared" {
  val got: List[Pt] = newList()
  for p in points() {
    if p.x > 1 {
      got.add(p)
    }
  }
  assertEqualInt(got.count, 2, "two points with x > 1")
  assertEqualInt(got[0].y, 4, "first kept point")
  assertEqualInt(got[1].y, 6, "second kept point")
}

test "generator element: nested record field chain" {
  var total = 0
  var names = ""
  for t in tagged() {
    total = total + t.at.x * t.at.y
    names = names + t.name
  }
  assertEqualInt(total, 146, "7*8 + 9*10")
  assertEqual(names, "abc", "names concatenated")
}

test "generator element: generator with a parameter" {
  var s = 0
  for p in pointsUpTo(4) {
    s = s + p.y - p.x
  }
  assertEqualInt(s, 20, "(1-1) + (4-2) + (9-3) + (16-4)")
}

test "generator element: union matched on the loop variable" {
  var s = 0
  for sh in shapes() {
    s = s + match sh { case Circle(r) -> r * 100; case Square(side) -> side; case Dot -> 1000 }
  }
  assertEqualInt(s, 1205, "200 + 5 + 1000")
}

test "generator element: List[Int] is the element, not the iterable" {
  var s = 0
  for xs in lists() {
    s = s + xs.count * 1000 + xs[0]
  }
  assertEqualInt(s, 3011, "(2*1000 + 1) + (1*1000 + 10)")
}

test "generator element: nested loop over the List[Int] element" {
  var s = 0
  for xs in lists() {
    for v in xs {
      s = s + v
    }
  }
  assertEqualInt(s, 13, "1 + 2 + 10")
}

test "generator element: Option[Int] matched on the loop variable" {
  var s = 0
  for o in options() {
    s = s + match o { case Some(v) -> v; case None -> 100 }
  }
  assertEqualInt(s, 110, "4 + 100 + 6")
}

test "generator element: Option[Int] accessors on the loop variable" {
  var some = 0
  var none = 0
  for o in options() {
    if o.isSome {
      some = some + 1
    } else {
      none = none + 1
    }
  }
  assertEqualInt(some, 2, "two Some elements")
  assertEqualInt(none, 1, "one None element")
}

test "generator element: generic generator specialised to a record" {
  val ps: List[Pt] = newList()
  ps.add(Pt(x = 1, y = 2))
  ps.add(Pt(x = 3, y = 4))
  var s = 0
  for p in each(ps) {
    s = s + p.x * p.y
  }
  assertEqualInt(s, 14, "1*2 + 3*4")
}

test "generator element: generic generator specialised to an Option" {
  val os: List[Option[Int]] = newList()
  os.add(Some(value = 5))
  os.add(None)
  var t = 0
  for o in each(os) {
    t = t + match o { case Some(v) -> v; case None -> 10 }
  }
  assertEqualInt(t, 15, "5 + 10")
}
