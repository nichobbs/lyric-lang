//! generic_ctor_open_arg_self_test.l — cross-target runtime regression test
//! for generic constructors given an argument that leaves its own type open
//! (#7844).
//!
//! 1. Inference.  `Holder(value = None, fallback = 5)` for
//!    `record Holder[T] { value: Option[T]; fallback: T }` failed with T0110:
//!    the `None` bound `T` to a hole, and the later `fallback` argument could
//!    not fill it.  A generic call's type arguments are now bound past such a
//!    hole for every call, constructor or function, and a union case's named
//!    arguments bind by field name in any order.
//! 2. Construction.  Where nothing around the construction gave its type
//!    (`val h = Holder(...)`), --target dotnet built the `None` as an
//!    `Option<object>` and stored it in an `Option<int>` field ("match not
//!    exhaustive"), whichever field the `None` was in.  The checker now
//!    records the open argument's type at its field, and `Lyric.Mono` binds it
//!    to a local of that type, as for the operands the await hoist binds
//!    (#7823).
//!
//! The `None` is the first, a middle and the last field, in record and union
//! case constructors, passed by name in and out of declaration order and by
//! position, in unannotated bindings, arguments, returns and generic bodies.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_ctor_open_arg_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/generic_ctor_open_arg_self_test.l
//!   lyric test --target native lyric-compiler/lyric/generic_ctor_open_arg_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GenericCtorOpenArgSelfTest

import Std.Core
import Std.Testing

record Holder[T] {
  value: Option[T]
  fallback: T
}

record Middle[T] {
  first: T
  maybe: Option[T]
  last: T
}

record Tail[T] {
  head: T
  rest: Option[T]
}

union Shape[T] {
  case Pair(first: Option[T], second: T)
  case Solo(only: T)
}

func holderValue(h: in Holder[Int]): Int {
  match h.value {
    case Some(v) -> v
    case None -> h.fallback + 1000
  }
}

func middleValue(m: in Middle[Int]): Int {
  match m.maybe {
    case Some(v) -> v
    case None -> m.first + m.last + 1000
  }
}

func tailText(t: in Tail[String]): String {
  match t.rest {
    case Some(v) -> v
    case None -> "none " + t.head
  }
}

func shapeValue(s: in Shape[Int]): Int {
  match s {
    case Pair(f, n) -> match f { case Some(v) -> v; case None -> n + 1000 }
    case Solo(o) -> o
  }
}

func pick[T](a: in Option[T], b: in T): T {
  match a {
    case Some(v) -> v
    case None -> b
  }
}

func makeHolder[T](fallback: in T): Holder[T] {
  Holder(value = None, fallback = fallback)
}

func holderOr[T](h: in Holder[T]): T {
  match h.value {
    case Some(v) -> v
    case None -> h.fallback
  }
}

func returnedHolder(): Holder[Int] {
  Holder(value = None, fallback = 9)
}

test "a None first field, named" {
  val h = Holder(value = None, fallback = 5)
  assertEqualInt(holderValue(h), 1005, "unannotated binding")
  assertEqualInt(holderValue(Holder(value = None, fallback = 6)), 1006, "argument")
  assertEqualInt(holderValue(returnedHolder()), 1009, "returned")
}

test "a None first field, named out of order" {
  val h = Holder(fallback = 7, value = None)
  assertEqualInt(holderValue(h), 1007, "fallback named first")
}

test "a None first field, positional" {
  val h = Holder(None, 8)
  assertEqualInt(holderValue(h), 1008, "positional")
}

test "a None middle field" {
  val m = Middle(first = 1, maybe = None, last = 2)
  assertEqualInt(middleValue(m), 1003, "named")
  val p = Middle(1, None, 3)
  assertEqualInt(middleValue(p), 1004, "positional")
}

test "a None last field" {
  val t = Tail(head = "s", rest = None)
  assertEqual(tailText(t), "none s", "named")
  val p = Tail("p", None)
  assertEqual(tailText(p), "none p", "positional")
}

test "a None union-case field" {
  val s = Pair(first = None, second = 7)
  assertEqualInt(shapeValue(s), 1007, "named")
  val r = Pair(second = 8, first = None)
  assertEqualInt(shapeValue(r), 1008, "named out of order")
  val q = Pair(None, 9)
  assertEqualInt(shapeValue(q), 1009, "positional")
  assertEqualInt(shapeValue(Pair(first = Some(4), second = 0)), 4, "Some")
}

test "a generic body" {
  assertEqualInt(holderOr(makeHolder(3)), 3, "Int")
  assertEqual(holderOr(makeHolder("g")), "g", "String")
}

test "a generic function given None first" {
  val n = pick(None, 5)
  assertEqualInt(n + 1, 6, "result typed from the later argument")
  assertEqual(pick(None, "x"), "x", "String")
}
