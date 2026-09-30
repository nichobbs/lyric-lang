//! list_literal_join_self_test.l — dual-target runtime regression test for a
//! list literal whose element type only its elements together fix (#7818).
//!
//! `[Some(1), None, Some(3)]` has element type `Option[Int]`, but `None`
//! alone fixes nothing about it.  The MSIL backend, whose generics are
//! reified, built a literal no collection type is expected of as a
//! `List<object>` with each element at its own instantiation (`Some(1)` an
//! `Option<int>`, `None` an `Option<object>`), and read its elements back as
//! `object`: `for o in [...] { match o { case Some(v) -> ... } }` summed
//! garbage, and passing the literal to a `slice[Option[Int]]` parameter threw
//! `InvalidCastException` on the `None`.  An annotated `slice[Option[Int]]`
//! literal and a `List[Option[Int]]` literal holding a bare `None` built the
//! `None` wrong too.
//!
//! The type checker now joins the element types (each hole takes what a
//! sibling has there), and a literal typed with no collection type expected
//! of it is bound to a local of that checked type, so every element is built
//! at one closed instantiation and read back at it.  The JVM erases generics
//! and was already correct; every case runs on both targets.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/list_literal_join_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/list_literal_join_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ListLiteralJoinSelfTest

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing

record OptBox {
  items: List[Option[Int]]
}

func sumOpts(xs: in slice[Option[Int]]): Int {
  var t = 0
  for o in xs {
    match o {
      case Some(v) -> {
        t = t + v
      }
      case None -> ()
    }
  }
  t
}

func sumOptList(xs: in List[Option[Int]]): Int {
  var t = 0
  for o in xs {
    match o {
      case Some(v) -> {
        t = t + v
      }
      case None -> ()
    }
  }
  t
}

func sumResults(xs: in slice[Result[Int, String]]): Int {
  var t = 0
  for r in xs {
    match r {
      case Ok(v) -> {
        t = t + v
      }
      case Err(e) -> {
        t = t + e.length * 100
      }
    }
  }
  t
}

func sumNested(xs: in slice[Option[Option[Int]]]): Int {
  var t = 0
  for o in xs {
    match o {
      case Some(Some(v)) -> {
        t = t + v
      }
      case Some(None) -> {
        t = t + 1000
      }
      case None -> ()
    }
  }
  t
}

func countSome[T](xs: in slice[Option[T]]): Int {
  var n = 0
  for o in xs {
    match o {
      case Some(_) -> {
        n = n + 1
      }
      case None -> ()
    }
  }
  n
}

func someNoneSome[T](x: in T): slice[Option[T]] {
  [Some(x), None, Some(x)]
}

func mixedReturned(): slice[Option[Int]] {
  val xs = [Some(1), None, Some(3)]
  xs
}

async func asyncFive(): Int {
  await Std.Task.delay(5)
  5
}

async func asyncElementSum(): Int {
  var t = 0
  for o in [Some(await asyncFive()), None, Some(1)] {
    match o {
      case Some(v) -> {
        t = t + v
      }
      case None -> ()
    }
  }
  t
}

test "for over an unannotated literal mixing Some and None" {
  var t = 0
  for o in [Some(1), None, Some(3)] {
    match o {
      case Some(v) -> {
        t = t + v
      }
      case None -> ()
    }
  }
  assertEqualInt(t, 4, "Some(1) + Some(3)")
}

test "for over an unannotated literal whose first element is None" {
  var t = 0
  var nones = 0
  for o in [None, Some(5)] {
    match o {
      case Some(v) -> {
        t = t + v
      }
      case None -> {
        nones = nones + 1
      }
    }
  }
  assertEqualInt(t, 5, "payload")
  assertEqualInt(nones, 1, "None seen")
}

test "for over an unannotated literal of Some only" {
  var t = 0
  for o in [Some(1), Some(3)] {
    match o {
      case Some(v) -> {
        t = t + v
      }
      case None -> ()
    }
  }
  assertEqualInt(t, 4, "Some(1) + Some(3)")
}

test "an unannotated literal bound to a val, indexed and counted" {
  val xs = [Some(1), None, Some(3)]
  assertEqualInt(xs.count, 3, ".count")
  match xs[2] {
    case Some(v) -> assertEqualInt(v + 1, 4, "xs[2] payload")
    case None -> assertTrue(false, "xs[2] should be Some")
  }
  match xs[1] {
    case Some(_) -> assertTrue(false, "xs[1] should be None")
    case None -> assertTrue(true, "xs[1] is None")
  }
}

test "an unannotated literal passed to a slice parameter and returned" {
  assertEqualInt(sumOpts([Some(2), None, Some(4)]), 6, "argument")
  assertEqualInt(sumOpts(mixedReturned()), 4, "returned through a local")
}

test "annotated slice and List literals holding None" {
  val a: slice[Option[Int]] = [Some(1), None, Some(3)]
  assertEqualInt(sumOpts(a), 4, "slice[Option[Int]]")
  val b: List[Option[Int]] = [Some(1), None, Some(3)]
  assertEqualInt(sumOptList(b), 4, "List[Option[Int]]")
  val c: List[Option[Int]] = [None]
  assertEqualInt(c.count, 1, "List of one None")
  match c[0] {
    case Some(_) -> assertTrue(false, "c[0] should be None")
    case None -> assertTrue(true, "c[0] is None")
  }
  assertEqualInt(sumOptList([Some(1), None, Some(3)]), 4, "List parameter")
  val box = OptBox(items = [Some(1), None, Some(2)])
  assertEqualInt(sumOptList(box.items), 3, "List record field")
}

test "Ok and Err mixed in one literal" {
  assertEqualInt(sumResults([Ok(1), Err("ab"), Ok(3)]), 204, "argument")
  var t = 0
  for r in [Err("x"), Ok(7)] {
    match r {
      case Ok(v) -> {
        t = t + v
      }
      case Err(_) -> {
        t = t + 10
      }
    }
  }
  assertEqualInt(t, 17, "for over the literal")
}

test "nested options and nested literals" {
  assertEqualInt(sumNested([Some(Some(1)), None, Some(None), Some(Some(4))]), 1005, "Option[Option[Int]] argument")
  var t = 0
  for o in [Some(None), Some(Some(2)), None] {
    match o {
      case Some(Some(v)) -> {
        t = t + v
      }
      case Some(None) -> {
        t = t + 100
      }
      case None -> ()
    }
  }
  assertEqualInt(t, 102, "for over Option[Option[Int]]")
  var u = 0
  for inner in [[Some(1)], [None, Some(5)]] {
    for o in inner {
      match o {
        case Some(v) -> {
          u = u + v
        }
        case None -> ()
      }
    }
  }
  assertEqualInt(u, 6, "literal of literals")
}

test "tuple elements and a String payload" {
  var t = 0
  for p in [(None, 1), (Some(2), 3)] {
    match p {
      case (Some(v), w) -> {
        t = t + v + w
      }
      case (None, w) -> {
        t = t + w
      }
    }
  }
  assertEqualInt(t, 6, "tuple elements")
  var n = 0
  for o in [Some("ab"), None] {
    match o {
      case Some(s) -> {
        n = n + s.length
      }
      case None -> {
        n = n + 10
      }
    }
  }
  assertEqualInt(n, 12, "String payload")
}

test "a literal passed to and built in a generic function" {
  assertEqualInt(countSome([Some(1), None, Some(3)]), 2, "generic callee")
  assertEqualInt(countSome(someNoneSome("a")), 2, "generic body, T = String")
  assertEqualInt(sumOpts(someNoneSome(4)), 8, "generic body, T = Int")
}

test "a literal whose first element awaits" {
  assertEqualInt(await asyncElementSum(), 6, "await in an element")
}
